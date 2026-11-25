// ---------------------------------------------------------------------------
// hbm4_ecc_cache -- resident ECC columns, one entry per bank.
//
// DIRECT-MAPPED BY BANK INDEX, with no associativity and no replacement
// policy.  That is not a simplification for its own sake -- it is EXACT:
//
//   a bank has exactly ONE open row,
//   and each row-half has exactly ONE ECC column,
//   therefore there is never more than one ECC block per bank in flight.
//
// The structure is forced by the DRAM, which is the best kind of design: there
// is no replacement decision to get wrong because there is never a conflict.
// (docs/02-architecture.md 10.3)
//
// WRITE-ALLOCATE ELISION.  Each entry carries ECC_FANOUT field-valid bits.  If
// a write stream fills all of them before eviction -- which sequential writes
// do -- the ECC block is GENERATED, never read.  That is what keeps writes at
// 6.25% overhead instead of 12.5%: without it every ECC block would have to be
// read before it could be modified.
// ---------------------------------------------------------------------------
module hbm4_ecc_cache
  import hbm4_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- lookup, from the data access path ----------------------------------
  input  logic                    lu_valid,
  input  bank_t                   lu_bank,
  input  row_t                    lu_row,
  input  col_t                    lu_col,        // DATA column, 0..N_COL_DATA-1
  output logic                    lu_hit,
  output logic                    lu_miss,
  output logic [ECC_FIELD_W-1:0]  lu_field,

  // ---- fill: an ECC column read came back ---------------------------------
  input  logic                    fill_valid,
  input  bank_t                   fill_bank,
  input  row_t                    fill_row,
  input  logic                    fill_half,
  input  logic [AG_BYTES*8-1:0]   fill_data,

  // ---- update: the write path stores a new field --------------------------
  input  logic                    upd_valid,
  input  bank_t                   upd_bank,
  input  row_t                    upd_row,       // REQUIRED: completes the tag
  input  col_t                    upd_col,
  input  logic [ECC_FIELD_W-1:0]  upd_field,
  output logic                    upd_stall,     // conflicting dirty block first

  // ---- eviction ------------------------------------------------------------
  output logic                    evict_req,
  output bank_t                   evict_bank,
  output row_t                    evict_row,
  output logic                    evict_half,
  output logic [AG_BYTES*8-1:0]   evict_data,
  output logic                    evict_generate, // all fields valid: no read needed
  input  logic                    evict_ack,

  // ---- observability -------------------------------------------------------
  output logic [N_BANK-1:0]       dbg_valid,
  output logic [N_BANK-1:0]       dbg_dirty,
  // Packed mirrors of the tag state.  Packed, not unpacked, because a formal
  // wrapper cannot index an unpacked array through a hierarchy boundary --
  // the same reason hbm4_wbuf and hbm4_rd_ptr_fifo export theirs.
  output row_t [N_BANK-1:0]       dbg_row,
  output logic [N_BANK-1:0]       dbg_half,
  output logic [N_BANK-1:0]       dbg_fv_full   // every field of this entry known
);

  localparam int unsigned FAN = ECC_FANOUT;          // 15 data blocks per ECC column
  localparam int unsigned FW  = ECC_FIELD_W;         // 16 bits per field

  // Which ECC column covers a data column, and which field within it.
  // N_COL_ECC is 2, so the "divide" is a compare and a conditional subtract --
  // no divider needed here, unlike the row/column split in hbm4_addr_decode.
  function automatic logic half_of(input col_t c);
    return (c >= col_t'(FAN));
  endfunction

  function automatic int unsigned field_of(input col_t c);
    return (c >= col_t'(FAN)) ? int'(c) - int'(FAN) : int'(c);
  endfunction

  // ---- storage -------------------------------------------------------------
  logic [N_BANK-1:0]            ent_valid, ent_dirty;
  row_t                         ent_row  [N_BANK];
  logic                         ent_half [N_BANK];
  logic [FW-1:0]                ent_fld  [N_BANK][FAN];
  logic [FAN-1:0]               ent_fv   [N_BANK];   // per-field valid

  assign dbg_valid = ent_valid;
  assign dbg_dirty = ent_dirty;

  always_comb
    for (int unsigned b = 0; b < N_BANK; b++) begin
      dbg_row    [b] = ent_row [b];
      dbg_half   [b] = ent_half[b];
      dbg_fv_full[b] = &ent_fv [b];
    end

  // ---- lookup --------------------------------------------------------------
  logic lu_tag_match;
  assign lu_tag_match = ent_valid[lu_bank]
                     && (ent_row [lu_bank] == lu_row)
                     && (ent_half[lu_bank] == half_of(lu_col));

  assign lu_hit   = lu_valid &&  lu_tag_match;
  assign lu_miss  = lu_valid && !lu_tag_match;
  assign lu_field = ent_fld[lu_bank][field_of(lu_col)];

  // ---- eviction ------------------------------------------------------------
  // An entry must be written back when it is dirty and something else wants
  // the slot.  Because the mapping is exact, "something else" can only ever be
  // a different row or row-half of the SAME bank.
  logic fill_conflict, upd_conflict, fill_same_tag, fill_redundant, fill_apply;

  assign fill_same_tag = ent_valid[fill_bank]
                      && (ent_row [fill_bank] == fill_row)
                      && (ent_half[fill_bank] == fill_half);

  assign fill_conflict = fill_valid && ent_valid[fill_bank] && ent_dirty[fill_bank]
                      && !fill_same_tag;

  // A fill onto a DIRTY entry whose tag already MATCHES must be DROPPED, not
  // applied.  The cache holds check values recomputed by the write path; DRAM
  // holds the stale ones.  Applying the fill overwrites newer data with older
  // and clears the dirty bit, so the updates are lost with no eviction and no
  // error -- and 15 data blocks silently keep check bits that no longer match
  // them.
  //
  // This was the residual failure behind OPEN-8.  The two earlier fixes
  // (adding upd_row, and making upd_stall respect ack ownership) were both
  // real, but neither covered a fill that does not conflict yet still destroys
  // dirty state.
  assign fill_redundant = fill_valid && ent_valid[fill_bank]
                       && ent_dirty[fill_bank] && fill_same_tag;

  assign fill_apply = fill_valid && !fill_redundant
                   && (!fill_conflict || evict_ack);

  // An UPDATE can conflict too, and the first version of this module missed it:
  // a write to a different row or row-half reused the slot and discarded the
  // resident dirty block with no write-back, losing the check bits for
  // ECC_FANOUT data blocks.  It also left the tag inconsistent, because the
  // update path had no row input at all -- it set `half` from the new column
  // while `row` still described the old block.
  //
  // Both found by formal (p_dirty_not_lost_row).  An update now takes the same
  // eviction protocol as a fill, and carries the row that completes its tag.
  assign upd_conflict = upd_valid && ent_valid[upd_bank] && ent_dirty[upd_bank]
                     && ((ent_row[upd_bank] != upd_row)
                      || (ent_half[upd_bank] != half_of(upd_col)));

  // The ack belongs to whichever request WON arbitration.  A fill conflict
  // takes priority, so an ack while fill_conflict is asserted is the fill's --
  // it says nothing about the update's block.
  //
  // Bug found by formal (p_dirty_still_dirty): the first version tested
  // `!evict_ack` alone, so a fill and an update conflicting on DIFFERENT banks
  // let the update through on the fill's acknowledgement, discarding a dirty
  // ECC block that was never written back.  Fifteen data blocks lose their
  // check bits, and the next read of any of them reports an uncorrectable
  // error on data that was never damaged.
  assign upd_stall  = upd_conflict && !(evict_ack && !fill_conflict);

  // Mux the RESULTS, not the address.
  //
  // The natural form -- ev_bank = fill_conflict ? fill_bank : upd_bank, then
  // ent_row[ev_bank] -- makes a memory read port whose ADDRESS depends on
  // another read of the same array (fill_conflict compares ent_row[fill_bank]).
  // Yosys models the array as one cell and reports that as a combinational
  // loop, even though no real loop exists.  Reading both candidates at fixed
  // addresses and selecting afterwards is equivalent and analysable.
  assign evict_req  = fill_conflict || upd_conflict;
  assign evict_bank = fill_conflict ? fill_bank : upd_bank;
  assign evict_row  = fill_conflict ? ent_row [fill_bank] : ent_row [upd_bank];
  assign evict_half = fill_conflict ? ent_half[fill_bank] : ent_half[upd_bank];

  // Every field written since the entry was created means the block can be
  // generated outright -- the read that would otherwise be needed is elided.
  assign evict_generate = fill_conflict ? (&ent_fv[fill_bank]) : (&ent_fv[upd_bank]);

  always_comb begin
    evict_data = '0;
    for (int unsigned f = 0; f < FAN; f++)
      evict_data[f*FW +: FW] = fill_conflict ? ent_fld[fill_bank][f]
                                             : ent_fld[upd_bank][f];
  end

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ent_valid <= '0;
      ent_dirty <= '0;
      for (int unsigned b = 0; b < N_BANK; b++) ent_fv[b] <= '0;
    end else begin
      // fill: install a new ECC column for this bank.  Allowed only once any
      // dirty predecessor has been acknowledged -- otherwise the write-back
      // would be dropped and 15 blocks would lose their check bits.
      if (fill_apply) begin
        ent_valid[fill_bank] <= 1'b1;
        ent_dirty[fill_bank] <= 1'b0;
        ent_row  [fill_bank] <= fill_row;
        ent_half [fill_bank] <= fill_half;
        ent_fv   [fill_bank] <= '1;              // a filled block is fully known
        for (int unsigned f = 0; f < FAN; f++)
          ent_fld[fill_bank][f] <= fill_data[f*FW +: FW];
      end

      // update: the write path recomputed one field
      if (upd_valid && !upd_stall) begin
        ent_fld  [upd_bank][field_of(upd_col)] <= upd_field;
        ent_fv   [upd_bank][field_of(upd_col)] <= 1'b1;
        ent_dirty[upd_bank]                    <= 1'b1;
        // A write to a slot that holds a different row-half implicitly starts a
        // new block: only the field just written is known.
        if (!ent_valid[upd_bank] || (ent_row[upd_bank] != upd_row)
            || (ent_half[upd_bank] != half_of(upd_col))) begin
          ent_valid[upd_bank] <= 1'b1;
          ent_row  [upd_bank] <= upd_row;          // completes the tag
          ent_half [upd_bank] <= half_of(upd_col);
          ent_fv   [upd_bank] <= (FAN'(1) << field_of(upd_col));
        end
      end
    end
  end

endmodule
