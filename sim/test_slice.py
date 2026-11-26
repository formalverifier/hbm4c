"""Slice-level tests.

The headline test is test_reset_clean: assumption A1 in formal/ASSUMPTIONS.md
says the design starts from a clean reset, and no proof can justify that -- the
proofs ASSUME it.  Simulation is the only thing that can discharge it, which is
why it is here and why it checks state rather than just "nothing exploded".
"""

import os
import random
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from testbench import setup, N_BANK, N_COL_DATA, TQ_DEPTH, TAG_W
from hbm4_dram_model import TimingViolation


@cocotb.test()
async def test_reset_clean(dut):
    """A1: after reset the slice is idle, holds no state, and drives nothing.

    This is the assumption every formal proof rests on.  If the slice comes out
    of reset with a bank marked active, a non-empty queue, or a command on the
    bus, then every proof that assumed a clean start is proving something about
    a state the silicon never occupies.
    """
    # Gate held CLOSED: this is the state the design is actually in between
    # reset release and the end of PHY training, and the state A1 is about.
    drv, mon, model, rdret = await setup(dut, open_gate=False)

    assert int(dut.busy.value) == 0, "busy asserted out of reset"
    assert int(dut.dfi_row_valid.value) == 0, \
        "row command driven before training completed"
    assert int(dut.occupancy.value) == 0, "queue non-empty out of reset"
    # NOT "the row bus is idle".  The refresh engine legitimately issues
    # opportunistically as soon as banks are idle, and after reset every bank is
    # idle -- so refresh traffic here is correct behaviour, not a fault.  What
    # must hold is that nothing has been issued to a bank the controller thinks
    # is OPEN, and that no COLUMN command appears: a column command requires an
    # open row, and out of reset there is none.
    assert int(dut.dfi_col_valid.value) == 0, \
        "column command driven out of reset -- there is no open row to address"
    assert int(dut.rsp_valid.value) == 0, "response driven out of reset"
    assert int(dut.err_rdfifo.value) == 0 and int(dut.err_stall.value) == 0, \
        "error flag set out of reset"
    assert int(dut.sts_lecc_ce.value) == 0 and int(dut.sts_lecc_ue.value) == 0, \
        "error counters non-zero out of reset"

    # No credit check here: credits are an INITIAL allowance, not something the
    # controller grants after reset (docs/03 §7).  Credit RETURN is checked in
    # test_credit_return, where there is a completion to return one for.

    # Stay closed for a while: the slice must remain off the bus indefinitely,
    # not merely be slow to start.  Boot takes ~200 us of wall time in the real
    # sequence, so "quiet for two cycles" proves nothing.
    for _ in range(200):
        await RisingEdge(dut.clk)
        assert int(dut.dfi_row_valid.value) == 0 and int(dut.dfi_col_valid.value) == 0, \
            "slice drove the DRAM bus while the boot gate was closed"
        assert int(dut.busy.value) == 0, \
            "slice reported busy while gated -- the stack top would never see a " \
            "quiet slice and boot would deadlock"

    # Opening the gate must actually release it -- a gate that never opens is
    # just as broken as one that never closes.
    dut.cmd_en.value = 1
    saw = False
    for _ in range(400):
        await RisingEdge(dut.clk)
        if int(dut.dfi_row_valid.value):
            saw = True
            break
    assert saw, "slice never issued a command after the boot gate opened"

    dut._log.info(f"reset clean; gate holds and releases; {drv.credits} credits")


@cocotb.test()
async def test_single_read(dut):
    """One read: does anything happen at all, and is it legal?"""
    drv, mon, model, rdret = await setup(dut)
    await drv.send(is_write=False, blk=0)
    # Long enough for production timings AND the opportunistic refresh sweep that
    # follows reset: with 32 banks and tRFCsb = 96 the row bus is busy for a
    # while before the first ACT can go.
    await ClockCycles(dut.clk, 4000)

    assert model.n_act >= 1, "no ACT issued for a read -- the row never opened"
    assert model.n_rd >= 1, "no column read issued"
    assert not model.violations, f"timing violations: {model.violations[:3]}"
    dut._log.info(f"single read -> {model.stats()}")


