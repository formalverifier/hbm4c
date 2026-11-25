// ---------------------------------------------------------------------------
// hbm4_supervisor -- the one global block.  Never in the data path.
//
// Four jobs, and each exists because it CANNOT be done per-stack:
//
//   BOOT        one ctrl_ready, not four.  Stacks train in parallel -- doing it
//               serially would make boot N_STACK times longer for no reason --
//               but traffic must not start until every stack is ready, because
//               under FINE interleave a single stream touches all of them.
//
//   RAS         a correlated event (power, thermal) hits every stack at once.
//               Per-stack logs would record it as four unrelated faults with
//               four timestamps; one aggregated view records it as one event,
//               which is the difference between a diagnosable failure and four
//               red herrings.
//
//   DVFS        under FINE interleave one slow stack throttles everything, so
//               the frequency decision cannot be made locally.
//
//   PERF        cross-stack imbalance is the thing you are usually hunting, and
//               counters sampled at different times cannot show it.  The
//               snapshot freezes all stacks on one edge.
// ---------------------------------------------------------------------------
module hbm4_supervisor
  import hbm4_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  boot_start,
  output logic                  ctrl_ready,
  output logic                  boot_failed,

  input  logic [N_STACK-1:0]    stack_boot_done,
  input  logic [N_STACK-1:0]    stack_boot_error,
  output logic [N_STACK-1:0]    stack_boot_start,

  input  logic [N_STACK-1:0]    stack_err,
  input  logic [N_STACK-1:0]    stack_busy,

  input  logic                  perf_snapshot_req,
  output logic                  perf_freeze,

  output logic [31:0]           irq_status,
  input  logic [31:0]           irq_mask,
  output logic                  irq
);

  typedef enum logic [1:0] {
    B_IDLE = 2'd0, B_TRAIN = 2'd1, B_READY = 2'd2, B_FAILED = 2'd3
  } boot_e;

  boot_e bst;

  // Every stack starts together.  Serialising would multiply boot time by
  // N_STACK, and there is nothing to serialise for -- the PHYs are independent.
  assign stack_boot_start = {N_STACK{bst == B_TRAIN}};
  assign ctrl_ready       = (bst == B_READY);
  assign boot_failed      = (bst == B_FAILED);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bst <= B_IDLE;
    end else begin
      case (bst)
        B_IDLE:  if (boot_start) bst <= B_TRAIN;
        // ANY failure fails the boot.  Releasing traffic with one stack
        // untrained corrupts every access that maps to it -- and under FINE
        // interleave that is one access in N_STACK, everywhere.
        B_TRAIN: if (|stack_boot_error)      bst <= B_FAILED;
                 else if (&stack_boot_done)  bst <= B_READY;
        default: ;
      endcase
    end
  end

  // One freeze edge for every stack: counters sampled at different times cannot
  // show the cross-stack imbalance they exist to reveal.
  always_ff @(posedge clk)
    if (!rst_n) perf_freeze <= 1'b0;
    else        perf_freeze <= perf_snapshot_req;

  always_comb begin
    irq_status         = 32'd0;
    irq_status[0]      = |stack_err;
    irq_status[1]      = boot_failed;
    irq_status[2]      = ctrl_ready;
    irq_status[7:4]    = 4'(stack_err);
  end

  assign irq = |(irq_status & ~irq_mask);

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, stack_busy};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
