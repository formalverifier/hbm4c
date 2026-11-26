# Formal Scaling Argument

**Rev 1.4** · reviewed at each signoff (verification plan criterion S5). Rev 1.4 added §5b and
updated the counts and the coverage table.

Proofs run at reduced geometry (`FV_SMALL`). This document is the argument that results at
that scale say something about production silicon.

**It is the weakest link in the assurance chain, and it is stated as such rather than
presented as equivalent to a full-scale proof.**

---

## 1. The two configurations

| | `FV_SMALL` (proof) | Production |
|---|---|---|
| `N_STACK` | 2 | 4 |
| Bank groups | 2 | 4 |
| Banks per group | **4** | 8 |
| Banks per PC | **8** | 32 |
| Columns per row | 16 (15 data + 1 ECC) | 32 (30 data + 2 ECC) |
| Rows per bank | 8 | 32768 |
| `TQ_DEPTH` | 4 | 64 |
| Timing values | `small_timing()` | `default_timing()` |

Selected by `-DFV_SMALL`, which switches the geometry inside `hbm4_pkg` so **every derived
width, type and field offset shrinks consistently**. There is no separate small-scale RTL.

---

## 2. What the reduced geometry must preserve

A property proved at a scale where it cannot be violated is worth nothing. The reduced
configuration therefore keeps every structural relationship the properties depend on:

| Preserved | Why it matters |
|---|---|
| More than one bank group | otherwise `tCCD_L` vs `tCCD_S` collapses and C2 is untestable |
| More than one bank per group | otherwise per-bank and per-group timing are the same thing |
| **≥ 5 banks** | see §3 — fewer makes `tFAW` unreachable |
| Non-power-of-two data column count (15) | keeps the `div15`/`div30` path real, not a bit-select |
| **Non-power-of-two `SCRIPT_DEPTH` (6)** | see §3 — a power of two makes the PC range check dead |
| An out-of-range region (`rem` 120–255 of 8 bits) | keeps the range-fault path reachable |
| `tRC > tRAS > tRCD`, `tCCD_L > tCCD_S` | the orderings the properties actually exercise |

---

## 3. A finding: 4 banks was too small, and only mutation testing said so

The first `FV_SMALL` used 2 bank groups × 2 banks = **4 banks**. Every proof passed.

But `tFAW` is violated only by five activates inside one window, and five activates need
five **distinct** banks — re-activating a bank costs `tRC`, which is longer than `tFAW`. At
four banks the constraint is unreachable, so:

- every `tFAW` property passed **vacuously**, and
- deleting the entire `tFAW` mechanism from the RTL **survived mutation testing**.

The geometry is now 2 × 4 = 8 banks, at which
`ACT b0(bg0) b1(bg1) b2(bg0) b3(bg1) b4(bg0)` spans 4 cycles against `tFAW = 6` and the
constraint bites. The mutation is now caught.

### A second instance: powers of two hide range checks

`fv_init_seq` first used `SCRIPT_DEPTH = 8` with a 3-bit program counter. At a power of two
the counter truncation makes **every** branch target in range by construction, so the range
check is dead code — and deleting it survived mutation testing.

Changed to `SCRIPT_DEPTH = 6`, the check became live and immediately exposed a real bug: the
PC advanced past the last instruction without any bound test, so a script that ran off the
end would fetch out-of-range RAM and **execute it as an instruction** — an arbitrary-command
primitive from a firmware-supplied script.

**Powers of two are a specific hazard for range properties.** Widths chosen to be "natural"
are exactly the ones that make bound checks vacuous.

### A third instance: a threshold larger than the proof depth

`fv_init_seq` set `WDOG_LIMIT = 12` and proved to depth 12. The watchdog can therefore never
fire inside the proof, so `p_wdog_reports` never had its antecedent satisfied — it passed
**vacuously**, and deleting the error report survived mutation testing.

With `WDOG_LIMIT = 4` the guard is reachable and the mutation is caught.

**The general defence, now applied everywhere:** every property with a non-trivial antecedent
gets a *guard-reachability cover* (`c_wdog_fires` here) asserting that the antecedent is
actually satisfiable. A property whose guard never fires is indistinguishable from a property
that holds, and only the cover tells them apart.

All three instances are the same mistake wearing different clothes: **a reduced configuration
that cannot reach the state the property is about.**

