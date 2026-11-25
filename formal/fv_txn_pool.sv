// ---------------------------------------------------------------------------
// fv_txn_pool -- P-POOL-*.
//
// The headline property here is P-POOL-5, which DISCHARGES ASSUMPTION A3.
// fv_col_arb assumes that a candidate stays a candidate until it is granted;
// without it the solver withdraws candidacy to defeat any fairness bound.
// That assumption is only legitimate if the pool actually behaves that way,
// and this is where that is proved rather than asserted.
//
// P-POOL-3 (the list counts sum to the number of valid entries) is the classic
// pool invariant.  Entry leaks and double-frees are exactly the bugs that
// simulation finds three weeks late, as a slow throughput decay under a long
// random test, with no failing check to point at.
// ---------------------------------------------------------------------------
module fv_txn_pool
  import hbm4_pkg::*;
(
  input logic     clk,
  input logic     rst_n,
  input logic     alloc_valid,
  input logic     alloc_wr,
  input pc_addr_t alloc_addr,
  input bank_t    alloc_bank,
  input tag_t     alloc_tag,
  input qos_t     alloc_qos,
  input logic     issue_valid,
  input bank_t    issue_bank,
  input dir_e     issue_dir
);

  logic              alloc_ready;
  logic [N_BANK-1:0] pend_rd, pend_wr, pend_urgent;
  row_t              head_row [N_BANK];
  row_t              head_wrow[N_BANK];
  pc_addr_t          issue_addr;
  tag_t              issue_tag;
  logic [TQ_IDX_W:0] occupancy, occ_lists;

  hbm4_txn_pool dut (
    .clk (clk), .rst_n (rst_n),
    .alloc_valid (alloc_valid), .alloc_wr (alloc_wr), .alloc_addr (alloc_addr),
    .alloc_bank (alloc_bank), .alloc_tag (alloc_tag), .alloc_qos (alloc_qos),
    .alloc_ready (alloc_ready),
    .pend_rd (pend_rd), .pend_wr (pend_wr), .pend_urgent (pend_urgent),
    .head_row (head_row), .head_wrow (head_wrow),
    .issue_valid (issue_valid), .issue_bank (issue_bank), .issue_dir (issue_dir),
    .issue_addr (issue_addr), .issue_tag (issue_tag),
    .occupancy (occupancy), .occ_lists (occ_lists)
  );

  // ---- reset (ASSUMPTION A1) ----------------------------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- environment contract: never issue from an empty list ---------------
  // The column arbiter only grants a bank whose pend_* bit is set, which is
  // proved in fv_col_arb (p_only_ready plus the candidate definition).
  // NOTE: written as two separate guarded assumes rather than if/else.
  // sv2v mis-converts `if (c) assume(a); else assume(b);` into
  // `assume(a) else assume(b)`, which Yosys then rejects.  Second sv2v quirk
  // found in this project after the silent -E Assert stripping; both are
  // recorded in docs/06-verification-plan.md.
  always @(*)
    if (f_past_valid && rst_n && issue_valid && (issue_dir == DIR_READ))
      assume (pend_rd[issue_bank]);

  always @(*)
    if (f_past_valid && rst_n && issue_valid && (issue_dir == DIR_WRITE))
      assume (pend_wr[issue_bank]);

  // ---- P-POOL-3: list counts sum to the valid-entry count -----------------
  // Catches entry leaks (occupancy drifts up, throughput decays) and double
  // frees (an entry issued twice, so data is written twice or lost).
  // Bind the DUT's per-list counters out through a generate loop so every
  // hierarchical reference has a CONSTANT index.  A variable index into an
  // unpacked array across a hierarchy boundary cannot be width-resolved
  // (Yosys: "Don't know how to detect sign and width for AST_AUTOWIRE").


  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_counts_sum: assert (occ_lists == occupancy);
    end

  // ---- P-POOL-2: occupancy never exceeds the pool -------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_no_overflow  : assert (occupancy <= (TQ_IDX_W+1)'(TQ_DEPTH));
      p_ready_correct: assert (alloc_ready == (occupancy < (TQ_IDX_W+1)'(TQ_DEPTH)));
    end

  // ---- P-POOL-5: candidacy is persistent  (DISCHARGES A3) -----------------
  //
  // A bank that has a pending read stays pending until a read is issued FROM
  // THAT BANK.  This is exactly the persistence fv_col_arb assumes, and it is
  // what makes the fairness bound meaningful rather than an artefact of an
  // over-constrained environment.
  (* anyconst *) logic [BANK_W-1:0] f_bank;

  always @(posedge clk) begin
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)) begin
      if ($past(pend_rd[f_bank])
          && !($past(issue_valid) && ($past(issue_bank) == f_bank)
               && ($past(issue_dir) == DIR_READ))) begin
        p_rd_persistent: assert (pend_rd[f_bank]);
      end

      if ($past(pend_wr[f_bank])
          && !($past(issue_valid) && ($past(issue_bank) == f_bank)
               && ($past(issue_dir) == DIR_WRITE))) begin
        p_wr_persistent: assert (pend_wr[f_bank]);
      end
    end
  end

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_full        : cover (occupancy == (TQ_IDX_W+1)'(TQ_DEPTH));
    c_empty_again : cover ((occupancy == '0) && $past(occupancy != '0));
    c_two_lists   : cover (pend_rd[f_bank] && pend_wr[f_bank]);
    c_alloc_issue : cover (alloc_valid && alloc_ready && issue_valid);
  end

endmodule