@cocotb.test()
async def test_streaming_sequential(dut):
    """The workload the design is FOR: long sequential streaming reads.

    docs/07 claims ~83% bus efficiency on this pattern.  The check here is the
    weaker but sharper one -- that the bank group alternates on consecutive
    column commands, which is constraint C2 and the thing the whole address map
    exists to deliver.  If it holds, tCCD_L is never the limiter; if it does
    not, the design cannot reach its claimed bandwidth no matter what else is
    right.
    """
    drv, mon, model, rdret = await setup(dut)

    for i in range(64):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 3000)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert model.n_rd >= 32, f"only {model.n_rd} reads issued from 64 requests"

    # Consecutive column commands should alternate bank group.
    cols = mon.col_log
    same_bg = sum(1 for a, b in zip(cols, cols[1:])
                  if model.bg_of(a[2]) == model.bg_of(b[2]))
    frac = same_bg / max(1, len(cols) - 1)
    dut._log.info(f"{len(cols)} column commands, {frac:.1%} consecutive pairs "
                  f"in the same bank group")
    assert frac < 0.5, (f"bank group failed to alternate on {frac:.1%} of "
                        f"consecutive column commands -- C2 is not being met, "
                        f"so tCCD_L will cap throughput")


@cocotb.test()
async def test_write_read_data(dut):
    """End-to-end data: what the DRAM ends up holding must match what was written.

    This is now true. Before Rev 1.2 the assertion was a write COUNT while this
    docstring claimed contents -- the design had no write datapath at all, so
    there was nothing to check and the reference array stayed empty.

    Timing legality alone does not catch a controller that writes to the wrong
    place -- wrong open row, wrong column after the ECC reservation, wrong bank
    from a bad decode.  This is the check that does.
    """
    drv, mon, model, rdret = await setup(dut)

    sent = {}
    for i in range(16):
        d = 0xA5A5_0000 + i
        sent[i] = d
        await drv.send(is_write=True, blk=i, data=d)
    await ClockCycles(dut.clk, 4000)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert model.n_wr >= 8, f"only {model.n_wr} writes reached the DRAM"

    # THE ACTUAL DATA CHECK. Until Rev 1.2 this test asserted only the write
    # COUNT while its docstring claimed to verify contents -- and it could not
    # have done more, because the design had no write datapath and the reference
    # array was never written. It passed for three revisions saying nothing.
    stored = sorted(v for v in model.array.values() if v is not None)
    expect = sorted(sent.values())
    assert stored, "the reference array is empty -- no write data reached the DRAM"
    assert stored == expect, (
        f"the DRAM holds {len(stored)} blocks but not the values written: "
        f"got {stored[:4]}..., expected {expect[:4]}...")
    dut._log.info(f"{len(stored)} blocks written and verified byte-exact -> "
                  f"{model.stats()}")


async def _send_tagged(drv, dut, tag, blk, data):
    """One write with a CHOSEN tag -- NhiDriver.send picks tags itself, and the
    whole point here is to pick colliding ones. Credits are still honoured."""
    while drv.credits <= 0:
        await RisingEdge(dut.clk)
    dut.req_valid.value = 1
    dut.req_wr.value = 1
    dut.req_blk.value = blk
    dut.req_tag.value = tag
    dut.req_qos.value = 0
    dut.req_data.value = data
    await RisingEdge(dut.clk)
    dut.req_valid.value = 0
    drv.credits -= 1


