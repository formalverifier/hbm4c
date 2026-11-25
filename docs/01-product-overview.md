# 01 — Product Overview

**HBM4 Memory Controller IP · Rev 1.3**

A configurable, synthesizable HBM4 memory controller for bandwidth-first accelerators —
GPUs, NPUs, and tensor engines that need every byte per second the stack can deliver.

---

## 1. At a glance

| | Baseline configuration |
|---|---|
| Memory standard | JEDEC HBM4 (JESD270-4) |
| Stacks supported | 1 / 2 / 4 / 8 (`N_STACK`, baseline **4**) |
| Raw bandwidth | **8.19 TB/s** (4 stacks at 8 Gb/s/pin) |
| Achieved bandwidth, 2:1 R:W streaming | **≥ 6.80 TB/s** (83% efficiency, ECC on) |
| Raw capacity | 256 GB (16-high, 32 Gb dies) |
| Usable capacity | **240 GB** (inline ECC on) |
| Scheduling domains | 256 independent pseudo-channel controllers |
| Core clock | 1.0 GHz (DFI ratio 1:2) |
| Idle read latency | ~33 ns end to end; **10 clocks** attributable to the controller |
| Host interface | Native wide (NHI), 256 ports, synchronous |
| Data protection | Link ECC + on-die ECC visibility + inline system ECC |
| Target | ASIC, advanced FinFET |

---

## 2. What it does well, and what it does not

**Built for:** long sequential streams, high row-hit potential, latency tolerated, bandwidth
paramount. Tensor traffic, activation and weight streaming, large-block DMA.

**Also handles:** mixed traffic with a latency-sensitive class (QoS with aging), moderate
irregularity (configurable XOR hashing), and random access (`CLOSE` page policy).

**Not built for:** latency-dominant CPU-like workloads with shallow memory-level parallelism.
Nothing here breaks — but a controller tuned for that would use shorter queues, a different
page policy, and would not spend 1 MB of SRAM on write buffering. If that is the target,
say so before configuring.

---

## 3. Features

**Scheduling**
- One independent scheduler core per pseudo-channel — no shared state, no cross-PC stalls
- **Dual arbiter**: row and column commands issue in the same cycle on separate buses
- Row-hit batching without a CAM (per-bank, per-row linked lists)
- Look-ahead activation targeted at `tRCD` before the column stream needs the bank
- Read/write direction batching with programmable watermarks and burst credits
- Bounded starvation at every arbitration point, with QoS aging

**Address mapping**
- Four preset maps plus a fully programmable mode
- CSR-programmable XOR hashing on stack, pseudo-channel, bank group, and bank
- Contiguous usable address space even with ECC enabled
- `HBM4_ADDR_SLICE` block shipped for the customer's fabric, formally proved equivalent to
  the controller's own decode

**RAS**
- Link ECC with bounded transparent read retry
- On-die ECC status polling and `ALERT_n` capture
- Inline system ECC: Hsiao SEC-DED(266,256), **6.25% overhead**, ECC stored in the same
  open row as its data. Single-bit correct, double-bit detect-and-never-miscorrect.
- Poison generation and propagation, patrol scrub, PPR and lane-repair flows
- Per-stack error logs with sticky first-error, aggregated globally with one timestamp

**Refresh**
- Per-bank refresh (REFsb) with opportunistic scheduling
- ±8 refresh credit slack with graded urgency
- Global refresh phase assignment across all stacks
- RFM / Directed RFM row-hammer mitigation, lockable

**Power**
- Per-pseudo-channel clock gating and DRAM power-down
- Per-stack self-refresh
- DVFS with double-buffered timing registers for atomic swap

**Init**
- Microcoded training sequencer with loadable 2 KB script RAM — training changes are a
  firmware update, not a metal spin
- Parallel training across all channels and all stacks
- Hardware ECC region initialisation

---

## 4. Configuration matrix

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `N_STACK` | 1, 2, 4, 8 | 4 | bandwidth and capacity scale linearly |
| `SYSECC_EN` | 0, 1 | **1** | 6.25% of bandwidth and capacity for SDC protection |
| `WBUF_DEPTH` | 64, 128, 256 | **128** | turnaround loss 5.9% / 3.0% / 1.5% |
| `TQ_DEPTH` | 32, 64, 128 | 64 | must cover `tRC` of issue |
| `ADDRMAP_MODE` | STREAM, LOCAL, CLOSE, NUMA, RAW | STREAM | see [07-performance-guide.md](07-performance-guide.md) |
| `STACK_ILV` | FINE, MEDIUM, NUMA | FINE | bandwidth vs fault isolation |
| `ECCINIT_MODE` | FULL, LAZY | FULL | ~50 ms boot vs a more complex write path |
| `RFM_MODE` | OFF, RFM, DRFM | DRFM | row-hammer mitigation |
| `PG_GROUP` | 4, 8, 16 | 8 | power-gating granularity |

Non-power-of-two `N_STACK` (e.g. 6) is **not** expressible under `STACK_ILV = FINE`, because
the slicer is pure bit-select. Use `MEDIUM` or `NUMA`.

