# HBM4 Memory Controller IP — Documentation

**Rev 1.3** · configurable HBM4 controller for bandwidth-first accelerators
· 8.19 TB/s raw · 256 pseudo-channels · fully open-source verification flow

---

## Start here

| If you are… | Read, in this order |
|---|---|
| **Evaluating the IP** | [01 Product Overview](01-product-overview.md) → [08 Compliance Matrix](08-compliance-matrix.md) → [07 Performance Guide](07-performance-guide.md) |
| **New to DRAM controllers** | [02 Architecture §1–§2](02-architecture.md) → [A Glossary](A-glossary.md) → [02 §3, §7, §8](02-architecture.md) |
| **Integrating it into an SoC** | [05 Integration Guide](05-integration-guide.md) → [03 Interface Spec](03-interface-spec.md) → [02 §4](02-architecture.md) |
| **Writing the driver** | [04 Programming Guide](04-programming-guide.md) → [03 Interface Spec §3](03-interface-spec.md) |
| **Verifying it** | [06 Verification Plan](06-verification-plan.md) → [02 Architecture](02-architecture.md) |
| **Tuning for a workload** | [07 Performance Guide](07-performance-guide.md) → [04 §3](04-programming-guide.md) |
| **Reviewing the design** | [02 Architecture](02-architecture.md) end to end, then [06](06-verification-plan.md) |

---

## Documents

| | | |
|---|---|---|
| **01** | [Product Overview](01-product-overview.md) | What it is, features, configuration matrix, deliverables, what you provide |
| **02** | [Architecture](02-architecture.md) | **The core document.** DRAM background, the three constraints, address map, scheduler, ECC, refresh, performance model |
| **03** | [Interface Specification](03-interface-spec.md) | NHI, DFI, APB4 signal lists, rules, ordering contract, all timing diagrams |
| **04** | [Programming Guide](04-programming-guide.md) | Register map, boot sequence, runtime tuning, DVFS, error handling |
| **05** | [Integration Guide](05-integration-guide.md) | Parameters, clocking, reset, PHY, DFT, floorplan, checklist, common mistakes |
| **06** | [Verification Plan](06-verification-plan.md) | SymbiYosys formal + Verilator/cocotb simulation, ~60 properties, signoff criteria |
| **07** | [Performance Guide](07-performance-guide.md) | Expected numbers, address-map selection, tuning recipes, low-bandwidth debug tree |
| **08** | [Compliance Matrix](08-compliance-matrix.md) | Feature support, and every value that must be confirmed before signoff |
| **09** | [Release Notes](09-release-notes.md) | Versioning, changelog, upgrade notes, roadmap |
| **A** | [Glossary](A-glossary.md) | Every term and acronym, written for newcomers |

---

## Figures and timing diagrams

**Block diagrams** live in [`figures/`](figures/) as `.drawio.svg`. Each file is *both* a
rendered SVG (displays in Markdown, GitHub, any browser) *and* an editable draw.io document —
open it with the [draw.io VS Code extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio)
or diagrams.net and edit directly. No build step, no broken image links, no separate source
file to drift.

