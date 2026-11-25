// ---------------------------------------------------------------------------
// hbm4_dir_fsm -- read/write direction batching.
//
// The DQ bus is bidirectional and turning it around wastes ~12 ns of totally
// dead bus.  Switching direction per request would spend more time turning
// than transferring, so reads and writes are batched into long runs:
//
//     overhead = t_turn / (Bw + Br + t_turn)
//
// At WBUF_DEPTH = 128 and a 2:1 read:write mix that is 3.0%.  At 64 it is
// 5.9%.  Those 512 KB of extra SRAM buy ~240 GB/s -- see docs/02 8.4.
//
// The dead cycles themselves are enforced by hbm4_timing_engine (t_rtw,
// t_wtr_s/l), not here.  This block only decides WHEN to turn; the timing
// engine decides when the turn has completed.
// ---------------------------------------------------------------------------
module hbm4_dir_fsm
  import hbm4_pkg::*;
  import hbm4_timing_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,

  // policy (CSR)
  input  logic [15:0]       wr_hi,          // leave READ when writes reach this
  input  logic [15:0]       wr_lo,          // leave WRITE when writes fall to this
  input  logic [15:0]       wr_burst_credit,// max writes per drain
  input  logic [31:0]       wr_age_limit,   // starvation guard, clocks
  input  logic              wr_preempt_en,

  // status
  input  logic [15:0]       wr_occupancy,
  input  logic              rd_pending,
  input  logic              wr_pending,
  input  logic              raw_hazard,     // a read needs a specific write drained
  input  logic [31:0]       wr_oldest_age,
  input  logic              urgent_rd,

  // the timing engine tells us when the bus has finished turning
  input  logic [N_BANK-1:0] rd_ok,
  input  logic [N_BANK-1:0] wr_ok,

  input  logic              col_issued,     // a column command went out this cycle

  output dir_e              dir,
  output logic              turning
);

  typedef enum logic [1:0] {
    S_READ = 2'd0, S_TO_WR = 2'd1, S_WRITE = 2'd2, S_TO_RD = 2'd3
  } st_e;

  st_e         st;
  logic [15:0] burst_cnt;

  logic leave_read, leave_write;

  always_comb begin
    leave_read = (wr_occupancy >= wr_hi)
              || (!rd_pending && wr_pending)
              || raw_hazard
              || (wr_pending && (wr_oldest_age >= wr_age_limit));

    leave_write = (wr_occupancy <= wr_lo)
               || (burst_cnt >= wr_burst_credit)
               || !wr_pending
               || (wr_preempt_en && urgent_rd);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st        <= S_READ;
      burst_cnt <= '0;
    end else begin
      case (st)
        S_READ:  if (leave_read)  st <= S_TO_WR;
        // The turnaround timers are shared, so "any bank may write" is exactly
        // the condition that the bus has finished turning.
        S_TO_WR: if (|wr_ok) begin st <= S_WRITE; burst_cnt <= '0; end
        S_WRITE: begin
          if (col_issued) burst_cnt <= burst_cnt + 16'd1;
          if (leave_write) st <= S_TO_RD;
        end
        S_TO_RD: if (|rd_ok) st <= S_READ;
        default: st <= S_READ;
      endcase
    end
  end

  assign dir     = (st == S_WRITE) ? DIR_WRITE : DIR_READ;
  assign turning = (st == S_TO_WR) || (st == S_TO_RD);

`ifdef FORMAL
  // Bounded liveness: a write drain cannot run forever, so reads always resume.
  always_ff @(posedge clk)
    if (rst_n) a_burst_bounded: assert (burst_cnt <= wr_burst_credit + 16'd1);
`endif

endmodule
