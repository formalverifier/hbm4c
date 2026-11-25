# 08 — Compliance Matrix

**HBM4 Memory Controller · Rev 1.3**

What this controller claims, what it does not, and every value that must be confirmed before
you can sign off. Written to be handed to a customer's verification lead unedited.

---

## 1. How to read this

| Status | Meaning |
|---|---|
| ✅ **Supported** | Implemented and covered by the verification plan |
| 🔶 **Configurable** | Supported, off or limited by default; see the named parameter |
| ⚠️ **Assumed** | Implemented against an **assumption** about the device. Confirm against JESD270-4 before signoff. |
| ❌ **Not supported** | Deliberately out of scope. Rationale given. |
| 🔲 **Customer-provided** | Outside the IP boundary |

---

## 2. Device feature support

### 2.1 Core operation

| Feature | Status | Notes |
|---|---|---|
| 32 channels / 64 pseudo-channels per stack | ✅ | one scheduler core per PC |
| Independent per-pseudo-channel operation | ✅ | no shared state between PCs |
| Separate row and column command buses | ✅ | dual arbiter, both issue per clock |
| ACT / PRE / RD / WR | ✅ | |
| Auto-precharge (RDA / WRA) | ✅ | `PAGE_POLICY = CLOSE` |
| Bank groups | ⚠️ | **assumed 4 BG × 8 banks = 32.** Confirm. |
| Burst length BL8, 32 B granularity | ⚠️ | **DECIDED, Rev 0.4.** Chosen on three grounds (§4.2). Still requires datasheet confirmation, but it is now the implemented and proved baseline, not an open question. |
| BL16 / 64 B granularity | 🔶 | parameterised, but not the verified baseline |
| Stack heights 4/8/12/16-high | 🔶 | via `ROW_BITS` / `SID_BITS`; only 16-high is the verified baseline |
| Multi-stack (1/2/4/8) | ✅ | `N_STACK`; non-power-of-two needs `STACK_ILV != FINE` |

### 2.2 Refresh

| Feature | Status | Notes |
|---|---|---|
| All-bank refresh (REFab) | ✅ | supported but not the default — ~9% overhead |
| Per-bank refresh (REFsb) | ✅ | **default**; ~3% overhead |
| Refresh postpone / pull-in (±8) | ✅ | `ref_debt` credit engine |
| Opportunistic refresh scheduling | ✅ | merges PRE→REF in idle bank windows |
| Temperature-based `tREFI` switching | ✅ | polls the DRAM temperature register |
| Global cross-stack refresh phasing | ✅ | supervisor-assigned offsets |
| RFM (Refresh Management) | ✅ | per-bank RAA counters |
| **DRFM (Directed RFM)** | ⚠️ | **assumed supported.** If the device lacks it, `RFM_MODE=RFM` is the fallback at higher cost. |

### 2.3 Data protection

| Feature | Status | Notes |
|---|---|---|
| Link ECC generate / check | ⚠️ | implemented; **code definition assumed** — confirm against JESD270-4 |
| Link ECC transparent read retry | ✅ | bounded at `LECC_RETRY_MAX` = 3 |
| On-die ECC status polling | ✅ | via mode registers, every `ODECC_POLL_MS` |
| `ALERT_n` capture | ✅ | timestamped, raises IRQ |
| Inline system ECC | ✅ | **Hsiao SEC-DED(266,256)** — single correct, double detect. 6.25% overhead, on by default. **Not** symbol-correcting; see §4.3. |
| Poison generate / propagate | 🔶 | requires `SYSECC_EN` |
| Patrol scrub | 🔶 | requires `SYSECC_EN`; on by default |
| Soft / hard PPR | ✅ | scripted, firmware-invoked |
| Spare lane repair | ✅ | scripted; **mechanism is PHY-vendor-specific** |
| ECS (Error Check and Scrub, DRAM-internal) | ❌ | not exposed. If the device supports it, controller-side patrol scrub is the equivalent. |

