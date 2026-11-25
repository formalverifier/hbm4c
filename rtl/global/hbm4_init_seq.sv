// ---------------------------------------------------------------------------
// hbm4_init_seq -- microcoded PHY training sequencer.
//
// WHY MICROCODE.  HBM training algorithms differ by vendor, by stack revision,
// and by bring-up iteration.  A hardwired FSM *will* be wrong -- not might be,
// will be -- and being wrong costs a metal spin.  ~2500 gates plus a script RAM
// buys the ability to fix a training bug with a firmware update, which on an
// 8 TB/s interface is the highest-leverage 2500 gates in the design
// (docs/02-architecture.md 13).
//
// THE SAFETY PROPERTY (P-SEQ-1) is that the sequencer never drives the DRAM
// while the scheduler is live.  Both would be issuing commands onto the same
// row and column buses, and DRAM has no arbitration: two drivers means a
// corrupted command, which at best wedges the channel and at worst activates
// the wrong row and writes there.
//
// So the sequencer owns the buses only while `slices_quiesced` is asserted, and
// it must never assert a DRAM operation otherwise.
//
// THE LIVENESS PROPERTY (P-SEQ-2) is that a malformed script cannot hang boot.
// The script is firmware-supplied and therefore untrusted: a bad branch target
// or a loop with no exit must terminate with an error, not spin forever with
// the machine unusable and nothing logged.
// ---------------------------------------------------------------------------
module hbm4_init_seq
  import hbm4_pkg::*;
