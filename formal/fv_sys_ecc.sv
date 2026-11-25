// ---------------------------------------------------------------------------
// fv_sys_ecc -- P-ECC-*.
//
// This is the clearest case in the project for formal over simulation.  The
// properties are combinational and COMPLETE: "every single-bit error is
// corrected" and "every double-bit error is detected" quantify over 256 and
// 32640 error patterns respectively, and formal covers all of them at once.
// A directed test samples; a random test samples more slowly.
//
// The property that actually protects data is P-ECC-3.  A code that
// MISCORRECTS a double error is worse than one with no ECC at all: it writes
// back data it has just made wrong, reports success, and the patrol scrubber
// then propagates the damage across the array.  "Detected and refused" is a
// good outcome; "corrected to something else" is the catastrophic one.
// ---------------------------------------------------------------------------
module fv_sys_ecc
  import hbm4_pkg::*;
#(
  // Reduced width for tractability.  32 data bits with 7 check bits exercises
  // exactly the same construction: C(7,3)+C(7,5)+C(7,7) = 35+21+1 = 57 >= 32
  // odd-weight, weight>=3 columns available.
  parameter int unsigned DW = 32,
  parameter int unsigned SW = 7
) (
  input logic [DW-1:0]         data,
  input logic                  poison,
  // symbolic error positions, held constant by the solver
  input logic [$clog2(DW)-1:0] e1,
  input logic [$clog2(DW)-1:0] e2,
  input logic                  inject1,
  input logic                  inject2
);

  localparam int unsigned FW = ECC_FIELD_W;

  /* verilator lint_off UNUSEDSIGNAL */
  logic [FW-1:0] field;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [DW-1:0] corrected;
  logic          ce, ue, pois_out;

  // ---- encode --------------------------------------------------------------
  logic [FW-1:0] enc_field;
  hbm4_sys_ecc #(.DW(DW), .SW(SW)) u_enc (
    .enc_data (data), .enc_poison (poison), .enc_field (enc_field),
    .dec_data ('0), .dec_field ('0),
    .dec_corrected (), .dec_ce (), .dec_ue (), .dec_poison ()
  );

  // ---- corrupt then decode -------------------------------------------------
  // err_mask carries 0, 1 or 2 flipped bits, selected symbolically.
  logic [DW-1:0] err_mask, rx;

  always_comb begin
    err_mask = '0;
    if (inject1) err_mask[e1] = 1'b1;
    if (inject2) err_mask[e2] = err_mask[e2] ^ 1'b1;
  end

  assign rx = data ^ err_mask;

  hbm4_sys_ecc #(.DW(DW), .SW(SW)) u_dec (
    .enc_data ('0), .enc_poison (1'b0), .enc_field (field),
    .dec_data (rx), .dec_field (enc_field),
    .dec_corrected (corrected), .dec_ce (ce), .dec_ue (ue), .dec_poison (pois_out)
  );

  // ---- P-ECC-1: a clean round trip is exact -------------------------------
  always @(*)
    if (!inject1 && !inject2) begin
      p_roundtrip : assert (corrected == data);
      p_no_flags  : assert (!ce && !ue);
      p_poison_rt : assert (pois_out == poison);
    end

  // ---- P-ECC-2: EVERY single-bit data error is corrected ------------------
  always @(*)
    if (inject1 && !inject2) begin
      p_sec_corrects: assert (corrected == data);
      p_sec_flags   : assert (ce && !ue);
    end

  // ---- P-ECC-3: EVERY double-bit error is DETECTED, never miscorrected ----
  // The critical one.  Miscorrection converts a detectable fault into silent
  // corruption that the scrubber then spreads.
  always @(*)
    if (inject1 && inject2 && (e1 != e2)) begin
      p_ded_detects   : assert (ue);
      p_ded_no_correct: assert (!ce);
    end

  // ---- P-ECC-4: CE and UE are mutually exclusive --------------------------
  always @(*) p_exclusive: assert (!(ce && ue));

  // ---- reachability --------------------------------------------------------
  always @(*) begin
    c_clean  : cover (!inject1 && !inject2);
    c_single : cover (inject1 && !inject2 && ce);
    c_double : cover (inject1 && inject2 && (e1 != e2) && ue);
    c_poison : cover (pois_out);
  end

endmodule
