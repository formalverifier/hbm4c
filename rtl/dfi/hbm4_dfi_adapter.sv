// ---------------------------------------------------------------------------
// hbm4_dfi_adapter -- controller commands onto the DFI, and read data back.
//
// DFI frequency ratio 1:2 -- one core clock carries TWO CK phases, so every
// command bus is presented as a 2-element array indexed by phase.
//
// ON PHASE SELECTION.  docs/03-interface-spec.md 2.6 describes tracking the
// last issued phase and placing the next command on whichever phase exactly
// satisfies tCCD_S.  At the shipped configuration that logic is DEGENERATE, and
// it is worth being explicit about why rather than building speculative
// machinery:
//
//     tCCD_S = 2 tCK = 1 core clock  (BL8, 1:2 gearing)
//
// Back-to-back column commands are therefore exactly one core clock apart, and
// keeping them on the SAME phase is what makes the spacing exactly 2 tCK.
// Alternating phases would produce 1 tCK and 3 tCK alternately -- the first
// violates tCCD_S outright.  So the phase is a constant, and COL_PHASE is a
// parameter only so a board or PHY that wants the other alignment can have it.
//
// Phase selection becomes real if BL16 is confirmed (burst = 2 core clocks) or
// the gearing changes; the interface is shaped to accept that without a
// redesign, which is the point of parameterising it now.
// ---------------------------------------------------------------------------
module hbm4_dfi_adapter
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
#(
  parameter int unsigned RD_FIFO_DEPTH = 32,
  parameter logic        COL_PHASE     = 1'b0,
  parameter logic        ROW_PHASE     = 1'b0
) (
  input  logic                        clk,
  input  logic                        rst_n,

  // ---- from the scheduler --------------------------------------------------
  input  row_issue_t                  row_iss,
  input  col_issue_t                  col_iss,
  input  tag_t                        col_tag,        // routes the returning read

  // ---- DFI command buses (2 CK phases per core clock) ---------------------
  output logic [1:0]                  dfi_row_valid,
  output row_cmd_e [1:0]              dfi_row_cmd,
  output bank_t [1:0]                 dfi_row_bank,
  output row_t [1:0]                  dfi_row_addr,

  output logic [1:0]                  dfi_col_valid,
  output col_cmd_e [1:0]              dfi_col_cmd,
  output bank_t [1:0]                 dfi_col_bank,
  output col_t [1:0]                  dfi_col_addr,

  // ---- DFI read data -------------------------------------------------------
  // Write data leaves with its column command.  The PHY applies WL alignment --
  // that is what tphy_wrlat in the DFI spec is for -- so the controller must
  // NOT pre-delay it here, or the two delays compound and the data lands a full
  // write latency late.
  output logic                        dfi_wrdata_valid,
  output logic [AG_BYTES*8-1:0]       dfi_wrdata,
  input  logic [AG_BYTES*8-1:0]       wr_data,

  input  logic                        dfi_rddata_valid,
  input  logic [DFI_DATA_W-1:0]       dfi_rddata,

  // ---- read return to the core --------------------------------------------
  output logic                        rd_valid,
  output tag_t                        rd_tag,
  output logic [DFI_DATA_W-1:0]       rd_data,

  // ---- status --------------------------------------------------------------
  output logic                        rdfifo_overflow,
  output logic                        rdfifo_underflow,
  // In-flight read count.  Exposed as a perf counter: it is the measured PHY
  // round trip in cycles, so it tells the integrator directly how much of
  // RD_FIFO_DEPTH their PHY actually consumes (docs/05-integration-guide.md 5).
  output logic [$clog2(RD_FIFO_DEPTH):0] rdfifo_level,
  output logic                        rdfifo_at_limit
);

  // ---- command formatting --------------------------------------------------
  // The row and column buses are physically separate (constraint C3), so both
  // may carry a command in the same core clock.  Nothing here may serialise
  // them -- that would throw away half the command bandwidth.
  // The DFI command strobes are combinational, so they need an EXPLICIT reset
  // term.  Without one, a slice whose boot gate happens to be tied high drives
  // commands onto the bus while rst_n is asserted -- the refresh engine requests
  // as soon as banks read idle, which after reset is all of them.
  //
  // In the assembled system this was masked: cmd_en comes from seq_done, a
  // register that resets to zero, so the arbiters were gated anyway.  Relying on
  // that is relying on how the level above happens to be wired, which is not a
  // guarantee this block can make for an integrator who instantiates the slice
  // directly.  The same class of mistake as busy/quiesced in Rev 0.9.
  // Write data accompanies its column command.  The PHY applies WL alignment
  // (tphy_wrlat), so the controller must NOT pre-delay it -- the two delays
  // would compound and the data would land a full write latency late.
  assign dfi_wrdata       = wr_data;
  assign dfi_wrdata_valid = col_iss.valid && rst_n
                         && ((col_iss.cmd == COL_WR) || (col_iss.cmd == COL_WRA));

  always_comb begin
    dfi_row_valid = '0;
    dfi_col_valid = '0;
    for (int unsigned p = 0; p < 2; p++) begin
      dfi_row_cmd [p] = ROW_NOP;
      dfi_row_bank[p] = '0;
      dfi_row_addr[p] = '0;
      dfi_col_cmd [p] = COL_NOP;
      dfi_col_bank[p] = '0;
      dfi_col_addr[p] = '0;
    end

    if (row_iss.valid) begin
      dfi_row_valid[ROW_PHASE] = rst_n;
      dfi_row_cmd  [ROW_PHASE] = row_iss.cmd;
      dfi_row_bank [ROW_PHASE] = row_iss.bank;
      dfi_row_addr [ROW_PHASE] = row_iss.row;
    end

    if (col_iss.valid) begin
      dfi_col_valid[COL_PHASE] = rst_n;
      dfi_col_cmd  [COL_PHASE] = col_iss.cmd;
      dfi_col_bank [COL_PHASE] = col_iss.bank;
      dfi_col_addr [COL_PHASE] = col_iss.col;
    end
  end

  // ---- read tracking -------------------------------------------------------
  logic is_read;
  assign is_read = col_iss.valid
                && ((col_iss.cmd == COL_RD) || (col_iss.cmd == COL_RDA));

  logic   fifo_empty;
  tag_t   fifo_pop_idx;
  // Pointer observability is exported for silicon debug; not consumed here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(RD_FIFO_DEPTH)-1:0] fifo_wptr, fifo_rptr;
  /* verilator lint_on UNUSEDSIGNAL */

  hbm4_rd_ptr_fifo #(.DEPTH(RD_FIFO_DEPTH), .PW(TAG_W)) u_rdfifo (
    .clk (clk), .rst_n (rst_n),
    .push (is_read), .push_idx (col_tag),
    .pop (dfi_rddata_valid), .pop_idx (fifo_pop_idx),
    .empty (fifo_empty), .full (rdfifo_at_limit), .level (rdfifo_level),
    .overflow_err (rdfifo_overflow), .underflow_err (rdfifo_underflow),
    .dbg_wptr (fifo_wptr), .dbg_rptr (fifo_rptr)
  );

  // Read data is returned in command order by the DRAM, so the FIFO head is
  // always the owner of the data arriving now.
  assign rd_valid  = dfi_rddata_valid && !fifo_empty;
  assign rd_tag    = fifo_pop_idx;
  assign rd_data   = dfi_rddata;

endmodule
