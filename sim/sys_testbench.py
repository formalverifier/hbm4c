"""cocotb environment for the WHOLE controller -- every pseudo-channel at once.

testbench.py drives one slice: scalar ports, one DRAM model, one read-return
path.  Nothing in it survives being pointed at hbm4_sys_top, where every
interface is a packed array of N_PC_TOTAL elements and the question being asked
is no longer "does this slice schedule legally" but "does a slice in one stack
disturb a slice in another".

Three things are structurally different here, and each of them is a bug the
obvious approach produces:

  ONE DRIVER, NOT N.  Eight per-port coroutines writing bit-slices of the same
  packed input vector in the same delta cycle leave whichever ran last; the
  other seven requests are silently lost and it presents as a controller that
  drops transactions.  So there is exactly one coroutine, it owns every input,
  and per-port logic is plain code it calls.

  ONE MODEL PER PSEUDO-CHANNEL.  A single DRAM model fed from all eight command
  streams would flag tCCD and tRRD violations between commands that are on
  physically different buses -- the checker would be inventing the very
  cross-channel coupling the architecture exists to avoid.  Each pseudo-channel
  gets its own hbm4_dram_model.DramModel, and the timing checker is live on all
  of them simultaneously.

  READ DATA MUST COME BACK.  With dfi_rddata_valid tied low nothing completes
  (sim/README.md, "three ways this environment lied").  The return path here
  also carries a per-pseudo-channel PAYLOAD with a correct link-ECC code, so
  "stack 1's data arrived at stack 0's port" is detectable rather than invisible
  -- which is the whole point of running the stacks concurrently.
"""

import os
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from hbm4_dram_model import (DramModel, small_timing, Timing, TimingViolation,
                             ROW_NAME, COL_NAME)

# Reduced geometry -- must match hbm4_pkg under -DFV_SMALL.  Everything that can
# be derived from the DUT's own port widths IS derived (see SysHarness), because
# a harness constant that has drifted from the RTL slices the wrong bits out of
# a packed bus and then reports confident nonsense about the wrong bank.
N_BANK, N_BG, N_ROW, N_COL_DATA = 8, 2, 8, 15
TQ_DEPTH = 4                      # initial credits per NHI port (docs/03 7)
DFI_DATA_W = 256

# Largest legal block address: rem = blk >> (BG_W+BA_W) must be <= REM_MAX.
# Above it hbm4_addr_decode raises out-of-range and the transaction is dropped
# by design -- a stimulus generator that wanders up there would look like lost
# traffic.
BLK_MAX = (N_ROW * N_COL_DATA) * (N_BANK) - 1

ROW_ACT, ROW_PRE, ROW_PREA, ROW_MRS = 1, 2, 3, 7
COL_RD, COL_RDA = 1, 3


# ---------------------------------------------------------------------------
# link-ECC codec, encode side
# ---------------------------------------------------------------------------
# Written from the CONSTRUCTION described in hbm4_sys_ecc's header -- Hsiao
# SEC-DED, H columns are the distinct odd-weight, weight>=3 values of SW bits in
# increasing order -- not by reading the RTL's syndrome function.  Same rule as
# the DRAM timing checker: a codec copied from the design agrees with it
# wherever it is wrong.
#
# If this encode were wrong, the DUT would flag CE or UE on data the testbench
# believes is clean, and every rsp_err assertion below would fire.  The failure
# is loud, not silent, which is the property that makes an independent
# reimplementation safe to rely on.
_SW = 10


def _h_columns(dw=DFI_DATA_W, sw=_SW):
    cols = []
    for v in range(1, 1 << sw):
        w = bin(v).count("1")
        if w >= 3 and (w & 1):
            cols.append(v)
            if len(cols) == dw:
                break
    assert len(cols) == dw, "not enough odd-weight columns for the H matrix"
    return cols


_H = _h_columns()
_ecc_cache = {}


def ecc_field(data):
    """The check field hbm4_sys_ecc would have stored for `data`."""
    f = _ecc_cache.get(data)
    if f is None:
        s = 0
        d = data
        i = 0
        while d:
            if d & 1:
                s ^= _H[i]
            d >>= 1
            i += 1
        f = s                       # bit SW is poison, left clear
        _ecc_cache[data] = f
    return f


