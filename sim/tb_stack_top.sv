// ---------------------------------------------------------------------------
// tb_stack_top -- boot-sequence testbench wrapper.
//
// The stack level is where the boot path lives, and it had NEVER been simulated
// -- which is exactly how OPEN-10 (training commands terminating in an unused
// sink) survived review, lint and forty formal proofs.
//
// BOOT_DELAY_SHIFT scales the init waits so the sequence completes in
// simulation time.  The instruction sequence is unchanged; only the waiting is
// shorter.
// ---------------------------------------------------------------------------
module tb_stack_top
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned BOOT_DELAY_SHIFT = 10
) (
  input  logic clk,
  input  logic rst_n,
  input  logic boot_start,
  output logic boot_done,
  output logic boot_error,

  output logic [7:0]  dfi_mrs_index,
  output logic [15:0] dfi_mrs_opcode,
  output logic        phy_req,
  output logic [3:0]  phy_op,
  output logic [23:0] phy_arg,
  input  logic        phy_ack,

  output logic [N_PC_PER_STACK-1:0][1:0]      dfi_row_valid,
  output logic [N_PC_PER_STACK-1:0][1:0][2:0] dfi_row_cmd,
  output logic        stack_busy,
  output logic        stack_err
);

  logic [N_PC_PER_STACK-1:0]                  req_credit, rsp_valid, rsp_wack;
  logic [N_PC_PER_STACK-1:0][TAG_W-1:0]       rsp_tag;
  logic [N_PC_PER_STACK-1:0][DFI_DATA_W-1:0]  rsp_data;
  logic [N_PC_PER_STACK-1:0][1:0]             rsp_err;
  logic [N_PC_PER_STACK-1:0][1:0][BANK_W-1:0] dfi_row_bank, dfi_col_bank;
  logic [N_PC_PER_STACK-1:0][1:0][ROW_W-1:0]  dfi_row_addr;
  logic [N_PC_PER_STACK-1:0][1:0][COL_W-1:0]  dfi_col_addr;
  logic [N_PC_PER_STACK-1:0][1:0]             dfi_col_valid;
  logic [N_PC_PER_STACK-1:0][1:0][2:0]        dfi_col_cmd;
  logic [1:0] lp_state;
  logic [N_PC_PER_STACK-1:0]                 stk_wrdata_valid;
  logic [N_PC_PER_STACK-1:0][AG_BYTES*8-1:0] stk_wrdata;

  hbm4_stack_top #(.STACK_ID(0), .BOOT_DELAY_SHIFT(BOOT_DELAY_SHIFT)) u_stack (
    .clk (clk), .rst_n (rst_n),
    .tcfg (small_timing()), .lcfg ('0),
    .cfg_wr_hi (16'd24), .cfg_wr_lo (16'd8), .cfg_wr_burst (16'd16),
    .cfg_wr_age_limit (32'd5000), .cfg_wr_preempt (1'b0),
    .cfg_refi_pb (16'd2000), .cfg_rfm_thresh (8'd32), .cfg_raa_imt (8'd4),
    .cfg_rfm_en (1'b0), .cfg_lp_en (1'b0),
    .cfg_pd_thresh (16'd1000), .cfg_sr_thresh (16'd5000),
    .boot_start (boot_start), .boot_done (boot_done), .boot_error (boot_error),
    .req_valid ('0), .req_wr ('0), .req_blk ('0), .req_tag ('0), .req_qos ('0),
    .req_data ('0),
    .req_credit (req_credit),
    .rsp_valid (rsp_valid), .rsp_ready ('1), .rsp_tag (rsp_tag),
    .rsp_data (rsp_data), .rsp_err (rsp_err), .rsp_wack (rsp_wack),
    .dfi_row_valid (dfi_row_valid), .dfi_row_cmd (dfi_row_cmd),
    .dfi_row_bank (dfi_row_bank), .dfi_row_addr (dfi_row_addr),
    .dfi_wrdata_valid (stk_wrdata_valid), .dfi_wrdata (stk_wrdata),
    .dfi_col_valid (dfi_col_valid), .dfi_col_cmd (dfi_col_cmd),
    .dfi_col_bank (dfi_col_bank), .dfi_col_addr (dfi_col_addr),
    .dfi_rddata_valid ('0), .dfi_rddata ('0), .dfi_rdcode ('0),
    .dfi_mrs_index (dfi_mrs_index), .dfi_mrs_opcode (dfi_mrs_opcode),
    .phy_req (phy_req), .phy_op (phy_op), .phy_arg (phy_arg), .phy_ack (phy_ack),
    .stack_busy (stack_busy), .stack_err (stack_err), .lp_state (lp_state)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, req_credit, rsp_valid, rsp_tag, rsp_data, rsp_err,
                   rsp_wack, dfi_row_bank, dfi_row_addr, dfi_col_valid,
                   dfi_col_cmd, dfi_col_bank, dfi_col_addr, lp_state,
                   stk_wrdata_valid, stk_wrdata};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
