// ---------------------------------------------------------------------------
// fv_csr -- P-CSR-*.
//
// The lock is the whole point of this block.  Four register groups decide where
// data physically lives -- address-map mode, hash masks, ECC_EN, DRAM timing.
// Changing any of them while traffic runs silently relocates where addresses
// map: writes land in one place and later reads look in another, with no ECC
// error, no interrupt, and no symptom except wrong data.
//
// P-CSR-1 is therefore not a convenience property.  It is the mechanism that
// makes the silent-corruption class of driver bug impossible rather than
// merely unlikely.
// ---------------------------------------------------------------------------
module fv_csr
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input logic        pclk,
  input logic        presetn,
  input logic        psel,
  input logic        penable,
  input logic        pwrite,
  input logic [15:0] paddr,
  input logic [31:0] pwdata,
  input logic [31:0] sts_irq,
  input logic [31:0] sts_perf
);

  logic [31:0] prdata, cfg_amap_mode, cfg_refresh, cfg_ras;
  logic [31:0] cfg_sched [4];
  logic        pready, pslverr, cfg_locked, irq_locked_write;

  hbm4_csr dut (
    .pclk (pclk), .presetn (presetn),
    .psel (psel), .penable (penable), .pwrite (pwrite),
    .paddr (paddr), .pwdata (pwdata), .prdata (prdata),
    .pready (pready), .pslverr (pslverr),
    .cfg_amap_mode (cfg_amap_mode), .cfg_sched (cfg_sched),
    .cfg_refresh (cfg_refresh), .cfg_ras (cfg_ras), .cfg_locked (cfg_locked),
    .sts_irq (sts_irq), .sts_perf (sts_perf),
    .irq_locked_write (irq_locked_write)
  );

  reg f_past_valid = 1'b0;
  always @(posedge pclk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!presetn);
  always @(posedge pclk) if (f_past_valid) assume (presetn);

  // ---- P-CSR-1: a locked register NEVER changes --------------------------
  // The property that makes silent address-map corruption impossible.
  always @(posedge pclk)
    if (f_past_valid && presetn && $past(f_past_valid) && $past(presetn)
        && $past(cfg_locked)) begin
      p_amap_frozen   : assert (cfg_amap_mode == $past(cfg_amap_mode));
      p_refresh_frozen: assert (cfg_refresh   == $past(cfg_refresh));
    end

  // ---- P-CSR-2: the lock itself is one-way -------------------------------
  // A lock the untrusted bus can undo is not a lock.
  always @(posedge pclk)
    if (f_past_valid && presetn && $past(f_past_valid) && $past(presetn)
        && $past(cfg_locked))
      p_lock_sticky: assert (cfg_locked);

  // ---- P-CSR-3: a refused write is REPORTED, never silent ----------------
  // Both channels, because an integrator who checks only one still needs to
  // find the driver bug.
  always @(*)
    if (f_past_valid && presetn && psel && penable && pwrite && cfg_locked
        && ((paddr == 16'h0100) || (paddr == 16'h0400)
            || ((paddr >= 16'h0200) && (paddr < 16'h0300)))) begin
      p_refused_slverr: assert (pslverr);
      p_refused_irq   : assert (irq_locked_write);
    end

  // ---- P-CSR-4: an UNLOCKED write takes effect ---------------------------
  // Without this, a CSR block that simply ignores every write satisfies all of
  // the above -- and the whole property set would be vacuous.
  always @(posedge pclk)
    if (f_past_valid && presetn && $past(f_past_valid) && $past(presetn)
        && $past(psel) && $past(penable) && $past(pwrite) && !$past(cfg_locked)
        && ($past(paddr) == 16'h0100))
      p_write_lands: assert (cfg_amap_mode == $past(pwdata));

  // ---- P-CSR-5: APB handshake --------------------------------------------
  always @(*)
    if (f_past_valid && presetn) begin
      p_ready_in_access: assert (pready == (psel && penable));
      p_no_err_idle    : assert (!pslverr || (psel && penable && pwrite));
    end

  // ---- reachability --------------------------------------------------------
  always @(posedge pclk) if (f_past_valid && presetn) begin
    c_locked  : cover (cfg_locked);
    c_refused : cover (irq_locked_write);
    c_write   : cover (psel && penable && pwrite && !cfg_locked);
    c_read_id : cover (psel && penable && !pwrite && (prdata == 32'h4842_4D34));
  end

endmodule
