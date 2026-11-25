// ---------------------------------------------------------------------------
// tb_sys_top -- first simulation of the whole controller.
//
// hbm4_sys_top and hbm4_supervisor had only ever been LINTED.  That is exactly
// the situation that hid OPEN-10 one level down: the stack level had never been
// simulated, and boot completed successfully while issuing no commands at all.
// A level that has never been run is a level whose failures are invisible.
//
// What is only observable HERE:
//   - whether the stacks train in parallel or accidentally serialise;
//   - whether one ctrl_ready really waits for every stack;
//   - whether one stack failing fails the boot, or hangs it silently;
//   - whether traffic on one stack disturbs another.
//
// THE FULL DFI IS EXPOSED, PER PSEUDO-CHANNEL, and that is what the last line
// above needs.  Rev 1.1 tied dfi_rddata_valid/dfi_rddata/dfi_rdcode to zero and
// brought out only the command STROBES: enough to watch a boot, and useless for
// traffic.  With the read-data path tied off nothing ever completes -- the
// slice parks each read in its pointer FIFO and waits for data that never
// arrives -- so a testbench built on it sees a healthy scheduler and a host that
// never gets an answer, which is precisely the failure mode documented in
// sim/README.md as "three ways this environment lied".
//
// Every command payload is out as well, not just the strobes, because a
// per-pseudo-channel DRAM model cannot check tRCD or "column command with no
// open row" without the bank and row fields.  A monitor that sees only strobes
// passes against a controller that addresses the wrong bank.
// ---------------------------------------------------------------------------
module tb_sys_top
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned BOOT_DELAY_SHIFT = 10
) (
  input  logic clk,
  input  logic rst_n,
  input  logic boot_start,
  output logic ctrl_ready,
  output logic boot_failed,

  // Refresh interval and interrupt mask are DRIVEN, not tied.  A test that
  // wants refresh pressure inside a simulation-length window has to shorten
  // tREFI; a test that wants to see an interrupt has to be able to unmask one.
  input  logic [15:0] cfg_refi_pb,
  input  logic [31:0] irq_mask,

  output logic [N_STACK-1:0][7:0]  dfi_mrs_index,
  output logic [N_STACK-1:0]       phy_req,
  output logic [N_STACK-1:0][23:0] phy_arg,
  input  logic [N_STACK-1:0]       phy_ack,

  // ---- DFI, full command detail per pseudo-channel ------------------------
  output logic [N_PC_TOTAL-1:0][1:0]             dfi_row_valid,
  output logic [N_PC_TOTAL-1:0][1:0][2:0]        dfi_row_cmd,
  output logic [N_PC_TOTAL-1:0][1:0][BANK_W-1:0] dfi_row_bank,
  output logic [N_PC_TOTAL-1:0][1:0][ROW_W-1:0]  dfi_row_addr,
  output logic [N_PC_TOTAL-1:0][1:0]             dfi_col_valid,
  output logic [N_PC_TOTAL-1:0][1:0][2:0]        dfi_col_cmd,
  output logic [N_PC_TOTAL-1:0][1:0][BANK_W-1:0] dfi_col_bank,
  output logic [N_PC_TOTAL-1:0][1:0][COL_W-1:0]  dfi_col_addr,

  // ---- DFI read data, per pseudo-channel ----------------------------------
  input  logic [N_PC_TOTAL-1:0]                  dfi_rddata_valid,
  input  logic [N_PC_TOTAL-1:0][DFI_DATA_W-1:0]  dfi_rddata,
  input  logic [N_PC_TOTAL-1:0][ECC_FIELD_W-1:0] dfi_rdcode,

  // ---- NHI ----------------------------------------------------------------
  input  logic [N_PC_TOTAL-1:0]           req_valid,
  input  logic [N_PC_TOTAL-1:0]           req_wr,
  input  logic [N_PC_TOTAL-1:0][PC_BLK_W-1:0] req_blk,
  input  logic [N_PC_TOTAL-1:0][TAG_W-1:0]    req_tag,
  output logic [N_PC_TOTAL-1:0]           req_credit,
  output logic [N_PC_TOTAL-1:0]           rsp_valid,
  output logic [N_PC_TOTAL-1:0][TAG_W-1:0] rsp_tag,
  output logic [N_PC_TOTAL-1:0][DFI_DATA_W-1:0] rsp_data,
  output logic [N_PC_TOTAL-1:0][1:0]      rsp_err,
  output logic [N_PC_TOTAL-1:0]           rsp_wack,

  input  logic        perf_snapshot_req,
  output logic        perf_freeze,
  output logic [31:0] irq_status,
  output logic        irq
);

  logic [N_STACK-1:0][15:0]               dfi_mrs_opcode;
  logic [N_STACK-1:0][3:0]                phy_op;
  logic [N_PC_TOTAL-1:0]                  sys_wrdata_valid;
  logic [N_PC_TOTAL-1:0][AG_BYTES*8-1:0]  sys_wrdata;

  hbm4_sys_top #(.BOOT_DELAY_SHIFT(BOOT_DELAY_SHIFT)) u_sys (
    .clk (clk), .rst_n (rst_n),
    .tcfg (small_timing()), .lcfg ('0),
    .cfg_wr_hi (16'd24), .cfg_wr_lo (16'd8), .cfg_wr_burst (16'd16),
    .cfg_wr_age_limit (32'd5000), .cfg_wr_preempt (1'b0),
    .cfg_refi_pb (cfg_refi_pb), .cfg_rfm_thresh (8'd32), .cfg_raa_imt (8'd4),
    .cfg_rfm_en (1'b0), .cfg_lp_en (1'b0),
    .cfg_pd_thresh (16'd1000), .cfg_sr_thresh (16'd5000),
    .irq_mask (irq_mask),
    .boot_start (boot_start), .ctrl_ready (ctrl_ready),
    .boot_failed (boot_failed),
    .req_valid (req_valid), .req_wr (req_wr), .req_blk (req_blk),
    .req_tag (req_tag), .req_qos ('0), .req_data ('0),
    .req_credit (req_credit),
    // rsp_ready tied high: the host is always ready.  Back-pressure has its own
    // failure mode (the nhi_target stall watchdog) and belongs in a test that
    // asserts it deliberately, not as an accident of the harness.
    .rsp_valid (rsp_valid), .rsp_ready ('1), .rsp_tag (rsp_tag),
    .rsp_data (rsp_data), .rsp_err (rsp_err), .rsp_wack (rsp_wack),
    .dfi_row_valid (dfi_row_valid), .dfi_row_cmd (dfi_row_cmd),
    .dfi_row_bank (dfi_row_bank), .dfi_row_addr (dfi_row_addr),
    .dfi_wrdata_valid (sys_wrdata_valid), .dfi_wrdata (sys_wrdata),
    .dfi_col_valid (dfi_col_valid), .dfi_col_cmd (dfi_col_cmd),
    .dfi_col_bank (dfi_col_bank), .dfi_col_addr (dfi_col_addr),
    .dfi_rddata_valid (dfi_rddata_valid), .dfi_rddata (dfi_rddata),
    .dfi_rdcode (dfi_rdcode),
    .dfi_mrs_index (dfi_mrs_index), .dfi_mrs_opcode (dfi_mrs_opcode),
    .phy_req (phy_req), .phy_op (phy_op), .phy_arg (phy_arg),
    .phy_ack (phy_ack),
    .perf_snapshot_req (perf_snapshot_req), .perf_freeze (perf_freeze),
    .irq_status (irq_status), .irq (irq)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, dfi_mrs_opcode, phy_op, sys_wrdata_valid, sys_wrdata};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