**Timing diagrams** live in [`waves/`](waves/) as WaveDrom `.json` sources plus committed
`.svg`. Paste a `.json` into [wavedrom.com](https://wavedrom.com) to edit it.

Both sets are generated, so they can be restyled or regenerated wholesale:

```bash
python3 tools/gen_figures.py    # -> docs/figures/*.drawio.svg
python3 tools/gen_waves.py      # -> docs/waves/*.json + *.svg
```

Only Python 3 is needed — no Node, no drawio CLI, no wavedrom install.

| Figure | | Timing | |
|---|---|---|---|
| [1](figures/fig-01-system-context.drawio.svg) | System context | [1](waves/wave-01-nhi-read.svg) | NHI read |
| [2](figures/fig-02-rtl-hierarchy.drawio.svg) | RTL hierarchy | [2](waves/wave-02-nhi-out-of-order.svg) | Out-of-order response |
| [3](figures/fig-03-pc-slice.drawio.svg) | Inside a PC slice | [3](waves/wave-03-nhi-write.svg) | NHI write |
| [4](figures/fig-04-clock-domains.drawio.svg) | Clock domains | [4](waves/wave-04-nhi-credit.svg) | Credit flow control |
| [5](figures/fig-05-address-map.drawio.svg) | Address map | [5](waves/wave-05-dfi-steady-state.svg) | **DFI steady state** |
| [6](figures/fig-06-pipeline.drawio.svg) | Pipeline | [6](waves/wave-06-bank-group-penalty.svg) | Bank-group penalty |
| [7](figures/fig-07-scheduler.drawio.svg) | Dual arbiter | [7](waves/wave-07-read-write-turnaround.svg) | R/W turnaround |
| [8](figures/fig-08-txn-lists.drawio.svg) | Transaction lists | [8](waves/wave-08-internal-pipeline.svg) | Internal pipeline |
| [9](figures/fig-09-ecc-layout.drawio.svg) | ECC layout | [9](waves/wave-09-ecc-column-access.svg) | ECC column access |
| [10](figures/fig-10-direction-fsm.drawio.svg) | Direction FSM | [10](waves/wave-10-per-bank-refresh.svg) | Per-bank refresh |
| [11](figures/fig-11-write-hazard.drawio.svg) | Write hazard | [11](waves/wave-11-apb-csr.svg) | APB CSR access |
| [12](figures/fig-12-refresh.drawio.svg) | Refresh | | |
| [13](figures/fig-13-verification-flow.drawio.svg) | Verification flow | | |
| [14](figures/fig-14-deliverables.drawio.svg) | Deliverables | | |

---

## The five things worth knowing

1. **It is 256 controllers, not one.** An HBM4 pseudo-channel has its own command buses, bank
   state, and timing. Nothing meaningful is shared between them.

2. **Three device constraints shape everything** ([02 §2](02-architecture.md)): one column
   command per clock; the bank group must alternate on every command; row and column commands
   travel on separate buses and issue in the same cycle.
   [Timing 5](waves/wave-05-dfi-steady-state.svg) shows all three at once.

3. **The address map does the scheduler's hardest work.** Ordering the fields
   *stack → PC → bank group → bank → column → row* makes sequential streams alternate bank
   groups automatically ([02 §7](02-architecture.md)).

4. **ECC lives in the same open row as its data.** Two of 32 columns per row hold the check
   bits, so fetching ECC costs one column access — no activate, no precharge. 6.25% of
   capacity and bandwidth, on by default.

5. **There is no crossbar, by design.** Address slicing happens in *your* fabric using
   `HBM4_ADDR_SLICE`, which ships with the IP and is formally proved equivalent to the
   controller's own decode ([03 §4](03-interface-spec.md)).

---

## Project state

**Rev 1.0 is an implemented, verified release.** 32 SystemVerilog modules, lint-clean at
`-Wall`, with the full 256-pseudo-channel system elaborating at production geometry.

| Evidence | State |
|---|---|
| Formal (SymbiYosys) | 20 blocks, **40/40 proof tasks pass**, 71-mutation coverage harness |
| Simulation — slice | **10/10** at production geometry |
| Simulation — stack boot | **6/6** |
| Simulation — full system | **none** |
| Synthesis | area and logic depth measured; **no signed timing** |

**Before committing to this IP, read [01 §Verification status](01-product-overview.md) and
[formal/ASSUMPTIONS.md](../formal/ASSUMPTIONS.md).** The short version: 1 GHz operation is not
yet proven against a real library, every DRAM timing value is a placeholder marked **(P)**
pending the device datasheet, and the multi-stack system level has never been simulated.

> **Highest-impact open item: burst length.** The design assumes BL8 / 32 B, scaled from
> HBM3 where the arithmetic checks out exactly. If HBM4 defines BL16 / 64 B, a burst becomes
> two core clocks, the column arbiter gains timing slack, and the ECC field width doubles.
> Confirm this before anything else.

---

## Repository layout

```
docs/          this documentation set
  figures/     14 block diagrams  (.drawio.svg - render AND edit)
  waves/       11 timing diagrams (WaveDrom .json + .svg)
tools/         figure and waveform generators (Python 3, no dependencies)
  figlib.py    .drawio.svg emitter: mxGraph XML + matching SVG from one description
  wavelib.py   WaveDrom-subset renderer
rtl/           32 SystemVerilog modules, lint-clean at -Wall
  pkg/         geometry, types, timing sets
  fabric/      address slicing shipped to the customer's fabric
  fe/          host front-end: NHI, decode, write buffer
  core/        scheduler: timing engine, bank state, dual arbiter, refresh
  dfi/         PHY handshake, read-pointer FIFO
  ras/         inline ECC, scrub, error log, link ECC
  global/      CSR, power, boot sequencer + script ROM, supervisor
  slice/       pseudo-channel slice, stack top, system top
formal/        20 SymbiYosys proof wrappers + 72-mutation coverage harness
  SCALING.md   why reduced-geometry results transfer -- and where they do not
  ASSUMPTIONS.md   every assumption and open item, stated plainly
sim/           cocotb 2.0.1 + Verilator 5.050, independent JEDEC timing checker
  README.md    including the ways the checker itself was wrong first
  test_slice.py  10/10 at production geometry, incl. measured bus efficiency
  test_boot.py   6/6 boot sequence at the stack level
syn/           Yosys synthesis: area, logic depth, loop check
  README.md    what an open-source flow can and cannot tell you about timing
```

**Read `formal/ASSUMPTIONS.md` and `sim/README.md` before trusting any green result in this
repository.** Both record what is *not* covered as carefully as what is.
