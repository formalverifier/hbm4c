// ---------------------------------------------------------------------------
// hbm4_link_ecc -- link ECC check, bounded retry, and escalation.
//
// Protects the micro-bump / TSV / PHY path, where transient errors at 8 Gb/s
// actually occur.  Because they ARE transient, a re-read usually succeeds and
// the host never learns anything happened -- which is the whole reason for
// retrying rather than reporting immediately.
//
// The coding itself is not repeated here: this module instantiates the codec
// that hbm4_sys_ecc already proves.  What is local to this block, and what the
// properties are about, is the RETRY POLICY:
//
//   - retry is BOUNDED.  An unbounded retry on a hard fault -- a broken lane,
//     a dead TSV -- is a livelock: the controller re-reads forever, the
//     transaction never completes, and the host waits on a response that will
//     never arrive.  A hang is worse than an error report.
//
//   - an error is NEVER silently dropped.  Every read either succeeds, is
//     corrected, is retried, or is escalated as uncorrectable.  There is no
//     path that returns "ok" on data the codec flagged.
//
// A rising correctable rate is also the leading indicator of a degrading link,
// so the counters feed a threshold interrupt that triggers a retrain
// (docs/02-architecture.md 10.1).
// ---------------------------------------------------------------------------
module hbm4_link_ecc
  import hbm4_pkg::*;
#(
  parameter int unsigned RETRY_MAX = 3
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic [15:0]             cfg_ce_thresh,
  input  logic                    cfg_retry_en,

  // ---- read data arriving from the PHY ------------------------------------
  input  logic                    rx_valid,
  input  logic [AG_BYTES*8-1:0]   rx_data,
  input  logic [ECC_FIELD_W-1:0]  rx_code,
  input  tqidx_t                  rx_idx,

  // ---- corrected data out --------------------------------------------------
  output logic                    out_valid,
  output logic [AG_BYTES*8-1:0]   out_data,
  output tqidx_t                  out_idx,
  output logic [1:0]              out_err,      // 0 ok, 1 corrected, 2 uncorrectable

  // ---- retry request -------------------------------------------------------
  output logic                    retry_req,
  output tqidx_t                  retry_idx,
  input  logic                    retry_ack,

  // ---- status --------------------------------------------------------------
  output logic [15:0]             ce_count,
  output logic [15:0]             ue_count,
  output logic                    thresh_irq,
  output logic [$clog2(RETRY_MAX+1)-1:0] dbg_retries
);

  localparam int unsigned RW = $clog2(RETRY_MAX + 1);

  // ---- decode (codec proved separately by fv_sys_ecc) ---------------------
  logic                  ce, ue, pois;
  logic [AG_BYTES*8-1:0] fixed;
  // The encode side of the codec is unused on the receive path.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ECC_FIELD_W-1:0] unused_enc;
  /* verilator lint_on UNUSEDSIGNAL */

  hbm4_sys_ecc u_codec (
    .enc_data ('0), .enc_poison (1'b0), .enc_field (unused_enc),
    .dec_data (rx_data), .dec_field (rx_code),
    .dec_corrected (fixed), .dec_ce (ce), .dec_ue (ue), .dec_poison (pois)
  );

  // ---- retry accounting ----------------------------------------------------
  logic [RW-1:0] retries;
  logic          retry_exhausted;

  assign retry_exhausted = (retries >= RW'(RETRY_MAX));
  assign dbg_retries     = retries;

  // Retry only a detected-uncorrectable, only if enabled, and only while the
  // budget lasts.  A CORRECTED read needs no retry -- the data is already good.
  assign retry_req = rx_valid && ue && cfg_retry_en && !retry_exhausted;
  assign retry_idx = rx_idx;

  // ---- output --------------------------------------------------------------
  // The read is passed on unless it is being retried.  Every non-retried case
  // carries its true status: a UE that has run out of retries is reported as
  // uncorrectable, never as success.
  assign out_valid = rx_valid && !retry_req;
  assign out_data  = fixed;
  assign out_idx   = rx_idx;

  always_comb begin
    if (ue || pois)  out_err = 2'd2;   // detected-uncorrectable, or stored poison
    else if (ce)     out_err = 2'd1;   // corrected, data is good
    else             out_err = 2'd0;
  end

  // ---- counters ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      retries    <= '0;
      ce_count   <= 16'd0;
      ue_count   <= 16'd0;
    end else begin
      // Budget is per transaction: a retry that is accepted spends one, and any
      // completed read resets it for the next.
      if (retry_req && retry_ack)      retries <= retries + 1'b1;
      else if (out_valid)              retries <= '0;

      if (out_valid && (out_err == 2'd1) && (ce_count != 16'hFFFF))
        ce_count <= ce_count + 16'd1;
      if (out_valid && (out_err == 2'd2) && (ue_count != 16'hFFFF))
        ue_count <= ue_count + 16'd1;
    end
  end

  assign thresh_irq = (ce_count >= cfg_ce_thresh);

endmodule
