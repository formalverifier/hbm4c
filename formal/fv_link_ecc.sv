// ---------------------------------------------------------------------------
// fv_link_ecc -- P-LECC-*.
//
// Two properties, and they pull in opposite directions -- which is exactly why
// both need stating:
//
//   P-LECC-1  retry is BOUNDED.  Unbounded retry on a hard fault (a broken
//             lane, a dead TSV) is a livelock: the controller re-reads forever
//             and the host waits on a response that never comes.  A hang is
//             worse than an error report, because there is nothing to log.
//
//   P-LECC-2  an error is NEVER silently dropped.  Every read either succeeds,
//             is corrected, is retried, or is escalated as uncorrectable.  The
//             one outcome that must be impossible is "ok" on data the codec
//             flagged.
//
// A design that satisfies only the first hangs; only the second corrupts.
// ---------------------------------------------------------------------------
module fv_link_ecc
  import hbm4_pkg::*;
#(
  parameter int unsigned RETRY_MAX = 3
) (
  input logic                   clk,
  input logic                   rst_n,
  input logic [15:0]            cfg_ce_thresh,
  input logic                   cfg_retry_en,
  input logic                   rx_valid,
  input logic [AG_BYTES*8-1:0]  rx_data,
  input logic [ECC_FIELD_W-1:0] rx_code,
  input tqidx_t                 rx_idx,
  input logic                   retry_ack
);

  localparam int unsigned RW = $clog2(RETRY_MAX + 1);

  logic                  out_valid, retry_req, thresh_irq;
  logic [AG_BYTES*8-1:0] out_data;
  tqidx_t                out_idx, retry_idx;
  logic [1:0]            out_err;
  logic [15:0]           ce_count, ue_count;
  logic [RW-1:0]         dbg_retries;

  hbm4_link_ecc #(.RETRY_MAX(RETRY_MAX)) dut (
    .clk (clk), .rst_n (rst_n),
    .cfg_ce_thresh (cfg_ce_thresh), .cfg_retry_en (cfg_retry_en),
    .rx_valid (rx_valid), .rx_data (rx_data), .rx_code (rx_code),
    .rx_idx (rx_idx),
    .out_valid (out_valid), .out_data (out_data), .out_idx (out_idx),
    .out_err (out_err),
    .retry_req (retry_req), .retry_idx (retry_idx), .retry_ack (retry_ack),
    .ce_count (ce_count), .ue_count (ue_count), .thresh_irq (thresh_irq),
    .dbg_retries (dbg_retries)
  );

  // Reference decode, instantiated HERE rather than reached into the DUT.
  // Hierarchical references into an sv2v-converted design have been unreliable
  // throughout this project, and an independent instance is a better property
  // anyway: it compares the DUT's reported status against a separately
  // elaborated decode of the same inputs.
  logic                  ref_ce, ref_ue, ref_pois;
  logic [AG_BYTES*8-1:0] ref_fixed;
  logic [ECC_FIELD_W-1:0] ref_unused;

  hbm4_sys_ecc u_ref (
    .enc_data ('0), .enc_poison (1'b0), .enc_field (ref_unused),
    .dec_data (rx_data), .dec_field (rx_code),
    .dec_corrected (ref_fixed), .dec_ce (ref_ce), .dec_ue (ref_ue),
    .dec_poison (ref_pois)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-LECC-1: retry is bounded -----------------------------------------
  always @(*)
    if (f_past_valid && rst_n)
      p_retry_bounded: assert (dbg_retries <= RW'(RETRY_MAX));

  // Once the budget is spent, no further retry is requested -- the transaction
  // MUST complete, one way or the other.
  always @(*)
    if (f_past_valid && rst_n && (dbg_retries >= RW'(RETRY_MAX)))
      p_no_retry_when_spent: assert (!retry_req);

  // ---- P-LECC-2: an arriving read is never silently dropped ---------------
  // Every rx_valid either produces an output or a retry request.  Neither is
  // the same as "vanishes".
  always @(*)
    if (f_past_valid && rst_n && rx_valid)
      p_never_dropped: assert (out_valid || retry_req);

  // ...and an output never reports success on data the codec flagged.
  always @(*)
    if (f_past_valid && rst_n && out_valid) begin
      p_ue_escalated : assert (!(ref_ue || ref_pois) || (out_err == 2'd2));
      p_ce_reported  : assert (!(ref_ce && !ref_ue && !ref_pois)
                               || (out_err == 2'd1));
      p_clean_is_ok  : assert ((ref_ce || ref_ue || ref_pois)
                               || (out_err == 2'd0));
      // The data handed on must be the CORRECTED data, not the raw payload.
      p_data_corrected: assert (out_data == ref_fixed);
    end

  // ---- P-LECC-3: a corrected read is not retried --------------------------
  // The data is already good; retrying it would spend budget for nothing and
  // delay a transaction that has nothing wrong with it.
  always @(*)
    if (f_past_valid && rst_n && rx_valid && ref_ce && !ref_ue)
      p_no_retry_on_ce: assert (!retry_req);

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_clean     : cover (out_valid && (out_err == 2'd0));
    c_corrected : cover (out_valid && (out_err == 2'd1));
    c_retry     : cover (retry_req);
    // The case P-LECC-1 exists for: a hard fault that exhausts the budget and
    // is then reported rather than retried forever.
    c_escalated : cover (out_valid && (out_err == 2'd2)
                         && (dbg_retries >= RW'(RETRY_MAX)));
    c_thresh    : cover (thresh_irq);
  end

endmodule
