// ---------------------------------------------------------------------------
// fv_init_seq -- P-SEQ-*.
//
// Two properties, protecting against two different kinds of disaster.
//
// P-SEQ-1 (safety): the sequencer never drives the DRAM while the scheduler is
// live.  Both would be issuing onto the same row and column buses, and DRAM has
// no arbitration -- two drivers means a corrupted command, which at best wedges
// the channel and at worst activates the wrong row and writes there.
//
// P-SEQ-2 (liveness): a malformed script cannot hang boot.  The script is
// FIRMWARE-SUPPLIED and therefore untrusted -- a branch to itself, an
// out-of-range target, a wait with a huge argument.  Any of them must terminate
// with an error, not spin forever with the machine unusable and nothing logged.
//
// The second is the one that is easy to skip.  Boot code is written once, tends
// to work, and the failure only shows up on a customer's bring-up bench with a
// vendor script nobody here has seen.
// ---------------------------------------------------------------------------
module fv_init_seq
  import hbm4_pkg::*;
#(
  // NON-power-of-two on purpose.  At SCRIPT_DEPTH = 8 with PCW = 3, PCW'(arg)
  // truncates to 3 bits and every branch target is in range by construction --
  // the range guard becomes dead code and deleting it SURVIVES mutation
  // testing.  Same trap as proving tFAW with only 4 banks: the reduced
  // configuration has to be shaped so the property can actually be violated.
  parameter int unsigned SCRIPT_DEPTH = 6,
  // Small enough to EXPIRE within the proof depth.  At WDOG_LIMIT = 12 with a
  // depth-12 prove, the watchdog can never fire, so p_wdog_reports never has
  // its guard satisfied and passes vacuously -- deleting the error report
  // survived mutation testing.  Third instance of the same trap (tFAW at 4
  // banks, SCRIPT_DEPTH at a power of two); see formal/SCALING.md.
  parameter int unsigned WDOG_LIMIT   = 4,
  localparam int unsigned PCW = $clog2(SCRIPT_DEPTH)
) (
  input logic        clk,
  input logic        rst_n,
  input logic        start,
  input logic        slices_quiesced,
  input logic [31:0] script_data,
  input logic        op_ack
);

  logic           busy, done, error, op_valid;
  logic [PCW-1:0] script_addr, dbg_pc;
  logic [3:0]     op_code;
  logic [23:0]    op_arg;
  logic [31:0]    dbg_wdog;
  logic [23:0]    dbg_wait;
  logic           dbg_at_end;

  hbm4_init_seq #(.SCRIPT_DEPTH(SCRIPT_DEPTH), .WDOG_LIMIT(WDOG_LIMIT)) dut (
    .clk (clk), .rst_n (rst_n),
    .start (start), .slices_quiesced (slices_quiesced),
    .busy (busy), .done (done), .error (error),
    .script_addr (script_addr), .script_data (script_data),
    .op_valid (op_valid), .op_code (op_code), .op_arg (op_arg), .op_ack (op_ack),
    .dbg_pc (dbg_pc), .dbg_wdog (dbg_wdog), .dbg_wait (dbg_wait), .dbg_at_end (dbg_at_end)
  );

  // "A script that actually executed a WAIT still reached done" -- the end-to-end
  // check that the WAIT path terminates rather than looping on itself.
  reg saw_wait = 1'b0;
  always @(posedge clk)
    if (!rst_n)                  saw_wait <= 1'b0;
    else if (dbg_wait != 24'd0)  saw_wait <= 1'b1;

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-SEQ-1: never drives the DRAM while the scheduler is live --------
  // Structural in the RTL (the gate is on the output, not in the FSM), and
  // asserted here so no future edit can reintroduce a bus conflict.
  always @(*)
    if (f_past_valid && rst_n && !slices_quiesced)
      p_quiet_when_live: assert (!op_valid);

  always @(*)
    if (f_past_valid && rst_n && (!busy || done || error))
      p_quiet_when_idle: assert (!op_valid);

  // A wait in progress must not let a DRAM op onto the bus.  The waits between
  // MRS writes are mandatory JEDEC init timing (tMRD, tINIT3), so issuing
  // through one is an init-protocol violation, not a scheduling nicety.
  always @(*)
    if (f_past_valid && rst_n && (dbg_wait != 24'd0))
      p_wait_blocks_op: assert (!op_valid);

  // ---- P-SEQ-2: an untrusted script cannot hang boot ---------------------
  // The watchdog is bounded, so busy cannot persist indefinitely regardless of
  // what the script contains.
  always @(*)
    if (f_past_valid && rst_n)
      p_wdog_bounded: assert (dbg_wdog <= 32'(WDOG_LIMIT));

  // Once the watchdog expires, the sequencer stops and REPORTS.  Stopping
  // silently would be the same hang from the driver's point of view.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(busy) && ($past(dbg_wdog) >= 32'(WDOG_LIMIT))) begin
      p_wdog_stops  : assert (!busy);
      p_wdog_reports: assert (error);
    end

  // ---- P-SEQ-3: the program counter never leaves the script --------------
  // A branch outside the script would fetch whatever the RAM returns for an
  // out-of-range address and execute it as an instruction.
  always @(*)
    if (f_past_valid && rst_n)
      p_pc_in_range: assert (dbg_pc < PCW'(SCRIPT_DEPTH));

  // ---- P-SEQ-4: done and error are mutually exclusive --------------------
  always @(*)
    if (f_past_valid && rst_n)
      p_done_xor_error: assert (!(done && error));

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_busy     : cover (busy);
    c_op       : cover (op_valid);
    c_done     : cover (done);
    // The case P-SEQ-2 exists for: a script that never terminates on its own.
    c_wdog     : cover (error);
    // Guard-reachability cover: without this, p_wdog_reports can pass while its
    // antecedent is never satisfied, and nothing says so.
    c_wdog_fires: cover (busy && (dbg_wdog >= 32'(WDOG_LIMIT)));
    c_held_off : cover (busy && !slices_quiesced);

    // Guard-reachability for the WAIT path.  c_done alone is satisfied by an
    // OP_END at pc 0, so it never exercised a wait -- and an OP_WAIT that
    // looped on itself forever passed every property in this file.
    // Reachability cover on the END-OF-SCRIPT GUARD itself.  This is the
    // general detector for a guard that a tool has constant-folded away: a
    // signal folded to 1'b0 makes its own cover unreachable, and an unreachable
    // cover fails the build.  Nothing else in this file would have noticed.
    c_at_end    : cover (busy && dbg_at_end);

    c_wait      : cover (busy && (dbg_wait != 24'd0));
    // Sticky, not $past.  Written as `done && $past(dbg_wait != 0)` this is
    // UNREACHABLE by construction: when wait_cnt reaches zero the OP_END
    // executes that same cycle and `done` asserts the next, so the previous
    // cycle's wait_cnt is already zero.  The cover would have failed the build
    // forever while looking like a real coverage hole.
    c_wait_done : cover (done && saw_wait);
    c_wait_prog : cover (busy && $past(dbg_wait == 24'd1) && (dbg_wait == 24'd0));


  end

endmodule
