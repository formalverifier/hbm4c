// ---------------------------------------------------------------------------
// hbm4_rd_ptr_fifo -- in-flight read tracking across the PHY.
//
// The controller issues a column read and the data comes back some number of
// cycles later, decided by the PHY.  Rather than hardcode that latency, the
// pool index is pushed here at command issue and popped on dfi_rddata_valid.
//
// Why this is the right decoupling: read latency is measured during training
// (boot step 10) and differs by PHY vendor, by frequency, and after every
// DVFS retrain.  Anything that hardcoded it would need re-verifying per
// customer.  The ONLY thing this design needs to know is that the latency is
// BOUNDED -- and RD_FIFO_DEPTH is that bound.
//
// DRAM returns read data strictly in command order, so a plain FIFO is exact:
// no tags, no reordering, no CAM.
//
// Overflow means the PHY's round trip exceeded RD_FIFO_DEPTH.  It is reported,
// never silently wrapped: a wrapped pointer would route read data to the wrong
// transaction, which is silent data corruption of the worst kind -- the data is
// valid, it just belongs to somebody else.
// ---------------------------------------------------------------------------
module hbm4_rd_ptr_fifo
  import hbm4_pkg::*;
#(
  parameter int unsigned DEPTH = 32,
  // Payload is opaque.  Integration carries the TAG rather than the pool index:
  // the pool entry is freed at issue, so by the time data returns the index no
  // longer identifies anything.  Widening this here beats a side-table that has
  // to be kept coherent with the pool.
  parameter int unsigned PW    = TAG_W,
  localparam int unsigned AW    = $clog2(DEPTH)
) (
  input  logic         clk,
  input  logic         rst_n,

  input  logic         push,          // a column read was issued
  input  logic [PW-1:0] push_idx,
  input  logic         pop,           // dfi_rddata_valid
  output logic [PW-1:0] pop_idx,

  output logic         empty,
  output logic         full,
  output logic [AW:0]  level,
  output logic         overflow_err,  // PHY round trip exceeded DEPTH
  output logic         underflow_err, // data returned that was never requested
  // Pointer observability.  Needed by the formal wrapper (Yosys cannot
  // width-resolve a hierarchical reference in a cast), and useful in silicon
  // debug to see exactly how deep the PHY round trip runs.
  output logic [AW-1:0] dbg_wptr,
  output logic [AW-1:0] dbg_rptr
);

  logic [PW-1:0] mem [DEPTH];
  logic [AW-1:0] wptr, rptr;
  logic [AW:0]   cnt;

  assign empty   = (cnt == '0);
  assign full    = (cnt == (AW+1)'(DEPTH));
  assign level   = cnt;
  assign pop_idx = mem[rptr];

  assign dbg_wptr = wptr;
  assign dbg_rptr = rptr;

  assign overflow_err  = push && full;
  assign underflow_err = pop  && empty;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
      cnt  <= '0;
    end else begin
      // Both guards are load-bearing.  Pushing when full would overwrite an
      // in-flight entry; popping when empty would advance the read pointer past
      // valid entries.  Either one silently mis-routes read data.
      if (push && !full) begin
        mem[wptr] <= push_idx;
        wptr      <= (wptr == AW'(DEPTH-1)) ? '0 : AW'(wptr + 1'b1);
      end
      if (pop && !empty)
        rptr <= (rptr == AW'(DEPTH-1)) ? '0 : AW'(rptr + 1'b1);

      case ({push && !full, pop && !empty})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: ;
      endcase
    end
  end

endmodule
