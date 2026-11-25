// ---------------------------------------------------------------------------
// fv_scrub -- P-SCRUB-*.
//
// The interesting property is COVERAGE, and it cannot be proved by enumerating
// addresses: the space is 2^25 blocks per pseudo-channel.
//
// It is proved structurally instead.  If the walk advances by EXACTLY ONE
// position on every accepted scrub, in a fixed nested order, and wraps only
// after the last position, then complete coverage follows by induction on the
// enumeration -- no address can be skipped because no step is larger than one.
//
// That is the right shape for this class of property generally: prove the step
// function is a proper enumeration, not that every element is visited.
//
// The other property is that scrub NEVER displaces real traffic.  A scrubber
// that steals bandwidth is one that gets disabled in the field, and a disabled
// scrubber protects nothing.
// ---------------------------------------------------------------------------
module fv_scrub
  import hbm4_pkg::*;
(
  input logic        clk,
  input logic        rst_n,
  input logic        cfg_en,
  input logic [15:0] cfg_rate,
  input logic        host_pending,
  input logic        scrub_ack,
  input logic        scrub_ce,
  input logic        scrub_ue
);

  logic       scrub_req, sweep_done;
  bank_t      scrub_bank, dbg_bank;
  row_t       scrub_row,  dbg_row;
  col_t       scrub_col,  dbg_col;
  logic [31:0] ce_count, ue_count;

  hbm4_scrub dut (
    .clk (clk), .rst_n (rst_n),
    .cfg_en (cfg_en), .cfg_rate (cfg_rate), .host_pending (host_pending),
    .scrub_req (scrub_req), .scrub_bank (scrub_bank), .scrub_row (scrub_row),
    .scrub_col (scrub_col), .scrub_ack (scrub_ack),
    .scrub_ce (scrub_ce), .scrub_ue (scrub_ue),
    .ce_count (ce_count), .ue_count (ue_count), .sweep_done (sweep_done),
    .dbg_bank (dbg_bank), .dbg_row (dbg_row), .dbg_col (dbg_col)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-SCRUB-1: never displaces real traffic ----------------------------
  // Gated on the REQUEST, not merely on the grant: the scrubber must not even
  // compete for the row bus while anything else wants it.
  always @(*)
    if (f_past_valid && rst_n && host_pending)
      p_yields_to_traffic: assert (!scrub_req);

  always @(*)
    if (f_past_valid && rst_n && !cfg_en)
      p_disabled_is_quiet: assert (!scrub_req);

  // ---- P-SCRUB-2: the walk is a strict enumeration ------------------------
  // Position never changes except on an accepted scrub...
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && !($past(scrub_req) && $past(scrub_ack)))
      p_no_drift: assert ((dbg_bank == $past(dbg_bank))
                       && (dbg_row  == $past(dbg_row))
                       && (dbg_col  == $past(dbg_col)));

  // ...and when it does, it advances by EXACTLY ONE position in the nested
  // order.  This is what forbids skipping: no larger step exists.
  always @(posedge clk)
    if (f_past_valid && rst_n && $past(f_past_valid) && $past(rst_n)
        && $past(scrub_req) && $past(scrub_ack)) begin
      if ($past(dbg_col) != col_t'(N_COL_DATA - 1)) begin
        p_col_step : assert ((dbg_col  == $past(dbg_col) + 1'b1)
                          && (dbg_row  == $past(dbg_row))
                          && (dbg_bank == $past(dbg_bank)));
      end else if ($past(dbg_row) != row_t'(N_ROW - 1)) begin
        p_row_step : assert ((dbg_col  == '0)
                          && (dbg_row  == $past(dbg_row) + 1'b1)
                          && (dbg_bank == $past(dbg_bank)));
      end else if ($past(dbg_bank) != bank_t'(N_BANK - 1)) begin
        p_bank_step: assert ((dbg_col  == '0) && (dbg_row == '0)
                          && (dbg_bank == $past(dbg_bank) + 1'b1));
      end else begin
        p_wrap     : assert ((dbg_col == '0) && (dbg_row == '0)
                          && (dbg_bank == '0));
      end
    end

  // ---- P-SCRUB-3: the column walked is always a DATA column ---------------
  // Walking an ECC column would decode it against itself and report a fault on
  // a healthy device.
  always @(*)
    if (f_past_valid && rst_n)
      p_data_col_only: assert (dbg_col < col_t'(N_COL_DATA));

  // ---- P-SCRUB-4: sweep_done marks a real wrap ----------------------------
  always @(posedge clk)
    if (f_past_valid && rst_n && sweep_done)
      p_sweep_at_origin: assert ((dbg_bank == '0) && (dbg_row == '0)
                              && (dbg_col == '0));

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_issues     : cover (scrub_req && scrub_ack);
    c_col_wrap   : cover (scrub_req && scrub_ack
                          && (dbg_col == col_t'(N_COL_DATA - 1)));
    c_held_off   : cover (cfg_en && host_pending);
    c_counts_ce  : cover (ce_count != 32'd0);
  end

endmodule
