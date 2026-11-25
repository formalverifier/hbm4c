"""cocotb environment for one HBM4 pseudo-channel slice.

Structure:
  NhiDriver    drives the host side, tracks credits, checks responses
  DfiMonitor   watches the DRAM side and feeds every command to DramModel
  Scoreboard   end-to-end data check: what the host reads is what it wrote

The DfiMonitor is where the independent timing checker actually bites.  Every
command the controller issues is replayed into the model on the cycle it is
issued, and the model raises on the first parameter violation -- so a scheduling
bug fails the test at the command that caused it, not thousands of cycles later
as corrupted data.
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from hbm4_dram_model import (DramModel, Timing, small_timing, TimingViolation,
                             ROW_NOP, COL_NOP, ROW_NAME, COL_NAME)

# Reduced geometry -- must match hbm4_pkg under -DFV_SMALL
import os

# Must track hbm4_pkg for the geometry the DUT was BUILT with.  A checker whose
# geometry disagrees with the device reports confident, wrong findings -- the
# same failure as using production timings against a reduced-config DUT.
if os.environ.get("GEOM", "small") == "full":
    N_BANK, N_BG, N_ROW, N_COL_DATA = 32, 4, 32768, 30
    TQ_DEPTH = 64
else:
    N_BANK, N_BG, N_ROW, N_COL_DATA = 8, 2, 8, 15
    TQ_DEPTH = 4      # initial credits per NHI port (docs/03 §7)


class DfiMonitor:
    """Replays the DFI command stream into the reference DRAM model.

    1:2 gearing: each core clock carries TWO DFI phases, and they are ordered --
    phase 0 precedes phase 1.  Feeding them in the wrong order, or as if they
    were simultaneous, would make tCCD_S look violated on legal back-to-back
    column commands.  The model is therefore ticked at DFI phase resolution.
    """

    def __init__(self, dut, model, log):
        self.dut, self.model, self.log = dut, model, log
        self.cycle = 0
        self.col_log = []          # (phase_cycle, cmd, bank, col)
        self.row_log = []

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            if not self.dut.rst_n.value:
                self.cycle += 2
                continue
            for ph in range(2):
                t = self.cycle + ph
                rv = (int(self.dut.dfi_row_valid.value) >> ph) & 1
                if rv:
                    cmd = self._sl(self.dut.dfi_row_cmd, ph, 3)
                    bk = self._sl(self.dut.dfi_row_bank, ph, N_BANK.bit_length() - 1)
                    rw = self._sl(self.dut.dfi_row_addr, ph, N_ROW.bit_length() - 1)
                    self.model.row_cmd(t, cmd, bk, rw)
                    self.row_log.append((t, cmd, bk, rw))
                cv = (int(self.dut.dfi_col_valid.value) >> ph) & 1
                if cv:
                    cmd = self._sl(self.dut.dfi_col_cmd, ph, 3)
                    bk = self._sl(self.dut.dfi_col_bank, ph, N_BANK.bit_length() - 1)
                    cl = self._sl(self.dut.dfi_col_addr, ph, (N_COL_DATA + 1).bit_length() - 1)
                    # Hand the model the WRITE DATA the controller is actually
                    # driving. Without this the reference array is never written,
                    # and every "did the right data land" check is vacuous --
                    # which is exactly what test_write_read_data was before the
                    # write datapath existed.
                    wd = None
                    if cmd in (2, 4) and int(self.dut.dfi_wrdata_valid.value):
                        wd = int(self.dut.dfi_wrdata.value)
                    self.model.col_cmd(t, cmd, bk, cl, wdata=wd)
                    self.col_log.append((t, cmd, bk, cl))
            self.cycle += 2

    def pending_returns(self, cycle, tRL):
        """Read commands seen at `cycle`, due to return data at cycle + tRL."""
        return [(t + tRL, bk, cl) for (t, cmd, bk, cl) in self.col_log
                if cmd in (1, 3) and t + tRL == cycle]      # COL_RD, COL_RDA

    @staticmethod
    def _sl(sig, ph, w):
        """Extract phase `ph` from a packed [1:0][w-1:0] bus."""
        return (int(sig.value) >> (ph * w)) & ((1 << w) - 1)


class NhiDriver:
    """Host front-end driver with credit accounting.

    Credit is a promise: the controller asserts req_credit to say it can accept
    one more transaction.  Issuing without credit is the host violating the
    contract, so the driver never does it -- and a test that wedges here has
    found a controller that stopped returning credit, which is exactly the
    NHI outstanding-underflow bug formal caught.
    """

    def __init__(self, dut, log):
        self.dut, self.log = dut, log
        # The host starts with TQ_DEPTH credits and req_credit RETURNS them one
        # per completion -- it is not an initial grant.  Modelling it as a grant
        # (starting at zero and waiting to be given permission) deadlocks against
        # a perfectly correct controller, because nothing is ever completed to
        # return a credit for.  docs/03 §7.
        self.credits = TQ_DEPTH
        # Tags must be UNIQUE among outstanding transactions -- docs/03 rule H2,
        # and the write-data path depends on it (hbm4_wdata_ram is indexed by
        # tag). A driver that cycles tags round-robin regardless of what is in
        # flight violates that: the pool issues by bank rather than in request
        # order, so an early tag can still be queued long after later ones have
        # completed, and reusing it overwrites its write data with a newer
        # block's. That is a host-protocol violation, not a controller bug, but
        # it corrupts memory just the same -- so the driver must model a
        # conforming host.
        self.free_tags = list(range(TQ_DEPTH))
        self.inflight = {}
        self.outstanding = {}
        self.completed = []
        self.next_tag = 0
        # Tags must be UNIQUE among outstanding transactions -- docs/03 rule H2 --
        # and the write-data path depends on it, since hbm4_wdata_ram is indexed
        # by tag. Cycling tags round-robin regardless of what is in flight
        # violates that: the pool issues by BANK, not in request order, so an
        # early tag can still be queued long after later ones completed, and
        # reusing it overwrites its write data with a newer block's. A
        # host-protocol violation rather than a controller bug -- but it corrupts
        # memory just the same, so the driver has to model a conforming host.
        self.free_tags = list(range(TQ_DEPTH))

    async def credit_counter(self):
        while True:
            await RisingEdge(self.dut.clk)
            if not self.dut.rst_n.value:
                self.credits = TQ_DEPTH
                self.free_tags = list(range(TQ_DEPTH))
                continue
            if int(self.dut.req_credit.value):
                self.credits += 1

    async def send(self, is_write, blk, data=None):
        while self.credits <= 0:
            await RisingEdge(self.dut.clk)
        while not self.free_tags:
            await RisingEdge(self.dut.clk)
        tag = self.free_tags.pop(0)
        self.dut.req_valid.value = 1
        self.dut.req_wr.value = 1 if is_write else 0
        self.dut.req_blk.value = blk
        self.dut.req_tag.value = tag
        self.dut.req_qos.value = 0
        self.dut.req_data.value = data if (is_write and data is not None) else 0
        await RisingEdge(self.dut.clk)
        self.dut.req_valid.value = 0
        self.credits -= 1
        self.outstanding[tag] = (is_write, blk, data)
        return tag

    async def collect(self):
        self.dut.rsp_ready.value = 1
        while True:
            await RisingEdge(self.dut.clk)
            if not self.dut.rst_n.value:
                continue
            if int(self.dut.rsp_valid.value):
                tag = int(self.dut.rsp_tag.value)
                if tag not in self.free_tags:
                    self.free_tags.append(tag)
                self.completed.append(
                    (tag, int(self.dut.rsp_data.value),
                     int(self.dut.rsp_err.value), int(self.dut.rsp_wack.value)))


class ReadReturn:
    """Returns read data to the controller tRL after each column read.

    WITHOUT THIS NOTHING COMPLETES.  The controller issues the read, parks the
    transaction in the read-pointer FIFO, and waits for dfi_rddata_valid.  A
    testbench that only watches the command bus sees a perfectly healthy
    scheduler and a host that never gets an answer -- which is exactly what the
    first version did, and it looked like a controller deadlock.

    Data is returned as ZERO with a ZERO link-ECC code.  The codec is linear, so
    all-zero is a valid codeword and the return path stays clean; a test that
    wants to check data content sets `self.data_fn`.
    """

    def __init__(self, dut, monitor, tRL):
        self.dut, self.mon, self.tRL = dut, monitor, tRL
        self.queue = []
        self.returned = 0
        self.data_fn = None

    async def run(self):
        seen = 0
        while True:
            await RisingEdge(self.dut.clk)
            self.dut.dfi_rddata_valid.value = 0
            if not self.dut.rst_n.value:
                continue
            # Newly observed reads join the queue with their due time.
            while seen < len(self.mon.col_log):
                t, cmd, bk, cl = self.mon.col_log[seen]
                seen += 1
                if cmd in (1, 3):                     # COL_RD / COL_RDA
                    self.queue.append((t + self.tRL, bk, cl))
            if self.queue and self.mon.cycle >= self.queue[0][0]:
                _, bk, cl = self.queue.pop(0)
                data = self.data_fn(bk, cl) if self.data_fn else 0
                self.dut.dfi_rddata_valid.value = 1
                self.dut.dfi_rddata.value = data
                self.dut.dfi_rdcode.value = 0
                self.returned += 1


async def setup(dut, refi=2000, rfm_en=0, open_gate=True):
    """Bring the slice up.  Returns (driver, monitor, model)."""
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())

    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.req_wr.value = 0
    dut.req_blk.value = 0
    dut.req_tag.value = 0
    dut.req_qos.value = 0
    dut.req_data.value = 0
    dut.rsp_ready.value = 0
    dut.cfg_wr_hi.value = 24
    dut.cfg_wr_lo.value = 8
    dut.cfg_wr_burst.value = 16
    dut.cfg_wr_age_limit.value = 5000
    dut.cfg_wr_preempt.value = 0
    dut.cfg_refi_pb.value = refi
    dut.cfg_refi_phase.value = 0
    dut.cfg_rfm_thresh.value = 32
    dut.cfg_raa_imt.value = 4
    dut.cfg_rfm_en.value = rfm_en
    dut.cmd_en.value = 0        # boot gate closed; opened by setup() below
    dut.dfi_rddata_valid.value = 0
    dut.dfi_rddata.value = 0
    dut.dfi_rdcode.value = 0

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # Stand in for the stack's training sequencer.  In the real system cmd_en is
    # driven by hbm4_stack_top from boot_done; here the tests open it explicitly
    # so that "before training" and "after training" are both reachable states.
    if open_gate:
        dut.cmd_en.value = 1
        await ClockCycles(dut.clk, 1)

    # small_timing(), not Timing(): the DUT is built with -DFV_SMALL and is
    # configured with the reduced timing set.  See hbm4_dram_model.small_timing.
    tset = small_timing() if os.environ.get('GEOM','small') != 'full' else Timing()
    model = DramModel(N_BANK, N_BG, N_ROW, N_COL_DATA, tset, dut._log)
    drv = NhiDriver(dut, dut._log)
    mon = DfiMonitor(dut, model, dut._log)
    cocotb.start_soon(drv.credit_counter())
    cocotb.start_soon(drv.collect())
    rdret = ReadReturn(dut, mon, tset.tRL)
    cocotb.start_soon(mon.run())
    cocotb.start_soon(rdret.run())
    return drv, mon, model, rdret