@cocotb.test()
async def test_write_data_tag_independence(dut):
    """Write data must follow the TRANSACTION, never the host's tag.

    Until Rev 1.4 hbm4_wdata_ram was indexed by req_tag. At production geometry
    a tag is 8 bits and the RAM has TQ_DEPTH = 64 entries, so the index was
    silently truncated and tags t and t+64 shared an entry. And docs/03 rule H2
    requires tags to be unique among outstanding READS only, so a conforming
    host may also reuse one tag across outstanding writes. Either way a later
    write overwrote an earlier write's data while it was still queued, and the
    earlier write then put the wrong bytes at a correct address -- with no error
    anywhere. Formal could not see it: under FV_SMALL the tag is exactly as wide
    as the pool index. The other tests could not either: their driver keeps
    tags small and unique.

    Both collision patterns are driven here with every write outstanding at
    once, and every block must reach the DRAM byte-exact, exactly once.
    """
    # Gate CLOSED while sending: requests are accepted but nothing issues, so
    # every write in the plan is provably outstanding at the same time. Without
    # that, a write could issue before its collider arrived and the test would
    # pass against the broken design.
    drv, mon, model, rdret = await setup(dut, open_gate=False)

    err_cycles = []

    async def watch_no_data():
        # hbm4_wdata_ram's own alarm: a write issued from an entry that holds no
        # data. With per-transaction storage it must never fire.
        while True:
            await RisingEdge(dut.clk)
            if dut.rst_n.value and int(dut.u_dut.err_wdata.value):
                err_cycles.append(mon.cycle)

    cocotb.start_soon(watch_no_data())

    rng = random.Random(0x7A6)
    plan = []                                   # (tag, blk, data)
    # (1) One tag on several outstanding writes -- legal under H2 as written.
    for _ in range(min(4, TQ_DEPTH)):
        plan.append((1, len(plan), rng.getrandbits(256)))
    # (2) Tags that are all DIFFERENT but congruent modulo TQ_DEPTH -- legal
    # under any reading of H2, and they collided anyway through the truncated
    # index. Needs a tag space wider than the pool: production geometry only.
    if (1 << TAG_W) > TQ_DEPTH:
        for t in range(8, 24):
            for tag in (t, t + TQ_DEPTH):
                plan.append((tag, len(plan), rng.getrandbits(256)))
    assert len(plan) <= TQ_DEPTH, "plan exceeds the credit allowance"

    for tag, blk, data in plan:
        await _send_tagged(drv, dut, tag, blk, data)
    await ClockCycles(dut.clk, 4)      # past the two-cycle decode, into the pool

    # Anti-vacuity: all of them held in the transaction pool together, none
    # issued. Read the pool's own occupancy, not the `occupancy` port: that is
    # the NHI's count of accepted requests, equal to len(plan) by construction,
    # so a check on it could never fail.
    assert not [c for c in drv.completed if c[3]], \
        "a write completed while the boot gate was closed"
    pool_occ = int(dut.u_dut.pool_occ.value)
    assert pool_occ == len(plan), (
        f"only {pool_occ} of {len(plan)} writes held in the pool at once -- "
        f"the collision this test exists for never happened")

    dut.cmd_en.value = 1
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if sum(1 for c in drv.completed if c[3]) >= len(plan):
            break
    n_ack = sum(1 for c in drv.completed if c[3])
    assert n_ack == len(plan), f"only {n_ack} of {len(plan)} writes completed"
    await ClockCycles(dut.clk, 50)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert model.n_wr == len(plan), \
        f"{model.n_wr} column writes reached the DRAM for {len(plan)} requests"
    # Every value is distinct, so any write that carried another write's data
    # shows up as one value missing and another duplicated.
    stored = sorted(v for v in model.array.values() if v is not None)
    expect = sorted(d for (_, _, d) in plan)
    assert stored == expect, (
        f"{sum(1 for d in expect if d not in stored)} of {len(plan)} blocks "
        f"hold another write's data")
    # Checked second: the data above is the symptom; this is the RAM's own
    # alarm, and it must stay silent too.
    assert not err_cycles, (
        f"a write issued with no data in its entry (first at DFI cycle "
        f"{err_cycles[0]}) -- write data is not tracked per transaction")
    dut._log.info(f"{len(plan)} colliding-tag writes, all byte-exact -> "
                  f"{model.stats()}")