**The lesson generalises: a reduced configuration is only valid if every property is
reachable in it, and reachability is not obvious by inspection.** Two defences:

1. Every property file carries `cover` statements for the states it depends on
   (`c_back_to_back_col`, `c_out_range`, `c_passed_over`, …). An unreachable cover fails the
   build.
2. `mutate.sh` requires each injected bug to be caught. An unexplained survivor means either
   a property hole or a scale that is too small — both are findings.

---

## 4. Why small-scale results should transfer

**First, a correction in the design's favour.** This section originally assumed reduced
scale was necessary for every proof. Measured, it is not:

| Proof | Reduced geometry | **Full production geometry** |
|---|---|---|
| `divc` (P-MAP-4) | `prove` PASS | `prove` PASS — always ran at W=20/D=30 |
| `addrmap` (P-MAP-2/3) | `prove` PASS | **`prove` PASS** (~2 min) |
| `timing` (P-TIM-*) | `prove` PASS | **`prove` PASS** (~1.5 min) |

The address path and the timing engine **prove unbounded at 32 banks, 32768 rows and 38-bit
addresses**. For those blocks the scaling argument below is not load-bearing at all — there
is no gap to bridge.

`FV_SMALL` is retained because it runs in seconds rather than minutes, which is what makes
`mutate.sh` viable as a per-push gate — 77 mutations across 21 blocks is only tractable at
reduced scale. (The full-scale timing and address-map proofs still close: re-run with
`FV_DEFINES=` for Rev 1.4, both pass unbounded at production geometry in under four minutes.)

The three legs below apply to blocks that cannot close at full scale: as of Rev 0.7g those
are the transaction pool, the read-pointer FIFO, the ECC codec and link ECC, all of which are
dominated by wide datapaths rather than deep state.

Three legs, in decreasing order of strength.

### 4.1 Parameter-driven RTL (strong)

No module special-cases a small count. Every structure is a `for` loop over `N_BANK`,
`N_BG`, or a `generate`. The scaling parameters appear only as loop bounds and width
expressions, never in a comparison or a case arm. Verified by inspection at each signoff —
`grep` for numeric literals against the geometry parameters is part of the review.

### 4.2 Full-scale BMC (medium)

**Rev 1.4: this leg does not exist as described.** `FV_DEFINES=` only changes the geometry the
RTL is built at; each `.sby` keeps its own modes (`prove`, `bmc`, `cover`) and depths, and
nothing runs a full-scale BMC at depth ≥ 40. What has been run at production geometry is the
timing-engine and address-map proofs, in their `prove` mode, both passing unbounded. The rest of
this paragraph is the intent.

A full-scale `mode bmc` run of every proof would catch anything genuinely width-dependent: a
truncation, an overflowing counter, a field offset that only misbehaves at a larger width. It
does **not** prove absence of deep bugs — that is what the small-scale unbounded proof is for.
For the one width bug this project has had (§5b), production-geometry lint caught it.

> The two legs are complementary, and neither alone is sufficient. Small-scale `prove` gives
> depth without width; full-scale `bmc` gives width without depth.

### 4.3 Structural review (weak — the acknowledged gap)

The remaining step is a human argument that nothing about 32 banks differs qualitatively
from 8. It is a signoff checklist item, it is subjective, and it is where an escape would
most plausibly hide.

**This is stated plainly rather than dressed up.** A reader should treat "proved at reduced
scale" as materially weaker than "proved", and the honest summary of this project's formal
status is: *the timing engine and address path are proved unbounded at 8 banks and
bounded-checked at 32, with a human argument bridging the two.*

---

## 5. What is not covered at any scale

| Gap | Tracked as |
|---|---|
| RAA overshoot bound | ASSUMPTIONS.md OPEN-5 (system-level) |
| ECC symbol correction (SEC-DED only) | ASSUMPTIONS.md OPEN-7 |
| Pool / read-FIFO order proved bounded, not unbounded | ASSUMPTIONS.md OPEN-4, OPEN-6 |
| Integration: PC slice, stack | **simulated** (Rev 1.4): 12/12 slice at production geometry, 6/6 stack boot at reduced geometry. No proof covers either (ASSUMPTIONS.md OPEN-14) |
| Integration: **system top** | simulated at **reduced geometry only** (2 stacks, 8 slices), boot and control, 5/5. The 256-slice system lints clean but has **never been simulated** |
| Multi-pseudo-channel and multi-stack interaction | simulation only, by design. Multi-stack boot and control are covered; multi-stack **data traffic** is still unwritten |
| Out-of-range request completion | ASSUMPTIONS.md OPEN-13 — requests are dropped, not answered |
| Index-width truncation (tag wider than the index it selects) | **invisible at `FV_SMALL` by construction** — see §5b |
| ~~Reset behaviour (assumption A1)~~ | **DISCHARGED in Rev 1.0** — power-on and mid-operation both tested |
| Clock-domain crossings | no open-source tool; hand review (see verification plan §7) |

