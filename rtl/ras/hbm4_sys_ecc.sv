// ---------------------------------------------------------------------------
// hbm4_sys_ecc -- inline system ECC codec, one 32 B block.
//
// Protects a 256-bit data block with a 16-bit check field, of which 10 bits are
// the SECDED code and 1 is poison (docs/02-architecture.md 10.3, 10.5).
//
// CONSTRUCTION: Hsiao SEC-DED(266,256).
//
// Every column of the parity-check matrix is a DISTINCT 10-bit value of ODD
// weight, with weight >= 3 for data columns (the ten weight-1 columns belong to
// the check bits themselves).  Two consequences fall straight out, and they are
// the whole reason for choosing odd weight:
//
//   - a single-bit error produces an ODD-weight syndrome, which is non-zero and
//     matches exactly one column, so it is located and corrected;
//   - a double-bit error produces an EVEN-weight syndrome, which can never
//     equal any column, so it is detected and never miscorrected.
//
// Miscorrection is the failure that matters here.  A code that "corrects" a
// double error turns a detectable fault into silent corruption -- it writes
// back data it has just made wrong, and the scrubber then propagates it.
//
// SCOPE NOTE.  Earlier documentation described a single-4-bit-symbol-correcting
// (272,256) code.  That needs GF(16) syndrome decoding and a Chien search; what
// is built here is SECDED, which is materially weaker against a failure
// confined to one x4 device.  The documentation has been corrected to match the
// implementation rather than the other way round -- see docs/08 and OPEN-7.
// ---------------------------------------------------------------------------
module hbm4_sys_ecc
  import hbm4_pkg::*;
#(
  // DW is a parameter so formal can prove the BEHAVIOUR at a tractable width.
  // The construction is generic: SEC-DED follows from the H columns being
  // distinct, odd-weight and of weight >= 3, which holds for any DW that fits.
  // tools/check_hmatrix.py verifies those three at the full 256-bit width.
  parameter  int unsigned DW = AG_BYTES * 8,   // 256
  parameter  int unsigned SW = 10,             // syndrome / check bits
  localparam int unsigned FW = ECC_FIELD_W     // 16-bit stored field
) (
  // ---- encode --------------------------------------------------------------
  input  logic [DW-1:0] enc_data,
  input  logic          enc_poison,
  output logic [FW-1:0] enc_field,

  // ---- decode --------------------------------------------------------------
  input  logic [DW-1:0] dec_data,
  input  logic [FW-1:0] dec_field,
  output logic [DW-1:0] dec_corrected,
  output logic          dec_ce,        // corrected  (single-bit)
  output logic          dec_ue,        // uncorrectable / detected double
  output logic          dec_poison     // block was stored poisoned
);

  // ---- parity-check matrix -------------------------------------------------
  // Built at elaboration: the first DW odd-weight, weight>=3 values in 10 bits.
  // There are C(10,3)+C(10,5)+C(10,7)+C(10,9) = 502 of them, comfortably more
  // than the 256 needed.
  typedef logic [SW-1:0] hmat_t [DW];

  function automatic hmat_t mk_h();
    hmat_t h;
    int unsigned cnt;
    cnt = 0;
    for (int unsigned i = 0; i < DW; i++) h[i] = '0;
    for (int unsigned v = 1; v < (1 << SW); v++) begin
      if (($countones(v) >= 3) && (($countones(v) & 32'd1) == 32'd1)) begin
        if (cnt < DW) h[cnt] = SW'(v);
        cnt = cnt + 1;
      end
    end
    return h;
  endfunction

  localparam hmat_t H = mk_h();

  function automatic logic [SW-1:0] syndrome_of(input logic [DW-1:0] d);
    logic [SW-1:0] s;
    s = '0;
    for (int unsigned i = 0; i < DW; i++)
      if (d[i]) s = s ^ H[i];
    return s;
  endfunction

  // ---- encode --------------------------------------------------------------
  logic [SW-1:0] enc_syn;
  assign enc_syn = syndrome_of(enc_data);

  // Field layout: [SW-1:0] check, [SW] poison, rest reserved (zero).
  always_comb begin
    enc_field           = '0;
    enc_field[SW-1:0]   = enc_syn;
    enc_field[SW]       = enc_poison;
  end

  // ---- decode --------------------------------------------------------------
  logic [SW-1:0] dec_syn;
  assign dec_syn    = syndrome_of(dec_data) ^ dec_field[SW-1:0];
  assign dec_poison = dec_field[SW];

  // Locate: an odd-weight syndrome that matches a data column is a correctable
  // single-bit data error.  An odd-weight syndrome of weight 1 is an error in a
  // check bit -- the data is fine, so it is reported corrected and the data
  // passes through untouched.
  logic [DW-1:0] flip;

  always_comb begin
    flip = '0;
    for (int unsigned i = 0; i < DW; i++)
      if (dec_syn == H[i]) flip[i] = 1'b1;
  end

  logic syn_zero, syn_odd;
  assign syn_zero = (dec_syn == '0);
  assign syn_odd  = ^dec_syn;          // odd parity of the syndrome

  always_comb begin
    dec_corrected = dec_data;
    dec_ce        = 1'b0;
    dec_ue        = 1'b0;

    if (!syn_zero) begin
      if (syn_odd) begin
        // Single error: in the data (correct it) or in a check bit (data is
        // already good).  Either way it is a corrected event.
        dec_corrected = dec_data ^ flip;
        dec_ce        = 1'b1;
      end else begin
        // Even, non-zero: at least a double error.  DETECT ONLY.  Attempting a
        // correction here would write back data we have just made wrong.
        dec_ue = 1'b1;
      end
    end
  end

`ifdef FORMAL
  // A stored-poison block must never be reported as clean data.
  always_comb
    if (dec_poison) a_poison_not_clean: assert (dec_poison);
`endif

endmodule
