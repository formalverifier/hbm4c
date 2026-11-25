// ---------------------------------------------------------------------------
// fv_nhi_target -- P-NHI-*.
//
// The NHI has no ready signal on the request channel: a credit IS the
// permission to send (docs/03-interface-spec.md 1).  That makes the
// controller's obligation an accounting one, and accounting bugs here are
// silent.  Over-issue a credit and the host sends a request the transaction
// pool has no room for -- it is dropped, and nothing reports it.  The host
// waits forever for a response that will never come.
//
// P-NHI-4 (response stability) is the other silent one.  Withdrawing or
// mutating a response while the host is back-pressuring corrupts data with no
// error path, exactly like an AXI slave changing RDATA before RREADY.
// ---------------------------------------------------------------------------
module fv_nhi_target
  import hbm4_pkg::*;
(
  input logic                  clk,
  input logic                  rst_n,
  input logic                  req_valid,
  input logic                  req_wr,
  input logic [PC_BLK_W-1:0]   req_blk,
  input tag_t                  req_tag,
  input qos_t                  req_qos,
  input logic                  cmpl_valid,
  input tag_t                  cmpl_tag,
  input logic                  cmpl_wr,
  input logic [DFI_DATA_W-1:0] cmpl_data,
  input logic [1:0]            cmpl_err,
  input logic                  rsp_ready
);

  logic                  req_credit, core_valid, core_wr, cmpl_ready;
  logic [PC_BLK_W-1:0]   core_blk;
  tag_t                  core_tag, rsp_tag;
  qos_t                  core_qos;
  logic                  rsp_valid, rsp_wack, stall_err;
  logic [DFI_DATA_W-1:0] rsp_data;
  logic [1:0]            rsp_err;
  logic [TQ_IDX_W:0]     outstanding;

  hbm4_nhi_target dut (
    .clk (clk), .rst_n (rst_n),
    .req_valid (req_valid), .req_wr (req_wr), .req_blk (req_blk),
    .req_tag (req_tag), .req_qos (req_qos), .req_credit (req_credit),
    .core_valid (core_valid), .core_wr (core_wr), .core_blk (core_blk),
    .core_tag (core_tag), .core_qos (core_qos),
    .cmpl_valid (cmpl_valid), .cmpl_tag (cmpl_tag), .cmpl_wr (cmpl_wr),
    .cmpl_data (cmpl_data), .cmpl_err (cmpl_err), .cmpl_ready (cmpl_ready),
    .rsp_valid (rsp_valid), .rsp_ready (rsp_ready), .rsp_tag (rsp_tag),
    .rsp_data (rsp_data), .rsp_err (rsp_err), .rsp_wack (rsp_wack),
    .outstanding (outstanding), .stall_err (stall_err)
  );

  logic [TQ_IDX_W+2:0] n_accepted;

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- ASSUMPTION A8: the host obeys its credits --------------------------
  // Host rule H1 (docs/03-interface-spec.md 1.6): assert req_valid only while
  // holding a credit.  The controller cannot enforce this -- there is no ready
  // to withhold -- so it is the host's obligation, and the verification kit
  // ships an NHI protocol assertion for the integrator to bind into their
  // fabric adapter.  Nothing in the controller detects a violation, which is
  // exactly why the assertion is shipped.
  always @(*)
    if (f_past_valid && rst_n && req_valid)
      assume (outstanding < (TQ_IDX_W+1)'(TQ_DEPTH));

  // The core does not produce a completion the buffer cannot take.
  always @(*)
    if (f_past_valid && rst_n && cmpl_valid)
      assume (cmpl_ready);

  // ---- ASSUMPTION A9: exactly one completion per accepted request ---------
  // The core never completes work it was never given.  Without this the free
  // environment invents completions out of nowhere, the outstanding counter
  // underflows, and the resulting counterexample says nothing about the NHI
  // endpoint.  Discharged by the transaction pool (P-POOL-3, counts sum) and
  // the response path, once the PC slice is assembled in Rev 0.8.
  logic [TQ_IDX_W+2:0] n_cmpl;
  always @(posedge clk)
    if (!rst_n)                        n_cmpl <= '0;
    else if (cmpl_valid && cmpl_ready) n_cmpl <= n_cmpl + 1'b1;

  always @(*)
    if (f_past_valid && rst_n && cmpl_valid)
      assume (n_cmpl < n_accepted);

  // ---- P-NHI-1: credit conservation ---------------------------------------
  // An INDEPENDENT shadow of the outstanding count, sized like the DUT's.
  //
  // The first version used two free-running totals (accepted, credited) and
  // asserted their difference.  Basecase passed; induction could not, because
  // the solver may start with totals that differ by more than the counter can
  // represent -- a state unreachable from reset but not excluded by anything.
  // A same-width shadow of the quantity actually being checked has no such
  // gap, and is no less independent.
  logic [TQ_IDX_W:0] shadow_out;
  always @(posedge clk) begin
    if (!rst_n) begin
      shadow_out <= '0;
      n_accepted <= '0;
    end else begin
      // Mirrors the DUT's saturation.  Under A8 (the host obeys its credits)
      // the guards never engage -- they are defence against an upstream fault,
      // and p_no_overflow proves the bound holds regardless.
      case ({req_valid, req_credit})
        2'b10: if (shadow_out != (TQ_IDX_W+1)'(TQ_DEPTH))
                 shadow_out <= shadow_out + 1'b1;
        2'b01: if (shadow_out != '0)
                 shadow_out <= shadow_out - 1'b1;
        default: ;
      endcase
      if (req_valid)  n_accepted <= n_accepted + 1'b1;
    end
  end

  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_conservation: assert (shadow_out == outstanding);
      p_no_overflow : assert (outstanding <= (TQ_IDX_W+1)'(TQ_DEPTH));
    end

  // ---- P-NHI-2: the request is passed through unmodified -------------------
  always @(*)
    if (f_past_valid && rst_n && req_valid) begin
      p_passthrough: assert (core_valid && (core_tag == req_tag)
                             && (core_blk == req_blk) && (core_wr == req_wr)
                             && (core_qos == req_qos));
    end

  // ---- P-NHI-4: a response is never withdrawn or mutated ------------------
  // While the host back-pressures, rsp_valid must stay asserted and every
  // payload field must hold.  Changing them mid-handshake hands the host data
  // belonging to a different transaction, with no error anywhere.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(rsp_valid) && !$past(rsp_ready)) begin
      p_rsp_held   : assert (rsp_valid);
      p_rsp_stable : assert ((rsp_tag  == $past(rsp_tag))
                          && (rsp_data == $past(rsp_data))
                          && (rsp_err  == $past(rsp_err))
                          && (rsp_wack == $past(rsp_wack)));
    end

  // ---- P-NHI-5: a credit accompanies the response leaving, not arriving ---
  // Returning the credit when a completion reaches the skid buffer would let
  // the host refill while a beat is still stuck behind back-pressure.
  always @(*)
    if (f_past_valid && rst_n)
      p_credit_on_fire: assert (req_credit == (rsp_valid && rsp_ready));

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_full        : cover (outstanding == (TQ_IDX_W+1)'(TQ_DEPTH));
    c_backpressure: cover (rsp_valid && !rsp_ready);
    c_credit      : cover (req_credit);
    c_wack        : cover (rsp_valid && rsp_wack);
    c_drain       : cover ((outstanding == '0) && $past(outstanding != '0));
  end

endmodule