# A nonzero EVEN-weight syndrome delta can never equal a column of H, so it is
# detected and never miscorrected: a guaranteed uncorrectable.  This is the
# defining property of the code, so injecting with it does not depend on any
# implementation detail.
UE_DELTA = 0b11


def _width(handle):
    try:
        return len(handle)
    except TypeError:
        return len(handle.value)


# ---------------------------------------------------------------------------
# per-port state
# ---------------------------------------------------------------------------
class Port:
    """One NHI port: stimulus, credit accounting, response checking.

    Credit is a promise the CONTROLLER makes: the host starts with TQ_DEPTH and
    req_credit returns one per completion (docs/03 7).  This never issues
    without a credit in hand, so a port that stops making progress has found a
    controller that stopped returning them -- it does not paper over it by
    issuing anyway.
    """

    def __init__(self, pc, n_pc_per_stack):
        self.pc = pc
        self.stack = pc // n_pc_per_stack
        self.credits = TQ_DEPTH
        self.gen = None                 # callable -> (is_write, blk) or None
        self.issued = 0
        self.credit_pulses = 0
        self.responses = 0
        self.rd_rsp = self.wr_rsp = 0
        self.err_rsp = 0
        self.err_codes = {}
        self.next_tag = 0
        self.out_tags = []              # tags issued and not yet answered
        self.tag_errors = []
        self.expect_rd = deque()        # payloads handed to this PC's DFI, in order
        self.check_data = True
        self.data_errors = []
        self.max_outstanding = 0

    @property
    def outstanding(self):
        return self.issued - self.responses


