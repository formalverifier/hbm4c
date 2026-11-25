// ---------------------------------------------------------------------------
// tb_pc_slice -- thin flattening wrapper around hbm4_pc_slice for cocotb.
//
// The DUT's boundary uses packed structs (timing_cfg_t, local_cfg_t) and enum
// types.  Verilator's VPI presents those to cocotb inconsistently across
// versions, so the testbench drives SCALARS and this wrapper rebuilds the
// structured types.  Nothing here is logic -- it is purely a type adapter, and
// it is deliberately the ONLY thing between the testbench and the real slice.
//
// The hash masks default to ZERO (identity).  A zero mask makes the address map
// the plain bit-slicing described in docs/02 5.1, which is what the reference
// model in the testbench implements.  Hash randomisation is enabled explicitly
// by tests that want it, so a failure is never ambiguous between "the scheduler
// is wrong" and "the testbench modelled the hash wrong".
// ---------------------------------------------------------------------------
module tb_pc_slice
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned RD_FIFO_DEPTH = 32
) (
  input  logic                  clk,
  input  logic                  rst_n,

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
  input  logic                  cmd_en,

  input  logic                  req_valid,
  input  logic                  req_wr,
  input  logic [PC_BLK_W-1:0]   req_blk,
  input  logic [TAG_W-1:0]      req_tag,
  input  logic [QOS_W-1:0]      req_qos,
  input  logic [AG_BYTES*8-1:0] req_data,
  output logic                  req_credit,

  output logic                  rsp_valid,
  input  logic                  rsp_ready,
  output logic [TAG_W-1:0]      rsp_tag,
  output logic [DFI_DATA_W-1:0] rsp_data,
  output logic [1:0]            rsp_err,
  output logic                  rsp_wack,

  // DFI, flattened: two half-cycle phases per core clock (1:2 gearing)
  output logic [1:0]            dfi_row_valid,
  output logic [1:0][2:0]       dfi_row_cmd,
  output logic [1:0][BANK_W-1:0] dfi_row_bank,
  output logic [1:0][ROW_W-1:0] dfi_row_addr,
  output logic                  dfi_wrdata_valid,
  output logic [AG_BYTES*8-1:0] dfi_wrdata,
  output logic [1:0]            dfi_col_valid,
  output logic [1:0][2:0]       dfi_col_cmd,
  output logic [1:0][BANK_W-1:0] dfi_col_bank,
  output logic [1:0][COL_W-1:0] dfi_col_addr,
  input  logic                  dfi_rddata_valid,
  input  logic [DFI_DATA_W-1:0] dfi_rddata,
  input  logic [ECC_FIELD_W-1:0] dfi_rdcode,

  output logic                  busy,
  output logic [TQ_IDX_W:0]     occupancy,
  output logic                  err_rdfifo,
  output logic                  err_stall,
  output logic                  sts_turning,
  output logic signed [5:0]     sts_ref_debt,
  output logic [15:0]           sts_lecc_ce,
  output logic [15:0]           sts_lecc_ue,
  output logic                  sts_lecc_thresh,
  output logic [$clog2(RD_FIFO_DEPTH):0] sts_rdfifo_level
);

`ifdef FV_SMALL
  timing_cfg_t tcfg; assign tcfg = small_timing();
`else
  timing_cfg_t tcfg; assign tcfg = default_timing();
`endif

  local_cfg_t lcfg;
  assign lcfg = '0;   // identity address map -- see header

  row_cmd_e [1:0] w_row_cmd;
  col_cmd_e [1:0] w_col_cmd;
  always_comb for (int unsigned h = 0; h < 2; h++) begin
    dfi_row_cmd[h] = w_row_cmd[h];
    dfi_col_cmd[h] = w_col_cmd[h];
  end

  hbm4_pc_slice #(.RD_FIFO_DEPTH(RD_FIFO_DEPTH)) u_dut (
    .clk (clk), .rst_n (rst_n), .tcfg (tcfg), .lcfg (lcfg),
    .cfg_wr_hi (cfg_wr_hi), .cfg_wr_lo (cfg_wr_lo),
    .cfg_wr_burst (cfg_wr_burst), .cfg_wr_age_limit (cfg_wr_age_limit),
    .cfg_wr_preempt (cfg_wr_preempt),
    .cfg_refi_pb (cfg_refi_pb), .cfg_refi_phase (cfg_refi_phase),
    .cfg_rfm_thresh (cfg_rfm_thresh), .cfg_raa_imt (cfg_raa_imt),
    .cfg_rfm_en (cfg_rfm_en), .cmd_en (cmd_en),
    .req_valid (req_valid), .req_wr (req_wr), .req_blk (req_blk),
    .req_tag (tag_t'(req_tag)), .req_qos (qos_t'(req_qos)),
    .req_data (req_data),
    .req_credit (req_credit),
    .rsp_valid (rsp_valid), .rsp_ready (rsp_ready), .rsp_tag (rsp_tag),
    .rsp_data (rsp_data), .rsp_err (rsp_err), .rsp_wack (rsp_wack),
    .dfi_row_valid (dfi_row_valid), .dfi_row_cmd (w_row_cmd),
    .dfi_row_bank (dfi_row_bank), .dfi_row_addr (dfi_row_addr),
    .dfi_wrdata_valid (dfi_wrdata_valid), .dfi_wrdata (dfi_wrdata),
    .dfi_col_valid (dfi_col_valid), .dfi_col_cmd (w_col_cmd),
    .dfi_col_bank (dfi_col_bank), .dfi_col_addr (dfi_col_addr),
    .dfi_rddata_valid (dfi_rddata_valid), .dfi_rddata (dfi_rddata),
    .dfi_rdcode (dfi_rdcode),
    .busy (busy), .occupancy (occupancy),
    .err_rdfifo (err_rdfifo), .err_stall (err_stall),
    .sts_turning (sts_turning), .sts_ref_debt (sts_ref_debt),
    .sts_lecc_ce (sts_lecc_ce), .sts_lecc_ue (sts_lecc_ue),
    .sts_lecc_thresh (sts_lecc_thresh), .sts_rdfifo_level (sts_rdfifo_level)
  );

endmodule
