# Formal Assumption Audit

**Rev 1.0** · reviewed at each signoff (verification plan criterion S4)

Every `assume` is a hole in a proof. A proof over an environment that cannot happen proves
nothing, so each one is listed here with a justification and the place it is discharged.

**The rule:** an `assume` in one proof must be an `assert` somewhere else — in another
proof, or as a checker in the simulation environment. An assumption that is only ever
assumed is a wish.

---

## A1 — Reset is asserted at power-on and not re-asserted mid-operation

**Where:** `fv_divc`, `fv_addr_slice_miter`, `fv_timing_engine`, `fv_col_arb`

```systemverilog
always @(*)         if (!f_past_valid) assume (!rst_n);
always @(posedge clk) if (f_past_valid) assume (rst_n);
```

**Why it is needed.** Without it the solver deasserts `rst_n` mid-pipeline, leaving
`out_valid` high over stale pipeline registers. That state is reachable only via a
system-level reset fault while transactions are in flight.

**Why it is legitimate.** The controller does not claim to ride through a reset glitch. A
mid-operation reset requires the full boot sequence
([04-programming-guide.md §2](../docs/04-programming-guide.md)); nothing is expected to
survive it.

**Discharged in Rev 1.0 — and discharged more strongly than this criterion asked for.**

The original plan was a checker asserting `rst_n` never falls while a transaction is
outstanding: that would have *policed* the assumption, not removed it. What
`sim/test_slice.py::test_reset_mid_operation` does instead is assert reset precisely when the
assumption forbids it — with transactions queued, a row open and a read in flight — and check
that no state survives, that nothing is driven while `rst_n` is low, and that the slice
recovers and resumes issuing.

The assumption is therefore no longer needed in the form stated above. Doing it this way found
two real defects a policing checker could not have: the boot script had no `PRECHARGE ALL`
(so the controller and device disagreed about open rows after a reset), and the DFI command
strobes had no reset term.

**Residual:** one slice at a time. Reset behaviour of the assembled 256-slice system is
untested, as is everything else at that level.

---

## A2 — The arbiters only issue what the ready vectors permit

**Where:** `fv_timing_engine`

```systemverilog
if (do_act) assume (act_ok[rb]);
if (do_rd)  assume (rd_ok[cb]);
...
```

**Why it is needed.** `hbm4_timing_engine` contains no arbiter. It computes readiness; it
cannot prevent a caller from ignoring it. The proof it supports is conditional by
construction: *if* the arbiters obey the ready vectors, *then* no JEDEC parameter is ever
violated.

**Discharged by:** `fv_col_arb` `p_only_ready` (column bus) and `fv_row_arb`
`p_act_legal` / `p_pre_legal` (row bus). **Status: FULLY DISCHARGED (Rev 0.6c). Both prove
unbounded.**

---

## A3 — Requests are persistent

**Where:** `fv_col_arb`

```systemverilog
if ($past(cand[f_bank]) && !$past(grant[f_bank])) assume (cand[f_bank]);
```

**Why it is needed.** With `cand` free every cycle the solver withdraws a bank's candidacy
whenever the rotating pointer is about to reach it and re-adds it afterwards. That
counterexample says nothing about the arbiter — it says the environment was
under-constrained.

**Why it is legitimate.** A candidate is the head of a per-bank list in the transaction
pool. A queued transaction does not evaporate; it leaves only by being issued.

**Discharged by:** `fv_txn_pool` `p_rd_persistent` / `p_wr_persistent` — a bank stays
pending until an issue from that bank's list. **Status: DISCHARGED (Rev 0.5), BMC-bounded.**

---

## A4 — Only ACT/PRE and RD/WR are exercised

**Where:** `fv_timing_engine`

```systemverilog
assume (row_iss.valid -> (row_iss.cmd inside {ROW_ACT, ROW_PRE}));
assume (col_iss.valid -> (col_iss.cmd inside {COL_RD, COL_WR}));
```

**Why.** Refresh, RFM and auto-precharge variants are modelled in the timing engine but are
not yet covered by properties. This assumption makes the current proof honest about its
scope rather than silently ignoring those paths.

**Status: CLOSED (Rev 0.6d).** Every command the scheduler can issue is now in scope for
`fv_timing_engine` — `ROW_ACT`, `ROW_PRE`, `ROW_REF_SB`, `ROW_RFM`, `COL_RD`, `COL_WR`,
`COL_RDA`, `COL_WRA` — with P-TIM-14 (tRFC), P-TIM-15 (tRFM) and P-TIM-16/17
(auto-precharge) proved, and covers confirming each path is exercised rather than vacuous.