# ---------------------------------------------------------------------------
# the harness
# ---------------------------------------------------------------------------
class SysHarness:
    """Drives and checks every pseudo-channel of hbm4_sys_top from one loop."""

    def __init__(self, dut, tset=None):
        self.dut = dut
        self.t = tset or (small_timing() if os.environ.get("GEOM", "small") != "full"
                          else Timing())

        # Geometry from the DUT's own ports.  N_PC_TOTAL and N_STACK are the two
        # numbers every packed slice index depends on; taking them from the
        # device instead of a constant means a geometry change cannot leave the
        # harness reading the wrong bits.
        self.n_pc = _width(dut.dfi_rddata_valid)
        self.n_stack = _width(dut.phy_req)
        self.n_pc_per_stack = self.n_pc // self.n_stack

        self.w_blk = _width(dut.req_blk) // self.n_pc
        self.w_tag = _width(dut.req_tag) // self.n_pc
        self.w_data = _width(dut.dfi_rddata) // self.n_pc
        self.w_code = _width(dut.dfi_rdcode) // self.n_pc
        # The command buses carry TWO DFI phases per core clock (1:2 gearing),
        # so every field width divides by 2*n_pc.
        self.w_rcmd = _width(dut.dfi_row_cmd) // (self.n_pc * 2)
        self.w_rbank = _width(dut.dfi_row_bank) // (self.n_pc * 2)
        self.w_raddr = _width(dut.dfi_row_addr) // (self.n_pc * 2)
        self.w_ccmd = _width(dut.dfi_col_cmd) // (self.n_pc * 2)
        self.w_cbank = _width(dut.dfi_col_bank) // (self.n_pc * 2)
        self.w_caddr = _width(dut.dfi_col_addr) // (self.n_pc * 2)

        assert self.w_rbank == (N_BANK.bit_length() - 1), (
            f"bank field is {self.w_rbank} bits, geometry says "
            f"{N_BANK.bit_length() - 1} -- the harness and hbm4_pkg disagree")

        self.data_mask = (1 << self.w_data) - 1

        self.ports = [Port(p, self.n_pc_per_stack) for p in range(self.n_pc)]
        self.model = [DramModel(N_BANK, N_BG, N_ROW, N_COL_DATA, self.t, None)
                      for _ in range(self.n_pc)]
        self.stopped = [False] * self.n_pc      # model gave up after a violation
        self.viol = []                          # (pc, text) first per pc

        self.col_log = [[] for _ in range(self.n_pc)]   # (phase, cmd, bank, col)
        self.n_mrs = 0                          # MRS on the row bus after boot
        self.rd_q = [deque() for _ in range(self.n_pc)]  # (due_phase, bank, col)
        self.rd_returned = [0] * self.n_pc
        self.max_rd_q = 0

        self.cycle = 0          # core clocks since the harness started
        self.phase = 0          # DFI phases, two per core clock
        self.credit_mismatch = []

        # Injection controls, set by tests.
        self.corrupt = set()    # pseudo-channels whose returned code is broken
        self.payload = lambda pc, bank, col: (
            (0x5A5A << 40) | (pc << 24) | (bank << 8) | col)

    # ---- geometry helpers -------------------------------------------------
    def stack_of(self, pc):
        return pc // self.n_pc_per_stack

    def pcs_of(self, stack):
        lo = stack * self.n_pc_per_stack
        return range(lo, lo + self.n_pc_per_stack)

    # ---- stimulus ---------------------------------------------------------
    def stream(self, pcs, wr_frac=0.0, base=0, count=None, seed=0):
        """Attach a sustained generator to each listed pseudo-channel.

        Addresses walk the low bits first, which sweeps bank group then bank
        before advancing the row -- the pattern the address map is designed for
        and the one that keeps the column bus busy.
        """
        import random as _random
        for i, pc in enumerate(pcs):
            rng = _random.Random(seed + 1000 * pc)
            state = {"n": 0}

            def gen(pc=pc, rng=rng, state=state, wr_frac=wr_frac, base=base,
                    count=count):
                if count is not None and state["n"] >= count:
                    return None
                blk = (base + state["n"] * 1 + pc * 37) % (BLK_MAX + 1)
                state["n"] += 1
                return (rng.random() < wr_frac, blk)

            self.ports[pc].gen = gen

    def quiesce(self):
        for p in self.ports:
            p.gen = None

    # ---- the single driver ------------------------------------------------
    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            if not dut.rst_n.value:
                continue
            self._sample_dfi()
            self._sample_responses()
            self._drive_rddata()
            self._drive_requests()
            self.cycle += 1
            self.phase += 2

    # ---- DFI command capture ---------------------------------------------
    def _sample_dfi(self):
        dut = self.dut
        rv = int(dut.dfi_row_valid.value)
        cv = int(dut.dfi_col_valid.value)
        if rv:
            rcmd = int(dut.dfi_row_cmd.value)
            rbank = int(dut.dfi_row_bank.value)
            raddr = int(dut.dfi_row_addr.value)
            for p in range(self.n_pc):
                for ph in range(2):
                    if not (rv >> (p * 2 + ph)) & 1:
                        continue
                    k = p * 2 + ph
                    cmd = (rcmd >> (k * self.w_rcmd)) & ((1 << self.w_rcmd) - 1)
                    if cmd == ROW_MRS:
                        # Only the training sequencer issues MRS, and it is
                        # finished by the time traffic is released.  One here
                        # means the boot mux handed the bus back.
                        self.n_mrs += 1
                        continue
                    bk = (rbank >> (k * self.w_rbank)) & ((1 << self.w_rbank) - 1)
                    rw = (raddr >> (k * self.w_raddr)) & ((1 << self.w_raddr) - 1)
                    self._feed(p, "row", self.phase + ph, cmd, bk, rw)
        if cv:
            ccmd = int(dut.dfi_col_cmd.value)
            cbank = int(dut.dfi_col_bank.value)
            caddr = int(dut.dfi_col_addr.value)
            for p in range(self.n_pc):
                for ph in range(2):
                    if not (cv >> (p * 2 + ph)) & 1:
                        continue
                    k = p * 2 + ph
                    cmd = (ccmd >> (k * self.w_ccmd)) & ((1 << self.w_ccmd) - 1)
                    bk = (cbank >> (k * self.w_cbank)) & ((1 << self.w_cbank) - 1)
                    cl = (caddr >> (k * self.w_caddr)) & ((1 << self.w_caddr) - 1)
                    t = self.phase + ph
                    self._feed(p, "col", t, cmd, bk, cl)
                    self.col_log[p].append((t, cmd, bk, cl))
                    if cmd in (COL_RD, COL_RDA):
                        self.rd_q[p].append((t + self.t.tRL, bk, cl))
                        self.max_rd_q = max(self.max_rd_q, len(self.rd_q[p]))

    def _feed(self, pc, bus, t, cmd, bank, addr):
        """Replay one command into that pseudo-channel's reference DRAM.

        The first violation on a pseudo-channel STOPS that model.  Continuing
        would report the same broken state a thousand more times and bury the
        command that actually caused it.
        """
        if self.stopped[pc]:
            return
        try:
            if bus == "row":
                self.model[pc].row_cmd(t, cmd, bank, addr)
            else:
                self.model[pc].col_cmd(t, cmd, bank, addr)
        except TimingViolation as e:
            self.stopped[pc] = True
            name = ROW_NAME.get(cmd, cmd) if bus == "row" else COL_NAME.get(cmd, cmd)
            self.viol.append((pc, f"pc{pc} (stack {self.stack_of(pc)}) {name}: {e}"))

    # ---- NHI responses ----------------------------------------------------
    def _sample_responses(self):
        dut = self.dut
        rv = int(dut.rsp_valid.value)
        rc = int(dut.req_credit.value)

        # rsp_ready is tied high, so a response fires the cycle it is valid and
        # the credit for it is returned in that same cycle.  Anything else means
        # a credit was manufactured without a completion, or a completion left
        # without returning one -- both silently starve the port.
        if rv != rc:
            if len(self.credit_mismatch) < 8:
                self.credit_mismatch.append(
                    f"cycle {self.cycle}: rsp_valid=0x{rv:x} but req_credit=0x{rc:x}")

        if not rv:
            return
        tags = int(dut.rsp_tag.value)
        errs = int(dut.rsp_err.value)
        wacks = int(dut.rsp_wack.value)
        data = int(dut.rsp_data.value)

        for p in range(self.n_pc):
            if not (rv >> p) & 1:
                continue
            port = self.ports[p]
            port.responses += 1
            tag = (tags >> (p * self.w_tag)) & ((1 << self.w_tag) - 1)
            err = (errs >> (p * 2)) & 3
            wack = (wacks >> p) & 1

            if tag in port.out_tags:
                port.out_tags.remove(tag)
            elif len(port.tag_errors) < 4:
                port.tag_errors.append(
                    f"cycle {self.cycle}: response tag {tag} was never issued "
                    f"on pc{p} (outstanding {sorted(port.out_tags)})")

            if err:
                port.err_rsp += 1
                port.err_codes[err] = port.err_codes.get(err, 0) + 1
            if wack:
                port.wr_rsp += 1
            else:
                port.rd_rsp += 1
                got = (data >> (p * self.w_data)) & self.data_mask
                if port.expect_rd:
                    want = port.expect_rd.popleft()
                    if port.check_data and got != want:
                        if len(port.data_errors) < 4:
                            port.data_errors.append(
                                f"cycle {self.cycle}: pc{p} read returned "
                                f"0x{got:x}, its PHY was handed 0x{want:x}")
                elif len(port.data_errors) < 4:
                    port.data_errors.append(
                        f"cycle {self.cycle}: pc{p} produced a read response "
                        f"with no read data outstanding")

    def _sample_credits(self):
        rc = int(self.dut.req_credit.value)
        for p in range(self.n_pc):
            if (rc >> p) & 1:
                self.ports[p].credit_pulses += 1
                self.ports[p].credits += 1

    # ---- DFI read data ----------------------------------------------------
    def _drive_rddata(self):
        """Return read data tRL after the column read that asked for it.

        One beat per core clock per pseudo-channel is enough: the DFI adapter
        places every column command on a fixed phase (COL_PHASE), so a slice
        issues at most one column command per core clock.  max_rd_q is watched
        so that if that ever stops being true the harness reports its own
        backlog rather than blaming the DUT for a read FIFO it filled itself.
        """
        valid = 0
        data = 0
        code = 0
        for p in range(self.n_pc):
            q = self.rd_q[p]
            if not q or self.phase < q[0][0]:
                continue
            _, bk, cl = q.popleft()
            pay = self.payload(p, bk, cl) & self.data_mask
            f = ecc_field(pay)
            if p in self.corrupt:
                f ^= UE_DELTA
            valid |= 1 << p
            data |= pay << (p * self.w_data)
            code |= (f & ((1 << self.w_code) - 1)) << (p * self.w_code)
            self.rd_returned[p] += 1
            self.ports[p].expect_rd.append(pay)
        self.dut.dfi_rddata_valid.value = valid
        self.dut.dfi_rddata.value = data
        self.dut.dfi_rdcode.value = code

    # ---- NHI requests -----------------------------------------------------
    def _drive_requests(self):
        # Credits are returned in the cycle just sampled; count them here so a
        # credit and the request it enables cannot be used in the same cycle.
        self._sample_credits()

        rv = rw = blk_v = tag_v = 0
        for p in range(self.n_pc):
            port = self.ports[p]
            port.max_outstanding = max(port.max_outstanding, port.outstanding)
            if port.gen is None or port.credits <= 0:
                continue
            nxt = port.gen()
            if nxt is None:
                continue
            is_wr, blk = nxt
            tag = port.next_tag
            port.next_tag = (tag + 1) % TQ_DEPTH
            rv |= 1 << p
            if is_wr:
                rw |= 1 << p
            blk_v |= (blk & ((1 << self.w_blk) - 1)) << (p * self.w_blk)
            tag_v |= tag << (p * self.w_tag)
            port.credits -= 1
            port.issued += 1
            port.out_tags.append(tag)

        self.dut.req_valid.value = rv
        self.dut.req_wr.value = rw
        self.dut.req_blk.value = blk_v
        self.dut.req_tag.value = tag_v

    # ---- reporting --------------------------------------------------------
    def stats(self, pc):
        m = self.model[pc]
        return m.stats()

    def stack_totals(self, what):
        out = []
        for s in range(self.n_stack):
            out.append(sum(getattr(self.ports[p], what) for p in self.pcs_of(s)))
        return out

    def summary(self):
        lines = []
        for p in range(self.n_pc):
            m = self.model[p].stats()
            port = self.ports[p]
            lines.append(
                f"  pc{p} (stack {self.stack_of(p)}): act={m['act']} pre={m['pre']} "
                f"rd={m['rd']} wr={m['wr']} ref={m['ref']} | issued={port.issued} "
                f"rsp={port.responses} (rd {port.rd_rsp}/wr {port.wr_rsp}) "
                f"err={port.err_rsp}")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# boot