#(
  parameter int unsigned SCRIPT_DEPTH = 512,
  parameter int unsigned WDOG_LIMIT   = 65535,
  localparam int unsigned PCW = $clog2(SCRIPT_DEPTH)
) (
  input  logic             clk,
  input  logic             rst_n,

  input  logic             start,
  input  logic             slices_quiesced,   // scheduler is off the bus
  output logic             busy,
  output logic             done,
  output logic             error,             // malformed script / watchdog

  // ---- script memory -------------------------------------------------------
  // Instruction layout: [31:28] opcode, [27:24] reserved, [23:0] argument.
  // The reserved nibble is deliberate headroom -- new opcodes will need
  // qualifiers, and widening the instruction after firmware exists is worse
  // than carrying four spare bits now.
  output logic [PCW-1:0]   script_addr,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]      script_data,
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- DRAM / PHY operation ------------------------------------------------
  output logic             op_valid,
  output logic [3:0]       op_code,
  output logic [23:0]      op_arg,
  input  logic             op_ack,

  output logic [PCW-1:0]   dbg_pc,
  // Watchdog value, for the formal wrapper and for silicon debug: it is the
  // direct measure of how long a vendor's training script actually takes.
  output logic [31:0]      dbg_wdog,
  output logic [23:0]      dbg_wait,
  output logic             dbg_at_end
);

  // Opcodes.  WAIT/BRANCH/LOOP are sequencer-internal; the rest reach the DRAM.
  localparam logic [3:0] OP_NOP    = 4'd0;
  localparam logic [3:0] OP_END    = 4'd1;
  localparam logic [3:0] OP_WAIT   = 4'd2;
  localparam logic [3:0] OP_BRANCH = 4'd3;
  localparam logic [3:0] OP_MRS    = 4'd4;   // reaches the DRAM
  localparam logic [3:0] OP_PHY    = 4'd5;   // reaches the PHY
  localparam logic [3:0] OP_PATTERN= 4'd6;   // reaches the DRAM
  // Precharge-all.  Reaches the DRAM, and must come FIRST after reset release:
  // a reset wipes the controller's bank state while the device keeps whatever
  // rows were open, so until every bank is explicitly closed the two disagree
  // and the controller will issue REF or ACT to a bank the DRAM thinks is open.
  localparam logic [3:0] OP_PREA   = 4'd7;

  logic [PCW-1:0]  pc;
  logic [23:0]     wait_cnt;
  logic [31:0]     wdog;
  logic [3:0]      opc;
  logic [23:0]     arg;

  assign script_addr = pc;
  assign dbg_pc      = pc;
  assign dbg_wdog    = wdog;
  assign dbg_wait    = wait_cnt;
  assign dbg_at_end  = pc_at_end;
  assign opc         = script_data[31:28];
  assign arg         = script_data[23:0];

  // Running off the end of the script is a malformed script, not a wrap.
  // Without this, the PC advances past the last instruction, fetches whatever
  // the RAM returns for an out-of-range address, and EXECUTES it -- which for
  // a firmware-supplied script is an arbitrary-command primitive.
  //
  // Found by formal only after the proof configuration was changed to a
  // NON-power-of-two SCRIPT_DEPTH: at a power of two the PC truncation hides
  // the overrun completely.
  // Compared at an explicit fixed width rather than with a parameterised cast.
  // Both forms are correct here; the explicit one is preferred because a cast
  // whose WIDTH comes from a parameter and whose VALUE comes from the same
  // parameter is the shape that produced a real truncation bug elsewhere in this
  // design (ROW_W'(N_ROW) in hbm4_bank_state, which evaluated to zero and turned
  // a range check into `row < 0`).
  logic pc_at_end;
  assign pc_at_end = (32'(pc) == 32'(SCRIPT_DEPTH) - 32'd1);

  logic is_dram_op;
  assign is_dram_op = (opc == OP_MRS) || (opc == OP_PHY)
                   || (opc == OP_PATTERN) || (opc == OP_PREA);

  // P-SEQ-1 is structural: op_valid cannot assert unless the slices are
  // quiesced.  Putting the gate here, on the output, rather than relying on the
  // state machine never reaching a bad state, means no future edit to the FSM
  // can produce a bus conflict.
  // The `wait_cnt == 0` term is not redundant.  OP_WAIT advances the PC when it
  // loads the counter (see below), so during a wait the PC already points at the
  // NEXT instruction -- and without this gate that instruction's op_valid would
  // assert immediately, issuing the DRAM command before the wait elapsed.  The
  // waits between MRS writes are mandatory JEDEC init timing (tMRD, tINIT3),
  // so skipping them is a real init-protocol violation, not a scheduling nicety.
  assign op_valid = busy && !done && !error && is_dram_op && slices_quiesced
                 && (wait_cnt == 24'd0);
  assign op_code  = opc;
  assign op_arg   = arg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc       <= '0;
      wait_cnt <= 24'd0;
      wdog     <= 32'd0;
      busy     <= 1'b0;
      done     <= 1'b0;
      error    <= 1'b0;
    end else if (start && !busy && !done) begin
      pc       <= '0;
      wait_cnt <= 24'd0;
      wdog     <= 32'd0;
      busy     <= 1'b1;
      error    <= 1'b0;
      done     <= 1'b0;
    end else if (busy) begin
      // Watchdog runs on EVERY cycle the sequencer is busy, including waits and
      // loops.  A firmware-supplied script is untrusted: a branch to itself, or
      // a wait with a huge argument, must terminate with an error rather than
      // leave the machine unusable with nothing logged.
      if (wdog >= WDOG_LIMIT) begin
        busy  <= 1'b0;
        error <= 1'b1;
        done  <= 1'b0;
      end else begin
        wdog <= wdog + 32'd1;

        if (wait_cnt != 24'd0) begin
          wait_cnt <= wait_cnt - 24'd1;
        end else begin
          case (opc)
            // done and error are made mutually exclusive by CONSTRUCTION --
            // each terminal path clears the other.  Leaving that to an
            // invariant would mean the two could coexist in principle, and a
            // driver reading `done` while `error` is set would report a
            // successful boot on a stack that never trained.
            OP_END: begin
              busy  <= 1'b0;
              done  <= 1'b1;
              error <= 1'b0;
            end
            // The PC MUST advance here.  The first version only loaded the
            // counter: when it reached zero the PC still pointed at the same
            // OP_WAIT, which reloaded it -- an unconditional infinite loop, so
            // every script containing a WAIT ran until the watchdog killed it
            // and reported a boot failure.  Formal missed it because
            // `script_data` is a free input and `c_done` is satisfied by an
            // OP_END at pc 0, so no proof ever executed a WAIT (the same
            // unreachable-guard trap as formal/SCALING.md 3).
            OP_WAIT: begin
              wait_cnt <= arg;
              if (pc_at_end) begin busy <= 1'b0; error <= 1'b1; done <= 1'b0; end
              else           pc <= pc + 1'b1;
            end
            OP_BRANCH: begin
              // A target outside the script is a malformed script, not a jump.
              if (arg < 24'(SCRIPT_DEPTH)) pc <= PCW'(arg);
              else begin
                busy  <= 1'b0;
                error <= 1'b1;
                done  <= 1'b0;
              end
            end
            OP_NOP: begin
              if (pc_at_end) begin busy <= 1'b0; error <= 1'b1; done <= 1'b0; end
              else           pc <= pc + 1'b1;
            end
            default: begin
              // DRAM/PHY op: advance only once it has been accepted, and only
              // while the buses are ours.
              if (op_valid && op_ack) begin
                if (pc_at_end) begin busy <= 1'b0; error <= 1'b1; done <= 1'b0; end
                else           pc <= pc + 1'b1;
              end
            end
          endcase
        end
      end
    end
  end

endmodule
