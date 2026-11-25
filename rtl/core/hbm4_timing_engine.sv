// ---------------------------------------------------------------------------
// hbm4_timing_engine -- DRAM timing tracking and ready-vector generation.
//
// This is pipeline stage S0.  It is the block that makes the whole design
// legal, and the block that formal verification exists for: a timing violation
// is not a functional bug you find in the lab, it is data corruption that
// depends on temperature, voltage and traffic phase.
//
// Two ideas do all the work:
//
// 1. COLLAPSED COUNTERS.  The naive implementation is one counter per JEDEC
//    parameter per bank -- ~20 x 32 = 640 per pseudo-channel, 164k system-wide.
//    Instead each counter holds "cycles until this COMMAND CLASS is legal on
//    this bank", and every parameter that gates that class loads it with a
//    max().  Three per bank, plus a handful shared.  ~720 flops per PC.
//
// 2. READY IS COMPUTED ONE CYCLE AHEAD.  The arbiter (S1) must decide
//    combinationally from a bit mask -- if it also had to evaluate counter
//    comparisons, the critical path would be
//        compare -> mask -> priority encode -> command mux
//    which does not close at 1 GHz.  So this block computes the counters'
//    NEXT values (including this cycle's loads) and registers the resulting
//    ready vectors.  What S1 sees is always exactly correct for the cycle it
//    is used in -- the "speculation" costs nothing in accuracy.
//
// Turnaround note: t_rtw / t_wtr_s / t_wtr_l are COMMAND-TO-COMMAND values,
// precomputed by firmware to already include CL/CWL and the burst.  Keeping
// that arithmetic in firmware is what lets DVFS be a register swap.
// ---------------------------------------------------------------------------
module hbm4_timing_engine
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input  logic             clk,
  input  logic             rst_n,

  // Not every tcfg field is consumed here: CL/CWL are already folded into the
  // firmware-computed turnaround values, tRFCab/tREFI belong to the refresh
  // engine.  Likewise this block needs only the bank and opcode of an issue --
  // row and column addresses do not affect timing.
  /* verilator lint_off UNUSEDSIGNAL */
  input  timing_cfg_t      tcfg,
  input  row_issue_t       row_iss,
  input  col_issue_t       col_iss,
  /* verilator lint_on UNUSEDSIGNAL */

  // refresh engine holds a bank out of service for tRFC
  input  logic [N_BANK-1:0] refresh_block,

  // ready vectors, registered, valid for the NEXT cycle
  output logic [N_BANK-1:0] act_ok,
  output logic [N_BANK-1:0] pre_ok,
  output logic [N_BANK-1:0] rd_ok,
  output logic [N_BANK-1:0] wr_ok
);

  // ---- helper: saturating down-counter with max-load -----------------------
  // A later event must never SHORTEN an outstanding restriction, hence max().
  function automatic tmr_t tick(input tmr_t cur, input logic load, input tmr_t val);
    tmr_t dec;
    dec = (cur == '0) ? '0 : tmr_t'(cur - 1'b1);
    return (load && (val > dec)) ? val : dec;
  endfunction

  // Convert a JEDEC parameter into the value this counter must be LOADED with.
  //
  // Subtle and worth spelling out.  A parameter of N means "the next command
  // is legal N cycles after this one".  The counter is loaded during the event
  // cycle itself, and readiness is registered one cycle ahead (see the header),
  // so the load value is N-1.
  //
  //   tCCD_S = 1, loaded as 0  ->  n_ccds == 0 in the issue cycle
  //                            ->  ready registers high for the NEXT cycle
  //                            ->  a column command every cycle.  This is C1.
  //
  // Loading N instead of N-1 costs exactly one cycle per event.  At tCCD_S = 1
  // that halves column throughput -- 50% of peak bandwidth -- while never
  // violating a timing parameter, so it is invisible to a timing checker and
  // shows up only as missing performance.
  function automatic tmr_t ld(input tmr_t v);
    return (v == '0) ? '0 : tmr_t'(v - 1'b1);
  endfunction

  // ---- state ---------------------------------------------------------------
  tmr_t t_act  [N_BANK];   // until ACT legal   (tRP, tRC, tRFC, tRFM)
  tmr_t t_col  [N_BANK];   // until RD/WR legal (tRCD)
  tmr_t t_pre  [N_BANK];   // until PRE legal   (tRAS, tRTP, tWR)
  tmr_t t_ccdl [N_BG];     // tCCD_L, per bank group
  tmr_t t_rrdl [N_BG];     // tRRD_L, per bank group
  tmr_t t_wtrl [N_BG];     // tWTR_L, per bank group
  tmr_t t_ccds, t_rrds, t_wtrs, t_rtw;
  tmr_t t_faw  [4];        // four-activate window

  tmr_t n_act  [N_BANK];
  tmr_t n_col  [N_BANK];
  tmr_t n_pre  [N_BANK];
  tmr_t n_ccdl [N_BG];
  tmr_t n_rrdl [N_BG];
  tmr_t n_wtrl [N_BG];
  tmr_t n_ccds, n_rrds, n_wtrs, n_rtw;
  tmr_t n_faw  [4];

  // ---- decode this cycle's issue ------------------------------------------
  logic do_act, do_pre, do_ref, do_rfm, do_rd, do_wr, do_col;
  logic do_rda, do_wra, do_ap;
  bg_t  row_bg, col_bg;

  always_comb begin
    do_act = row_iss.valid && (row_iss.cmd == ROW_ACT);
    do_pre = row_iss.valid && ((row_iss.cmd == ROW_PRE) || (row_iss.cmd == ROW_PREA));
    do_ref = row_iss.valid && ((row_iss.cmd == ROW_REF_SB) || (row_iss.cmd == ROW_REF_AB));
    do_rfm = row_iss.valid && (row_iss.cmd == ROW_RFM);
    do_rd  = col_iss.valid && ((col_iss.cmd == COL_RD) || (col_iss.cmd == COL_RDA));
    do_wr  = col_iss.valid && ((col_iss.cmd == COL_WR) || (col_iss.cmd == COL_WRA));
    do_col = do_rd || do_wr;
    // Auto-precharge: the bank closes by itself after the burst.  No row
    // command is ever issued, so if this is not tracked here NOTHING enforces
    // tRP before the next ACT -- and PAGE_POLICY = CLOSE issues RDA/WRA on
    // every single access.
    do_rda = col_iss.valid && (col_iss.cmd == COL_RDA);
    do_wra = col_iss.valid && (col_iss.cmd == COL_WRA);
    do_ap  = do_rda || do_wra;
    row_bg = bg_of(row_iss.bank);
    col_bg = bg_of(col_iss.bank);
  end

  // tFAW: allocate the first expired slot.  ACT is illegal when all four are
  // still counting, which is exactly "4 activates already in this window".
  logic [3:0] faw_free, faw_pick;
  always_comb begin
    for (int unsigned i = 0; i < 4; i++) faw_free[i] = (t_faw[i] == '0);
    faw_pick = faw_free & (~faw_free + 4'd1);   // lowest free slot, one-hot
  end

  // ---- next-state ----------------------------------------------------------
  always_comb begin
    for (int unsigned b = 0; b < N_BANK; b++) begin
      logic hit, aphit;
      tmr_t row_val, ap_val, n_act_row;
      hit   = (bank_t'(b) == row_iss.bank);
      aphit = do_ap && (bank_t'(b) == col_iss.bank);

      // ACT is gated by whichever of tRP / tRC / tRFC / tRFM is longest
      // The row bus and the column bus can BOTH constrain the same bank in the
      // same cycle -- a PRE on the row bus and an auto-precharging RDA on the
      // column bus, for instance.  These must combine as a MAX, not as a
      // priority chain: a chain silently drops whichever constraint loses, and
      // since t_rda (tRTP+tRP) is longer than t_rp, the dropped one is the
      // binding one.  Found by formal (p_trda) -- the first version of this fix
      // had exactly that bug.
      row_val = (do_act) ? ld(tcfg.t_rc)     :
                (do_pre) ? ld(tcfg.t_rp)     :
                (do_ref) ? ld(tcfg.t_rfc_sb) : ld(tcfg.t_rfm);
      ap_val  = do_rda ? ld(tcfg.t_rda) : ld(tcfg.t_wra);

      n_act_row = tick(t_act[b],
                       hit && (do_pre || do_act || do_ref || do_rfm),
                       row_val);
      n_act[b]  = (aphit && (ap_val > n_act_row)) ? ap_val : n_act_row;

      n_col[b] = tick(t_col[b], hit && do_act, ld(tcfg.t_rcd));

      // PRE waits for tRAS from the ACT, tRTP from a read, tWR from a write
      n_pre[b] = tick(t_pre[b],
                      (hit && do_act) ||
                      (col_iss.valid && (bank_t'(b) == col_iss.bank) && (do_rd || do_wr)),
                      (hit && do_act) ? ld(tcfg.t_ras) :
                      do_rd           ? ld(tcfg.t_rtp) : ld(tcfg.t_wr));
    end

    for (int unsigned g = 0; g < N_BG; g++) begin
      n_ccdl[g] = tick(t_ccdl[g], do_col && (bg_t'(g) == col_bg), ld(tcfg.t_ccd_l));
      n_rrdl[g] = tick(t_rrdl[g], do_act && (bg_t'(g) == row_bg), ld(tcfg.t_rrd_l));
      n_wtrl[g] = tick(t_wtrl[g], do_wr  && (bg_t'(g) == col_bg), ld(tcfg.t_wtr_l));
    end

    n_ccds = tick(t_ccds, do_col, ld(tcfg.t_ccd_s));
    n_rrds = tick(t_rrds, do_act, ld(tcfg.t_rrd_s));
    n_wtrs = tick(t_wtrs, do_wr,  ld(tcfg.t_wtr_s));
    n_rtw  = tick(t_rtw,  do_rd,  ld(tcfg.t_rtw));

    for (int unsigned i = 0; i < 4; i++)
      n_faw[i] = tick(t_faw[i], do_act && faw_pick[i], ld(tcfg.t_faw));
  end

  // ---- ready vectors for cycle N+1 ----------------------------------------
  logic n_faw_ok;
  always_comb begin
    n_faw_ok = 1'b0;
    for (int unsigned i = 0; i < 4; i++) if (n_faw[i] == '0) n_faw_ok = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned b = 0; b < N_BANK; b++) begin
        t_act[b] <= '0; t_col[b] <= '0; t_pre[b] <= '0;
      end
      for (int unsigned g = 0; g < N_BG; g++) begin
        t_ccdl[g] <= '0; t_rrdl[g] <= '0; t_wtrl[g] <= '0;
      end
      for (int unsigned i = 0; i < 4; i++) t_faw[i] <= '0;
      t_ccds <= '0; t_rrds <= '0; t_wtrs <= '0; t_rtw <= '0;
      act_ok <= '0; pre_ok <= '0; rd_ok <= '0; wr_ok <= '0;
    end else begin
      for (int unsigned b = 0; b < N_BANK; b++) begin
        t_act[b] <= n_act[b]; t_col[b] <= n_col[b]; t_pre[b] <= n_pre[b];
      end
      for (int unsigned g = 0; g < N_BG; g++) begin
        t_ccdl[g] <= n_ccdl[g]; t_rrdl[g] <= n_rrdl[g]; t_wtrl[g] <= n_wtrl[g];
      end
      for (int unsigned i = 0; i < 4; i++) t_faw[i] <= n_faw[i];
      t_ccds <= n_ccds; t_rrds <= n_rrds; t_wtrs <= n_wtrs; t_rtw <= n_rtw;

      for (int unsigned b = 0; b < N_BANK; b++) begin
        automatic bg_t g = bg_of(bank_t'(b));
        act_ok[b] <= (n_act[b] == '0) && (n_rrdl[g] == '0) && (n_rrds == '0)
                     && n_faw_ok && !refresh_block[b];
        pre_ok[b] <= (n_pre[b] == '0) && !refresh_block[b];
        rd_ok [b] <= (n_col[b] == '0) && (n_ccdl[g] == '0) && (n_ccds == '0)
                     && (n_wtrs == '0) && (n_wtrl[g] == '0) && !refresh_block[b];
        wr_ok [b] <= (n_col[b] == '0) && (n_ccdl[g] == '0) && (n_ccds == '0)
                     && (n_rtw  == '0) && !refresh_block[b];
      end
    end
  end

endmodule