---

## 5. Deliverables

![Figure 14 — deliverables](figures/fig-14-deliverables.drawio.svg)

| | Contents |
|---|---|
| **RTL** | Parameterised SystemVerilog. `hbm4_sys_top` (instantiate this) and `hbm4_addr_slice` (instantiate in your fabric). |
| **Documentation** | This 10-document set. Figures ship as `.drawio.svg` — they render as images and open editable in diagrams.net or the VS Code draw.io extension. |
| **Verification kit** | SymbiYosys property set and `.sby` scripts; cocotb environment, DRAM model, independent timing checker, traffic generators. Fully open-source toolchain — **no licence needed to re-verify your configuration**. |
| **Software** | CSR header, init/training scripts, reference driver, tuning recipes. |
| **Diagram sources** | `tools/gen_figures.py`, `tools/gen_waves.py` — regenerate or restyle every figure and waveform. |

Everything is version-locked by one release tag. See
[09-release-notes.md](09-release-notes.md).

---

## 6. What you provide

| # | Responsibility | Document |
|---|---|---|
| 1 | Instantiate `HBM4_ADDR_SLICE` in your fabric | [03](03-interface-spec.md) §4 |
| 2 | Deliver NHI traffic at `clk_core` (1 GHz) | [05](05-integration-guide.md) |
| 3 | Supply the PHY and its training script | [05](05-integration-guide.md) |
| 4 | Replace every **(P)** value from your JEDEC copy and vendor datasheet | [08](08-compliance-matrix.md) |
| 5 | DFT insertion and physical closure | [05](05-integration-guide.md) |
| 6 | Run the integration checklist | [05](05-integration-guide.md) §9 |

Item 4 is not optional and not a formality. The controller ships with placeholder timing
scaled from HBM3; signing off against those proves it obeys timings that are not the ones in
your silicon.

---

## 7. Headline numbers, and where they come from

| Metric | Value | Derivation |
|---|---|---|
| Sequential read efficiency | ≥ 88% | [02](02-architecture.md) §14.1 |
| 2:1 R:W streaming efficiency | ≥ 83% | [02](02-architecture.md) §14.1 |
| Efficiency with ECC off | ≥ 89% | the ECC cost, made visible |
| Row-hit rate, ≥8 MB stream | ≥ 96% | [02](02-architecture.md) §7.5 |
| Idle read latency | ~33 ns | [02](02-architecture.md) §14.2 |
| Controller-attributable latency | 10 clocks | the rest is DRAM and PHY physics |
| Write buffer SRAM | 1 MB | 256 PC × 4 KB |
| ECC cache SRAM | 256 KB | 256 PC × 1 KB |

These are **analytic** numbers. The verification kit cross-checks them against Ramulator 2
before the RTL numbers are trusted ([06](06-verification-plan.md) §5).

---

## 8. Maturity

**Rev 1.0 is an implemented and verified release.** The RTL exists (32 modules), is
lint-clean, elaborates at full 256-pseudo-channel scale, and is covered by 40 formal proof
tasks and 16 simulation tests across the slice and stack levels.

What it is *not* yet: silicon-ready. See the verification status table below for the
distinction, which matters more than the revision number.

Twelve items remain open ([02](02-architecture.md) §16): eight require JESD270-4 or vendor
datasheet values, four are customer decisions. The highest-impact open item is **burst
length** — if HBM4 defines BL16/64 B rather than BL8/32 B, the column arbiter's timing
pressure eases and the ECC field width doubles. Confirm this first.

---

## Verification status at a glance

**Rev 1.0.** Stated so an evaluator does not have to reconstruct it from the release notes.

| Evidence | Status |
|---|---|
| Lint (Verilator `-Wall`) | 32 modules clean; 256-slice system elaborates |
| Formal (SymbiYosys) | 20 blocks, 40 proof tasks, 72-mutation coverage harness |
| Simulation — slice | 10/10 at production geometry |
| Simulation — stack boot | 6/6 |
| Simulation — full system | **none** |
| Synthesis | area + logic depth measured; **no signed timing** |
| Assumptions outstanding | A2, A3, A4, A7 (A1 discharged Rev 1.0) |

### What a customer must know before committing

1. **1 GHz does not currently close.** Measured against ASAP7 (predictive 7 nm, typical
   corner, no wire delay): **1830–2252 ps**, i.e. ~440–545 MHz, against a 1000 ps target.
   The architecture's central premise — one column command per core clock — fails by ~2×
   as the RTL stands. It needs pipelining of cross-module paths, which has not been
   attempted. See [syn/README.md](../syn/README.md).
2. **All DRAM timing values are placeholders** marked `(P)`, pending the device datasheet.
3. **Link-ECC retry is not available** — `cfg_retry_en` must stay off. Link uncorrectables
   escalate to the host as errors. See OPEN-9.
4. **The full 256-slice system is unsimulated.** Slice and stack levels are verified.
5. **The boot sequence must re-run after any reset.** Enforced structurally (`cmd_en` follows
   `boot_done`), not merely documented.
