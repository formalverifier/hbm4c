// ---------------------------------------------------------------------------
// hbm4_pc_slice -- one complete pseudo-channel controller.
//
// This is the block replicated 256 times.  Everything in it is private to one
// pseudo-channel: its own queue, its own bank state, its own command buses.
// Nothing is shared between slices except the CSR bus and refresh phase.
//
// The ROW-HIT LOGIC lives here rather than in any leaf block, because it is the
// one decision that needs the pool and the bank state TOGETHER:
//
//   bank ACTIVE on the row the head wants  -> the column command may go
//   bank IDLE                              -> ACT it, to the head's row
//   bank ACTIVE on a DIFFERENT row         -> PRE it first
//
// That three-way split is what turns "a request exists" into "a command is
// legal".  The pool knows what is wanted, the bank state knows what is open,
// and neither alone can decide anything -- which is exactly why this logic
// could not have been written inside either of them.
//
// Note what is deliberately NOT serialised: the row and column arbiters run in
// the same cycle on separate buses (constraint C3).  Any structure here that
// made them take turns would silently halve command bandwidth.
// ---------------------------------------------------------------------------
module hbm4_pc_slice
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned RD_FIFO_DEPTH = 32
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- configuration -------------------------------------------------------
  input  timing_cfg_t           tcfg,
  input  local_cfg_t            lcfg,
  input  logic [15:0]           cfg_wr_hi,
  input  logic [15:0]           cfg_wr_lo,
  input  logic [15:0]           cfg_wr_burst,
  input  logic [31:0]           cfg_wr_age_limit,
  input  logic                  cfg_wr_preempt,
  input  logic [15:0]           cfg_refi_pb,
  input  logic [15:0]           cfg_refi_phase,
  input  logic [7:0]            cfg_rfm_thresh,
  input  logic [7:0]            cfg_raa_imt,
  input  logic                  cfg_rfm_en,

  // BOOT GATE.  Low until the stack's training sequencer has finished; while it
  // is low this slice issues NOTHING and reports itself idle.
  //
  // Without it the design has no working boot order at all.  The refresh engine
  // issues opportunistically whenever a bank is idle, and after reset every bank
  // is idle -- so the slice starts driving REF on the row bus immediately, and:
  //   * if `busy` excludes refresh, the stack top thinks the slice is quiesced
  //     and puts the sequencer's MRS on the same bus in the same cycle;
  //   * if `busy` includes refresh (which is what it means), the stack top never
  //     sees a quiet slice and the sequencer never runs -- boot deadlocks.
  // Both orderings are broken, which is what makes this structural rather than a
  // scheduling tweak: the slice must be OFF the bus until training completes.
  input  logic                  cmd_en,

  // ---- NHI -----------------------------------------------------------------
  input  logic                  req_valid,
  input  logic                  req_wr,
  input  logic [PC_BLK_W-1:0]   req_blk,
  input  tag_t                  req_tag,
  input  qos_t                  req_qos,
  input  logic [AG_BYTES*8-1:0] req_data,   // write data, valid with the request
  output logic                  req_credit,

  output logic                  rsp_valid,
  input  logic                  rsp_ready,
  output tag_t                  rsp_tag,
  output logic [DFI_DATA_W-1:0] rsp_data,
  output logic [1:0]            rsp_err,
  output logic                  rsp_wack,

  // ---- DFI -----------------------------------------------------------------
  output logic [1:0]            dfi_row_valid,
  output row_cmd_e [1:0]        dfi_row_cmd,
  output bank_t [1:0]           dfi_row_bank,
  output row_t [1:0]            dfi_row_addr,
  output logic                  dfi_wrdata_valid,
  output logic [AG_BYTES*8-1:0] dfi_wrdata,
  output logic [1:0]            dfi_col_valid,
  output col_cmd_e [1:0]        dfi_col_cmd,
  output bank_t [1:0]           dfi_col_bank,
  output col_t [1:0]            dfi_col_addr,
  input  logic                  dfi_rddata_valid,
  input  logic [DFI_DATA_W-1:0] dfi_rddata,
  input  logic [ECC_FIELD_W-1:0] dfi_rdcode,

  // ---- status / observability ---------------------------------------------
  output logic                  busy,
  output logic [TQ_IDX_W:0]     occupancy,
  output logic                  err_rdfifo,
  output logic                  err_stall,
  output logic                  sts_turning,      // bus is mid-turnaround
  output logic signed [5:0]     sts_ref_debt,
  output logic [15:0]           sts_lecc_ce,
  output logic [15:0]           sts_lecc_ue,
  output logic                  sts_lecc_thresh,
  output logic [$clog2(RD_FIFO_DEPTH):0] sts_rdfifo_level
);

  // =========================================================================
  // Front end: NHI -> address decode -> transaction pool
  // =========================================================================
  logic                  core_valid, core_wr;
  logic [PC_BLK_W-1:0]   core_blk;
  tag_t                  core_tag;
  qos_t                  core_qos;
  logic                  cmpl_valid, cmpl_wr, cmpl_ready;
  tag_t                  cmpl_tag;
  logic [1:0]            cmpl_err;
  logic [DFI_DATA_W-1:0] cmpl_data;

  hbm4_nhi_target u_nhi (
    .clk (clk), .rst_n (rst_n),
    .req_valid (req_valid), .req_wr (req_wr), .req_blk (req_blk),
    .req_tag (req_tag), .req_qos (req_qos), .req_credit (req_credit),
    .core_valid (core_valid), .core_wr (core_wr), .core_blk (core_blk),
    .core_tag (core_tag), .core_qos (core_qos),
    .cmpl_valid (cmpl_valid), .cmpl_tag (cmpl_tag), .cmpl_wr (cmpl_wr),
    .cmpl_data (cmpl_data), .cmpl_err (cmpl_err), .cmpl_ready (cmpl_ready),
    .rsp_valid (rsp_valid), .rsp_ready (rsp_ready), .rsp_tag (rsp_tag),
    .rsp_data (rsp_data), .rsp_err (rsp_err), .rsp_wack (rsp_wack),
    .outstanding (occupancy), .stall_err (err_stall)
  );

  logic     dec_valid, dec_oor;
  pc_addr_t dec_addr;
  bank_t    dec_bank;

  hbm4_addr_decode u_dec (
    .clk (clk), .rst_n (rst_n),
    .in_valid (core_valid), .in_pc_blk (core_blk), .cfg (lcfg),
    .out_valid (dec_valid), .out_addr (dec_addr), .out_bank (dec_bank),
    .out_range_err (dec_oor)
  );

  // The decode is two cycles deep (the div30), so the fields that do not go
  // through it have to be delayed to match.  Getting this wrong pairs a
  // request with another request's tag -- data delivered to the wrong
  // consumer, with nothing to detect it.
  logic dw_wr  [2];
  tag_t dw_tag [2];
  qos_t dw_qos [2];
  always_ff @(posedge clk) begin
    dw_wr[0] <= core_wr;  dw_tag[0] <= core_tag;  dw_qos[0] <= core_qos;
    dw_wr[1] <= dw_wr[0]; dw_tag[1] <= dw_tag[0]; dw_qos[1] <= dw_qos[0];
  end

  logic              pool_alloc_ready;
  logic [N_BANK-1:0] pend_rd, pend_wr, pend_urgent;
  row_t              head_row  [N_BANK];
  row_t              head_wrow [N_BANK];
  pc_addr_t          issue_addr;
  tag_t              issue_tag;
  logic [TQ_IDX_W:0] pool_occ, pool_occ_lists;

  logic  col_fire;
  dir_e  dir;
  bank_t col_bank;

  hbm4_txn_pool u_pool (
    .clk (clk), .rst_n (rst_n),
    .alloc_valid (dec_valid && !dec_oor), .alloc_wr (dw_wr[1]),
    .alloc_addr (dec_addr), .alloc_bank (dec_bank),
    .alloc_tag (dw_tag[1]), .alloc_qos (dw_qos[1]),
    .alloc_ready (pool_alloc_ready),
    .pend_rd (pend_rd), .pend_wr (pend_wr), .pend_urgent (pend_urgent),
    .head_row (head_row), .head_wrow (head_wrow),
    .issue_valid (col_fire && !raw_block), .issue_bank (col_bank), .issue_dir (dir),
    .issue_addr (issue_addr), .issue_tag (issue_tag),
    .occupancy (pool_occ), .occ_lists (pool_occ_lists)
  );

  // =========================================================================
  // Bank state, refresh, timing
  // =========================================================================
  row_issue_t        row_iss;
  col_issue_t        col_iss;
  bank_st_e          bk_st    [N_BANK];
  row_t              open_row [N_BANK];
  logic [N_BANK-1:0] is_active;

  hbm4_bank_state u_bank (
    .clk (clk), .rst_n (rst_n), .row_iss (row_iss), .col_iss (col_iss),
    .st (bk_st), .open_row (open_row), .is_active (is_active)
  );

  logic              ref_req, ref_urgent, rfm_req, ref_ack, rfm_ack;
  bank_t             ref_bank, rfm_bank;
  logic [N_BANK-1:0] refresh_block;
  logic [N_BANK-1:0] ref_want_pre;   // banks refresh needs closed
  logic signed [5:0]      dbg_debt;
  logic [N_BANK-1:0][7:0] dbg_raa;

  hbm4_refresh u_ref (
    .clk (clk), .rst_n (rst_n), .tcfg (tcfg),
    .cfg_refi_pb (cfg_refi_pb), .cfg_refi_phase (cfg_refi_phase), .cfg_rfm_thresh (cfg_rfm_thresh),
    .cfg_raa_imt (cfg_raa_imt), .cfg_rfm_en (cfg_rfm_en),
    .act_valid (row_iss.valid && (row_iss.cmd == ROW_ACT)),
    .act_bank (row_iss.bank), .bank_idle (~is_active),
    .ref_req (ref_req), .ref_urgent (ref_urgent), .ref_bank (ref_bank),
    .rfm_req (rfm_req), .rfm_bank (rfm_bank),
    .ref_ack (ref_ack), .rfm_ack (rfm_ack),
    .refresh_block (refresh_block), .ref_want_pre (ref_want_pre),
    .dbg_debt (dbg_debt), .dbg_raa (dbg_raa)
  );

  logic [N_BANK-1:0] act_ok, pre_ok, rd_ok, wr_ok;

  hbm4_timing_engine u_timing (
    .clk (clk), .rst_n (rst_n), .tcfg (tcfg),
    .row_iss (row_iss), .col_iss (col_iss), .refresh_block (refresh_block),
    .act_ok (act_ok), .pre_ok (pre_ok), .rd_ok (rd_ok), .wr_ok (wr_ok)
  );

  // =========================================================================
  // ROW-HIT LOGIC -- the join between "what is wanted" and "what is open"
  // =========================================================================
  logic [N_BANK-1:0] hit_rd, hit_wr, want_act, want_pre;
  row_t [N_BANK-1:0] want_row;

  always_comb begin
    for (int unsigned b = 0; b < N_BANK; b++) begin
      automatic row_t rrow = (dir == DIR_WRITE) ? head_wrow[b] : head_row[b];
      automatic logic pend = (dir == DIR_WRITE) ? pend_wr[b]   : pend_rd[b];

      // A column command is a candidate ONLY when the bank is already open on
      // exactly the row its head wants.  Anything else needs the row bus first,
      // and offering it to the column arbiter would let it issue a read against
      // whatever row happens to be open -- valid data, wrong address.
      hit_rd[b] = pend_rd[b] && is_active[b] && (open_row[b] == head_row[b]);
      hit_wr[b] = pend_wr[b] && is_active[b] && (open_row[b] == head_wrow[b]);

      want_act[b] = pend && !is_active[b];
      // ref_want_pre is ORed in, not ANDed with `pend`: a bank that owes a
      // refresh must close whether or not the host wants anything from it.
      // Requiring a pending transaction here would leave an idle-but-open bank
      // refusing to close, and its refresh would never happen.
      want_pre[b] = (pend && is_active[b] && (open_row[b] != rrow))
                 || (ref_want_pre[b] && is_active[b]);
      want_row[b] = rrow;
    end
  end

  // =========================================================================
  // Arbitration
  // =========================================================================
  logic turning;

  hbm4_dir_fsm u_dir (
    .clk (clk), .rst_n (rst_n),
    .wr_hi (cfg_wr_hi), .wr_lo (cfg_wr_lo), .wr_burst_credit (cfg_wr_burst),
    .wr_age_limit (cfg_wr_age_limit), .wr_preempt_en (cfg_wr_preempt),
    .wr_occupancy (16'(pool_occ)), .rd_pending (|pend_rd), .wr_pending (|pend_wr),
    .raw_hazard (raw_block), .wr_oldest_age (32'd0), .urgent_rd (|pend_urgent),
    .rd_ok (rd_ok), .wr_ok (wr_ok), .col_issued (col_fire),
    .dir (dir), .turning (turning)
  );

  // =========================================================================
  // READ-AFTER-WRITE HAZARD -- hbm4_wbuf
  //
  // This module existed, was proved, and was WIRED TO NOTHING until Rev 1.1.
  // `raw_hazard` on the direction FSM was tied to 1'b0, so a read to an address
  // with a queued write issued straight to DRAM and returned the OLD data.
  // Silent corruption, no error anywhere -- the worst failure class this design
  // can have, and it passed lint, 40 formal proof tasks and 30 simulation tests
  // because every one of them was scoped to what was connected.
  //
  // ONE QUERY PORT, TWO USES, NO CONFLICT.  `dir` is either READ or WRITE in any
  // given cycle, and the two uses are disjoint on exactly that boundary:
  //   dir == WRITE: the issued write is looked up to get its index, and drained.
  //   dir == READ : the issued read is checked against every pending write.
  // So the CAM is queried with `issue_addr` regardless, and only the
  // interpretation of the result changes.
  //
  // A hazarding read is SUPPRESSED -- neither issued to DRAM nor popped from the
  // pool -- and `raw_hazard` forces the direction FSM to drain writes. The read
  // is re-granted later and by then the blocking write is gone. Blocking without
  // forcing the drain would livelock: the arbiter would re-grant the same read
  // forever while the write it waits on never issues.
  // Write data is held from request until the column write issues.  Indexed by
  // TAG, which the interface spec already requires to be unique among
  // outstanding transactions -- so this needs no change to the transaction pool.
  logic [AG_BYTES*8-1:0] wdata_out;
  logic                  err_wdata;
  logic [TQ_DEPTH-1:0]   wdata_dbg;

  hbm4_wdata_ram u_wdata (
    .clk (clk), .rst_n (rst_n),
    .wr_valid (req_valid && req_wr), .wr_tag (req_tag), .wr_data (req_data),
    .rd_valid (col_fire && !raw_block && (dir == DIR_WRITE)),
    .rd_tag (issue_tag), .rd_data (wdata_out),
    .err_no_data (err_wdata), .dbg_written (wdata_dbg)
  );

  logic raw_hazard, raw_forward, raw_block;
  logic wbuf_ready, wbuf_coalesced;
  logic [WBUF_DEPTH-1:0]                 wb_dbg_valid, wb_dbg_be_full;
  logic [WBUF_DEPTH-1:0][HAZ_TAG_W-1:0]  wb_dbg_tag;
  logic [WBUF_DEPTH-1:0][HAZ_HASH_W-1:0] wb_dbg_hash;
  logic [WBUF_IDX_W-1:0] raw_idx;
  logic [WBUF_IDX_W:0]   wbuf_occ;

  hbm4_wbuf u_wbuf (
    .clk (clk), .rst_n (rst_n),
    .wr_valid (dec_valid && !dec_oor && dw_wr[1]),
    .wr_bank  (dec_bank),
    .wr_row   (dec_addr.row),
    .wr_col   (dec_addr.col),
    .wr_be    ('1),                 // NHI is block-granular; no partial writes
    // wr_ready cannot go low here, and the reason is structural rather than
    // hopeful: the NHI grants exactly TQ_DEPTH credits, so at most TQ_DEPTH
    // transactions are ever outstanding, and WBUF_DEPTH (128 production, 4
    // reduced) is >= TQ_DEPTH (64 production, 4 reduced) in every configuration.
    // It is monitored rather than ignored -- if a future config breaks that
    // inequality, a write would silently stop being tracked for hazards and RAW
    // corruption would return, so this deserves to be visible.
    .wr_ready (wbuf_ready),
    .wr_coalesced (wbuf_coalesced),
    .rd_valid (col_fire),
    .rd_bank  (col_bank),
    .rd_row   (issue_addr.row),
    .rd_col   (issue_addr.col),
    .rd_hazard (raw_hazard), .rd_forward (raw_forward), .rd_haz_idx (raw_idx),
    .drain_valid (col_fire && (dir == DIR_WRITE)),
    .drain_idx   (raw_idx),
    .occupancy (wbuf_occ),
    .dbg_valid (wb_dbg_valid), .dbg_tag (wb_dbg_tag),
    .dbg_be_full (wb_dbg_be_full), .dbg_hash (wb_dbg_hash)
  );

  // Suppress only READS. A write cycle's query is a drain lookup, and its
  // rd_hazard result is meaningless -- a write always matches itself.
  assign raw_block = col_fire && (dir == DIR_READ) && raw_hazard;

  logic [N_BANK-1:0] col_grant;

  // The boot gate is applied to the arbiters' LEGALITY inputs, not to the DFI
  // outputs.  Gating the outputs would leave the arbiters granting and the
  // refresh engine acking into a bus that goes nowhere -- the controller would
  // believe it had refreshed banks it never touched, and come out of boot with
  // its model of the DRAM already wrong.  Suppressing legality means no grant is
  // ever produced, so no state advances at all.
  // The *_ok signals are PER-BANK vectors, so the gate is a replicated mask.
  logic [N_BANK-1:0] g_rd_ok, g_wr_ok, g_act_ok, g_pre_ok;
  logic              g_ref_req, g_rfm_req;
  assign g_rd_ok   = rd_ok   & {N_BANK{cmd_en}};
  assign g_wr_ok   = wr_ok   & {N_BANK{cmd_en}};
  assign g_act_ok  = act_ok  & {N_BANK{cmd_en}};
  assign g_pre_ok  = pre_ok  & {N_BANK{cmd_en}};
  assign g_ref_req = ref_req && cmd_en;
  assign g_rfm_req = rfm_req && cmd_en;

  hbm4_col_arb u_colarb (
    .clk (clk), .rst_n (rst_n), .dir (dir),
    .rd_ok (g_rd_ok), .wr_ok (g_wr_ok),
    .pend_rd (hit_rd), .pend_wr (hit_wr), .pend_urgent (pend_urgent),
    .grant (col_grant), .grant_valid (col_fire), .grant_bank (col_bank)
  );

  hbm4_row_arb u_rowarb (
    .clk (clk), .rst_n (rst_n),
    .act_ok (g_act_ok), .pre_ok (g_pre_ok),
    .want_act (want_act), .want_pre (want_pre), .want_row (want_row),
    .ref_req (g_ref_req), .ref_urgent (ref_urgent), .ref_bank (ref_bank),
    .rfm_req (g_rfm_req), .rfm_bank (rfm_bank),
    .ref_ack (ref_ack), .rfm_ack (rfm_ack), .row_iss (row_iss)
  );

  always_comb begin
    col_iss = '{valid: col_fire && !raw_block,
                cmd:   (dir == DIR_WRITE) ? COL_WR : COL_RD,
                bank:  col_bank,
                col:   issue_addr.col};
  end

  // =========================================================================
  // DFI and the read return path
  // =========================================================================
  logic                  rd_valid;
  tag_t                  rd_tag;
  logic [DFI_DATA_W-1:0] rd_data;
  logic                  rdfifo_of, rdfifo_uf, rdfifo_limit;
  logic [$clog2(RD_FIFO_DEPTH):0] rdfifo_level;

  hbm4_dfi_adapter #(.RD_FIFO_DEPTH(RD_FIFO_DEPTH)) u_dfi (
    .clk (clk), .rst_n (rst_n),
    .row_iss (row_iss), .col_iss (col_iss), .col_tag (issue_tag),
    .dfi_row_valid (dfi_row_valid), .dfi_row_cmd (dfi_row_cmd),
    .dfi_row_bank (dfi_row_bank), .dfi_row_addr (dfi_row_addr),
    .dfi_col_valid (dfi_col_valid), .dfi_col_cmd (dfi_col_cmd),
    .dfi_col_bank (dfi_col_bank), .dfi_col_addr (dfi_col_addr),
    .dfi_wrdata_valid (dfi_wrdata_valid), .dfi_wrdata (dfi_wrdata),
    .wr_data (wdata_out),
    .dfi_rddata_valid (dfi_rddata_valid), .dfi_rddata (dfi_rddata),
    .rd_valid (rd_valid), .rd_tag (rd_tag), .rd_data (rd_data),
    .rdfifo_overflow (rdfifo_of), .rdfifo_underflow (rdfifo_uf),
    .rdfifo_level (rdfifo_level), .rdfifo_at_limit (rdfifo_limit)
  );

  assign err_rdfifo = rdfifo_of || rdfifo_uf;

  // Link ECC sits on the return path, between the PHY and the host.
  logic                  lecc_valid, lecc_retry;
  logic [DFI_DATA_W-1:0] lecc_data;
  logic [1:0]            lecc_err;
  logic [15:0]           lecc_ce, lecc_ue;
  logic                  lecc_thresh;
  logic [1:0]            lecc_retries;
  tqidx_t                lecc_out_idx, lecc_retry_idx;

  // RETRY IS DISABLED AT THIS INTEGRATION LEVEL, deliberately.
  //
  // hbm4_link_ecc suppresses out_valid while a retry is outstanding, expecting
  // something to re-issue the read.  That re-issue path does not exist yet: it
  // needs the pool entry to stay allocated past issue so the request can be
  // replayed, which the pool does not currently do.
  //
  // Wiring retry_req to nothing while leaving retry ENABLED would suppress the
  // completion and never replay it -- the transaction would simply never
  // finish, and the host would wait forever with no error anywhere.  A HANG.
  //
  // With retry off, a link UE is escalated immediately: less available, but
  // correct and visible.  Tracked as OPEN-9; found by lint flagging retry_req
  // as unconnected.
  hbm4_link_ecc #(.RETRY_MAX(3)) u_lecc (
    .clk (clk), .rst_n (rst_n),
    .cfg_ce_thresh (16'hFFFF), .cfg_retry_en (1'b0),
    .rx_valid (rd_valid), .rx_data (rd_data), .rx_code (dfi_rdcode),
    .rx_idx (tqidx_t'(rd_tag)),
    .out_valid (lecc_valid), .out_data (lecc_data), .out_idx (lecc_out_idx),
    .out_err (lecc_err),
    .retry_req (lecc_retry), .retry_idx (lecc_retry_idx), .retry_ack (1'b1),
    .ce_count (lecc_ce), .ue_count (lecc_ue), .thresh_irq (lecc_thresh),
    .dbg_retries (lecc_retries)
  );

  // Writes complete at issue; reads complete when their data returns.  A read
  // and a write can therefore complete in the same cycle -- the read wins and
  // the write is deferred, because the read has data that cannot be regenerated
  // whereas the write completion is only an acknowledgement.
  logic wack_pending;
  tag_t wack_tag;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wack_pending <= 1'b0;
    end else begin
      if (col_fire && (dir == DIR_WRITE) && lecc_valid) begin
        wack_pending <= 1'b1;
        wack_tag     <= issue_tag;
      end else if (wack_pending && cmpl_ready && !lecc_valid) begin
        wack_pending <= 1'b0;
      end
    end
  end

  always_comb begin
    if (lecc_valid) begin
      cmpl_valid = 1'b1;
      cmpl_tag   = rd_tag;
      cmpl_wr    = 1'b0;
      cmpl_data  = lecc_data;
      cmpl_err   = lecc_err;
    end else if (wack_pending) begin
      cmpl_valid = 1'b1;
      cmpl_tag   = wack_tag;
      cmpl_wr    = 1'b1;
      cmpl_data  = '0;
      cmpl_err   = 2'd0;
    end else begin
      cmpl_valid = col_fire && (dir == DIR_WRITE);
      cmpl_tag   = issue_tag;
      cmpl_wr    = 1'b1;
      cmpl_data  = '0;
      cmpl_err   = 2'd0;
    end
  end

  // BUSY MEANS "I AM DRIVING, OR WANT TO DRIVE, THE DRAM BUSES."
  //
  // It was `pool_occ != 0` -- host transactions only.  That is not what the
  // level above uses it for: hbm4_stack_top computes `quiesced = !stack_busy`
  // and hands the command buses to the training sequencer on the strength of it.
  // The refresh engine issues opportunistically whenever a bank is idle, which
  // includes the entire boot window, so `quiesced` could be true while this
  // slice was actively driving REF on the row bus -- and the sequencer would
  // put an MRS on the same bus in the same cycle.
  //
  // P-SEQ-1 proves the sequencer never drives while `slices_quiesced` is low.
  // It cannot prove that `slices_quiesced` MEANS anything, because the meaning
  // lives on the other side of a module boundary.  That gap is why this was
  // found by simulating the assembled slice and not by any block proof.
  assign busy             = cmd_en
                         && ((pool_occ != '0)
                             || |dfi_row_valid || |dfi_col_valid
                             || ref_req || rfm_req);
  assign sts_turning      = turning;
  assign sts_ref_debt     = dbg_debt;
  assign sts_lecc_ce      = lecc_ce;
  assign sts_lecc_ue      = lecc_ue;
  assign sts_lecc_thresh  = lecc_thresh;
  assign sts_rdfifo_level = rdfifo_level;

  // Signals read only by assertions or intentionally left open.
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, pool_alloc_ready, pool_occ_lists, col_grant,
                   raw_forward, wbuf_occ, wbuf_ready, wbuf_coalesced,
                   err_wdata, wdata_dbg,
                   wb_dbg_valid, wb_dbg_tag, wb_dbg_be_full, wb_dbg_hash,
                   rdfifo_limit, lecc_retry, lecc_out_idx, lecc_retry_idx, lecc_retries,
                   dbg_raa, issue_addr, bk_st[0]};
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef FORMAL
  // The NHI credit scheme guarantees at most TQ_DEPTH outstanding, so the pool
  // can never be asked for an entry it does not have.  Asserted rather than
  // assumed: if the credit accounting ever drifts, a dropped allocation is
  // silent -- the request simply never completes.
  always_ff @(posedge clk)
    if (rst_n && dec_valid && !dec_oor)
      a_pool_has_room: assert (pool_alloc_ready);
`endif

endmodule
