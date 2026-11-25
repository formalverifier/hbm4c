#!/usr/bin/env python3
"""Generate every timing diagram in docs/waves/ (WaveDrom .json + rendered .svg).
Run: python3 tools/gen_waves.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wavelib import Wave  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "docs", "waves"))
WAVES = []


def wv(fn):
    WAVES.append(fn)
    return fn


def chk(w):
    """Every signal must span the same cycle count, and every data char must have data."""
    lens = {r[2]["name"]: len(r[2]["wave"]) for r in w.rows if r[1] == "sig"}
    n = max(lens.values())
    bad = {k: v for k, v in lens.items() if v != n}
    if bad:
        raise SystemExit("%s: wave length != %d: %s" % (w.name, n, bad))
    for r in w.rows:
        if r[1] != "sig":
            continue
        pl = r[2]
        if pl["node"] and len(pl["node"]) != n:
            raise SystemExit("%s: node on %s is %d, expected %d"
                             % (w.name, pl["name"], len(pl["node"]), n))
        need = sum(1 for c in pl["wave"] if c in "=23456789")
        if need != len(pl["data"]):
            raise SystemExit("%s: %s has %d data segments but %d data entries"
                             % (w.name, pl["name"], need, len(pl["data"])))
    return w


# ==================================================== 01 NHI read
@wv
def w01():
    w = Wave("wave-01-nhi-read", "Timing 1 - NHI read transaction",
             "One 32-byte read. The controller echoes req_tag back as rsp_tag, so the host "
             "never has to track ordering. The red break is DRAM latency, not a stall.",
             hscale=0.95)
    w.sig("clk", "p" + "." * 19)
    w.group("request  (host -> controller)")
    w.sig("req_valid", "010" + "." * 4 + "|" + "." * 12,
          node=".a" + "." * 18, depth=1)
    w.sig("req_wr", "x0x" + "." * 4 + "|" + "." * 12, depth=1)
    w.sig("req_blk[24:0]", "x=x" + "." * 4 + "|" + "." * 12, data=["0x004A1"], depth=1)
    w.sig("req_tag[7:0]", "x=x" + "." * 4 + "|" + "." * 12, data=["07"], depth=1)
    w.sig("req_qos[1:0]", "x=x" + "." * 4 + "|" + "." * 12, data=["1"], depth=1)
    w.sig("req_credit", "0" + "." * 6 + "|" + "." * 10 + "10", depth=1)
    w.group("response  (controller -> host)")
    w.sig("rsp_valid", "0" + "." * 6 + "|" + "." * 9 + "10.",
          node="." * 17 + "b..", depth=1)
    w.sig("rsp_ready", "1" + "." * 6 + "|" + "." * 12, depth=1)
    w.sig("rsp_tag[7:0]", "x" + "." * 6 + "|" + "." * 9 + "=x.", data=["07"], depth=1)
    w.sig("rsp_data[255:0]", "x" + "." * 6 + "|" + "." * 9 + "3x.",
          data=["32 B read data"], depth=1)
    w.sig("rsp_err[1:0]", "x" + "." * 6 + "|" + "." * 9 + "=x.", data=["ok"], depth=1)
    w.edge("a<->b  ~32 clk idle, row hit")
    w.note(4, "accepted; one credit consumed")
    w.note(16, "credit returned when the pool entry frees")
    return chk(w)


# ==================================================== 02 out-of-order
@wv
def w02():
    w = Wave("wave-02-nhi-out-of-order", "Timing 2 - Responses return out of order",
             "Tags 07, 08, 09 are issued in that order. Tag 08 hit an open row, so it comes "
             "back first. The host must key on the tag, never on arrival order.",
             hscale=0.95)
    w.sig("clk", "p" + "." * 19)
    w.sig("req_valid", "0111" + "0" + "." * 2 + "|" + "." * 12)
    w.sig("req_tag[7:0]", "x===" + "x" + "." * 2 + "|" + "." * 12,
          data=["07", "08", "09"])
    w.sig("row hit?", "x===" + "x" + "." * 2 + "|" + "." * 12,
          data=["miss", "HIT", "miss"], mono=False)
    w.spacer()
    w.sig("rsp_valid", "0" + "." * 7 + "|" + "." * 5 + "1110..")
    w.sig("rsp_tag[7:0]", "x" + "." * 7 + "|" + "." * 5 + "===x..",
          data=["08", "07", "09"])
    w.sig("rsp_data[255:0]", "x" + "." * 7 + "|" + "." * 5 + "333x..",
          data=["D08", "D07", "D09"])
    w.note(2.5, "issued  07, 08, 09")
    w.note(16, "returned  08, 07, 09")
    return chk(w)


# ==================================================== 03 NHI write
@wv
def w03():
    w = Wave("wave-03-nhi-write", "Timing 3 - NHI write, with write-data skew",
             "The write-data channel is separate and may lag the request by up to WD_SKEW "
             "(default 8) beats. Beats pair with requests in order - wd carries no tag.",
             hscale=0.95)
    w.sig("clk", "p" + "." * 17)
    w.group("request")
    w.sig("req_valid", "0110" + "." * 4 + "|" + "." * 9, depth=1)
    w.sig("req_wr", "x11x" + "." * 4 + "|" + "." * 9, depth=1)
    w.sig("req_blk[24:0]", "x==x" + "." * 4 + "|" + "." * 9,
          data=["0x004A1", "0x004A2"], depth=1)
    w.sig("req_tag[7:0]", "x==x" + "." * 4 + "|" + "." * 9, data=["11", "12"], depth=1)
    w.sig("req_be[31:0]", "x==x" + "." * 4 + "|" + "." * 9,
          data=["all ones", "all ones"], depth=1)
    w.group("write data  (lags by 2 beats here)")
    w.sig("wd_valid", "0.0110" + "." * 2 + "|" + "." * 9, depth=1)
    w.sig("wd_ready", "1" + "." * 7 + "|" + "." * 9, depth=1)
    w.sig("wd_data[255:0]", "x.x44x" + "." * 2 + "|" + "." * 9,
          data=["W0", "W1"], depth=1)
    w.group("completion")
    w.sig("rsp_valid", "0" + "." * 7 + "|" + "." * 5 + "110.", depth=1)
    w.sig("rsp_wack", "0" + "." * 7 + "|" + "." * 5 + "110.", depth=1)
    w.sig("rsp_tag[7:0]", "x" + "." * 7 + "|" + "." * 5 + "==x.",
          data=["11", "12"], depth=1)
    w.note(2, "requests accepted")
    w.note(4.5, "data follows")
    w.note(15, "wack once visible to later reads")
    return chk(w)


# ==================================================== 04 credits
@wv
def w04():
    w = Wave("wave-04-nhi-credit", "Timing 4 - Credit flow control",
             "The host may assert req_valid only while it holds a credit. There is no ready "
             "signal on the request channel - holding a credit IS the permission to send.",
             hscale=0.95)
    w.sig("clk", "p" + "." * 15)
    w.sig("req_valid", "0111111" + "0" + "..." + "110" + "..")
    w.sig("credits (host)", "====..=6" + "..." + "=6" + "...",
          data=["64", "63", "62", "61", "1", "0", "1", "0"], mono=False)
    w.sig("req_credit", "0" + "." * 10 + "1010" + ".")
    w.spacer()
    w.sig("pool occupancy", "====..==" + "..." + "==" + "...",
          data=["0", "1", "2", "3", "63", "64", "63", "64"], mono=False)
    w.note(8, "credits exhausted - the host MUST stall")
    w.note(13, "entry frees, credit returns, host resumes")
    return chk(w)


# ==================================================== 05 DFI steady state
@wv
def w05():
    w = Wave("wave-05-dfi-steady-state",
             "Timing 5 - DFI steady state: all three constraints, visible at once",
             "The picture worth memorising. C1: exactly one column command per clock. "
             "C2: the bank group changes every clock (see the colours). C3: the row bus "
             "issues ACTs in parallel, for free.", hscale=1.0)
    w.sig("clk", "p" + "." * 15)
    w.group("ROW command bus  -  independent (C3)")
    w.sig("dfi_row_cmd", "=.4=..4=..4=..4=",
          data=["--", "ACT b12", "--", "ACT b13", "--", "ACT b14", "--", "ACT b15", "--"],
          depth=1)
    w.group("COLUMN command bus  -  one command per clock (C1)")
    w.sig("dfi_col_cmd", "2345" * 4,
          data=["RD b0", "RD b8", "RD b16", "RD b24",
                "RD b1", "RD b9", "RD b17", "RD b25",
                "RD b2", "RD b10", "RD b18", "RD b26",
                "RD b3", "RD b11", "RD b19", "RD b27"], depth=1)
    w.sig("bank group", "2345" * 4,
          data=["BG0", "BG1", "BG2", "BG3"] * 4, depth=1, mono=False)
    w.group("data bus")
    w.sig("DQ[31:0]", "3" + "." * 15,
          data=["32 B every clock   -   100% bus utilisation"], depth=1)
    w.note(4.5, "ACTs for banks the stream needs in ~tRCD, on the OTHER bus")
    w.note(12.5, "not one column slot wasted")
    return chk(w)


# ==================================================== 06 bank groups
@wv
def w06():
    w = Wave("wave-06-bank-group-penalty",
             "Timing 6 - Why the address map alternates bank groups (C2)",
             "Left: consecutive commands to DIFFERENT bank groups obey tCCD_S = 1 clock and "
             "the bus stays full. Right: the SAME bank group forces tCCD_L = 2 clocks and "
             "half the bandwidth disappears.", hscale=1.0)
    w.sig("clk", "p" + "." * 15)
    w.sig("dfi_col_cmd", "2345234" + "2=2=2=2=2",
          data=["RD BG0", "RD BG1", "RD BG2", "RD BG3", "RD BG0", "RD BG1", "RD BG2",
                "RD BG0", "--", "RD BG0", "--", "RD BG0", "--", "RD BG0", "--", "RD BG0"])
    w.sig("DQ[31:0]", "3" + "." * 6 + "3=3=3=3=3",
          data=["busy every clock", "32B", "", "32B", "", "32B", "", "32B", "", "32B"])
    w.sig("effective BW", "3" + "." * 6 + "6" + "." * 8,
          data=["32 GB/s   (100%)", "16 GB/s   (50%)"], mono=False)
    w.note(3.5, "tCCD_S = 1 clk: bank group alternates")
    w.note(11.5, "tCCD_L = 2 clk: same bank group stalls")
    return chk(w)


# ==================================================== 07 turnaround
@wv
def w07():
    w = Wave("wave-07-read-write-turnaround",
             "Timing 7 - Read/write turnaround burns dead bus",
             "The DQ bus is bidirectional, so every direction change wastes ~12 ns. This is "
             "exactly why the direction FSM drains 128 writes at a time instead of "
             "interleaving per request.", hscale=0.95)
    w.sig("clk", "p" + "." * 19)
    w.sig("direction FSM", "3" + "." * 4 + "6" + "." * 3 + "4" + "." * 10,
          data=["READ", "TO_WRITE  (t_rtw)", "WRITE"], mono=False)
    w.sig("dfi_col_cmd", "22222" + "=" + "..." + "44444" + "4" + "." * 5,
          data=["RD", "RD", "RD", "RD", "RD", "--- bus turning ---",
                "WR", "WR", "WR", "WR", "WR", "... 123 more"])
    w.sig("DQ[31:0]", "33333" + "x" + "..." + "44444" + "4" + "." * 5,
          data=["R", "R", "R", "R", "R", "W", "W", "W", "W", "W", "W"])
    w.sig("bus doing useful work?", "1" + "." * 4 + "0" + "." * 3 + "1" + "." * 10)
    w.note(6.5, "dead: nothing may use the bus")
    w.note(15, "drain 128 writes before turning back")
    return chk(w)


# ==================================================== 08 pipeline
@wv
def w08():
    w = Wave("wave-08-internal-pipeline",
             "Timing 8 - One request through the controller pipeline",
             "The internal view of Figure 6. S0 computes ready vectors for the cycle AFTER "
             "it runs; that one-cycle speculation is what keeps S1 a pure mux at 1 GHz.",
             hscale=1.0)
    w.sig("clk", "p" + "." * 11)
    w.group("E0  accept")
    w.sig("nhi_req_valid", "010" + "." * 9, depth=1)
    w.sig("pool_alloc", "0.10" + "." * 8, depth=1)
    w.group("E1  decode and file")
    w.sig("e1_valid", "0" + "." * 2 + "10" + "." * 7, depth=1)
    w.sig("e1_row / e1_col", "x" + "." * 2 + "=x" + "." * 7,
          data=["row 0x1A4, col 7"], depth=1)
    w.sig("e1_bank", "x" + "." * 2 + "=x" + "." * 7, data=["b12  (BG1)"], depth=1)
    w.sig("hazard_hit", "0" + "." * 11, depth=1)
    w.group("S0  ready vectors, for cycle N+1")
    w.sig("col_ready[31:0]", "=" + "." * 3 + "=" + "." * 7,
          data=["...", "b12 ready"], depth=1)
    w.sig("row_ready[31:0]", "=" + "." * 3 + "=" + "." * 7,
          data=["...", "b12 open"], depth=1)
    w.group("S1  arbitrate    |    S2  format and drive")
    w.sig("col_grant", "0" + "." * 4 + "10" + "." * 5, depth=1)
    w.sig("dfi_col_cmd", "=" + "." * 5 + "2=" + "." * 4,
          data=["--", "RD b12", "--"], depth=1)
    w.sig("dfi_col_phase", "x" + "." * 5 + "=x" + "." * 4, data=["1"], depth=1)
    w.note(2, "E0")
    w.note(3.5, "E1")
    w.note(5, "S0")
    w.note(6.5, "S1/S2 - on the bus")
    return chk(w)


# ==================================================== 09 ECC
@wv
def w09():
    w = Wave("wave-09-ecc-column-access",
             "Timing 9 - Inline ECC costs one column access in fifteen",
             "The ECC column lives in the SAME open row, so fetching it is an ordinary column "
             "read - no activate, no precharge, no bank conflict. After the fill, 14 more "
             "accesses hit the cached block.", hscale=1.0)
    w.sig("clk", "p" + "." * 15)
    w.sig("dfi_col_cmd", "4" + "2" * 14 + "4",
          data=["RD col30 (ECC)", "RD c0", "RD c1", "RD c2", "RD c3", "RD c4", "RD c5",
                "RD c6", "RD c7", "RD c8", "RD c9", "RD c10", "RD c11", "RD c12",
                "RD c13", "RD col31 (ECC)"])
    w.sig("bank / row", "=" + "." * 15,
          data=["b12, row 0x1A4   -   unchanged throughout"], mono=False)
    w.sig("ecc_cache_hit", "0" + "1" + "." * 13 + "0")
    w.sig("ecc_fill_pending", "10" + "." * 14)
    w.note(1, "MISS: fetch ECC col 30")
    w.note(8, "14 data accesses covered by the cached block")
    w.note(15, "next row-half")
    return chk(w)


# ==================================================== 10 refresh
@wv
def w10():
    w = Wave("wave-10-per-bank-refresh",
             "Timing 10 - Per-bank refresh does not stop the stream",
             "REFsb takes bank 5 out of service for tRFCsb (~190 ns). The column arbiter "
             "masks bank 5 and keeps issuing to the other 31. An all-bank REFab would have "
             "stalled the whole pseudo-channel.", hscale=1.0)
    w.sig("clk", "p" + "." * 15)
    w.sig("dfi_row_cmd", "=4=" + "." * 13, data=["--", "REFsb b5", "--"])
    w.sig("refresh_block[5]", "01" + "." * 12 + "0.")
    w.sig("dfi_col_cmd", "2345" * 4,
          data=["RD b0", "RD b8", "RD b16", "RD b24",
                "RD b1", "RD b9", "RD b17", "RD b25",
                "RD b2", "RD b10", "RD b18", "RD b26",
                "RD b3", "RD b11", "RD b19", "RD b27"])
    w.sig("DQ[31:0]", "3" + "." * 15,
          data=["still 100% busy   -   bank 5 was not in the stream"])
    w.sig("ref_debt", "=" + "." * 15,
          data=["-1   (ran early: bank 5 was idle anyway)"], mono=False)
    w.note(2, "REFsb issued on the ROW bus")
    w.note(9.5, "the column bus never notices")
    return chk(w)


# ==================================================== 11 APB
@wv
def w11():
    w = Wave("wave-11-apb-csr", "Timing 11 - APB4 CSR access",
             "Standard APB4 on clk_cfg: SETUP then ACCESS, extended until pready. A write to "
             "a LOCKed register is dropped and raises an interrupt - see the programming guide.",
             hscale=1.0)
    w.sig("pclk", "p" + "." * 13)
    w.sig("psel", "01..0.1..0" + "." * 4)
    w.sig("penable", "0.1.0..1.0" + "." * 4)
    w.sig("pwrite", "01..0" + "." * 9)
    w.sig("paddr[15:0]", "x=..x.=..x" + "." * 4, data=["0x0500", "0x2040"])
    w.sig("pwdata[31:0]", "x=..x" + "." * 9, data=["0x0000_0060"])
    w.sig("pready", "0..10...10" + "." * 4)
    w.sig("prdata[31:0]", "x" + "." * 7 + "=x" + "." * 4, data=["0x0000_1F40"])
    w.note(2.5, "write  WR_HI = 96")
    w.note(8, "read  PC perf counter")
    return chk(w)


def main():
    os.makedirs(OUT, exist_ok=True)
    for fn in WAVES:
        print("wrote docs/waves/%s.json + .svg" % fn().save(OUT))


if __name__ == "__main__":
    main()