### 2.4 Power

| Feature | Status | Notes |
|---|---|---|
| Controller clock gating | ✅ | per PC, 4 idle clocks |
| DRAM power-down (PD) | ✅ | per PC, independent |
| Self-refresh (SR) | ✅ | per stack; all 64 PCs must vote idle |
| DVFS | ✅ | double-buffered timing, atomic swap |
| Per-stack power gating | 🔶 | `PG_GROUP`; note that `STACK_ILV=FINE` prevents idle stacks in practice |
| Maximum Power Saving Mode | ❌ | not implemented; SR covers the deep-idle case |

### 2.5 Initialization

| Feature | Status | Notes |
|---|---|---|
| Microcoded training sequencer | ✅ | 2 KB script RAM, ~15 instructions |
| Parallel training, all channels and stacks | ✅ | |
| WCK / write-leveling / DQ training | 🔲 | algorithm is a **customer-supplied script** |
| Read/write latency measurement | ✅ | writes `RD_FIFO_DEPTH` and CL/CWL CSRs |
| ECC region initialisation | ✅ | `FULL` (default) or `LAZY` |
| Degraded boot (stack disabled) | 🔶 | `DEGRADED_BOOT_EN`; requires `STACK_ILV = NUMA` |

---

## 3. Host interface

| Feature | Status | Notes |
|---|---|---|
| Native wide interface (NHI) | ✅ | 32 B granularity, tagged, credit-metered |
| Out-of-order response | ✅ | by design; the host must key on the tag |
| Same-block RAW hazard | ✅ | detect, forward, or block |
| Write coalescing | ✅ | |
| Per-port QoS with aging | ✅ | 4 classes, bounded starvation |
| **Cross-port ordering** | ❌ | Pseudo-channels are independent memories. Fence in the fabric. |
| AXI4 / ACE / CHI | ❌ | Bridge in the fabric where one bridge can serve many PCs. Bridging per-PC would cost 256 protocol engines for semantics streaming traffic does not use. |
| Exclusive access / atomics | ❌ | out of scope; implement above the controller |
| Address translation / IOMMU | ❌ | out of scope |

---

## 4. Values that MUST be confirmed before signoff

Every value marked **(P)** in [02-architecture.md](02-architecture.md) is a placeholder scaled
from HBM3 and public HBM4 summaries. **Signing off against these proves the controller obeys
timings that are not the ones in your silicon.**

| # | Item | Where | Impact if wrong |
|---|---|---|---|
| 1 | Bank group / bank count | §1.4 | arbiter width, address map field positions |
| 2 | Burst length and access granularity | §1.3 | **Decided as BL8 / 32 B — see §4.2.** Confirm, but the RTL derives everything from one `BL` parameter, so a change is an edit and a re-proof, not a redesign. |
| 3 | Full timing table at 8 Gb/s | App. A | every timing counter; the whole efficiency model |
| 4 | Row/column command bus widths and encodings | §12 | DFI adapter |
| 5 | SID addressing for 12-/16-high | §5 | `ROW_BITS`/`SID_BITS` split |
| 6 | Link ECC code and sideband | §10.1 | link ECC block |
| 7 | DRFM support and format | §9 | `RFM_MODE` fallback to RFM |
| 8 | Pin data rate | §1.3 | **the entire clock plan.** 8 Gb/s → CK 2 GHz → core 1 GHz. |
| 9 | `tREFI` grades and temperature thresholds | §9 | refresh engine |
| 10 | `tRFCsb` vs `tRFCab` | §9 | the per-bank refresh argument (3% vs 9%) |

**Signoff gate S12** in [06-verification-plan.md](06-verification-plan.md) requires all ten
resolved and the full regression re-run.

### 4.2 Burst length — decided, with the reasoning

`BL = 8` (32 B access granularity), set in `rtl/pkg/hbm4_pkg.sv`.

