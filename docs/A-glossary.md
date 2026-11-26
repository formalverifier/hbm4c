# A — Glossary

**HBM4 Memory Controller · Rev 1.4**

Every acronym and term used in this documentation set. Written for someone new to DRAM
controllers; nothing here assumes you have seen the rest of the docs.

---

## DRAM fundamentals

**ACT (Activate)** — Command that copies an entire row into a bank's row buffer. Costs
`tRCD`. Nothing can be read or written from a bank until it has been activated.

**Bank** — An independent DRAM array with **exactly one row buffer**. 32 banks per
pseudo-channel here. The one-row-buffer rule drives a surprising amount of this design — it
is why the ECC scheme puts check bits in the same row as their data ([02 §10.3](02-architecture.md)).

**Bank group (BG)** — A set of banks sharing some internal circuitry. Consecutive column
commands to the *same* bank group are slower (`tCCD_L`) than to *different* ones (`tCCD_S`).
4 bank groups of 8 banks each here.

**BL (Burst Length)** — How many bits per pin move in one access. BL8 on a 32-bit
pseudo-channel = 32 bytes.

**CL (CAS Latency)** — Clocks from a read command until data appears. **CWL** is the write
equivalent.

**Column** — The addressable unit within an open row. 32 columns of 32 B per 1 KB row here;
30 are data and 2 hold ECC when inline ECC is on. (Rev 1.4: the 2 columns are still reserved,
but inline ECC is not integrated and nothing reads or writes them; see
[09 Release Notes](09-release-notes.md).)

**DQ** — The data pins. 32 per pseudo-channel, bidirectional — which is why turning the bus
around costs time.

**PRE (Precharge)** — Command that writes the row buffer back and readies the bank for a
different row. Costs `tRP`.

**Pseudo-channel (PC)** — Half a channel: 32 bits wide, with its own command buses, bank
state, and timing. **The independent scheduling domain in this design.** 64 per stack, 256 in
the system.

**RD / WR** — Read and write commands, issued to an already-activated bank on the column bus.

**REFab / REFsb** — All-bank and per-bank refresh. This controller uses **REFsb** by default:
it blocks one bank of 32 instead of the whole pseudo-channel (~3% overhead versus ~9%).

**Refresh** — Periodically rewriting rows so their charge does not leak away. Mandatory,
every `tREFI`.

**RFM / DRFM** — Refresh Management and Directed Refresh Management: row-hammer mitigation.
DRFM targets a specific aggressor row and is much cheaper.

**Row** — 1 KB of DRAM read into the row buffer by an ACT.

**Row buffer** — The strip of sense amplifiers holding one open row. One per bank.

**Row hit / row miss** — A hit reuses the currently open row (fast). A miss requires
PRE + ACT (~15× slower). Maximising hits is most of what a memory controller does.

**SID (Stack ID)** — Selects among die groups in a 12- or 16-high stack.

---

## Timing parameters

| Symbol | Meaning |
|---|---|
| `tCCD_S` / `tCCD_L` | Column-to-column delay, different / same bank group |
| `tFAW` | Four-activate window: at most 4 ACTs in this span |
| `tRAS` | ACT to PRE, minimum |
| `tRC` | ACT to ACT, same bank (full row cycle) |
| `tRCD` | ACT to first column command |
| `tREFI` | Average interval between refreshes |
| `tRFCab` / `tRFCsb` | Refresh cycle time, all-bank / per-bank |
| `tRP` | PRE to ACT |
| `tRRD_S` / `tRRD_L` | ACT to ACT, different / same bank group |
| `tRTP` | Read to precharge |
| `tRTW` / `tWTR` | Read-to-write and write-to-read turnaround |
| `tWR` | Write recovery |

---

## Interfaces and standards

**APB4** — Simple AMBA bus used here for configuration registers. (Rev 1.4: not integrated.
`hbm4_csr`, the APB register block, is not instantiated, so `hbm4_sys_top` has no APB port and
is configured through input ports; see [09 Release Notes](09-release-notes.md).)

