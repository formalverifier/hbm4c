// ---------------------------------------------------------------------------
// fv_divc -- P-MAP-4: the constant divider is exact.
//
// row = rem / N_COL_DATA and col = rem % N_COL_DATA decide where every byte in
// the device lives.  An off-by-one anywhere in the input range puts data in
// the wrong row -- and because the map is deterministic, it would be written
// AND read from the same wrong place, so functional tests would pass and only
// a capacity or aliasing check would ever catch it.
//
// Formal proves it for EVERY input.  Simulation would need 2^20 vectors and
// still only be a sampling argument.
// ---------------------------------------------------------------------------
module fv_divc #(
  parameter int unsigned W = 20,
  parameter int unsigned D = 30
) (
  input logic         clk,
  input logic         rst_n,
  input logic         in_valid,
  input logic [W-1:0] in_x
);

  localparam int unsigned QW = $clog2(((2**W) - 1) / D + 1);
  localparam int unsigned RW = $clog2(D);
  localparam int unsigned CW = W + 2;          // width for the reconstruction

  logic          out_valid;
  logic [QW-1:0] out_q;
  logic [RW-1:0] out_r;

  hbm4_divc #(.W(W), .D(D)) dut (
    .clk (clk), .rst_n (rst_n),
    .in_valid (in_valid), .in_x (in_x),
    .out_valid (out_valid), .out_q (out_q), .out_r (out_r)
  );

  // ---- hold reset for the first cycle --------------------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);

  // ---- shadow: track the dividend through the 2-stage pipe -----------------
  // Written independently of the DUT, which is the point: if the checker
  // shared the DUT's own pipeline registers, a bug in them would be invisible.
  logic          v1, v2;
  logic [W-1:0]  x1, x2;

  always @(posedge clk) begin
    if (!rst_n) begin
      v1 <= 1'b0; v2 <= 1'b0;
    end else begin
      v1 <= in_valid; x1 <= in_x;
      v2 <= v1;       x2 <= x1;
    end
  end

  // ---- P-MAP-4 -------------------------------------------------------------
  always @(posedge clk) begin
    if (f_past_valid && rst_n && out_valid) begin
      p_valid_tracks : assert (v2);
      p_exact        : assert ((CW'(out_q) * CW'(D)) + CW'(out_r) == CW'(x2));
      p_rem_in_range : assert (out_r < RW'(D));
    end
  end

  // Reachability: prove the pipeline can actually produce a result at all,
  // so a vacuously-passing proof cannot hide behind an unreachable assertion.
  always @(posedge clk)
    if (f_past_valid && rst_n) c_produces_output: cover (out_valid);

endmodule