**A4 no longer exists as an assumption.** Closing it found a real bug — see OPEN-2 below.

---

## ~~A5, A6~~ — REMOVED in Rev 0.6, not discharged: deleted

Earlier drafts assumed the row arbiter always grants an urgent refresh (A5) and grants RFM
promptly (A6). Both existed only to support a bound on RAA that was replaced by
`p_rfm_always_requested`, which needs no grant assumption at all.

Removing them makes `fv_refresh` **strictly stronger**: the arbiter is now entirely
unconstrained, so the refresh engine is proved correct even against one that never
acknowledges anything.

It also had a concrete verification payoff. With A5 in place, deleting the JEDEC
`ref_debt < DEBT_MAX` saturation guard **survived mutation testing** — debt could never
climb far enough for the guard to matter. Without A5 the guard is reachable and the mutation
is caught.

**Two assumptions that were load-bearing for nothing.** Worth re-checking periodically
whether an assume is still earning its place, rather than only ever adding them.

---

## A7 — No activate to a bank that is refreshing

**Where:** `fv_refresh`.

**Discharged by (Rev 0.6c):** `fv_timing_engine` **P-TIM-14** proves that an ACT never
follows a REFsb to the same bank within tRFC — and critically, that is enforced by the
timing engine's own `t_act` counter, **independently of the `refresh_block` vector**.

That independence is the point. `refresh_block` is redundant protection, not the mechanism,
so A7 does not rest on the two modules agreeing about a shared signal. `fv_row_arb`
`p_act_legal` closes the loop by proving the arbiter only issues cleared ACTs.
**Status: DISCHARGED.**

---

## Open items

### ~~OPEN-1~~ — CLOSED in Rev 0.5

The fairness bound is proved: `fv_col_arb` `p_bounded_starvation`, `starve < N_BANK`,
unbounded via k-induction.

**The fix was to delete logic, not to add it.** The bank-group bias tier was redundant with
the timing engine — `t_ccdl` already prevents a same-bank-group candidate from being marked
ready, so every candidate the arbiter could see was already legal. Removing it restored the
plain round-robin argument (rotational distance strictly decreases on every grant), deleted
the `last_bg` register, and dropped one priority encoder from the critical path.

Trying to *prove* a claimed property is what exposed the redundancy. The original text of
this item is kept below because the reasoning is the point.

<details><summary>Original OPEN-1 (Rev 0.4)</summary>

### OPEN-12 — Write-data integrity is bounded, not proved

`fv_wdata_ram` proves three properties unbounded — the written-flag mirrors the shadow, a write
issued with no data is reported, and no false alarm is raised. Those depend only on the
written-vector, which the DUT exports as `dbg_written`.

**`p_data_integrity` is BMC-only.** It needs *"for every entry, the array holds what was written
there"*, and the array is observable only through the addressed read port. Stating it for the
read tag alone leaves the induction step free to begin from a state where some other entry
already disagrees — which is exactly the shape that defeated OPEN-6 on the read FIFO.

Two things were tried before settling: a single symbolic entry (fails, same reason as OPEN-6),
and a full shadow of every entry at a narrow width (the width is now a parameter, which is a
genuine improvement — but the shadow still cannot be compared against an unobservable array).

Closing it would need a `TQ_DEPTH:1` mux of 256 bits exported for observation. **That is real
silicon area for a proof, on a block this small, and it was judged not worth it** — the same
call as the reverted debug port in OPEN-6, made deliberately this time rather than after the
fact. BMC to depth 16 covers write, read-back, tag reuse and the no-data path several times
over at `TQ_DEPTH = 4`.

Matching mutations exist for all four properties.

### OPEN-11 — QoS aging does not exist, and the fairness proof looks past its absence

**Severity: denial of service, reachable by any requester that can set `req_qos`.**

