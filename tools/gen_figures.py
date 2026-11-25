#!/usr/bin/env python3
"""Generate every .drawio.svg figure in docs/figures/.  Run: python3 tools/gen_figures.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from figlib import Fig, PAL, TXT  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "figures")
FIGS = []


def fig(fn):
    FIGS.append(fn)
    return fn


def cols(x0, x1, n, gap):
    """n equal columns spanning x0..x1."""
    w = (x1 - x0 - gap * (n - 1)) / float(n)
    return [x0 + i * (w + gap) for i in range(n)], w


# ============================================================ 01 system context
@fig
def f01():
    f = Fig("fig-01-system-context", 1120, 680,
            "Figure 1 - System context",
            "Where the controller sits, and who owns which piece. "
            "Green = you build it into the SoC; blue = this IP; purple = vendor PHY and DRAM.")
    xs, w = cols(70, 1050, 4, 26)

    f.box("cpu", 70, 78, 980, 54, "Accelerator compute  (GPU / NPU / tensor cores)",
          kind="plain", sub="Issues 32-byte read and write requests")

    f.group("fab", 70, 162, 980, 104,
            "SoC fabric / NoC   -   you build this",
            kind="fe")
    for i, x in enumerate(xs):
        f.box("sl%d" % i, x, 200, w, 50, "HBM4_ADDR_SLICE", kind="fe", fs=11,
              sub="sys addr -> stack, PC")

    f.group("ctl", 70, 300, 980, 214,
            "HBM4 controller IP   -   this deliverable", kind="core")
    for i, x in enumerate(xs):
        f.box("st%d" % i, x, 340, w, 78,
              "Stack controller %d" % i,
              kind="core", fs=11,
              sub="64 x PC slice\n32 x DFI channel\ninit sequencer, CSR")
    f.box("sup", 96, 440, 928, 52, "Top-level supervisor",
          kind="core", fs=11,
          sub="boot orchestration - unified CSR - cross-stack RAS - DVFS - refresh phase")

    for i, x in enumerate(xs):
        f.box("phy%d" % i, x, 548, w, 46, "HBM4 PHY %d" % i, kind="phy", fs=11,
              sub="vendor IP")
        f.box("dr%d" % i, x, 620, w, 44, "HBM4 stack %d" % i, kind="phy", fs=11,
              sub="64 GB, 2.05 TB/s")

    f.edge(("cpu", "s", 0.5), ("fab", "n", 0.5), "requests", thick=True)
    for i in range(4):
        f.edge(("sl%d" % i, "s", 0.5), ("st%d" % i, "n", 0.5),
               "NHI x64" if i == 0 else None)
        # leave from the controller container's lower edge so the arrow clears
        # the supervisor band that spans the full width
        f.edge(("ctl", "s", (xs[i] + w / 2.0 - 70) / 980.0), ("phy%d" % i, "n", 0.5),
               "DFI" if i == 0 else None)
        f.edge(("phy%d" % i, "s", 0.5), ("dr%d" % i, "n", 0.5))

    f.text(560, 528, "Total: 256 pseudo-channels - 8.19 TB/s raw - 240 GB usable with ECC on",
           fs=11.5, bold=True, color="#41546b")
    return f


# ============================================================ 02 hierarchy
@fig
def f02():
    f = Fig("fig-02-rtl-hierarchy", 1120, 620,
            "Figure 2 - RTL instantiation hierarchy",
            "Read top to bottom. Numbers in brackets are instance counts for the "
            "N_STACK = 4 baseline.")

    f.box("top", 400, 74, 320, 52, "hbm4_sys_top  [1]", kind="dark", inv=True,
          sub="the only module you instantiate")
    f.box("sup", 110, 172, 260, 50, "hbm4_supervisor  [1]", kind="core", fs=11,
          sub="boot, CSR aperture, RAS, DVFS")
    f.box("stk", 480, 172, 300, 50, "hbm4_stack_top  [4]", kind="core", fs=11,
          sub="one per HBM4 stack")
    f.box("slice", 470, 268, 320, 50, "hbm4_pc_slice  [64 per stack]", kind="core", fs=11,
          sub="256 total - the scheduling domain")
    f.box("sglob", 840, 268, 250, 50, "stack global  [1 per stack]", kind="core", fs=11,
          sub="init_seq, csr, pmgr")
    f.box("dfi", 840, 356, 250, 46, "hbm4_dfi_adapter  [32]", kind="phy", fs=11,
          sub="2 PC slices -> 1 DFI channel")

    xs, w = cols(90, 800, 4, 22)
    names = [("fe", "front-end", "nhi_target\naddr_decode (div30)\nwbuf + hazard"),
             ("core", "controller core", "txn_pool, bank_state\ntiming_engine\ncol_arb, row_arb\ndir_fsm, refresh"),
             ("ras", "RAS / ECC", "link_ecc, sys_ecc\necc_cache, scrub\nerr_log"),
             ("dfia", "DFI adapter", "cmd format\nrd_ptr_fifo")]
    kinds = ["fe", "core", "ras", "phy"]
    for i, (nid, lab, sub) in enumerate(names):
        f.box(nid, xs[i], 396, w, 96, lab, kind=kinds[i], fs=11, sub=sub)

    f.box("fabsl", 110, 268, 260, 50, "hbm4_addr_slice", kind="fe", fs=11,
          sub="shipped for YOUR fabric, not instantiated here")

    f.edge(("top", "s", 0.25), ("sup", "n", 0.5))
    f.edge(("top", "s", 0.75), ("stk", "n", 0.5))
    f.edge(("stk", "s", 0.35), ("slice", "n", 0.4))
    f.edge(("stk", "s", 0.85), ("sglob", "n", 0.5))
    f.edge(("sglob", "s", 0.5), ("dfi", "n", 0.5))
    for nid in ("fe", "core", "ras", "dfia"):
        f.edge(("slice", "s", 0.5), (nid, "n", 0.5))
    f.edge(("sup", "s", 0.5), ("fabsl", "n", 0.5), "same hash source", style="dashed")

    f.text(560, 540, "hbm4_addr_slice shares one RTL source with the controller's decode, and a formal",
           fs=11, color="#41546b")
    f.text(560, 558, "miter proves they agree. A silent disagreement here corrupts memory with no error.",
           fs=11, color="#41546b")
    return f


# ============================================================ 03 PC slice
@fig
def f03():
    f = Fig("fig-03-pc-slice", 1140, 760,
            "Figure 3 - Inside one pseudo-channel slice",
            "This block is replicated 256 times. Everything here is private to one "
            "pseudo-channel: its own queue, its own bank state, its own command bus.")

    f.box("nhi", 60, 78, 1020, 44, "Native Host Interface (NHI)  -  synchronous, 1 GHz",
          kind="fe", fs=12, sub="req / write-data / response, credit-metered, out-of-order")

    f.group("fe", 60, 146, 1020, 118, "FRONT-END", kind="group")
    f.box("dec", 82, 186, 300, 60, "address decode", kind="fe", fs=11,
          sub="div30 -> row, col\nBG / BA hash")
    f.box("wb", 400, 186, 300, 60, "write buffer  128 x 32 B", kind="fe", fs=11,
          sub="coalesce - forward - 2-tier hazard")
    f.box("rsp", 718, 186, 340, 60, "tag alloc / response assembly", kind="fe", fs=11,
          sub="out-of-order return")

    f.group("core", 60, 288, 1020, 226, "CONTROLLER CORE", kind="group")
    f.box("pool", 82, 328, 240, 78, "transaction pool", kind="core", fs=11,
          sub="64 entries\nper-bank + per-row lists")
    f.box("bank", 340, 328, 230, 78, "bank state table", kind="core", fs=11,
          sub="32 banks: state,\nopen row, pending")
    f.box("tim", 588, 328, 230, 78, "timing engine", kind="core", fs=11,
          sub="ready vectors,\ncomputed 1 cycle ahead")
    f.box("ref", 836, 328, 222, 78, "refresh + RFM", kind="core", fs=11,
          sub="REFsb, credits,\nrow-hammer counters")
    f.box("row", 200, 424, 280, 68, "ROW ARBITER", kind="hot", fs=11,
          sub="ACT / PRE / REF")
    f.box("dirf", 500, 424, 160, 68, "direction\nFSM", kind="core", fs=11,
          sub="read <-> write")
    f.box("col", 680, 424, 280, 68, "COLUMN ARBITER", kind="hot", fs=11,
          sub="RD / WR   (critical cycle)")

    f.group("ras", 60, 538, 1020, 96, "RAS / ECC", kind="group")
    f.box("lecc", 82, 574, 300, 48, "link ECC gen / check", kind="ras", fs=11)
    f.box("secc", 400, 574, 300, 48, "system ECC codec (272,256)", kind="ras", fs=11)
    f.box("ecache", 718, 574, 340, 48, "ECC column cache  32 x 32 B", kind="ras", fs=11,
          sub="direct-mapped by bank index")

    f.box("dfi", 60, 656, 1020, 48, "DFI ADAPTER   ->   PHY", kind="phy", fs=12,
          sub="row cmd  |  col cmd  |  wrdata 256 b  |  rddata 256 b")

    f.edge(("nhi", "s", 0.2), ("dec", "n", 0.5))
    f.edge(("nhi", "s", 0.45), ("wb", "n", 0.5))
    f.edge(("rsp", "n", 0.5), ("nhi", "s", 0.8))
    f.edge(("dec", "s", 0.5), ("pool", "n", 0.5))
    f.edge(("tim", "s", 0.3), ("col", "n", 0.35), "ready vec")
    f.edge(("tim", "s", 0.1), ("row", "n", 0.75), "ready vec")
    f.edge(("dirf", "e", 0.5), ("col", "w", 0.25))
    # Route the two command buses down the clear gaps BETWEEN the RAS boxes
    # (x=391 sits between lecc and secc; x=709 between secc and ecache).
    f.edge(("row", "s", 0.682), ("dfi", "n", 0.3245), "row bus", thick=True)
    f.edge(("col", "s", 0.1036), ("dfi", "n", 0.6363), "col bus", thick=True)
    f.edge(("ecache", "s", 0.5), ("dfi", "n", 0.9), style="dashed")

    f.text(570, 726,
           "Key point: the row and column arbiters run in the SAME cycle on SEPARATE buses. "
           "An ACT and a RD can issue together.",
           fs=11.5, bold=True, color="#b85450")
    return f


# ============================================================ 04 clocks
@fig
def f04():
    f = Fig("fig-04-clock-domains", 1060, 540,
            "Figure 4 - Clock domains and the CDC surface",
            "Only two clock crossings exist in the whole design. That is a deliberate "
            "outcome of making the NHI synchronous.")

    f.group("cc", 60, 100, 640, 300, "clk_core   -   1.0 GHz", kind="core")
    f.box("nhi", 84, 144, 280, 54, "NHI ports  x256", kind="fe", fs=11)
    f.box("sl", 396, 144, 280, 54, "PC slices  x256", kind="core", fs=11)
    f.box("dfi", 84, 222, 592, 54, "DFI adapters  x128", kind="phy", fs=11,
          sub="dfi_clk IS clk_core - no crossing here")
    f.box("note1", 84, 300, 592, 76, "Why 1 GHz?", kind="plain", fs=11, dashed=True,
          sub="Pin rate 8 Gb/s -> CK = 2 GHz -> DFI ratio 1:2 -> core = 1 GHz.\n"
              "One BL8 burst = 1 ns = exactly one core clock.")

    f.group("cfg", 740, 100, 280, 300, "clk_cfg   -   100-400 MHz", kind="group")
    f.box("csr", 762, 144, 236, 54, "CSR / APB", kind="plain", fs=11)
    f.box("seq", 762, 222, 236, 54, "init sequencer", kind="plain", fs=11)
    f.box("supb", 762, 300, 236, 54, "supervisor, RAS", kind="plain", fs=11)

    f.box("phyd", 380, 440, 300, 52, "PHY internal  (WCK / CK)", kind="phy", fs=11,
          sub="inside vendor IP - not your problem")

    f.edge(("cc", "e", 0.5), ("cfg", "w", 0.5), "CDC #1", both=True, kind="hot")
    f.edge(("cc", "s", 0.5), ("phyd", "n", 0.5), "CDC #2 (vendor)", kind="hot")

    f.text(530, 516,
           "No production-grade open-source CDC tool exists. A two-crossing design is "
           "reviewable by hand; a 512-crossing one is not.",
           fs=11, color="#41546b")
    return f


# ============================================================ 05 address map
@fig
def f05():
    f = Fig("fig-05-address-map", 1140, 660,
            "Figure 5 - Address map (STREAM mode, N_STACK = 4, ECC on)",
            "The field ORDER is the whole design. Each goal - spread across stacks, "
            "spread across pseudo-channels, hit the open row - owns a different stride.")

    flds = [("rem20", "[37:18]", 20, 290, "core"),
            ("BA", "[17:15]", 3, 110, "core"),
            ("BG", "[14:13]", 2, 100, "hot"),
            ("PC", "[12:7]", 6, 175, "fe"),
            ("STACK", "[6:5]", 2, 110, "fe"),
            ("offset", "[4:0]", 5, 125, "plain")]
    x = 75
    for nid, rng, bits, w, kind in flds:
        f.box("fld_" + nid, x, 112, w, 62, nid, kind=kind, fs=12,
              sub="%s   %d bits" % (rng, bits))
        x += w

    f.text(607, 196, "MSB  <-------------------------------------------------  LSB",
           fs=10, color="#8a97a5")

    rows = [("+32 B", "next STACK", "128 B of address touches all 4 stacks"),
            ("+128 B", "next PC", "8 KB touches all 256 pseudo-channels"),
            ("+8 KB", "next BANK GROUP", "this is why back-to-back commands never hit tCCD_L"),
            ("+32 KB", "next BANK", "32 banks open at once per PC"),
            ("+256 KB", "rem20 += 1  ->  next COLUMN", "same row: a ROW HIT"),
            ("+7.9 MB", "next ROW", "after 30 data columns are consumed")]
    y = 226
    for stride, what, why in rows:
        f.box("r%d" % y, 75, y, 150, 40, stride, kind="plain", fs=11.5)
        f.box("w%d" % y, 233, y, 250, 40, what, kind="core", fs=11)
        f.text(500, y + 25, why, fs=11, anchor="start", color="#41546b")
        y += 50

    f.box("div", 75, 542, 480, 76, "rem20  ->  div30", kind="ras", fs=12,
          sub="col = rem20 mod 30   (0..29, 2 columns reserved for ECC)\n"
              "row = rem20 div 30   (0..32767)")
    f.box("divwhy", 575, 542, 490, 76, "Why divide, and why here?", kind="plain",
          fs=11, dashed=True,
          sub="rem20 sits at the TOP of the address, so reserving 2 of 32 columns\n"
              "leaves the usable space contiguous: 0 .. 240 GB, no holes.")
    return f


# ============================================================ 06 pipeline
@fig
def f06():
    f = Fig("fig-06-pipeline", 1140, 520,
            "Figure 6 - Controller pipeline, one request end to end",
            "Five control stages, then the data path. All the arithmetic is in S0 so "
            "that S1 - the stage that must fire every single cycle - is only a mux.")

    st = [("E0", "accept", "take request\nconsume credit\nallocate pool entry", "fe"),
          ("E1", "decode + file", "div30, BG/BA hash\nhazard check\nfile into bank list", "fe"),
          ("S0", "ready vectors", "evaluate ALL DRAM\ntiming for cycle N+1\n-> two 32-bit masks", "core"),
          ("S1", "arbitrate", "row arbiter +\ncolumn arbiter\ncombinational", "hot"),
          ("S2", "command format", "encode onto DFI\npick CK phase", "core"),
          ("D0+", "data path", "write data out /\nread data in, ECC,\nrespond", "ras")]
    xs, w = cols(60, 1080, 6, 18)
    for i, (nm, lab, sub, kind) in enumerate(st):
        f.box("s%d" % i, xs[i], 108, w, 130, "%s\n%s" % (nm, lab), kind=kind, fs=12, sub=sub)
        if i:
            f.edge(("s%d" % (i - 1), "e", 0.5), ("s%d" % i, "w", 0.5))
        f.text(xs[i] + w / 2, 260, "1 cycle" if i < 5 else "variable", fs=10.5,
               color="#8a97a5")

    f.box("spec", xs[2], 296, xs[3] + w - xs[2], 62,
          "S0 runs one cycle AHEAD, speculatively", kind="plain", fs=11, dashed=True,
          sub="If it ran in the same cycle as S1, the timing comparisons would be on the\n"
              "critical path and 1 GHz would not close.")

    f.box("fast", 60, 296, xs[2] - 78, 62, "FAST PATH", kind="plain", fs=11, dashed=True,
          sub="Pool empty and row already open?\nE1 feeds S1 directly, skipping 2 cycles.")

    f.box("lat", 60, 392, 1020, 72,
          "Idle read latency budget:  1 (NHI) + 2 (decode) + 2 (arb) + 3 (to DRAM) + 16 (tRCD=0 on a row hit, + CL) "
          "+ 4 (back) + 2 (ECC) + 2 (respond)  =  32 clocks = 32 ns",
          kind="core", fs=11.5,
          sub="Only 9 of those 32 clocks belong to the controller. The rest is DRAM and PHY physics.")
    return f


# ============================================================ 07 scheduler
@fig
def f07():
    f = Fig("fig-07-scheduler", 1140, 700,
            "Figure 7 - The dual-arbiter scheduler",
            "HBM gives each pseudo-channel two independent command buses. So we build "
            "two independent arbiters, not one arbiter choosing between command types.")

    f.box("pool", 60, 104, 320, 96, "transaction pool\n+ per-bank lists", kind="core", fs=12,
          sub="only the 32 list HEADS are ever candidates\n(not all 64 entries)")
    f.box("bank", 410, 104, 300, 96, "bank state table", kind="core", fs=12,
          sub="32 x { state, open row, pending }")
    f.box("tim", 740, 104, 340, 96, "timing engine", kind="core", fs=12,
          sub="96 per-bank counters + shared\ncollapsed to 'earliest legal cycle'")

    f.box("rv", 410, 236, 670, 62, "READY VECTORS  (computed in S0, for cycle N+1)",
          kind="plain", fs=12,
          sub="row_ready[31:0]        col_ready[31:0]")

    f.box("rowa", 120, 348, 380, 150, "ROW ARBITER", kind="hot", fs=13,
          sub="1. refresh, if urgent\n2. PRE - close a finished row\n"
              "3. ACT - look-ahead: activate the bank\n     the column stream needs in ~tRCD")
    f.box("cola", 640, 348, 380, 150, "COLUMN ARBITER", kind="hot", fs=13,
          sub="1. QoS urgent\n2. bank group != last issued  <- tCCD_L\n"
              "3. round-robin (bounded starvation)")
    f.box("dirf", 520, 386, 100, 74, "direction\nFSM", kind="core", fs=11)

    f.box("rowb", 120, 540, 380, 54, "ROW COMMAND BUS", kind="phy", fs=12,
          sub="ACT / PRE / REF / RFM")
    f.box("colb", 640, 540, 380, 54, "COLUMN COMMAND BUS", kind="phy", fs=12,
          sub="RD / WR  -  max ONE per core clock")

    f.edge(("pool", "s", 0.5), ("rowa", "n", 0.2))
    f.edge(("bank", "s", 0.5), ("rv", "n", 0.2))
    f.edge(("tim", "s", 0.5), ("rv", "n", 0.75))
    f.edge(("rv", "s", 0.2), ("rowa", "n", 0.75))
    f.edge(("rv", "s", 0.8), ("cola", "n", 0.3))
    f.edge(("dirf", "e", 0.5), ("cola", "w", 0.25))
    f.edge(("rowa", "s", 0.5), ("rowb", "n", 0.5), thick=True)
    f.edge(("cola", "s", 0.5), ("colb", "n", 0.5), thick=True)

    f.box("why", 60, 622, 1020, 56, "Why this matters", kind="plain", fs=11.5, dashed=True,
          sub="tCCD_S = 1 ns = 1 core clock = one 32-byte burst. Every cycle the column arbiter "
              "fails to issue is 32 bytes of\nbandwidth gone forever. It must decide combinationally, "
              "which is why all the arithmetic lives one stage upstream.")
    return f


# ============================================================ 08 txn lists
@fig
def f08():
    f = Fig("fig-08-txn-lists", 1100, 620,
            "Figure 8 - Filing transactions without a CAM",
            "Because address bits pick the bank directly, we can file each request into "
            "the right list on arrival. Row-hit batching then falls out for free.")

    f.box("in", 60, 100, 220, 56, "incoming request", kind="fe", fs=12,
          sub="bank and row already decoded")

    f.box("pool", 330, 96, 300, 200, "shared entry pool\n64 entries", kind="core", fs=12,
          sub="{ valid, wr, bg, ba, row, col,\n  tag, qos, wbuf_idx, next_ptr }\n\n"
              "next_ptr threads the lists")

    y = 96
    labs = [("bank 0  read list", "row 12 -> row 12 -> row 12   |   row 40"),
            ("bank 0  write list", "row 12"),
            ("bank 1  read list", "row 12 -> row 12"),
            ("...", ""),
            ("bank 31 read list", "row 12 -> row 12 -> row 12")]
    for i, (lab, contents) in enumerate(labs):
        f.box("l%d" % i, 680, y, 165, 38, lab, kind="core" if i != 3 else "plain",
              fs=10.5, bold=False)
        f.text(858, y + 24, contents, fs=10, anchor="start", color="#41546b")
        y += 44

    f.edge(("in", "e", 0.5), ("pool", "w", 0.3))
    f.edge(("pool", "e", 0.3), ("l0", "w", 0.5))

    f.box("grp", 60, 340, 570, 116, "Row grouping on enqueue", kind="fe", fs=12,
          sub="if (row == grp_row[bank][dir])  append to the current tail group\n"
              "else                            start a new group\n\n"
              "Same-row requests end up physically CONTIGUOUS in the list, so when the\n"
              "head is reached they issue as a burst of row hits. No content-addressable\n"
              "memory, no search, no comparators.")

    f.box("cand", 680, 340, 380, 116, "Arbitration candidates", kind="hot", fs=12,
          sub="32 list heads per direction.\n\n"
              "head_is_row_hit[b] = (grp_row at head == open row of bank b)\n\n"
              "Maintained incrementally as a 32-bit vector, so the arbiter\n"
              "sees a mask, not a comparison tree.")

    f.box("lim", 60, 490, 1000, 92, "The limit you should know about", kind="plain",
          fs=11.5, dashed=True,
          sub="Strict per-bank FIFO order means a row hit sitting behind a row miss TO THE SAME BANK has to wait.\n"
              "Under the STREAM address map this essentially never happens, because consecutive accesses to one\n"
              "pseudo-channel go to DIFFERENT banks. For random traffic, set GROUP_HOIST_EN to let a newer same-row\n"
              "group jump ahead - bounded by HOIST_MAX = 8 so the starvation guarantee survives.")
    return f


# ============================================================ 09 ECC layout
@fig
def f09():
    f = Fig("fig-09-ecc-layout", 1140, 680,
            "Figure 9 - Inline system ECC lives in the same open row",
            "Two of the 32 columns in every row hold the check bits for the other 30. "
            "Fetching ECC therefore costs one column access - no activate, no precharge.")

    f.text(70, 108, "One DRAM row, one bank, one pseudo-channel  (1 KB = 32 columns of 32 B)",
           fs=12, anchor="start", bold=True, color="#41546b")

    x = 70
    cw = 30
    for c in range(30):
        f.box("c%d" % c, x, 126, cw, 46, str(c) if c % 5 == 0 or c == 29 else "",
              kind="core", fs=9.5, bold=False, rounded=False)
        x += cw + 2
    f.box("e0", x, 126, cw + 14, 46, "E0", kind="ras", fs=10, rounded=False)
    x += cw + 16
    f.box("e1", x, 126, cw + 14, 46, "E1", kind="ras", fs=10, rounded=False)

    f.text(300, 194, "columns 0 .. 29   =   DATA", fs=11, bold=True, color="#41546b")
    f.text(1010, 194, "cols 30, 31 = ECC", fs=11, bold=True, color="#d79b00")

    f.box("m0", 70, 220, 480, 60, "ECC column 30 protects data columns 0 - 14",
          kind="ras", fs=11.5, sub="15 blocks x 16 check bits = 240 of 256 bits used")
    f.box("m1", 570, 220, 480, 60, "ECC column 31 protects data columns 15 - 29",
          kind="ras", fs=11.5, sub="code is (272,256): single 4-bit symbol correct, double detect")

    f.box("cache", 70, 314, 470, 150, "ECC column cache", kind="ras", fs=12.5,
          sub="32 entries x 32 B = 1 KB per pseudo-channel\n"
              "DIRECT-MAPPED BY BANK INDEX - no tags, no replacement policy\n\n"
              "This is exact, not an approximation: a bank has ONE open row,\n"
              "and each row-half has ONE ECC column, so there is never more\n"
              "than one ECC block per bank in flight.")

    f.box("elide", 570, 314, 480, 150, "Write-allocate elision", kind="fe", fs=12.5,
          sub="Each cache entry carries 15 field-valid bits.\n\n"
              "If a write stream fills all 15 before eviction, the ECC block is\n"
              "GENERATED, never read. No read-modify-write on the write path.\n\n"
              "This is what keeps writes at 6.25% instead of 12.5%.")

    f.box("cost", 70, 496, 980, 70, "Cost, stated honestly", kind="plain", fs=12, dashed=True,
          sub="Capacity 2/32 = 6.25%  (240 GB usable of 256 GB)      Bandwidth 6.25% sequential read AND write\n"
              "6.25% of 8.19 TB/s is 512 GB/s. That is the floor for this class of scheme, and it is cheap next to a wrong answer.")

    f.box("bad", 70, 588, 980, 62, "What Rev 0.1 got wrong (kept here because the failure mode is instructive)",
          kind="hot", fs=11.5,
          sub="It put the ECC block in a different ROW of the same bank. A bank has one row buffer, so every ECC fetch would have\n"
              "precharged the row being streamed and re-activated it after: ~60 ns each, ~12.5% overhead, and double the ACT rate against tFAW.")
    return f


# ============================================================ 10 direction FSM
@fig
def f10():
    f = Fig("fig-10-direction-fsm", 1060, 620,
            "Figure 10 - Read/write direction FSM",
            "The DRAM data bus is bidirectional. Every turn costs ~12 ns of dead bus, so "
            "we batch reads and writes into long runs.")

    f.box("rd", 80, 250, 200, 78, "READ", kind="core", fs=14,
          sub="issue only RD\ncolumn commands")
    f.box("tw", 420, 120, 200, 78, "TO_WRITE", kind="hot", fs=13,
          sub="wait t_rtw\nbus is idle")
    f.box("wr", 760, 250, 200, 78, "WRITE", kind="core", fs=14,
          sub="drain the write\nbuffer")
    f.box("tr", 420, 380, 200, 78, "TO_READ", kind="hot", fs=13,
          sub="wait t_wtr\nbus is idle")

    f.edge(("rd", "e", 0.3), ("tw", "w", 0.5), "wr_q >= WR_HI (96)")
    f.edge(("tw", "e", 0.5), ("wr", "w", 0.3))
    f.edge(("wr", "w", 0.8), ("tr", "e", 0.5), "wr_q <= WR_LO (16)")
    f.edge(("tr", "w", 0.5), ("rd", "e", 0.8))

    f.box("leave", 60, 496, 480, 104, "Other reasons to leave READ", kind="plain",
          fs=11.5, dashed=True,
          sub="- read list empty and writes pending\n"
              "- a read hit a pending write (RAW) that must drain first\n"
              "- a write has aged past WR_AGE_LIMIT (starvation guard)\n"
              "- req_last seen and reads are done")

    f.box("size", 580, 496, 420, 104, "Why WBUF_DEPTH = 128 matters", kind="fe",
          fs=11.5,
          sub="overhead  =  12 ns / (Bw + Br + 12)\n\n"
              "  64 entries, 2:1 R:W  ->  5.9% lost\n"
              " 128 entries, 2:1 R:W  ->  3.0% lost\n\n"
              "512 KB more SRAM buys 2.9% of 8 TB/s.")
    return f


# ============================================================ 11 hazard
@fig
def f11():
    f = Fig("fig-11-write-hazard", 1060, 560,
            "Figure 11 - Two-tier write hazard check",
            "A read must never overtake a pending write to the same block. Doing that "
            "with a flat 128-entry CAM at 1 GHz across 256 slices would cost ~30 W in "
            "search power alone.")

    f.box("rd", 60, 116, 220, 60, "incoming READ", kind="fe", fs=12,
          sub="{bg, ba, row, col}")
    f.box("t1", 340, 106, 320, 80, "TIER 1", kind="core", fs=13,
          sub="128 x 12-bit hash compare\nfully parallel, every cycle")
    f.box("t2", 720, 106, 300, 80, "TIER 2", kind="ras", fs=13,
          sub="read <= 4 full tags from a\nsmall RAM, compare exactly")

    f.box("miss", 340, 244, 320, 62, "no match  (97% of accesses)", kind="fe", fs=11.5,
          sub="proceed straight to the queue")
    f.box("hit", 720, 244, 300, 62, "match  (~3%)", kind="ras", fs=11.5,
          sub="costs 1 extra cycle")

    f.box("out1", 340, 344, 320, 88, "exact match, full byte coverage", kind="fe", fs=11.5,
          sub="FORWARD the buffered data.\nThe read never touches DRAM at all.")
    f.box("out2", 720, 344, 300, 88, "exact match, partial coverage", kind="ras", fs=11.5,
          sub="mark blocked_on[idx];\nbecomes a candidate once\nthat write issues.")

    f.edge(("rd", "e", 0.5), ("t1", "w", 0.5))
    f.edge(("t1", "e", 0.5), ("t2", "w", 0.5), "tier-1 hit")
    f.edge(("t1", "s", 0.5), ("miss", "n", 0.5))
    f.edge(("t2", "s", 0.5), ("hit", "n", 0.5))
    f.edge(("hit", "s", 0.3), ("out1", "n", 0.8))
    f.edge(("hit", "s", 0.7), ("out2", "n", 0.5))

    f.box("prop", 60, 460, 960, 74, "The property that makes this safe", kind="hot", fs=12,
          sub="False POSITIVES cost a cycle. False NEGATIVES are impossible, because the 12-bit tag is a pure function of the full 25-bit tag.\n"
              "That is a property you PROVE, not a property you test - see the verification plan, P-WB-1.")
    return f


# ============================================================ 12 refresh
@fig
def f12():
    f = Fig("fig-12-refresh", 1080, 580,
            "Figure 12 - Per-bank refresh keeps the stream running",
            "All-bank refresh stalls a whole pseudo-channel. Per-bank refresh takes out "
            "one bank of 32 while the other 31 keep streaming.")

    f.box("ab", 60, 106, 460, 120, "REFab  -  all-bank  (NOT used)", kind="hot", fs=12.5,
          sub="tRFCab ~ 350 ns, blocks the ENTIRE pseudo-channel\n"
              "= 11 KB of lost bandwidth per event\n\n"
              "350 ns every tREFI (3900 ns)  ->  ~9% overhead")
    f.box("sb", 560, 106, 460, 120, "REFsb  -  per-bank  (baseline)", kind="fe", fs=12.5,
          sub="tRFCsb ~ 190 ns, blocks 1 bank of 32\n"
              "the column stream continues on the other 31\n\n"
              "1.56 banks blocked on average  ->  4.9% raw")

    f.box("opp", 60, 264, 960, 104, "Opportunistic scheduling brings 4.9% down to ~2%", kind="core",
          fs=12.5,
          sub="In steady state 31 of 32 banks are open and streaming, and each goes briefly idle when its row is exhausted.\n"
              "The engine tracks those windows and refreshes a bank that was ABOUT TO BE PRECHARGED ANYWAY, merging\n"
              "PRE -> REF into one row-bus slot pair. Most refreshes then cost only row-bus capacity, which is spare.")

    f.box("cred", 60, 396, 460, 116, "Refresh credit (ref_debt)", kind="core", fs=12,
          sub="JEDEC allows +/- 8 refreshes of slack.\n\n"
              "  debt < 0   opportunistic - only when free\n"
              "  0 .. 5     normal priority in the row arbiter\n"
              "  >= 6       URGENT - taken unconditionally")

    f.box("stag", 560, 396, 460, 116, "Global phase assignment", kind="fe", fs=12,
          sub="256 pseudo-channels refreshing together is a\ncorrelated current spike and a correlated\n"
              "bandwidth notch.\n\n"
              "The supervisor gives each PC a fixed offset of\n(global_pc_index x tREFI) / 256. Costs nothing.")
    return f


# ============================================================ 13 verification
@fig
def f13():
    f = Fig("fig-13-verification-flow", 1140, 700,
            "Figure 13 - Open-source verification flow",
            "Two independent attacks on the same RTL. Properties are written once, in a "
            "subset both engines accept.")

    f.box("rtl", 440, 96, 260, 52, "SystemVerilog RTL", kind="core", fs=12.5)
    f.box("props", 440, 176, 260, 52, "properties  (SVA subset)", kind="hot", fs=12,
          sub="written ONCE, used by both")

    f.group("fm", 60, 268, 500, 260, "FORMAL", kind="group")
    f.box("slang", 84, 308, 210, 48, "yosys-slang", kind="phy", fs=11,
          sub="SV front end")
    f.box("sv2v", 314, 308, 220, 48, "sv2v  (fallback)", kind="plain", fs=11,
          sub="if slang chokes")
    f.box("sby", 84, 376, 450, 56, "SymbiYosys (sby)", kind="core", fs=12.5,
          sub="bmc  -  prove (k-induction)  -  cover  -  live")
    f.box("solv", 84, 452, 210, 56, "solvers", kind="plain", fs=11,
          sub="bitwuzla, yices2,\nz3, abc pdr")
    f.box("mcy", 314, 452, 220, 56, "mcy + eqy", kind="ras", fs=11,
          sub="mutation coverage,\nequivalence")

    f.group("sm", 620, 268, 460, 260, "SIMULATION", kind="group")
    f.box("vl", 644, 308, 200, 48, "Verilator 5", kind="core", fs=11,
          sub="fast, 2-state")
    f.box("iv", 864, 308, 192, 48, "Icarus Verilog", kind="plain", fs=11,
          sub="4-state, X checks")
    f.box("cocotb", 644, 376, 412, 56, "cocotb  (Python testbench)", kind="fe", fs=12.5,
          sub="drivers, monitors, scoreboards")
    f.box("pyvsc", 644, 452, 200, 56, "PyVSC", kind="fe", fs=11,
          sub="constrained random,\nfunctional coverage")
    f.box("model", 864, 452, 192, 56, "HBM4 model", kind="phy", fs=11,
          sub="+ independent\ntiming checker")

    f.edge(("rtl", "s", 0.5), ("props", "n", 0.5))
    f.edge(("props", "s", 0.3), ("fm", "n", 0.6))
    f.edge(("props", "s", 0.7), ("sm", "n", 0.4))

    f.box("gap", 60, 556, 1020, 118, "What open source does NOT give you - plan around these",
          kind="hot", fs=12,
          sub="- No CDC tool of production quality. Mitigated by design: the synchronous NHI leaves only two crossings (Figure 4).\n"
              "- No UVM. cocotb + pyuvm covers the structure; PyVSC covers randomization and coverage.\n"
              "- Verilator is 2-state, so reset and X-propagation bugs can hide. Icarus runs the reset suite as a gate.\n"
              "- No gate-level SDF simulation at speed. Plan for vendor tools at signoff, or lean on eqy equivalence.")
    return f


# ============================================================ 14 deliverables
@fig
def f14():
    f = Fig("fig-14-deliverables", 1080, 600,
            "Figure 14 - What ships to a customer",
            "Everything below is version-locked together by one release tag. "
            "See docs/09-release-notes.md.")

    f.box("rel", 380, 92, 320, 50, "release tag  hbm4c-vX.Y.Z", kind="dark", inv=True, fs=13)

    items = [
        ("rtl", "RTL", "rtl/  parameterized SystemVerilog\nhbm4_sys_top + hbm4_addr_slice", "core"),
        ("docs", "Documentation", "this docs/ set, 10 documents\nfigures as editable .drawio.svg", "fe"),
        ("vip", "Verification kit", "formal/  sby scripts + properties\ntb/  cocotb env, DRAM model", "ras"),
        ("sw", "Software", "CSR header, init scripts,\nreference driver, tuning recipes", "phy"),
    ]
    xs, w = cols(60, 1020, 4, 22)
    for i, (nid, lab, sub, kind) in enumerate(items):
        f.box(nid, xs[i], 194, w, 108, lab, kind=kind, fs=12.5, sub=sub)
        f.edge(("rel", "s", 0.5), (nid, "n", 0.5))

    f.box("cfg", 60, 348, 460, 140, "Configured per customer", kind="core", fs=12.5,
          sub="N_STACK          1 / 2 / 4 / 8\n"
              "SYSECC_EN        on (default) or off\n"
              "WBUF_DEPTH       64 / 128 / 256\n"
              "TQ_DEPTH         32 / 64 / 128\n"
              "ADDRMAP_MODE     STREAM / LOCAL / CLOSE / NUMA\n"
              "PHY vendor       DFI adapter + training script")

    f.box("own", 560, 348, 460, 140, "Customer responsibilities", kind="hot", fs=12.5,
          sub="1. Instantiate hbm4_addr_slice in the fabric\n"
              "2. Deliver NHI traffic at clk_core (1 GHz)\n"
              "3. Provide the PHY and its training script\n"
              "4. Run the integration checklist (doc 05)\n"
              "5. Confirm timing values against their datasheet\n"
              "6. Own DFT insertion and physical closure")

    f.box("supp", 60, 516, 960, 62, "Support model", kind="plain", fs=11.5, dashed=True,
          sub="Every placeholder value marked (P) in the architecture spec must be replaced from the customer's JEDEC copy and\n"
              "vendor datasheet before verification signoff. Doc 08 (compliance matrix) tracks what is claimed and what is not.")
    return f


def main():
    outdir = os.path.normpath(OUT)
    os.makedirs(outdir, exist_ok=True)
    for fn in FIGS:
        p = fn().save(outdir)
        print("wrote", os.path.relpath(p, os.path.join(outdir, "..", "..")))


if __name__ == "__main__":
    main()
