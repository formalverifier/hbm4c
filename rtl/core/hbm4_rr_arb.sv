// ---------------------------------------------------------------------------
// hbm4_rr_arb -- rotating-priority (round-robin) arbiter, one-hot grant.
//
// Combinational, ~2 levels of logic beyond the mask: rotate the request vector
// so `ptr` sits at bit 0, isolate the lowest set bit, rotate back.  The
// isolate step is x & -x, which synthesises to a borrow chain.
//
// This is what bounds starvation: a ready requester is passed over at most
// N-1 times before the pointer reaches it.  That bound is asserted formally
// (P-LIVE-1), because livelock in a streaming scheduler is exactly the bug
// class that survives simulation.
// ---------------------------------------------------------------------------
module hbm4_rr_arb #(
  parameter int unsigned N = 32,
  localparam int unsigned PW = (N > 1) ? $clog2(N) : 1
) (
  input  logic [N-1:0]  req,
  input  logic [PW-1:0] ptr,      // highest priority index
  output logic [N-1:0]  grant,    // one-hot, zero if req == 0
  output logic          valid
);

  // `shifted` is deliberately 2N wide: only the low N bits are the rotation
  // result, the high bits are the discarded part of the double vector.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2*N-1:0] shifted;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2*N-1:0] dbl, back;
  logic [N-1:0]   rot, low;

  assign dbl     = {req, req};
  assign shifted = dbl >> ptr;          // bits [N-1:0] are req rotated right by ptr
  assign rot     = shifted[N-1:0];
  assign low     = rot & (~rot + {{(N-1){1'b0}}, 1'b1});
  assign back    = {{N{1'b0}}, low} << ptr;
  assign grant   = back[N-1:0] | back[2*N-1:N];
  assign valid   = |req;

`ifdef FORMAL
  always_comb begin
    // A grant is always one of the requesters, and never more than one.
    a_grant_subset:  assert ((grant & ~req) == '0);
    a_grant_onehot:  assert ($countones(grant) <= 1);
    a_grant_iff_req: assert (valid == (|grant));
  end
`endif

endmodule