**AXI4 / CHI** — ARM SoC interconnect protocols. **Not** the controller's native interface;
bridge in the fabric if needed ([08 §3](08-compliance-matrix.md)).

**CK** — The DRAM command clock, 2 GHz here (data rate ÷ 4).

**DFI (DDR PHY Interface)** — Standard controller-to-PHY interface. "Frequency ratio 1:2"
here means `dfi_clk` = CK ÷ 2 = 1 GHz.

**HBM4** — High Bandwidth Memory generation 4, JEDEC JESD270-4. 2048-bit stack interface.

**JESD270-4** — The JEDEC HBM4 standard document.

**NHI (Native Host Interface)** — This controller's host-side interface. Tagged,
credit-metered, out-of-order, 32 B granularity. Defined in
[03-interface-spec.md](03-interface-spec.md).

**PHY** — The analogue/mixed-signal block driving the physical pins. Vendor-supplied.

**UI (Unit Interval)** — One bit time on a pin. 125 ps at 8 Gb/s.

**WCK** — The write/data clock, 4 GHz here (data rate ÷ 2).

---

## This design's terms

**C1, C2, C3** — The three constraints that shape the whole architecture
([02 §2](02-architecture.md)): one column command per clock; bank groups must alternate; row
and column buses are independent.

**Column arbiter** — Picks one RD or WR per cycle. The tightest timing path in the design.

**`div30`** — The constant divide-by-30 that splits `rem20` into row and column when inline
ECC reserves 2 of 32 columns. Lives in the controller, never in the fabric slicer.

**Direction FSM** — Decides whether the pseudo-channel is currently reading or writing, and
batches each direction to amortise turnaround.

**ECC column cache** — 32 entries per PC, **direct-mapped by bank index**. Exact, not
approximate: a bank has one open row and each row-half has one ECC column. (Rev 1.4: not
integrated; `hbm4_ecc_cache` is not instantiated.)

**`HBM4_ADDR_SLICE`** — The ~200-gate block, shipped with the IP, that *your fabric*
instantiates to map a system address to `{stack, pseudo-channel, block address}`.

**Look-ahead activation** — Activating a bank about `tRCD` before the column stream will need
it. Too early wastes tFAW budget; too late stalls the column bus.

**NHI port** — One per pseudo-channel; 256 total. Port *i* is hardwired to PC *i*.

**Opportunistic refresh** — Refreshing a bank that was about to be precharged anyway, merging
PRE→REF into one row-bus slot pair.

**`ref_debt`** — Refresh credit counter, range −8…+8. Negative = ahead of schedule; ≥6 =
urgent.

**`rem20`** — The top 20 address bits, which `div30` splits into row and column. Deliberately
placed at the top so the reserved ECC space leaves the usable address range **contiguous**.

**Row arbiter** — Picks one ACT, PRE, REF, or RFM per cycle, on the row bus, in parallel with
the column arbiter.

**Row grouping** — Filing same-row requests contiguously in a per-bank list on arrival, so
row-hit batching happens without a CAM.

**`STACK_ILV`** — How addresses interleave across stacks: `FINE` (32 B, max bandwidth),
`MEDIUM` (4 KB), `NUMA` (contiguous regions).

**Supervisor** — The one global block: boot orchestration, unified CSR aperture, cross-stack
RAS, DVFS, refresh phasing. Never in the data path. (Rev 1.4: `hbm4_supervisor` does boot
orchestration, interrupt aggregation and the performance-snapshot edge. There is no CSR
aperture, because `hbm4_csr` is not integrated, and no DVFS logic; refresh phases are assigned
in `hbm4_stack_top`.)

**Transaction pool** — The 64-entry per-PC request store, threaded into per-bank, per-row
linked lists.

