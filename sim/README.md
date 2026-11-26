# Simulation environment

**Rev 1.4** · cocotb 2.0.1 + Verilator 5.050 · [verification plan](../docs/06-verification-plan.md)

Runs one pseudo-channel slice, one stack, and the system top at reduced geometry (`-DFV_SMALL`)
— the same configuration the formal proofs use —
and the slice again at production geometry (`GEOM=full`), so a failure here and a failure there refer to the same design. See
[formal/SCALING.md](../formal/SCALING.md) for why the reduced geometry is shaped as it is.

## Running

```bash
python3 -m venv ../.venv && ../.venv/bin/pip install cocotb
PATH=../.venv/bin:$PATH make          # strict lint gate, then the slice tests (reduced geometry)
PATH=../.venv/bin:$PATH MODULE=test_debug make    # command-trace debug
```

## What is here

| File | Role |
|---|---|
| `tb_pc_slice.sv`, `tb_stack_top.sv`, `tb_sys_top.sv` | type adapters only — flatten packed structs and enums for VPI |
| `hbm4_dram_model.py` | DRAM model + **independent** JEDEC timing checker |
| `testbench.py` | slice environment: NHI driver (credits), DFI monitor, read-return path |
| `sys_testbench.py` | stack and system environment |
| `test_slice.py` | slice tests (12) |
| `test_boot.py`, `test_system.py` | stack boot (6) and system boot and control (5) |
| `test_debug.py` | command-trace debug aid, not a test |

## The checker is written independently, on purpose

The controller already contains a timing engine that decides when each command is legal. A
checker derived from that engine — or written by reading it — agrees with it by construction,
**including where it is wrong.** It would catch typos and nothing else.

So `hbm4_dram_model.py` is written from the JEDEC parameter definitions instead: for each
parameter, *"command A must be followed by command B no sooner than N cycles"*, as a
last-event timestamp and a comparison. It does not know how the controller schedules, only
what the DRAM permits. Where the two disagree, one of them is wrong.

Same principle as the shadow counters in the formal wrappers, and the reason `bg_of()` is
written out here rather than imported: a checker that shares the design's own decode cannot
detect a bug in that decode.

## Three ways this environment lied before it worked

Each was diagnosed as a DUT bug first. **A checker is code, and gets the same scrutiny as the
design.**

1. **Production timings against a reduced-config DUT.** `t_rfc_sb` is 6 in `small_timing()`,
   not 96. Back-to-back per-bank refresh looked like a gross violation and was perfectly
   legal. A checker whose parameters disagree with the device produces confident, specific,
   wrong findings — worse than no checker.
2. **The credit protocol backwards.** `req_credit` is a *return* pulse; the host starts with
   `TQ_DEPTH` credits. Modelling it as a grant deadlocks against a correct controller, because
   nothing completes to return a credit for.
3. **No read-return path.** Nothing drove `dfi_rddata_valid`, so the controller waited forever
   for data. A healthy scheduler presented as a deadlock — and note that a test which only
   counts commands on the DFI bus passes against a controller that never answers the host.

## Running the suites

```bash
PATH=../.venv/bin:$PATH make                                   # slice, reduced geometry
PATH=../.venv/bin:$PATH GEOM=full make GEOM=full               # slice, production geometry
PATH=../.venv/bin:$PATH TOPLEVEL=tb_stack_top MODULE=test_boot make   # boot sequence
PATH=../.venv/bin:$PATH TOPLEVEL=tb_sys_top MODULE=test_system make   # system, reduced geometry
```

Every run starts with the strict lint gate (`make lint`: design and testbench at `-Wall`,
warnings fatal) and stops if it fails. **Check that a run reports its tests.** In Rev 1.3 the
lint target had become make's default goal, so a plain `make` linted, reported success, and
ran no tests at all. Rev 1.4 pins the default goal and makes `sim` depend on `lint`.

`GEOM=full` is not optional for the efficiency test: `TQ_DEPTH` is 4 under `FV_SMALL`, so at
most four transactions are ever outstanding and the column bus cannot be saturated no matter how
good the scheduler is. The test skips itself at reduced geometry rather than report a number
that describes the testbench.

Each toplevel and geometry gets its own build directory. Sharing one means the second run
reuses the first's compiled model and fails with "cannot find root handle" — or worse, silently
simulates the wrong top.

## Results (Rev 1.4)

| Suite | Geometry | Result |
|---|---|---|
| `test_slice.py` | production | **12/12** — incl. 98.8% column-bus utilisation, and colliding-tag writes byte-exact |
| `test_slice.py` | reduced | 11 pass, efficiency skipped |
| `test_boot.py` (stack) | reduced | **6/6** — MRS + PHY + PREA all reach the device |
| `test_system.py` (system) | reduced: 2 stacks, 8 slices | **5/5** — parallel boot, failure propagation, freeze edge |

`test_write_data_tag_independence` (new in Rev 1.4) writes with one tag reused across
outstanding writes, and with tags 64 apart, holding the boot gate closed while sending so that
every write is provably in flight at once. Against Rev 1.3 RTL it fails: 3 of 4 blocks hold
another write's data at reduced geometry, and 19 of 36 at production geometry.

## Known gaps

- System tests cover boot and control only, at reduced geometry; **no data traffic runs at
  system level**, and the 256-slice production system has never been simulated.
- Out-of-range requests get no response and leak a credit (formal/ASSUMPTIONS.md OPEN-13).
  No test covers them yet.
- **Every test holds `rsp_ready` high**, and `NhiDriver.collect` records each cycle that
  `rsp_valid` is high rather than each handshake. So back-pressure is untested, and it loses
  responses (OPEN-16).
- No test checks that every request in mixed traffic is answered. Under mixed traffic at
  production geometry some write acks are lost (OPEN-17).
- `test_raw_hazard` sends one write per block. A second queued write to the same block is
  unprotected (OPEN-15).
- No signed timing or power — see [syn/README.md](../syn/README.md).
- All `(P)` timing values are placeholders pending the device datasheet.
