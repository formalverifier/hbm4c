// ---------------------------------------------------------------------------
// fv_rd_ptr_fifo -- P-DFI-*.
//
// This FIFO decides WHICH TRANSACTION each returning read belongs to.  If it
// mis-routes, the controller hands one requester another requester's data --
// valid data, correct ECC, wrong owner.  Nothing detects that: not ECC, not the
// timing checker, not a scoreboard unless it happens to compare payloads.
//
// The property that matters is order preservation (P-DFI-2), proved here the
// way order properties should be: pick an arbitrary pair of pushes and require
// them to pop in the same relative order.  Checking only "what goes in comes
// out" would pass on a FIFO that reverses everything.
// ---------------------------------------------------------------------------
module fv_rd_ptr_fifo
  import hbm4_pkg::*;
#(
  parameter int unsigned DEPTH = 8
) (
  input logic   clk,
  input logic   rst_n,
  input logic   push,
  input logic [TAG_W-1:0] push_idx,
  input logic   pop
);

  localparam int unsigned AW = $clog2(DEPTH);

  logic [TAG_W-1:0] pop_idx;
  logic        empty, full, overflow_err, underflow_err;
  logic [AW:0] level;
  logic [AW-1:0] w_ptr, r_ptr;

  hbm4_rd_ptr_fifo #(.DEPTH(DEPTH), .PW(TAG_W)) dut (
    .clk (clk), .rst_n (rst_n),
    .push (push), .push_idx (push_idx), .pop (pop), .pop_idx (pop_idx),
    .empty (empty), .full (full), .level (level),
    .overflow_err (overflow_err), .underflow_err (underflow_err),
    .dbg_wptr (w_ptr), .dbg_rptr (r_ptr)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // NO assumptions on push/pop.  An earlier version assumed the adapter never
  // pushes when full or pops when empty -- which made the RTL's guards
  // unreachable, so DELETING THEM SURVIVED MUTATION TESTING.  The same trap as
  // A5 in fv_refresh.
  //
  // Leaving the environment free is strictly stronger, and it models a real
  // integration case: a PHY whose round trip exceeds RD_FIFO_DEPTH.  The FIFO
  // must then REPORT and hold, never wrap -- a wrapped pointer routes read data
  // to the wrong transaction, which is silent corruption.

  // ---- P-DFI-3: robustness against a PHY that overruns the FIFO ----------
  always @(*)
    if (f_past_valid && rst_n) begin
      p_ovf_reported: assert (overflow_err  == (push && full));
      p_unf_reported: assert (underflow_err == (pop  && empty));
    end

  // A push when full must not disturb the queue, and a pop when empty must not
  // advance past valid entries.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)) begin
      if ($past(push) && $past(full) && !$past(pop))
        p_ovf_holds: assert (w_ptr == $past(w_ptr));
      if ($past(pop) && $past(empty) && !$past(push))
        p_unf_holds: assert (r_ptr == $past(r_ptr));
    end

  // Any error means entries were refused, so the ordering bookkeeping below no
  // longer describes the queue.  Track it and gate the order properties.
  logic any_err;
  always @(posedge clk)
    if (!rst_n)                              any_err <= 1'b0;
    else if (overflow_err || underflow_err)  any_err <= 1'b1;

  // ---- P-DFI-1: level accounting --------------------------------------------
  logic [AW:0] shadow;
  always @(posedge clk)
    if (!rst_n) shadow <= '0;
    else case ({push && !full, pop && !empty})
      2'b10:   shadow <= shadow + 1'b1;
      2'b01:   shadow <= shadow - 1'b1;
      default: ;
    endcase

  // Strengthening invariant for k-induction: the count and the two pointers
  // must agree.  Induction otherwise starts from a state where wptr, rptr and
  // cnt are mutually inconsistent -- unreachable from reset, but the solver
  // cannot know that, and every level property then fails for a reason the
  // design never exhibits.  This is the standard FIFO invariant.
  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_ptr_agree: assert (AW'(level) == AW'(w_ptr - r_ptr));
    end

  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_level    : assert (level == shadow);
      p_bounds   : assert (level <= (AW+1)'(DEPTH));
      p_empty    : assert (empty == (level == '0));
      p_full     : assert (full  == (level == (AW+1)'(DEPTH)));
    end

  // ---- P-DFI-2: ORDER IS PRESERVED -----------------------------------------
  // Track two arbitrary pushes, the first strictly before the second, and
  // require them to emerge in that order carrying their own values.
  (* anyconst *) logic [AW:0] f_first, f_second;

  logic [AW:0] n_push, n_pop;
  always @(posedge clk)
    if (!rst_n) begin
      n_push <= '0; n_pop <= '0;
    end else begin
      if (push && !full)  n_push <= n_push + 1'b1;
      if (pop  && !empty) n_pop  <= n_pop  + 1'b1;
    end

  always @(*) assume (f_first < f_second);

  // Capture the value pushed at each tracked position.
  logic [TAG_W-1:0] v_first, v_second;
  always @(posedge clk) begin
    if (push && !full && (n_push == f_first))  v_first  <= push_idx;
    if (push && !full && (n_push == f_second)) v_second <= push_idx;
  end

  always @(posedge clk)
    if (f_past_valid && rst_n && pop && !empty && !any_err) begin
      // The pop at index f_first must be the value pushed at f_first -- not
      // merely *a* pushed value.  This is what a reversing or dropping FIFO
      // fails, and what a weaker "something came out" property would miss.
      if (n_pop == f_first)  p_order_first : assert (pop_idx == v_first);
      if (n_pop == f_second) p_order_second: assert (pop_idx == v_second);
    end

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_full        : cover (full);
    c_drain       : cover (empty && $past(!empty));
    c_simultaneous: cover (push && pop);
    c_ordered_pair: cover (pop && !empty && !any_err && (n_pop == f_second));
    c_overflow    : cover (overflow_err);
    c_underflow   : cover (underflow_err);
  end


endmodule
