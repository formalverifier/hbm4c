// ---------------------------------------------------------------------------
// hbm4_nhi_target -- Native Host Interface endpoint: credit accounting, tag
// pass-through, and response assembly.
//
// The NHI is deliberately minimal (docs/03-interface-spec.md 1): no burst
// descriptors, no ID-ordering matrix, no protocol FSM, and NO ready signal on
// the request channel.  A credit IS the permission to send.
//
// Why credits rather than ready/valid: at 1 GHz with 256 ports, a combinational
// ready travelling back to the requester is a timing problem at every one of
// them.  Credits are a purely local decision on the host side -- it knows
// whether it may send without waiting for anything this cycle.
//
// The controller's obligation is therefore an accounting one: never accept more
// outstanding requests than it has capacity for, and return exactly one credit
// per completion.  Over-issuing a credit overflows the transaction pool and
// silently drops a request -- there is no error path for that, which is why
// P-NHI-1 is proved rather than tested.
// ---------------------------------------------------------------------------
module hbm4_nhi_target
  import hbm4_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- NHI request channel -------------------------------------------------
  input  logic                    req_valid,
  input  logic                    req_wr,
  input  logic [PC_BLK_W-1:0]     req_blk,
  input  tag_t                    req_tag,
  input  qos_t                    req_qos,
  output logic                    req_credit,     // one pulse per freed entry

  // ---- to the controller core ---------------------------------------------
  output logic                    core_valid,
  output logic                    core_wr,
  output logic [PC_BLK_W-1:0]     core_blk,
  output tag_t                    core_tag,
  output qos_t                    core_qos,

  // ---- completion from the core -------------------------------------------
  input  logic                    cmpl_valid,
  input  tag_t                    cmpl_tag,
  input  logic                    cmpl_wr,
  input  logic [DFI_DATA_W-1:0]   cmpl_data,
  input  logic [1:0]              cmpl_err,
  output logic                    cmpl_ready,

  // ---- NHI response channel -----------------------------------------------
  output logic                    rsp_valid,
  input  logic                    rsp_ready,
  output tag_t                    rsp_tag,
  output logic [DFI_DATA_W-1:0]   rsp_data,
  output logic [1:0]              rsp_err,
  output logic                    rsp_wack,

  // ---- status --------------------------------------------------------------
  output logic [TQ_IDX_W:0]       outstanding,
  output logic                    stall_err       // host held rsp_ready too long
);

  // ---- request acceptance --------------------------------------------------
  // There is no back-pressure to apply: the host is only permitted to assert
  // req_valid while holding a credit, so a request that arrives is a request
  // the controller has already promised to take.  Accepting it unconditionally
  // is the contract; the accounting below is what keeps that promise honest.
  assign core_valid = req_valid;
  assign core_wr    = req_wr;
  assign core_blk   = req_blk;
  assign core_tag   = req_tag;
  assign core_qos   = req_qos;

  // ---- response skid buffer ------------------------------------------------
  // One entry deep.  rsp_ready going low must not lose a completion, and the
  // core cannot be stalled instantly, so exactly one beat of elasticity is
  // required -- and exactly one is enough, because cmpl_ready then back-
  // pressures the core in the following cycle.
  logic                  skid_v;
  tag_t                  skid_tag;
  logic [DFI_DATA_W-1:0] skid_data;
  logic [1:0]            skid_err;
  logic                  skid_wack;

  assign cmpl_ready = !skid_v || rsp_ready;

  assign rsp_valid = skid_v;
  assign rsp_tag   = skid_tag;
  assign rsp_data  = skid_data;
  assign rsp_err   = skid_err;
  assign rsp_wack  = skid_wack;

  // ---- credit return -------------------------------------------------------
  // One credit per completion that LEAVES the controller.  Returning on arrival
  // at the skid buffer instead would let the host refill while a beat is still
  // stuck behind back-pressure.
  logic rsp_fire;
  assign rsp_fire   = rsp_valid && rsp_ready;
  assign req_credit = rsp_fire;

  // ---- stall watchdog ------------------------------------------------------
  // Back-pressure here propagates all the way to the DRAM bus and idles it, so
  // a host that stalls responses is a bandwidth problem the integrator needs
  // told about (docs/03-interface-spec.md 1.6, rule H4).
  logic [15:0] stall_cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      skid_v    <= 1'b0;
      stall_cnt <= 16'd0;
      outstanding <= '0;
    end else begin
      // skid buffer
      if (cmpl_valid && cmpl_ready) begin
        skid_v    <= 1'b1;
        skid_tag  <= cmpl_tag;
        skid_data <= cmpl_data;
        skid_err  <= cmpl_err;
        skid_wack <= cmpl_wr;
      end else if (rsp_fire) begin
        skid_v <= 1'b0;
      end

      // outstanding accounting: +1 on accept, -1 on credit return
      // Saturating both ways.  A completion arriving with nothing outstanding
      // should be impossible -- the core only completes what it was given --
      // but an unguarded decrement UNDERFLOWS to all-ones, which then reads as
      // a hugely over-subscribed pool and wedges credit return permanently.
      // Cheap insurance against a fault upstream turning into a deadlock here.
      case ({req_valid, rsp_fire})
        2'b10: if (outstanding != (TQ_IDX_W+1)'(TQ_DEPTH))
                 outstanding <= outstanding + 1'b1;
        2'b01: if (outstanding != '0)
                 outstanding <= outstanding - 1'b1;
        default: ;                                  // both or neither: no change
      endcase

      // watchdog
      if (rsp_valid && !rsp_ready) stall_cnt <= stall_cnt + 16'd1;
      else                         stall_cnt <= 16'd0;
    end
  end

  assign stall_err = (stall_cnt == 16'hFFFF);

endmodule
