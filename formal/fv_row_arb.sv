// ---------------------------------------------------------------------------
// fv_row_arb -- P-ROW-*.  Discharges assumptions A2 (row half) and A7.
//
// fv_timing_engine proves that no JEDEC parameter is violated IF the arbiters
// only issue what the ready vectors permit.  fv_col_arb discharged that for the
// column bus; this discharges it for the row bus.  An assume in one proof must
// be an assert in another, or it is a wish.
//
// It also proves the two priority claims the refresh engine relies on -- that an
// urgent refresh and an RFM request actually reach the bus.  fv_refresh no
// longer assumes them (A5/A6 were deleted in Rev 0.6b), but they are real
// architectural claims from docs/02-architecture.md 8.6, and a claim nobody
// checks is a claim that quietly stops being true.
// ---------------------------------------------------------------------------
module fv_row_arb
  import hbm4_pkg::*;
(
  input logic              clk,
  input logic              rst_n,
  input logic [N_BANK-1:0] act_ok,
  input logic [N_BANK-1:0] pre_ok,
  input logic [N_BANK-1:0] want_act,
  input logic [N_BANK-1:0] want_pre,
  input row_t [N_BANK-1:0] want_row,
  input logic              ref_req,
  input logic              ref_urgent,
  input bank_t             ref_bank,
  input logic              rfm_req,
  input bank_t             rfm_bank
);

  logic       ref_ack, rfm_ack;
  row_issue_t row_iss;

  hbm4_row_arb dut (
    .clk (clk), .rst_n (rst_n),
    .act_ok (act_ok), .pre_ok (pre_ok),
    .want_act (want_act), .want_pre (want_pre), .want_row (want_row),
    .ref_req (ref_req), .ref_urgent (ref_urgent), .ref_bank (ref_bank),
    .rfm_req (rfm_req), .rfm_bank (rfm_bank),
    .ref_ack (ref_ack), .rfm_ack (rfm_ack), .row_iss (row_iss)
  );

  // ---- reset (ASSUMPTION A1) ----------------------------------------------
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- P-ROW-1/2: DISCHARGES A2 (row half) --------------------------------
  // The row bus never carries a command the timing engine has not cleared.
  // This is precisely what fv_timing_engine assumes about ACT and PRE.
  always @(*) begin
    p_act_legal: assert (!(row_iss.valid && (row_iss.cmd == ROW_ACT))
                         || (act_ok[row_iss.bank] && want_act[row_iss.bank]));
    p_pre_legal: assert (!(row_iss.valid && (row_iss.cmd == ROW_PRE))
                         || (pre_ok[row_iss.bank] && want_pre[row_iss.bank]));
  end

  // ---- P-ROW-3: one row command per clock ---------------------------------
  // Structural (row_iss is a single command), but assert it so a future change
  // to a wider issue interface cannot silently break constraint C3's premise.
  always @(*) begin
    p_one_ack     : assert (!(ref_ack && rfm_ack));
    p_ack_needs_req: assert ((!ref_ack || ref_req) && (!rfm_ack || rfm_req));
    p_ack_matches : assert ((!ref_ack || (row_iss.valid && (row_iss.cmd == ROW_REF_SB)))
                         && (!rfm_ack || (row_iss.valid && (row_iss.cmd == ROW_RFM))));
  end

  // ---- P-ROW-4: the ACT carries the row the requester asked for -----------
  // Getting this wrong opens the wrong row: the column stream then reads valid
  // data from the wrong place, with no error anywhere.
  always @(*)
    if (row_iss.valid && (row_iss.cmd == ROW_ACT)) begin
      p_act_row: assert (row_iss.row == want_row[row_iss.bank]);
    end

  // ---- P-ROW-5/6: the priority claims the refresh engine depends on -------
  // These are what A5 and A6 used to assume.  fv_refresh no longer needs them,
  // but the architecture claims them, so they are checked here rather than
  // being quietly untrue.
  always @(*) begin
    p_urgent_refresh_wins: assert (!(ref_req && ref_urgent) || ref_ack);
    p_rfm_beats_act_pre  : assert (!(rfm_req && !ref_ack) || rfm_ack);
  end

  // ---- reachability --------------------------------------------------------
  always @(posedge clk) if (f_past_valid && rst_n) begin
    c_act      : cover (row_iss.valid && (row_iss.cmd == ROW_ACT));
    c_pre      : cover (row_iss.valid && (row_iss.cmd == ROW_PRE));
    c_ref      : cover (ref_ack);
    c_rfm      : cover (rfm_ack);
    // The interesting case: a refresh that is NOT urgent still gets the bus
    // because nothing else wants it -- the opportunistic path.
    c_opp_ref  : cover (ref_ack && !ref_urgent);
    // ...and the case it must NOT take the bus: not urgent, ACT wants it.
    c_act_beats_ref: cover (row_iss.valid && (row_iss.cmd == ROW_ACT)
                            && ref_req && !ref_urgent);
  end

endmodule