1. **The arithmetic identity closes.** In HBM3 at 6.4 Gb/s: tCK = 625 ps, tCCD_S = 2 tCK =
   1.25 ns, and BL8 = 8 UI = 1.25 ns — burst time *exactly equals* tCCD_S. The same identity
   holds at HBM4's 8 Gb/s (1 ns = 1 ns). A standard breaking it would strand bus cycles or
   force tCCD_S = 4 tCK.
2. **HBM4 doubled the width, not the per-pseudo-channel organisation.** 32 channels /
   64 pseudo-channels over 2048 bits puts the pseudo-channel at 32 bits. Burst length follows
   the DRAM core's prefetch depth, and nothing per-PC widened to force a change.
3. **32 B granularity is an HBM value proposition** — fine-grained access for sparse and
   irregular traffic. 64 B would be a regression for the workloads HBM targets.

**What makes this cheap to reverse:** the DFI datapath is 256 bits per core clock either way
(32 B over 1 clock, or 64 B over 2). `BL` flows into `AG_BYTES`, `BURST_CLKS`, `N_COL_DATA`,
`OFFSET_W` and the ECC field width, and nothing else. Under BL16 the column budget becomes
16 columns (15 data + 1 ECC), the divider becomes ÷15, and the ECC field doubles to 34 bits.
Both configurations are exercised by `hbm4_divc`'s exhaustive proof.

### 4.3 ECC strength — a claim corrected downward

Revisions before 0.7 described the inline system ECC as a **(272,256)
single-4-bit-symbol-correcting** code. **What is implemented is Hsiao SEC-DED(266,256)**:
single-bit correct, double-bit detect, never miscorrect.

The difference matters for one failure mode: a fault confined to a single x4 device produces
a 4-bit burst within one symbol. A symbol-correcting code rides through it; SECDED detects
it and reports uncorrectable. **Data is not silently corrupted either way** — the block is
poisoned and reported — but availability is lower.

Symbol correction needs GF(16) syndrome decoding and a Chien search. It is tracked as
**OPEN-7** rather than claimed. The documentation was corrected to match the implementation,
not the other way round.

What *is* proved (`fv_sys_ecc` plus `tools/check_hmatrix.py`):

| | |
|---|---|
| clean round trip is exact | proved |
| every single-bit error corrected | proved |
| every double-bit error detected, **never miscorrected** | proved |
| CE and UE mutually exclusive | proved |
| H-matrix: 256 distinct odd-weight columns, weight ≥ 3 | exhaustive, full width |
| all 32 640 double-error syndromes even ⇒ cannot alias a column | exhaustive, full width |

### 4.1 Tracking template

Copy into your project and fill in:

| # | Item | Value used | Datasheet value | Confirmed by | Date | Regression re-run |
|---|---|---|---|---|---|---|
| 1 | Banks per PC | 4 × 8 = 32 | | | | ☐ |
| 2 | BL / granularity | **BL8 / 32 B (decided)** | | | | ☐ |
| 3 | tRCD | 14 ns | | | | ☐ |
| 3 | tRP | 14 ns | | | | ☐ |
| 3 | tRAS | 29 ns | | | | ☐ |
| 3 | tRC | 43 ns | | | | ☐ |
| 3 | tCCD_S / tCCD_L | 1 / 2 clk | | | | ☐ |
| 3 | tRRD_S / tRRD_L | 2 / 4 ns | | | | ☐ |
| 3 | tFAW | 14 ns | | | | ☐ |
| 3 | tWTR_S / tWTR_L | 5 / 10 ns | | | | ☐ |
| 3 | tRTW / tRTP / tWR | 7 / 5 / 15 ns | | | | ☐ |
| 3 | CL / CWL | 16 / 8 clk | | | | ☐ |
| 10 | tRFCab / tRFCsb | 350 / 190 ns | | | | ☐ |
| 9 | tREFI (≤85 / >85 °C) | 3900 / 1950 ns | | | | ☐ |
| 8 | Pin data rate | 8.0 Gb/s | | | | ☐ |

---

## 5. Verification coverage claim

