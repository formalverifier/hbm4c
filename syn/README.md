# Synthesis — area and timing-plausibility evidence

**Rev 1.0** · Yosys 0.68, generic `abc -g simple` mapping · `make -C syn`

Until this existed the design had been through Verilator lint and forty formal proofs and
**had never been synthesized**. The entire architecture is justified by a 1 ns core clock
(docs/02 §3); that number was an assumption with nothing behind it.

## What this flow can and cannot tell you

There is no liberty file in an open-source flow, so **this is not signed timing.** It produces
two things that are still worth having:

* **relative area** — which blocks actually cost what;
* **logic depth** — the longest register-to-register path in gate levels.

### The units matter, and are easy to get wrong

`abc -g simple` maps to **2-input primitives only** (AND/OR/NOT/XOR/MUX). The familiar
"30–40 levels at 1 GHz" rule of thumb refers to *standard cells*, which include AOI/OAI
compound gates, wide NANDs and full adders. A real library is typically **2.5–4× shallower**
for the same logic.

Comparing the two directly is a units error. It was made once while producing this report, and
it flipped the conclusion from "comfortable" to "will not close" and back again.

## Results

```
Longest register-to-register path:  125 levels of 2-input gates
  from  u_ref.rfc_cnt[4]        (refresh per-bank tRFC counter)
  to    u_timing.pre_ok[26]     (timing engine precharge readiness)
```

125 two-input levels is **roughly 30–50 standard-cell levels**. That is at or slightly beyond a
1 GHz budget: **tight, plausible, and unresolved.** It cannot be settled without a real library,
and it is the single largest technical risk remaining in the design.

The path is `refresh counter → … → per-bank precharge readiness`, i.e. the refresh engine
feeding the timing engine's readiness vectors across all 32 banks. If timing closure fails,
that is where to pipeline first — most cheaply by registering `refresh_block` one cycle before
it reaches the timing engine, which costs a cycle of refresh-blocking latency and nothing else.

### Area per pseudo-channel

| Block | Cells | Share |
|---|---:|---:|
| `hbm4_txn_pool` | 32 637 | **40.5%** |
| `hbm4_timing_engine` | 20 785 | **25.8%** |
| `hbm4_refresh` | 8 374 | 10.4% |
| slice top-level glue | 7 366 | 9.1% |
| `hbm4_row_arb` | 3 325 | 4.1% |
| `hbm4_sys_ecc` | 2 761 | 3.4% |
| everything else | 5 331 | 6.7% |
| **total** | **80 579** | |

**× 256 pseudo-channels ≈ 20.6 M 2-input-gate equivalents** for the controller alone.

### The actionable finding

**Two blocks are two thirds of the design.** `TQ_DEPTH` is the dominant area knob: at 64
entries per pseudo-channel the system carries **16 384 in-flight transactions**, which is
almost certainly over-provisioned for streaming traffic that is mostly row hits. Halving it to
32 would remove roughly 16 k cells per slice — about 4 M system-wide — and the queueing
analysis in docs/07 should be revisited to say what depth the workload actually needs rather
than inheriting 64 as a default.

This is a sizing question the performance model should answer, and it has not been asked.

## Reproducing

```bash
make -C syn          # synthesis + reports
make -C syn check    # combinational-loop check (authoritative)
```

`check.ys` runs `check -assert` and **passes**: there are no combinational loops. Note that
`ltp` run on an *unflattened* netlist reports ~185 spurious "Detected loop" warnings, because
it treats every submodule instance as a black box in which each input reaches each output —
so any two blocks that feed one another look like a cycle. `synth.ys` flattens first, after
which zero loops are reported. **Do not read loop warnings from an unflattened `ltp`.**

---

# Timing with a real cell library (ASAP7)

The generic `abc -g simple` results above are superseded. This section uses **ASAP7**
(predictive 7 nm, RVT, typical corner, NLDM), 202 cells across SIMPLE/INVBUF/AO/OA/SEQ,
merged into one liberty for `abc -liberty`.

## Headline: the design does not close at 1 GHz

| Metric | Value |
|---|---|
| Critical path, best measured | **1830 ps** (`TQ_DEPTH = 16`) |
| Critical path, as shipped (`TQ_DEPTH = 64`) | **2252 ps** |
| Implied Fmax | **~440-545 MHz** |
| Target | 1000 ps (1 GHz) |

