// ---------------------------------------------------------------------------
// fv_addr_slice_miter -- P-MAP-2 and P-MAP-3.  The most important proofs here.
//
// The fabric decides which of the 256 NHI ports a request goes to, using
// hbm4_addr_slice.  The controller then decides where in the DRAM it lives,
// using hbm4_addr_decode.  If those two ever disagree about the hash, a
// request is routed to pseudo-channel A but decoded as belonging at address B.
//
// Data is then written to the wrong place and read from the wrong place, with
// NO ECC error, NO interrupt, and no indication anywhere in the system.  It is
// the highest-consequence, lowest-visibility failure mode in the design, and
// functional testing cannot find it because the corruption is CONSISTENT --
// every write and its matching read are wrong in the same way.
//
// The structural defence is that both paths instantiate the same hbm4_hash.
// This miter proves the defence actually holds, for every address and every
// legal configuration -- including that the two agree on WHICH BITS feed the
// hash, which sharing a module alone does not guarantee.
// ---------------------------------------------------------------------------
module fv_addr_slice_miter
  import hbm4_pkg::*;
(
  input logic                   clk,
  input logic                   rst_n,
  input logic [SYS_ADDR_W-1:0]  sys_addr,
  input slice_cfg_t             scfg,
  input local_cfg_t             lcfg
);

  // ---- reset modelling -----------------------------------------------------
  // ASSUMPTION A1 (see ASSUMPTIONS.md): reset is asserted for at least one
  // cycle at power-on and is NOT re-asserted while transactions are in flight.
  // Without this the solver deasserts rst_n mid-pipeline, leaving out_valid
  // high over stale pipeline registers -- a state the real system reaches only
  // via a system-level reset fault, which the controller is not required to
  // ride through.  Mirrored as a checker in the cocotb environment.
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- path A: the fabric's view -------------------------------------------
  logic [STACK_W-1:0]  a_stack;
  logic [PC_W-1:0]     a_pc;
  logic [PC_BLK_W-1:0] a_blk;

  hbm4_addr_slice u_slice (
    .sys_addr (sys_addr), .cfg (scfg),
    .stack_id (a_stack), .pc_id (a_pc), .pc_blk (a_blk)
  );

  // ---- path B: an INDEPENDENT re-derivation of the field extraction --------
  // Written out longhand rather than reusing the slicer's wires.  If the field
  // offsets inside hbm4_addr_slice were wrong, sharing hbm4_hash would not
  // catch it -- only re-deriving the extraction does.
  logic [STACK_W-1:0]  b_stack_base, b_stack;
  logic [PC_W-1:0]     b_pc_base,    b_pc;
  logic [PC_BLK_W-1:0] b_blk;

  assign b_stack_base = sys_addr[OFFSET_W +: STACK_W];
  assign b_pc_base    = sys_addr[OFFSET_W + STACK_W +: PC_W];
  assign b_blk        = sys_addr[OFFSET_W + STACK_W + PC_W +: PC_BLK_W];

  always_comb begin
    for (int unsigned i = 0; i < STACK_W; i++)
      b_stack[i] = b_stack_base[i] ^ (^(sys_addr & scfg.h_st[i]));
    for (int unsigned i = 0; i < PC_W; i++)
      b_pc[i]    = b_pc_base[i]    ^ (^(sys_addr & scfg.h_pc[i]));
  end

  // ---- P-MAP-3: the two paths agree, always --------------------------------
  always_comb begin
    p_stack_agrees : assert (a_stack == b_stack);
    p_pc_agrees    : assert (a_pc    == b_pc);
    p_blk_agrees   : assert (a_blk   == b_blk);
  end

  // ---- controller-side decode ----------------------------------------------
  logic     dec_valid, dec_oor;
  pc_addr_t dec_addr;
  bank_t    dec_bank;

  hbm4_addr_decode u_dec (
    .clk (clk), .rst_n (rst_n),
    .in_valid (1'b1), .in_pc_blk (a_blk), .cfg (lcfg),
    .out_valid (dec_valid), .out_addr (dec_addr), .out_bank (dec_bank),
    .out_range_err (dec_oor)
  );

  // Shadow the `rem` field through the decode's 2-cycle pipe, independently of
  // the DUT's own registers.
  localparam int unsigned CW = REM_W + 2;      // room for row * N_COL_DATA

  logic [REM_W-1:0] rem_in, rem_d1, rem_d2;
  assign rem_in = a_blk[BG_W + BA_W +: REM_W];

  always @(posedge clk) begin
    rem_d1 <= rem_in;
    rem_d2 <= rem_d1;
  end

  // ---- P-MAP-2: range and reconstruction -----------------------------------
  //
  // NOTE ON A PROPERTY BUG THAT THIS REPLACES:
  //   The first version asserted `dec_oor || (row < ROW_W'(N_ROW))`.  That is
  //   meaningless: N_ROW is 2^ROW_W, so ROW_W'(N_ROW) truncates to 0 and the
  //   test read `row < 0`.  It failed loudly, which is the only reason it was
  //   caught.  A property whose constant silently truncates is worse than no
  //   property at all -- assert on the QUOTIENT, which is the thing that can
  //   actually overflow, not on a field that structurally cannot.
  always @(posedge clk) begin
    if (f_past_valid && rst_n && dec_valid) begin
      // The out-of-range flag is exactly right: no missed faults (which would
      // alias an illegal address onto real data) and no false faults (which
      // would make usable capacity disappear).
      p_oor_exact : assert (dec_oor == (rem_d2 > REM_W'(REM_MAX)));

      // In range: the decode is an exact inverse of the address map.
      if (!dec_oor) begin
        p_recon   : assert ((CW'(dec_addr.row) * CW'(N_COL_DATA))
                            + CW'(dec_addr.col) == CW'(rem_d2));
        p_col_data: assert (dec_addr.col < COL_W'(N_COL_DATA));
      end

      // Bank index layout, written out LITERALLY.
      //
      // The first version of this was `dec_bank == bank_of(bg, ba)` -- a
      // property that calls the very function it is testing.  Mutating
      // bank_of() mutated both sides, so the assertion was vacuous and the
      // mutation survived (found by mutate.sh, not by review).  Never let a
      // property defer to the logic under test.
      p_bank_layout : assert (dec_bank == {dec_addr.ba, dec_addr.bg});

      // The bank group MUST live in the low bits, because hbm4_timing_engine
      // derives it with bg_of() to track tCCD_L / tRRD_L.  If this round trip
      // breaks, timing is enforced against the wrong bank group and the
      // controller silently violates the DRAM -- with no functional symptom.
      p_bg_roundtrip: assert (bg_of(dec_bank) == dec_addr.bg);
    end
  end

  // Both outcomes must be reachable, or the range check is dead logic and the
  // property above is vacuous.
  always @(posedge clk) if (f_past_valid && rst_n && dec_valid) begin
    c_in_range  : cover (!dec_oor);
    c_out_range : cover ( dec_oor);
  end

endmodule
