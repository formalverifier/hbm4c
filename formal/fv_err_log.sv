// ---------------------------------------------------------------------------
// fv_err_log -- P-LOG-*.
//
// The property worth proving is P-LOG-1: the sticky first-error latch survives
// an unbounded storm of subsequent errors.
//
// A real fault never arrives alone.  A failing device produces a burst, the
// patrol scrubber then finds the same region and produces more, and a 16-entry
// FIFO holds only the last few -- which are consequences, not the cause.  If
// the latch can be overwritten, post-mortem debug is left with a log full of
// symptoms and no origin, on hardware that has already been returned.
//
// This is cheap to prove and essentially impossible to test convincingly: the
// interesting case is "an arbitrary number of arbitrary later errors", which is
// exactly what a bounded random test cannot cover.
// ---------------------------------------------------------------------------
module fv_err_log
  import hbm4_pkg::*;
#(
  parameter int unsigned DEPTH = 4
) (
  input logic        clk,
  input logic        rst_n,
  input logic        err_valid,
  input logic [3:0]  err_type,
  input bank_t       err_bank,
  input row_t        err_row,
  input col_t        err_col,
  input logic [15:0] err_syndrome,
  input logic [31:0] timestamp,
  input logic        pop,
  input logic        first_clr
);

  localparam int unsigned AW = $clog2(DEPTH);

  logic          fifo_valid, overflow, first_valid;
  logic [3:0]    fifo_type, first_type;
  bank_t         fifo_bank, first_bank;
  row_t          fifo_row,  first_row;
  col_t          fifo_col,  first_col;
  logic [15:0]   fifo_syndrome, first_syndrome;
  logic [31:0]   fifo_time, first_time;
  logic [AW:0]   fifo_level;

  hbm4_err_log #(.DEPTH(DEPTH)) dut (
    .clk (clk), .rst_n (rst_n),
    .err_valid (err_valid), .err_type (err_type), .err_bank (err_bank),
    .err_row (err_row), .err_col (err_col), .err_syndrome (err_syndrome),
    .timestamp (timestamp),
    .pop (pop), .first_clr (first_clr),
    .fifo_valid (fifo_valid), .fifo_type (fifo_type), .fifo_bank (fifo_bank),
    .fifo_row (fifo_row), .fifo_col (fifo_col), .fifo_syndrome (fifo_syndrome),
    .fifo_time (fifo_time), .fifo_level (fifo_level), .overflow (overflow),
    .first_valid (first_valid), .first_type (first_type), .first_bank (first_bank),
    .first_row (first_row), .first_col (first_col),
    .first_syndrome (first_syndrome), .first_time (first_time)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-LOG-1: the first-error latch is STICKY ---------------------------
  // Once captured it holds, through any number of later errors, until firmware
  // explicitly clears it.  No amount of storm can displace the origin.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(first_valid) && !$past(first_clr)) begin
      p_first_sticky : assert (first_valid);
      p_first_stable : assert ((first_type     == $past(first_type))
                            && (first_bank     == $past(first_bank))
                            && (first_row      == $past(first_row))
                            && (first_col      == $past(first_col))
                            && (first_syndrome == $past(first_syndrome))
                            && (first_time     == $past(first_time)));
    end

  // ---- P-LOG-2: an error that OVERFLOWS the FIFO can still be the first ---
  // A storm that begins with the log already full must not lose its own
  // origin.  The latch is therefore not gated on the FIFO accepting the entry.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(err_valid) && !$past(first_valid) && !$past(first_clr))
      p_first_captured: assert (first_valid);

  // ---- P-LOG-3: the FIFO drops NEW entries, never evicts old ones ---------
  // Under a storm the oldest entries are nearest the cause; evicting them
  // discards exactly what the log exists to preserve.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(fifo_level == (AW+1)'(DEPTH)) && $past(err_valid) && !$past(pop)) begin
      p_no_evict : assert (fifo_level == (AW+1)'(DEPTH));
      p_overflow : assert ($past(overflow));
    end

  // ---- P-LOG-4: level accounting ------------------------------------------
  always @(*)
    if (f_past_valid && rst_n) begin
      p_level_bound: assert (fifo_level <= (AW+1)'(DEPTH));
      p_valid_flag : assert (fifo_valid == (fifo_level != '0));
    end

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_first     : cover (first_valid);
    c_overflow  : cover (overflow);
    // The case the latch exists for: a storm arriving after the origin.
    c_storm     : cover (first_valid && overflow);
    c_cleared   : cover (!first_valid && $past(first_valid));
  end

endmodule
