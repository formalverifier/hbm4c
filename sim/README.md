# Simulation environment

**Rev 1.0** · cocotb 2.0.1 + Verilator 5.050 · [verification plan](../docs/06-verification-plan.md)

Runs one pseudo-channel slice, and one stack, at reduced geometry (`-DFV_SMALL`) — the same
configuration the formal proofs use —
and the slice again at production geometry (`GEOM=full`), so a failure here and a failure there refer to the same design. See
[formal/SCALING.md](../formal/SCALING.md) for why the reduced geometry is shaped as it is.

## Running

```bash
python3 -m venv ../.venv && ../.venv/bin/pip install cocotb
PATH=../.venv/bin:$PATH make          # all tests
PATH=../.venv/bin:$PATH MODULE=test_debug make    # command-trace debug
```

## What is here

| File | Role |
|---|---|
| `tb_pc_slice.sv` | type adapter only — flattens packed structs and enums for VPI |
| `hbm4_dram_model.py` | DRAM model + **independent** JEDEC timing checker |
| `testbench.py` | NHI driver (credits), DFI monitor, read-return path |
| `test_slice.py` | the tests |

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

## Running the two suites

```bash
PATH=../.venv/bin:$PATH make                                   # slice, reduced geometry
PATH=../.venv/bin:$PATH GEOM=full make GEOM=full               # slice, production geometry
PATH=../.venv/bin:$PATH TOPLEVEL=tb_stack_top MODULE=test_boot make   # boot sequence
```

`GEOM=full` is not optional for the efficiency test: `TQ_DEPTH` is 4 under `FV_SMALL`, so at
most four transactions are ever outstanding and the column bus cannot be saturated no matter how
good the scheduler is. The test skips itself at reduced geometry rather than report a number
that describes the testbench.

Each toplevel and geometry gets its own build directory. Sharing one means the second run
reuses the first's compiled model and fails with "cannot find root handle" — or worse, silently
simulates the wrong top.

## Results (Rev 1.0)

| Suite | Geometry | Result |
|---|---|---|
| `test_slice.py` | production | **10/10** — incl. 98.8% column-bus utilisation |
| `test_slice.py` | reduced | 9 pass, efficiency skipped |
| `test_boot.py` (stack) | reduced | **6/6** — MRS + PHY + PREA all reach the device |
| `test_system.py` (system) | reduced | **5/5** — parallel boot, failure propagation, freeze edge |

## Known gaps

- System tests cover boot and control only; **sustained multi-stack traffic is untested**.
- No signed timing or power — see [syn/README.md](../syn/README.md).
- All `(P)` timing values are placeholders pending the device datasheet.
