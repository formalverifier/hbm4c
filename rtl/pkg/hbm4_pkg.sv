// ---------------------------------------------------------------------------
// hbm4_pkg -- device geometry, derived constants, command and state encodings.
//
// Everything the rest of the design needs to know about the DRAM lives here.
// Values marked (P) are placeholders scaled from HBM3; see docs/08-compliance-matrix.md.
// ---------------------------------------------------------------------------
/* verilator lint_off UNUSEDPARAM */
package hbm4_pkg;

  // -------------------------------------------------------------------------
  // Device geometry
  // -------------------------------------------------------------------------
// FV_SMALL selects a reduced geometry for formal.  No solver can hold 32 banks
// x 32768 rows x a 64-entry pool, so proofs run at this scale and the gap to
// production is closed by (a) BMC at full scale and (b) the structural review
// in formal/SCALING.md.  The reduced set deliberately KEEPS every structural
// relationship that the properties depend on: >1 bank group, >1 bank per
// group, a non-power-of-two data column count, and an out-of-range region.
`ifdef FV_SMALL
  parameter int unsigned N_STACK        = 2;
  parameter int unsigned N_CH_PER_STACK = 2;
  parameter int unsigned N_PC_PER_CH    = 2;
  parameter int unsigned PC_DQ_W        = 32;
  parameter int unsigned N_BG           = 2;
  // 8 banks, not 4.  tFAW is violated only by 5 activates inside one window,
  // which needs 5 DISTINCT banks (re-activating one costs tRC, which is longer
  // than tFAW).  At 4 banks tFAW is unreachable, every tFAW property passes
  // vacuously, and deleting the tFAW logic entirely survives mutation testing.
  // The reduced geometry has to be big enough to REACH each property; see
  // SCALING.md.
  parameter int unsigned N_BA_PER_BG    = 4;     // -> 8 banks
  parameter int unsigned ROW_SIZE_B     = 512;   // -> 16 columns, 1 reserved
  parameter int unsigned N_ROW          = 8;
`else
  parameter int unsigned N_STACK        = 4;
  parameter int unsigned N_CH_PER_STACK = 32;
  parameter int unsigned N_PC_PER_CH    = 2;
  parameter int unsigned PC_DQ_W        = 32;    // data pins per pseudo-channel
  parameter int unsigned N_BG           = 4;     // (P) bank groups
  parameter int unsigned N_BA_PER_BG    = 8;     // (P) banks per bank group
  parameter int unsigned ROW_SIZE_B     = 1024;  // (P) bytes per row
  parameter int unsigned N_ROW          = 32768; // (P) rows per bank