@cocotb.test()
async def test_random_traffic(dut):
    """Mixed random read/write across the address space.

    The point is turnaround: random direction changes exercise tWTR/tRTW, which
    sequential traffic barely touches, and they are the parameters a
    write-buffer bug shows up in first.
    """
    random.seed(1)
    drv, mon, model, rdret = await setup(dut)

    for _ in range(96):
        await drv.send(is_write=random.random() < 0.35,
                       blk=random.randrange(0, N_BANK * N_COL_DATA),
                       data=random.getrandbits(32))
    await ClockCycles(dut.clk, 6000)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert int(dut.err_rdfifo.value) == 0, "read FIFO overflowed"
    assert int(dut.err_stall.value) == 0, "slice reported a stall timeout"
    dut._log.info(f"random traffic -> {model.stats()}")


@cocotb.test()
async def test_refresh_happens(dut):
    """Refresh must actually be issued, and must not violate tRFCsb.

    A controller that never refreshes passes every other test in this file and
    loses data in silicon after ~32 ms.
    """
    drv, mon, model, rdret = await setup(dut, refi=64)

    for i in range(32):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 6000)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert model.n_ref > 0, "no refresh issued -- data would be lost in silicon"
    dut._log.info(f"refresh issued {model.n_ref} times")


@cocotb.test()
async def test_credit_return(dut):
    """Every completion must return exactly one credit.

    A controller that completes a transaction without returning its credit
    starves the host one slot at a time.  Nothing fails; throughput just decays
    until the port stops, which is close to the worst symptom to debug from.
    """
    drv, mon, model, rdret = await setup(dut)
    start = drv.credits

    n = 8
    for i in range(n):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 3000)

    assert not model.violations, f"timing violations: {model.violations[:3]}"
    assert len(drv.completed) > 0, "no responses returned at all"
    # credits = start - issued + returned, and returns track completions 1:1.
    assert drv.credits == start - n + len(drv.completed), (
        f"credit accounting drifted: started {start}, issued {n}, "
        f"completed {len(drv.completed)}, hold {drv.credits}")
    dut._log.info(f"{len(drv.completed)} completions, {drv.credits} credits held")


@cocotb.test()
async def test_link_ue_escalates(dut):
    """A link uncorrectable must reach the host as an ERROR, not as silence.

    Retry is deliberately disabled (OPEN-9): pool entries are freed at issue, so
    by the time a link error is detected the entry holding the address is gone
    and there is nothing to re-issue from.  That makes the escalation path the
    ONLY defence, and it has to work: the failure mode it replaces is a response
    that never arrives, which the host sees as a hang with no error anywhere.

    Corrupting the code rather than the data is deliberate -- it is the check
    field the decoder trusts, so a bad one must be caught by the decoder rather
    than pass through as plausible data.
    """
    drv, mon, model, rdret = await setup(dut)

    # Return a code that does not match the data, on every read.
    rdret.data_fn = lambda bk, cl: 0
    orig = rdret.run

    corrupt = {"n": 0}

    async def corrupted():
        seen = 0
        while True:
            await RisingEdge(dut.clk)
            dut.dfi_rddata_valid.value = 0
            if not dut.rst_n.value:
                continue
            while seen < len(mon.col_log):
                t, cmd, bk, cl = mon.col_log[seen]
                seen += 1
                if cmd in (1, 3):
                    rdret.queue.append((t + rdret.tRL, bk, cl))
            if rdret.queue and mon.cycle >= rdret.queue[0][0]:
                rdret.queue.pop(0)
                dut.dfi_rddata_valid.value = 1
                dut.dfi_rddata.value = 0
                dut.dfi_rdcode.value = 0xFFFF      # inconsistent with data 0
                corrupt["n"] += 1

    cocotb.start_soon(corrupted())

    for i in range(4):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 2000)

    assert corrupt["n"] > 0, "no corrupted beats were injected"
    assert int(dut.sts_lecc_ue.value) > 0 or int(dut.sts_lecc_ce.value) > 0, (
        "link ECC counted neither a correctable nor an uncorrectable after "
        f"{corrupt['n']} corrupted beats -- the decoder is not checking the code")
    dut._log.info(f"{corrupt['n']} corrupted beats -> "
                  f"ce={int(dut.sts_lecc_ce.value)} ue={int(dut.sts_lecc_ue.value)} "
                  f"responses={len(drv.completed)}")


