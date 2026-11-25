// ---------------------------------------------------------------------------
// hbm4_bank_state -- per-bank open-row tracking.
//
// A bank has EXACTLY ONE row buffer.  That single fact drives more of this
// design than any other (see docs/02-architecture.md 1.2), and this module is
// where it is represented.
//
// Note what is NOT here: ACTIVATING and PRECHARGING states.  The delay between
// issuing ACT and being able to read is tRCD, which hbm4_timing_engine already
// enforces via t_col.  Duplicating it as an FSM state would give two sources of
// truth for one constraint -- and when those disagree, the bug is invisible.
// So a bank is ACTIVE the instant ACT issues, and legality is the timing
// engine's job alone.
// ---------------------------------------------------------------------------
module hbm4_bank_state
  import hbm4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  input  row_issue_t        row_iss,
  // Needed for auto-precharge: RDA/WRA close the bank with no row command.
  // Only the opcode and bank matter here; the column address does not.
  /* verilator lint_off UNUSEDSIGNAL */
  input  col_issue_t        col_iss,
  /* verilator lint_on UNUSEDSIGNAL */

  output bank_st_e          st       [N_BANK],
  output row_t              open_row [N_BANK],
  output logic [N_BANK-1:0] is_active
);

  bank_st_e st_q       [N_BANK];
  row_t     open_row_q [N_BANK];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned b = 0; b < N_BANK; b++) begin
        st_q[b]       <= BK_IDLE;
        open_row_q[b] <= '0;
      end
    end else begin
      // Row and column effects are applied INDEPENDENTLY, per bank.
      //
      // This must not be an if/else chain across the two buses.  Constraint C3
      // says the row and column buses are separate and issue in the SAME cycle,
      // so an ACT to one bank and an auto-precharging RDA to another both
      // happen at once.  Chaining them would silently drop one -- and the
      // dropped ACT would leave the bank state claiming IDLE while the DRAM
      // has the row open.
      for (int unsigned b = 0; b < N_BANK; b++) begin
        // --- column bus: auto-precharge closes the bank ---
        if (col_iss.valid && (col_iss.bank == bank_t'(b))
            && ((col_iss.cmd == COL_RDA) || (col_iss.cmd == COL_WRA)))
          st_q[b] <= BK_IDLE;

        // --- row bus ---
        if (row_iss.valid) begin
          if ((row_iss.cmd == ROW_PREA) || (row_iss.cmd == ROW_REF_AB)) begin
            st_q[b] <= BK_IDLE;                       // all-bank commands
          end else if (row_iss.bank == bank_t'(b)) begin
            case (row_iss.cmd)
              ROW_ACT: begin
                st_q[b]       <= BK_ACTIVE;
                open_row_q[b] <= row_iss.row;
              end
              ROW_PRE, ROW_REF_SB: st_q[b] <= BK_IDLE;
              default: ;                              // ROW_NOP, ROW_RFM
            endcase
          end
        end
      end
    end
  end

  always_comb begin
    for (int unsigned b = 0; b < N_BANK; b++) begin
      st[b]        = st_q[b];
      open_row[b]  = open_row_q[b];
      is_active[b] = (st_q[b] == BK_ACTIVE);
    end
  end

endmodule
