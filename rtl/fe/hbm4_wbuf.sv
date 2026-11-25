// ---------------------------------------------------------------------------
// hbm4_wbuf -- write buffer, write coalescing, and the read-after-write hazard
// check.
//
// Two jobs:
//
// 1. HOLD WRITES so the direction FSM can drain them in long bursts.  The DQ
//    bus is bidirectional and each turnaround wastes ~12 ns, so batching is
//    what keeps turnaround overhead at 3.0% instead of 11%.  Depth is the
//    single biggest lever on that number (docs/02-architecture.md 8.4).
//
// 2. STOP A READ OVERTAKING A PENDING WRITE to the same 32 B block.  Getting
//    this wrong returns stale data with no error anywhere -- there is no ECC
//    check that catches "correct data, wrong version".
//
// The hazard check is TWO-TIER.  A flat WBUF_DEPTH x HAZ_TAG_W CAM searched
// every cycle, at 1 GHz, across 256 pseudo-channels, is roughly 30 W of search
// power -- the whole power budget of a reasonable controller, spent on a check
// that misses 97% of the time.  So:
//
//    tier 1  HAZ_HASH_W-bit hash compare, fully parallel, every cycle.
//            Cheap.  May produce FALSE POSITIVES.
//    tier 2  on a tier-1 hit, compare the full tags exactly.
//            Costs a cycle, taken on ~3% of accesses.
//
// FALSE NEGATIVES ARE IMPOSSIBLE BY CONSTRUCTION, because the hash is a pure
// function of the tag: equal tags always hash equally, so a real match can
// never be filtered out at tier 1.  That is the property the whole structure
// rests on, and it is PROVED (fv_wbuf p_no_false_negative), not tested -- a
// test can only sample the tag space.
// ---------------------------------------------------------------------------
module hbm4_wbuf
  import hbm4_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- write allocate ------------------------------------------------------
  input  logic                    wr_valid,
  input  bank_t                   wr_bank,
  input  row_t                    wr_row,
  input  col_t                    wr_col,
  input  logic [AG_BYTES-1:0]     wr_be,
  output logic                    wr_ready,
  output logic                    wr_coalesced,   // merged into an existing entry

  // ---- read hazard check ---------------------------------------------------
  input  logic                    rd_valid,
  input  bank_t                   rd_bank,
  input  row_t                    rd_row,
  input  col_t                    rd_col,
  output logic                    rd_hazard,      // a pending write covers this block
  output logic                    rd_forward,     // ...and covers ALL of it
  output logic [WBUF_IDX_W-1:0]   rd_haz_idx,

  // ---- drain ---------------------------------------------------------------
  input  logic                    drain_valid,
  input  logic [WBUF_IDX_W-1:0]   drain_idx,

  output logic [WBUF_IDX_W:0]     occupancy,

  // ---- observability -------------------------------------------------------
  // Packed mirrors of the entry state, for silicon debug and for formal.
  // Packed (not unpacked) so they cross a hierarchy boundary cleanly: Yosys
  // cannot width-resolve a variable index into an unpacked array through a
  // hierarchical reference, and a formal wrapper needs exactly that.
  output logic [WBUF_DEPTH-1:0]                  dbg_valid,
  output logic [WBUF_DEPTH-1:0][HAZ_TAG_W-1:0]   dbg_tag,
  output logic [WBUF_DEPTH-1:0]                  dbg_be_full,
  output logic [WBUF_DEPTH-1:0][HAZ_HASH_W-1:0]  dbg_hash
);

  // ---- tag and hash --------------------------------------------------------
  function automatic logic [HAZ_TAG_W-1:0] mk_tag
      (input bank_t b, input row_t r, input col_t c);
    return {b, r, c};
  endfunction

  // XOR-fold the tag down to HAZ_HASH_W bits.  Any function would preserve the
  // no-false-negative property; folding is chosen because it distributes the
  // low-order bits that actually vary within a stream.
  function automatic logic [HAZ_HASH_W-1:0] mk_hash(input logic [HAZ_TAG_W-1:0] t);
    logic [HAZ_HASH_W-1:0] h;
    h = '0;
    for (int unsigned i = 0; i < HAZ_TAG_W; i++)
      h[i % HAZ_HASH_W] = h[i % HAZ_HASH_W] ^ t[i];
    return h;
  endfunction

  // ---- storage -------------------------------------------------------------
  logic [WBUF_DEPTH-1:0]      ent_valid;
  logic [HAZ_TAG_W-1:0]       ent_tag  [WBUF_DEPTH];
  logic [HAZ_HASH_W-1:0]      ent_hash [WBUF_DEPTH];
  logic [AG_BYTES-1:0]        ent_be   [WBUF_DEPTH];

  logic [HAZ_TAG_W-1:0]  wr_tag,  rd_tag;
  logic [HAZ_HASH_W-1:0] wr_hash, rd_hash;

  assign wr_tag  = mk_tag(wr_bank, wr_row, wr_col);
  assign rd_tag  = mk_tag(rd_bank, rd_row, rd_col);
  assign wr_hash = mk_hash(wr_tag);
  assign rd_hash = mk_hash(rd_tag);

  // ---- free entry ----------------------------------------------------------
  logic [WBUF_DEPTH-1:0] free_mask, free_onehot;
  logic [WBUF_IDX_W-1:0] free_idx;

  assign free_mask   = ~ent_valid;
  assign free_onehot = free_mask & (~free_mask + {{(WBUF_DEPTH-1){1'b0}}, 1'b1});
  assign wr_ready    = |free_mask;

  always_comb begin
    free_idx = '0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      if (free_onehot[i]) free_idx = WBUF_IDX_W'(i);
  end

  // ---- tier 1: hash compare (every cycle, cheap) ---------------------------
  logic [WBUF_DEPTH-1:0] rd_t1, wr_t1;
  always_comb begin
    for (int unsigned i = 0; i < WBUF_DEPTH; i++) begin
      rd_t1[i] = ent_valid[i] && (ent_hash[i] == rd_hash);
      wr_t1[i] = ent_valid[i] && (ent_hash[i] == wr_hash);
    end
  end

  // ---- tier 2: exact tag compare, only on tier-1 hits ----------------------
  // In silicon this reads <= 4 candidate tags from a small RAM and costs one
  // extra cycle.  Modelled combinationally here; the gating by rd_t1 is what
  // makes it cheap, and is why the false-negative property matters.
  logic [WBUF_DEPTH-1:0] rd_t2, wr_t2;
  always_comb begin
    for (int unsigned i = 0; i < WBUF_DEPTH; i++) begin
      rd_t2[i] = rd_t1[i] && (ent_tag[i] == rd_tag);
      wr_t2[i] = wr_t1[i] && (ent_tag[i] == wr_tag);
    end
  end

  // ---- read hazard result --------------------------------------------------
  logic [WBUF_IDX_W-1:0] haz_idx;
  logic                  haz_hit;
  always_comb begin
    haz_hit = 1'b0;
    haz_idx = '0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      if (rd_t2[i]) begin
        haz_hit = 1'b1;
        haz_idx = WBUF_IDX_W'(i);
      end
  end

  assign rd_hazard  = rd_valid && haz_hit;
  // Forward only when the buffered write covers EVERY byte the read wants.
  // A partial hit cannot be forwarded -- the read needs the merge of buffered
  // and DRAM data, so it must wait for the write to drain instead.
  assign rd_forward = rd_hazard && (&ent_be[haz_idx]);
  assign rd_haz_idx = haz_idx;

  // ---- write coalescing ----------------------------------------------------
  // A write hitting a pending write to the same block merges into it: OR the
  // byte enables.  This is what keeps partial writes off the ECC read-modify-
  // write path (docs/02-architecture.md 10.4), and it is nearly free given the
  // hazard structure already exists.
  logic                  coal_hit;
  logic [WBUF_IDX_W-1:0] coal_idx;
  always_comb begin
    coal_hit = 1'b0;
    coal_idx = '0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      if (wr_t2[i]) begin
        coal_hit = 1'b1;
        coal_idx = WBUF_IDX_W'(i);
      end
  end

  assign wr_coalesced = wr_valid && coal_hit;

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ent_valid <= '0;
    end else begin
      if (drain_valid) ent_valid[drain_idx] <= 1'b0;

      if (wr_valid) begin
        if (coal_hit) begin
          ent_be[coal_idx] <= ent_be[coal_idx] | wr_be;
        end else if (wr_ready) begin
          ent_valid[free_idx] <= 1'b1;
          ent_tag  [free_idx] <= wr_tag;
          ent_hash [free_idx] <= wr_hash;
          ent_be   [free_idx] <= wr_be;
        end
      end
    end
  end

  always_comb begin
    occupancy = '0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      if (ent_valid[i]) occupancy = occupancy + 1'b1;
  end

  always_comb begin
    dbg_valid = ent_valid;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++) begin
      dbg_tag    [i] = ent_tag[i];
      dbg_hash   [i] = ent_hash[i];
      dbg_be_full[i] = &ent_be[i];
    end
  end

endmodule
