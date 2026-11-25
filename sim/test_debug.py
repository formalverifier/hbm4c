import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from testbench import setup, TQ_DEPTH
from hbm4_dram_model import ROW_NAME, COL_NAME

@cocotb.test()
async def test_progress(dut):
    drv, mon, model, rdret = await setup(dut)
    # Fire-and-forget: do NOT wait on credits, so a credit stall cannot be
    # mistaken for a scheduling stall.
    for i in range(4):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 400)
    rows = [(t, ROW_NAME.get(c,'?'), b) for t,c,b,_ in mon.row_log]
    cols = [(t, COL_NAME.get(c,'?'), b) for t,c,b,_ in mon.col_log]
    dut._log.info(f"ROW commands ({len(rows)}): {rows[:24]}")
    dut._log.info(f"COL commands ({len(cols)}): {cols[:16]}")
    dut._log.info(f"returned={rdret.returned} completed={len(drv.completed)} credits={drv.credits} "
                  f"occ={int(dut.occupancy.value)} debt={int(dut.sts_ref_debt.value)}")
