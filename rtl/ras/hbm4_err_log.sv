// ---------------------------------------------------------------------------
// hbm4_err_log -- RAS error log with a sticky first-error latch.
//
// Two structures, deliberately separate:
//
//   a 16-entry FIFO   -- recent history, overwritten under load
//   a FIRST-ERROR latch -- the first event since the log was cleared, sticky
//
// The latch is the point.  A real fault does not arrive alone: a failing device
// produces a burst, the patrol scrubber then finds the same region and produces
// more, and a 16-entry FIFO holds only the last few -- which are consequences,
// not the cause.  Post-mortem debug needs the FIRST event, and it must survive
// however many follow it.
//
// So the FIFO drops NEW entries when full rather than evicting old ones, and
// the latch cannot be overwritten at all until firmware explicitly clears it
// (docs/04-programming-guide.md 5.2: read the latch BEFORE draining the FIFO).
// ---------------------------------------------------------------------------
module hbm4_err_log
  import hbm4_pkg::*;
#(
  parameter int unsigned DEPTH = 16,
  localparam int unsigned AW   = $clog2(DEPTH)
) (
  input  logic          clk,
  input  logic          rst_n,

  // ---- error events --------------------------------------------------------
  input  logic          err_valid,
  input  logic [3:0]    err_type,      // see IRQ_STATUS in the programming guide
  input  bank_t         err_bank,
  input  row_t          err_row,
  input  col_t          err_col,
  input  logic [15:0]   err_syndrome,
  input  logic [31:0]   timestamp,

  // ---- firmware access -----------------------------------------------------
  input  logic          pop,           // drain one FIFO entry
  input  logic          first_clr,     // explicit: clears the sticky latch
  output logic          fifo_valid,
  output logic [3:0]    fifo_type,
  output bank_t         fifo_bank,
  output row_t          fifo_row,
  output col_t          fifo_col,
  output logic [15:0]   fifo_syndrome,
  output logic [31:0]   fifo_time,
  output logic [AW:0]   fifo_level,
  output logic          overflow,      // events were dropped

  // ---- sticky first error --------------------------------------------------
  output logic          first_valid,
  output logic [3:0]    first_type,
  output bank_t         first_bank,
  output row_t          first_row,
  output col_t          first_col,
  output logic [15:0]   first_syndrome,
  output logic [31:0]   first_time
);

  typedef struct packed {
    logic [3:0]  etype;
    bank_t       bank;
    row_t        row;
    col_t        col;
    logic [15:0] syndrome;
    logic [31:0] tstamp;
  } rec_t;

  rec_t incoming;
  assign incoming = '{etype: err_type, bank: err_bank, row: err_row,
                      col: err_col, syndrome: err_syndrome, tstamp: timestamp};

  // ---- FIFO ----------------------------------------------------------------
  rec_t          mem [DEPTH];
  logic [AW-1:0] wptr, rptr;
  logic [AW:0]   cnt;
  logic          full;

  assign full       = (cnt == (AW+1)'(DEPTH));
  assign fifo_valid = (cnt != '0);
  assign fifo_level = cnt;

  // Drop NEW entries when full; never evict old ones.  Under a fault storm the
  // oldest entries are the ones nearest the cause, so evicting them would throw
  // away exactly the information the log exists to preserve.
  logic push;
  assign push     = err_valid && !full;
  assign overflow = err_valid && full;

  always_comb begin
    fifo_type     = mem[rptr].etype;
    fifo_bank     = mem[rptr].bank;
    fifo_row      = mem[rptr].row;
    fifo_col      = mem[rptr].col;
    fifo_syndrome = mem[rptr].syndrome;
    fifo_time     = mem[rptr].tstamp;
  end

  // ---- sticky first error --------------------------------------------------
  rec_t first_rec;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; cnt <= '0;
      first_valid <= 1'b0;
    end else begin
      if (push) begin
        mem[wptr] <= incoming;
        wptr      <= (wptr == AW'(DEPTH-1)) ? '0 : AW'(wptr + 1'b1);
      end
      if (pop && fifo_valid)
        rptr <= (rptr == AW'(DEPTH-1)) ? '0 : AW'(rptr + 1'b1);

      case ({push, pop && fifo_valid})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: ;
      endcase

      // The latch takes the first event and then holds.  Note this is NOT
      // gated on `push`: an event that overflows the FIFO must still be able to
      // become the first error, or a storm that begins at a full log would lose
      // its own origin.
      if (first_clr) begin
        first_valid <= 1'b0;
      end else if (err_valid && !first_valid) begin
        first_valid <= 1'b1;
        first_rec   <= incoming;
      end
    end
  end

  assign first_type     = first_rec.etype;
  assign first_bank     = first_rec.bank;
  assign first_row      = first_rec.row;
  assign first_col      = first_rec.col;
  assign first_syndrome = first_rec.syndrome;
  assign first_time     = first_rec.tstamp;

endmodule
