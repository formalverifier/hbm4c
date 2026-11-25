// ---------------------------------------------------------------------------
// hbm4_hash -- programmable XOR-fold of high address bits into a field index.
//
// THIS IS THE SHARED SOURCE.  Both hbm4_addr_slice (which lives in the
// customer's fabric) and hbm4_addr_decode (which lives in the controller)
// instantiate this module.  They must never be allowed to drift apart: if the
// fabric routes a request to pseudo-channel A while the controller decodes it
// as belonging at address B, memory is corrupted with NO error indication
// anywhere in the system.  See docs/03-interface-spec.md 4 and the formal
// miter fv_addr_slice_miter (property P-MAP-3).
//
// Why hashing is not optional: a raw bit-slice map sends every access of an
// 8 KB-strided stream -- extremely common in tensor tiling -- to a single
// pseudo-channel of a single stack.  That is 32 GB/s on an 8 TB/s machine.
// ---------------------------------------------------------------------------
module hbm4_hash #(
  parameter int unsigned IN_W  = 38,
  parameter int unsigned OUT_W = 6
) (
  input  logic [IN_W-1:0]            addr,
  input  logic [OUT_W-1:0]           base,   // raw bit-select value
  input  logic [OUT_W-1:0][IN_W-1:0] mask,   // CSR-programmed, one per output bit
  output logic [OUT_W-1:0]           hashed
);

  // A zero mask makes this the identity, which is what the reset value gives:
  // the design comes up with the plain bit-slice map and firmware programs the
  // folds afterwards.
  for (genvar i = 0; i < int'(OUT_W); i++) begin : g_bit
    assign hashed[i] = base[i] ^ (^(addr & mask[i]));
  end

endmodule
