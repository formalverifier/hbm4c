// ---------------------------------------------------------------------------
// hbm4_wdata_ram -- write-data storage, held from allocation until the write is
// issued to the DRAM.
//
// WHY THIS BLOCK EXISTS.  Until Rev 1.2 the design had NO WRITE DATAPATH at all.
// The NHI carried `req_wr` -- a direction bit -- and no data; the DFI adapter
// had `dfi_rddata` in and nothing out.  A write issued a WR command carrying an
// address, and no data ever reached the device.
//
// INDEXED BY POOL ENTRY, not by the host's tag.  The pool entry is the one
// identifier that is unique among in-flight transactions by construction: the
// pool hands out a free entry on allocation (`alloc_idx`) and names the entry
// it pops on issue (`issue_idx`), and no entry is reused before it is popped.
//
// Rev 1.3 indexed this RAM by tag, and it was wrong twice over.  At production
// geometry a tag is 8 bits and this RAM has TQ_DEPTH = 64 entries, so the index
// was silently truncated and tags t and t+64 shared an entry.  And docs/03 rule
// H2 requires tags to be unique among outstanding READS only, so a host that
// follows the interface may legally reuse one tag across outstanding writes.
// Either way a later write overwrote a queued write's data, and the queued write
// then put the wrong bytes at a correct address with no error anywhere.  Formal
// could not see it (under FV_SMALL the tag is exactly as wide as this index);
// lint could (WIDTHTRUNC on every index), at production geometry only.
//
// THE CALLER STORES AT ALLOCATION, NOT AT REQUEST.  The pool entry is not known
// until the request leaves the two-cycle address decode, so hbm4_pc_slice
// carries the data down that pipeline alongside the tag and writes it here in
// the cycle the pool allocates.
//
// `err_no_data` flags a write issued from an entry that holds no data since its
// last issue.  With storage keyed by pool entry and written at allocation, that
// is an INTERNAL fault -- a broken index or a lost store -- never a host error.
// It must be visible rather than inferred later from bad memory.
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

  // ---- store, when the pool allocates a write ------------------------------
  input  logic                    wr_valid,
  input  tqidx_t                  wr_idx,
  input  logic [DW-1:0]           wr_data,

  // ---- fetch, when the column write issues --------------------------------
  input  logic                    rd_valid,
  input  tqidx_t                  rd_idx,
  output logic [DW-1:0]           rd_data,

  output logic                    err_no_data,   // issued a write with no data

  output logic [TQ_DEPTH-1:0]     dbg_written
);

  logic [DW-1:0] mem [TQ_DEPTH];
  logic [TQ_DEPTH-1:0]   written;

  assign rd_data     = mem[rd_idx];
  assign dbg_written = written;

  // Flagged combinationally on the issue cycle: by the time the command has left
  // the controller it is too late to do anything but report it.
  assign err_no_data = rd_valid && !written[rd_idx];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      written <= '0;
    end else begin
      if (wr_valid) begin
        mem[wr_idx]     <= wr_data;
        written[wr_idx] <= 1'b1;
      end
      // Cleared on issue so a REUSED entry cannot silently inherit the previous
      // transaction's data -- without this, an entry re-allocated to a write
      // whose store was lost would write the old block to a new address.
      if (rd_valid && !(wr_valid && (wr_idx == rd_idx)))
        written[rd_idx] <= 1'b0;
    end
  end

endmodule
