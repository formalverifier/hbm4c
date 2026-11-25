"""HBM4 pseudo-channel DRAM model with an independent timing checker.

WHY THIS IS WRITTEN THE WAY IT IS
---------------------------------
The controller already contains a timing engine that decides when each command
is legal.  A checker derived from that engine -- or written by reading it --
would agree with it by construction, including where it is wrong.  It would
catch typos and nothing else.

So this checker is written from the JEDEC PARAMETER DEFINITIONS instead: for
each parameter, "command A must be followed by command B no sooner than N
cycles", expressed as a last-event timestamp and a comparison.  It does not know
how the controller schedules, only what the DRAM permits.  Where the two
disagree, one of them is wrong and the disagreement is the finding.

This is the same principle as the shadow counters in the formal wrappers, and it
is the reason this model can discharge assumption A1 (reset behaviour) -- an
assumption the proofs make and cannot themselves justify.

THE MODEL ALSO HOLDS DATA.  Timing legality is only half of correctness: a
controller can obey every parameter and still return the wrong bytes (wrong row
left open, read serviced from a stale buffer, ECC applied to the wrong column).
The array below is the reference for what a read must return.
"""

from dataclasses import dataclass, field


# ---- command encodings, matching hbm4_pkg -------------------------------
ROW_NOP, ROW_ACT, ROW_PRE, ROW_PREA, ROW_REF, ROW_REFSB, ROW_RFM = range(7)
COL_NOP, COL_RD, COL_WR, COL_RDA, COL_WRA = range(5)

ROW_NAME = {ROW_NOP: "NOP", ROW_ACT: "ACT", ROW_PRE: "PRE", ROW_PREA: "PREA",
            ROW_REF: "REF", ROW_REFSB: "REFsb", ROW_RFM: "RFM"}
COL_NAME = {COL_NOP: "NOP", COL_RD: "RD", COL_WR: "WR", COL_RDA: "RDA",
            COL_WRA: "WRA"}


class TimingViolation(Exception):
    pass


@dataclass
class Timing:
    """JEDEC parameters in CORE CLOCKS (1 GHz, so 1 unit = 1 ns).

    Values marked (P) are placeholders pending the device datasheet -- signoff
    gate S12.  The checker's job is to enforce whatever is configured here, so
    substituting real numbers changes the check without changing the code.
    """
    tRCD: int = 14      # ACT -> RD/WR, same bank                        (P)
    tRP: int = 14       # PRE -> ACT, same bank                          (P)
    tRAS: int = 32      # ACT -> PRE, same bank                          (P)
    tRC: int = 46       # ACT -> ACT, same bank  (== tRAS + tRP)         (P)
    tRRD_S: int = 2     # ACT -> ACT, different bank group               (P)
    tRRD_L: int = 4     # ACT -> ACT, same bank group                    (P)
    tFAW: int = 16      # any four ACTs must span at least this          (P)
    tCCD_S: int = 1     # col -> col, different bank group  <- the BL8 identity
    tCCD_L: int = 4     # col -> col, same bank group                    (P)
    tWTR_S: int = 4     # write -> read turnaround, diff BG              (P)
    tWTR_L: int = 8     # write -> read turnaround, same BG              (P)
    tRTW: int = 8       # read -> write turnaround                       (P)
    tWR: int = 15       # write recovery, last write -> PRE              (P)
    tRTP: int = 6       # read -> PRE, same bank                         (P)
    tRFCsb: int = 96    # per-bank refresh                               (P)
    tRFM: int = 96      # refresh management                             (P)
    tRL: int = 18       # read latency, RD -> first data                 (P)
    tWL: int = 8        # write latency                                  (P)


