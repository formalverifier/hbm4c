// ---------------------------------------------------------------------------
// hbm4_ecc_init -- boot-time initialisation of the ECC region.
//
// WHY THIS BLOCK EXISTS.  With SYSECC_EN on, the check field for a block is
// only meaningful once it has been written.  Reading a block whose ECC column
// was never initialised decodes real data against a random check value, and
// reports an UNCORRECTABLE ERROR on memory that is perfectly healthy.
//
// So every ECC column must be written before any data block is read -- and
// "every" is the whole requirement.  Missing one block out of 2^25 produces a
// single spurious uncorrectable somewhere in the address space, which is
// exactly the kind of fault that gets chased for weeks.
//
// The walk is the same strict enumeration as hbm4_scrub, for the same reason:
// coverage is proved from the step function (advance by exactly one, wrap only
// at the end) rather than by enumerating 2^25 addresses.  The one property that
// differs is P-INIT-1 -- `done` must not assert until the wrap has happened.
//
// Cost: 256 GB / 8.19 TB/s ~= 31 ms at full rate.  Budget 50 ms of boot time
// (docs/02-architecture.md 13).
// ---------------------------------------------------------------------------
module hbm4_ecc_init
  import hbm4_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,

  input  logic       start,
  output logic       busy,
  output logic       done,          // sticky: the region is fully initialised

  // ---- write request -------------------------------------------------------
  output logic       wr_req,
  output bank_t      wr_bank,
  output row_t       wr_row,
  output col_t       wr_col,
  input  logic       wr_ack,

  output bank_t      dbg_bank,
  output row_t       dbg_row,
  output col_t       dbg_col
);

  bank_t w_bank;
  row_t  w_row;
  col_t  w_col;

  logic col_last, row_last, bank_last, at_end;
  assign col_last  = (w_col  == col_t'(N_COL_DATA - 1));
  assign row_last  = (w_row  == row_t'(N_ROW - 1));
  assign bank_last = (w_bank == bank_t'(N_BANK - 1));
  assign at_end    = col_last && row_last && bank_last;

  assign wr_bank  = w_bank;
  assign wr_row   = w_row;
  assign wr_col   = w_col;
  assign dbg_bank = w_bank;
  assign dbg_row  = w_row;
  assign dbg_col  = w_col;

  assign wr_req = busy;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w_bank <= '0; w_row <= '0; w_col <= '0;
      busy   <= 1'b0;
      done   <= 1'b0;
    end else begin
      if (start && !busy && !done) begin
        busy   <= 1'b1;
        w_bank <= '0; w_row <= '0; w_col <= '0;
      end else if (busy && wr_ack) begin
        // done asserts ONLY at the wrap, so it cannot be observed while any
        // block remains unwritten.  Anything weaker here -- a counter compare,
        // an approximate length -- risks releasing traffic onto uninitialised
        // ECC and producing spurious uncorrectables.
        if (at_end) begin
          busy <= 1'b0;
          done <= 1'b1;
        end else if (!col_last) begin
          w_col <= w_col + 1'b1;
        end else begin
          w_col <= '0;
          if (!row_last) begin
            w_row <= w_row + 1'b1;
          end else begin
            w_row  <= '0;
            w_bank <= bank_t'(w_bank + 1'b1);
          end
        end
      end
    end
  end

endmodule
