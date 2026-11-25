// ---------------------------------------------------------------------------
// hbm4_sys_top -- the only module the integrator instantiates.
//
// N_STACK stacks, 64 pseudo-channels each, plus the supervisor.  At the
// baseline that is 256 independent scheduler cores and 8.19 TB/s of raw
// bandwidth.
//
// There is NO CROSSBAR here, and that is the central architectural decision
// (docs/02-architecture.md 2).  256 pseudo-channels at 32 B per clock is
// ~16 000 wires per direction; a central switch at that width is not buildable
// at 1 GHz.  Instead each pseudo-channel gets its own NHI port, placed next to
// its PHY slice, and the address slicing that decides WHICH port happens in the
// customer's fabric using hbm4_addr_slice -- which this design ships, and which
// a formal miter proves equivalent to the controller's own decode.
//
// So the 256 ports below are not a convenience. They are the interface, and an
// integrator who aggregates them back into a switch has undone the thing that
// makes the design closeable.
// ---------------------------------------------------------------------------
module hbm4_sys_top
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned RD_FIFO_DEPTH = 32,
  // Scales the boot script's tINIT waits. MUST be 0 in silicon; simulation only.
  // Forwarded to every stack so a system-level testbench can actually reach the
  // end of boot -- without it, a system simulation spends its entire run inside
  // the first 200 us wait and never exercises anything.
  parameter int unsigned BOOT_DELAY_SHIFT = 0
) (
  input  logic                       clk,
  input  logic                       rst_n,

  // ---- configuration -------------------------------------------------------
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
  input  logic [31:0]                irq_mask,

  // ---- boot ----------------------------------------------------------------
  input  logic                       boot_start,
  output logic                       ctrl_ready,
  output logic                       boot_failed,

  // ---- NHI, one port per pseudo-channel in the SYSTEM ---------------------
  input  logic [N_PC_TOTAL-1:0]                  req_valid,
  input  logic [N_PC_TOTAL-1:0]                  req_wr,
  input  logic [N_PC_TOTAL-1:0][PC_BLK_W-1:0]    req_blk,
  input  logic [N_PC_TOTAL-1:0][TAG_W-1:0]       req_tag,
  input  logic [N_PC_TOTAL-1:0][QOS_W-1:0]       req_qos,
  input  logic [N_PC_TOTAL-1:0][AG_BYTES*8-1:0] req_data,
  output logic [N_PC_TOTAL-1:0]                  req_credit,

  output logic [N_PC_TOTAL-1:0]                  rsp_valid,
  input  logic [N_PC_TOTAL-1:0]                  rsp_ready,
  output logic [N_PC_TOTAL-1:0][TAG_W-1:0]       rsp_tag,
  output logic [N_PC_TOTAL-1:0][DFI_DATA_W-1:0]  rsp_data,
  output logic [N_PC_TOTAL-1:0][1:0]             rsp_err,
  output logic [N_PC_TOTAL-1:0]                  rsp_wack,

  // ---- DFI -----------------------------------------------------------------
  output logic [N_PC_TOTAL-1:0][1:0]             dfi_row_valid,
  output logic [N_PC_TOTAL-1:0][1:0][2:0]        dfi_row_cmd,
  output logic [N_PC_TOTAL-1:0][1:0][BANK_W-1:0] dfi_row_bank,
  output logic [N_PC_TOTAL-1:0][1:0][ROW_W-1:0]  dfi_row_addr,
  output logic [N_PC_TOTAL-1:0]                  dfi_wrdata_valid,
  output logic [N_PC_TOTAL-1:0][AG_BYTES*8-1:0] dfi_wrdata,
  output logic [N_PC_TOTAL-1:0][1:0]             dfi_col_valid,
  output logic [N_PC_TOTAL-1:0][1:0][2:0]        dfi_col_cmd,
  output logic [N_PC_TOTAL-1:0][1:0][BANK_W-1:0] dfi_col_bank,
  output logic [N_PC_TOTAL-1:0][1:0][COL_W-1:0]  dfi_col_addr,
  input  logic [N_PC_TOTAL-1:0]                  dfi_rddata_valid,
  input  logic [N_PC_TOTAL-1:0][DFI_DATA_W-1:0]  dfi_rddata,
  input  logic [N_PC_TOTAL-1:0][ECC_FIELD_W-1:0] dfi_rdcode,

  // ---- boot-time command path, per stack ----------------------------------
  // Per-stack, not system-wide: each stack has its own PHY and trains
  // independently, so collapsing these into one bus would serialise a boot that
  // is deliberately parallel.
  output logic [N_STACK-1:0][7:0]    dfi_mrs_index,
  output logic [N_STACK-1:0][15:0]   dfi_mrs_opcode,
  output logic [N_STACK-1:0]         phy_req,
  output logic [N_STACK-1:0][3:0]    phy_op,
  output logic [N_STACK-1:0][23:0]   phy_arg,
  input  logic [N_STACK-1:0]         phy_ack,

  // ---- status --------------------------------------------------------------
  input  logic                       perf_snapshot_req,
  output logic                       perf_freeze,
  output logic [31:0]                irq_status,
  output logic                       irq
);

  logic [N_STACK-1:0] st_boot_start, st_boot_done, st_boot_error;
  logic [N_STACK-1:0] st_err, st_busy;
  logic [N_STACK-1:0][1:0] st_lp;

  hbm4_supervisor u_sup (
    .clk (clk), .rst_n (rst_n),
    .boot_start (boot_start), .ctrl_ready (ctrl_ready),
    .boot_failed (boot_failed),
    .stack_boot_done (st_boot_done), .stack_boot_error (st_boot_error),
    .stack_boot_start (st_boot_start),
    .stack_err (st_err), .stack_busy (st_busy),
    .perf_snapshot_req (perf_snapshot_req), .perf_freeze (perf_freeze),
    .irq_status (irq_status), .irq_mask (irq_mask), .irq (irq)
  );

  for (genvar s = 0; s < int'(N_STACK); s++) begin : g_stack
    localparam int unsigned LO = s * N_PC_PER_STACK;

    hbm4_stack_top #(.STACK_ID(s), .RD_FIFO_DEPTH(RD_FIFO_DEPTH),
                     .BOOT_DELAY_SHIFT(BOOT_DELAY_SHIFT)) u_stack (
      .clk (clk), .rst_n (rst_n),
      .tcfg (tcfg), .lcfg (lcfg),
      .cfg_wr_hi (cfg_wr_hi), .cfg_wr_lo (cfg_wr_lo),
      .cfg_wr_burst (cfg_wr_burst), .cfg_wr_age_limit (cfg_wr_age_limit),
      .cfg_wr_preempt (cfg_wr_preempt), .cfg_refi_pb (cfg_refi_pb),
      .cfg_rfm_thresh (cfg_rfm_thresh), .cfg_raa_imt (cfg_raa_imt),
      .cfg_rfm_en (cfg_rfm_en), .cfg_lp_en (cfg_lp_en),
      .cfg_pd_thresh (cfg_pd_thresh), .cfg_sr_thresh (cfg_sr_thresh),

      .boot_start (st_boot_start[s]), .boot_done (st_boot_done[s]),
      .boot_error (st_boot_error[s]),

      .req_valid  (req_valid [LO +: N_PC_PER_STACK]),
      .req_wr     (req_wr    [LO +: N_PC_PER_STACK]),
      .req_blk    (req_blk   [LO +: N_PC_PER_STACK]),
      .req_tag    (req_tag   [LO +: N_PC_PER_STACK]),
      .req_qos    (req_qos   [LO +: N_PC_PER_STACK]),
      .req_data   (req_data  [LO +: N_PC_PER_STACK]),
      .req_credit (req_credit[LO +: N_PC_PER_STACK]),

      .rsp_valid (rsp_valid[LO +: N_PC_PER_STACK]),
      .rsp_ready (rsp_ready[LO +: N_PC_PER_STACK]),
      .rsp_tag   (rsp_tag  [LO +: N_PC_PER_STACK]),
      .rsp_data  (rsp_data [LO +: N_PC_PER_STACK]),
      .rsp_err   (rsp_err  [LO +: N_PC_PER_STACK]),
      .rsp_wack  (rsp_wack [LO +: N_PC_PER_STACK]),

      .dfi_row_valid (dfi_row_valid[LO +: N_PC_PER_STACK]),
      .dfi_row_cmd   (dfi_row_cmd  [LO +: N_PC_PER_STACK]),
      .dfi_row_bank  (dfi_row_bank [LO +: N_PC_PER_STACK]),
      .dfi_row_addr  (dfi_row_addr [LO +: N_PC_PER_STACK]),
      .dfi_wrdata_valid (dfi_wrdata_valid[LO +: N_PC_PER_STACK]),
      .dfi_wrdata       (dfi_wrdata      [LO +: N_PC_PER_STACK]),
      .dfi_col_valid (dfi_col_valid[LO +: N_PC_PER_STACK]),
      .dfi_col_cmd   (dfi_col_cmd  [LO +: N_PC_PER_STACK]),
      .dfi_col_bank  (dfi_col_bank [LO +: N_PC_PER_STACK]),
      .dfi_col_addr  (dfi_col_addr [LO +: N_PC_PER_STACK]),
      .dfi_rddata_valid (dfi_rddata_valid[LO +: N_PC_PER_STACK]),
      .dfi_rddata       (dfi_rddata      [LO +: N_PC_PER_STACK]),
      .dfi_rdcode       (dfi_rdcode      [LO +: N_PC_PER_STACK]),

      .dfi_mrs_index (dfi_mrs_index[s]), .dfi_mrs_opcode (dfi_mrs_opcode[s]),
      .phy_req (phy_req[s]), .phy_op (phy_op[s]), .phy_arg (phy_arg[s]),
      .phy_ack (phy_ack[s]),

      .stack_busy (st_busy[s]), .stack_err (st_err[s]), .lp_state (st_lp[s])
    );
  end

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, st_lp};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
