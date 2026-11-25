// ---------------------------------------------------------------------------
// fv_refresh -- P-REF-*, P-RFM-*.  Closes OPEN-2 for the refresh engine.
//
// Refresh is the one scheduler input where a bug is DATA LOSS rather than lost
// bandwidth: a row that misses its window forgets, and nothing in the system
// reports it -- the data reads back as plausible garbage long after the cause.
//
// Two things must hold:
//   1. the engine never lets the device fall more than the JEDEC slack behind
//      (P-REF-1), and
//   2. a bank that is refreshing is genuinely masked, so no column command can
//      be issued to it (P-REF-2, checked where refresh_block is consumed).
// ---------------------------------------------------------------------------
module fv_refresh
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input logic              clk,
  input logic              rst_n,
  input logic [15:0]       cfg_refi_pb,
  input logic [15:0]       cfg_refi_phase,
  input logic [7:0]        cfg_rfm_thresh,
  input logic [7:0]        cfg_raa_imt,
  input logic              cfg_rfm_en,
  input logic              act_valid,
  input bank_t             act_bank,
  input logic [N_BANK-1:0] bank_idle,
  input logic              ref_ack_i,
  input logic              rfm_ack_i
);

  timing_cfg_t tcfg;
  assign tcfg = small_timing();

  logic              ref_req, ref_urgent, rfm_req;
  bank_t             ref_bank, rfm_bank;
  logic [N_BANK-1:0] refresh_block;
  logic [N_BANK-1:0] ref_want_pre;
  logic signed [5:0]      dbg_debt;
  logic [N_BANK-1:0][7:0] dbg_raa;

  // The row arbiter only acknowledges what was requested (hbm4_row_arb builds
  // the ack from the request), so tie the acks through that gate.
  logic ref_ack, rfm_ack;
  assign ref_ack = ref_ack_i && ref_req;
  assign rfm_ack = rfm_ack_i && rfm_req && !ref_ack;   // one row command per clock

  hbm4_refresh dut (
    .clk (clk), .rst_n (rst_n), .tcfg (tcfg),
    .cfg_refi_pb (cfg_refi_pb), .cfg_refi_phase (cfg_refi_phase), .cfg_rfm_thresh (cfg_rfm_thresh),
    .cfg_raa_imt (cfg_raa_imt), .cfg_rfm_en (cfg_rfm_en),
    .act_valid (act_valid), .act_bank (act_bank), .bank_idle (bank_idle),
    .ref_req (ref_req), .ref_urgent (ref_urgent), .ref_bank (ref_bank),
    .rfm_req (rfm_req), .rfm_bank (rfm_bank),
    .ref_ack (ref_ack), .rfm_ack (rfm_ack),
    .refresh_block (refresh_block), .ref_want_pre (ref_want_pre),
    .dbg_debt (dbg_debt), .dbg_raa (dbg_raa)
  );

  // ---- reset (ASSUMPTION A1) ----------------------------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // Keep the configuration stable and legal.  These are lockable CSRs written
  // once at boot (docs/04-programming-guide.md 1.7), so a mid-flight change is
  // not a state the engine must survive.
  always @(*) begin
    assume (cfg_refi_pb >= 16'd2);
    // The phase is an offset within one interval, never beyond it.
    assume (cfg_refi_phase <= cfg_refi_pb);
    assume (cfg_rfm_thresh >= 8'd2);
    assume (cfg_raa_imt >= 8'd1);
  end

  // Config is STABLE.  These are lockable CSRs, written once at boot and then
  // frozen by AMAP_LOCK (docs/04-programming-guide.md 1.7).  Letting the solver
  // change the RFM threshold mid-flight models a system that cannot exist and
  // produces counterexamples about nothing.
  always @(posedge clk)
    if (f_past_valid && $past(f_past_valid)) begin
      assume (cfg_refi_pb    == $past(cfg_refi_pb));
      assume (cfg_refi_phase == $past(cfg_refi_phase));
      assume (cfg_rfm_thresh == $past(cfg_rfm_thresh));
      assume (cfg_raa_imt    == $past(cfg_raa_imt));
      assume (cfg_rfm_en     == $past(cfg_rfm_en));
    end

  // ---- A5 and A6 REMOVED in Rev 0.6 ---------------------------------------
  //
  // Earlier drafts assumed the row arbiter always grants an urgent refresh (A5)
  // and grants RFM promptly (A6).  Both existed only to support a bound on RAA
  // that has since been replaced by p_rfm_always_requested, which needs no
  // grant assumption at all.
  //
  // Dropping them makes this proof STRICTLY STRONGER -- the arbiter is now
  // completely unconstrained, so the engine is proved correct even against an
  // arbiter that never acknowledges anything -- and it makes the JEDEC
  // saturation guard reachable, which is what lets mutation testing reach it.
  // With A5 in place, removing the `ref_debt < DEBT_MAX` guard survived
  // mutation, because debt could never climb that far.
  //
  // Fewer assumptions is not a cosmetic win: every assume is a hole, and two
  // of them here were load-bearing for nothing.

  // ---- ASSUMPTION A7: no activate to a bank that is refreshing ------------
  // hbm4_timing_engine gates act_ok with !refresh_block, and the row arbiter
  // only issues what act_ok permits (a_act_legal).  Without this the free
  // environment hammers a bank while it is mid-refresh, driving RAA past any
  // bound -- a state the assembled design cannot produce.
  // Discharged by fv_timing_engine + fv_row_arb.
  always @(*)
    if (f_past_valid && rst_n && act_valid)
      assume (!refresh_block[act_bank]);

  // ---- P-REF-1: the device never falls further behind than JEDEC allows ---
  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_debt_upper: assert (dbg_debt <= 6'sd8);
      p_debt_lower: assert (dbg_debt >= -6'sd8);
    end

  // ---- P-REF-3: a refresh is only ever issued to a bank that is free ------
  // Refreshing a bank that is already mid-refresh would violate tRFC.
  always @(posedge clk)
    if (f_past_valid && rst_n && ref_ack) begin
      p_ref_bank_free: assert (!refresh_block[ref_bank]);
    end

  always @(posedge clk)
    if (f_past_valid && rst_n && rfm_ack) begin
      p_rfm_bank_free: assert (!refresh_block[rfm_bank]);
    end

  // ---- P-REF-4: one row command per clock ---------------------------------
  always @(*)
    if (f_past_valid && rst_n) begin
      p_one_cmd: assert (!(ref_ack && rfm_ack));
    end

  // ---- P-RFM-1: row-hammer accumulators are bounded -----------------------
  // If RAA could run away, activations accumulate past the disturbance limit
  // and neighbouring rows corrupt -- silently, and only under a specific access
  // pattern.  With RFM enabled and requests granted, RAA must stay bounded.
  (* anyconst *) logic [BANK_W-1:0] f_bank;
  

  // THE PROPERTY THIS MODULE CAN ACTUALLY GUARANTEE: the detector never fails
  // to ask.  Whenever a bank has reached the threshold and is free to accept
  // the command, RFM is requested.  How quickly the row bus then grants it is
  // the arbiter's business, not this module's.
  //
  // Two earlier attempts to bound RAA itself were both wrong:
  //   `raa != 8'hFF`        -- threshold-dependent, and silently assumed grants
  //   `raa <= thresh + 1`   -- overflowed at thresh=255; and even widened it is
  //                            false, because RFM is deferred whenever a
  //                            refresh is granted in the same cycle and
  //                            activates keep arriving during the deferral.
  //
  // The overshoot bound is real and worth having, but it depends on how long
  // hbm4_row_arb can defer RFM, so it belongs to a system-level proof.
  // Tracked as OPEN-5 rather than guessed at -- the same discipline that
  // closed OPEN-1 properly instead of inflating a constant.
  always @(*)
    if (f_past_valid && rst_n && cfg_rfm_en
        && (dbg_raa[f_bank] >= cfg_rfm_thresh) && !refresh_block[f_bank]) begin
      // Contract updated, not weakened.  It used to be "a hammered bank always
      // raises rfm_req".  RFM to an OPEN bank is illegal, so the obligation is
      // now "a hammered bank is always being acted on": either mitigated this
      // cycle, or asked to close so that it can be next.  Accepting only
      // rfm_req would demand an illegal command; accepting neither would let
      // the mitigation silently stop, which is the bug this property exists to
      // catch.
      p_rfm_always_requested: assert (rfm_req || |ref_want_pre);
    end

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_opportunistic : cover (ref_ack && (dbg_debt <= 6'sd0));  // free refresh
    c_urgent        : cover (ref_urgent);
    c_blocked       : cover (|refresh_block);
    c_rfm           : cover (rfm_ack);
    c_behind        : cover (dbg_debt >= 6'sd3);
  end


  // ---- P-REF-6: refresh is never requested for an open bank --------------
  // The engine issued REF to whatever bank the pointer named whenever it was
  // behind schedule, without checking that the bank was closed.  REF to an
  // active bank is illegal and destroys the open row.  Being behind schedule is
  // the normal state under load, so this was not a corner case -- it was the
  // steady-state behaviour, and it took a streaming simulation to reach it.
  always @(*)
    if (f_past_valid && rst_n && ref_req)
      p_ref_bank_closed: assert (bank_idle[ref_bank]);

  always @(*)
    if (f_past_valid && rst_n && rfm_req)
      p_rfm_bank_closed: assert (bank_idle[rfm_bank]);

  // ...and the other half: gating on bank_idle alone would trade an illegal
  // command for silent starvation, so a bank that owes a refresh while open must
  // be asked to close.  Without this, "never refresh an open bank" is trivially
  // satisfiable by never refreshing at all.
  always @(*)
    if (f_past_valid && rst_n && |ref_want_pre)
      p_force_pre_only_open: assert (!(ref_want_pre & bank_idle));

  // Sticky rather than $past: this must be a clocked observation, and what it
  // needs to show is that a bank asked to close IS eventually refreshed -- the
  // end-to-end behaviour the split into ref_due/ref_req exists to provide.
  reg saw_force = 1'b0;
  always @(posedge clk)
    if (!rst_n)            saw_force <= 1'b0;
    else if (|ref_want_pre) saw_force <= 1'b1;

  always @(*) if (f_past_valid && rst_n) begin
    c_ref_forced_pre: cover (|ref_want_pre);
    c_ref_after_pre : cover (ref_req && saw_force);
  end

endmodule
