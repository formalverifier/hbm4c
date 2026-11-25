// ---------------------------------------------------------------------------
// hbm4_timing_pkg -- DRAM timing configuration.
//
// All values are in CORE CLOCKS, not nanoseconds.  Firmware converts from the
// datasheet at the operating frequency and writes them to CSRs; the RTL never
// sees nanoseconds.  That is what makes DVFS a register swap rather than a
// re-synthesis (docs/04-programming-guide.md 4).
//
// The defaults below are PLACEHOLDERS scaled from HBM3 -- see
// docs/08-compliance-matrix.md 4.  They exist so simulation and formal have
// something legal to run against, NOT so anyone ships them.
// ---------------------------------------------------------------------------
package hbm4_timing_pkg;

  parameter int unsigned TMR_W = 10;   // timing counter width, core clocks

  typedef logic [TMR_W-1:0] tmr_t;

  typedef struct packed {
    // --- bank-level -------------------------------------------------------
    tmr_t t_rcd;      // ACT -> first column command
    tmr_t t_rp;       // PRE -> ACT
    tmr_t t_ras;      // ACT -> PRE (minimum)
    tmr_t t_rc;       // ACT -> ACT, same bank
    tmr_t t_rtp;      // RD  -> PRE
    tmr_t t_wr;       // write recovery: last write data -> PRE
    // Auto-precharge command to next ACT on the same bank.  RDA/WRA trigger an
    // INTERNAL precharge, so the bank closes without any row command ever being
    // issued -- nothing on the row bus marks it.  Firmware precomputes
    //   t_rda = tRTP + tRP        t_wra = CWL + BL/2 + tWR + tRP
    // for the same reason the turnaround values are precomputed: the arithmetic
    // belongs in firmware so DVFS stays a register swap.
    tmr_t t_rda;
    tmr_t t_wra;
    // --- bank-group / pseudo-channel level --------------------------------
    tmr_t t_ccd_s;    // column -> column, different bank group
    tmr_t t_ccd_l;    // column -> column, same bank group
    tmr_t t_rrd_s;    // ACT -> ACT, different bank group
    tmr_t t_rrd_l;    // ACT -> ACT, same bank group
    tmr_t t_faw;      // four-activate window
    tmr_t t_wtr_s;    // write -> read, different bank group
    tmr_t t_wtr_l;    // write -> read, same bank group
    tmr_t t_rtw;      // read  -> write turnaround
    // --- latency ----------------------------------------------------------
    tmr_t cl;         // read latency
    tmr_t cwl;        // write latency
    // --- refresh ----------------------------------------------------------
    tmr_t t_rfc_sb;   // per-bank refresh cycle time
    tmr_t t_rfc_ab;   // all-bank refresh cycle time
    tmr_t t_rfm;      // refresh-management cycle time
    logic [15:0] t_refi_pb;  // per-bank refresh interval = tREFI / N_BANK
  } timing_cfg_t;

  // Placeholder defaults, 1 GHz core clock so 1 clock == 1 ns.
  // tCCD_S == BURST_CLKS is the identity that makes the column bus saturable;
  // if a datasheet ever breaks it, the efficiency model in docs/02 14.1 changes.
  function automatic timing_cfg_t default_timing();
    timing_cfg_t t;
    t.t_rcd     = TMR_W'(14);
    t.t_rp      = TMR_W'(14);
    t.t_ras     = TMR_W'(29);
    t.t_rc      = TMR_W'(43);
    t.t_rtp     = TMR_W'(5);
    t.t_wr      = TMR_W'(15);
    t.t_rda     = TMR_W'(19);   // tRTP 5 + tRP 14
    t.t_wra     = TMR_W'(29);   // CWL 8 + BL/2 1 + tWR 15 + ... + tRP 14 (P)
    t.t_ccd_s   = TMR_W'(1);
    t.t_ccd_l   = TMR_W'(2);
    t.t_rrd_s   = TMR_W'(2);
    t.t_rrd_l   = TMR_W'(4);
    t.t_faw     = TMR_W'(14);
    t.t_wtr_s   = TMR_W'(5);
    t.t_wtr_l   = TMR_W'(10);
    t.t_rtw     = TMR_W'(7);
    t.cl        = TMR_W'(16);
    t.cwl       = TMR_W'(8);
    t.t_rfc_sb  = TMR_W'(190);
    t.t_rfc_ab  = TMR_W'(350);
    t.t_rfm     = TMR_W'(190);
    t.t_refi_pb = 16'd122;      // 3900 ns / 32 banks
    return t;
  endfunction

  // Small legal timing set for formal, where every extra counter bit costs
  // state space.  Preserves the ORDERING relationships that matter
  // (tRC > tRAS > tRCD, tCCD_L > tCCD_S, ...) so the proofs stay meaningful.
  function automatic timing_cfg_t small_timing();
    timing_cfg_t t;
    t.t_rcd     = TMR_W'(3);
    t.t_rp      = TMR_W'(3);
    t.t_ras     = TMR_W'(5);
    t.t_rc      = TMR_W'(8);
    t.t_rtp     = TMR_W'(2);
    t.t_wr      = TMR_W'(3);
    t.t_rda     = TMR_W'(5);    // t_rtp 2 + t_rp 3
    t.t_wra     = TMR_W'(6);    // t_wr 3 + t_rp 3
    t.t_ccd_s   = TMR_W'(1);
    t.t_ccd_l   = TMR_W'(2);
    t.t_rrd_s   = TMR_W'(1);
    t.t_rrd_l   = TMR_W'(2);
    t.t_faw     = TMR_W'(6);
    t.t_wtr_s   = TMR_W'(2);
    t.t_wtr_l   = TMR_W'(3);
    t.t_rtw     = TMR_W'(2);
    t.cl        = TMR_W'(4);
    t.cwl       = TMR_W'(2);
    t.t_rfc_sb  = TMR_W'(6);
    t.t_rfc_ab  = TMR_W'(10);
    t.t_rfm     = TMR_W'(6);
    t.t_refi_pb = 16'd20;
    return t;
  endfunction

endpackage