`endif

  parameter int unsigned N_PC_PER_STACK = N_CH_PER_STACK * N_PC_PER_CH;   // 64
  parameter int unsigned N_PC_TOTAL     = N_STACK * N_PC_PER_STACK;       // 256
  parameter int unsigned N_BANK         = N_BG * N_BA_PER_BG;             // 32

  // -------------------------------------------------------------------------
  // Burst length -- THE decision, see docs/02-architecture.md 1.3
  //
  // BL8 on a 32-bit pseudo-channel gives 32 B, and the burst then occupies
  // exactly one core clock, which is exactly tCCD_S.  That identity also holds
  // in HBM3 at 6.4 Gb/s, which is the strongest evidence it is the right read
  // of the standard.
  //
  // BL16 (64 B) is supported by changing BL alone.  The DFI datapath width is
  // invariant at DFI_DATA_W either way -- 32 B over 1 clock or 64 B over 2 --
  // which is what keeps the change cheap.  Everything downstream derives.
  // -------------------------------------------------------------------------
  parameter int unsigned BL         = 8;
  parameter int unsigned DFI_DATA_W = 256;                       // bits/clk/PC

  parameter int unsigned AG_BYTES   = (BL * PC_DQ_W) / 8;        // 32
  parameter int unsigned BURST_CLKS = (AG_BYTES * 8) / DFI_DATA_W;// 1 (BL8), 2 (BL16)
  parameter int unsigned OFFSET_W   = $clog2(AG_BYTES);          // 5

  // -------------------------------------------------------------------------
  // Column budget.  Inline system ECC reserves 1/16 of the columns in every
  // row; the ECC for a block therefore sits in the SAME bank and the SAME open
  // row as its data (docs/02-architecture.md 10.3).
  // -------------------------------------------------------------------------
  parameter int unsigned SYSECC_EN   = 1;
  parameter int unsigned N_COL_RAW   = ROW_SIZE_B / AG_BYTES;             // 32
  parameter int unsigned N_COL_ECC   = (SYSECC_EN != 0) ? (N_COL_RAW / 16) : 0; // 2
  parameter int unsigned N_COL_DATA  = N_COL_RAW - N_COL_ECC;             // 30
  // data blocks covered by one ECC block (one per row-half)
  parameter int unsigned ECC_FANOUT  = N_COL_DATA / (N_COL_ECC == 0 ? 1 : N_COL_ECC);
  // check-field width per data block inside an ECC block
  parameter int unsigned ECC_FIELD_W = (AG_BYTES * 8) / ECC_FANOUT;       // 16

  // -------------------------------------------------------------------------
  // Address field widths
  // -------------------------------------------------------------------------
  parameter int unsigned BG_W      = $clog2(N_BG);        // 2
  parameter int unsigned BA_W      = $clog2(N_BA_PER_BG); // 3
  parameter int unsigned BANK_W    = $clog2(N_BANK);      // 5
  parameter int unsigned COL_W     = $clog2(N_COL_RAW);   // 5
  parameter int unsigned ROW_W     = $clog2(N_ROW);       // 15
  parameter int unsigned SID_W     = 0;

  parameter int unsigned STACK_W   = $clog2(N_STACK);           // 2
  parameter int unsigned PC_W      = $clog2(N_PC_PER_STACK);    // 6

  // PC-local block address: {rem, BA, BG}.  rem is split into row/col by the
  // constant divider (hbm4_divc) because N_COL_DATA is not a power of two.
  parameter int unsigned PC_BLK_W  = ROW_W + SID_W + BG_W + BA_W + COL_W;  // 25
  parameter int unsigned REM_W     = PC_BLK_W - BG_W - BA_W;               // 20
  parameter int unsigned SYS_ADDR_W = PC_BLK_W + PC_W + STACK_W + OFFSET_W;// 38

  // -------------------------------------------------------------------------
  // Queue / buffer sizing
  // -------------------------------------------------------------------------
`ifdef FV_SMALL
  parameter int unsigned TQ_DEPTH    = 4;
`elsif TQ_DEPTH_OVERRIDE
  // Build-time override for the sizing study.  TQ_DEPTH is the dominant knob for
  // BOTH area and timing in this design -- the transaction pool is ~40% of a
  // pseudo-channel's cells and, with real cells and buffering, its critical path
  // is the slowest in the slice.  The default of 64 was inherited, never derived.
  parameter int unsigned TQ_DEPTH    = `TQ_DEPTH_OVERRIDE;
`else
  parameter int unsigned TQ_DEPTH    = 64;
`endif
  parameter int unsigned TQ_IDX_W    = $clog2(TQ_DEPTH);
`ifdef FV_SMALL
  parameter int unsigned WBUF_DEPTH  = 4;
`else
  parameter int unsigned WBUF_DEPTH  = 128;
`endif
  parameter int unsigned WBUF_IDX_W  = $clog2(WBUF_DEPTH);
`ifdef FV_SMALL
  parameter int unsigned HAZ_HASH_W  = 3;
`else
  parameter int unsigned HAZ_HASH_W  = 12;   // tier-1 hazard hash (docs 02 8.5)
`endif

  // Write-buffer hazard tag: everything that identifies a 32 B block within a
  // pseudo-channel.  A read matching a pending write on this tag must not
  // overtake it.
  parameter int unsigned HAZ_TAG_W   = BANK_W + ROW_W + COL_W;
`ifdef FV_SMALL
  // Tags are opaque payload -- the pool and arbiter invariants do not depend on
  // their width, but 8 bits x every entry x every head mirror is a large slice
  // of the solver's state space.  Narrowed for formal only.
  parameter int unsigned TAG_W       = 2;
`else
  parameter int unsigned TAG_W       = 8;
