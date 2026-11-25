// ---------------------------------------------------------------------------
// hbm4_seq_rom -- the boot script hbm4_init_seq executes.
//
// Until this existed the stack top tied `script_data` to a constant OP_END, so
// boot terminated immediately and reported success WITHOUT TRAINING THE PHY.
// Nothing failed: `ctrl_ready` asserted, traffic started, and the first read
// returned whatever an untrained interface returns.
//
// WHY A ROM AND NOT A STATE MACHINE.  Init sequences change -- between HBM4
// vendors, between silicon revisions, and between bring-up and production.  A
// hard-coded FSM makes each of those an RTL change and a respin of the
// verification that goes with it.  A script keeps the sequencing logic fixed and
// proved (hbm4_init_seq is proved unbounded) while the *contents* become data.
//
// WHY THE SEQUENCER STILL DISTRUSTS IT.  This ROM is the default script, but the
// integrator may substitute a RAM loaded by firmware (docs/05 6.3), so the
// sequencer treats script contents as UNTRUSTED: a branch out of range, a run
// off the end, and a script that never terminates are all caught and reported as
// boot errors rather than allowed to hang or to issue arbitrary DRAM commands.
// That is why the range checks and the watchdog exist even though the script
// below is well-formed by construction.
//
// ENCODING (matches hbm4_init_seq)
//   [31:28] opcode   [23:0] argument
//   OP_NOP=0  OP_END=1  OP_WAIT=2  OP_BRANCH=3  OP_MRS=4  OP_PHY=5  OP_PATTERN=6
//
// For OP_MRS the argument is {MR index[7:0], opcode payload[15:0]}.
// For OP_PHY  the argument selects a PHY action; the PHY consumes it via op_*.
//
// TIMING VALUES marked (P) are placeholders pending the device datasheet and the
// PHY databook -- signoff gate S12 (docs/06 12).  They are expressed in core
// clocks at 1 GHz, so 1 unit = 1 ns.
// ---------------------------------------------------------------------------
module hbm4_seq_rom #(
  parameter int unsigned DEPTH = 512,
  // Right-shift applied to every init delay.  Zero for silicon.
  //
  // The real sequence spends ~200 us waiting for power and clocks to settle,
  // which is 200 000 core clocks -- a simulation that runs the true delays
  // spends all of its time in OP_WAIT and never reaches the training steps,
  // so in practice boot would go untested and stay untested.  That is not a
  // hypothetical: OPEN-10 (training commands never reaching the DRAM) survived
  // precisely because nothing ever simulated a boot.
  //
  // A shift rather than a separate "fast" script, so simulation exercises the
  // SAME instruction sequence in the same order -- only the waiting is shorter.
  parameter int unsigned DELAY_SHIFT = 0,
  localparam int unsigned AW   = $clog2(DEPTH)
) (
  input  logic [AW-1:0]  addr,
  output logic [31:0]    data
);

  localparam logic [3:0] OP_END     = 4'd1;
  localparam logic [3:0] OP_WAIT    = 4'd2;
  localparam logic [3:0] OP_MRS     = 4'd4;
  localparam logic [3:0] OP_PHY     = 4'd5;
  localparam logic [3:0] OP_PATTERN = 4'd6;
  localparam logic [3:0] OP_PREA    = 4'd7;

  // PHY actions (argument of OP_PHY)
  localparam logic [23:0] PHY_CK_START  = 24'h00_0001;
  localparam logic [23:0] PHY_RESET     = 24'h00_0002;
  localparam logic [23:0] PHY_ZQCAL     = 24'h00_0003;
  localparam logic [23:0] PHY_WRLVL     = 24'h00_0004;
  localparam logic [23:0] PHY_RDLVL     = 24'h00_0005;
  localparam logic [23:0] PHY_WR_TRAIN  = 24'h00_0006;
  localparam logic [23:0] PHY_LOCK      = 24'h00_0007;   // freeze trained values

  // Init delays, core clocks @1 GHz (P)
  localparam logic [23:0] T_INIT1 = 24'd200_000;   // 200 us  power/clock stable
  localparam logic [23:0] T_INIT2 = 24'd10_000;    //  10 us  after CK start
  localparam logic [23:0] T_INIT3 = 24'd2_000;     //   2 us  after reset release
  localparam logic [23:0] T_MRD   = 24'd16;        //  MRS to MRS
  localparam logic [23:0] T_ZQINIT= 24'd1_000;     //   1 us  ZQ calibration
  localparam logic [23:0] T_TRAIN = 24'd5_000;     //   5 us  per training step

  function automatic logic [31:0] I(input logic [3:0] op, input logic [23:0] a);
    return {op, 4'd0, a};
  endfunction

  // Scaled delay.  Never returns zero for a non-zero delay: a wait that
  // collapses to nothing would let simulation pass an ordering that silicon
  // cannot achieve.
  function automatic logic [23:0] D(input logic [23:0] v);
    logic [23:0] r;
    r = v >> DELAY_SHIFT;
    return (r == 24'd0) ? 24'd1 : r;
  endfunction

  // MRS payload helper: {MR index, value}
  function automatic logic [23:0] MR(input logic [7:0] idx, input logic [15:0] val);
    return {idx, val};
  endfunction

  always_comb begin
    // DEFAULT IS OP_END, not zero.  A fetch outside the written region returns a
    // clean terminate rather than OP_NOP (0), which would walk the PC forward
    // through unwritten space until the end-of-script guard caught it and
    // reported a boot ERROR -- a confusing failure for what is really just a
    // short script.
    data = I(OP_END, 24'd0);

    unique case (addr)
      // -- power-up ---------------------------------------------------------
      9'd0 : data = I(OP_WAIT,    D(T_INIT1));
      9'd1 : data = I(OP_PHY,     PHY_CK_START);
      9'd2 : data = I(OP_WAIT,    D(T_INIT2));
      9'd3 : data = I(OP_PHY,     PHY_RESET);
      9'd4 : data = I(OP_WAIT,    D(T_INIT3));

      // PRECHARGE ALL, before anything else touches the array.
      //
      // After a reset the controller believes every bank is closed; the device
      // does not, because a reset does not close its rows.  Until every bank is
      // explicitly closed the two models disagree, and the first refresh goes to
      // a bank the DRAM still has open -- a protocol violation on a perfectly
      // healthy device.
      //
      // Found by simulating reset asserted MID-OPERATION (assumption A1's other
      // half).  It is invisible at cold power-on, where the device really does
      // start with everything closed, which is why it survived every earlier
      // boot test.
      9'd5 : data = I(OP_PREA,    24'd0);

      // -- mode registers ---------------------------------------------------
      // Order matters: MR0 (burst length / read latency) must be programmed
      // before any training step that issues a read, because the PHY's expected
      // latency is derived from it.
      9'd6 : data = I(OP_MRS,     MR(8'd0, 16'h0008));  // BL8, RL (P)
      9'd7 : data = I(OP_WAIT,    D(T_MRD));
      9'd8 : data = I(OP_MRS,     MR(8'd1, 16'h0000));  // drive strength (P)
      9'd9 : data = I(OP_WAIT,    D(T_MRD));
      9'd10: data = I(OP_MRS,     MR(8'd2, 16'h0000));  // WL, write recovery (P)
      9'd11: data = I(OP_WAIT,    D(T_MRD));
      9'd12: data = I(OP_MRS,     MR(8'd3, 16'h0000));  // DBI, parity (P)
      9'd13: data = I(OP_WAIT,    D(T_MRD));
      9'd14: data = I(OP_MRS,     MR(8'd4, 16'h0000));  // refresh mode / RFM (P)
      9'd15: data = I(OP_WAIT,    D(T_MRD));

      // -- ZQ calibration ---------------------------------------------------
      9'd16: data = I(OP_PHY,     PHY_ZQCAL);
      9'd17: data = I(OP_WAIT,    D(T_ZQINIT));

      // -- training ---------------------------------------------------------
      // Write levelling first: read training needs writes that land correctly,
      // so doing these in the other order trains reads against garbage.
      9'd18: data = I(OP_PHY,     PHY_WRLVL);
      9'd19: data = I(OP_WAIT,    D(T_TRAIN));
      9'd20: data = I(OP_PATTERN, 24'h00_00AA);      // known pattern for rd eye
      9'd21: data = I(OP_PHY,     PHY_RDLVL);
      9'd22: data = I(OP_WAIT,    D(T_TRAIN));
      9'd23: data = I(OP_PHY,     PHY_WR_TRAIN);
      9'd24: data = I(OP_WAIT,    D(T_TRAIN));

      // Freeze the trained values BEFORE releasing traffic.  Leaving training
      // adaptive while the scheduler runs means the delays move underneath live
      // transactions.
      9'd25: data = I(OP_PHY,     PHY_LOCK);
      9'd26: data = I(OP_END,     24'd0);
      default: ;   // covered by the default assignment above
    endcase
  end

endmodule
