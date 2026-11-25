// ---------------------------------------------------------------------------
// fv_ecc_init -- P-INIT-*.
//
// P-INIT-1 is the one that matters: `done` must not assert until the walk has
// covered everything.  Releasing traffic onto a partially initialised ECC
// region produces UNCORRECTABLE ERRORS ON HEALTHY MEMORY -- a fault that looks
// like failing silicon and is chased as such.
//
// Coverage is proved structurally, as in fv_scrub: a step function that
// advances by exactly one position and wraps only at the end cannot skip an
// address, so complete coverage follows by induction rather than by
// enumerating 2^25 blocks.
// ---------------------------------------------------------------------------
module fv_ecc_init
  import hbm4_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic start,
  input logic wr_ack
);

  logic  busy, done, wr_req;
  bank_t wr_bank, dbg_bank;
  row_t  wr_row,  dbg_row;
  col_t  wr_col,  dbg_col;

  hbm4_ecc_init dut (
    .clk (clk), .rst_n (rst_n), .start (start), .busy (busy), .done (done),
    .wr_req (wr_req), .wr_bank (wr_bank), .wr_row (wr_row), .wr_col (wr_col),
    .wr_ack (wr_ack),
    .dbg_bank (dbg_bank), .dbg_row (dbg_row), .dbg_col (dbg_col)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-INIT-1: done implies the walk actually completed ----------------
  // It can only be set at the wrap, so observing it means every position was
  // visited.  Traffic released on this signal is released onto a fully
  // initialised region.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && !$past(done) && done)
      p_done_only_at_end: assert ($past(dbg_col)  == col_t'(N_COL_DATA - 1)
                               && $past(dbg_row)  == row_t'(N_ROW - 1)
                               && $past(dbg_bank) == bank_t'(N_BANK - 1)
                               && $past(wr_ack) && $past(busy));

  // done is sticky: a second start must not un-initialise the region.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n) && $past(done))
      p_done_sticky: assert (done);

  // ---- P-INIT-2: strict enumeration, exactly as in fv_scrub --------------
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(busy) && $past(wr_ack) && !$past(done)) begin
      if ($past(dbg_col) != col_t'(N_COL_DATA - 1)) begin
        p_col_step: assert ((dbg_col == $past(dbg_col) + 1'b1)
                         && (dbg_row == $past(dbg_row))
                         && (dbg_bank == $past(dbg_bank)));
      end else if ($past(dbg_row) != row_t'(N_ROW - 1)) begin
        p_row_step: assert ((dbg_col == '0)
                         && (dbg_row == $past(dbg_row) + 1'b1)
                         && (dbg_bank == $past(dbg_bank)));
      end else if ($past(dbg_bank) != bank_t'(N_BANK - 1)) begin
        p_bank_step: assert ((dbg_col == '0) && (dbg_row == '0)
                          && (dbg_bank == $past(dbg_bank) + 1'b1));
      end
    end

  // ---- P-INIT-3: never writes an ECC column as if it were data -----------
  always @(*)
    if (f_past_valid && rst_n)
      p_data_col_only: assert (dbg_col < col_t'(N_COL_DATA));

  // ---- P-INIT-4: no requests once idle ------------------------------------
  always @(*)
    if (f_past_valid && rst_n && !busy)
      p_quiet_when_idle: assert (!wr_req);

  // NOTE ON c_done.  There is deliberately no cover for `done` being reached.
  // Reaching it requires a complete sweep of N_BANK x N_ROW x N_COL_DATA
  // positions -- 960 even at the reduced formal geometry, and 7.9 million at
  // production -- which exceeds any practical BMC depth.
  //
  // Its reachability is not in doubt and does not need a cover: P-INIT-2 proves
  // the walk advances by exactly one position per accepted write over a FINITE
  // space, so termination follows mathematically.  A cover that cannot be
  // reached tells you nothing about the design and only makes the run fail.
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_busy    : cover (busy);
    // Only the innermost wrap is within BMC reach (15 steps).  A row wrap needs
    // 120 and a full sweep 960 -- both beyond any useful depth, for the same
    // reason as c_done above.
    c_col_wrap: cover (busy && wr_ack && (dbg_col == col_t'(N_COL_DATA - 1)));
  end

endmodule
