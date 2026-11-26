#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# mutate.sh -- mutation coverage for the formal property set.
#
# A proof that cannot fail proves nothing.  This injects known bugs into the
# RTL one at a time and requires the proof to FAIL on each.  Any mutation that
# survives is a hole in the property set, not a harmless change.
#
# This is a stand-in for YosysHQ's `mcy`, which is the tool the verification
# plan calls for.  mcy mutates automatically and at scale; this covers the
# specific defect classes we care about and runs in seconds, so it can gate
# every push.  Replace with mcy when it is available in the flow.
#
# Usage:  ./mutate.sh          run all mutations
#         ./mutate.sh -v       show the failing property for each
# ---------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"

# Serialise against any other build.  mutate.sh edits RTL in place and rebuilds
# into build/, so a concurrent `make` clobbers the mutated source and the
# mutation "survives" for a reason that says nothing about the property set --
# which is exactly what happened once, and cost a real debug cycle.
# Same lock name as the Makefile's `guarded` target, deliberately.  These were
# two DIFFERENT locks (.mutate.lock and .sby.lock), which meant they never
# excluded each other -- a mutation run and a regression could regenerate the
# same build/*.v simultaneously, which is the precise race both locks exist to
# prevent.  A lock that does not cover every writer is not a lock.
LOCK=.sby.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another build is running (or $LOCK is stale); refusing to start" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

VERBOSE=${1:-}
PASS=0; FAIL=0

