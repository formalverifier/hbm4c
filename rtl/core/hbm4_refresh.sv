// ---------------------------------------------------------------------------
// hbm4_refresh -- per-bank refresh engine, credit slack, and row-hammer (RFM).
//
// DRAM forgets.  Every row must be refreshed within tREFI or it loses charge,
// so refresh is the one scheduler input that is not about performance at all --
// missing it is data loss, not a slow cycle.
//
// PER-BANK (REFsb), not all-bank.  REFab stalls a whole pseudo-channel for
// tRFCab (~350 ns) -- 11 KB of lost bandwidth per event, ~9% overhead.  REFsb
// costs tRFCsb (~190 ns) but takes out 1 bank of 32 while the column stream
// keeps running on the other 31.  That is the difference between ~9% and ~3%
// (docs/02-architecture.md 9), and it is why refresh_block is a per-bank vector
// rather than a single stall.
//
// CREDIT SLACK.  JEDEC allows +/- 8 refreshes of drift, tracked in ref_debt:
//
//    debt < 0   ran ahead      -- issue only OPPORTUNISTICALLY, when the target
//                                 bank is already idle and the row bus is free.
//                                 These are effectively free refreshes.
//    0 .. 5     on schedule    -- normal priority in the row arbiter
//    >= 6       behind         -- URGENT: the row arbiter takes it
//                                 unconditionally and the column arbiter masks
//                                 the bank.  Correctness now outranks bandwidth.
//
// The opportunistic path is what turns 4.9% of raw bank capacity into ~2%: in
// steady state 31 of 32 banks are streaming and each goes briefly idle when its
// row is exhausted, so most refreshes land in a window that cost nothing.
//
// RFM / row hammer.  Repeatedly activating one row disturbs its neighbours.
// Per-bank RAA (Rolling Accumulated ACT) counters trigger a refresh-management
// command before the disturbance accumulates.  This is a DATA INTEGRITY
// mechanism, not a performance knob -- RFM_MODE is a lockable CSR.
// ---------------------------------------------------------------------------
module hbm4_refresh
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  // Only tRFCsb and tRFM are consumed here; the rest of the timing set belongs
  // to hbm4_timing_engine.
  /* verilator lint_off UNUSEDSIGNAL */
  input  timing_cfg_t       tcfg,
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- policy (CSR) --------------------------------------------------------
  input  logic [15:0]       cfg_refi_pb,     // tREFI / N_BANK, in core clocks
  // Per-pseudo-channel phase offset, assigned by the supervisor as
  // (global_pc_index * tREFI) / N_PC_TOTAL.
  //
  // Without it every one of the 256 pseudo-channels resets its interval counter
  // to zero and they all refresh in LOCKSTEP -- a correlated current spike
  // across the whole package and a correlated bandwidth notch, both of which
  // docs/02-architecture.md 9.4 says the supervisor prevents.  It costs nothing
  // (a different reset value, not extra logic) and was simply missing.
  input  logic [15:0]       cfg_refi_phase,
  input  logic [7:0]        cfg_rfm_thresh,  // RAA level that triggers RFM
  input  logic [7:0]        cfg_raa_imt,     // RAA decrement per refresh
  input  logic              cfg_rfm_en,

  // ---- observed DRAM activity ---------------------------------------------
  input  logic              act_valid,
  input  bank_t             act_bank,
  input  logic [N_BANK-1:0] bank_idle,       // from hbm4_bank_state

  // ---- request / grant with the row arbiter -------------------------------
  output logic              ref_req,
  output logic              ref_urgent,
  output bank_t             ref_bank,
  output logic              rfm_req,
  output bank_t             rfm_bank,
  input  logic              ref_ack,
  input  logic              rfm_ack,

  // ---- gates every ready vector in hbm4_timing_engine ---------------------
  output logic [N_BANK-1:0] refresh_block,

  // Banks that owe a refresh (or RFM) but are still open.  The slice ORs this
  // into want_pre so the row arbiter closes them; without it, gating refresh on
  // bank_idle turns an illegality into a starvation.
  output logic [N_BANK-1:0] ref_want_pre,

  // ---- observability -------------------------------------------------------
  output logic signed [5:0]                dbg_debt,
  output logic [N_BANK-1:0][7:0]           dbg_raa
);

  // Sized to match ref_debt so the comparisons below stay 6-bit signed rather
  // than promoting to 32-bit int.
  localparam logic signed [5:0] DEBT_MAX =  6'sd8;   // JEDEC postpone limit
  localparam logic signed [5:0] DEBT_MIN = -6'sd8;   // JEDEC pull-in limit

  // ---- refresh interval ----------------------------------------------------
  logic [15:0]       refi_cnt;
  logic              refi_tick;
  logic signed [5:0] ref_debt;
  bank_t             ref_ptr;

  assign refi_tick = (refi_cnt == 16'd0);

  // ---- per-bank refresh busy (tRFC) ---------------------------------------
  tmr_t rfc_cnt [N_BANK];

  always_comb
    for (int unsigned b = 0; b < N_BANK; b++)
      refresh_block[b] = (rfc_cnt[b] != '0);

  // ---- RAA counters --------------------------------------------------------
  logic [7:0] raa [N_BANK];

  logic       raa_hit;
  bank_t      raa_bank;
  // Select a hammered bank that is ALSO free to accept the command.
  //
  // Bug found by formal (p_rfm_always_requested): the first version selected
  // the hammered bank first and only then checked refresh_block on it.  A
  // hammered bank that happened to be mid-refresh therefore MASKED every other
  // hammered bank, and the RFM request never fired for any of them -- so
  // row-hammer mitigation silently stopped while the counters kept climbing.
  // Exactly the kind of defect that never shows up as a functional failure.
  always_comb begin
    raa_hit  = 1'b0;
    raa_bank = '0;
    for (int unsigned b = 0; b < N_BANK; b++)
      if ((raa[b] >= cfg_rfm_thresh) && !refresh_block[b]) begin
        raa_hit  = 1'b1;
        raa_bank = bank_t'(b);
      end
  end

  logic rfm_req_raw;
  assign rfm_req_raw = cfg_rfm_en && raa_hit;
  assign rfm_req     = rfm_req_raw && bank_idle[raa_bank];
  assign rfm_bank = raa_bank;

  // ---- refresh request -----------------------------------------------------
  assign ref_bank   = ref_ptr;
  assign ref_urgent = (ref_debt >= 6);

  // May issue while we have not already pulled in the full 8.  Below schedule
  // (debt <= 0) we only take a slot the bank was not using anyway -- that is
  // the whole opportunistic mechanism.
  // REFRESH REQUIRES A CLOSED BANK, and this is split into two signals because
  // one alone gets it wrong in opposite directions.
  //
  // The first version was a single term: `(ref_debt > 0) || bank_idle[ref_ptr]`.
  // Read it as "when behind schedule, refresh regardless of whether the bank is
  // open" -- and since being behind is the NORMAL state under sustained load,
  // that issued REF to open banks routinely.  REF to an active bank is illegal
  // in JEDEC and destroys the open row.  Found in simulation at cycle 32012 of a
  // streaming test; it cannot appear until the engine falls behind, which is why
  // no short test and no block proof reached it.
  //
  // Simply adding `&& bank_idle[ref_ptr]` fixes the legality and creates a
  // starvation bug in its place: a bank under continuous row hits never goes
  // idle, so its refresh is postponed forever and the data is lost anyway.
  //
  // So `ref_due` says "this bank owes a refresh" and drives a FORCED PRECHARGE
  // through ref_want_pre, while `ref_req` -- the thing that actually issues the
  // command -- waits for the bank to be closed.  The controller closes the bank
  // because it must, then refreshes it.
  logic ref_due;
  assign ref_due = (ref_debt > DEBT_MIN)
                && !refresh_block[ref_ptr]
                && ((ref_debt > 0) || bank_idle[ref_ptr]);

  assign ref_req = ref_due && bank_idle[ref_ptr];

  always_comb begin
    ref_want_pre = '0;
    if (ref_due && !bank_idle[ref_ptr]) ref_want_pre[ref_ptr] = 1'b1;
    // Same for RFM: a hammered bank that stays open would otherwise never get
    // its mitigation, which is the whole point of the mechanism.
    if (rfm_req_raw && !bank_idle[raa_bank]) ref_want_pre[raa_bank] = 1'b1;
  end

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      refi_cnt <= cfg_refi_phase;
      ref_debt <= '0;
      ref_ptr  <= '0;
      for (int unsigned b = 0; b < N_BANK; b++) begin
        rfc_cnt[b] <= '0;
        raa[b]     <= 8'd0;
      end
    end else begin
      // interval counter
      refi_cnt <= refi_tick ? cfg_refi_pb : (refi_cnt - 16'd1);

      // debt: +1 each interval, -1 each refresh issued.  Both can happen in the
      // same cycle, in which case they cancel.
      if (refi_tick && !ref_ack) begin
        if (ref_debt < DEBT_MAX) ref_debt <= ref_debt + 6'sd1;
      end else if (!refi_tick && ref_ack) begin
        if (ref_debt > DEBT_MIN) ref_debt <= ref_debt - 6'sd1;
      end

      if (ref_ack)
        ref_ptr <= (ref_ptr == bank_t'(N_BANK-1)) ? '0 : bank_t'(ref_ptr + 1'b1);

      // Per-bank state, written in ONE place per register with explicit
      // priority.  An earlier version loaded rfc_cnt on ack and then ran a
      // decrement loop afterwards, relying on last-assignment-wins to not
      // clobber the load.  That was correct only because ref_req is gated on
      // !refresh_block -- an implicit, non-local dependency that the next edit
      // to the request logic would silently break.
      for (int unsigned b = 0; b < N_BANK; b++) begin
        // --- refresh busy timer ---
        if (ref_ack && (ref_bank == bank_t'(b)))
          rfc_cnt[b] <= tcfg.t_rfc_sb;
        else if (rfm_ack && (rfm_bank == bank_t'(b)))
          rfc_cnt[b] <= tcfg.t_rfm;
        else if (rfc_cnt[b] != '0)
          rfc_cnt[b] <= rfc_cnt[b] - 1'b1;

        // --- row-hammer accumulator ---
        if (rfm_ack && (rfm_bank == bank_t'(b)))
          raa[b] <= 8'd0;
        else if (ref_ack && (ref_bank == bank_t'(b)))
          // a refresh also relieves accumulated activation stress
          raa[b] <= (raa[b] > cfg_raa_imt) ? (raa[b] - cfg_raa_imt) : 8'd0;
        else if (act_valid && (act_bank == bank_t'(b)) && (raa[b] != 8'hFF))
          raa[b] <= raa[b] + 8'd1;
      end
    end
  end

  assign dbg_debt = ref_debt;
  always_comb
    for (int unsigned b = 0; b < N_BANK; b++) dbg_raa[b] = raa[b];

endmodule
