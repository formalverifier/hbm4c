// ---------------------------------------------------------------------------
// hbm4_scrub -- patrol scrub: background walk of the address space.
//
// Latent single-bit errors accumulate.  A block that has sat unread for hours
// can pick up a second one, and SEC-DED then reports it as uncorrectable --
// data that was recoverable yesterday is lost today.  Scrub reads every block
// periodically so single errors are found and rewritten while they are still
// single.
//
// TWO REQUIREMENTS, and they are in tension:
//
//   1. NEVER displace real traffic.  Scrub runs at the lowest priority and
//      only when nothing else wants the bus.  A scrubber that steals bandwidth
//      is a scrubber that gets disabled in the field, which is worse than not
//      having one.
//
//   2. COVER EVERYTHING.  A walk that skips blocks leaves exactly the regions
//      scrub exists to protect unprotected -- and silently, because a skipped
//      block looks identical to a clean one.  The address walk is therefore a
//      strict enumeration: +1 per accepted scrub, wrapping only after the last
//      address (P-SCRUB-2).
//
// ECC columns are not walked.  They are read implicitly whenever their data
// blocks are, and reading them as data would decode them against themselves.
// ---------------------------------------------------------------------------
module hbm4_scrub
  import hbm4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  logic              cfg_en,
  input  logic [15:0]       cfg_rate,      // clocks between scrub issues

  // ---- back-pressure from real traffic ------------------------------------
  input  logic              host_pending,  // anything else wants the bus

  // ---- scrub request -------------------------------------------------------
  output logic              scrub_req,
  output bank_t             scrub_bank,
  output row_t              scrub_row,
  output col_t              scrub_col,
  input  logic              scrub_ack,

  // ---- error feedback ------------------------------------------------------
  input  logic              scrub_ce,
  input  logic              scrub_ue,
  output logic [31:0]       ce_count,
  output logic [31:0]       ue_count,

  // ---- status --------------------------------------------------------------
  output logic              sweep_done,    // pulses at the end of a full pass
  output bank_t             dbg_bank,
  output row_t              dbg_row,
  output col_t              dbg_col
);

  // ---- walk position -------------------------------------------------------
  // Nested counters rather than one flat address: the enumeration order is then
  // explicit, and "advances by exactly one position" is a property that can be
  // stated directly instead of inferred from arithmetic on a packed value.
  bank_t w_bank;
  row_t  w_row;
  col_t  w_col;

  logic col_last, row_last, bank_last;
  assign col_last  = (w_col  == col_t'(N_COL_DATA - 1));
  assign row_last  = (w_row  == row_t'(N_ROW - 1));
  assign bank_last = (w_bank == bank_t'(N_BANK - 1));

  assign scrub_bank = w_bank;
  assign scrub_row  = w_row;
  assign scrub_col  = w_col;
  assign dbg_bank   = w_bank;
  assign dbg_row    = w_row;
  assign dbg_col    = w_col;

  // ---- rate limit ----------------------------------------------------------
  logic [15:0] tick_cnt;
  logic        tick;
  assign tick = (tick_cnt == 16'd0);

  // Lowest priority, unconditionally.  host_pending gates the REQUEST, not just
  // the grant, so the scrubber never even competes for the row bus.
  assign scrub_req = cfg_en && tick && !host_pending;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      w_bank     <= '0;
      w_row      <= '0;
      w_col      <= '0;
      tick_cnt   <= 16'd0;
      ce_count   <= 32'd0;
      ue_count   <= 32'd0;
      sweep_done <= 1'b0;
    end else begin
      sweep_done <= 1'b0;

      // rate counter: reload on every issue, otherwise count down to the next
      // opportunity.  It does NOT run down while host_pending holds the request
      // off -- otherwise a busy period would bank up credits and the scrubber
      // would burst afterwards, which is precisely the displacement requirement
      // (1) forbids.
      if (scrub_req && scrub_ack)      tick_cnt <= cfg_rate;
      else if (!tick && !host_pending) tick_cnt <= tick_cnt - 16'd1;

      // Advance ONLY on an accepted scrub, and by exactly one position.
      if (scrub_req && scrub_ack) begin
        if (!col_last) begin
          w_col <= w_col + 1'b1;
        end else begin
          w_col <= '0;
          if (!row_last) begin
            w_row <= w_row + 1'b1;
          end else begin
            w_row <= '0;
            w_bank <= bank_last ? '0 : bank_t'(w_bank + 1'b1);
            sweep_done <= bank_last;
          end
        end
      end

      if (scrub_ack && scrub_ce && (ce_count != 32'hFFFF_FFFF))
        ce_count <= ce_count + 32'd1;
      if (scrub_ack && scrub_ue && (ue_count != 32'hFFFF_FFFF))
        ue_count <= ue_count + 32'd1;
    end
  end

endmodule
