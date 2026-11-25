// ---------------------------------------------------------------------------
// fv_timing_engine -- P-TIM-*, P-BUS-*.  The crown jewels.
//
// A DRAM timing violation is not a functional bug you find in the lab.  It is
// data corruption whose appearance depends on temperature, voltage and traffic
// phase.  Random simulation explores a vanishing fraction of the command
// orderings a real workload produces, so this must be PROVED.
//
// The decomposition:
//   here          -- IF the arbiters only ever issue what the ready vectors
//                    permit, THEN no JEDEC parameter is ever violated.
//   fv_col_arb    -- the arbiters only ever issue what the ready vectors
//                    permit  (a_only_ready, a_act_legal).
//
// Every shadow counter below is written independently of the DUT's own
// counters.  If the checker reused them, a bug in them would be invisible --
// the same reason tb/model/hbm4_timing_checker.sv is written from the
// datasheet by someone other than the RTL author.
// ---------------------------------------------------------------------------
module fv_timing_engine
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input logic       clk,
  input logic       rst_n,
  input row_issue_t row_iss,
  input col_issue_t col_iss
);

  localparam int unsigned SW = 12;                  // shadow counter width
  localparam tmr_t SAT = tmr_t'((1 << SW) - 1);

  timing_cfg_t tcfg;
  assign tcfg = small_timing();

  logic [N_BANK-1:0] act_ok, pre_ok, rd_ok, wr_ok;

  hbm4_timing_engine dut (
    .clk (clk), .rst_n (rst_n), .tcfg (tcfg),
    .row_iss (row_iss), .col_iss (col_iss),
    .refresh_block ('0),
    .act_ok (act_ok), .pre_ok (pre_ok), .rd_ok (rd_ok), .wr_ok (wr_ok)
  );

  // ---- reset (ASSUMPTION A1, see ASSUMPTIONS.md) ---------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- decode the issue ----------------------------------------------------
  logic do_act, do_pre, do_ref, do_rfm, do_rda, do_wra, do_rd, do_wr, do_col;
  bank_t rb, cb;
  bg_t   rg, cg;

  assign do_act = row_iss.valid && (row_iss.cmd == ROW_ACT);
  assign do_pre = row_iss.valid && (row_iss.cmd == ROW_PRE);
  assign do_ref = row_iss.valid && (row_iss.cmd == ROW_REF_SB);
  assign do_rfm = row_iss.valid && (row_iss.cmd == ROW_RFM);
  assign do_rda = col_iss.valid && (col_iss.cmd == COL_RDA);
  assign do_wra = col_iss.valid && (col_iss.cmd == COL_WRA);
  assign do_rd  = col_iss.valid && ((col_iss.cmd == COL_RD) || (col_iss.cmd == COL_RDA));
  assign do_wr  = col_iss.valid && ((col_iss.cmd == COL_WR) || (col_iss.cmd == COL_WRA));
  assign do_col = do_rd || do_wr;
  assign rb = row_iss.bank;  assign rg = bg_of(rb);
  assign cb = col_iss.bank;  assign cg = bg_of(cb);

  // ---- ASSUMPTION A2: the arbiters obey the ready vectors ------------------
  // This is the contract the arbiters are separately proved to honour.  It is
  // an assume HERE and an assert THERE -- never only an assume.
  always @(*) begin
    if (f_past_valid && rst_n) begin
      if (do_act) assume (act_ok[rb]);
      if (do_pre) assume (pre_ok[rb]);
      if (do_rd)  assume (rd_ok[cb]);
      if (do_wr)  assume (wr_ok[cb]);
      // Constraint C1: the column port is one command wide.  Structural in the
      // arbiter; assumed here because this block has no arbiter in it.
      assume (!(do_rd && do_wr));
      // FULL COMMAND SCOPE as of Rev 0.6d -- this is what closes OPEN-2.
      // Every command the scheduler can issue is now exercised, including RFM
      // and the auto-precharge variants.  Nothing is assumed away.
      assume (row_iss.valid -> (row_iss.cmd inside {ROW_ACT, ROW_PRE,
                                                    ROW_REF_SB, ROW_RFM}));
      assume (col_iss.valid -> (col_iss.cmd inside {COL_RD, COL_WR,
                                                    COL_RDA, COL_WRA}));
    end
  end

  // ---- independent shadow timers -------------------------------------------
  // "cycles since the last such event", saturating.
  tmr_t s_ref [N_BANK];   // since REFsb on this bank
  tmr_t s_rfm [N_BANK];   // since RFM   on this bank
  tmr_t s_rda [N_BANK];   // since an auto-precharging read  on this bank
  tmr_t s_wra [N_BANK];   // since an auto-precharging write on this bank
  tmr_t s_act [N_BANK];   // since ACT on this bank
  tmr_t s_pre [N_BANK];   // since PRE on this bank
  tmr_t s_colb[N_BANK];   // since a column command on this bank
  tmr_t s_colg[N_BG];     // since a column command in this bank group
  tmr_t s_actg[N_BG];     // since an ACT in this bank group
  tmr_t s_col, s_acta, s_rd, s_wr;

  // "Cycles elapsed since the event."  On the event cycle we load 1, NOT 0:
  // the register is read in the FOLLOWING cycle, by which time exactly one
  // cycle has elapsed.  Loading 0 makes back-to-back commands look like a
  // zero-cycle gap and fails tCCD_S = 1 spuriously -- which is precisely what
  // the first version of this checker did.
  function automatic tmr_t bump(input tmr_t v, input logic ev);
    return ev ? tmr_t'(1) : ((v == SAT) ? SAT : tmr_t'(v + 1'b1));
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned b = 0; b < N_BANK; b++) begin
        s_act[b] <= SAT; s_pre[b] <= SAT; s_colb[b] <= SAT; s_ref[b] <= SAT;
        s_rfm[b] <= SAT; s_rda[b] <= SAT; s_wra[b] <= SAT;
      end
      for (int unsigned g = 0; g < N_BG; g++) begin
        s_colg[g] <= SAT; s_actg[g] <= SAT;
      end
      s_col <= SAT; s_acta <= SAT; s_rd <= SAT; s_wr <= SAT;
    end else begin
      for (int unsigned b = 0; b < N_BANK; b++) begin
        s_act [b] <= bump(s_act [b], do_act && (rb == bank_t'(b)));
        s_ref [b] <= bump(s_ref [b], do_ref && (rb == bank_t'(b)));
        s_rfm [b] <= bump(s_rfm [b], do_rfm && (rb == bank_t'(b)));
        s_rda [b] <= bump(s_rda [b], do_rda && (cb == bank_t'(b)));
        s_wra [b] <= bump(s_wra [b], do_wra && (cb == bank_t'(b)));
        s_pre [b] <= bump(s_pre [b], do_pre && (rb == bank_t'(b)));
        s_colb[b] <= bump(s_colb[b], do_col && (cb == bank_t'(b)));
      end
      for (int unsigned g = 0; g < N_BG; g++) begin
        s_colg[g] <= bump(s_colg[g], do_col && (cg == bg_t'(g)));
        s_actg[g] <= bump(s_actg[g], do_act && (rg == bg_t'(g)));
      end
      s_col  <= bump(s_col,  do_col);
      s_acta <= bump(s_acta, do_act);
      s_rd   <= bump(s_rd,   do_rd);
      s_wr   <= bump(s_wr,   do_wr);
    end
  end

  // ---- P-TIM-*: no JEDEC parameter is ever violated ------------------------
  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      // P-TIM-14: tRFC.  A bank that is refreshing cannot be activated until
      // the refresh completes.  Note this is enforced by the timing engine's
      // own t_act counter, INDEPENDENTLY of the refresh_block vector -- which
      // makes refresh_block redundant protection rather than the mechanism.
      // That redundancy is deliberate and is why assumption A7 is safe.
      if (do_act) begin
        p_trfc  : assert (s_ref [rb]  >= tcfg.t_rfc_sb);
        // P-TIM-15: tRFM -- RFM takes the bank out of service like a refresh.
        p_trfm  : assert (s_rfm [rb]  >= tcfg.t_rfm);
        // P-TIM-16/17: AUTO-PRECHARGE.  RDA/WRA close the bank internally, with
        // NO row command to mark it, so nothing on the row bus records that a
        // precharge happened.  Before Rev 0.6d the timing engine did not track
        // this at all -- the next ACT was legal immediately, violating tRP on
        // every access under PAGE_POLICY = CLOSE.
        p_trda  : assert (s_rda [rb]  >= tcfg.t_rda);
        p_twra  : assert (s_wra [rb]  >= tcfg.t_wra);
        p_trp   : assert (s_pre [rb]  >= tcfg.t_rp);
        p_trc   : assert (s_act [rb]  >= tcfg.t_rc);
        p_trrd_s: assert (s_acta      >= tcfg.t_rrd_s);
        p_trrd_l: assert (s_actg[rg]  >= tcfg.t_rrd_l);
      end
      if (do_pre) begin
        p_tras  : assert (s_act [rb]  >= tcfg.t_ras);
      end
      if (do_col) begin
        p_trcd  : assert (s_act [cb]  >= tcfg.t_rcd);
        p_tccd_s: assert (s_col       >= tcfg.t_ccd_s);
        p_tccd_l: assert (s_colg[cg]  >= tcfg.t_ccd_l);
      end
      if (do_rd) p_twtr_s: assert (s_wr >= tcfg.t_wtr_s);
      if (do_wr) p_trtw  : assert (s_rd >= tcfg.t_rtw);
    end
  end

  // ---- P-TIM-13: tFAW -- never more than 4 ACTs in any tFAW window ---------
  // Counted independently: a shift register of the last 4 activate times.
  tmr_t act_hist [4];
  always @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned i = 0; i < 4; i++) act_hist[i] <= SAT;
    end else begin
      for (int unsigned i = 0; i < 4; i++)
        act_hist[i] <= (act_hist[i] == SAT) ? SAT : tmr_t'(act_hist[i] + 1'b1);
      if (do_act) begin
        act_hist[0] <= tmr_t'(1);          // same convention as bump()
        act_hist[1] <= (act_hist[0] == SAT) ? SAT : tmr_t'(act_hist[0] + 1'b1);
        act_hist[2] <= (act_hist[1] == SAT) ? SAT : tmr_t'(act_hist[1] + 1'b1);
        act_hist[3] <= (act_hist[2] == SAT) ? SAT : tmr_t'(act_hist[2] + 1'b1);
      end
    end
  end
  always @(posedge clk)
    if (f_past_valid && rst_n && do_act)
      p_tfaw: assert (act_hist[3] >= tcfg.t_faw);

  // ---- C1 must be ACHIEVABLE, not merely respected ------------------------
  // A timing engine that never grants anything satisfies every property above.
  // These covers prove the ready vectors actually permit a saturated column
  // bus -- which is the whole performance argument.  If tCCD_S were loaded one
  // cycle too long, every assertion would still pass and this cover would fail.
  logic col_d1;
  always @(posedge clk) col_d1 <= do_col;

  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_back_to_back_col : cover (do_col && col_d1);
    c_act_and_col      : cover (do_act && do_col);   // C3: both buses, one cycle
    c_read_after_write : cover (do_rd && (s_wr < SAT));
    c_refresh          : cover (do_ref);
    c_act_after_refresh: cover (do_act && (s_ref[rb] < SAT));
    c_rfm              : cover (do_rfm);
    c_auto_precharge   : cover (do_rda || do_wra);
    // The case that was broken: an ACT to a bank that was auto-precharged.
    c_act_after_ap     : cover (do_act && (s_rda[rb] < SAT));
  end

endmodule
