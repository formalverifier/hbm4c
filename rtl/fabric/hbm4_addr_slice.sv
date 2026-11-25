// ---------------------------------------------------------------------------
// hbm4_addr_slice -- fabric-side address slicer.  DELIVERED TO THE CUSTOMER.
//
// Instantiate ONE PER REQUESTER PORT in your SoC fabric.  It maps a system
// byte address to {stack, pseudo-channel, PC-local block address}, which is
// how the fabric knows which of the 256 NHI ports to route to.
//
// Purely combinational: bit-select plus XOR reduction, ~200 gates, zero
// latency.  There is deliberately no arithmetic here -- the divide that inline
// ECC needs lives in the controller (hbm4_divc), because this module is
// replicated at every requester port and that one is not.
//
// CONTRACT: `cfg` must be identical to the hash image programmed into the
// controller's CSRs.  Drive both from one struct in your driver and set
// AMAP_LOCK before enabling traffic.  See docs/05-integration-guide.md 6.
//
// Field order (docs/02-architecture.md 7.2), LSB first:
//   [4:0] offset | [6:5] STACK | [12:7] PC | [37:13] pc_blk
// The ordering is the whole design: a +32 B stride changes the stack, +128 B
// the pseudo-channel, and +8 KB the bank group -- which is what makes
// sequential streams alternate bank groups for free (constraint C2).
// ---------------------------------------------------------------------------
module hbm4_addr_slice
  import hbm4_pkg::*;
(
  input  logic [SYS_ADDR_W-1:0] sys_addr,
  input  slice_cfg_t            cfg,
  output logic [STACK_W-1:0]    stack_id,
  output logic [PC_W-1:0]       pc_id,
  output logic [PC_BLK_W-1:0]   pc_blk
);

  logic [STACK_W-1:0] stack_base;
  logic [PC_W-1:0]    pc_base;

  assign stack_base = sys_addr[OFFSET_W +: STACK_W];
  assign pc_base    = sys_addr[OFFSET_W + STACK_W +: PC_W];
  assign pc_blk     = sys_addr[OFFSET_W + STACK_W + PC_W +: PC_BLK_W];

  hbm4_hash #(.IN_W(SYS_ADDR_W), .OUT_W(STACK_W)) u_hash_stack (
    .addr   (sys_addr),
    .base   (stack_base),
    .mask   (cfg.h_st),
    .hashed (stack_id)
  );

  hbm4_hash #(.IN_W(SYS_ADDR_W), .OUT_W(PC_W)) u_hash_pc (
    .addr   (sys_addr),
    .base   (pc_base),
    .mask   (cfg.h_pc),
    .hashed (pc_id)
  );

endmodule