# mutate <name> <target-file> <python-old> <python-new> <make-target> [expect]
#   expect = "survive" marks a KNOWN EQUIVALENT MUTATION: a change that does
#   not alter behaviour for the parameters being built, so no property can or
#   should catch it.  mcy calls these equivalent mutants.  They must be listed
#   explicitly with a justification -- an unexplained survivor is a hole.
mutate() {
  local name="$1" file="$2" old="$3" new="$4" target="$5" expect="${6:-catch}"
  cp "$file" "$file.bak"
  python3 - "$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old not in s:
    sys.stderr.write("MUTATION PATTERN NOT FOUND: %s\n" % old); sys.exit(2)
open(p, 'w').write(s.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  ERROR  $name -- pattern not found, mutation harness is stale"
    mv "$file.bak" "$file"; FAIL=$((FAIL+1)); return
  fi

  local out
  out=$(make "$target" 2>&1)
  mv "$file.bak" "$file"

  # A mutation is caught if the result changes from the clean PASS to anything
  # else.  UNKNOWN counts: "this property is no longer provable" is a detection,
  # even though no counterexample was produced within the depth budget.
  local caught="no"
  echo "$out" | grep -qE "DONE \((FAIL|UNKNOWN)" && caught="yes"

  if [ "$expect" = "survive" ]; then
    if [ "$caught" = "no" ]; then
      echo "  equivalent  $name  (expected: no behavioural change)"
      PASS=$((PASS+1))
    else
      echo "  UNEXPECTED-CATCH $name  <-- it was NOT equivalent; re-check the claim"
      FAIL=$((FAIL+1))
    fi
  elif [ "$caught" = "yes" ]; then
    echo "  caught      $name"
    [ -n "$VERBOSE" ] && echo "$out" | grep -m1 'Assert failed' | sed 's/^/              /'
    PASS=$((PASS+1))
  else
    echo "  SURVIVED    $name   <-- property set has a hole here"
    FAIL=$((FAIL+1))
  fi
}

echo "=== mutation coverage ==="

# --- divider ---------------------------------------------------------------
mutate "divc: wrong reciprocal constant" ../rtl/fe/hbm4_divc.sv \
  "((longint'(1) << S) / longint'(D)) + 1" \
  "((longint'(1) << S) / longint'(D)) + 2" divc

# EQUIVALENT: the reciprocal constant was chosen so that no correction is ever
# required for the shipped parameters -- verified exhaustively in Python over
# both (W=20,D=30) and (W=21,D=15), and now independently by formal, since
# removing the step changes nothing.  The step is retained as insurance for
# anyone who re-parameterises the divider; for the current build it is
# provably dead logic.
# RETIRED in Rev 1.0: "divc: drop the correction step".
#
# Its target, `if (r_wide >= (W+1)'(D))`, is now a literal `if (1'b0)` -- the
# reciprocal is exact over the proved parameter range, so the correction never
# runs.  Mutating dead code is an EQUIVALENT MUTANT: it cannot be caught,
# because it changes nothing observable.  Carrying it produced a permanent
# "pattern not found" error that reads like harness rot and trains you to ignore
# the one signal that catches real rot.
#
# The load-bearing part of the same logic is already covered by
# "divc: off-by-one shift" immediately below.

mutate "divc: off-by-one shift" ../rtl/fe/hbm4_divc.sv \
  "assign q_approx = QW'(s1_prod >> S);" \
  "assign q_approx = QW'(s1_prod >> (S-1));" divc

# --- address map -----------------------------------------------------------
mutate "slice: PC field off by one bit" ../rtl/fabric/hbm4_addr_slice.sv \
  "assign pc_base    = sys_addr[OFFSET_W + STACK_W +: PC_W];" \
  "assign pc_base    = sys_addr[OFFSET_W + STACK_W + 1 +: PC_W];" addrmap

mutate "hash: OR instead of XOR fold" ../rtl/fabric/hbm4_hash.sv \
  "assign hashed[i] = base[i] ^ (^(addr & mask[i]));" \
  "assign hashed[i] = base[i] | (^(addr & mask[i]));" addrmap

mutate "decode: out-of-range detection removed" ../rtl/fe/hbm4_addr_decode.sv \
  "assign div_oor = (q >= QW'(N_ROW));" \
  "assign div_oor = 1'b0;" addrmap

mutate "decode: bank groups swapped" ../rtl/pkg/hbm4_pkg.sv \
  "return bank_t'({ba, bg});" \
  "return bank_t'({bg, ba});" addrmap

# The bank group must occupy the LOW bits of the bank index, because the timing
# engine derives it with bg_of() to enforce tCCD_L.  Breaking that round trip
# applies timing to the wrong bank group with no functional symptom.
mutate "pkg: bg_of reads the wrong field" ../rtl/pkg/hbm4_pkg.sv \
  "return bg_t'(b[BG_W-1:0]);" \
  "return bg_t'(b[BANK_W-1:BANK_W-BG_W]);" addrmap

# --- timing engine ---------------------------------------------------------
# The load-value off-by-one.  This violates NO timing parameter -- it is
# strictly more conservative -- so every P-TIM assertion still passes.  It is
# caught only by the c_back_to_back_col COVER, because it makes a saturated
# column bus unreachable.  That is a 50%-bandwidth bug that a timing checker,
# a scoreboard, and a directed test would all report as fully correct.
mutate "timing: load N instead of N-1 (halves column throughput)" \
  ../rtl/core/hbm4_timing_engine.sv \
  "return (v == '0) ? '0 : tmr_t'(v - 1'b1);" \
  "return v;" timing

mutate "timing: tCCD_L not tracked" ../rtl/core/hbm4_timing_engine.sv \
  "n_ccdl[g] = tick(t_ccdl[g], do_col && (bg_t'(g) == col_bg), ld(tcfg.t_ccd_l));" \
  "n_ccdl[g] = '0;" timing

mutate "timing: tRCD not applied on ACT" ../rtl/core/hbm4_timing_engine.sv \
  "n_col[b] = tick(t_col[b], hit && do_act, ld(tcfg.t_rcd));" \
  "n_col[b] = '0;" timing

mutate "timing: tFAW window disabled" ../rtl/core/hbm4_timing_engine.sv \
  "n_faw[i] = tick(t_faw[i], do_act && faw_pick[i], ld(tcfg.t_faw));" \
  "n_faw[i] = '0;" timing

mutate "timing: tRAS not applied (PRE too early)" ../rtl/core/hbm4_timing_engine.sv \
  "(hit && do_act) ? ld(tcfg.t_ras) :" \
  "(hit && do_act) ? tmr_t'(0) :" timing

# --- column arbiter --------------------------------------------------------
mutate "colarb: pointer does not advance (breaks round-robin)" \
  ../rtl/core/hbm4_col_arb.sv \
  "ptr <= (grant_bank == bank_t'(N_BANK-1)) ? '0 : PW'(grant_bank + 1'b1);" \
  "ptr <= ptr;" colarb

mutate "colarb: urgent tier ignored" ../rtl/core/hbm4_col_arb.sv \
  "assign sel = (|t0) ? t0 : cand;" \
  "assign sel = cand;" colarb

mutate "colarb: grants a bank the timing engine did not clear" \
  ../rtl/core/hbm4_col_arb.sv \
  "assign cand = (dir == DIR_READ) ? (rd_ok & pend_rd) : (wr_ok & pend_wr);" \
  "assign cand = (dir == DIR_READ) ? pend_rd : pend_wr;" colarb

# --- write buffer ----------------------------------------------------------
# Trust the cheap tier-1 hash and skip the exact compare.  Every hash collision
# then becomes a reported hazard on a block that is NOT pending -- a false
# positive.  Harmless for correctness in isolation, but it also makes
# rd_forward return ANOTHER block's data, which is silent corruption.
mutate "wbuf: tier-2 exact compare skipped (hash collisions accepted)" \
  ../rtl/fe/hbm4_wbuf.sv \
  "rd_t2[i] = rd_t1[i] && (ent_tag[i] == rd_tag);" \
  "rd_t2[i] = rd_t1[i];" wbuf

mutate "wbuf: tier-1 filter drops real matches" ../rtl/fe/hbm4_wbuf.sv \
  "rd_t1[i] = ent_valid[i] && (ent_hash[i] == rd_hash);" \
  "rd_t1[i] = ent_valid[i] && (ent_hash[i] == rd_hash) && (i != 0);" wbuf

mutate "wbuf: forwards a partially written block" ../rtl/fe/hbm4_wbuf.sv \
  "assign rd_forward = rd_hazard && (&ent_be[haz_idx]);" \
  "assign rd_forward = rd_hazard;" wbuf

mutate "wbuf: coalescing disabled (duplicate entries)" ../rtl/fe/hbm4_wbuf.sv \
  "wr_t2[i] = wr_t1[i] && (ent_tag[i] == wr_tag);" \
  "wr_t2[i] = 1'b0;" wbuf

# --- write-data storage (Rev 1.3; indexed by pool entry since Rev 1.4) -----
# On the write datapath. Corruption here writes the wrong bytes to a correct
# address, with no error anywhere.

mutate "wdata: read returns the wrong entry" \
  ../rtl/fe/hbm4_wdata_ram.sv \
  "assign rd_data     = mem[rd_idx];" \
  "assign rd_data     = mem[0];" wdataram

mutate "wdata: written-flag never set (every write reports no data)" \
  ../rtl/fe/hbm4_wdata_ram.sv \
  "written[wr_idx] <= 1'b1;" \
  "written[wr_idx] <= 1'b0;" wdataram

mutate "wdata: issuing without data is not reported" \
  ../rtl/fe/hbm4_wdata_ram.sv \
  "assign err_no_data = rd_valid && !written[rd_idx];" \
  "assign err_no_data = 1'b0;" wdataram

mutate "wdata: stale flag survives issue, so a reused entry inherits old data" \
  ../rtl/fe/hbm4_wdata_ram.sv \
  "if (rd_valid && !(wr_valid && (wr_idx == rd_idx)))" \
  "if (1'b0)" wdataram

# The pool's exported indices (Rev 1.4) are what the write data is stored and
# fetched by. One that names the wrong entry hands a write another write's
# bytes -- the Rev 1.3 tag-aliasing failure, by a different route.
mutate "pool: issue_idx names the list tail, not the entry popped" \
  ../rtl/core/hbm4_txn_pool.sv \
  "assign issue_idx  = pop_idx;" \
  "assign issue_idx  = l_tail[il];" pool

mutate "pool: alloc_idx ignores the free-entry search" \
  ../rtl/core/hbm4_txn_pool.sv \
  "assign alloc_idx   = free_idx;" \
  "assign alloc_idx   = '0;" pool

# --- refresh engine --------------------------------------------------------
# Reproduces a REAL bug this proof found: selecting the hammered bank before
# checking whether it is free lets a blocked bank mask every other hammered
# bank, so RFM never fires and row-hammer mitigation silently stops.
mutate "refresh: RFM bank selected without checking it is free" \
  ../rtl/core/hbm4_refresh.sv \
  "if ((raa[b] >= cfg_rfm_thresh) && !refresh_block[b]) begin" \
  "if (raa[b] >= cfg_rfm_thresh) begin" refresh

mutate "refresh: debt allowed past the JEDEC postpone limit" \
  ../rtl/core/hbm4_refresh.sv \
  "if (ref_debt < DEBT_MAX) ref_debt <= ref_debt + 6'sd1;" \
  "ref_debt <= ref_debt + 6'sd1;" refresh

# --- the Rev 0.9 refresh legality split ------------------------------------
# These three cover the bug simulation found (REF to an open bank) and the
# starvation bug that the obvious fix would have introduced in its place.  Both
# halves need a mutation: a fix that only prevents the illegal command, and one
# that only forces the precharge, are each individually wrong.

mutate "refresh: REF issued without checking the bank is closed" \
  ../rtl/core/hbm4_refresh.sv \
  "assign ref_req = ref_due && bank_idle[ref_ptr];" \
  "assign ref_req = ref_due;" refresh

mutate "refresh: RFM issued without checking the bank is closed" \
  ../rtl/core/hbm4_refresh.sv \
  "assign rfm_req     = rfm_req_raw && bank_idle[raa_bank];" \
  "assign rfm_req     = rfm_req_raw;" refresh

mutate "refresh: no forced precharge, so refresh silently starves" \
  ../rtl/core/hbm4_refresh.sv \
  'if (ref_due && !bank_idle[ref_ptr]) ref_want_pre[ref_ptr] = 1'"'"'b1;' \
  'if (ref_due && bank_idle[ref_ptr]) ref_want_pre[ref_ptr] = 1'"'"'b1;' refresh

mutate "refresh: refresh issued to a bank already refreshing" \
  ../rtl/core/hbm4_refresh.sv \
  "&& !refresh_block[ref_ptr]" \
  "&& 1'b1" refresh

mutate "refresh: RFM disabled entirely" ../rtl/core/hbm4_refresh.sv \
  "assign rfm_req_raw = cfg_rfm_en && raa_hit;" \
  "assign rfm_req_raw = 1'b0;" refresh

# --- row arbiter -----------------------------------------------------------
mutate "rowarb: ACT issued without timing-engine clearance (breaks A2)" \
  ../rtl/core/hbm4_row_arb.sv \
  "assign act_cand = act_ok & want_act;" \
  "assign act_cand = want_act;" rowarb

mutate "rowarb: urgent refresh no longer wins the bus" ../rtl/core/hbm4_row_arb.sv \
  "if (ref_req && (ref_urgent || (!act_valid && !pre_valid))) begin" \
  "if (ref_req && (!act_valid && !pre_valid)) begin" rowarb

mutate "rowarb: ACT opens the wrong row" ../rtl/core/hbm4_row_arb.sv \
  "row: want_row[act_bank]};" \
  "row: want_row[0]};" rowarb

mutate "timing: tRFC not applied on refresh" ../rtl/core/hbm4_timing_engine.sv \
  "(do_ref) ? ld(tcfg.t_rfc_sb) : ld(tcfg.t_rfm);" \
  "(do_ref) ? tmr_t'(0) : ld(tcfg.t_rfm);" timing

# --- auto-precharge (the Rev 0.6d bug class) -------------------------------
# RDA/WRA close the bank internally with NO row command, so nothing on the row
# bus records the precharge.  Untracked, the next ACT is legal immediately and
# tRP is violated on EVERY access under PAGE_POLICY = CLOSE.
mutate "timing: auto-precharge not tracked at all" \
  ../rtl/core/hbm4_timing_engine.sv \
  "n_act[b]  = (aphit && (ap_val > n_act_row)) ? ap_val : n_act_row;" \
  "n_act[b]  = n_act_row;" timing

# Combining row-bus and column-bus constraints as a PRIORITY CHAIN instead of a
# MAX silently drops the binding one when both hit the same bank in one cycle.
mutate "timing: row/auto-precharge combined by priority, not max" \
  ../rtl/core/hbm4_timing_engine.sv \
  "n_act[b]  = (aphit && (ap_val > n_act_row)) ? ap_val : n_act_row;" \
  "n_act[b]  = aphit ? tick(t_act[b], 1'b1, ap_val) : n_act_row;" timing

# NOTE: targets `bankst`, not `timing`.  An earlier version pointed this at the
# timing proof, which does not compile hbm4_bank_state at all -- so the mutation
# had no effect and "survived" for a reason that said nothing about the
# property set.  A mutation aimed at a proof that cannot see it is a broken
# test, not a finding.
mutate "bankstate: auto-precharge leaves the bank marked ACTIVE" \
  ../rtl/core/hbm4_bank_state.sv \
  "&& ((col_iss.cmd == COL_RDA) || (col_iss.cmd == COL_WRA)))" \
  "&& 1'b0)" bankst

mutate "bankstate: row and column buses chained, so one is dropped" \
  ../rtl/core/hbm4_bank_state.sv \
  "        if (row_iss.valid) begin" \
  "        if (row_iss.valid && !col_iss.valid) begin" bankst

# --- NHI target ------------------------------------------------------------
mutate "nhi: credit returned on arrival, not on the response leaving" \
  ../rtl/fe/hbm4_nhi_target.sv \
  "assign req_credit = rsp_fire;" \
  "assign req_credit = cmpl_valid && cmpl_ready;" nhi

mutate "nhi: skid buffer overwritten while back-pressured" \
  ../rtl/fe/hbm4_nhi_target.sv \
  "assign cmpl_ready = !skid_v || rsp_ready;" \
  "assign cmpl_ready = 1'b1;" nhi

mutate "nhi: outstanding not decremented on credit return" \
  ../rtl/fe/hbm4_nhi_target.sv \
  "        2'b01: if (outstanding != '0)" \
  "        2'b01: if (1'b0)" nhi

# --- read-pointer FIFO -----------------------------------------------------
# This FIFO decides which transaction each returning read belongs to.  Get it
# wrong and one requester receives another's data -- valid, correct ECC, wrong
# owner.  Nothing downstream detects that.
mutate "rdfifo: read pointer does not advance (all reads get entry 0)" \
  ../rtl/dfi/hbm4_rd_ptr_fifo.sv \
  "        rptr <= (rptr == AW'(DEPTH-1)) ? '0 : AW'(rptr + 1'b1);" \
  "        rptr <= rptr;" rdfifo

mutate "rdfifo: push accepted when full (overwrites in-flight entry)" \
  ../rtl/dfi/hbm4_rd_ptr_fifo.sv \
  "      if (push && !full) begin" \
  "      if (push) begin" rdfifo

mutate "rdfifo: pop when empty advances past valid entries" \
  ../rtl/dfi/hbm4_rd_ptr_fifo.sv \
  "      if (pop && !empty)" \
  "      if (pop)" rdfifo

# --- ECC column cache ------------------------------------------------------
# Three real bugs, all found by P-EC-2.  Losing one dirty ECC block costs the
# check bits for 15 data blocks, and the symptom is an uncorrectable-error
# storm on data that was never damaged.
mutate "ecccache: same-tag fill onto a dirty entry is applied (loses updates)" \
  ../rtl/ras/hbm4_ecc_cache.sv \
  "  assign fill_redundant = fill_valid && ent_valid[fill_bank]" \
  "  assign fill_redundant = 1'b0 && fill_valid && ent_valid[fill_bank]" ecccache

mutate "ecccache: upd_stall ignores which eviction was acknowledged" \
  ../rtl/ras/hbm4_ecc_cache.sv \
  "assign upd_stall  = upd_conflict && !(evict_ack && !fill_conflict);" \
  "assign upd_stall  = upd_conflict && !evict_ack;" ecccache

mutate "ecccache: update reuses a dirty slot without eviction" \
  ../rtl/ras/hbm4_ecc_cache.sv \
  "      if (upd_valid && !upd_stall) begin" \
  "      if (upd_valid) begin" ecccache

mutate "ecccache: conflicting fill applied without the write-back" \
  ../rtl/ras/hbm4_ecc_cache.sv \
  "                   && (!fill_conflict || evict_ack);" \
  "                   && 1'b1;" ecccache

mutate "ecccache: elision claimed without every field known" \
  ../rtl/ras/hbm4_ecc_cache.sv \
  "assign evict_generate = fill_conflict ? (&ent_fv[fill_bank]) : (&ent_fv[upd_bank]);" \
  "assign evict_generate = 1'b1;" ecccache

# --- error log -------------------------------------------------------------
# The first-error latch is the only record of a fault's ORIGIN.  A storm fills
# the FIFO with consequences; if the latch can be displaced, post-mortem debug
# is left with symptoms and no cause, on hardware already returned.
mutate "errlog: first-error latch can be overwritten" \
  ../rtl/ras/hbm4_err_log.sv \
  "end else if (err_valid && !first_valid) begin" \
  "end else if (err_valid) begin" errlog

mutate "errlog: FIFO evicts oldest instead of dropping newest" \
  ../rtl/ras/hbm4_err_log.sv \
  "assign push     = err_valid && !full;" \
  "assign push     = err_valid;" errlog

mutate "errlog: an overflowing error cannot become the first error" \
  ../rtl/ras/hbm4_err_log.sv \
  "end else if (err_valid && !first_valid) begin" \
  "end else if (push && !first_valid) begin" errlog

# --- link ECC --------------------------------------------------------------
# Unbounded retry on a hard fault is a livelock; silently passing a flagged
# read is corruption.  Both must be impossible.
mutate "linkecc: retry is unbounded (livelock on a hard fault)" \
  ../rtl/ras/hbm4_link_ecc.sv \
  "assign retry_exhausted = (retries >= RW'(RETRY_MAX));" \
  "assign retry_exhausted = 1'b0;" linkecc

mutate "linkecc: uncorrectable reported as success" \
  ../rtl/ras/hbm4_link_ecc.sv \
  "    if (ue || pois)  out_err = 2'd2;" \
  "    if (1'b0)  out_err = 2'd2;" linkecc

mutate "linkecc: raw payload passed on instead of the corrected data" \
  ../rtl/ras/hbm4_link_ecc.sv \
  "assign out_data  = fixed;" \
  "assign out_data  = rx_data;" linkecc

mutate "linkecc: a corrected read is retried anyway (wastes the budget)" \
  ../rtl/ras/hbm4_link_ecc.sv \
  "assign retry_req = rx_valid && ue && cfg_retry_en && !retry_exhausted;" \
  "assign retry_req = rx_valid && (ue || ce) && cfg_retry_en && !retry_exhausted;" linkecc

# --- patrol scrub ----------------------------------------------------------
# A walk that skips blocks leaves exactly the regions scrub exists to protect
# unprotected -- and silently, because a skipped block looks like a clean one.
mutate "scrub: walk skips two columns per step (incomplete coverage)" \
  ../rtl/ras/hbm4_scrub.sv \
  "          w_col <= w_col + 1'b1;" \
  "          w_col <= w_col + 2'd2;" scrub

mutate "scrub: displaces real traffic" ../rtl/ras/hbm4_scrub.sv \
  "assign scrub_req = cfg_en && tick && !host_pending;" \
  "assign scrub_req = cfg_en && tick;" scrub

mutate "scrub: walks ECC columns as if they were data" ../rtl/ras/hbm4_scrub.sv \
  "assign col_last  = (w_col  == col_t'(N_COL_DATA - 1));" \
  "assign col_last  = (w_col  == col_t'(N_COL_RAW - 1));" scrub

mutate "scrub: position drifts without an accepted scrub" ../rtl/ras/hbm4_scrub.sv \
  "      if (scrub_req && scrub_ack) begin" \
  "      if (scrub_req || scrub_ack) begin" scrub

# --- ECC region init -------------------------------------------------------
# `done` released early leaves part of the ECC region uninitialised, and the
# first read of any of it reports an UNCORRECTABLE ERROR on healthy memory --
# a fault that looks like failing silicon and gets chased as such.
mutate "eccinit: done asserted before the sweep completes" \
  ../rtl/ras/hbm4_ecc_init.sv \
  "        if (at_end) begin" \
  "        if (col_last) begin" eccinit

mutate "eccinit: walk skips columns" ../rtl/ras/hbm4_ecc_init.sv \
  "          w_col <= w_col + 1'b1;" \
  "          w_col <= w_col + 2'd2;" eccinit

mutate "eccinit: writes ECC columns as data" ../rtl/ras/hbm4_ecc_init.sv \
  "assign col_last  = (w_col  == col_t'(N_COL_DATA - 1));" \
  "assign col_last  = (w_col  == col_t'(N_COL_RAW - 1));" eccinit

# --- CSR lock --------------------------------------------------------------
# The lock is what makes silent address-map corruption impossible rather than
# merely unlikely.  Changing the map under live traffic relocates where
# addresses land, with no ECC error and no symptom except wrong data.
mutate "csr: locked registers still writable" ../rtl/global/hbm4_csr.sv \
  "assign refused = wr_access && cfg_locked && addr_is_locked_group;" \
  "assign refused = 1'b0;" csr

mutate "csr: lock can be cleared by the bus" ../rtl/global/hbm4_csr.sv \
  "A_LOCK:    if (pwdata[0]) cfg_locked <= 1'b1;" \
  "A_LOCK:    cfg_locked <= pwdata[0];" csr

mutate "csr: refused write is silent (no bus error)" ../rtl/global/hbm4_csr.sv \
  "assign pslverr           = refused;" \
  "assign pslverr           = 1'b0;" csr

mutate "csr: timing registers left outside the lock" ../rtl/global/hbm4_csr.sv \
  "                        || ((paddr >= 16'h0200) && (paddr < 16'h0300));  // timing" \
  "                        || 1'b0;" csr

# --- power manager ---------------------------------------------------------
# Entering self-refresh with work in flight is a HANG: the DRAM leaves the
# command bus and the read never completes.  No error, no log, no timeout.
# The busy gating lives in the activity branch, which is the load-bearing one.
mutate "pmgr: descends while transactions are outstanding" \
  ../rtl/global/hbm4_pmgr.sv \
  "      if (busy || req_pending) begin" \
  "      if (1'b0) begin" pmgr

mutate "pmgr: skips straight to self-refresh" ../rtl/global/hbm4_pmgr.sv \
  "          S_ACTIVE:  if (idle_cnt >= 16'd4)            st <= S_CLKGATE;" \
  "          S_ACTIVE:  if (idle_cnt >= 16'd4)            st <= S_SR;" pmgr

mutate "pmgr: low power ignores its enable" ../rtl/global/hbm4_pmgr.sv \
  "      end else if (may_descend) begin" \
  "      end else if (!busy && !req_pending) begin" pmgr

# --- init sequencer --------------------------------------------------------
# Two disasters: driving the DRAM while the scheduler is live (two drivers on an
# unarbitrated bus), and an untrusted script hanging boot with nothing logged.
mutate "initseq: drives the DRAM while the scheduler is live" \
  ../rtl/global/hbm4_init_seq.sv \
  "is_dram_op && slices_quiesced" \
  "is_dram_op" initseq

mutate "initseq: watchdog disabled (untrusted script can hang boot)" \
  ../rtl/global/hbm4_init_seq.sv \
  "      if (wdog >= WDOG_LIMIT) begin" \
  "      if (1'b0) begin" initseq

# Multi-line patterns need $'...' so bash expands \n to a real newline; in a
# plain "..." string it stays a literal backslash-n and never matches.  The
# harness reports that as ERROR rather than SURVIVED, which is the distinction
# that made it visible instead of looking like a property hole.
mutate "initseq: watchdog stops without reporting an error" \
  ../rtl/global/hbm4_init_seq.sv \
  $'        busy  <= 1\'b0;\n        error <= 1\'b1;\n        done  <= 1\'b0;' \
  $'        busy  <= 1\'b0;\n        error <= 1\'b0;\n        done  <= 1\'b0;' initseq

mutate "initseq: branch outside the script is taken" \
  ../rtl/global/hbm4_init_seq.sv \
  "              if (arg < 24'(SCRIPT_DEPTH)) pc <= PCW'(arg);" \
  "              if (1'b1) pc <= PCW'(arg);" initseq

# The script-overrun bug this found: without the end check the PC advances past
# the last instruction and executes whatever the RAM returns out of range.
mutate "initseq: runs off the end of the script" \
  ../rtl/global/hbm4_init_seq.sv \
  "assign pc_at_end = (32'(pc) == 32'(SCRIPT_DEPTH) - 32'd1);" \
  "assign pc_at_end = 1'b0;" initseq

echo "=== caught $PASS, survived $FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