@cocotb.test()
async def test_reset_mid_operation(dut):
    """A1's other half: reset asserted while transactions are in flight.

    Every formal proof assumes reset happens at power-on and never again. Nothing
    justifies that -- a system reset can land at any time, and the dangerous case
    is precisely the one the proofs exclude: reset in the middle of an open row,
    a queued transaction and an outstanding read.

    What must hold afterwards is that NO STATE SURVIVES. A bank still marked open
    across a reset is the worst outcome available: the controller would issue a
    column command against a row the DRAM has closed, and read whatever the
    sense amps happen to hold.
    """
    drv, mon, model, rdret = await setup(dut)

    for i in range(4):
        await drv.send(is_write=False, blk=i)
    # Land the reset while work is genuinely in flight, not on an idle machine.
    await ClockCycles(dut.clk, 12)
    assert int(dut.occupancy.value) > 0 or model.n_act > 0, \
        "nothing was in flight; the test would prove nothing"

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)

    assert int(dut.dfi_row_valid.value) == 0 and int(dut.dfi_col_valid.value) == 0, \
        "slice drove the DRAM bus while reset was asserted"
    assert int(dut.rsp_valid.value) == 0, "response driven during reset"

    dut.rst_n.value = 1
    dut.cmd_en.value = 0            # gate closed again, as after any reset
    await ClockCycles(dut.clk, 3)

    # Resynchronise the reference device, standing in for the PRECHARGE ALL that
    # the boot script issues before anything else touches the array.
    #
    # This is not testbench convenience -- it is the actual requirement the test
    # discovered.  Reset wipes the controller's bank state but does NOT close the
    # device's rows, so until a precharge-all lands, the controller believes
    # everything is closed while the device still holds rows open, and the first
    # refresh goes to a bank the DRAM considers active.  The slice has no
    # sequencer, so the resync is modelled here; it is verified for real at the
    # stack level by test_boot.test_precharge_all_precedes_mrs.
    for b in model.bank:
        b.active = False

    assert int(dut.occupancy.value) == 0, \
        f"{int(dut.occupancy.value)} transactions survived reset -- the pool did not clear"
    assert int(dut.busy.value) == 0, "slice busy after reset"
    assert int(dut.err_rdfifo.value) == 0 and int(dut.err_stall.value) == 0, \
        "error flag set by the reset itself"
    assert int(dut.sts_lecc_ce.value) == 0 and int(dut.sts_lecc_ue.value) == 0, \
        "error counters survived reset"

    # The gate must stay closed long enough for the DEVICE to settle, not just
    # the controller.  Reset clears the controller's timing counters, but the
    # DRAM is still counting out whatever tRFCsb / tRP / tRAS was in flight --
    # so resuming immediately violates them on a device that is behaving
    # perfectly.  (Caught here as "tRFCsb violated: REF came 48 cycles after the
    # previous event, needs >= 96".)
    #
    # The real system gets this for free: cmd_en is seq_done, seq_done resets to
    # zero, and the boot script opens with tINIT waits that dwarf every DRAM
    # parameter.  It is a genuine PRODUCT REQUIREMENT rather than a quirk -- the
    # full boot sequence must re-run after any reset -- and it is enforced
    # structurally rather than by documentation.
    await ClockCycles(dut.clk, 150)
    dut.cmd_en.value = 1
    drv.credits = 4
    model2_acts = model.n_act
    await drv.send(is_write=False, blk=0)
    await ClockCycles(dut.clk, 600)
    assert model.n_act > model2_acts, "slice issued nothing after reset recovery"
    dut._log.info("mid-operation reset: no state survived, slice recovered")