---

## 5a. A fourth instance, and a hazard in the flow

`fv_init_seq` drives `script_data` as a free input. `c_done` is satisfied by an `OP_END` at
PC 0, so **no proof ever executed an `OP_WAIT`** — and an `OP_WAIT` that looped on itself
forever passed every property in the file. Same trap as §3: a cover that is satisfied by the
shortest path, leaving the interesting path untested. Fixed with `c_wait`, `c_wait_prog` and
`c_wait_done`.

`c_wait_done` was itself first written unreachably (`done && $past(dbg_wait != 0)`, which
cannot hold because the terminating instruction executes in the same cycle the wait expires).
**A cover statement is code, and gets the same scrutiny as a property.**

### Run proofs through `make`, never `sby` directly

`sby -f <block>.sby` reads the `build/*.v` already on disk. Only `make` re-runs sv2v first.
Invoking `sby` directly after editing RTL therefore **proves the previous revision and reports
PASS** — the most dangerous possible outcome, because it is green.

`mutate.sh` is safe (it calls `make`). A human iterating on one block is not. `make stale`
fails if any netlist is older than its sources; run it before believing a result.

### Never run two regressions at once

The same `build/*.v` files are regenerated by every target, so two concurrent `make` runs in
this directory write over each other: one proof reads a netlist the other is half-way through
producing. The result is meaningless **in whichever direction the race happens to fall,
including green.**

This is not hypothetical — it was done here by accident, by starting a second regression while
the first was still running and not noticing. `mutate.sh` already took a build lock for exactly
this reason; the top-level now has one too:

```bash
make guarded              # takes .sby.lock, refuses to start a second run
```

Both this and the staleness hazard above share a root cause worth naming: **the build products
are shared mutable state, and a proof that reads the wrong ones still reports PASS.** Every
guard in this flow exists because a wrong answer here is green, not red.

---

## 5b. A fifth instance: a tag exactly as wide as the index (Rev 1.4)

Rev 1.3 stored write data in `hbm4_wdata_ram` indexed by the host's `req_tag`. At production
geometry a tag is **8 bits** and the RAM has `TQ_DEPTH` = **64** entries, so the index was
silently truncated and tags *t* and *t*+64 shared an entry. A queued write's data was
overwritten by a later write, and the earlier write stored the wrong bytes at a correct address.

Under `FV_SMALL` a tag is **2 bits** and `TQ_DEPTH` is **4**, so a tag is exactly as wide as a
pool index. **Truncation cannot occur in the reduced configuration at all.** It is the §3
mistake again, a reduced configuration that cannot reach the state that matters, except that
this time the narrowing was a deliberate solver-state saving (`TAG_W` "is opaque payload")
whose side effect nobody re-examined when the tag gained a second use as an address.

What caught it: Verilator `-Wall` **at production geometry** (`WIDTHTRUNC` on every index into
the RAM) and a production-geometry simulation, `test_write_data_tag_independence`. Neither
proofs nor mutation testing could have, because both run at `FV_SMALL`.

**The rule this adds:** a narrowing in `FV_SMALL` is only safe while the narrowed value stays
opaque. When a narrowed field starts selecting storage, the reduced configuration must keep
that field strictly **wider** than the thing it indexes, or the production-geometry lint and a
production-geometry test must be gates. Rev 1.4 removed the dependency instead: write data is
indexed by pool entry (`alloc_idx` / `issue_idx`), which is always exactly as wide as the RAM it
indexes.

---

## 6. Reproducing

```bash
cd formal
make stale                # refuse to trust out-of-date netlists
make                      # all proofs, reduced geometry
make FV_DEFINES=          # all proofs, full production geometry (BMC)
./mutate.sh               # mutation coverage; must report 0 survivors
```
