// ---------------------------------------------------------------------------
// fv_wbuf -- P-WB-*.
//
// The headline is P-WB-1: the two-tier hazard check has NO FALSE NEGATIVES.
//
// Why this must be proved rather than tested.  A false negative lets a read
// overtake a pending write to the same block, so the read returns the OLD
// data.  There is no error indication -- the data is well formed, it is simply
// the wrong version, so ECC is silent and the scoreboard only catches it if
// the test happens to generate that exact address pair at that exact spacing.
// The tag space is 2^25 per pseudo-channel; a test samples it, a proof covers
// it.
//
// The structure makes false negatives impossible by construction (the hash is
// a pure function of the tag), which is exactly the kind of claim that is easy
// to state, easy to believe, and easy to break with one careless edit -- e.g.
// hashing something that is not the full tag, or comparing the hash of a
// stale register.  That is what this proof pins down.
// ---------------------------------------------------------------------------
module fv_wbuf
  import hbm4_pkg::*;
(
  input logic                clk,
  input logic                rst_n,
  input logic                wr_valid,
  input bank_t               wr_bank,
  input row_t                wr_row,
  input col_t                wr_col,
  input logic [AG_BYTES-1:0] wr_be,
  input logic                rd_valid,
  input bank_t               rd_bank,
  input row_t                rd_row,
  input col_t                rd_col,
  input logic                drain_valid,
  input logic [WBUF_IDX_W-1:0] drain_idx
);

  logic                  wr_ready, wr_coalesced, rd_hazard, rd_forward;
  logic [WBUF_IDX_W-1:0] rd_haz_idx;
  logic [WBUF_IDX_W:0]   occupancy;
  logic [WBUF_DEPTH-1:0]                b_valid, b_be_full;
  logic [WBUF_DEPTH-1:0][HAZ_TAG_W-1:0]  b_tag;
  logic [WBUF_DEPTH-1:0][HAZ_HASH_W-1:0] b_hash;

  hbm4_wbuf dut (
    .clk (clk), .rst_n (rst_n),
    .wr_valid (wr_valid), .wr_bank (wr_bank), .wr_row (wr_row), .wr_col (wr_col),
    .wr_be (wr_be), .wr_ready (wr_ready), .wr_coalesced (wr_coalesced),
    .rd_valid (rd_valid), .rd_bank (rd_bank), .rd_row (rd_row), .rd_col (rd_col),
    .rd_hazard (rd_hazard), .rd_forward (rd_forward), .rd_haz_idx (rd_haz_idx),
    .drain_valid (drain_valid), .drain_idx (drain_idx),
    .occupancy (occupancy),
    .dbg_valid (b_valid), .dbg_tag (b_tag), .dbg_be_full (b_be_full),
    .dbg_hash (b_hash)
  );

  // ---- reset (ASSUMPTION A1) ----------------------------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // Only drain entries that exist.  The direction FSM issues from the buffer,
  // so it never drains an empty slot.
  always @(*)
    if (f_past_valid && rst_n && drain_valid)
      assume (b_valid[drain_idx]);

  // ---- an INDEPENDENT model of "is this block pending?" --------------------
  // Deliberately does not use the DUT's hash at all.  It recomputes the tag
  // from the interface and compares against every valid entry's stored tag.
  // If the checker shared the hash, a broken hash would be invisible.
  // The reference model reads the DUT's PACKED observability outputs.  It never
  // touches the hash path, so a broken hash cannot hide from it -- which is the
  // whole point of P-WB-1.
  logic [HAZ_TAG_W-1:0] ref_rd_tag;
  assign ref_rd_tag = {rd_bank, rd_row, rd_col};

  logic ref_match;
  always_comb begin
    ref_match = 1'b0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      if (b_valid[i] && (b_tag[i] == ref_rd_tag)) ref_match = 1'b1;
  end

  // ---- strengthening invariant for k-induction ----------------------------
  //
  // Basecase passes without this, but INDUCTION does not: it starts from an
  // arbitrary state in which a stored hash disagrees with its stored tag.  The
  // design can never reach such a state -- both are written together, from the
  // same tag, in one cycle -- but the solver has no way to know that.  Stating
  // it is the standard k-induction strengthening step, and the verification
  // plan (06 4.8) budgets for exactly this.
  //
  // The fold is written out LONGHAND rather than calling the DUT's mk_hash().
  // A property that calls the function it is testing mutates along with it --
  // the same trap that made an earlier bank_of() property vacuous.
  function automatic logic [HAZ_HASH_W-1:0] ref_hash(input logic [HAZ_TAG_W-1:0] t);
    logic [HAZ_HASH_W-1:0] h;
    h = '0;
    for (int unsigned i = 0; i < HAZ_TAG_W; i++)
      h[i % HAZ_HASH_W] = h[i % HAZ_HASH_W] ^ t[i];
    return h;
  endfunction

  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      for (int unsigned i = 0; i < WBUF_DEPTH; i++)
        if (b_valid[i]) begin
          p_hash_matches_tag: assert (b_hash[i] == ref_hash(b_tag[i]));
        end
    end

  // ---- P-WB-1: NO FALSE NEGATIVES -----------------------------------------
  // If any valid entry holds this block, the hazard MUST be reported.  This is
  // the property that makes the cheap tier-1 filter safe.
  always @(posedge clk)
    if (f_past_valid && rst_n && rd_valid) begin
      p_no_false_negative: assert (ref_match == rd_hazard);
    end

  // ---- P-WB-2: forwarding is only ever done from a full-coverage entry -----
  // Forwarding a partially written block would return a mix of new bytes and
  // uninitialised ones -- silent corruption of the untouched bytes.
  always @(posedge clk)
    if (f_past_valid && rst_n && rd_forward) begin
      p_fwd_is_exact : assert (b_tag[rd_haz_idx] == ref_rd_tag);
      p_fwd_full_be  : assert (b_be_full[rd_haz_idx]);
      p_fwd_valid    : assert (b_valid[rd_haz_idx]);
    end

  // ---- P-WB-3: coalescing never creates a duplicate -----------------------
  // Two valid entries must never hold the same tag.  A duplicate means the
  // same block is written twice from two buffers, and which one lands last is
  // scheduling-dependent -- a data race with no error indication.
  logic dup;
  always_comb begin
    dup = 1'b0;
    for (int unsigned i = 0; i < WBUF_DEPTH; i++)
      for (int unsigned j = 0; j < WBUF_DEPTH; j++)
        if ((i != j) && b_valid[i] && b_valid[j]
            && (b_tag[i] == b_tag[j])) dup = 1'b1;
  end

  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_no_duplicate: assert (!dup);
    end

  // ---- P-WB-4: occupancy tracks reality -----------------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n) begin
      p_ready_correct: assert (wr_ready == (occupancy < (WBUF_IDX_W+1)'(WBUF_DEPTH)));
    end

  // ---- reachability --------------------------------------------------------
  // Without these the properties above could all hold vacuously in a buffer
  // that never accepts anything.
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_hazard   : cover (rd_hazard);
    c_forward  : cover (rd_forward);
    c_partial  : cover (rd_hazard && !rd_forward);   // must wait for the drain
    c_coalesce : cover (wr_coalesced);
    c_full     : cover (occupancy == (WBUF_IDX_W+1)'(WBUF_DEPTH));
  end

endmodule
