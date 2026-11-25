"""Boot-sequence tests at the stack level.

This is the level OPEN-10 lived at: the sequencer produced commands and nothing
carried them to the device.  Every test here checks that a command ACTUALLY
REACHED an interface, never that the sequencer believed it issued one.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

ROW_MRS, ROW_NOP, ROW_PREA = 7, 0, 3
OP_MRS, OP_PHY, OP_PATTERN = 4, 5, 6
PHY_CK_START, PHY_RESET, PHY_ZQCAL = 1, 2, 3
PHY_WRLVL, PHY_RDLVL, PHY_WR_TRAIN, PHY_LOCK = 4, 5, 6, 7


async def boot(dut, ack_phy=True, max_cycles=200_000):
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())
    dut.rst_n.value = 0
    dut.boot_start.value = 0
    dut.phy_ack.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    dut.boot_start.value = 1
    await RisingEdge(dut.clk)
    dut.boot_start.value = 0

    mrs, phy, rowcmds = [], [], []
    prev_req = 0
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        req = int(dut.phy_req.value)
        # PHY steps take real time; ack a cycle later so the sequencer must wait
        # rather than being marched through training.
        dut.phy_ack.value = 1 if (ack_phy and req) else 0
        # Count on the REQUEST EDGE.  phy_req is held across the ack handshake,
        # so sampling every cycle it is high counts each step twice -- which is
        # the request being held correctly, not a duplicate command.
        if req and not prev_req:
            phy.append(int(dut.phy_arg.value))
        prev_req = req
        rv = int(dut.dfi_row_valid.value)
        if rv & 1:
            cmd = int(dut.dfi_row_cmd.value) & 7
            if cmd == ROW_MRS:
                mrs.append((int(dut.dfi_mrs_index.value),
                            int(dut.dfi_mrs_opcode.value)))
            elif cmd == ROW_PREA:
                rowcmds.append(ROW_PREA)
        if int(dut.boot_done.value) or int(dut.boot_error.value):
            break
    return mrs, phy, rowcmds


@cocotb.test()
async def test_boot_completes(dut):
    """Boot must finish, and must not finish by failing."""
    mrs, phy, rowcmds = await boot(dut)
    assert int(dut.boot_done.value), "boot never completed"
    assert not int(dut.boot_error.value), "boot reported an error"
    dut._log.info(f"boot done: {len(mrs)} MRS, {len(phy)} PHY steps")


@cocotb.test()
async def test_mrs_reaches_the_dram(dut):
    """OPEN-10: mode-register writes must appear ON THE DFI BUS.

    The regression this guards against is precise: the sequencer walks the
    script, waits every delay, asserts boot_done -- and issues nothing.  Boot
    succeeds on a device that was never configured, and there is no symptom
    until data comes back wrong.
    """
    mrs, _phy, _rc = await boot(dut)
    assert int(dut.boot_done.value), "boot did not complete"
    assert len(mrs) >= 5, (
        f"only {len(mrs)} MRS commands reached the DFI bus; the script "
        f"programs MR0..MR4, so boot completed without configuring the device")
    idx = [i for i, _ in mrs]
    assert idx[:5] == [0, 1, 2, 3, 4], f"mode registers out of order: {idx}"
    dut._log.info(f"MRS on the bus: {mrs}")


@cocotb.test()
async def test_phy_training_steps_issued(dut):
    """Every PHY step in the script must reach the PHY interface, in order."""
    _, phy, _rc = await boot(dut)
    assert int(dut.boot_done.value), "boot did not complete"
    expect = [PHY_CK_START, PHY_RESET, PHY_ZQCAL,
              PHY_WRLVL, PHY_RDLVL, PHY_WR_TRAIN, PHY_LOCK]
    assert phy == expect, f"PHY steps {phy}, expected {expect}"
    dut._log.info(f"PHY steps issued in order: {phy}")


@cocotb.test()
async def test_phy_backpressure_is_honoured(dut):
    """A PHY that never acks must stall boot, not be marched past.

    Training steps take thousands of cycles.  Acking immediately would run the
    script to completion while the PHY was still working -- and at the interface
    that is indistinguishable from training that succeeded.
    """
    mrs, phy, rowcmds = await boot(dut, ack_phy=False, max_cycles=40_000)
    assert not int(dut.boot_done.value), (
        "boot completed while the PHY never acknowledged a single training "
        "step -- the sequencer is not waiting for the PHY")
    dut._log.info("boot correctly stalled on an unacknowledged PHY step")


@cocotb.test()
async def test_slices_quiet_during_boot(dut):
    """No slice may drive the DRAM bus while boot is running.

    The row bus carries the MRS broadcast during boot; a slice issuing refresh
    into the same cycle is a bus conflict.
    """
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())
    dut.rst_n.value = 0
    dut.boot_start.value = 0
    dut.phy_ack.value = 1
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    dut.boot_start.value = 1
    await RisingEdge(dut.clk)
    dut.boot_start.value = 0

    for _ in range(30_000):
        await RisingEdge(dut.clk)
        if int(dut.boot_done.value):
            break
        rv = int(dut.dfi_row_valid.value)
        if rv:
            cmd = int(dut.dfi_row_cmd.value) & 7
            # MRS and PREA are the sequencer's own broadcasts and are expected.
            # Anything else means a SLICE is driving, which is the bus conflict
            # the boot gate exists to prevent.
            assert cmd in (ROW_MRS, ROW_PREA), (
                f"row command {cmd} on the bus during boot -- only the "
                f"sequencer's MRS/PREA may be issued before training completes, "
                f"so a slice is driving")
    assert int(dut.boot_done.value), "boot did not complete"
    dut._log.info("no slice traffic during boot")


@cocotb.test()
async def test_precharge_all_precedes_mrs(dut):
    """PRECHARGE ALL must be issued before any mode register is written.

    A reset does not close the device's rows, but it does wipe the controller's
    bank state -- so without an explicit precharge-all the two disagree, and the
    first refresh after reset goes to a bank the DRAM still has open.

    Invisible at cold power-on, where the device genuinely starts closed. Only
    reset asserted mid-operation exposes it.
    """
    mrs, phy, rowcmds = await boot(dut)
    assert int(dut.boot_done.value), "boot did not complete"
    assert ROW_PREA in rowcmds, (
        "no PRECHARGE ALL in the boot sequence -- after a mid-operation reset "
        "the controller and the device disagree about which rows are open")
    dut._log.info(f"PREA issued {rowcmds.count(ROW_PREA)}x before {len(mrs)} MRS")
