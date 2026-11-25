// ---------------------------------------------------------------------------
// fv_pmgr -- P-PM-*.
//
// P-PM-1 is a hang property, not a data property, and hangs are the harder
// failure to diagnose: self-refresh takes the DRAM off the command bus
// entirely, so a read already issued but not yet returned never completes.
// The host waits forever on a response that no longer has any machinery behind
// it -- no error, no log entry, no timeout anywhere in the controller.
//
// P-PM-3 is the anti-vacuity guard.  A power manager that simply never leaves
// ACTIVE satisfies every safety property here and saves no power at all, which
// is exactly the kind of "correct" that ships and then gets a bug report about
// battery life instead of about correctness.
// ---------------------------------------------------------------------------
module fv_pmgr
  import hbm4_pkg::*;
(
  input logic        clk,
  input logic        rst_n,
  input logic [15:0] cfg_pd_thresh,
  input logic [15:0] cfg_sr_thresh,
  input logic        cfg_lp_en,
  input logic        busy,
  input logic        req_pending,
  input logic        lp_ack
);

  logic       pd_req, sr_req, exit_req, clk_gate_en;
  logic [1:0] state;

  hbm4_pmgr dut (
    .clk (clk), .rst_n (rst_n),
    .cfg_pd_thresh (cfg_pd_thresh), .cfg_sr_thresh (cfg_sr_thresh),
    .cfg_lp_en (cfg_lp_en),
    .busy (busy), .req_pending (req_pending),
    .pd_req (pd_req), .sr_req (sr_req), .lp_ack (lp_ack),
    .exit_req (exit_req), .state (state), .clk_gate_en (clk_gate_en)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-PM-1: never in a low-power state while work is outstanding ------
  // The hang property.  Checked one cycle AFTER busy, because the response to
  // activity is a state change, not a combinational output.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && ($past(busy) || $past(req_pending)))
      p_active_when_busy: assert (state == 2'd0);

  // Self-refresh gets its own statement, about ENTERING rather than being in.
  //
  // Written combinationally as `sr_req -> !busy` it fails, and correctly so:
  // the free environment can raise busy while already in SR.  The real system
  // cannot reach that -- work can only become outstanding by being issued, and
  // nothing issues from self-refresh -- but assuming it away here would be
  // circular.  The transition form needs no assumption and says what actually
  // matters: the deep state is never ENTERED with work in flight.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && (state == 2'd3) && ($past(state) != 2'd3))
      p_sr_entered_idle: assert (!$past(busy) && !$past(req_pending));

  // ---- P-PM-2: the descent is monotone, one step at a time ---------------
  // Skipping straight to self-refresh would bypass the PD handshake the PHY
  // expects, and the DRAM would be commanded into a state it was never
  // prepared for.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && (state > $past(state)))
      p_one_step_down: assert (state == $past(state) + 2'd1);

  // ---- P-PM-3: low power is disabled when it is disabled ----------------
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && !$past(cfg_lp_en) && (state > $past(state)))
      p_no_descend_when_disabled: assert (1'b0);

  // ---- P-PM-4: an arriving request always asks for exit -------------------
  always @(*)
    if (f_past_valid && rst_n && req_pending && (state != 2'd0))
      p_exit_requested: assert (exit_req);

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_clkgate : cover (state == 2'd1);
    c_pd      : cover (state == 2'd2);
    c_sr      : cover (state == 2'd3);        // the deep state must be reachable
    c_wake    : cover (exit_req);
    c_return  : cover ((state == 2'd0) && $past(state != 2'd0));
  end

endmodule