**Over budget by ~2x, and this is the optimistic number** -- `WireLoad = "none"`, so there is
no wire delay, no placement, no clock tree and no parasitics. At 7 nm on a block this size,
wire delay makes it worse, not better.

The entire architecture is justified by a 1 ns core clock (docs/02 §3): one column command per
clock, 1:2 DFI gearing, BL8 = 1 core clock. **That premise currently fails.** This is a
structural problem, not a margin problem, and it needs pipelining of the cross-module paths --
work that has not been attempted, since the RTL was written for function.

Countervailing: `abc`'s buffering and sizing are crude next to a commercial flow with
retiming, useful skew and physical optimisation. A real flow would do better than 1830 ps.
It is unlikely to find 2x.

## Two corrections to earlier conclusions in this document

**1. The critical path is not where `ltp` said it was.** The generic run reported
`u_ref.rfc_cnt -> u_timing.pre_ok` (refresh to timing-engine readiness). With real cells, no
single block is over 1 ns:

| Block | Critical path |
|---|---|
| `hbm4_txn_pool` (standalone) | 3867 ps -- see caveat |
| `hbm4_row_arb` | 1002 ps |
| `hbm4_col_arb` | 929 ps |
| `hbm4_timing_engine` | 788 ps |
| `hbm4_refresh` | 542 ps |
| `hbm4_dir_fsm` | 278 ps |
| `hbm4_bank_state` | 133 ps |

The slice-level path is therefore a **cross-module** path, not any one block. Topological depth
in generic gates is a poor predictor of where real time goes.

**Caveat on the pool number:** measured standalone it exceeds the whole flattened slice, which
is impossible for a real path. Standalone, its wide array outputs (`head_row[N_BANK]`,
`head_wrow[N_BANK]`) are unconstrained primary outputs, so `abc` optimises for worst-case
PI-to-PO paths that are constrained or unused in context. **Treat 3867 ps as unrepresentative**
rather than as evidence the pool is the bottleneck.

**2. Shrinking `TQ_DEPTH` does not fix timing.** The prediction above -- that the pool's
64-entry search drives the critical path -- is wrong. Measured:

| `TQ_DEPTH` | slice (ps) | pool standalone (ps) | slice area (um2) |
|---:|---:|---:|---:|
| 8 | 1850 | 3798 | 5467 |
| 16 | **1830** | 3726 | 5646 |
| 32 | 1839 | 3834 | 6139 |
| 64 | 2252 | 3867 | 6935 |

The pool's own path is **flat in depth** (3798 -> 3867 ps, 8 -> 64): whatever dominates it is
not the entry search. And the slice improves only ~19% from 64 to 16, then flattens -- so depth
is worth something for timing but nowhere near enough.

## What the sweep does justify: area

Depth 64 costs **1468 um2 per pseudo-channel** over depth 8 -- 21% of the slice. Across 256
pseudo-channels that is **~0.38 mm2** of pure area, for in-flight capacity the workload has not
been shown to need. `TQ_DEPTH = 16` is the knee: best measured timing and 19% less area than 64.

**This is a recommendation to evaluate, not to apply.** Reducing depth reduces the number of
outstanding transactions per pseudo-channel, which bounds latency hiding. The efficiency test
(98.8% at depth 64) must be re-run at the proposed depth before anything is changed -- and
`sim/testbench.py` derives its credit count from `TQ_DEPTH`, so it will follow automatically.

## Reproducing

```bash
cd syn && make            # generic mapping (area, logic depth, loop check)
yosys sta.ys              # ASAP7 mapped timing
```

Liberty files are downloaded to `syn/lib/` and merged by hand; `asap7_rvt_tt_merged.lib` is a
concatenation of the five RVT/TT cell families under one library header. All five declare
`time_unit : "1ps"` and `capacitive_load_unit (1,ff)`, verified before merging.

**One trap worth recording:** without `buffer -N 16; upsize; dnsize` in the `abc` script, the
reported delay was **19 865 ps** -- 9x worse. `abc`'s mapper inserts no buffers, so high-fanout
nets (reset, enables) carry the full unbuffered load of thousands of sinks. An unbuffered
number is not a timing estimate; it is an artifact.
