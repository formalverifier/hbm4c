// ---------------------------------------------------------------------------
// fv_ecc_cache -- P-EC-*.
//
// The property that protects data is P-EC-2: a DIRTY entry is never replaced
// without its write-back being acknowledged.
//
// Silently dropping one costs the check bits for ECC_FANOUT (15) data blocks
// at once.  Those blocks do not become obviously broken -- they become blocks
// whose stored ECC no longer matches their data, so the next read reports an
// UNCORRECTABLE error on data that was never actually damaged.  Worse, the
// patrol scrubber then finds them too and reports a storm of failures across a
// perfectly healthy device.  Debugging that from the symptom is close to
// hopeless; proving it cannot happen is cheap.
// ---------------------------------------------------------------------------
module fv_ecc_cache
  import hbm4_pkg::*;
(
  input logic                   clk,
  input logic                   rst_n,
  input logic                   lu_valid,
  input bank_t                  lu_bank,
  input row_t                   lu_row,
  input col_t                   lu_col,
  input logic                   fill_valid,
  input bank_t                  fill_bank,
  input row_t                   fill_row,
  input logic                   fill_half,
  input logic [AG_BYTES*8-1:0]  fill_data,
  input logic                   upd_valid,
  input bank_t                  upd_bank,
  input row_t                   upd_row,
  input col_t                   upd_col,
  input logic [ECC_FIELD_W-1:0] upd_field,
  input logic                   evict_ack
);

  localparam int unsigned FAN = ECC_FANOUT;

  logic                   lu_hit, lu_miss, evict_req, evict_half, evict_generate;
  logic                   upd_stall;
  logic [ECC_FIELD_W-1:0] lu_field;
  bank_t                  evict_bank;
  row_t                   evict_row;
  logic [AG_BYTES*8-1:0]  evict_data;
  logic [N_BANK-1:0]      dbg_valid, dbg_dirty, dbg_half, dbg_fv_full;
  row_t [N_BANK-1:0]      dbg_row;

  hbm4_ecc_cache dut (
    .clk (clk), .rst_n (rst_n),
    .lu_valid (lu_valid), .lu_bank (lu_bank), .lu_row (lu_row), .lu_col (lu_col),
    .lu_hit (lu_hit), .lu_miss (lu_miss), .lu_field (lu_field),
    .fill_valid (fill_valid), .fill_bank (fill_bank), .fill_row (fill_row),
    .fill_half (fill_half), .fill_data (fill_data),
    .upd_valid (upd_valid), .upd_bank (upd_bank), .upd_row (upd_row),
    .upd_col (upd_col), .upd_field (upd_field), .upd_stall (upd_stall),
    .evict_req (evict_req), .evict_bank (evict_bank), .evict_row (evict_row),
    .evict_half (evict_half), .evict_data (evict_data),
    .evict_generate (evict_generate), .evict_ack (evict_ack),
    .dbg_valid (dbg_valid), .dbg_dirty (dbg_dirty),
    .dbg_row (dbg_row), .dbg_half (dbg_half), .dbg_fv_full (dbg_fv_full)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // Columns are DATA columns; the ECC columns are not addressable this way.
  always @(*) begin
    assume (lu_col  < col_t'(N_COL_DATA));
    assume (upd_col < col_t'(N_COL_DATA));
  end

  (* anyconst *) logic [BANK_W-1:0] f_bank;

  // Strengthening invariant for k-induction: an entry cannot be dirty without
  // being valid.  Unreachable from reset -- dirty is only ever set alongside
  // valid -- but induction starts anywhere, and from `dirty && !valid` a fill
  // sees neither a conflict nor a redundancy and clears the dirty bit.
  always @(posedge clk)
    if (f_past_valid && rst_n)
      p_dirty_implies_valid: assert (!dbg_dirty[f_bank] || dbg_valid[f_bank]);

  // ---- P-EC-1: hit means the tag genuinely matches ------------------------
  // A false hit returns another row's check bits, which then "corrects" good
  // data into garbage -- silent corruption dressed up as a successful ECC
  // correction.
  always @(*)
    if (f_past_valid && rst_n && lu_hit) begin
      p_hit_is_valid: assert (dbg_valid[lu_bank]);
      p_hit_row     : assert (dbg_row[lu_bank] == lu_row);
      p_hit_half    : assert (dbg_half[lu_bank] == (lu_col >= col_t'(FAN)));
    end

  always @(*)
    if (f_past_valid && rst_n && lu_valid)
      p_hit_xor_miss: assert (lu_hit != lu_miss);

  // ---- P-EC-2: a DIRTY entry is never replaced without an acknowledged
  //              write-back.  CLOSED in Rev 0.7c (was OPEN-8).
  //
  // One property, three real bugs:
  //   1. the update path had no row input and reused a slot without eviction,
  //      discarding a dirty block and leaving an inconsistent tag;
  //   2. upd_stall tested the global evict_ack without asking WHOSE eviction
  //      was acknowledged, so a fill's ack let a conflicting update through;
  //   3. a fill whose tag ALREADY MATCHED a dirty entry was applied anyway,
  //      overwriting recomputed check values with the stale ones just read from
  //      DRAM and clearing the dirty bit -- no conflict, no eviction, no error.
  //
  // (3) is the one worth remembering: it is not a conflict at all, which is
  // why "handle the conflicting cases" was not enough.  A fill is only ever
  // useful onto a CLEAN entry.
  // Stated as: a dirty entry's tag changes ONLY when ITS OWN eviction was
  // acknowledged.
  //
  // The first formulation instead required `!$past(evict_ack)` in the
  // antecedent, so it never examined the case where an ack occurred FOR A
  // DIFFERENT BANK -- which is exactly the ack-ownership bug.  Reverting that
  // fix survived mutation testing until the property was rewritten this way.
  //
  // Keying on the identity of the acknowledged eviction, rather than on the
  // mere absence of an ack, is what makes it airtight.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(dbg_dirty[f_bank]) && $past(dbg_valid[f_bank])
        && ((dbg_row[f_bank]  != $past(dbg_row[f_bank]))
         || (dbg_half[f_bank] != $past(dbg_half[f_bank])))) begin
      p_dirty_evicted_first: assert ($past(evict_ack)
                                     && ($past(evict_bank) == f_bank));
    end

  // A fill must never clear the dirty bit of an entry it did not evict.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(dbg_dirty[f_bank]) && $past(fill_valid)
        && ($past(fill_bank) == f_bank) && !$past(evict_ack))
      p_fill_never_drops_dirty: assert (dbg_dirty[f_bank]);

  // ---- P-EC-3: a conflicting fill onto a dirty entry always asks for the
  //              write-back, rather than proceeding silently
  always @(*)
    if (f_past_valid && rst_n && fill_valid && dbg_valid[fill_bank]
        && dbg_dirty[fill_bank]
        && ((dbg_row[fill_bank] != fill_row)
            || (dbg_half[fill_bank] != fill_half)))
      p_evict_requested: assert (evict_req);

  // An UPDATE that would displace a dirty block must also request the
  // write-back -- the path the first version silently reused.
  always @(*)
    if (f_past_valid && rst_n && upd_valid && dbg_valid[upd_bank]
        && dbg_dirty[upd_bank]
        && ((dbg_row[upd_bank] != upd_row)
            || (dbg_half[upd_bank] != (upd_col >= col_t'(FAN)))))
      // The eviction must be REQUESTED; the update is held off unless it is
      // acknowledged in the same cycle.  Asserting upd_stall unconditionally
      // was too strong -- a same-cycle ack legitimately lets the update through.
      p_upd_evict_requested: assert (evict_req && (upd_stall || evict_ack));

  // ---- P-EC-4: elision is claimed only when every field is known ----------
  // Generating a block with an unwritten field would store a check value for
  // data that was never seen -- guaranteeing a false uncorrectable on the next
  // read of that block.
  always @(*)
    if (f_past_valid && rst_n && evict_req && evict_generate)
      p_elide_only_if_complete: assert (dbg_fv_full[evict_bank]);

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_hit      : cover (lu_hit);
    c_miss     : cover (lu_miss);
    c_dirty    : cover (dbg_dirty[f_bank]);
    c_evict    : cover (evict_req);
    c_elide    : cover (evict_req && evict_generate);
    c_no_elide : cover (evict_req && !evict_generate);
    c_upd_stall: cover (upd_stall);
  end

endmodule
