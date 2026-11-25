// ---------------------------------------------------------------------------
// hbm4_csr -- APB4 configuration and status registers.
//
// The interesting behaviour here is not the bus protocol, it is the LOCK.
//
// Four register groups decide where data physically lives: the address-map
// mode, the thirteen hash masks, ECC_EN, and the DRAM timing set.  Changing
// any of them while traffic runs does not fail loudly -- it silently relocates
// where addresses map, so writes land in one place and later reads look in
// another.  There is no ECC error for that, no interrupt, no symptom except
// wrong data.
//
// So firmware sets AMAP_LOCK once at boot and those registers become immutable
// until a cold reset.  A post-lock write is DROPPED, flagged with pslverr, and
// raises an interrupt -- it is a driver bug, and one that must not fail quietly
// (docs/04-programming-guide.md 1.7).
//
// The lock bit is itself sticky: it can be set, never cleared.  A lock that can
// be unlocked by the same bus that must not be trusted is not a lock.
// ---------------------------------------------------------------------------
module hbm4_csr
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input  logic         pclk,
  input  logic         presetn,

  // ---- APB4 ----------------------------------------------------------------
  input  logic         psel,
  input  logic         penable,
  input  logic         pwrite,
  input  logic [15:0]  paddr,
  input  logic [31:0]  pwdata,
  output logic [31:0]  prdata,
  output logic         pready,
  output logic         pslverr,

  // ---- configuration out ---------------------------------------------------
  output logic [31:0]  cfg_amap_mode,
  output logic [31:0]  cfg_sched [4],
  output logic [31:0]  cfg_refresh,
  output logic [31:0]  cfg_ras,
  output logic         cfg_locked,

  // ---- status in -----------------------------------------------------------
  input  logic [31:0]  sts_irq,
  input  logic [31:0]  sts_perf,

  output logic         irq_locked_write   // a write was refused after LOCK
);

  // Register map (offsets within this block; see docs/04 1.1 for the aperture)
  localparam logic [15:0] A_ID        = 16'h0000;
  localparam logic [15:0] A_AMAP      = 16'h0100;
  localparam logic [15:0] A_LOCK      = 16'h01F0;
  localparam logic [15:0] A_SCHED0    = 16'h0500;
  localparam logic [15:0] A_REFRESH   = 16'h0400;
  localparam logic [15:0] A_RAS       = 16'h0600;
  localparam logic [15:0] A_IRQ       = 16'h0018;
  localparam logic [15:0] A_PERF      = 16'h2000;

  // ---- APB access phase ----------------------------------------------------
  // Single-cycle: pready is asserted in the ACCESS phase.  No wait states are
  // needed -- every register is a flop, not a memory.
  logic access, wr_access, rd_access;
  assign access    = psel && penable;
  assign wr_access = access &&  pwrite;
  assign rd_access = access && !pwrite;
  assign pready    = access;

  // ---- which registers the lock protects -----------------------------------
  // Everything that decides where data physically lives.
  logic addr_is_locked_group;
  always_comb begin
    addr_is_locked_group = (paddr == A_AMAP)
                        || (paddr == A_REFRESH)
                        || ((paddr >= 16'h0200) && (paddr < 16'h0300));  // timing
  end

  logic refused;
  assign refused = wr_access && cfg_locked && addr_is_locked_group;

  // A refused write is an error on the bus AND an interrupt.  Reporting only
  // one lets a driver bug slip past whichever the integrator does not check.
  assign pslverr           = refused;
  assign irq_locked_write  = refused;

  // ---- registers -----------------------------------------------------------
  always_ff @(posedge pclk) begin
    if (!presetn) begin
      cfg_amap_mode <= 32'd0;
      cfg_refresh   <= 32'd0;
      cfg_ras       <= 32'd0;
      cfg_locked    <= 1'b0;
      for (int unsigned i = 0; i < 4; i++) cfg_sched[i] <= 32'd0;
    end else if (wr_access && !refused) begin
      case (paddr)
        A_AMAP:    cfg_amap_mode <= pwdata;
        A_REFRESH: cfg_refresh   <= pwdata;
        A_RAS:     cfg_ras       <= pwdata;
        // Set-only.  There is deliberately no path that clears this short of a
        // cold reset: a lock the untrusted bus can undo is not a lock.
        A_LOCK:    if (pwdata[0]) cfg_locked <= 1'b1;
        default: begin
          if ((paddr >= A_SCHED0) && (paddr < A_SCHED0 + 16'd16))
            cfg_sched[paddr[3:2]] <= pwdata;
        end
      endcase
    end
  end

  // ---- read ----------------------------------------------------------------
  always_comb begin
    prdata = 32'd0;
    if (rd_access) begin
      case (paddr)
        A_ID:      prdata = 32'h4842_4D34;      // "HBM4"
        A_AMAP:    prdata = cfg_amap_mode;
        A_LOCK:    prdata = {31'd0, cfg_locked};
        A_REFRESH: prdata = cfg_refresh;
        A_RAS:     prdata = cfg_ras;
        A_IRQ:     prdata = sts_irq;
        A_PERF:    prdata = sts_perf;
        default: begin
          if ((paddr >= A_SCHED0) && (paddr < A_SCHED0 + 16'd16))
            prdata = cfg_sched[paddr[3:2]];
        end
      endcase
    end
  end

endmodule
