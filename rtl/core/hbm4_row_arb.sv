// ---------------------------------------------------------------------------
// hbm4_row_arb -- row command arbiter.  Runs in the SAME cycle as
// hbm4_col_arb, on a physically separate bus (constraint C3).
//
// This is the single biggest departure from a DDR5 controller.  In DDR there
// is one command bus, so one arbiter must choose between ACT and RD.  HBM
// gives each pseudo-channel a row bus AND a column bus, so an ACT and a RD
// issue together, every cycle, for free.  Building one combined arbiter here
// would silently throw away half the command bandwidth.
//
// Priority:
//   0  refresh, once the credit engine calls it urgent (data integrity)
//   1  RFM / DRFM (row hammer -- also data integrity)
//   2  PRE  -- close a row nobody wants any more
//   3  ACT  -- look-ahead: open the bank the column stream reaches in ~tRCD
//
// On look-ahead: activating too early burns tRAS and tFAW budget on a row that
// cannot be used yet; too late stalls the column bus, which C1 forbids.  The
// need-time estimate is deliberately approximate -- being wrong costs a bubble,
// never correctness, and no formal property may depend on it.
// ---------------------------------------------------------------------------
module hbm4_row_arb
  import hbm4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  logic [N_BANK-1:0] act_ok,        // from hbm4_timing_engine
  input  logic [N_BANK-1:0] pre_ok,
  input  logic [N_BANK-1:0] want_act,      // bank idle, requests pending
  input  logic [N_BANK-1:0] want_pre,      // bank open on a row nobody wants
  input  row_t [N_BANK-1:0] want_row,      // packed: crosses to formal cleanly

  // refresh engine
  input  logic              ref_req,
  input  logic              ref_urgent,
  input  bank_t             ref_bank,
  input  logic              rfm_req,
  input  bank_t             rfm_bank,
  output logic              ref_ack,
  output logic              rfm_ack,

  output row_issue_t        row_iss
);

  localparam int unsigned PW = (N_BANK > 1) ? $clog2(N_BANK) : 1;

  logic [N_BANK-1:0] act_cand, pre_cand;
  assign act_cand = act_ok & want_act;
  assign pre_cand = pre_ok & want_pre;

  logic [PW-1:0]     ptr;
  logic [N_BANK-1:0] act_grant, pre_grant;
  logic              act_valid, pre_valid;

  hbm4_rr_arb #(.N(N_BANK)) u_rr_act (
    .req(act_cand), .ptr(ptr), .grant(act_grant), .valid(act_valid));

  hbm4_rr_arb #(.N(N_BANK)) u_rr_pre (
    .req(pre_cand), .ptr(ptr), .grant(pre_grant), .valid(pre_valid));

  bank_t act_bank, pre_bank;
  always_comb begin
    act_bank = '0;
    pre_bank = '0;
    for (int unsigned b = 0; b < N_BANK; b++) begin
      if (act_grant[b]) act_bank = bank_t'(b);
      if (pre_grant[b]) pre_bank = bank_t'(b);
    end
  end

  // ---- priority ------------------------------------------------------------
  // Refresh takes the bus unconditionally once urgent: at ref_debt >= 6 the
  // device is 6 refreshes behind and correctness, not bandwidth, is at stake.
  always_comb begin
    row_iss     = '{valid: 1'b0, cmd: ROW_NOP, bank: '0, row: '0};
    ref_ack     = 1'b0;
    rfm_ack     = 1'b0;

    if (ref_req && (ref_urgent || (!act_valid && !pre_valid))) begin
      row_iss = '{valid: 1'b1, cmd: ROW_REF_SB, bank: ref_bank, row: '0};
      ref_ack = 1'b1;
    end else if (rfm_req) begin
      row_iss = '{valid: 1'b1, cmd: ROW_RFM, bank: rfm_bank, row: '0};
      rfm_ack = 1'b1;
    end else if (pre_valid) begin
      row_iss = '{valid: 1'b1, cmd: ROW_PRE, bank: pre_bank, row: '0};
    end else if (act_valid) begin
      row_iss = '{valid: 1'b1, cmd: ROW_ACT, bank: act_bank, row: want_row[act_bank]};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n)
      ptr <= '0;
    else if (row_iss.valid && ((row_iss.cmd == ROW_ACT) || (row_iss.cmd == ROW_PRE)))
      ptr <= (row_iss.bank == bank_t'(N_BANK-1)) ? '0 : PW'(row_iss.bank + 1'b1);
  end

`ifdef FORMAL
  always_comb begin
    // Never ACT a bank the timing engine has not cleared.
    a_act_legal: assert (!(row_iss.valid && (row_iss.cmd == ROW_ACT))
                         || act_ok[row_iss.bank]);
    a_pre_legal: assert (!(row_iss.valid && (row_iss.cmd == ROW_PRE))
                         || pre_ok[row_iss.bank]);
    // Refresh and RFM are mutually exclusive on the bus.
    a_one_ack:   assert (!(ref_ack && rfm_ack));
  end
`endif

endmodule
