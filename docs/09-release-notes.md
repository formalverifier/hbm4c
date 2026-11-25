# 09 — Release Notes

**HBM4 Memory Controller IP**

---

## Versioning

`hbm4c-vMAJOR.MINOR.PATCH`. One tag version-locks RTL, documentation, verification kit, and
software together. Mixing components across tags is unsupported — the CSR map, the address
hash, and the formal property set are coupled by design.

| Field | Bumps when |
|---|---|
| MAJOR | An interface or CSR layout changes incompatibly, or a default changes in a way that alters data placement |
| MINOR | Features added, defaults unchanged, existing integrations unaffected |
| PATCH | Bug fixes, documentation, verification additions |

`VERSION` (CSR `0x0004`) reports the built version. **Drivers must check it at boot**
([04 §2](04-programming-guide.md)).

---

## Rev 1.3 — current

**Status: the controller could not write data. It can now.**

### There was no write datapath

The NHI carried `req_wr` — a direction bit — and **no data**. The DFI adapter had `dfi_rddata`
in and **nothing out**. A write issued a `WR` command carrying an address, and no data ever
reached the device. [docs/03](03-interface-spec.md) specifies the host side of it (rules H3 and
H5, and the `WD_SKEW` parameter); none of it existed.

This is why inline ECC could never have been wired: there was nothing to encode.

Now built: `req_data` on the NHI, a new `hbm4_wdata_ram` holding write data from request to
issue, and `dfi_wrdata`/`dfi_wrdata_valid` out of the adapter, propagated through slice, stack
and system.

**Indexed by tag, not by pool entry.** The pool does not expose its allocated index, and tags
are already required to be unique among outstanding transactions (rule H2). That avoids
touching the pool, which is the largest block in the slice. The dependency is real and now
explicit: a host that reuses a live tag overwrites that transaction's write data.

### The data test was checking nothing, for three revisions

`test_write_read_data` has passed since Rev 0.9 with the docstring *"what the DRAM ends up
holding must match what was written"*, while asserting `model.n_wr >= 8` — **a count of write
commands**. It could not have done more: there was no write data, and the reference model's
array was never written. It was reported as end-to-end data verification. It was not.

It now compares the reference array against the values sent, byte-exact, and the monitor hands
the model the write data the controller actually drives.

### Which immediately found a bug — in the testbench

The rewritten test failed at once: stored values shifted by one. Tracing showed captures were
correct (tag 0→data0 … tag 3→data3) but issues came out **1, 2, 3, 0** — the pool issues by
**bank**, not in request order, so tag 0's write issues last.

The driver was assigning tags round-robin regardless of what was in flight, reusing tag 0 while
its transaction was still queued and overwriting its data. A host-protocol violation
(rule H2), not a controller bug — but it corrupts memory identically, which is precisely why
the interface imposes the rule. The driver now models a conforming host.

Result: **16 blocks written and verified byte-exact.**

### A second silent-omission channel closed

`tb_stack_top` and `tb_sys_top` were missing the new `req_data` port and still built, because
the sim Makefile passes `-Wno-fatal` — needed for the cocotb/Verilator wrapper's own warnings,
but it stops *our* mistakes being fatal too. Verilator ties an unconnected input low and the
test passes while exercising a signal stuck at zero.

`make lint` in `sim/` now lints design and testbench at `-Wall` with warnings fatal, separately
from the simulation build. Same class as the unconnected modules and the unconnected DFI
payloads: **the tool knew, and something suppressed it.**

### Still unconnected

`hbm4_csr`, `hbm4_ecc_cache`, `hbm4_ecc_init`, `hbm4_err_log`, `hbm4_scrub` — five modules,
enforced by `tools/check_instantiation.sh`, which fails the build while they remain.

`hbm4_wdata_ram` is new and has **no formal proof yet**.

---

## Rev 1.2

**Status: six modules were found wired to nothing, including one that made reads return stale
data. The first is fixed. This supersedes every earlier shippability statement.**

### Six modules were never instantiated

| Module | Feature | Consequence |
|---|---|---|
| `hbm4_wbuf` | write buffer, **RAW hazard detection** | **reads returned stale data** — fixed, see below |
| `hbm4_csr` | the entire APB register block, `AMAP_LOCK` | no register map exists; [docs/04](04-programming-guide.md) describes absent hardware |
| `hbm4_ecc_cache` | inline ECC check-value cache | **inline system ECC does not exist** |
| `hbm4_ecc_init` | ECC region initialisation | — |
| `hbm4_err_log` | error log | no error history |
| `hbm4_scrub` | patrol scrub | no background scrub |

All six are lint-clean, formally proved and mutation-covered. **They were connected to
nothing.** `hbm4_sys_ecc` is instantiated exactly once — inside `hbm4_link_ecc`, as the link
decoder — so nothing generates or checks ECC on stored data, while the address map still
reserves 2 of 32 columns via `div30`. **6.25% of capacity was reserved for a feature that was
not implemented.**

### Why every existing check was blind to it

Each check scoped itself to what was connected, and each for a different reason:

* **Lint** elaborates an unconnected module standalone and is satisfied.
* **Formal** proves a module in isolation — and proving an unconnected module proves nothing
  about the design. 40/40 passing, 71 mutations, 0 survivors, on modules not in the design.
* **Simulation** exercises the assembled slice, so a feature that is absent never appears. The
  tests passed because they could not test what did not exist.

