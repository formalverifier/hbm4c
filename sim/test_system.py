"""System-level tests -- hbm4_sys_top and hbm4_supervisor.

These two modules had only ever been linted. The identical gap one level down
hid OPEN-10, where boot reported success while issuing nothing at all, so every
test here checks an OBSERVED interface event, never an internal belief.

Everything asserted below is only visible at this level. Anything provable at
the stack or slice level belongs in test_boot.py or test_slice.py.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Reduced geometry, matching hbm4_pkg under -DFV_SMALL.
N_STACK = 2
N_PC_PER_STACK = 4
N_PC_TOTAL = N_STACK * N_PC_PER_STACK
ROW_MRS, ROW_PREA = 7, 3


async def start(dut, ack_mask=None):
    """Reset, then assert boot_start. ack_mask selects which stacks' PHYs respond."""
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())
    dut.rst_n.value = 0
    dut.boot_start.value = 0
    dut.phy_ack.value = 0
    dut.req_valid.value = 0
    dut.req_wr.value = 0
    dut.req_blk.value = 0
    dut.req_tag.value = 0
    dut.perf_snapshot_req.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    dut.boot_start.value = 1
    await RisingEdge(dut.clk)
    dut.boot_start.value = 0


async def run_boot(dut, ack_mask=(1 << N_STACK) - 1, limit=200_000):
    """Drive phy_ack for the selected stacks; record when each stack finishes.

    A stack is considered finished the last time it asked for a PHY step, which
    is the only per-stack progress signal visible at this boundary.
    """
    await start(dut)
    last_req = [0] * N_STACK
    mrs_seen = [0] * N_STACK
    cyc = 0
    for cyc in range(limit):
        await RisingEdge(dut.clk)
        req = int(dut.phy_req.value)
        dut.phy_ack.value = req & ack_mask
        for s in range(N_STACK):
            if (req >> s) & 1:
                last_req[s] = cyc
        rv = int(dut.dfi_row_valid.value)
        rc = int(dut.dfi_row_cmd.value)
        for s in range(N_STACK):
            # Phase-0 command of the first pseudo-channel in each stack. Buses are
            # packed [N_PC_TOTAL-1:0][1:0] and [N_PC_TOTAL-1:0][1:0][2:0], so the
            # phase-0 bit of pseudo-channel `pc` sits at pc*2, and its command
            # field at pc*6.
            pc = s * N_PC_PER_STACK
            if (rv >> (pc * 2)) & 1 and ((rc >> (pc * 6)) & 7) == ROW_MRS:
                mrs_seen[s] += 1
        if int(dut.ctrl_ready.value) or int(dut.boot_failed.value):
            break
    return cyc, last_req, mrs_seen


@cocotb.test()
async def test_all_stacks_boot(dut):
    """ctrl_ready must assert, and every stack must actually have been trained."""
    cyc, last_req, mrs = await run_boot(dut)
    assert int(dut.ctrl_ready.value), \
        f"ctrl_ready never asserted after {cyc} cycles (boot_failed={int(dut.boot_failed.value)})"
    assert not int(dut.boot_failed.value), "boot reported failure with all PHYs acking"
    for s in range(N_STACK):
        assert last_req[s] > 0, f"stack {s} never issued a PHY training step"
    dut._log.info(f"ctrl_ready at cycle {cyc}; last PHY step per stack: {last_req}")


@cocotb.test()
async def test_stacks_train_in_parallel(dut):
    """Stacks must train concurrently, not one after another.

    Serialised boot is functionally correct and would pass every other test here,
    so nothing else catches it -- but it multiplies a ~200 us boot by the stack
    count, and at N_STACK=4 that is most of a millisecond of extra downtime.

    The check: each stack's last training step must land at a similar time. If
    stack 1 only starts once stack 0 has finished, its finish time is roughly
    double.
    """
    cyc, last_req, _ = await run_boot(dut)
    assert int(dut.ctrl_ready.value), "boot did not complete"
    spread = max(last_req) - min(last_req)
    latest = max(last_req)
    assert spread < latest * 0.4, (
        f"stacks finished at {last_req} -- spread {spread} of {latest} cycles. "
        f"That is serialised boot, not parallel: each stack is waiting for the "
        f"previous one")
    dut._log.info(f"parallel boot: finishes at {last_req}, spread {spread} cycles")


@cocotb.test()
async def test_one_stack_failure_fails_boot(dut):
    """If any stack cannot train, the whole boot must FAIL -- visibly.

    Stack 1's PHY never acknowledges. The supervisor must not assert ctrl_ready,
    and must not hang silently either: boot_failed has to come up so software
    sees a fault rather than a controller that is simply never ready.
    """
    cyc, last_req, _ = await run_boot(dut, ack_mask=0b01, limit=120_000)

    assert not int(dut.ctrl_ready.value), (
        "ctrl_ready asserted while stack 1's PHY never acknowledged a single "
        "training step -- the system would release traffic to an untrained stack")
    assert int(dut.boot_failed.value), (
        f"after {cyc} cycles with stack 1 dead, boot_failed is still low and "
        f"ctrl_ready is low: the failure is invisible to software, which sees "
        f"only a controller that never becomes ready")
    dut._log.info(f"dead stack correctly failed the boot at cycle {cyc}")


@cocotb.test()
async def test_no_traffic_before_ready(dut):
    """No column command anywhere in the system before ctrl_ready.

    A column command needs an open row. Before training completes there is none,
    so any column activity here means a slice escaped its boot gate.
    """
    await start(dut)
    for _ in range(60_000):
        await RisingEdge(dut.clk)
        dut.phy_ack.value = int(dut.phy_req.value)
        if int(dut.ctrl_ready.value):
            break
        assert int(dut.dfi_col_valid.value) == 0, \
            "column command issued somewhere in the system before ctrl_ready"
    assert int(dut.ctrl_ready.value), "boot did not complete"
    dut._log.info("no column traffic anywhere before ctrl_ready")


@cocotb.test()
async def test_perf_snapshot_single_edge(dut):
    """perf_freeze must be a single pulse per request, not a level.

    The supervisor freezes every stack's counters on one edge so the snapshot is
    coherent across stacks. A freeze that stays asserted stops the counters
    permanently and every later reading is stale -- which looks like a working
    system with suspiciously round numbers.
    """
    cyc, _, _ = await run_boot(dut)
    assert int(dut.ctrl_ready.value), "boot did not complete"

    dut.perf_snapshot_req.value = 1
    pulses, was = 0, 0
    for _ in range(50):
        await RisingEdge(dut.clk)
        now = int(dut.perf_freeze.value)
        if now and not was:
            pulses += 1
        was = now
    dut.perf_snapshot_req.value = 0
    await ClockCycles(dut.clk, 5)

    assert pulses == 1, (
        f"perf_freeze produced {pulses} rising edges while the request was held; "
        f"expected exactly one -- a level-sensitive freeze stalls the counters")
    dut._log.info("perf_freeze: exactly one edge per held request")
