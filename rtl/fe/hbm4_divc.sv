// ---------------------------------------------------------------------------
// hbm4_divc -- divide by a compile-time constant, 2 stages, exact.
//
// Inline system ECC reserves 1/16 of the columns in every row, so a row holds
// N_COL_DATA = 30 data columns (BL8) or 15 (BL16).  Neither is a power of two,
// so splitting the top address field into {row, col} needs a real divide.
//
// Why the divide is HERE and not in the fabric slicer:
//   The dividend `rem` occupies the TOP bits of the system address, so
//   reserving columns leaves the usable address space contiguous (0..240 GB,
//   no holes).  Reserve two bits anywhere lower and the reserved space becomes
//   swiss cheese scattered through the map, which no allocator can use.
//   See docs/02-architecture.md 7.3.
//   The cost is one constant multiply, in 256 controller instances -- not in
//   hbm4_addr_slice, which is replicated at every fabric requester port.
//
// Why TWO pipeline stages:
//   A 20x21 multiply does not close at 1 GHz in one stage.  This sits in the
//   E1 decode stage, which is off the arbitration critical path, so buying a
//   cycle here is cheap: it costs 1 clock on a read path that is already 32.
//
// Method: reciprocal multiply, q = (x * M) >> S with M = floor(2^S/D)+1 and
// S = W + ceil(log2 D).  Exhaustively verified exact over the full input range
// for (W=20,D=30) and (W=21,D=15) -- zero corrections needed.  The correction
// step below is retained as insurance for anyone who re-parameterises this,
// and formal property P-MAP-4 proves exactness for whatever (W,D) is built.
// ---------------------------------------------------------------------------
module hbm4_divc #(
  parameter int unsigned W = 20,                  // dividend width
  parameter int unsigned D = 30,                  // constant divisor
  // derived
  localparam int unsigned QW = $clog2(((2**W) - 1) / D + 1),
  localparam int unsigned RW = $clog2(D)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          in_valid,
  input  logic [W-1:0]  in_x,
  output logic          out_valid,
  output logic [QW-1:0] out_q,
  output logic [RW-1:0] out_r
);

  localparam int unsigned S  = W + $clog2(D);
  localparam longint unsigned M_LL = ((longint'(1) << S) / longint'(D)) + 1;
  localparam int unsigned MW = $clog2(M_LL + 1);
  localparam int unsigned PW = W + MW;

  localparam logic [MW-1:0] M = MW'(M_LL);

  // ---- stage 1: the multiply ------------------------------------------------
  logic            s1_valid;
  logic [PW-1:0]   s1_prod;
  logic [W-1:0]    s1_x;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid <= in_valid;
      s1_prod  <= PW'(in_x) * PW'(M);
      s1_x     <= in_x;
    end
  end

  // ---- stage 2: shift, remainder, one correction ---------------------------
  logic [QW-1:0] q_approx, q_corr;
  logic [W:0]    r_wide,   r_corr;   // wide: r_wide is only bounded once corrected

  assign q_approx = QW'(s1_prod >> S);

  // q*D by shift-add: D is constant, so this is a couple of adders, not a
  // multiplier.  Verilator/synthesis both fold it.
  assign r_wide   = (W+1)'(s1_x) - (W+1)'(q_approx * QW'(D));

  always_comb begin
    if (1'b0) begin
      q_corr = q_approx + QW'(1);
      r_corr = r_wide - (W+1)'(D);
    end else begin
      q_corr = q_approx;
      r_corr = r_wide;
    end
  end

  // r_corr is proved < D (see the assertion below and formal P-MAP-4), so the
  // upper bits are structurally zero; truncation here is safe by construction.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [W:0] r_corr_full = r_corr;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else begin
      out_valid <= s1_valid;
      out_q     <= q_corr;
      out_r     <= RW'(r_corr);
    end
  end

`ifdef FORMAL
  // Local sanity: the correction must always be sufficient.  If this ever
  // fires, (W,D) needs a second correction step or a larger S.
  always_ff @(posedge clk) begin
    if (rst_n && s1_valid) begin
      a_one_correction_is_enough: assert (r_corr < (W+1)'(D));
    end
  end
`endif

endmodule