`endif
  parameter int unsigned QOS_W       = 2;

  // -------------------------------------------------------------------------
  // Types
  // -------------------------------------------------------------------------
  typedef logic [BANK_W-1:0] bank_t;
  typedef logic [BG_W-1:0]   bg_t;
  typedef logic [BA_W-1:0]   ba_t;
  typedef logic [ROW_W-1:0]  row_t;
  typedef logic [COL_W-1:0]  col_t;
  typedef logic [REM_W-1:0]  rem_t;
  typedef logic [TAG_W-1:0]  tag_t;
  typedef logic [QOS_W-1:0]  qos_t;
  typedef logic [TQ_IDX_W-1:0] tqidx_t;

  // Row-bus commands.  Separate bus from the column commands (constraint C3),
  // so a ROW_ACT and a COL_RD issue in the same core clock.
  typedef enum logic [2:0] {
    ROW_NOP    = 3'd0,
    ROW_ACT    = 3'd1,
    ROW_PRE    = 3'd2,
    ROW_PREA   = 3'd3,   // precharge all
    ROW_REF_SB = 3'd4,   // per-bank refresh  <- the default
    ROW_REF_AB = 3'd5,   // all-bank refresh
    ROW_RFM    = 3'd6,   // refresh management (row hammer)
    // Mode-register write.  Issued ONLY by the stack's training sequencer during
    // boot, never by a slice -- which is why its payload does not travel on the
    // bank/row fields (they are far too narrow at reduced geometry) but on the
    // dedicated dfi_mrs_* buses at the stack boundary.
    ROW_MRS    = 3'd7
  } row_cmd_e;

  typedef enum logic [2:0] {
    COL_NOP = 3'd0,
    COL_RD  = 3'd1,
    COL_WR  = 3'd2,
    COL_RDA = 3'd3,      // read  + auto-precharge
    COL_WRA = 3'd4,      // write + auto-precharge
    COL_MRS = 3'd5
  } col_cmd_e;

  typedef enum logic [2:0] {
    BK_IDLE       = 3'd0,
    BK_ACTIVATING = 3'd1,
    BK_ACTIVE     = 3'd2,
    BK_PRECHARGING= 3'd3,
    BK_REFRESHING = 3'd4
  } bank_st_e;

  typedef enum logic [0:0] { DIR_READ = 1'b0, DIR_WRITE = 1'b1 } dir_e;

  typedef enum logic [1:0] {
    QOS_BULK = 2'd0, QOS_NORM = 2'd1, QOS_HIGH = 2'd2, QOS_URGENT = 2'd3
  } qos_e;

  typedef enum logic [2:0] {
    AMAP_STREAM = 3'd0, AMAP_LOCAL = 3'd1, AMAP_CLOSE = 3'd2,
    AMAP_NUMA   = 3'd3, AMAP_RAW   = 3'd4
  } amap_mode_e;

  typedef enum logic [1:0] {
    PAGE_OPEN = 2'd0, PAGE_ADAPTIVE = 2'd1, PAGE_CLOSE = 2'd2
  } page_policy_e;

  // Decoded PC-local address.
  typedef struct packed {
    row_t  row;
    col_t  col;
    ba_t   ba;
    bg_t   bg;
  } pc_addr_t;

  // What the two arbiters drive onto the two command buses each core clock.
  // They are separate structs because they are separate physical buses
  // (constraint C3): a ROW_ACT and a COL_RD issue in the SAME cycle.
  typedef struct packed {
    logic     valid;
    row_cmd_e cmd;
    bank_t    bank;
    row_t     row;
  } row_issue_t;

  typedef struct packed {
    logic     valid;
    col_cmd_e cmd;
    bank_t    bank;
    col_t     col;
  } col_issue_t;

  function automatic bank_t bank_of(input bg_t bg, input ba_t ba);
    return bank_t'({ba, bg});   // BG in the low bits: banks 0,1,2,3 are BG0..3
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic bg_t bg_of(input bank_t b);
    return bg_t'(b[BG_W-1:0]);   // only the low bits carry the bank group
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // Largest legal `rem` value.  rem addresses (row, col) pairs, and only
  // N_ROW * N_COL_DATA of the 2^REM_W encodable values exist in the device.
  // Because rem sits at the TOP of the system address, the illegal values are
  // the TOP of the address space -- one contiguous unusable region above
  // 240 GB, not holes scattered through it.  Decode must FAULT on them rather
  // than truncate, or an out-of-range access silently aliases onto real data.
  parameter int unsigned REM_MAX = (N_ROW * N_COL_DATA) - 1;

  // -------------------------------------------------------------------------
  // Address-hash configuration.  ONE definition, used by both the fabric-side
  // hbm4_addr_slice and the controller-side hbm4_addr_decode.  If these two
  // ever disagree, memory is corrupted with no error anywhere in the system
  // (docs/03-interface-spec.md 4), which is why they share this struct and a
  // formal equivalence proof.
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic [STACK_W-1:0][SYS_ADDR_W-1:0] h_st;
    logic [PC_W-1:0]   [SYS_ADDR_W-1:0] h_pc;
  } slice_cfg_t;

  typedef struct packed {
    logic [BG_W-1:0][PC_BLK_W-1:0] h_bg;
    logic [BA_W-1:0][PC_BLK_W-1:0] h_ba;
  } local_cfg_t;

endpackage