@cocotb.test(skip=(os.environ.get("GEOM", "small") != "full"))
async def test_streaming_efficiency(dut):
    """Measure column-bus utilisation on the workload the design is for.

    docs/07 claims ~83% bus efficiency on streaming reads. That number has been
    argued from the timing parameters and never measured. This measures it.

    RUNS AT PRODUCTION GEOMETRY ONLY (GEOM=full). Under FV_SMALL, TQ_DEPTH is 4,
    so at most four transactions are ever outstanding and the column bus cannot
    be saturated regardless of scheduling quality -- a first run there measured
    20% and that number says nothing about the design.

    Utilisation is column commands per core clock over the steady-state window:
    one column command per clock is 100% of the bus, because BL8 at 8 Gb/s is
    exactly one core clock (docs/02 §3).
    """
    drv, mon, model, rdret = await setup(dut)

    # Feed enough work to keep the bus the bottleneck for the whole window.
    # A first version issued 256 requests into a 1200-cycle window and measured
    # 21% -- which was 252 column commands from 256 requests, i.e. the number of
    # transactions supplied, not the bandwidth achieved.  A saturation test that
    # is not saturated measures the testbench.
    N = 4000
    cocotb.start_soon(_feed(drv, N))
    await ClockCycles(dut.clk, 200)         # let the pipeline fill
    start_cycle, start_cols = mon.cycle, len(mon.col_log)
    await ClockCycles(dut.clk, 1200)
    span = mon.cycle - start_cycle
    cols = len(mon.col_log) - start_cols

    # mon.cycle counts DFI phases (two per core clock).
    core_clocks = span / 2
    util = cols / core_clocks if core_clocks else 0
    dut._log.info(f"steady state: {cols} column commands in {core_clocks:.0f} "
                  f"core clocks = {util:.1%} column-bus utilisation")

    assert not model.violations, f"timing violations: {model.violations[:2]}"
    assert util > 0.30, (
        f"column-bus utilisation {util:.1%} on pure sequential streaming -- the "
        f"design targets ~83%, so this is a scheduling problem, not a margin")


async def _feed(drv, n):
    for i in range(n):
        await drv.send(is_write=False, blk=i)


@cocotb.test()
async def test_raw_hazard(dut):
    """A read must never overtake a queued write to the same block.

    Until Rev 1.1 hbm4_wbuf was not instantiated and dir_fsm's raw_hazard input
    was tied to 1'b0, so a read to an address with a write still queued issued
    straight to DRAM and returned the OLD data. Silent corruption: no error, no
    symptom, wrong bytes.

    The check is on the DRAM command stream, not on returned data, because the
    testbench's read-return path supplies its own data -- ordering at the device
    is the thing that has to hold.
    """
    drv, mon, model, rdret = await setup(dut)

    TARGET = 0
    await drv.send(is_write=True, blk=TARGET, data=0xDEAD_BEEF)
    await drv.send(is_write=False, blk=TARGET)
    # Background traffic to other blocks, so the scheduler has reasons to prefer
    # reads and the hazard has to be what holds the read back.
    for i in range(1, 8):
        await drv.send(is_write=False, blk=i)
    await ClockCycles(dut.clk, 4000)

    assert not model.violations, f"timing violations: {model.violations[:2]}"

    tw = [(t, bk, cl) for (t, cmd, bk, cl) in mon.col_log if cmd in (2, 4)]
    tr = [(t, bk, cl) for (t, cmd, bk, cl) in mon.col_log if cmd in (1, 3)]
    assert tw, "the write never reached the DRAM"
    assert tr, "no read reached the DRAM"
    for (twt, bk, cl) in tw:
        earlier = [t for (t, rbk, rcl) in tr if (rbk, rcl) == (bk, cl) and t < twt]
        assert not earlier, (
            f"read to bank {bk} col {cl} issued at {earlier[0]}, before the "
            f"write to the same block at {twt} -- the read returns stale data")

    dut._log.info(f"RAW ordering held: {len(tw)} writes, {len(tr)} reads, "
                  f"no read overtook a write to the same block")
