// ---------------------------------------------------------------------------
// hbm4_col_arb -- column command arbiter.  Pipeline stage S1.  THE critical
// cycle of the entire design.
//
// tCCD_S is 1.0 ns, which is one core clock, which is one 32 B burst.  So the
// column port is one command wide and it is saturated in steady state: every
// cycle this block fails to issue is 32 bytes that can never be recovered.
// Across 256 pseudo-channels, idling 5% of cycles costs 400 GB/s.
//
// Which is why it is a masked priority encoder over a bit vector and nothing
// else.  All arithmetic happened one stage upstream in hbm4_timing_engine.
//
// Priority tiers (highest first):
//   0  urgent QoS
//   1  anything ready
// then round-robin within the winning tier.
//
// REMOVED IN REV 0.5 -- the bank-group bias tier.
//
// Earlier revisions had a third tier preferring a different bank group from
// the last issue.  It was redundant: hbm4_timing_engine loads t_ccdl[g] with
// tCCD_L on every column command, so banks in the just-used bank group are
// NOT MARKED READY until tCCD_L has elapsed.  Every candidate the arbiter can
// see therefore already satisfies tCCD_L, and the bias was choosing among
// options that were all equally legal.  This holds for any tCCD_L, not just
// the 2 x tCCD_S of the baseline device.
//
// It was not merely useless.  It could exclude a ready bank from the selected
// tier entirely, so the rotating pointer swept past without granting -- which
// destroyed the round-robin starvation bound and forced the fairness property
// to be withdrawn in Rev 0.4 (OPEN-1).  Deleting it:
//   - restores the N_BANK-1 bound, now proved (fv_col_arb p_bounded_starvation)
//   - removes the last_bg register
//   - drops one priority encoder from THE critical path of the design
//
// Enforcement of tCCD_L stays where it belongs, in the timing engine.
// ---------------------------------------------------------------------------
module hbm4_col_arb
  import hbm4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  dir_e              dir,             // from hbm4_dir_fsm
  input  logic [N_BANK-1:0] rd_ok,           // from hbm4_timing_engine
  input  logic [N_BANK-1:0] wr_ok,
  input  logic [N_BANK-1:0] pend_rd,         // bank has a ready read  candidate
  input  logic [N_BANK-1:0] pend_wr,         // bank has a ready write candidate
  input  logic [N_BANK-1:0] pend_urgent,     // that candidate is QoS urgent

  output logic [N_BANK-1:0] grant,           // one-hot
  output logic              grant_valid,
  output bank_t             grant_bank
);

  localparam int unsigned PW = (N_BANK > 1) ? $clog2(N_BANK) : 1;

  // ---- candidate set -------------------------------------------------------
  logic [N_BANK-1:0] cand;
  assign cand = (dir == DIR_READ) ? (rd_ok & pend_rd) : (wr_ok & pend_wr);

  // ---- tier select ---------------------------------------------------------
  logic [N_BANK-1:0] t0, sel;
  assign t0 = cand & pend_urgent;

  // Two tiers, one mux.  Note that QoS urgency sitting above round-robin means
  // this block alone gives no fairness guarantee against a sustained urgent
  // stream -- that is bounded by QoS AGING in the transaction pool, which
  // promotes a waiting entry to urgent so it rejoins the rotation.
  assign sel = (|t0) ? t0 : cand;

  // ---- round robin ---------------------------------------------------------
  logic [PW-1:0] ptr;

  hbm4_rr_arb #(.N(N_BANK)) u_rr (
    .req   (sel),
    .ptr   (ptr),
    .grant (grant),
    .valid (grant_valid)
  );

  always_comb begin
    grant_bank = '0;
    for (int unsigned b = 0; b < N_BANK; b++)
      if (grant[b]) grant_bank = bank_t'(b);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ptr <= '0;
    end else if (grant_valid) begin
      // Advance past the winner so it goes to the back of the rotation.  This
      // is what makes the rotational distance from ptr to any un-granted
      // persistent candidate strictly decrease on every grant, which is the
      // whole starvation argument.
      ptr <= (grant_bank == bank_t'(N_BANK-1)) ? '0 : PW'(grant_bank + 1'b1);
    end
  end

`ifdef FORMAL
  always_comb begin
    // C1: never more than one column command per core clock.
    a_at_most_one:   assert ($countones(grant) <= 1);
    // Never grant a bank the timing engine did not mark ready in this direction.
    a_only_ready:    assert ((grant & ~cand) == '0);
    a_valid_iff_cand: assert (grant_valid == (|cand));
  end
`endif

endmodule
