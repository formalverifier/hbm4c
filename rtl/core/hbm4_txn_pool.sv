// ---------------------------------------------------------------------------
// hbm4_txn_pool -- transaction storage and per-bank scheduling lists.
//
// Holds TQ_DEPTH in-flight requests and files each one into a per-bank,
// per-direction FIFO on arrival.  Because the address map picks the bank
// deterministically, filing is free -- no search, no content-addressable
// memory, no comparator tree.  Only the 32 list HEADS are ever arbitration
// candidates, so the arbiter sees 32 bits, not 64 entries.
//
// Depth: TQ_DEPTH must cover tRC (43 core clocks) of continuous issue.  A
// shallower pool lets a bank stalling on a row cycle drain the queue, and the
// column bus goes idle -- which constraint C1 says is bandwidth you never get
// back.
//
// Head mirroring: h_row/h_col/h_tag/h_qos shadow the head entry of each list.
// Reading entry[head[bank][dir]] combinationally instead would be a 64-entry
// mux per list, 64 times over.  The mirror costs one extra read port, updated
// only when a list is popped.
//
// NOT implemented here (Rev 0.6): GROUP_HOIST_EN, which lets a newer same-open-
// row group jump ahead of an older group in the same list.  Plain FIFO order
// is correct, and under the STREAM address map consecutive accesses to one
// pseudo-channel go to DIFFERENT banks, so same-bank head-of-line blocking is
// rare.  It matters for random traffic; see docs/02-architecture.md 8.2.
// ---------------------------------------------------------------------------
module hbm4_txn_pool
  import hbm4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  // ---- allocate (pipeline stage E1b) --------------------------------------
  input  logic              alloc_valid,
  input  logic              alloc_wr,
  input  pc_addr_t          alloc_addr,
  input  bank_t             alloc_bank,
  input  tag_t              alloc_tag,
  input  qos_t              alloc_qos,
  output logic              alloc_ready,      // a free entry exists

  // ---- candidate status (to the two arbiters) ------------------------------
  output logic [N_BANK-1:0] pend_rd,
  output logic [N_BANK-1:0] pend_wr,
  output logic [N_BANK-1:0] pend_urgent,
  output row_t              head_row  [N_BANK],   // read-list head row
  output row_t              head_wrow [N_BANK],   // write-list head row

  // ---- issue (from the column arbiter) -------------------------------------
  input  logic              issue_valid,
  input  bank_t             issue_bank,
  input  dir_e              issue_dir,
  output pc_addr_t          issue_addr,
  output tag_t              issue_tag,

  output logic [TQ_IDX_W:0] occupancy,
  // Sum of all per-list counts.  Exposed as a perf/debug counter (see
  // docs/04-programming-guide.md 3.2, QUEUE_OCC) and used by formal: it must
  // always equal `occupancy`, which is the invariant that catches entry leaks
  // and double-frees.  Deriving it here also keeps the property free of
  // hierarchical references into unpacked arrays, which Yosys cannot resolve.
  output logic [TQ_IDX_W:0] occ_lists
);

  // Lists are indexed 1-D by {bank, dir} rather than as a 2-D unpacked array.
  // NL is 2, so the index is a plain concatenation -- and 1-D keeps the array
  // usable from a formal wrapper, since 2-D unpacked arrays cannot be
  // referenced across a hierarchy boundary by Yosys.
  localparam int unsigned NL   = 2;                 // read list, write list
  localparam int unsigned NLST = N_BANK * NL;
  localparam int unsigned LW   = $clog2(NLST);

  function automatic logic [LW-1:0] lidx(input bank_t b, input logic w);
    return LW'({b, w});
  endfunction

  // ---- entry storage -------------------------------------------------------
  logic     [TQ_DEPTH-1:0] ent_valid;
  // No ent_wr field: an entry's direction is implied by WHICH LIST it is in,
  // so storing it again would be duplicated state (TQ_DEPTH bits per
  // pseudo-channel, 16 kbit across the system) and a second source of truth.
  pc_addr_t                ent_addr [TQ_DEPTH];
  tag_t                    ent_tag  [TQ_DEPTH];
  qos_t                    ent_qos  [TQ_DEPTH];
  tqidx_t                  ent_next [TQ_DEPTH];

  // ---- list state ----------------------------------------------------------
  tqidx_t             l_head [NLST];
  tqidx_t             l_tail [NLST];
  logic [TQ_IDX_W:0]  l_cnt  [NLST];
  // mirror of the head entry, so the arbiters never index the entry array
  pc_addr_t           h_addr [NLST];
  tag_t               h_tag  [NLST];
  qos_t               h_qos  [NLST];

  // ---- free-entry selection ------------------------------------------------
  logic [TQ_DEPTH-1:0] free_mask, free_onehot;
  tqidx_t              free_idx;

  assign free_mask   = ~ent_valid;
  assign free_onehot = free_mask & (~free_mask + {{(TQ_DEPTH-1){1'b0}}, 1'b1});
  assign alloc_ready = |free_mask;

  always_comb begin
    free_idx = '0;
    for (int unsigned i = 0; i < TQ_DEPTH; i++)
      if (free_onehot[i]) free_idx = tqidx_t'(i);
  end

  // ---- which list is touched this cycle ------------------------------------
  logic          do_alloc, do_issue;
  logic [LW-1:0] al, il;

  assign do_alloc = alloc_valid && alloc_ready;
  assign do_issue = issue_valid;
  assign al       = lidx(alloc_bank, alloc_wr);
  assign il       = lidx(issue_bank, issue_dir == DIR_WRITE);

  // Same list touched by both an allocate and an issue this cycle.
  logic same_list;
  assign same_list = do_alloc && do_issue && (al == il);

  // ---- head entry being popped ---------------------------------------------
  tqidx_t pop_idx, pop_next;
  assign pop_idx  = l_head[il];
  assign pop_next = ent_next[pop_idx];

  assign issue_addr = h_addr[il];
  assign issue_tag  = h_tag [il];

  // ---- sequential ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ent_valid <= '0;
      for (int unsigned i = 0; i < NLST; i++) begin
        l_head[i] <= '0;
        l_tail[i] <= '0;
        l_cnt [i] <= '0;
      end
    end else begin
      // ---- issue: free the entry, advance the head -------------------------
      if (do_issue) begin
        ent_valid[pop_idx] <= 1'b0;
        l_cnt[il] <= l_cnt[il] - 1'b1;
        // The new head is the next link -- unless this same cycle also
        // allocates into a list that is now empty, handled below.
        if (!same_list || (l_cnt[il] > 1)) begin
          l_head[il] <= pop_next;
          h_addr[il] <= ent_addr[pop_next];
          h_tag [il] <= ent_tag [pop_next];
          h_qos [il] <= ent_qos [pop_next];
        end
      end

      // ---- allocate --------------------------------------------------------
      if (do_alloc) begin
        ent_valid[free_idx] <= 1'b1;
        ent_addr [free_idx] <= alloc_addr;
        ent_tag  [free_idx] <= alloc_tag;
        ent_qos  [free_idx] <= alloc_qos;

        l_tail[al] <= free_idx;
        l_cnt [al] <= same_list ? l_cnt[al]            // +1 and -1 cancel
                                : l_cnt[al] + 1'b1;

        if ((l_cnt[al] == '0) || (same_list && (l_cnt[al] == 1))) begin
          // list is (or becomes) empty: the new entry is also the head
          l_head[al] <= free_idx;
          h_addr[al] <= alloc_addr;
          h_tag [al] <= alloc_tag;
          h_qos [al] <= alloc_qos;
        end else begin
          ent_next[l_tail[al]] <= free_idx;
        end
      end
    end
  end

  // ---- candidate vectors ---------------------------------------------------
  always_comb begin
    for (int unsigned b = 0; b < N_BANK; b++) begin
      pend_rd    [b] = (l_cnt[lidx(bank_t'(b), 1'b0)] != '0);
      pend_wr    [b] = (l_cnt[lidx(bank_t'(b), 1'b1)] != '0);
      pend_urgent[b] = ((l_cnt[lidx(bank_t'(b), 1'b0)] != '0)
                        && (h_qos[lidx(bank_t'(b), 1'b0)] == QOS_URGENT))
                    || ((l_cnt[lidx(bank_t'(b), 1'b1)] != '0)
                        && (h_qos[lidx(bank_t'(b), 1'b1)] == QOS_URGENT));
      head_row   [b] = h_addr[lidx(bank_t'(b), 1'b0)].row;
      head_wrow  [b] = h_addr[lidx(bank_t'(b), 1'b1)].row;
    end
  end

  always_comb begin
    occupancy = '0;
    for (int unsigned i = 0; i < TQ_DEPTH; i++)
      if (ent_valid[i]) occupancy = occupancy + 1'b1;
  end

  always_comb begin
    occ_lists = '0;
    for (int unsigned i = 0; i < NLST; i++)
      occ_lists = occ_lists + l_cnt[i];
  end

`ifdef FORMAL
  // Local invariant: an entry is never issued from an empty list.
  always_ff @(posedge clk)
    if (rst_n && do_issue)
      a_issue_nonempty: assert (l_cnt[il] != '0);
`endif

endmodule
