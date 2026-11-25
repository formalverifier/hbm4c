// ---------------------------------------------------------------------------
// hbm4_pmgr -- power state management for one pseudo-channel group.
//
// Four states, in increasing depth and increasing exit cost:
//
//   ACTIVE  -> CLKGATE   controller clock gated,  ~1 clock to exit
//           -> POWERDOWN DRAM in PD,              ~tXP
//           -> SELFREF   DRAM in SR,              ~tXS (microseconds)
//
// THE SAFETY PROPERTY (P-PM-1) is that a deeper state is never entered while
// any transaction is outstanding.  Self-refresh in particular takes the DRAM
// off the command bus entirely: a read issued but not yet returned simply never
// completes, and the host waits forever on a response that no longer has any
// machinery behind it.  That is a hang with no error and no log entry.
//
// Refresh keeps running in SR -- the DRAM refreshes itself, which is the point
// of the state -- so data is safe.  What is not safe is IN-FLIGHT WORK.
// ---------------------------------------------------------------------------
module hbm4_pmgr
  import hbm4_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,

  input  logic [15:0] cfg_pd_thresh,      // idle clocks before power-down
  input  logic [15:0] cfg_sr_thresh,      // idle clocks before self-refresh
  input  logic        cfg_lp_en,

  // ---- activity ------------------------------------------------------------
  input  logic        busy,               // any transaction outstanding
  input  logic        req_pending,        // new work has arrived

  // ---- DRAM low-power handshake -------------------------------------------
  output logic        pd_req,
  output logic        sr_req,
  input  logic        lp_ack,             // PHY/DRAM entered the requested state
  output logic        exit_req,

  output logic [1:0]  state,              // 0 ACTIVE 1 CLKGATE 2 PD 3 SR
  output logic        clk_gate_en
);

  typedef enum logic [1:0] {
    S_ACTIVE = 2'd0, S_CLKGATE = 2'd1, S_PD = 2'd2, S_SR = 2'd3
  } st_e;

  st_e         st;
  logic [15:0] idle_cnt;

  assign state       = st;
  assign clk_gate_en = (st != S_ACTIVE);
  assign pd_req      = (st == S_PD);
  assign sr_req      = (st == S_SR);
  assign exit_req    = req_pending && (st != S_ACTIVE);

  // Deeper states are only ever entered from an idle controller.  The busy
  // gating lives in ONE place -- the activity branch below, which unconditionally
  // returns to ACTIVE -- so this is just the enable.
  //
  // An earlier version also tested !busy && !req_pending here.  Mutation
  // testing showed removing that made no difference: the else-if can only run
  // when the activity branch did not, so the test was dead.  A redundant guard
  // is a maintenance hazard -- it reads as load-bearing, so a later edit to the
  // outer condition looks safe when it is not.
  logic may_descend;
  assign may_descend = cfg_lp_en;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st       <= S_ACTIVE;
      idle_cnt <= 16'd0;
    end else begin
      // Any activity resets the timer AND returns to ACTIVE.  There is no path
      // that stays in a low-power state while work is outstanding.
      if (busy || req_pending) begin
        idle_cnt <= 16'd0;
        st       <= S_ACTIVE;
      end else if (may_descend) begin
        if (idle_cnt != 16'hFFFF) idle_cnt <= idle_cnt + 16'd1;

        case (st)
          S_ACTIVE:  if (idle_cnt >= 16'd4)            st <= S_CLKGATE;
          S_CLKGATE: if (idle_cnt >= cfg_pd_thresh)    st <= S_PD;
          S_PD:      if ((idle_cnt >= cfg_sr_thresh) && lp_ack) st <= S_SR;
          default: ;                                   // S_SR is the floor
        endcase
      end
    end
  end

endmodule