`tools/check_instantiation.sh` now fails the build on any module nothing instantiates, with an
explicit allow-list (`hbm4_addr_slice` ships to the customer's fabric by design).

**An unconnected module is the most expensive kind of dead code: it carries the full appearance
of verification while contributing nothing, and it makes the documentation lie.**

### RAW hazard: reads returned stale data

`raw_hazard` on `hbm4_dir_fsm` was tied to `1'b0`. A read to an address with a queued write
issued straight to DRAM and returned the old contents — silent corruption, no error.

Now integrated. The write buffer has one query port and it serves two disjoint uses, because
`dir` is either READ or WRITE in any cycle: on write cycles the issued write is looked up to
get its drain index, on read cycles the issued read is checked against every pending write. A
hazarding read is suppressed — neither issued to DRAM nor popped from the pool — and
`raw_hazard` forces the direction FSM to drain writes. Blocking without forcing the drain would
livelock.

**The new test was verified against the bug.** With the fix disabled it fails with a read to
bank 0 column 0 issuing at cycle 20, ten cycles before the write to the same block at cycle 30.
A regression test that has never seen the failure it guards is not evidence.

### QoS aging is specified, documented, and absent

[docs/02 §622](02-architecture.md) specifies "effective QoS +1 every `AGE_TICK` (512) clocks";
[docs/04](04-programming-guide.md) documents an `AGE_TICK` CSR at `+0x10`; [docs/07](07-performance-guide.md)
tells the operator to lower it. `grep` over `rtl/` finds only a *comment* in `hbm4_col_arb.sv`
citing it as the starvation mitigation.

The result is a real denial of service: two outstanding `QoS=3` reads to different bank groups
starve a `QoS=0` request in the same pseudo-channel **indefinitely** — its credit is never
returned, the host waits forever, and nothing reports an error. `req_qos` is an unpoliced
per-request host input.

`fv_col_arb.sv` resets its starvation counter whenever `urgent_present`, so **P-LIVE-1 passes
vacuously on exactly the traces where starvation happens**, deferring the real bound to
`P-LIVE-4` — which does not exist anywhere in `formal/`.

Two more dead paths on the same line: `hbm4_pc_slice.sv:256` ties `wr_oldest_age` to `32'd0`,
so `WR_AGE_LIMIT` can never fire and a sustained read stream starves queued writes.

**Not yet fixed.** Tracked as OPEN-11.

---

## Rev 1.1

**Status: the design does not meet its clock target. The system level is now simulated and is
clean.**

### The whole controller has been simulated for the first time

`hbm4_sys_top` and `hbm4_supervisor` had only ever been linted — the same gap that, one level
down, hid OPEN-10 (boot completing successfully while issuing nothing). **5/5 pass.**

| Test | What it establishes |
|---|---|
| `test_all_stacks_boot` | `ctrl_ready` asserts and every stack really issued PHY training |
| `test_stacks_train_in_parallel` | stacks finish within 40% of each other — boot is not serialised |
| `test_one_stack_failure_fails_boot` | a stack whose PHY never acks makes `boot_failed` assert; `ctrl_ready` stays low |
| `test_no_traffic_before_ready` | no column command anywhere in the system before `ctrl_ready` |
| `test_perf_snapshot_single_edge` | `perf_freeze` is exactly one edge per held request, not a level |

**No DUT defects found**, which is worth stating plainly given that the equivalent first run at
the stack level found a blocking one. Two of these check failure modes nothing else can see:
serialised boot is functionally correct and would pass every other test while multiplying a
~200 µs boot by the stack count; and a level-sensitive `perf_freeze` would stall the counters
permanently, which reads as a working system with suspiciously round numbers.

### A correction to the verification status

Earlier revisions of this document and my own reporting described assumptions **A2, A3, A4 and
A7 as still standing**. They are not. All four were discharged in Rev 0.6c–0.7, and A1 in
Rev 1.0 — the error came from reading the `## A2`…`## A7` section headers in
[ASSUMPTIONS.md](../formal/ASSUMPTIONS.md) as open items without reading their status lines.

**Every assumption is discharged.** The genuinely open items are OPEN-1, 4, 5, 6 and 7 — five,
not the nine implied by counting assumption headings as gaps.

### OPEN-6 attempted and NOT closed

The read-FIFO ordering proof. The cheap alternative to a reference queue is to track one
symbolic slot; three strengthening invariants were tried, each subsuming the last:

1. `f_live -> mem[f_slot] == f_val` — fails induction immediately;
2. `+ f_live -> offset(f_slot, rptr) < level`;
3. `+ wptr == (rptr + level) mod DEPTH` — the fundamental FIFO relation.

All three fail the induction step; the last ran ~17 minutes to `UNKNOWN`. The single-slot
shortcut is not sufficient for this structure, and OPEN-6's original assessment — that it needs
the full per-entry construction — stands.

**Reverted in full, including a `DEPTH:1` debug read port added to `hbm4_rd_ptr_fifo` to make
the array observable.** That port has genuine silicon-debug value, but it was added to serve a
proof that did not close, and shipping area on a rationale that turned out false is the same
mistake as the FIFO wrap comparisons in Rev 0.8c. `prove` was never left in the regression:
`UNKNOWN` is neither pass nor fail and would have quietly degraded what the suite means.

The three dead ends are written into OPEN-6 so the next attempt does not repeat them.

### 1 GHz fails by ~2×

First timing run against a real cell library — ASAP7, predictive 7 nm, RVT, typical corner:

| `TQ_DEPTH` | critical path | implied Fmax |
|---:|---:|---:|
| 16 | **1830 ps** | 546 MHz |
| 64 (as shipped) | **2252 ps** | 444 MHz |

Target is 1000 ps. **This is the optimistic number** — `WireLoad = "none"`, so no wire delay,
no placement, no clock tree. The whole architecture rests on a 1 ns core clock (one column
command per clock, 1:2 DFI gearing, BL8 = 1 core clock), and that premise currently fails.

Not a margin problem. It needs cross-module pipelining, which has not been attempted — the RTL
was written for function, never for timing.

### Two earlier conclusions were wrong

**The critical path is not where I said it was.** Generic-gate `ltp` reported
`u_ref.rfc_cnt → u_timing.pre_ok`. With real cells, *no single block exceeds 1 ns* — the worst
is `hbm4_row_arb` at 1002 ps. The slice path is a cross-module path. Topological depth in
2-input gates is a poor predictor of where real time goes.

**Shrinking `TQ_DEPTH` does not fix timing.** I predicted the pool's 64-entry search drove the
path. Measured, the pool's own delay is *flat in depth* (3798 → 3867 ps from 8 → 64). Depth
buys ~19% at the slice level, then flattens.

What the sweep does justify is **area**: depth 64 costs 1468 µm² per pseudo-channel over depth
8 — 21% of the slice, **~0.38 mm² across 256**. `TQ_DEPTH = 16` is the knee. To evaluate, not
to apply: the 98.8% efficiency result must be re-measured at any proposed depth first.

### A measurement trap worth recording

Without `buffer -N 16; upsize; dnsize` in the `abc` script the reported delay was **19 865 ps**
— 9× worse. `abc` inserts no buffers, so high-fanout nets carry the full unbuffered load of
thousands of sinks. I nearly reported that number. **An unbuffered delay is not an estimate,
it is an artifact.**

---

## Rev 1.0

**Status: the blocking functional gaps are closed, the design has been synthesized for the
first time, and the headline performance claim is measured rather than argued.**

### OPEN-10 closed — the device was never configured

`hbm4_init_seq` produced `op_valid`/`op_code`/`op_arg`; in `hbm4_stack_top` all three landed in
the `_unused` sink. Boot walked the script, waited every delay, asserted `boot_done` — and
issued nothing. **`ctrl_ready` asserted on a device that had never been configured and a PHY
that had never been trained**, with no symptom until data came back wrong.

Now implemented: `ROW_MRS` in the command encoding, dedicated `dfi_mrs_index`/`dfi_mrs_opcode`
payload buses at the stack boundary (broadcast — a slice never issues MRS), and a separate
`phy_req`/`phy_op`/`phy_arg`/`phy_ack` interface for training steps. The sequencer **waits for
`phy_ack`**: training takes thousands of cycles, and acking immediately would march the script
through training in a way that is indistinguishable at the interface from training that worked.

Verified at the stack level, which had never been simulated at all — which is precisely how
this survived review, lint and forty proofs.

### A missing PRECHARGE ALL, found by resetting mid-operation

Reset wipes the controller's bank state. **It does not close the device's rows.** Until an
explicit precharge-all lands the two models disagree, and the first refresh after reset goes to
a bank the DRAM still has open — a protocol violation on a perfectly healthy device.

Invisible at cold power-on, where the device really does start closed. Only reset asserted
*mid-operation* — the half of A1 no proof covers — exposes it. `OP_PREA` is now the first
command in the boot script, before any mode register.

A second instance of the same shape appeared immediately after: reset also clears the
controller's *timing* counters while the device is still counting out `tRFCsb`. The design
already handles it, because `cmd_en = seq_done` and the boot script opens with `tINIT` waits
that dwarf every DRAM parameter — but it makes the requirement explicit: **the full boot
sequence must re-run after any reset**, and that is enforced structurally, not by documentation.

### A1 fully discharged

Both halves now tested: power-on reset, and reset asserted with transactions in flight, an open
row and an outstanding read. Nothing survives, nothing is driven while reset is asserted, and
the slice recovers. The last standing assumption from Rev 0.5 is closed.

One fix went with it: `hbm4_dfi_adapter` drove the DFI command strobes from `always_comb` with
**no reset term**, so a slice whose boot gate happened to be tied high drove commands while
`rst_n` was asserted. Masked in the assembled system because `cmd_en` comes from a register
that resets to zero — but shipped IP cannot rely on how the level above happens to be wired.
The same class of mistake as `busy`/`quiesced` in Rev 0.9.

### First synthesis — see [syn/README.md](../syn/README.md)

| | |
|---|---|
| Area | **80 579** 2-input-gate equivalents per pseudo-channel → **~20.6 M** system-wide |
| Longest reg-to-reg path | **125** levels of 2-input gates (`u_ref.rfc_cnt` → `u_timing.pre_ok`) |
| Combinational loops | **none** (`check -assert` passes) |

`abc -g simple` maps to 2-input primitives only, so 125 levels is roughly **30–50 standard-cell
levels** — at or slightly beyond a 1 GHz budget. **Tight, plausible, and unresolved without a
real library.** It is the largest technical risk remaining, and the report says where to
pipeline first if it fails.

**Two blocks are two thirds of the area**: `hbm4_txn_pool` (40.5%) and `hbm4_timing_engine`
(25.8%). `TQ_DEPTH` is the dominant knob — 64 entries per pseudo-channel is **16 384 in-flight
transactions system-wide**, almost certainly over-provisioned for row-hit-dominated streaming.
Halving it would save ~4 M cells. The performance model should size it; it never has.

### Performance measured: 98.8%

At **production geometry** with saturating sequential reads, steady-state column-bus
utilisation is **98.8%** (1186 column commands in 1200 core clocks) — against the ~83% target
in [docs/07](07-performance-guide.md), which had been argued from timing parameters and never
measured.

Read it for what it is: a 1200-clock steady-state window on pure sequential reads with the
refresh duty cycle largely outside the window. It confirms the scheduler and address map can
saturate the bus; it is not a full-workload efficiency number.

**The first attempt measured 21%** — 252 column commands from 256 requests. The window was
transaction-limited, not bandwidth-limited. *A saturation test that is not saturated measures
the testbench.* The earlier reduced-geometry attempt was worse: `TQ_DEPTH` is 4 under
`FV_SMALL`, so at most four transactions are ever outstanding and the bus cannot be saturated
regardless of scheduling quality. Efficiency now runs at `GEOM=full` only.

### OPEN-9 resolved as a product decision, not a fix

Link-ECC retry cannot be implemented against the current pool: **entries are freed at issue**
(`ent_valid[pop_idx] <= 1'b0`), so by the time a link error is detected on the return path the
entry holding the address is gone. Implementing retry means extending entry lifetime through
completion, which changes occupancy, the credit model and several proofs.

That is a Rev 1.1 architectural change, not a bug fix. What has been done instead is to make
the fallback **correct and tested**: a link uncorrectable escalates to the host as an error
rather than a response that never arrives. Verified — 4 corrupted beats produce 4 uncorrectable
errors and 4 responses, so the host sees an error, not a hang.

---

## Rev 0.9

**Status: simulation environment exists (cocotb 2.0.1 + Verilator 5.050), and it immediately
found two bugs that 40 passing formal proofs did not.**

### Why these were not reachable by the proofs

Both live in the space between blocks — one in the *meaning* of a signal crossing a module
boundary, one in a state (falling behind on refresh while banks are open) that only sustained
traffic produces. Neither is a block-level property, which is exactly why block-level proofs
could not see them.

### Bug 1 — refresh issued to an open bank

`hbm4_refresh` gated its request on `(ref_debt > 0) || bank_idle[ref_ptr]`. Read it as *"when
behind schedule, refresh regardless of whether the bank is open."* **Being behind schedule is
the normal state under sustained load**, so this was not a corner case — it was steady-state
behaviour. REF to an active bank is illegal in JEDEC and destroys the open row.

The obvious fix — add `&& bank_idle` — trades an illegality for a starvation: a bank under
continuous row hits never goes idle, so its refresh is postponed forever and the data is lost
anyway. Both halves are needed, so the request is now split:

* `ref_due` — this bank owes a refresh; drives a **forced precharge** via the new
  `ref_want_pre`, which the slice ORs into `want_pre`;
* `ref_req` — actually issues, and waits for the bank to be closed.

The controller closes the bank because it must, then refreshes it. New properties
`p_ref_bank_closed`, `p_rfm_bank_closed` and `p_force_pre_only_open` hold this in place, and
`p_rfm_always_requested` was **updated rather than weakened**: the obligation is now "a
hammered bank is always being acted on — mitigated now, or closed so it can be next."

Found at cycle 32012 of a streaming test.

### Bug 2 — the design had no boot order that worked

The slice had no gate keeping it off the DRAM buses during training, and `busy` meant only
"host transactions outstanding." Since refresh issues opportunistically whenever a bank is
idle, and every bank is idle after reset, **the slice starts driving REF on the row bus the
first cycle after reset**. From there both polarities are broken:

* with `busy` excluding refresh, `hbm4_stack_top` computes `quiesced = !stack_busy`, believes
  the slice is idle, and puts the sequencer's MRS on the same row bus in the same cycle;
* with `busy` including refresh (which is what it means), the stack top never sees a quiet
  slice, the sequencer never runs, and **boot deadlocks**.

There is no correct value of `busy` — the slice has to be structurally off the bus until
training completes. `cmd_en` now does that, applied to the arbiters' *legality* inputs rather
than the DFI outputs: gating the outputs would leave the arbiters granting and the refresh
engine acking into a bus that goes nowhere, so the controller would exit boot believing it had
refreshed banks it never touched.

**`P-SEQ-1` proves the sequencer never drives while `slices_quiesced` is low. It cannot prove
that `slices_quiesced` means anything** — the meaning lives on the other side of a module
boundary. That gap is the whole finding.

### Three bugs in the testbench, which is the point of writing one carefully

The checker is written from the JEDEC parameter definitions rather than from the controller's
timing engine, so it can disagree with the design. It also disagreed with reality three times:

1. **Production timings against a reduced-config DUT.** `t_rfc_sb` is 6 in `small_timing()`,
   not 96, and with 8 banks and a round-robin pointer the same bank only recurs after 8
   cycles. Back-to-back per-bank refresh looked like a gross tRFCsb violation and was
   perfectly legal. *A checker whose parameters disagree with the device produces confident,
   specific, wrong findings — worse than no checker.*
2. **The credit protocol backwards.** `req_credit` is a *return* pulse; the host starts with
   `TQ_DEPTH` credits (docs/03 §7). Modelling it as a grant deadlocks against a correct
   controller, because nothing completes to return a credit for.
3. **Tag width.** Hardcoded `% 64` against a 2-bit port at reduced scale.

Each was diagnosed as a DUT bug first. The general lesson is the one already in
[formal/SCALING.md](../formal/SCALING.md): **a checker is code, and gets the same scrutiny as
the design.**

### The read-return path was missing from the testbench, and it looked like a deadlock

The first environment watched the command bus and never drove `dfi_rddata_valid`. The
controller issued the read, parked the transaction in the read-pointer FIFO, and waited
forever for data that was never returned — so nothing completed, no credits came back, and the
driver blocked. **A perfectly healthy scheduler presenting as a controller deadlock.**

Worth stating because of what it implies about the earlier passing runs: a test that counts
commands on the DFI bus will pass against a controller that never answers the host. Only an
end-to-end check — request in, response out, credit returned — can tell those apart.

### What the environment now measures

| Test | Result |
|---|---|
| `test_reset_clean` | gate holds 200 cycles, releases on demand |
| `test_streaming_sequential` | 64 requests → 64 column commands, **0.0% of consecutive pairs in the same bank group** |
| `test_write_read_data` | 16 writes drained, 8 rows opened, no violations |
| `test_random_traffic` | 96 mixed transactions, 65 reads / 31 writes, turnaround clean |
| `test_refresh_happens` | 101 refreshes, tRFCsb honoured |
| `test_credit_return` | credit accounting exact to the transaction |

**7/7 pass**, with the independent JEDEC checker live on every command.

The streaming number is the one that matters: **constraint C2 holds on every single
consecutive pair.** The bank group alternates on every column command, so `tCCD_L` is never
the limiter — which is precisely what the address map exists to deliver
([02 §5.1](02-architecture.md)) and the first time it has been measured rather than argued.

### A second flow hazard, hit the same way

After documenting the stale-netlist trap, I ran two `make` regressions concurrently in the same
directory. They regenerate the same `build/*.v`, so they overwrite each other mid-proof — and
the result is meaningless in whichever direction the race falls, **including green**. The
reported 40/40 from that run was discarded and re-run clean.

`mutate.sh` already held a build lock for exactly this reason. `make guarded` now takes one at
the top level too.

Both hazards share a root cause worth naming: **the build products are shared mutable state,
and a proof that reads the wrong ones still reports PASS.** Every guard in this flow exists
because a wrong answer here is green, not red.

### A1 is partially discharged

`test_reset_clean` is the first thing in the suite that tests the assumption every proof rests
on, and it **failed on first execution, three times, for three different reasons.** It now
verifies that the slice stays off both buses for as long as the gate is closed, reports itself
idle while doing so, and actually releases when the gate opens.

Still assumed: reset asserted *mid-operation*, and anything above a single slice. See
[OPEN-3](../formal/ASSUMPTIONS.md).

---

## Rev 0.8c

**Status: 32 modules; the full system elaborates with a real boot script.**

### The boot sequence did nothing

`hbm4_stack_top` tied the sequencer's `script_data` to a constant `OP_END`, as a stub. So
boot terminated on its first instruction and **reported success without training the PHY**.
Nothing failed: `ctrl_ready` asserted, traffic started, and the first read returned whatever
an untrained interface returns.

`hbm4_seq_rom` now holds the actual sequence — power-up delays, mode registers, ZQ
calibration, write levelling, read training, then a lock step that freezes the trained values
*before* traffic is released.

### Two bugs in the sequencer, exposed by writing the thing that feeds it

Both were in `OP_WAIT`, and both were invisible until a script actually contained one.

1. **`OP_WAIT` never advanced the PC.** It loaded `wait_cnt`, counted down, and then
   re-executed the same instruction — an unconditional infinite loop. Every script with a
   `WAIT` in it ran until the watchdog killed it and reported a boot failure.
2. **`op_valid` was not gated on the wait.** With the PC now advancing, the *next*
   instruction's command was issued immediately instead of after the delay. The waits between
   MRS writes are mandatory JEDEC init timing (tMRD, tINIT3), so this is an init-protocol
   violation, not a scheduling nicety.

**Why formal missed it.** `script_data` is a free input, and the `c_done` cover is satisfied
by an `OP_END` at PC 0 — so no proof had ever executed a `WAIT`. The same unreachable-guard
trap as [formal/SCALING.md §3](../formal/SCALING.md), for the fourth time. The covers added
(`c_wait`, `c_wait_prog`, `c_wait_done`) now force the path, and `p_wait_blocks_op` proves
the second bug cannot return.

### A cover that could never pass

`c_wait_done` was first written `done && $past(dbg_wait != 0)`. That is **unreachable by
construction**: when `wait_cnt` reaches zero the `OP_END` executes that same cycle and `done`
asserts the next, so the previous cycle's `wait_cnt` is already zero. It would have failed
the build forever while looking like a genuine coverage hole. Replaced with a sticky
`saw_wait` tracker, which is what the intent — *a script that executed a WAIT still finished*
— actually requires.

### A false-assurance hazard in the flow itself

Mid-debug I ran `sby -f initseq.sby` directly instead of `make initseq`, and spent a detour
diagnosing a guard that appeared to have been constant-folded to `1'b0` by sv2v.

**It had not been.** `sby` reads the `build/*.v` already on disk; only `make` re-runs sv2v
first. I was reading a netlist generated from an *older revision of the source* — one that
did not even have the ports I had just added.

The failure mode is worse than the wasted time: **a proof run this way passes against RTL you
have already changed, and reports green.** `mutate.sh` is safe because it invokes `make`, but
a human iterating on one block is not. `make stale` now refuses to proceed when any netlist
is older than its sources.

Two corrections went with it: the sv2v mechanism I had written into the code comments was
never established and has been removed, and the two ring-buffer wrap comparisons I "fixed" on
that false premise have been **reverted** — no defect was ever demonstrated there, and
churning proved RTL on a bad diagnosis is its own hazard.

### RFM is not a separate module

The module list carried `hbm4_rfm`. The RAA counters and mitigation are already inside
`hbm4_refresh`, where they share `refresh_block` and the per-bank counters. Splitting them
would create a cross-module dependency for no benefit, and `fv_refresh` already proves both.
The list was wrong, not the RTL — **32 modules, not 33.**

---

## Rev 0.8b

**Status: the full system integrates. 31 modules; `hbm4_sys_top` elaborates.**

### Added — RTL

`hbm4_stack_top` (64 slices + per-stack global), `hbm4_supervisor`, `hbm4_sys_top`.

### A documented mechanism that was never implemented

[02 §9.4](02-architecture.md) says the supervisor spreads refresh across pseudo-channels so
they do not all refresh at once. **The RTL reset every `refi_cnt` to zero** — all 256
pseudo-channels ticking their refresh interval in lockstep, which is precisely the correlated
current spike and correlated bandwidth notch the doc claims is prevented.

It costs nothing to fix: a different reset value, not extra logic. But it only works if
something *above* the slice hands out the offsets, which is why it was missing until the
stack level existed to assign them. `cfg_refi_phase` now seeds each slice from its global
pseudo-channel index.

**Worth noting how it was found:** not by a proof or a test, but by writing the level of
hierarchy that was supposed to provide the input and discovering there was no input to
provide.

### Another open output that would have been silent

The stack top first wired only `dfi_*_valid` and left `cmd`, `bank` and `addr` unconnected —
**the DRAM would see a valid strobe carrying nothing.** Caught by lint flagging the empty pin
connections, the second such finding in this integration after the unconnected `retry_req`.

Two silent functional failures in two integration levels, both from open outputs, both caught
by lint rather than by review. **An unconnected output deserves to be an error.**

### What the top level is, and is not

`hbm4_sys_top` has **no crossbar**, and that is the central architectural decision. 256
pseudo-channels at 32 B/clk is ~16 000 wires per direction; a central switch at that width is
not buildable at 1 GHz. Each pseudo-channel gets its own NHI port, placed next to its PHY
slice, and the address slicing that decides *which* port happens in the customer's fabric via
`hbm4_addr_slice` — shipped with the IP and proved equivalent to the controller's own decode
by formal miter.

The 256 ports are the interface, not a convenience. An integrator who aggregates them back
into a switch has undone the thing that makes the design closeable.

---

## Rev 0.8a

**Status: the pseudo-channel slice integrates. 28 modules, all lint-clean.**

### Added — RTL

`hbm4_pc_slice` — the block replicated 256 times, wiring together all 22 leaf blocks: NHI,
address decode, transaction pool, bank state, timing engine, both arbiters, direction FSM,
refresh, DFI adapter, read-pointer FIFO, and link ECC.

### The row-hit logic lives at this level, and could not live anywhere else

Turning "a request exists" into "a command is legal" needs the pool and the bank state
**together**:

| Bank state vs. the head's row | Action |
|---|---|
| ACTIVE on exactly that row | the column command may go |
| IDLE | ACT it, to the head's row |
| ACTIVE on a *different* row | PRE it first |

The pool knows what is wanted; the bank state knows what is open; neither alone can decide.
Offering a bank to the column arbiter without that check would let it read against whatever
row happened to be open — **valid data, wrong address, nothing to detect it.**

### A hang found by lint

`lecc_retry` was unconnected. `hbm4_link_ecc` suppresses `out_valid` while a retry is
outstanding, expecting something to re-issue the read — and **that re-issue path was never
built**. It needs the pool entry to survive past issue so the request can be replayed; the
pool frees on issue.

Left as written, a link uncorrectable would suppress the completion and never replay it: the
transaction never finishes, the host waits forever, no error anywhere.

Retry is now tied off at the slice, so a link UE escalates immediately — less available than
[02 §10.1](02-architecture.md) claims, but correct and visible. Tracked as **OPEN-9**, and
the availability claim needs softening until it closes.

**An unconnected output is worth treating as an error rather than a style warning.** This one
was the difference between a reported error and a silent hang.

### Also at this level

A write completing at issue and a read completing on data return can collide in the same
cycle. The read wins and the write acknowledgement is buffered: read data cannot be
regenerated, whereas a `wack` is only an acknowledgement.

---

## Rev 0.7g

**Status: 27 modules, 21 formal blocks. All leaf blocks complete.**

### Added — RTL

`hbm4_init_seq` — the microcoded PHY training sequencer. ~2500 gates plus a script RAM,
buying the ability to fix a training bug with a **firmware update instead of a metal spin**.
HBM training differs by vendor, by stack revision and by bring-up iteration; a hardwired FSM
will not merely *might* be wrong.

### Two properties, two different disasters

| | Failure mode |
|---|---|
| **P-SEQ-1** never drives the DRAM while the scheduler is live | two drivers on an unarbitrated bus — at best the channel wedges, at worst the wrong row is activated and written |
| **P-SEQ-2** an untrusted script cannot hang boot | a branch to itself or an out-of-range target spins forever, machine unusable, **nothing logged** |

P-SEQ-2 is the one that is easy to skip. Boot code is written once, tends to work, and the
failure surfaces on a customer's bring-up bench with a vendor script nobody here has seen.
The `c_wdog` cover confirms the watchdog path is genuinely reachable, so the property is not
vacuous.

P-SEQ-1 is enforced **structurally** — the quiesce gate is on the `op_valid` output, not
buried in the state machine — so no future FSM edit can reintroduce a bus conflict.

### A real bug, found only by un-rounding a parameter

The proof first used `SCRIPT_DEPTH = 8` with a 3-bit PC. At a power of two the counter
truncation makes every branch target in range **by construction**, so the range check is dead
code — and deleting it survived mutation testing.

Changed to `SCRIPT_DEPTH = 6`, the check became live and immediately failed: **the PC
advanced past the last instruction with no bound test.** A script that runs off the end
fetches out-of-range RAM and executes it as an instruction — an arbitrary-command primitive,
from a script the controller does not control.

Powers of two are a specific hazard for range properties: the widths that feel natural are
exactly the ones that make bound checks vacuous.

**And a third instance in the same block.** `WDOG_LIMIT = 12` with a depth-12 proof means the
watchdog can never fire, so `p_wdog_reports` passed vacuously and deleting the error report
survived mutation testing. Fixed by shrinking the limit to 4 — and, more usefully, by adding
a **guard-reachability cover**: every property with a non-trivial antecedent now needs a
cover proving that antecedent is satisfiable. A property whose guard never fires looks
exactly like a property that holds.

All three are the same mistake in different clothes — a reduced configuration that cannot
reach the state the property is about — and all three were found by mutation testing rather
than by review. Recorded in `formal/SCALING.md`.

### done and error made exclusive by construction

Induction found that `done` and `error` could coexist. Rather than add an invariant, each
terminal path now clears the other: leaving it to an invariant would mean the two *could*
coexist in principle, and a driver reading `done` while `error` is set would report a
successful boot on a stack that never trained.

---

## Rev 0.7f

**Status: 26 modules, 20 formal blocks. All leaf blocks except the init sequencer done.**

### Added — RTL

- `hbm4_csr` — APB4 configuration registers with the **lockable** groups.
- `hbm4_pmgr` — power state management: ACTIVE → CLKGATE → POWERDOWN → SELFREF.

### The CSR lock is the property, not the bus protocol

Four register groups decide where data physically *lives*: address-map mode, the thirteen
hash masks, `ECC_EN`, and the DRAM timing set. Changing any of them while traffic runs does
not fail loudly — it silently relocates where addresses map, so writes land in one place and
later reads look in another. **No ECC error, no interrupt, no symptom except wrong data.**

Proved: a locked register never changes, the lock is one-way (a lock the untrusted bus can
undo is not a lock), and a refused write is reported on **both** channels — `pslverr` and an
interrupt — because an integrator who checks only one still needs to find the driver bug.

### Two anti-vacuity properties

Both blocks needed a property whose only job is to stop the others passing trivially:

- **P-CSR-4** — an *unlocked* write takes effect. Without it, a CSR block that ignores every
  write satisfies every lock property.
- **P-PM-3 / `c_sr`** — low power is actually reachable and actually gated by its enable. A
  power manager that never leaves ACTIVE satisfies every safety property and saves nothing;
  that ships, and comes back as a battery-life bug rather than a correctness one.

### A property restated rather than assumed away

`p_sr_only_idle` was first written combinationally (`sr_req → !busy`) and failed — correctly.
The free environment can raise `busy` while *already in* self-refresh. The real system cannot
reach that (work becomes outstanding only by being issued, and nothing issues from SR), but
assuming it away here would be circular.

Rewritten as a **transition** property — the deep state is never *entered* with work in
flight — it needs no assumption and says what actually matters. Entering SR with an
outstanding read is a **hang**: the DRAM leaves the command bus, the read never completes,
and there is no error, no log entry, and no timeout anywhere in the controller.

---

## Rev 0.7e

**Status: 24 modules, 18 formal blocks. ECC and RAS subsystems complete.**

### Added — RTL

- `hbm4_scrub` — patrol scrub, the background walk that finds single-bit errors while they
  are still single. A block unread for hours can pick up a second one, and SEC-DED then
  reports as uncorrectable what was recoverable yesterday.
- `hbm4_ecc_init` — boot-time initialisation of the ECC region.

### Coverage proved structurally, not by enumeration

Both blocks walk the address space, and for both the property that matters is **complete
coverage** — which cannot be proved by enumerating 2²⁵ blocks.

It is proved from the *step function* instead: if the walk advances by **exactly one
position** in a fixed nested order and wraps only after the last, coverage follows by
induction, because no step larger than one exists. That is the right shape for this class of
property generally.

For scrub, an incomplete walk leaves exactly the regions scrub exists to protect
unprotected — silently, because a skipped block looks identical to a clean one. For init,
`done` released early means the first read of any uninitialised block reports an
**uncorrectable error on perfectly healthy memory**, a fault that looks like failing silicon
and gets chased as such.

### Scrub must also never displace real traffic

P-SCRUB-1 gates the **request**, not merely the grant: the scrubber never even competes for
the row bus while anything else wants it. The rate counter also does not run down while
held off — otherwise a busy period would bank credits and the scrubber would burst
afterwards, which is the displacement the requirement forbids. A scrubber that steals
bandwidth is one that gets disabled in the field, and a disabled scrubber protects nothing.

### A cover deliberately not written

`fv_ecc_init` has no cover for `done`. Reaching it needs a complete sweep — 960 positions at
the reduced formal geometry, 7.9 million at production — beyond any useful BMC depth. Its
reachability follows mathematically from P-INIT-2 (strict enumeration over a finite space).
**A cover that cannot be reached tells you nothing about the design and only makes the run
fail**, so it is documented rather than left in to be ignored.

---

## Rev 0.7d

**Status: 22 modules, 16 formal blocks, 50 mutations / 0 survivors.**

### Added — RTL

- `hbm4_err_log` — RAS log with a **sticky first-error latch**, separate from the FIFO.
- `hbm4_link_ecc` — link ECC check with bounded retry and escalation. It *instantiates* the
  already-proved `hbm4_sys_ecc` codec rather than repeating the coding, so this block is
  purely about retry policy — which is where its properties live.

### Two properties that pull against each other

Link ECC has to satisfy both, and a design meeting only one fails in opposite directions:

| | If violated |
|---|---|
| **P-LECC-1** retry is bounded | unbounded retry on a hard fault (broken lane, dead TSV) is a **livelock** — the host waits forever on a response that never comes, and there is nothing to log |
| **P-LECC-2** an error is never silently dropped | a flagged read reported as success is **silent corruption** |

Both proved, along with "a corrected read is not retried" (spending budget on data that is
already good) and "the data handed on is the *corrected* payload, not the raw one".

### The error log's first-error latch

A real fault arrives as a burst: the failing device produces one, the scrubber then finds the
same region and produces more, and a 16-entry FIFO holds only the last few — which are
*consequences*, not the cause. Proved: the latch survives an unbounded storm, the FIFO drops
**new** entries rather than evicting old ones, and an error that overflows the FIFO can still
become the first error.

### A verification-technique change

`fv_link_ecc` instantiates a **reference codec in the wrapper** instead of reaching into the
DUT hierarchically. Hierarchical references through the sv2v path have been unreliable all
project (five separate workarounds so far), and an independent instance is a better property
anyway: it compares the DUT's reported status against a separately elaborated decode of the
same inputs, rather than against the DUT's own opinion of itself.

---

## Rev 0.7c

**Status: OPEN-8 closed. 14 formal blocks, all green.**

### Fixed — the third and subtlest ECC-cache bug

**A fill whose tag already matched a dirty entry was applied anyway.**

The cache holds check values recomputed by the write path; DRAM holds the stale ones.
Applying that fill overwrote newer data with older *and cleared the dirty bit* — so the
updates were lost with no conflict, no eviction, and no error. Fifteen data blocks silently
keep check bits that no longer match them.

It is **not a conflict**, which is why the two earlier fixes (adding `upd_row`, and making
`upd_stall` respect ack ownership) both left the property failing. A fill is only ever
useful onto a *clean* entry.

`P-EC-2` now proves unbounded, with one strengthening invariant: `dirty ⇒ valid`. From
`dirty && !valid` a fill sees neither a conflict nor a redundancy and clears the dirty bit —
unreachable from reset, but induction starts anywhere.

### The wider point

One property found three independent bugs in one 170-line module, none of which produce a
crash, a timing violation, or a failing test. All three produce *uncorrectable errors on
undamaged data*, appearing long after the cause, on a device that is physically healthy.

This is the case for proving data-retention properties rather than testing them.

---

## Rev 0.7b

**Status: 21 modules, 13 formal blocks. ECC column cache built; two real bugs found in it.**

### Added — RTL

`hbm4_ecc_cache` — resident ECC columns, **direct-mapped by bank index** with no
associativity and no replacement policy. That is exact, not a simplification: a bank has one
open row, each row-half has one ECC column, so there is never more than one ECC block per
bank in flight. The structure is forced by the DRAM.

### Two real bugs, both found by one property

P-EC-2 ("a dirty entry is never replaced without an acknowledged write-back") found:

1. **The update path had no row input.** A write starting a new row-half reused the slot
   *without eviction* — discarding a dirty block — and left an inconsistent tag: old row,
   new row-half. Fixed: `upd_row` added, and updates now take the same eviction protocol as
   fills.
2. **`upd_stall` checked the global `evict_ack` without asking whose eviction it was.** A
   fill conflict takes priority, so when a fill and an update conflicted on *different*
   banks, the fill's acknowledgement let the update through — clobbering a dirty entry that
   was never written back.

Either one loses the check bits for **15 data blocks at once**, and the symptom is an
uncorrectable-error storm on data that was never damaged.

### P-EC-2 itself is DISABLED, not claimed

A residual case still fails and I have not isolated it. The property is disabled and tracked
as **OPEN-8 — the highest-priority open item in the project** — rather than reported as
proved. The other three ECC-cache property groups and all seven covers pass.

### Also fixed

A false combinational loop: `evict_row = ent_row[ev_bank]` where `ev_bank` depended on
`ent_row[fill_bank]` makes a memory read port whose *address* depends on another read of the
same array. Yosys models the array as one cell and reports a loop. Reading both candidates
at fixed addresses and muxing the results is equivalent and analysable.

---

## Rev 0.7a

**Status: 17 modules, 24/24 formal tasks PASS. ECC codec built and proved.**

### Added — RTL

`hbm4_sys_ecc` — inline system ECC codec, Hsiao SEC-DED(266,256).

Every column of the parity-check matrix is a distinct 10-bit value of **odd** weight
(weight ≥ 3 for data columns). Two things fall straight out, and they are the whole reason
for that choice:

- a single-bit error gives an **odd**-weight syndrome, which matches exactly one column, so
  it is located and corrected;
- a double-bit error gives an **even**-weight syndrome, which can never equal any column, so
  it is detected and **never miscorrected**.

Miscorrection is the failure that matters. A code that "corrects" a double error writes back
data it has just made wrong, reports success, and the patrol scrubber then spreads it.

### An overclaim corrected downward

Revisions before 0.7 described this as a **(272,256) single-4-bit-symbol-correcting** code.
**It is SEC-DED.** Symbol correction needs GF(16) syndrome decoding and a Chien search.

The difference is real: a fault confined to one x4 device produces a 4-bit burst inside one
symbol. A symbol code rides through it; SEC-DED detects it and reports uncorrectable. **Data
is not silently corrupted either way** — the block is poisoned and reported — but
availability is lower. Tracked as **OPEN-7**; docs 01, 02 and 08 corrected to match the
implementation rather than the other way round.

### Verified

| | |
|---|---|
| clean round trip exact; single-bit corrected; double-bit detected, never miscorrected | proved (`fv_sys_ecc`) |
| H-matrix: 256 distinct odd-weight columns, all weight ≥ 3 | exhaustive at full width |
| **all 32 640 double-error syndromes even** ⇒ cannot alias a column | exhaustive at full width |

The 256-bit codec is beyond SAT at full width, so behaviour is proved at 32 bits and the
*structural* invariants that make SEC-DED hold are checked exhaustively at 256 by
`tools/check_hmatrix.py`. The construction is generic; the properties depend only on those
invariants.

### Read-FIFO assumptions removed

`fv_rd_ptr_fifo` originally assumed the adapter never pushes when full or pops when empty —
which made the RTL's guards unreachable, so **deleting them survived mutation testing**. The
same trap as A5 in `fv_refresh`. Assumptions removed; the FIFO is now proved robust against
a PHY whose round trip exceeds `RD_FIFO_DEPTH`, which is a real integration case. Both
mutations are now caught.

---

## Rev 0.6f

**Status: DFI path complete. 10 blocks proved unbounded, 2 BMC-clean.**

### Added — RTL

- `hbm4_rd_ptr_fifo` — in-flight read tracking. The controller issues a column read; the
  data returns some PHY-decided number of cycles later. Pushing the pool index at issue and
  popping on `dfi_rddata_valid` means **read latency is never hardcoded** — it is measured
  at training and differs per PHY, per frequency, and after every DVFS retrain.
- `hbm4_dfi_adapter` — command formatting onto the two CK phases, plus read-data routing.

### On phase selection — documented as degenerate rather than built speculatively

[03-interface-spec.md](03-interface-spec.md) §2.6 describes choosing the CK phase that
satisfies tCCD_S. At the shipped configuration that is a **constant**: tCCD_S = 2 tCK = one
core clock, so back-to-back column commands must stay on the *same* phase. Alternating would
give 1 tCK and 3 tCK alternately — and 1 tCK violates tCCD_S outright.

It is a parameter (`COL_PHASE`) rather than hardwired, and becomes real logic if BL16 is
confirmed or the gearing changes. Building the tracking machinery now would be speculative
complexity in the block least able to afford it.

### Formal

| Property | Result |
|---|---|
| **P-DFI-1** level accounting, bounds, empty/full flags | ✅ proved unbounded |
| **P-DFI-2** order preservation (arbitrary tracked pair) | ✅ BMC-clean, depth 12 — see OPEN-6 |
| covers: full, drain, simultaneous push/pop, tracked pair pops | ✅ all reachable |

The order property is written the way order properties should be: track an arbitrary *pair*
of pushes and require them to emerge in the same relative order **carrying their own
values**. A weaker "something came out" check passes on a FIFO that reverses everything.

---

## Rev 0.6e

**Status: front-end complete. 9 blocks proved unbounded, 1 BMC-clean.**

### Added — RTL

`hbm4_nhi_target` — Native Host Interface endpoint: credit accounting, tag pass-through,
and a one-deep response skid buffer.

### Added — formal

`fv_bank_state` (P-ST-*) and `fv_nhi_target` (P-NHI-*), both proved unbounded.

| Property | Result |
|---|---|
| **P-ST-2/3** every close path closes; ACT records its row | ✅ proved unbounded |
| **P-ST-5** row-bus and column-bus effects both land in the same cycle | ✅ proved unbounded |
| **P-NHI-1** credit conservation; outstanding never exceeds `TQ_DEPTH` | ✅ proved unbounded |
| **P-NHI-4** a response is never withdrawn or mutated under back-pressure | ✅ proved unbounded |
| **P-NHI-5** the credit accompanies the response *leaving*, not arriving | ✅ proved unbounded |

### Fixed

**Outstanding-count underflow.** A completion arriving with nothing outstanding decremented
the counter to all-ones, which then reads as a hugely over-subscribed pool and **wedges
credit return permanently** — a deadlock, from a transient upstream fault. Now saturating
both ways.

### Verification-harness fixes

Two "survivors" in this revision were harness defects, not property holes, and both are
worth recording because each cost a real debug cycle:

1. **A mutation aimed at a proof that could not see it.** The bank-state mutation targeted
   the `timing` proof, which does not compile `hbm4_bank_state`. It had no effect and
   "survived". Now targets `bankst`.
2. **A concurrent build clobbered the mutated source.** Running the regression alongside
   `mutate.sh` overwrote the injected bug mid-run. `mutate.sh` now takes a lock.

A mutation that survives for a mechanical reason is worse than no mutation at all — it reads
as a verification gap and sends you hunting for one.

---

## Rev 0.6d

**Status: OPEN-2 closed. Every command the scheduler can issue is now formally in scope.**

### Fixed — a serious bug found by closing OPEN-2

**Auto-precharge was not tracked by the timing engine at all.**

`COL_RDA`/`COL_WRA` close the bank *internally*. No row command is issued, so nothing on the
row bus records the precharge — and `n_act` was only ever loaded by row commands. The next
ACT to that bank was legal immediately, violating tRTP+tRP.

**`PAGE_POLICY = CLOSE` would have violated DRAM timing on every access.** It is one of the
five documented address-map modes, and the one [07-performance-guide.md](07-performance-guide.md)
recommends for random-access workloads.

The first fix was *also* wrong, and formal caught that too: it combined the row-bus and
column-bus constraints as a **priority chain** rather than a **max**. With a PRE and an
auto-precharging RDA on the same bank in one cycle, the chain dropped whichever lost — and
`t_rda` (tRTP+tRP) exceeds `t_rp`, so the dropped one was binding.

Related: `hbm4_bank_state` now applies row-bus and column-bus effects **independently**.
An `if/else` across the two buses would drop a command, because constraint C3 says both
issue in the same cycle.

### Added

- `t_rda` / `t_wra` timing CSRs — auto-precharge to next ACT, firmware-precomputed for the
  same reason the turnaround values are: the arithmetic belongs in firmware so DVFS stays a
  register swap.
- **P-TIM-15** (tRFM), **P-TIM-16/17** (auto-precharge), plus covers `c_rfm`,
  `c_auto_precharge`, `c_act_after_ap`.

### Assumptions

**A4 no longer exists** — nothing is assumed away in the timing engine. Remaining: **A1**
(reset), discharged only by the Rev 0.8 testbench.

---

## Rev 0.6c

**Status: every assumption the scheduler-core proofs rest on is now discharged.**

### Added — formal

`fv_row_arb` — the row bus half of the arbiter contract, plus the two priority claims the
architecture makes about refresh.

| Property | Result |
|---|---|
| **P-ROW-1/2** ACT and PRE only when the timing engine cleared them | ✅ proved unbounded |
| **P-ROW-3** ack implies req; ack matches the issued command | ✅ proved unbounded |
| **P-ROW-4** an ACT opens the row the requester asked for | ✅ proved unbounded |
| **P-ROW-5** an urgent refresh always wins the bus | ✅ proved unbounded |
| **P-ROW-6** RFM beats PRE and ACT | ✅ proved unbounded |
| **P-TIM-14** tRFC — no ACT within tRFC of a REFsb to the same bank | ✅ proved unbounded |
| covers incl. `c_act_beats_ref`, `c_act_after_refresh` | ✅ all reachable |

### Assumptions discharged

| | Before | Now |
|---|---|---|
| **A2** arbiters obey the ready vectors | column half only | ✅ **fully discharged** — both buses |
| **A7** no activate to a refreshing bank | partial | ✅ **discharged** |
| **OPEN-2** refresh outside the property set | open | **mostly closed** — REFsb in scope with tRFC proved; RFM and auto-precharge remain |

A7 is discharged in a way worth noting: tRFC is enforced by the timing engine's own `t_act`
counter, **independently of the `refresh_block` vector**. `refresh_block` is redundant
protection rather than the mechanism, so the assumption does not rest on two modules
agreeing about a shared signal.

### Remaining assumptions

**A1** (reset behaviour) — still assumed in seven proofs, discharged only by the Rev 0.8
testbench. **A4** narrowed to RFM and auto-precharge. **A3** discharged in Rev 0.5.

---

## Rev 0.6b

**Status: refresh engine and RFM complete and proved. Scheduler core feature-complete.**

### Added — RTL

`hbm4_refresh` — per-bank refresh (REFsb) with ±8 credit slack, opportunistic scheduling,
graded urgency, and per-bank RAA row-hammer counters driving RFM.

### Formal results

| Property | Result |
|---|---|
| **P-REF-1** debt stays within the JEDEC ±8 slack | ✅ proved unbounded |
| **P-REF-3** refresh/RFM never issued to a busy bank | ✅ proved unbounded |
| **P-REF-4** one row command per clock | ✅ proved unbounded |
| **P-RFM-1** mitigation is always requested when a bank is hammered and free | ✅ proved unbounded |
| covers: opportunistic, urgent, blocked, RFM, behind-schedule | ✅ all reachable |
| Mutation coverage | **24 mutations** |

### Fixed — a real RTL bug found by formal

**RFM bank selection masked hammered banks.** The selector picked the highest-indexed bank
over the threshold and *then* checked whether it was free. A hammered bank that happened to
be mid-refresh therefore masked every other hammered bank, so the RFM request never fired
for any of them — **row-hammer mitigation silently stopped while the counters kept
climbing**. No functional symptom; the failure mode is neighbouring-row corruption under a
specific access pattern. Now the selector only considers banks that are free.

### Removed — two assumptions that were load-bearing for nothing

A5 (urgent refresh always granted) and A6 (RFM granted promptly) were deleted. They existed
only to support an RAA bound that was replaced by a property needing no grant assumption.
`fv_refresh` is now strictly stronger — proved against a completely unconstrained arbiter —
and the JEDEC saturation guard became reachable, which is what lets mutation testing reach
it. With A5 present, deleting that guard survived mutation.

### A recurring defect class, now documented

**Property arithmetic that silently wraps** — twice: `ROW_W'(N_ROW)` truncating to 0, and
`cfg_rfm_thresh + 8'd1` overflowing at threshold 255. Both made a check read `x <= 0`. Both
failed loudly; one that wrapped the other way would pass vacuously forever. Recorded in
[`formal/ASSUMPTIONS.md`](../formal/ASSUMPTIONS.md).

### Open items

**OPEN-2 narrowed** — the refresh engine is proved; the timing engine's handling of
REF/RFM/auto-precharge commands is still assumed away (A4). **OPEN-5 added** — the RAA
overshoot bound depends on how long the row arbiter can defer RFM, so it belongs to a
system-level proof and is left unstated rather than guessed at.

---

## Rev 0.6a

**Status: write buffer and RAW hazard complete and proved.**

### Added — RTL

`hbm4_wbuf` — write buffer, write coalescing, and the two-tier read-after-write hazard
check. A flat CAM over WBUF_DEPTH tags at 1 GHz across 256 pseudo-channels would be ~30 W
of search power, so tier 1 is a cheap HAZ_HASH_W-bit hash compare every cycle and tier 2 an
exact tag compare only on a tier-1 hit (~3% of accesses).

Also adds packed `dbg_*` observability outputs. These exist for silicon debug **and**
because Yosys cannot width-resolve a variable index into an *unpacked* array through a
hierarchical reference — a formal wrapper needs packed mirrors to build a reference model.

### Formal results

| Property | Result |
|---|---|
| **P-WB-1** two-tier hazard has no false negatives | ✅ proved unbounded |
| **P-WB-2** forwarding only from a full-coverage entry | ✅ proved unbounded |
| **P-WB-3** coalescing never creates duplicate entries | ✅ proved unbounded |
| **P-WB-4** `wr_ready` tracks occupancy | ✅ proved unbounded |
| covers: hazard, forward, partial, coalesce, full | ✅ all reachable |
| Mutation coverage | **20 mutations, 0 survivors** |

### Notes

- **k-induction needed a strengthening invariant** (`p_hash_matches_tag`: every valid
  entry's stored hash matches its stored tag). Basecase passed without it; induction did
  not, because it starts from a state the design cannot reach. Exactly the step
  [06 §4.8](06-verification-plan.md) budgets for.
- One mutation was found to be genuinely **equivalent** and is instructive: dropping tag
  bit 0 from the tier-2 compare changes nothing, because bit 0 is folded into the tier-1
  hash, so the two tiers together are still an exact test. Replaced with a mutation that is
  unambiguously a defect (skipping tier 2 entirely), which is caught.

---

## Rev 0.5

**Status: scheduler core complete and proved; OPEN-1 closed.**

### Added — RTL

`hbm4_txn_pool` — transaction storage and per-bank, per-direction scheduling lists. Filing
is free (the address map picks the bank), only the 32 list heads are arbitration candidates,
and head fields are mirrored so the arbiters never index the entry array.

### Changed — the bank-group bias tier was DELETED

`hbm4_col_arb` had a priority tier preferring a different bank group from the last issue.
**It was redundant.** `hbm4_timing_engine` loads `t_ccdl` on every column command, so banks
in the just-used bank group are not marked ready until tCCD_L has elapsed — every candidate
the arbiter could see was already legal. True for any tCCD_L, not just the baseline device.

It was also actively harmful: it could exclude a ready bank from the selected tier, so the
rotating pointer swept past without granting. That destroyed the round-robin starvation
bound and forced the fairness claim to be withdrawn in Rev 0.4.

Deleting it **closed OPEN-1**, removed the `last_bg` register, and dropped one priority
encoder from the critical path of the design. Trying to *prove* a claimed property is what
exposed the redundancy.

### Formal results

| Proof | Rev 0.4 | Rev 0.5 |
|---|---|---|
| P-MAP-4 divider exactness | proved unbounded | proved unbounded |
| P-MAP-2/3 decode equivalence, range faults | proved unbounded, full geometry | unchanged |
| P-TIM-1..13 all JEDEC timing | proved unbounded, full geometry | unchanged |
| P-BUS-1 one column command per clock | proved unbounded | unchanged |
| **P-LIVE-1 starvation bound** | ⚠️ disabled, OPEN-1 | ✅ **proved unbounded**, `starve < N_BANK` |
| **P-QOS-1 urgent tier honoured** | — | ✅ **proved unbounded** (new) |
| **P-POOL-2/3/5 pool invariants** | — | ✅ **BMC clean**, all covers reachable |
| Mutation coverage | 13, 0 survivors | **16, 0 survivors** |

### Fixed — found by proving

| # | Finding | Found by |
|---|---|---|
| 7 | **A property with no teeth**: deleting the QoS urgent tier entirely survived mutation. The safety properties were all satisfied by a plain round-robin ignoring QoS. Added P-QOS-1. | `mutate.sh` |
| 8 | **A fairness counter that conflated two regimes**: it accumulated pass-overs across urgent phases, but an urgent grant moves the pointer without decreasing rotational distance. It reported a bound the arbiter never claimed. | proof failure |
| 9 | **`ent_wr` was stored and never read** — direction is implied by which list an entry is in. 16 kbit of duplicated state, and a second source of truth. Removed. | Verilator lint |
| 10 | **`sv2v` mis-converts `if (c) assume(a); else assume(b);`** into `assume(a) else assume(b)`, which Yosys rejects. Second sv2v trap after the silent `-E Assert` stripping. | proof error |

### Known limitations

- **A3 discharged; A1 still open** (needs the Rev 0.6 testbench). OPEN-2 (refresh/RFM/auto-
  precharge properties) and OPEN-4 (pool is BMC-bounded, not proved) remain.
- Write buffer, ECC codec + cache, refresh engine, NHI, DFI adapter, CSR block, init
  sequencer, and the top-level integration are **not yet written**.
- No simulation environment yet — no DRAM model, no timing checker, no traffic generators.

---

## Rev 0.4

**Status: first RTL, and the first proofs that actually run.** Address path and scheduler
core implemented, lint-clean, and formally verified with an entirely open-source flow.

### Added — RTL

`rtl/` — 10 modules, all lint-clean at `verilator -Wall`:

| Path | Module |
|---|---|
| `pkg/` | `hbm4_pkg`, `hbm4_timing_pkg` |
| `fabric/` | `hbm4_hash`, `hbm4_addr_slice` |
| `fe/` | `hbm4_divc`, `hbm4_addr_decode` |
| `core/` | `hbm4_timing_engine`, `hbm4_bank_state`, `hbm4_rr_arb`, `hbm4_col_arb`, `hbm4_row_arb`, `hbm4_dir_fsm` |

### Added — formal

`formal/` — SymbiYosys via sv2v, Yices 2. Results:

| Proof | Result |
|---|---|
| P-MAP-4 divider exactness | **PROVED UNBOUNDED**, all 2^20 inputs |
| P-MAP-2/3 fabric ≡ controller decode, range faults | **PROVED UNBOUNDED at full geometry** |
| P-TIM-1..13 every JEDEC timing parameter incl. tFAW | **PROVED UNBOUNDED at full geometry** |
| P-BUS-1 one column command per clock | **PROVED UNBOUNDED** |
| Covers: back-to-back column, ACT+RD same cycle, both range outcomes | **all reachable** |
| `mutate.sh` mutation coverage | **13 mutations, 0 survivors** |

Plus `ASSUMPTIONS.md` (audit, 4 assumptions, 3 open items) and `SCALING.md`.

### Decided

**Burst length: BL8 / 32 B**, on three grounds now recorded in
[08 §4.2](08-compliance-matrix.md). Fully parameterised — the DFI datapath is 256 b/clk
either way, so BL16 is a parameter edit and a re-proof, not a redesign.

### Fixed — found by implementing and proving

| # | Finding | Found by |
|---|---|---|
| 1 | **Address decode silently aliased out-of-range addresses onto real rows.** The quotient needs 16 bits but `ROW_W` is 15; truncating mapped illegal addresses onto legal ones. Now faults via `out_range_err`. | Verilator lint |
| 2 | **Timing counters were loaded with N instead of N-1**, costing one cycle per event. At tCCD_S = 1 that halves column throughput — 50% of peak bandwidth — while violating no timing parameter, so it is invisible to a timing checker. | Hand trace, then locked in by the `c_back_to_back_col` cover |
| 3 | **`sv2v` silently discards all assertions** without `-E Assert`. Every proof reported PASS with zero assertions in the model. | `mutate.sh` |
| 4 | **A property called the function it was testing** (`bank_of`), so it mutated along with the RTL and proved nothing. | `mutate.sh` |
| 5 | **A property constant truncated to zero**: `ROW_W'(N_ROW)` is `3'(8) = 0`, so the check read `row < 0`. | proof failure |
| 6 | **The reduced formal geometry was too small to reach tFAW** — 4 banks cannot produce 5 activates in a window, so deleting tFAW entirely survived mutation. Now 8 banks. | `mutate.sh` |

### Changed

- **`div30` is pipelined over 2 stages**, so E1 became E1a/E1b. A 20×21 multiply does not
  close at 1 GHz in one stage. Idle read latency is **33 ns, not 32**; controller-attributable
  portion is 10 clocks, not 9. Propagated through docs 01, 02, 07.
- **The round-robin starvation bound claim was withdrawn.** §8.7 previously claimed "≤ 31
  issue slots" — the bound for *plain* round-robin. The bank-group bias can exclude a ready
  bank from the selected tier, and BMC finds pass-overs beyond 4·N_BANK. The property is
  **disabled and tracked as OPEN-1**, not weakened until it passes.

### Known limitations

- Transaction pool, write buffer, ECC codec, NHI, DFI adapter, refresh engine: **not yet
  written** (Rev 0.5–0.6).
- Refresh, RFM and auto-precharge command paths are outside the property set (OPEN-2).
- Assumptions A1 and A3 are assumed but not yet discharged elsewhere (OPEN-3).
- `yosys-slang` was not available; the documented `sv2v` fallback is in use. Yosys's built-in
  frontend cannot parse user types inside packed structs.

---

## Rev 0.3

**Status: architecture and verification-plan release. RTL not yet written.**

Complete and reviewable: architecture, all interfaces, CSR map, verification plan, figures,
timing diagrams, integration and programming guides.

### Added

- **Documentation restructured into a 10-document set** for external delivery, with reading
  paths by role ([README](README.md)).
- **14 block diagrams as `.drawio.svg`** — render as images in Markdown and open editable in
  diagrams.net or the VS Code draw.io extension. Regenerate with `tools/gen_figures.py`.
- **11 timing diagrams** with WaveDrom `.json` sources plus committed SVG, covering NHI
  (read, out-of-order, write, credits), DFI (steady state, bank-group penalty, turnaround,
  refresh), internal pipeline, ECC column access, and APB.
- **[06-verification-plan.md](06-verification-plan.md)** — full open-source flow: SymbiYosys
  formal (≈60 named properties across 9 blocks) and Verilator + cocotb simulation.
- [01-product-overview.md](01-product-overview.md), [04-programming-guide.md](04-programming-guide.md),
  [05-integration-guide.md](05-integration-guide.md), [07-performance-guide.md](07-performance-guide.md),
  [08-compliance-matrix.md](08-compliance-matrix.md), [A-glossary.md](A-glossary.md).
- Architecture document rewritten to be self-teaching: DRAM background, "Why?" boxes on every
  significant decision, and explicit "common misconception" warnings.

### Changed

- Architecture doc is now `02-architecture.md` (was `hbm4_controller_uarch.md`).

### Known limitations

- No RTL. Module hierarchy is specified ([02 §17](02-architecture.md)) but not implemented.
- Every timing value is a placeholder — see [08 §4](08-compliance-matrix.md).
- The formal scaling argument ([06 §4.8](06-verification-plan.md)) rests on a structural
  review, which is the weakest link in the assurance chain. Stated explicitly rather than
  papered over.
- No CDC tool exists in the open-source flow. Mitigated architecturally (two crossings), not
  by tooling.

---

## Rev 0.2

### Added

- **Multi-stack support.** `N_STACK` parameter (baseline 4), top-level supervisor, stack
  bits added at the bottom of the address map, global refresh phasing across all stacks,
  `STACK_ILV` modes (`FINE` / `MEDIUM` / `NUMA`).

### Changed — behavioural, read carefully

| # | Change | Driver |
|---|---|---|
| 1 | **Inline system ECC relocated to reserved columns in the same row.** Rev 0.1 placed the ECC block in a different *row* of the same bank. Since a bank has one row buffer, every ECC fetch would have precharged the row being streamed and re-activated it: ~60 ns each, ~12.5% overhead, double the ACT rate against tFAW. | ECC becoming default-on turned a latent flaw in an optional path into the dominant cost |
| 2 | Column count is 30 (not 32) when ECC is on; a constant `div30` was added to controller address decode. `HBM4_ADDR_SLICE` stays pure bit-select. | consequence of 1 |
| 3 | ECC column cache became direct-mapped by bank index — no tags, no replacement policy | consequence of 1 |
| 4 | `SYSECC_EN` default 0 → **1** | decision |
| 5 | `WBUF_DEPTH` 64 → **128**; turnaround loss 5.9% → 3.0% | decision |
| 6 | NHI made **synchronous** to `clk_core`; 512 async FIFOs removed; CDC surface reduced to two crossings | decision |
| 7 | Write-buffer hazard check changed from a flat 128-entry CAM to a two-tier hashed structure (~30 W of search power avoided) | consequence of 5 |

### Fixed

- **§5 per-PC bit budget was wrong in Rev 0.1.** It stated `ROW + SID + 5 + 5 = 30`, omitting
  the 5 bank bits and double-counting the byte offset. Correct:
  `ROW + SID + BG + BA + COL = 25`. If you hold a copy of Rev 0.1, discard its §5 arithmetic.

---

## Rev 0.1

Initial architecture baseline: single stack, ECC optional and off by default,
`WBUF_DEPTH`=64, asynchronous NHI, address slicing in the fabric.

**Superseded. Do not use** — it contains the ECC placement flaw (Rev 0.2 change 1) and the
§5 arithmetic error.

---

## Upgrade notes

### 0.4 → 0.5

Additive RTL plus one behavioural change: the column arbiter's bank-group bias tier was
removed as redundant. No interface, CSR or address-map change. The architecture doc's
starvation bound is restored to ≤ N_BANK-1 and is now proved.

### 0.3 → 0.4

Documentation and additive RTL. Three doc-visible corrections: idle read latency 32 → 33 ns,
the round-robin starvation bound withdrawn, and burst length moved from open question to
decided. No interface or CSR changes.

### 0.2 → 0.3

Documentation only. No RTL, CSR, or interface changes. Update document references:
`hbm4_controller_uarch.md` → `docs/02-architecture.md`.

### 0.1 → 0.2

**Breaking.** Do not attempt an in-place upgrade.

- Address map changed: stack bits added, column count 32 → 30 with ECC on. **Existing memory
  contents are not readable under the new map.**
- Usable capacity per stack changed from 64 GB to 60 GB.
- NHI clocking changed from asynchronous to synchronous — fabric integration must be revisited.
- `WBUF_DEPTH` default changed; re-run area and power estimates.

---

## Roadmap

| Rev | Contents |
|---|---|
| ~~0.4~~ | ~~RTL skeleton~~ — **done**, and went further: timing engine and arbiters are implemented and proved |
| ~~0.5~~ | ~~Transaction pool~~ **done**; OPEN-1 closed, A3 discharged |
| ~~0.6a~~ | ~~Write buffer + RAW hazard~~ **done**, proved unbounded |
| ~~0.6b~~ | ~~Refresh engine + RFM~~ **done**, proved unbounded; OPEN-2 narrowed |
| ~~0.6c~~ | ~~Row-arbiter proof~~ **done**; A2 and A7 discharged, OPEN-2 mostly closed |
| ~~0.6d~~ | ~~RFM + auto-precharge properties~~ **done**, OPEN-2 closed |
| ~~0.6e~~ | ~~NHI target~~ **done**, proved unbounded |
| ~~0.6f~~ | ~~DFI adapter + read-pointer FIFO~~ **done** |
| ~~0.7a~~ | ~~ECC codec~~ **done**, proved |
| ~~0.7b~~ | ~~ECC column cache~~ **done**; OPEN-8 raised |
| ~~0.7c~~ | ~~Close OPEN-8~~ **done** — three bugs fixed, P-EC-2 proved |
| ~~0.7d~~ | ~~Error log + link ECC~~ **done**, proved |
| ~~0.7e~~ | ~~Scrub + ECC init~~ **done**, proved |
| ~~0.7f~~ | ~~CSR block + power manager~~ **done**, proved |
| ~~0.7g~~ | ~~Init sequencer~~ **done**, proved. All leaf blocks complete. |
| ~~0.8a~~ | ~~PC slice integration~~ **done**, lint-clean |
| ~~0.8b~~ | ~~Stack + system integration~~ **done** |
| ~~0.8c~~ | ~~Boot script ROM~~ **done**; full system elaborates and boots |
| ~~0.9~~ | ~~cocotb env, DRAM model, timing checker~~ **done** |
| ~~1.0~~ | ~~OPEN-10, A1, synthesis, performance~~ **done**; see remaining below |
| 0.6 | Full PC slice, NHI, DFI adapter, L1 simulation environment, DRAM model + independent timing checker |
| 0.7 | Multi-stack integration, boot sequencer, L3 environment |
| 0.8 | Performance correlation against Ramulator 2; tuning defaults finalised |
| 1.0 | All (P) values replaced, full signoff criteria met ([06 §6](06-verification-plan.md)) |

---

## Support

| Question | Document |
|---|---|
| "How do I connect this?" | [05-integration-guide.md](05-integration-guide.md) |
| "How do I program it?" | [04-programming-guide.md](04-programming-guide.md) |
| "Why is my bandwidth low?" | [07-performance-guide.md §4](07-performance-guide.md) |
| "What does it support?" | [08-compliance-matrix.md](08-compliance-matrix.md) |
| "How do I re-verify my config?" | [06-verification-plan.md §10](06-verification-plan.md) |
| "What does this word mean?" | [A-glossary.md](A-glossary.md) |