def small_timing():
    """MUST match hbm4_timing_pkg::small_timing().

    The DUT under -DFV_SMALL is configured with the reduced timing set, so a
    checker holding production values reports violations that are not real --
    which is exactly what happened first time: back-to-back per-bank refresh
    looked like a gross tRFCsb violation when, at t_rfc_sb = 6 with 8 banks and
    a round-robin pointer, the same bank only recurs after 8 cycles and the
    parameter is satisfied.

    A checker whose parameters disagree with the device it is checking produces
    confident, specific, wrong findings -- worse than no checker.
    """
    return Timing(
        tRCD=3, tRP=3, tRAS=5, tRC=8, tRTP=2, tWR=3,
        tCCD_S=1, tCCD_L=2, tRRD_S=1, tRRD_L=2, tFAW=6,
        tWTR_S=2, tWTR_L=3, tRTW=2, tRL=4, tWL=2,
        tRFCsb=6, tRFM=6,
    )


@dataclass
class BankState:
    active: bool = False
    row: int = 0
    last_act: int = -10_000
    last_pre: int = -10_000
    last_rd: int = -10_000
    last_wr: int = -10_000
    last_ref: int = -10_000


class DramModel:
    """One HBM4 pseudo-channel: bank state, timing checks, and the data array."""

    def __init__(self, n_bank, n_bg, n_row, n_col, timing=None, log=None):
        self.n_bank, self.n_bg = n_bank, n_bg
        self.n_row, self.n_col = n_row, n_col
        self.t = timing or Timing()
        self.log = log
        self.bank = [BankState() for _ in range(n_bank)]
        self.array = {}                     # (bank,row,col) -> int
        self.act_history = []               # for tFAW
        self.last_col_any = -10_000
        self.last_col_bg = {}
        self.last_rd_any = -10_000
        self.last_wr_any = -10_000
        self.violations = []
        self.n_act = self.n_pre = self.n_rd = self.n_wr = self.n_ref = 0

    # ---- helpers ---------------------------------------------------------
    def bg_of(self, b):
        """Bank-group index.

        MUST match hbm4_pkg::bg_of.  It is written out rather than imported
        because a checker that shares the DUT's own decode cannot detect a bug
        in that decode -- the same reason the formal properties do not call
        bank_of().
        """
        return b % self.n_bg

    def _fail(self, cycle, msg):
        text = f"cycle {cycle}: {msg}"
        self.violations.append(text)
        if self.log:
            self.log.error(text)
        raise TimingViolation(text)

    def _need(self, cycle, since, param, name, what):
        if since < 0:
            return
        gap = cycle - since
        if gap < param:
            self._fail(cycle, f"{name} violated: {what} came {gap} cycles after "
                              f"the previous event, needs >= {param}")

    # ---- row bus ---------------------------------------------------------
    def row_cmd(self, cycle, cmd, bank, row):
        if cmd == ROW_NOP:
            return
        b = self.bank[bank]

        if cmd == ROW_ACT:
            if b.active:
                self._fail(cycle, f"ACT to bank {bank} which is already active "
                                  f"(row {b.row} still open) -- a lost PRE")
            self._need(cycle, b.last_act, self.t.tRC, "tRC", f"ACT bank {bank}")
            self._need(cycle, b.last_pre, self.t.tRP, "tRP", f"ACT bank {bank}")
            self._need(cycle, b.last_ref, self.t.tRFCsb, "tRFCsb", f"ACT bank {bank}")

            # tRRD: bank-group dependent, so this is where a bad bank-group
            # decode shows up as a timing failure rather than as wrong data.
            for ob in range(self.n_bank):
                if ob == bank:
                    continue
                p = self.t.tRRD_L if self.bg_of(ob) == self.bg_of(bank) else self.t.tRRD_S
                nm = "tRRD_L" if self.bg_of(ob) == self.bg_of(bank) else "tRRD_S"
                self._need(cycle, self.bank[ob].last_act, p, nm, f"ACT bank {bank}")

            # tFAW is a ROLLING FOUR-ACTIVATE window, not a counter that resets.
            recent = [c for c in self.act_history if cycle - c < self.t.tFAW]
            if len(recent) >= 4:
                self._fail(cycle, f"tFAW violated: ACT bank {bank} is the 5th "
                                  f"activate within {self.t.tFAW} cycles "
                                  f"(previous at {recent})")
            self.act_history.append(cycle)
            self.act_history = [c for c in self.act_history if cycle - c < self.t.tFAW]

            b.active, b.row, b.last_act = True, row, cycle
            self.n_act += 1

        elif cmd in (ROW_PRE, ROW_PREA):
            targets = range(self.n_bank) if cmd == ROW_PREA else [bank]
            for tb in targets:
                bb = self.bank[tb]
                if not bb.active:
                    if cmd == ROW_PRE:
                        self._fail(cycle, f"PRE to bank {tb} which is not active")
                    continue
                self._need(cycle, bb.last_act, self.t.tRAS, "tRAS", f"PRE bank {tb}")
                self._need(cycle, bb.last_rd, self.t.tRTP, "tRTP", f"PRE bank {tb}")
                self._need(cycle, bb.last_wr, self.t.tWR, "tWR", f"PRE bank {tb}")
                bb.active, bb.last_pre = False, cycle
                self.n_pre += 1

        elif cmd in (ROW_REF, ROW_REFSB, ROW_RFM):
            if self.bank[bank].active:
                self._fail(cycle, f"{ROW_NAME[cmd]} to bank {bank} while it is "
                                  f"active -- refresh requires a closed bank")
            self._need(cycle, b.last_ref, self.t.tRFCsb, "tRFCsb", ROW_NAME[cmd])
            b.last_ref = cycle
            self.n_ref += 1

    # ---- column bus ------------------------------------------------------
    def col_cmd(self, cycle, cmd, bank, col, wdata=None):
        if cmd == COL_NOP:
            return None
        b = self.bank[bank]
        bg = self.bg_of(bank)
        is_rd = cmd in (COL_RD, COL_RDA)
        auto_pre = cmd in (COL_RDA, COL_WRA)
        name = COL_NAME[cmd]

        if not b.active:
            self._fail(cycle, f"{name} to bank {bank} with no open row -- "
                              f"the ACT was lost or precharged early")
        self._need(cycle, b.last_act, self.t.tRCD, "tRCD", f"{name} bank {bank}")

        # tCCD.  C2 in docs/02: the bank group must alternate every column
        # command, and this is the check that proves the address map delivers it.
        self._need(cycle, self.last_col_bg.get(bg, -10_000), self.t.tCCD_L,
                   "tCCD_L", f"{name} bank {bank} (bank group {bg})")
        self._need(cycle, self.last_col_any, self.t.tCCD_S, "tCCD_S",
                   f"{name} bank {bank}")

        # Bus turnaround.
        if is_rd:
            for obg in range(self.n_bg):
                p = self.t.tWTR_L if obg == bg else self.t.tWTR_S
                nm = "tWTR_L" if obg == bg else "tWTR_S"
                last = max((self.bank[x].last_wr for x in range(self.n_bank)
                            if self.bg_of(x) == obg), default=-10_000)
                self._need(cycle, last, p, nm, f"{name} bank {bank}")
        else:
            self._need(cycle, self.last_rd_any, self.t.tRTW, "tRTW",
                       f"{name} bank {bank}")

        self.last_col_any = cycle
        self.last_col_bg[bg] = cycle

        key = (bank, b.row, col)
        if is_rd:
            b.last_rd = self.last_rd_any = cycle
            self.n_rd += 1
            result = self.array.get(key)
        else:
            b.last_wr = self.last_wr_any = cycle
            self.n_wr += 1
            if wdata is not None:
                self.array[key] = wdata
            result = None

        if auto_pre:
            # Auto-precharge closes the bank with NO row command.  The
            # controller must still honour tRAS/tRTP/tWR against it, and must
            # not issue an ACT before tRP -- the bug class that made
            # PAGE_POLICY=CLOSE violate tRP on every access.
            self._need(cycle, b.last_act, self.t.tRAS, "tRAS",
                       f"{name} auto-precharge bank {bank}")
            b.active, b.last_pre = False, cycle
            self.n_pre += 1

        return result

    def stats(self):
        return dict(act=self.n_act, pre=self.n_pre, rd=self.n_rd,
                    wr=self.n_wr, ref=self.n_ref)
