// ---------------------------------------------------------------------------
// fv_col_arb -- P-BUS-1, P-LIVE-1.
//
// Discharges the assumption that fv_timing_engine makes: that the arbiter only
// ever issues what the ready vectors permit.  An `assume` in one proof must be
// an `assert` in another, or it is just a wish (see ASSUMPTIONS.md).
//
// Also proves the starvation bound.  Livelock in a streaming scheduler is
// exactly the bug class that survives simulation: the machine keeps running,
// throughput looks plausible, and one requester quietly never advances.
// ---------------------------------------------------------------------------
module fv_col_arb
  import hbm4_pkg::*;
(
  input logic              clk,
  input logic              rst_n,
  input dir_e              dir,
  input logic [N_BANK-1:0] rd_ok,
  input logic [N_BANK-1:0] wr_ok,
  input logic [N_BANK-1:0] pend_rd,
  input logic [N_BANK-1:0] pend_wr,
  input logic [N_BANK-1:0] pend_urgent
);

  logic [N_BANK-1:0] grant;
  logic              grant_valid;
  bank_t             grant_bank;

  hbm4_col_arb dut (
    .clk (clk), .rst_n (rst_n), .dir (dir),
    .rd_ok (rd_ok), .wr_ok (wr_ok),
    .pend_rd (pend_rd), .pend_wr (pend_wr), .pend_urgent (pend_urgent),
    .grant (grant), .grant_valid (grant_valid), .grant_bank (grant_bank)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  logic [N_BANK-1:0] cand;
  assign cand = (dir == DIR_READ) ? (rd_ok & pend_rd) : (wr_ok & pend_wr);

  // ---- P-BUS-1: constraint C1, one column command per core clock ----------
  always @(*) begin
    p_at_most_one : assert ($countones(grant) <= 1);
    p_only_ready  : assert ((grant & ~cand) == '0);
    p_valid_iff   : assert (grant_valid == (|cand));
    p_bank_matches: assert (!grant_valid || grant[grant_bank]);

    // P-QOS-1: the urgent tier is actually honoured.  If any candidate is
    // urgent, the grant must go to an urgent one.  Without this, deleting the
    // tier entirely survives mutation testing -- the safety properties are all
    // still satisfied by a plain round-robin that ignores QoS completely.
    p_urgent_preferred: assert (!grant_valid || !(|(cand & pend_urgent))
                                || pend_urgent[grant_bank]);
  end

  // ---- P-LIVE-1: bounded starvation, WITHIN the round-robin tier ----------
  //
  // What this module does NOT guarantee, and must not be asserted here:
  //   QoS-urgent candidates sit ABOVE round-robin (tiers 0 and 1 of
  //   hbm4_col_arb).  A continuous stream of urgent traffic can therefore
  //   starve a non-urgent bank indefinitely, at this module's boundary.
  //   That is not a bug -- it is bounded by QoS AGING in the transaction pool,
  //   which promotes a waiting entry to urgent after AGE_TICK cycles, at which
  //   point it rejoins round-robin (docs/02-architecture.md 8.7).  The bound
  //   therefore belongs to a pool-level proof (P-LIVE-4), not to this one.
  //   Asserting it here failed, correctly, and the first version of this file
  //   claimed a guarantee the arbiter does not make.
  //
  // What IS proved here: absent urgent traffic, the rotating pointer reaches
  // every continuously-ready bank promptly.  The bound is 2*N_BANK rather than
  // N_BANK because the bank-group bias (tier 2) can defer a bank for one extra
  // rotation -- and only one, since granting a different group flips last_bg
  // and moves the deferred bank INTO the preferred tier.
  (* anyconst *) logic [BANK_W-1:0] f_bank;

  logic [7:0] starve;
  logic       urgent_present;
  assign urgent_present = |(cand & pend_urgent);

  // ---- ASSUMPTION A3: requests are persistent ------------------------------
  // A candidate stays a candidate until it is granted.  This is true by
  // construction -- a candidate is the head of a per-bank list in the
  // transaction pool, and a queued transaction does not evaporate.
  //
  // It is also NECESSARY.  With cand free every cycle the solver simply
  // withdraws f_bank's candidacy whenever the pointer is about to reach it and
  // re-adds it after, defeating any bound.  That counterexample says nothing
  // about the arbiter; it says the environment was under-constrained.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(cand[f_bank]) && !$past(grant[f_bank]))
      assume (cand[f_bank]);

  always @(posedge clk) begin
    if (!rst_n)                  starve <= '0;
    else if (!cand[f_bank])      starve <= '0;  // not asking
    else if (grant[f_bank])      starve <= '0;  // served
    // An urgent-driven grant selects from the urgent tier, so the granted bank
    // need NOT lie between ptr and f_bank -- the pointer can jump past f_bank
    // and the rotational-distance argument is broken.  The counter therefore
    // measures a run of CONSECUTIVE non-urgent grants.  (Rev 0.5: the first
    // version accumulated across urgent phases, which conflated two regimes
    // and reported a bound the arbiter never claimed.)
    else if (urgent_present)     starve <= '0;
    else if (grant_valid)        starve <= starve + 8'd1;
  end

  // ---- P-LIVE-1: the starvation bound, RESTORED in Rev 0.5 ----------------
  //
  // Rev 0.4 had to disable this.  The bank-group bias tier could exclude a
  // ready bank from the selected tier, so the rotating pointer swept past it
  // without granting, and BMC found pass-overs beyond 4*N_BANK.
  //
  // Rev 0.5 deleted that tier: it was redundant with the timing engine, which
  // does not mark a bank ready until tCCD_L has elapsed, so every candidate
  // the arbiter can see is already legal (see the hbm4_col_arb header).
  //
  // With sel == cand the argument is simple again.  A grant either serves
  // f_bank, or serves a bank lying strictly between ptr and f_bank in the
  // rotation -- after which ptr advances past it, so the rotational distance
  // from ptr to f_bank STRICTLY DECREASES.  That distance is at most N_BANK-1,
  // so f_bank is served within N_BANK-1 grants.
  //
  // Fixing the design rather than weakening the property was the right call:
  // it removed logic, removed a register, and shortened the critical path.
  always @(posedge clk)
    if (f_past_valid && rst_n)
      p_bounded_starvation: assert (starve < 8'(N_BANK));


  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_grants        : cover (grant_valid);
    c_urgent_wins   : cover (grant_valid && pend_urgent[grant_bank]);
    c_passed_over   : cover (starve > 8'd0);
    c_back_to_back  : cover (grant_valid && $past(grant_valid));
  end

endmodule
