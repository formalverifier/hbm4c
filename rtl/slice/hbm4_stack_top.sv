// ---------------------------------------------------------------------------
// hbm4_stack_top -- one HBM4 stack: 64 pseudo-channel slices plus the per-stack
// global block (CSR, training sequencer, power management).
//
// The slices share almost nothing.  That is the architecture, not an
// accident: an HBM4 pseudo-channel has its own command buses, bank state and
// timing, so any shared resource here would be inventing a dependency the
// device does not have -- and would show up as one slice stalling another.
//
// What IS shared, and why each has to be:
//
//   CSR bus          one driver, one aperture, one lock (docs/04 1.1)
//   training         the PHY is per-stack, so training is per-stack
//   power state      self-refresh takes the whole stack off the bus, so it
//                    needs every slice to vote idle
//   refresh PHASE    the one piece of genuine cross-slice coordination -- see
//                    below
//
// REFRESH PHASE is assigned here rather than left to each slice.  64 slices
// resetting their interval counters together refresh in lockstep: a correlated
// current spike across the package and a correlated bandwidth notch.  Spreading
// them costs nothing -- a different reset value, not extra logic -- and it only
// works if something above the slice hands out the offsets.
// ---------------------------------------------------------------------------
module hbm4_stack_top
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned STACK_ID      = 0,
  parameter int unsigned BOOT_DELAY_SHIFT = 0,   // simulation only; 0 in silicon
  parameter int unsigned RD_FIFO_DEPTH = 32
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // ---- configuration, from the supervisor ---------------------------------
  input  timing_cfg_t                tcfg,
  input  local_cfg_t                 lcfg,
  input  logic [15:0]                cfg_wr_hi,
  input  logic [15:0]                cfg_wr_lo,
  input  logic [15:0]                cfg_wr_burst,
  input  logic [31:0]                cfg_wr_age_limit,
  input  logic                       cfg_wr_preempt,
  input  logic [15:0]                cfg_refi_pb,
  input  logic [7:0]                 cfg_rfm_thresh,
  input  logic [7:0]                 cfg_raa_imt,
  input  logic                       cfg_rfm_en,
  input  logic                       cfg_lp_en,
  input  logic [15:0]                cfg_pd_thresh,
  input  logic [15:0]                cfg_sr_thresh,

  // ---- boot ----------------------------------------------------------------
  input  logic                       boot_start,
  output logic                       boot_done,
  output logic                       boot_error,

  // ---- NHI, one port per pseudo-channel -----------------------------------
  input  logic [N_PC_PER_STACK-1:0]                  req_valid,
  input  logic [N_PC_PER_STACK-1:0]                  req_wr,
  input  logic [N_PC_PER_STACK-1:0][PC_BLK_W-1:0]    req_blk,
  input  logic [N_PC_PER_STACK-1:0][TAG_W-1:0]       req_tag,
  input  logic [N_PC_PER_STACK-1:0][QOS_W-1:0]       req_qos,
  input  logic [N_PC_PER_STACK-1:0][AG_BYTES*8-1:0] req_data,
  output logic [N_PC_PER_STACK-1:0]                  req_credit,

  output logic [N_PC_PER_STACK-1:0]                  rsp_valid,
  input  logic [N_PC_PER_STACK-1:0]                  rsp_ready,
  output logic [N_PC_PER_STACK-1:0][TAG_W-1:0]       rsp_tag,
  output logic [N_PC_PER_STACK-1:0][DFI_DATA_W-1:0]  rsp_data,
  output logic [N_PC_PER_STACK-1:0][1:0]             rsp_err,
  output logic [N_PC_PER_STACK-1:0]                  rsp_wack,

  // ---- DFI, one set per pseudo-channel ------------------------------------
  // The COMMAND PAYLOADS have to come out, not just the strobes.  An earlier
  // version wired only *_valid and left cmd/bank/addr open: the DRAM would see
  // a valid strobe carrying nothing.  Caught by lint flagging the empty pin
  // connections -- the same class of finding as the unconnected retry_req in
  // the slice, and the second time in this integration that an open output
  // would have been a silent functional failure.
  output logic [N_PC_PER_STACK-1:0][1:0]             dfi_row_valid,
  output logic [N_PC_PER_STACK-1:0][1:0][2:0]        dfi_row_cmd,
  output logic [N_PC_PER_STACK-1:0][1:0][BANK_W-1:0] dfi_row_bank,
  output logic [N_PC_PER_STACK-1:0][1:0][ROW_W-1:0]  dfi_row_addr,
  output logic [N_PC_PER_STACK-1:0]                  dfi_wrdata_valid,
  output logic [N_PC_PER_STACK-1:0][AG_BYTES*8-1:0] dfi_wrdata,
  output logic [N_PC_PER_STACK-1:0][1:0]             dfi_col_valid,
  output logic [N_PC_PER_STACK-1:0][1:0][2:0]        dfi_col_cmd,
  output logic [N_PC_PER_STACK-1:0][1:0][BANK_W-1:0] dfi_col_bank,
  output logic [N_PC_PER_STACK-1:0][1:0][COL_W-1:0]  dfi_col_addr,
  input  logic [N_PC_PER_STACK-1:0]                  dfi_rddata_valid,
  input  logic [N_PC_PER_STACK-1:0][DFI_DATA_W-1:0]  dfi_rddata,
  input  logic [N_PC_PER_STACK-1:0][ECC_FIELD_W-1:0] dfi_rdcode,

  // ---- boot-time command path ---------------------------------------------
  // MRS payload.  Broadcast to every pseudo-channel in the stack: mode-register
  // programming during init applies to the whole device, and a slice never
  // issues MRS, so this does not belong on the per-slice row bus.
  output logic [7:0]                 dfi_mrs_index,
  output logic [15:0]                dfi_mrs_opcode,

  // PHY control.  OP_PHY steps (CK start, reset, ZQ calibration, write
  // levelling, read training, lock) are directed at the PHY, not the DRAM, so
  // they leave on their own interface and the sequencer waits for phy_ack --
  // training steps take thousands of cycles and cannot be fire-and-forget.
  output logic                       phy_req,
  output logic [3:0]                 phy_op,
  output logic [23:0]                phy_arg,
  input  logic                       phy_ack,

  // ---- status --------------------------------------------------------------
  output logic                       stack_busy,
  output logic                       stack_err,
  output logic [1:0]                 lp_state
);

  // ---- per-slice status ----------------------------------------------------
  logic [N_PC_PER_STACK-1:0] slice_busy, slice_err_fifo, slice_err_stall;
  // Per-slice observability, aggregated for the supervisor's perf snapshot.
  logic [N_PC_PER_STACK-1:0][TQ_IDX_W:0]  s_occ;
  logic [N_PC_PER_STACK-1:0]              s_turning, s_thresh;
  logic signed [N_PC_PER_STACK-1:0][5:0]  s_debt;
  logic [N_PC_PER_STACK-1:0][15:0]        s_ce, s_ue;
  logic [N_PC_PER_STACK-1:0][$clog2(RD_FIFO_DEPTH):0] s_rdlvl;

  assign stack_busy = |slice_busy;
  assign stack_err  = (|slice_err_fifo) || (|slice_err_stall);

  // ---- training sequencer --------------------------------------------------
  // The slices must be off the command buses while it runs; P-SEQ-1 makes that
  // structural inside the sequencer, and `quiesced` is the signal it gates on.
  logic seq_busy, seq_done, seq_error, quiesced;
  logic [8:0]  seq_addr, seq_pc;
  logic [31:0] seq_data;
  logic        seq_op_valid;
  logic [3:0]  seq_op_code;
  logic [23:0] seq_op_arg;
  logic [31:0] seq_wdog;
  logic [23:0] seq_wait;
  logic        seq_at_end;

  assign quiesced = !stack_busy;

  // Slices take the DRAM buses only once training has finished.  Sticky: it
  // follows boot_done, which is itself sticky, so a slice cannot be pulled back
  // off the bus mid-traffic.
  logic cmd_en;
  assign cmd_en = seq_done;

  hbm4_seq_rom #(.DEPTH(512), .DELAY_SHIFT(BOOT_DELAY_SHIFT)) u_rom (.addr (seq_addr), .data (seq_data));

  hbm4_init_seq #(.SCRIPT_DEPTH(512)) u_seq (
    .clk (clk), .rst_n (rst_n),
    .start (boot_start), .slices_quiesced (quiesced),
    .busy (seq_busy), .done (seq_done), .error (seq_error),
    .script_addr (seq_addr), .script_data (seq_data),
    .op_valid (seq_op_valid), .op_code (seq_op_code), .op_arg (seq_op_arg),
    .op_ack (seq_op_ack),
    .dbg_pc (seq_pc), .dbg_wdog (seq_wdog), .dbg_wait (seq_wait), .dbg_at_end (seq_at_end)
  );

  // ---- boot command routing ------------------------------------------------
  // Until this existed the sequencer's op_valid/op_code/op_arg terminated in the
  // unused sink: the script ran, the delays elapsed, boot_done asserted -- and
  // not one command reached the device.  Boot reported success on a DRAM that
  // had never been configured and a PHY that had never been trained.
  localparam logic [3:0] OP_MRS     = 4'd4;
  localparam logic [3:0] OP_PHY     = 4'd5;
  localparam logic [3:0] OP_PATTERN = 4'd6;
  localparam logic [3:0] OP_PREA    = 4'd7;

  logic boot_mrs_fire, boot_pre_fire, boot_phy_fire, seq_op_ack;
  assign boot_mrs_fire = seq_op_valid
                      && ((seq_op_code == OP_MRS) || (seq_op_code == OP_PATTERN));
  assign boot_pre_fire = seq_op_valid && (seq_op_code == OP_PREA);
  assign boot_phy_fire = seq_op_valid && (seq_op_code == OP_PHY);

  assign phy_req = boot_phy_fire;
  assign phy_op  = seq_op_code;
  assign phy_arg = seq_op_arg;

  // A DRAM-bound command completes in the cycle it is broadcast; a PHY step does
  // not.  Acking a PHY step immediately would march the script through training
  // without waiting for any of it to finish, which is indistinguishable at the
  // interface from training that worked.
  assign seq_op_ack = boot_phy_fire ? phy_ack : 1'b1;

  assign dfi_mrs_index  = seq_op_arg[23:16];
  assign dfi_mrs_opcode = seq_op_arg[15:0];

  assign boot_done  = seq_done;
  assign boot_error = seq_error;

  // ---- power management ----------------------------------------------------
  // Self-refresh takes the whole stack off the bus, so it needs EVERY slice to
  // vote idle -- one busy slice must veto it, or that slice's outstanding read
  // never completes.
  logic pd_req, sr_req, exit_req, clk_gate_en;

  hbm4_pmgr u_pmgr (
    .clk (clk), .rst_n (rst_n),
    .cfg_pd_thresh (cfg_pd_thresh), .cfg_sr_thresh (cfg_sr_thresh),
    .cfg_lp_en (cfg_lp_en),
    .busy (stack_busy), .req_pending (|req_valid),
    .pd_req (pd_req), .sr_req (sr_req), .lp_ack (1'b1),
    .exit_req (exit_req), .state (lp_state), .clk_gate_en (clk_gate_en)
  );

  // Enum-typed command buses, converted to plain vectors at the boundary so the
  // port list stays synthesis- and tool-portable.
  row_cmd_e [N_PC_PER_STACK-1:0][1:0] s_row_cmd;
  col_cmd_e [N_PC_PER_STACK-1:0][1:0] s_col_cmd;
  logic [N_PC_PER_STACK-1:0][1:0]             s_row_valid, s_col_valid;
  logic [N_PC_PER_STACK-1:0][1:0][BANK_W-1:0] s_row_bank, s_col_bank;
  logic [N_PC_PER_STACK-1:0][1:0][ROW_W-1:0]  s_row_addr;
  logic [N_PC_PER_STACK-1:0][1:0][COL_W-1:0]  s_col_addr;

  // Boot owns the command buses, then the slices do.  The handover is on
  // seq_done, the same edge that opens each slice's cmd_en gate, so there is no
  // window in which both could drive: while !seq_done every slice's arbiters are
  // gated off, and once seq_done the sequencer is finished by construction.
  always_comb
    for (int unsigned p = 0; p < N_PC_PER_STACK; p++) begin
      if (!seq_done) begin
        // Boot commands are broadcast to every pseudo-channel, on DFI phase 0
        // only.  PREA and MRS are mutually exclusive by construction -- they are
        // separate script opcodes, and the sequencer issues one instruction at a
        // time -- so this is a select, not an arbitration.
        dfi_row_valid[p] = {1'b0, boot_mrs_fire || boot_pre_fire};
        dfi_row_cmd[p][0] = boot_pre_fire ? 3'(ROW_PREA) : 3'(ROW_MRS);
        dfi_row_cmd[p][1] = 3'(ROW_NOP);
        dfi_row_bank[p]  = '0;
        dfi_row_addr[p]  = '0;
        dfi_col_valid[p] = 2'b00;
        dfi_col_cmd[p][0] = 3'(COL_NOP);
        dfi_col_cmd[p][1] = 3'(COL_NOP);
        dfi_col_bank[p]  = '0;
        dfi_col_addr[p]  = '0;
      end else begin
        dfi_row_valid[p] = s_row_valid[p];
        dfi_row_bank[p]  = s_row_bank[p];
        dfi_row_addr[p]  = s_row_addr[p];
        dfi_col_valid[p] = s_col_valid[p];
        dfi_col_bank[p]  = s_col_bank[p];
        dfi_col_addr[p]  = s_col_addr[p];
        for (int unsigned h = 0; h < 2; h++) begin
          dfi_row_cmd[p][h] = s_row_cmd[p][h];
          dfi_col_cmd[p][h] = s_col_cmd[p][h];
        end
      end
    end

  // ---- the 64 slices -------------------------------------------------------
  for (genvar p = 0; p < int'(N_PC_PER_STACK); p++) begin : g_slice
    // Phase offset: spread this stack's slices evenly across one refresh
    // interval, and offset the whole stack so slices in DIFFERENT stacks do not
    // land on the same phase either.
    localparam int unsigned GLOBAL_PC = (STACK_ID * N_PC_PER_STACK) + p;
    localparam logic [15:0] PHASE = 16'((GLOBAL_PC * 64) / N_PC_TOTAL);

    hbm4_pc_slice #(.RD_FIFO_DEPTH(RD_FIFO_DEPTH)) u_pc (
      .clk (clk), .rst_n (rst_n),
      .tcfg (tcfg), .lcfg (lcfg),
      .cfg_wr_hi (cfg_wr_hi), .cfg_wr_lo (cfg_wr_lo),
      .cfg_wr_burst (cfg_wr_burst), .cfg_wr_age_limit (cfg_wr_age_limit),
      .cfg_wr_preempt (cfg_wr_preempt),
      .cfg_refi_pb (cfg_refi_pb), .cfg_refi_phase (PHASE),
      .cfg_rfm_thresh (cfg_rfm_thresh), .cfg_raa_imt (cfg_raa_imt),
      .cfg_rfm_en (cfg_rfm_en), .cmd_en (cmd_en),

      .req_valid (req_valid[p]), .req_wr (req_wr[p]), .req_blk (req_blk[p]),
      .req_tag (req_tag[p]), .req_qos (qos_t'(req_qos[p])),
      .req_data (req_data[p]),
      .req_credit (req_credit[p]),

      .rsp_valid (rsp_valid[p]), .rsp_ready (rsp_ready[p]),
      .rsp_tag (rsp_tag[p]), .rsp_data (rsp_data[p]), .rsp_err (rsp_err[p]),
      .rsp_wack (rsp_wack[p]),

      .dfi_row_valid (s_row_valid[p]),
      .dfi_row_cmd   (s_row_cmd[p]),
      .dfi_row_bank  (s_row_bank[p]),
      .dfi_row_addr  (s_row_addr[p]),
      .dfi_wrdata_valid (dfi_wrdata_valid[p]), .dfi_wrdata (dfi_wrdata[p]),
      .dfi_col_valid (s_col_valid[p]),
      .dfi_col_cmd   (s_col_cmd[p]),
      .dfi_col_bank  (s_col_bank[p]),
      .dfi_col_addr  (s_col_addr[p]),
      .dfi_rddata_valid (dfi_rddata_valid[p]), .dfi_rddata (dfi_rddata[p]),
      .dfi_rdcode (dfi_rdcode[p]),

      .busy (slice_busy[p]), .occupancy (s_occ[p]),
      .err_rdfifo (slice_err_fifo[p]), .err_stall (slice_err_stall[p]),
      .sts_turning (s_turning[p]), .sts_ref_debt (s_debt[p]),
      .sts_lecc_ce (s_ce[p]), .sts_lecc_ue (s_ue[p]),
      .sts_lecc_thresh (s_thresh[p]), .sts_rdfifo_level (s_rdlvl[p])
    );
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, seq_addr, seq_pc,
                   seq_wdog, seq_wait, seq_at_end, seq_busy, pd_req, sr_req, exit_req, clk_gate_en,
                   s_occ, s_turning, s_debt, s_ce, s_ue, s_thresh, s_rdlvl};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
