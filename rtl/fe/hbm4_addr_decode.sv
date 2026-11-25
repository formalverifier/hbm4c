// ---------------------------------------------------------------------------
// hbm4_addr_decode -- controller-side decode, pipeline stages E1a / E1b.
//
// Takes the PC-local block address handed over by the fabric (which produced
// it with hbm4_addr_slice) and finishes the job: bank-group and bank hashing,
// then the row/column split.
//
// pc_blk layout, LSB first:   [1:0] BG | [4:2] BA | [24:5] rem
// and rem splits as           col = rem mod N_COL_DATA
//                             row = rem div N_COL_DATA
//
// Two cycles, entirely because of the divide (see hbm4_divc).  The depth is
// the same whether or not ECC is enabled, so latency does not change with a
// build option -- one less thing to characterise per configuration.
// ---------------------------------------------------------------------------
module hbm4_addr_decode
  import hbm4_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  input  logic                   in_valid,
  input  logic [PC_BLK_W-1:0]    in_pc_blk,
  input  local_cfg_t             cfg,

  output logic                   out_valid,
  output pc_addr_t               out_addr,
  output bank_t                  out_bank,
  // Address is above the device's usable range (see REM_MAX in hbm4_pkg).
  // Must be turned into rsp_err = 3 (access fault); it MUST NOT be issued to
  // DRAM, because a truncated row aliases onto real data.
  output logic                   out_range_err
);

  // ---- combinational field extraction + hash (E1a) --------------------------
  logic [BG_W-1:0] bg_base, bg_hashed;
  logic [BA_W-1:0] ba_base, ba_hashed;
  logic [REM_W-1:0] rem;

  assign bg_base = in_pc_blk[0 +: BG_W];
  assign ba_base = in_pc_blk[BG_W +: BA_W];
  assign rem     = in_pc_blk[BG_W + BA_W +: REM_W];

  hbm4_hash #(.IN_W(PC_BLK_W), .OUT_W(BG_W)) u_hash_bg (
    .addr(in_pc_blk), .base(bg_base), .mask(cfg.h_bg), .hashed(bg_hashed));

  hbm4_hash #(.IN_W(PC_BLK_W), .OUT_W(BA_W)) u_hash_ba (
    .addr(in_pc_blk), .base(ba_base), .mask(cfg.h_ba), .hashed(ba_hashed));

  // ---- row / column split ---------------------------------------------------
  logic             div_valid;
  logic [ROW_W-1:0] div_row;
  logic [COL_W-1:0] div_col;
  logic             div_oor;      // quotient landed outside the device

  if (SYSECC_EN != 0) begin : g_ecc_divide
    localparam int unsigned QW = $clog2(((2**REM_W) - 1) / N_COL_DATA + 1);
    localparam int unsigned RW = $clog2(N_COL_DATA);

    logic [QW-1:0] q;
    logic [RW-1:0] r;

    hbm4_divc #(.W(REM_W), .D(N_COL_DATA)) u_div (
      .clk       (clk),
      .rst_n     (rst_n),
      .in_valid  (in_valid),
      .in_x      (rem),
      .out_valid (div_valid),
      .out_q     (q),
      .out_r     (r)
    );

    // QW (16) exceeds ROW_W (15): rem can encode 2^20 values but the device
    // holds only N_ROW * N_COL_DATA = 983040 of them.  Detect rather than
    // truncate -- truncating aliases an illegal address onto a legal row.
    assign div_oor = (q >= QW'(N_ROW));
    assign div_row = ROW_W'(q);
    assign div_col = COL_W'(r);
  end else begin : g_pow2_split
    // No ECC: the column count is a power of two and this is a pure bit
    // select.  Still two registers deep, to keep the pipeline depth constant.
    logic            v_q;
    logic [REM_W-1:0] rem_q;
    always_ff @(posedge clk) begin
      if (!rst_n) begin v_q <= 1'b0; div_valid <= 1'b0; end
      else        begin v_q <= in_valid; div_valid <= v_q; rem_q <= rem; end
    end
    assign div_col = rem_q[0 +: COL_W];
    assign div_row = ROW_W'(rem_q[COL_W +: (REM_W - COL_W)]);
    assign div_oor = 1'b0;   // power-of-two split: every encodable value exists
  end

  // ---- carry the hashed bank bits alongside the divider (E1a -> E1b) --------
  logic [BG_W-1:0] bg_s1, bg_s2;
  logic [BA_W-1:0] ba_s1, ba_s2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bg_s1 <= '0; ba_s1 <= '0; bg_s2 <= '0; ba_s2 <= '0;
    end else begin
      bg_s1 <= bg_hashed; ba_s1 <= ba_hashed;
      bg_s2 <= bg_s1;     ba_s2 <= ba_s1;
    end
  end

  assign out_valid     = div_valid;
  assign out_range_err = div_oor;
  assign out_addr.row  = div_row;
  assign out_addr.col  = div_col;
  assign out_addr.bg   = bg_s2;
  assign out_addr.ba   = ba_s2;
  assign out_bank      = bank_of(bg_s2, ba_s2);

`ifdef FORMAL
  // A decoded column must always be a DATA column.  If this fires, the divider
  // or the column budget is wrong, and every ECC block in the device is
  // aliased onto data.
  if (SYSECC_EN != 0) begin : g_fv_col
    always_ff @(posedge clk) begin
      if (rst_n && out_valid) begin
        a_col_is_data: assert (out_addr.col < COL_W'(N_COL_DATA));
      end
    end
  end
`endif

endmodule
