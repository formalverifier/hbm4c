// ---------------------------------------------------------------------------
// fv_wdata_ram -- P-WD-*.  Write-data storage on the write datapath.
//
// This block is new in Rev 1.3 and it sits directly on the path between the
// host's write data and the DRAM.  If it returns the wrong entry, the wrong
// bytes are written to a correct address: silent corruption with no error
// anywhere, which is the failure class this whole design works hardest to
// exclude.
//
// The data-integrity proof tracks ONE SYMBOLIC TAG.  That technique failed on
// hbm4_rd_ptr_fifo (OPEN-6) because a ring FIFO's entry lifetime depends on two
// pointers and a count, and the invariant tying them together was not reachable
// in three attempts.  Here it works, and the reason is worth stating: this is a
// flat RAM, so mem[t] is written by exactly one condition -- wr_valid with
// wr_tag == t -- and nothing else can disturb it.  There is no ordering state to
// strengthen over.
// ---------------------------------------------------------------------------
module fv_wdata_ram
  import hbm4_pkg::*;
#(
  // Narrow on purpose: at DW = 8 a shadow of EVERY entry is 32 bits, so the
  // invariant is unconditional rather than conditional on the environment
  // happening to address the tracked entry -- which is what defeated the
  // single-entry attempt. The block never inspects the data it carries, so this
  // is width-independent by construction (see the DW comment in the RTL).
  parameter int unsigned DW = 8
) (
  input logic clk,
  input logic rst_n,
  input logic wr_valid,
  input tag_t wr_tag,
  input logic [DW-1:0] wr_data,
  input logic rd_valid,
  input tag_t rd_tag
);

  logic [DW-1:0] rd_data;
  logic                  err_no_data;
  logic [TQ_DEPTH-1:0]   dbg_written;

  hbm4_wdata_ram #(.DW(DW)) dut (
    .clk (clk), .rst_n (rst_n),
    .wr_valid (wr_valid), .wr_tag (wr_tag), .wr_data (wr_data),
    .rd_valid (rd_valid), .rd_tag (rd_tag), .rd_data (rd_data),
    .err_no_data (err_no_data), .dbg_written (dbg_written)
  );

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  always @(*) if (!f_past_valid) assume (!rst_n);
  always @(posedge clk) if (f_past_valid) assume (rst_n);

  // ---- shadow model of one arbitrary tag ----------------------------------
  // Written independently of the DUT: it records what the INTERFACE promised,
  // not what the DUT stored, so the two can disagree.
  logic [DW-1:0]       f_shadow [TQ_DEPTH];
  logic [TQ_DEPTH-1:0] f_has;

  always @(posedge clk) begin
    if (!rst_n) begin
      f_has <= '0;
    end else begin
      for (int unsigned i = 0; i < TQ_DEPTH; i++) begin
        if (wr_valid && (32'(wr_tag) == 32'(i))) begin
          f_shadow[i] <= wr_data;
          f_has[i]    <= 1'b1;
        end else if (rd_valid && (32'(rd_tag) == 32'(i))) begin
          f_has[i]    <= 1'b0;
        end
      end
    end
  end

  // ---- P-WD-1: the entry read is the entry written --------------------------
  always @(*)
    if (f_past_valid && rst_n && f_has[rd_tag])
      p_data_integrity: assert (rd_data == f_shadow[rd_tag]);

  // ---- P-WD-2: the written-flag mirrors the shadow --------------------------
  // The strengthening invariant. Without it p_data_integrity is not inductive:
  // the solver may start from a state where f_has is set but the DUT believes
  // the entry is stale, and then a read reports no error while returning junk.
  always @(*)
    if (f_past_valid && rst_n)
      p_flag_agrees: assert (dbg_written == f_has);

  // ---- P-WD-3: issuing a write with no data is REPORTED ---------------------
  // A write that reaches the DRAM carrying whatever the RAM happened to hold is
  // corruption. It is a host-protocol violation (docs/03 H3), so the controller
  // cannot prevent it -- but it must never be silent.
  always @(*)
    if (f_past_valid && rst_n && rd_valid && !dbg_written[rd_tag])
      p_no_data_flagged: assert (err_no_data);

  always @(*)
    if (f_past_valid && rst_n && rd_valid && dbg_written[rd_tag])
      p_no_false_alarm: assert (!err_no_data);

  // ---- anti-vacuity ---------------------------------------------------------
  // Every property above is guarded. Without these covers, a configuration in
  // which f_tag is never written makes all four hold trivially -- the trap that
  // has caught this project five times (formal/SCALING.md 3, 5a).
  always @(*) if (f_past_valid && rst_n) begin
    c_written  : cover (|f_has);
    c_read_back: cover (f_has[rd_tag] && rd_valid);
    c_err      : cover (err_no_data);
    c_reuse    : cover (wr_valid && rd_valid && (wr_tag == rd_tag));
  end

endmodule