**Two-tier hazard check** — A cheap 12-bit hash compare every cycle, with an exact tag
comparison only on a hit. False positives cost a cycle; false negatives are impossible by
construction.

**Write-allocate elision** — Skipping the ECC read when a write stream fills all 15 fields of
an ECC block. Keeps writes at 6.25% overhead instead of 12.5%. (Part of `hbm4_ecc_cache`; not
integrated in Rev 1.4.)

---

## RAS terms

**ECC (Error Correcting Code)** — Three independent layers here: **link ECC** (protects the
interconnect), **on-die ECC** (inside the DRAM, invisible), and **inline system ECC**
(end-to-end, stored in reserved columns). (Rev 1.4: inline system ECC is not integrated; its
columns are reserved, but nothing encodes or checks stored data. Link ECC is integrated, with
retry disabled, OPEN-9.)

**MBIST** — Memory built-in self test. Needed for the write buffer and ECC cache (the ECC cache
is not integrated in Rev 1.4).

**Patrol scrub** — Background reads at lowest priority that find and correct latent errors
before they accumulate into uncorrectable ones. (Rev 1.4: not integrated; `hbm4_scrub` is not
instantiated.)

**Poison** — Marking data as known-bad so a later reader is told rather than silently misled.
Propagated, never re-reported — one fault yields one log entry. (Rev 1.4: not available. Poison
is stored in the inline-ECC field, and neither inline ECC nor the error log, `hbm4_err_log`, is
integrated.)

**PPR (Post Package Repair)** — Replacing a failed row with a spare. **Soft** is volatile;
**hard** is permanent and irreversible.

**RAA (Rolling Accumulated ACT)** — Per-bank activate counter used to trigger row-hammer
mitigation.

**SDC (Silent Data Corruption)** — Wrong data returned with no error indication. The failure
mode inline system ECC exists to prevent, and the reason it is on by default despite costing
6.25%. (Rev 1.4: inline system ECC is not integrated. `hbm4_ecc_cache` is not instantiated
and nothing encodes or checks stored data, although its 2 of 32 columns, 6.25% of capacity,
are still reserved. See [09 Release Notes](09-release-notes.md).)

**SECDED** — Single Error Correct, Double Error Detect. The baseline ECC strength; the code
used here is Hsiao SEC-DED(266,256), not the stronger single-4-bit-symbol-correcting code once
specified (OPEN-7).

---

## Verification terms

**BMC (Bounded Model Checking)** — Formal search for a property violation within N cycles.
Fast; proves nothing beyond depth N.

**cocotb** — Python testbench framework used for this design's simulation environment.

**`eqy`** — Yosys-based equivalence checker.

**k-induction** — Formal technique proving a property holds for all time. Usually needs
hand-written strengthening invariants.

**`mcy`** — Mutation Cover with Yosys: injects bugs and reports what fraction your properties
catch. The real answer to "are my properties strong enough?"

**Miter** — Two copies of a design compared for equivalence or distinctness. Used here for
address-map bijectivity (P-MAP-1) and fabric-vs-controller decode (P-MAP-3).

**PDR / IC3** — An unbounded model-checking algorithm; `abc pdr` in this flow.

**PyVSC** — Python constrained-random and functional-coverage library.

**Shadow state** — Checker-side logic that independently tracks what the DUT should be doing.
Must be written independently of the DUT, or a shared bug becomes invisible.

**SVA (SystemVerilog Assertions)** — The property language. This project uses a restricted
subset accepted by both Yosys and Verilator.

**SymbiYosys / `sby`** — The open-source formal verification driver used throughout
[06-verification-plan.md](06-verification-plan.md).

**Verilator** — Fast open-source simulator that compiles SystemVerilog to C++. 2-state by
default, which is why an Icarus Verilog reset suite exists alongside it.

**WaveDrom** — The timing-diagram format used in `docs/waves/`. The `.json` files are the
editable source.

**yosys-slang** — Yosys plugin providing SystemVerilog front-end support via the `slang`
parser.
