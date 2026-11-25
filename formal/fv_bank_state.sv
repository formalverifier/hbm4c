// ---------------------------------------------------------------------------
// fv_bank_state -- P-ST-*.
//
// A bank has exactly one row buffer.  This module is the design's record of
// which row that is, and if it disagrees with the DRAM the controller will
// happily read the wrong row and report success.  There is no ECC check for
// "correct data, wrong row".
//
// The property that earns this proof its place is P-ST-5: row-bus and
// column-bus effects are applied INDEPENDENTLY.  Constraint C3 means both buses
// issue in the same cycle, so an ACT to one bank and an auto-precharging RDA to
// another both happen at once.  Written as an if/else chain across the buses --
// which the first version of this module was -- one of them is silently
// dropped, and a dropped ACT leaves the model claiming IDLE while the DRAM has
// the row open.
// ---------------------------------------------------------------------------
module fv_bank_state
  import hbm4_pkg::*;
(
  input logic       clk,
  input logic       rst_n,
  input row_issue_t row_iss,
  input col_issue_t col_iss
);

  bank_st_e          st       [N_BANK];
  row_t              open_row [N_BANK];
  logic [N_BANK-1:0] is_active;

  hbm4_bank_state dut (
    .clk (clk), .rst_n (rst_n),
    .row_iss (row_iss), .col_iss (col_iss),
    .st (st), .open_row (open_row), .is_active (is_active)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  (* anyconst *) logic [BANK_W-1:0] f_bank;

  logic do_act, do_pre, do_prea, do_ref_sb, do_ref_ab, do_ap;
  assign do_act    = row_iss.valid && (row_iss.cmd == ROW_ACT);
  assign do_pre    = row_iss.valid && (row_iss.cmd == ROW_PRE);
  assign do_prea   = row_iss.valid && (row_iss.cmd == ROW_PREA);
  assign do_ref_sb = row_iss.valid && (row_iss.cmd == ROW_REF_SB);
  assign do_ref_ab = row_iss.valid && (row_iss.cmd == ROW_REF_AB);
  assign do_ap     = col_iss.valid && ((col_iss.cmd == COL_RDA)
                                    || (col_iss.cmd == COL_WRA));

  // ---- P-ST-4: the state encoding is always legal -------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_legal_state: assert (st[f_bank] inside {BK_IDLE, BK_ACTIVE});
      p_active_flag: assert (is_active[f_bank] == (st[f_bank] == BK_ACTIVE));
    end

  // ---- P-ST-2: ACT records the row it opened ------------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(do_act) && ($past(row_iss.bank) == f_bank)) begin
      p_act_opens  : assert (st[f_bank] == BK_ACTIVE);
      p_act_row    : assert (open_row[f_bank] == $past(row_iss.row));
    end

  // ---- P-ST-3: every close path actually closes ---------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)) begin
      // explicit precharge / per-bank refresh
      if (($past(do_pre) || $past(do_ref_sb)) && ($past(row_iss.bank) == f_bank)
          && !$past(do_act))
        p_pre_closes: assert (st[f_bank] == BK_IDLE);

      // all-bank commands close every bank
      if (($past(do_prea) || $past(do_ref_ab)))
        p_all_close: assert (st[f_bank] == BK_IDLE);

      // AUTO-PRECHARGE closes the bank with no row command at all
      if ($past(do_ap) && ($past(col_iss.bank) == f_bank)
          && !($past(row_iss.valid) && ($past(row_iss.bank) == f_bank)))
        p_ap_closes: assert (st[f_bank] == BK_IDLE);
    end

  // ---- P-ST-5: the two buses are independent ------------------------------
  // An ACT on the row bus and an auto-precharge on the column bus, to DIFFERENT
  // banks, in the SAME cycle.  Both must land.  This is the property an
  // if/else chain across the buses breaks.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(do_act) && $past(do_ap)
        && ($past(row_iss.bank) != $past(col_iss.bank))
        && ($past(row_iss.bank) == f_bank))
      p_row_not_dropped: assert (st[f_bank] == BK_ACTIVE);

  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(do_act) && $past(do_ap)
        && ($past(row_iss.bank) != $past(col_iss.bank))
        && ($past(col_iss.bank) == f_bank))
      p_col_not_dropped: assert (st[f_bank] == BK_IDLE);

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_active      : cover (is_active[f_bank]);
    c_idle_again  : cover (!is_active[f_bank] && $past(is_active[f_bank]));
    c_ap_close    : cover (do_ap && (col_iss.bank == f_bank));
    // The simultaneous case that motivates P-ST-5.
    c_both_buses  : cover (do_act && do_ap && (row_iss.bank != col_iss.bank));
  end

endmodule