| Area | Method | Status at Rev 0.4 |
|---|---|---|
| DRAM timing compliance | Formal (P-TIM-1..13) | ✅ **PROVED UNBOUNDED at full production geometry** (32 banks, 32768 rows) |
| Command legality | Formal (P-BUS-*) | ✅ **PROVED UNBOUNDED** (column arbiter) |
| Divider exactness | Formal (P-MAP-4) | ✅ **PROVED UNBOUNDED**, exhaustive over all 2^20 inputs |
| Fabric ≡ controller decode | Formal miter (P-MAP-3) | ✅ **PROVED UNBOUNDED at full geometry** |
| Address range / fault detect | Formal (P-MAP-2) | ✅ **PROVED UNBOUNDED** |
| Mutation coverage | `formal/mutate.sh` | ✅ **13 mutations, 13 handled, 0 survivors** |
| Address map bijectivity | Formal (P-MAP-1) | Planned |
| ECC codecs | Formal, exhaustive (P-ECC-*) | Planned (RTL not yet written) |
| Starvation bounds | Formal, bounded liveness (P-LIVE-*) | ⚠️ **OPEN-1 — disabled, bound not established** |
| Data integrity end to end | Simulation scoreboard | Planned |
| Achieved bandwidth | Simulation + Ramulator cross-check | Planned |
| Boot and training | Simulation L3 | Planned |
| Error injection and recovery | Simulation, full matrix | Planned |
| CDC | **Hand review + per-synchroniser formal** | Planned — no open-source tool exists (§7 of the verification plan) |
| Gate-level timing | **Not covered by the open-source flow** | STA + `eqy` equivalence; vendor tools if available |

**Superseded at Rev 1.0.** The rows above were written when no RTL existed and every entry read
"planned." RTL now exists and much of it is verified — see the **Rev 1.0 evidence status**
table below, which supersedes the planning language above and separates what is *measured*
from what is merely *derived*.

The planning rows are kept rather than deleted: they record what was promised, which is what
makes the evidence table checkable.

---

## Rev 1.0 — evidence status

Each claim below is marked with what actually backs it, so a reviewer can tell a measured
result from a derived one.

| Claim | Evidence | Strength |
|---|---|---|
| JEDEC command timing honoured | independent checker in `sim/hbm4_dram_model.py`, live on every command | **measured** |
| Bank group alternates every column command (C2) | 0.0% same-BG consecutive pairs | **measured** |
| Column bus can be saturated | 98.8% utilisation, production geometry | **measured** |
| Boot configures the device | MRS + PREA + 7 PHY steps observed on the interfaces | **measured** |
| Link uncorrectable escalates to the host | 4 injected → 4 UE, 4 responses | **measured** |
| No state survives reset | power-on and mid-operation both tested | **measured** |
| Timing-engine and address-path correctness | unbounded proofs at production geometry | **proved** |
| Refresh legality (never to an open bank) | `p_ref_bank_closed`, `p_rfm_bank_closed` | **proved** |
| Address slice matches controller decode | formal miter | **proved** |
| Inline ECC is SEC-DED(266,256) | behaviour proved at 32 bits + exhaustive H-matrix check at 256 | **proved (structurally)** |
| No combinational loops | `check -assert` | **proved** |
| 1 GHz operation | **1830–2252 ps measured on ASAP7** (~440–545 MHz), no wire delay | **FAILS — ~2× over budget** |
| Area | **6935 µm² per pseudo-channel** on ASAP7 (~1.78 mm² for 256) | **measured** |
| Power | no estimate | **NOT established** |
| ~83% full-workload efficiency | derived from timing parameters only | **NOT measured** |
| Multi-stack system behaviour | lint and elaboration only | **NOT verified** |
| DRAM timing values | every value marked `(P)` is a placeholder | **NOT established** |

**The bottom five rows are what stands between this and a tapeout-ready deliverable.** Four of
them need vendor documentation or a real PDK; the fifth needs a system-level testbench.