Three documents specify QoS aging: [docs/02 §622](../docs/02-architecture.md) ("effective QoS
+1 every `AGE_TICK` (512) clocks, capped at 3"), [docs/04](../docs/04-programming-guide.md)
(an `AGE_TICK` CSR at `+0x10`, default 512, range 32–8192), and
[docs/07](../docs/07-performance-guide.md) ("Lower `AGE_TICK` so bulk traffic escalates
faster"). `hbm4_col_arb.sv:68` and `fv_col_arb.sv:60-70` both discharge urgent-tier starvation
to it.

`grep -rniE "age_tick|aging|promote" rtl/` returns **only those two comments**. There is no
counter, no timer, and no such CSR — `hbm4_csr.sv` decodes `A_SCHED0` at `0x0500` for four
words and nothing at `0x0010`. `hbm4_nhi_target.sv:71` assigns `core_qos = req_qos` with no
policing; `hbm4_txn_pool.sv` stores it and never changes it. **An entry's QoS is fixed for its
entire life.**

#### The scenario

Production geometry, one pseudo-channel. One `QoS=0` read to bank 5 becomes a candidate and
stays one (A3 persistence — it leaves the list only by issuing). The attacker keeps ~2 reads
outstanding to banks 0 and 1, which are in *different bank groups*, so alternating between them
sustains one legal urgent candidate every cycle. Pool occupancy stays far below `wr_hi`, so the
direction FSM never leaves READ. Every cycle `sel = cand & pend_urgent`, which excludes bank 5.
**It is never granted, its credit is never returned, and the host waits indefinitely with no
error reported anywhere.**

Cost to the attacker: two outstanding requests with `req_qos = 3`.

[docs/07](../docs/07-performance-guide.md) lists "Adversarial: all-urgent flood → bulk traffic
still progresses (aging works)" as an acceptance floor. It does not hold. Note the precise
shape: a *pure* all-urgent flood is fair, because round-robin within the urgent tier is the same
rotation argument. **The killer is mixed traffic** — sustained urgent plus one bulk.

#### Why the proof did not catch it

`fv_col_arb.sv` resets its starvation counter on `urgent_present`. `pend_urgent` is a free
input with no assumption on it, so the solver already explores every starving trace — the
counter simply refuses to count them. **P-LIVE-1 is true and vacuous on exactly the traces that
matter.** Its own comment defers the real bound to `P-LIVE-4`, which does not exist anywhere in
`formal/`.

A second, independent weakness: `starve < N_BANK` is not 1-inductive, and closes today only
because `prove depth 20 > N_BANK = 8` under `FV_SMALL` lets k-induction unroll the rotation. At
production `N_BANK = 32` it would not close, and the full-scale leg is BMC to depth 20 — which
cannot reach a 31-cycle pass-over. Related: `hbm4_rr_arb`'s properties assert subset, one-hot
and valid-iff, all satisfied by a *fixed-priority* encoder. Nothing asserts it grants the
**closest** requester, which is the single fact the entire bound rests on.

#### Two more dead paths found on the same line

`hbm4_pc_slice.sv:256` ties `.wr_oldest_age (32'd0)`, so `dir_fsm`'s guard
`wr_pending && (wr_oldest_age >= wr_age_limit)` can never fire and **`WR_AGE_LIMIT` is dead** —
a sustained read stream that keeps occupancy below `wr_hi` starves queued writes indefinitely.
(`raw_hazard` on the same line was the RAW bug, fixed in Rev 1.2.)

**Do not close this by widening a constant.** The number is not the problem; the missing
mechanism is.

### OPEN-1 — The column arbiter fairness bound is not established

`docs/02-architecture.md` §8.7 claimed *"a ready bank waits ≤ 31 issue slots"* — the bound
for **plain** round-robin. That claim does not survive contact with the implementation.

The bank-group bias (tier 2 of `hbm4_col_arb`) can exclude a ready bank from the selected
tier entirely, so the rotating pointer sweeps past it without granting. The interaction
between the tier and the pointer does not reduce to a rotation count.

**Measured:** with A3 assumed, BMC finds `starve` reaching 32 within 40 cycles. So the bound
exceeds 4·N_BANK, if it is finite at all.

The property is **disabled**, not weakened until it passes. Inflating a constant until a
proof goes green fabricates an assurance nobody has. Three ways forward, in order of
preference:

1. Prove a real bound analytically and assert it.
2. Change the arbiter so the bound is obvious by construction — e.g. force the bank-group
   bias to be skipped whenever a candidate has been passed over more than N_BANK times.
3. Accept the QoS-aging argument as the only fairness mechanism and delete the claim.

Option 2 is probably right: a fairness property you cannot state is a fairness property you
do not have.

</details>

### ~~OPEN-2~~ — CLOSED in Rev 0.6d, and it was hiding a real bug

Widening the timing engine's command scope to include auto-precharge exposed that
**`COL_RDA`/`COL_WRA` were not tracked at all.**

Auto-precharge closes the bank *internally*. No row command is ever issued, so nothing on
the row bus records that a precharge happened — and `n_act` was only ever loaded by row
commands. The next ACT to that bank was therefore legal immediately, violating tRTP+tRP.

**`PAGE_POLICY = CLOSE` would have violated DRAM timing on every single access**, and it is
one of the five documented address-map modes — recommended for random-access workloads.

The first fix was also wrong, and formal caught that too: it combined the row-bus and
column-bus constraints as a **priority chain** rather than a **max**. When a PRE and an
auto-precharging RDA hit the same bank in one cycle, the chain silently dropped whichever
lost — and since `t_rda` (tRTP+tRP) exceeds `t_rp`, the dropped one was the binding
constraint. Both defects are now mutation-tested.

### ~~OPEN-10~~ — CLOSED in Rev 1.0

Training commands now reach the device: `ROW_MRS` in the encoding, `dfi_mrs_*` payload buses,
a `phy_req`/`phy_ack` interface the sequencer actually waits on, and `OP_PREA` first in the
script. Verified by `sim/test_boot.py` (6/6) at the stack level — a level that had never been
simulated, which is how the gap survived.

**`ctrl_ready` now means what it says.**

<details><summary>Original OPEN-10 (Rev 0.9)</summary>

### OPEN-10 — Training commands never reach the DRAM

`hbm4_init_seq` produces `op_valid` / `op_code` / `op_arg`, and `hbm4_seq_rom` now supplies a
real sequence. **Neither is connected to the DFI command bus.** In `hbm4_stack_top` those
three signals terminate in the `_unused` sink.

So the sequencer walks the script, waits the right delays, reports `boot_done` — and issues
no MRS, no ZQ calibration and no training to the device. Boot succeeds and the DRAM was never
configured.

This needs a boot-time mux on the row bus (sequencer while `!boot_done`, slices after) and an
MRS encoding in `row_cmd_e`, which currently has none. Deferred rather than half-built: it
changes the DFI command encoding, which is a shipped interface (docs/03), and it belongs with
the PHY databook that also fixes the training step list.

**Until it is closed, `ctrl_ready` does not mean the device is usable.**

</details>

### ~~A1~~ — FULLY DISCHARGED in Rev 1.0

Both halves are now tested against the assembled slice:

* **power-on** — `test_reset_clean`: the slice stays off both DRAM buses while the boot gate is
  closed, reports itself idle, and releases when the gate opens;
* **mid-operation** — `test_reset_mid_operation`: reset asserted with transactions queued, a row
  open and a read outstanding. No state survives, nothing is driven while `rst_n` is low, and
  the slice recovers and resumes issuing.

The second found two real requirements: the boot script was missing `PRECHARGE ALL`, and the
DFI command strobes had no reset term. Both fixed.

Residual: still one slice at a time, not the 256-slice system.

### ~~OPEN-3~~ — A1 partially discharged in Rev 0.9

A1 (reset behaviour) is now exercised by `sim/test_slice.py::test_reset_clean` against the
assembled slice, and it **failed on first execution** — three times, for three different
reasons. See the release notes for Rev 0.9. What it checks now:

* no column command out of reset (there is no open row to address);
* the slice stays off both DRAM buses for as long as the boot gate is closed, and reports
  itself idle while doing so;
* opening the gate actually releases traffic.

It remains *partially* discharged: the test covers a single slice at reduced geometry, not the
256-slice system, and not reset asserted mid-operation — which is the half of A1 that still
has no coverage anywhere.

<details><summary>OPEN-3 as originally written (Rev 0.5) — superseded, kept for the record</summary>

### OPEN-3 (original) — A1 is not yet discharged

**A3 is discharged as of Rev 0.5** (see above). A1 (reset behaviour) remains assumed in four
proofs and asserted nowhere; it becomes real when the Rev 0.6 cocotb environment lands.

</details>

### OPEN-5 — The RAA overshoot bound is not established

`fv_refresh` proves the row-hammer detector never fails to *request* mitigation
(`p_rfm_always_requested`). It does **not** bound how far RAA can climb past the threshold.

Two attempts were made and both were wrong, instructively:

| Attempt | Why it was wrong |
|---|---|
| `raa != 8'hFF` | threshold-dependent — a threshold near 255 legitimately drives RAA there — and it silently assumed RFM grants |
| `raa <= thresh + 1` | **overflowed** at `thresh = 255`, so the test became `raa <= 0`; and even widened it is false, because RFM is deferred whenever a refresh is granted the same cycle while activates keep arriving |

The bound depends on how long `hbm4_row_arb` can defer RFM, so it belongs to a system-level
proof, not to this module. **Left unstated rather than guessed at** — the same discipline
that closed OPEN-1 by fixing the design instead of inflating a constant.

### ~~OPEN-8~~ — CLOSED in Rev 0.7c. One property, three real bugs.

P-EC-2 ("a dirty entry is never replaced without an acknowledged write-back") now proves
unbounded. Getting there took three separate fixes:

1. **The update path had no row input.** It reused a slot without eviction, discarding a
   dirty block and leaving an inconsistent tag (old row, new row-half).
2. **`upd_stall` tested the global `evict_ack`** without asking *whose* eviction was
   acknowledged, so a fill's ack let a conflicting update through.
3. **A fill whose tag already MATCHED a dirty entry was applied anyway** — overwriting
   recomputed check values with the stale ones just read from DRAM, and clearing the dirty
   bit. No conflict, no eviction, no error.

(3) is the one worth remembering. It is **not a conflict at all**, which is why fixing the
conflicting cases twice still left the property failing. A fill is only ever useful onto a
*clean* entry; onto a dirty one it is either redundant or destructive, never helpful.

Each of these loses the check bits for 15 data blocks at once, and the symptom is an
uncorrectable-error storm on data that was never damaged. All three are now mutation-tested.

**And a fourth defect, in the property itself.** The first formulation required
`!$past(evict_ack)` in the antecedent, so it never examined the case where an ack occurred
**for a different bank** — precisely the ack-ownership bug. Reverting fix (2) survived
mutation testing until the property was rewritten to key on the *identity* of the
acknowledged eviction: *a dirty entry's tag changes only when its own eviction was acked.*

Keying on identity rather than on the mere absence of an ack is what made it airtight, and
mutation testing is the only reason the weakness was visible.

Closing it also needed one strengthening invariant: `dirty ⇒ valid`. From `dirty && !valid`
a fill sees neither a conflict nor a redundancy and clears the dirty bit — unreachable from
reset, but induction starts anywhere.

### OPEN-9 — Link-ECC retry is architecturally blocked; escalation is the shipped behaviour

**Rev 1.0 resolution: this is a product decision, not an outstanding bug.**

Retry cannot be implemented against the current transaction pool. Entries are freed **at
issue** (`ent_valid[pop_idx] <= 1'b0` in `hbm4_txn_pool`), so by the time a link error is
detected on the return path, the entry holding the address no longer exists — there is nothing
to re-issue from. Implementing retry requires extending entry lifetime through completion,
which changes occupancy accounting, the NHI credit model, and several proofs. That is a Rev 1.1
architectural change.

What ships instead is a **tested escalation path**: a link uncorrectable is reported to the host
as an error rather than becoming a response that never arrives. `test_link_ue_escalates`
confirms 4 corrupted beats produce 4 uncorrectable errors and 4 responses — the host sees an
error, not a hang.

`cfg_retry_en` remains tied off. It is a working mechanism inside `hbm4_link_ecc` with no
usable source of re-issue above it; integrators must not enable it.

<details><summary>Original OPEN-9 (Rev 0.7)</summary>

### OPEN-9 — The link-ECC retry path does not exist; retry is disabled

`hbm4_link_ecc` suppresses `out_valid` while a retry is outstanding, expecting something to
re-issue the read. **That re-issue path was never built.** It needs the transaction-pool
entry to stay allocated past issue so the request can be replayed, and the pool currently
frees on issue.

Wiring `retry_req` to nothing while leaving retry *enabled* suppresses the completion and
never replays it: the transaction simply never finishes and the host waits forever, with no
error anywhere. **A hang.**

`cfg_retry_en` is therefore tied off at the slice. A link uncorrectable is escalated
immediately — less available than the design intends (docs/02 §10.1 claims transparent
retry), but correct and visible.

**Found by lint**, flagging `retry_req` as unconnected — which is the kind of finding that
argues for treating an unconnected output as an error rather than a style warning. Closing it
means adding a replay path in the pool, and the docs' availability claim should be softened
until then.

### OPEN-7 — Inline system ECC is SEC-DED, not symbol-correcting

Documentation before Rev 0.7 claimed a (272,256) single-4-bit-symbol-correcting code. The
implementation is Hsiao SEC-DED(266,256).

A fault confined to one x4 device produces a 4-bit burst inside a single symbol: a symbol
code corrects it, SEC-DED detects it and reports uncorrectable. **No silent corruption
either way** — the block is poisoned — but availability is lower under a device-level fault.

Closing it needs GF(16) syndrome decoding and a Chien search. The 16-bit field already has
the room (10 used, 1 poison, 5 spare). Docs corrected to match the implementation.

### OPEN-6 — The read-FIFO ORDER property is bounded, not unbounded

`fv_rd_ptr_fifo` proves level accounting, bounds, and the empty/full flags unbounded. The
**order** properties (`p_order_first` / `p_order_second`) are BMC-only.

k-induction cannot close them without a full "FIFO contents match a reference queue"
invariant — a substantially larger construction than the property is worth here. BMC to
depth 12 covers complete fill and drain cycles of the 8-deep proof configuration.

**Reported as bounded, never as proved.** The order property is the one that matters most
in this block — a mis-ordered FIFO hands one requester another's data with no error
anywhere — so this gap is worth closing when the reference-queue construction is built for
the pool (OPEN-4) as well.

### Rev 1.1 attempt — did not close, and what it ruled out

The standard cheap alternative to a reference queue is to track **one symbolic slot**: remember
what was written when the write pointer passed an `anyconst` slot `k`, and prove the pop at `k`
returns it. Three strengthening invariants were tried, in increasing order of strength:

1. `f_live -> mem[f_slot] == f_val` — fails induction immediately. From an arbitrary state the
   solver sets `f_live` with `f_slot` outside the occupied region, and a push then legitimately
   overwrites it.
2. `+ f_live -> offset(f_slot, rptr) < level` — ties the tracked slot into the occupied range.
   Still fails.
3. `+ wptr == (rptr + level) mod DEPTH` — the fundamental FIFO relation, which rules out states
   where pointers and count disagree. **Still fails**, running ~17 minutes to `UNKNOWN`.

So the missing invariant is not any of those three, and it is not simply pointer consistency.
The next thing to try is the full per-entry invariant — *for every occupied slot, the entry
equals what was pushed there* — which is the reference-queue construction this item originally
called for. The single-slot shortcut does not appear to be sufficient for this FIFO.

**The attempt was reverted, including a `DEPTH:1` debug read port added to `hbm4_rd_ptr_fifo`
to make the array observable.** That port has real silicon-debug value, but it was added to
serve a proof that did not close, and shipping area justified by a rationale that turned out
false is not acceptable. Whoever closes this should re-add it.

`prove` was never left in the regression: it would have reported `UNKNOWN`, which is neither
pass nor fail and would have quietly degraded the suite's meaning.

### OPEN-4 — The pool proof is bounded, not unbounded

`hbm4_txn_pool` has by far the largest state of any block proved: `N_BANK × 2` lists of
{head, tail, count} plus a head mirror per list. Unbounded `prove` does not close in
reasonable time at 8 banks.

**Status: BMC clean to depth 6.** Three of four cover targets reachable at that depth;
`c_full` (a completely full pool) needs more. Neither is a design finding — both are solver
budget. Two ways forward: a pool-specific 2-bank geometry, or strengthening invariants
relating `l_cnt` to the list linkage. Until then the pool is **bounded-checked, and reported
as such**.

---

## A recurring defect class: property arithmetic that silently wraps

**Twice now** a property has been quietly neutered by its own constant overflowing:

- `ROW_W'(N_ROW)` — `N_ROW` is `2^ROW_W`, so the cast truncated to 0 and `row < N_ROW`
  became `row < 0`.
- `cfg_rfm_thresh + 8'd1` — at threshold 255 this wraps to 0, so `raa <= thresh+1` became
  `raa <= 0`.

Both failed loudly, which is the only reason they were caught. A property whose constant
wraps the *other* way would pass vacuously and never be noticed. **Widen before adding, and
be suspicious of any comparison against a parameter-derived constant.**

---

## A note on tooling, learned the hard way

`sv2v` **silently discards all assertions** unless invoked with `-E Assert`. The first runs
of every proof in this project reported `PASS` with zero assertions in the model.

They were vacuous, and nothing in the `sby` output said so — "Checking assertions in step N"
is printed whether or not any assertions exist.

This was caught only by `mutate.sh`, which injects a known bug and requires the proof to
fail. **Any formal flow that has never been shown to fail should be assumed broken.**
`make -C formal` and `./mutate.sh` are both CI gates for exactly this reason.
