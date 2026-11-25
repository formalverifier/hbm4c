// ---------------------------------------------------------------------------
// hbm4_wdata_ram -- write-data storage, held from request until the write is
// issued to the DRAM.
//
// WHY THIS BLOCK EXISTS.  Until Rev 1.2 the design had NO WRITE DATAPATH at all.
// The NHI carried `req_wr` -- a direction bit -- and no data; the DFI adapter
// had `dfi_rddata` in and nothing out.  A write issued a WR command carrying an
// address, and no data ever reached the device.  docs/03 specifies the host side
// of it (rules H3/H5 and the WD_SKEW parameter) and none of it was implemented.
//
// INDEXED BY TAG, not by pool entry.  The transaction pool does not expose the
// index it allocated, and the tag is already unique among outstanding
// transactions -- that is a host obligation the interface spec already imposes
// (docs/03 rule H2), and the NHI's credit accounting bounds the number
// outstanding to TQ_DEPTH.  Using the tag therefore needs no change to the pool,
// which is already the largest block in the slice.
//
// A WRITE THAT ARRIVES WITHOUT DATA IS NOT DETECTED HERE.  This block stores
// what it is given.  If the host violates H3 and supplies data late, the write
// issues with whatever the RAM held -- which is the previous transaction's data
// at that tag.  That is silent corruption, so `err_no_data` flags a read of an
// entry that was never written since reset; it is a host-protocol error, and it
// must be visible rather than inferred later from bad memory.
// ---------------------------------------------------------------------------
module hbm4_wdata_ram
  import hbm4_pkg::*;
#(
  // Width is a parameter purely so the formal proof can run a FULL shadow of
  // every entry at a narrow width. The block is width-agnostic -- data flows
  // in and out unexamined -- so correctness at one width is correctness at any,
  // and that is a far stronger argument than proving one symbolic entry at the
  // production width would have been.
  parameter int unsigned DW = AG_BYTES*8
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- capture, when a write request is accepted --------------------------
  input  logic                    wr_valid,
  input  tag_t                    wr_tag,
  input  logic [DW-1:0]           wr_data,

  // ---- fetch, when the column write issues --------------------------------
  input  logic                    rd_valid,
  input  tag_t                    rd_tag,
  output logic [DW-1:0]           rd_data,

  output logic                    err_no_data,   // issued a write with no data

  output logic [TQ_DEPTH-1:0]     dbg_written
);

  logic [DW-1:0] mem [TQ_DEPTH];
  logic [TQ_DEPTH-1:0]   written;

  assign rd_data     = mem[rd_tag];
  assign dbg_written = written;

  // Flagged combinationally on the issue cycle: by the time the command has left
  // the controller it is too late to do anything but report it.
  assign err_no_data = rd_valid && !written[rd_tag];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      written <= '0;
    end else begin
      if (wr_valid) begin
        mem[wr_tag]     <= wr_data;
        written[wr_tag] <= 1'b1;
      end
      // Cleared on issue so a REUSED tag cannot silently inherit the previous
      // transaction's data -- without this, a host that reuses a tag before
      // supplying new data writes the old block to a new address.
      if (rd_valid && !(wr_valid && (wr_tag == rd_tag)))
        written[rd_tag] <= 1'b0;
    end
  end

endmodule