# ---------------------------------------------------------------------------
async def boot(dut, refi=2000, irq_mask=0xFFFF_FFFF, limit=20_000):
    """Reset, train every stack, and return once ctrl_ready is up.

    The PHY model acks every training step immediately.  Everything after this
    point is post-boot behaviour; nothing here is the subject of a traffic test.
    """
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())
    dut.rst_n.value = 0
    dut.boot_start.value = 0
    dut.phy_ack.value = 0
    dut.req_valid.value = 0
    dut.req_wr.value = 0
    dut.req_blk.value = 0
    dut.req_tag.value = 0
    dut.perf_snapshot_req.value = 0
    dut.cfg_refi_pb.value = refi
    dut.irq_mask.value = irq_mask
    dut.dfi_rddata_valid.value = 0
    dut.dfi_rddata.value = 0
    dut.dfi_rdcode.value = 0

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    dut.boot_start.value = 1
    await RisingEdge(dut.clk)
    dut.boot_start.value = 0

    for cyc in range(limit):
        await RisingEdge(dut.clk)
        dut.phy_ack.value = int(dut.phy_req.value)
        if int(dut.ctrl_ready.value):
            dut._log.info(f"ctrl_ready at cycle {cyc}")
            return cyc
        if int(dut.boot_failed.value):
            raise AssertionError(f"boot failed at cycle {cyc}")
    raise AssertionError(f"boot did not complete in {limit} cycles")


async def start_traffic(dut, refi=2000, irq_mask=0xFFFF_FFFF):
    """Boot, then attach the harness.  Returns the harness, already running.

    The harness starts AFTER ctrl_ready on purpose.  Before it the sequencer
    owns the command buses and broadcasts MRS and PREA to every pseudo-channel;
    feeding those into per-pseudo-channel DRAM models would have the models
    checking the boot script, which test_boot.py already does at the level where
    it belongs.  Post-boot the device rows are closed, which is exactly the
    state a fresh model starts in.
    """
    await boot(dut, refi=refi, irq_mask=irq_mask)
    h = SysHarness(dut)
    cocotb.start_soon(h.run())
    await ClockCycles(dut.clk, 2)
    return h


async def drain(dut, h, limit=8000):
    """Stop issuing and wait for every outstanding transaction to answer."""
    h.quiesce()
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if all(p.outstanding == 0 for p in h.ports):
            return True
    return False
