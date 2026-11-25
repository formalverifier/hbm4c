# 07 — Performance Guide

**HBM4 Memory Controller · Rev 1.3**

Expected numbers, how to choose an address map, how to tune, and how to debug a controller
that is not delivering.

---

## 1. Expected performance

Baseline: `N_STACK`=4, `SYSECC_EN`=1, `WBUF_DEPTH`=128, `ADDRMAP_MODE`=STREAM,
`STACK_ILV`=FINE. Raw = 8.19 TB/s.

| Workload | Efficiency | Bandwidth |
|---|---|---|
| 100% sequential read | 88% | 7.21 TB/s |
| 2:1 read:write streaming | **83%** | **6.80 TB/s** |
| 1:1 read:write streaming | 81% | 6.63 TB/s |
| 100% sequential write | 86% | 7.04 TB/s |
| Random 32 B, `CLOSE` policy | 28–35% | 2.3–2.9 TB/s |
| 2:1 streaming, `SYSECC_EN`=0 | 89% | 7.29 TB/s |

Latency (idle, no contention): **~33 ns** on a row hit, **~47 ns** on a row miss. Under load
at 80% utilisation, expect 2–4× the idle figure — that is queueing, not the controller, and
it is the correct trade for a bandwidth-first design.

### 1.1 Where the missing 17% goes

| Loss | Cost | Reducible? |
|---|---|---|
| Inline system ECC | 6.25% | Yes — set `SYSECC_EN=0`, but you give up SDC protection |
| Refresh | 3.0% | Barely. Already using per-bank + opportunistic. |
| Read/write turnaround | 3.0% | Yes — `WBUF_DEPTH`=256 halves it to 1.5% |
| Row miss | 2.0% | Only via the address map, and it is already near optimal |
| Scheduling | 1.5% | Marginally, via tuning |
| Periodic (ZQ, retrain) | 0.3% | No |

**The two levers that actually matter are `SYSECC_EN` and `WBUF_DEPTH`.** Everything else is
noise by comparison.

---

## 2. Choosing an address map

This is the highest-leverage decision. A wrong map cannot be recovered by tuning.

| Workload | Mode | Why |
|---|---|---|
| Long sequential streams, tensor traffic | **`STREAM`** | maximum spread + guaranteed bank-group alternation |
| Working set fits in a few MB, latency matters | `LOCAL` | keeps a stream on fewer PCs, improving row locality per PC |
| Genuinely random 32 B access | `CLOSE` | auto-precharge every access; frees the row bus; row hits were never coming |
| Heterogeneous or degraded stacks; software placement | `NUMA` | contiguous per-stack regions |
| Bring-up, characterisation | `RAW` | full manual control |

### 2.1 Tuning the XOR hash — do not skip this

A raw bit-slice map is catastrophic under power-of-two strides. With defaults, an 8 KB stride
sends **every access to one pseudo-channel of one stack** — you would measure 32 GB/s on an
8 TB/s machine.

The masks `H_ST`, `H_PC`, `H_BG`, `H_BA` fold higher address bits into the low field indices.
Method:

1. Extract the access-stride histogram from a real trace.
2. For each dominant stride `S`, find the bit position `log2(S)`.
3. Set that bit in the `H_PC` masks so the stride folds into the PC index.
4. Re-measure `PC_ACCESS_COUNT` across all 256 PCs. **Max/min should be < 1.1.**

> **Do not hash `rem20`.** The row and column fields must stay contiguous or every row hit
> disappears. The hash masks only reach `stack_id`, `pc_id`, `bg_id`, `ba_id` by
> construction — but in `RAW` mode you can break this yourself. Don't.

### 2.2 Quick diagnostic

```
  imbalance = max(PC_ACCESS_COUNT) / min(PC_ACCESS_COUNT)

    < 1.1   healthy
    1.1-2   mild hot-spotting; adjust one H_PC mask bit
    > 2     the hash is wrong for this workload; go back to step 1
    > 10    a power-of-two stride is camping on one PC
```

---

## 3. Tuning recipes

Always: snapshot → measure → change **one** knob → re-measure.

### 3.1 Turnaround overhead too high

**Symptom:** `TURNAROUND_CYCLES / TOTAL_CYCLES` > 5%.

```
  1. Raise WR_BURST_CREDIT   (128 -> 256)
  2. Raise WR_HI             (96  -> 112)   -- drain later, drain longer
  3. If still high, WBUF_DEPTH is too small: 128 -> 256 at elaboration
```

Overhead follows `12 / (Bw + Br + 12)` ns. If your read:write ratio is near 1:1 you are on
the worst part of that curve and a deeper buffer is the only real fix.

### 3.2 Row-hit rate below 90%

```
  1. Confirm ADDRMAP_MODE == STREAM
  2. Check PC imbalance (§2.2) -- hot-spotting looks like a row-hit problem
  3. Check TQ occupancy: if the queue is shallow the scheduler cannot see
     enough ahead to batch by row.  Raise TQ_DEPTH.
  4. If the workload is genuinely random, stop fighting it: switch to CLOSE.
     Chasing row hits that do not exist costs bandwidth on the row bus.
```

### 3.3 Urgent refreshes appearing

**Symptom:** `REFRESH_URGENT` > 5% of `REFRESH_COUNT`.

The opportunistic path is failing — banks never go idle. Usually means the stream is
saturating all 32 banks with no gaps.

```
  1. Lower IDLE_PRE_THRESH so rows close sooner and idle windows appear
  2. Verify tREFI is programmed for the right temperature grade
  3. Accept it: at very high utilisation some refreshes must be forced.
     3% is the budget; 5% is still fine.
```

### 3.4 ECC read-modify-writes

**Symptom:** `ECC_RMW` > 2% of writes.

Partial writes are not coalescing.

```
  1. Raise RMW_COALESCE_WIN (128 -> 512)
  2. Raise WBUF_DEPTH -- more time for neighbours to merge
  3. Fix it upstream: if the host can issue full 32 B writes, it should.
     A partial write is expensive here and free to avoid in the producer.
```

### 3.5 Latency-critical class missing its target

```
  1. Mark it req_qos = 3 (urgent)
  2. Set WR_PREEMPT_EN = 1 so it can break a write drain
  3. Lower AGE_TICK so bulk traffic escalates faster and queues stay shallow
  4. If it still misses, the working set may want ADDRMAP_MODE = LOCAL
```

Note the tension: QoS urgent sits above round-robin, but aging promotes bulk traffic to
urgent too. That is deliberate — it bounds starvation — and it means QoS is a *bias*, not a
guarantee.

---

## 4. Debugging low bandwidth

Work down this list. `COL_IDLE_WITH_PENDING` is the master metric: it counts cycles where
the column bus was idle *while work was queued*. Every other counter exists to explain it.

```
  COL_IDLE_WITH_PENDING is high?
    |
    +-- TURNAROUND_CYCLES high?          -> §3.1
    +-- ROW_MISS high?                   -> §3.2
    +-- REFRESH_URGENT high?             -> §3.3
    +-- ECC_RMW high?                    -> §3.4
    +-- QUEUE_OCC low?                   -> the host is not supplying enough
    |                                       requests; check credits and rsp_ready
    +-- PC imbalance > 2?                -> §2.2, the address hash
    +-- none of the above                -> bank-group conflicts; check that
                                            ADDRMAP_MODE is STREAM and that
                                            H_BG has not been set to something
                                            that breaks the +8 KB alternation
```

### 4.1 If the host is the bottleneck

`IRQ_STATUS` bit 7 (`rsp_ready` stalled) and low `QUEUE_OCC` together mean the controller is
waiting on you. At 32 GB/s per pseudo-channel, a port that cannot accept a response every
clock will cap that PC. Buffer in the fabric rather than back-pressuring the controller —
back-pressure on `rsp_ready` propagates all the way to the DRAM bus and idles it.

---

## 5. Scaling

| Change | Bandwidth | Capacity | Notes |
|---|---|---|---|
| `N_STACK` 4 → 8 | 2× | 2× | linear; fabric must supply 2× the traffic |
| `N_STACK` 4 → 2 | 0.5× | 0.5× | linear |
| `SYSECC_EN` 1 → 0 | +6.25% | +6.25% | forfeits SDC protection |
| `WBUF_DEPTH` 128 → 256 | +1.5% | — | +512 KB SRAM |
| `WBUF_DEPTH` 128 → 64 | −2.9% | — | −512 KB SRAM |
| Data rate 8 → 10 Gb/s (HBM4E) | +25% | — | core clock 1.25 GHz; re-close timing |

**Efficiency is essentially independent of `N_STACK`** — pseudo-channels are independent, so
the per-PC analysis holds. What changes is whether your fabric can feed it.

---

## 6. Cross-checking the model

The numbers in §1 are analytic. Before trusting them:

1. Build an HBM4 configuration for **Ramulator 2** (or DRAMsim3) with your timing table.
2. Replay the same traces through Ramulator and through the RTL.
3. Compare achieved bandwidth.

**If they disagree by more than 3%, one of them is wrong** — and finding out which is worth
the day it costs. Historically the disagreement is usually the model's refresh handling or
the RTL's turnaround policy, and both are worth knowing about before tape-out.

---

## 7. Regression floors

Record these as CI gates ([06-verification-plan.md §8](06-verification-plan.md)). A change
costing more than 2% must fail the build.

| Generator | Floor |
|---|---|
| Sequential read, 32 MB | 88% efficiency, 96% row hit |
| Sequential write, 32 MB | 86% |
| 2:1 R:W streaming | 83% |
| 1:1 R:W streaming | 81% |
| Tensor tiling (2-D, 4 KB tiles) | 78%, PC imbalance < 1.2 |
| Uniform random, CLOSE | 28% |
| Idle read latency | ≤ 35 ns |
| Adversarial: single-bank hammer | no starvation; max latency < `WR_AGE_LIMIT` |
| Adversarial: all-urgent flood | bulk traffic still progresses (aging works) |

---

## Measured results

**Rev 1.0.** Everything above this section was derived from the timing parameters. This section
is measured — `sim/test_slice.py::test_streaming_efficiency`, production geometry.

| Workload | Measured |
|---|---|
| Sequential streaming reads, saturating | **98.8%** column-bus utilisation (1186 column commands / 1200 core clocks) |
| Sequential streaming, bank-group alternation | **0.0%** of consecutive column pairs in the same bank group |

The second number is the reason for the first: constraint **C2** holds on *every* consecutive
pair, so `tCCD_L` is never the limiter. That is what the address map exists to deliver
([02 §5.1](02-architecture.md)), and it is now measured rather than argued.

### How to read 98.8%

It is a 1200-clock steady-state window on pure sequential reads, with the refresh duty cycle
largely outside it. It establishes that the scheduler and address map **can** saturate the
column bus. It is **not** a full-workload efficiency figure, and it does not supersede the
~83% target above, which includes refresh overhead and direction turnaround over long windows.

### Two ways this measurement lied first

Both produced a specific, confident, wrong number:

1. **21%** — 252 column commands from 256 requests. The window was transaction-limited, not
   bandwidth-limited. *A saturation test that is not saturated measures the testbench.*
2. **20% at reduced geometry** — `TQ_DEPTH` is 4 under `FV_SMALL`, so at most four transactions
   are ever outstanding and the bus cannot be saturated regardless of scheduling quality.

Efficiency runs at `GEOM=full` only, and is skipped at reduced geometry rather than reported.

### Sizing the transaction pool — an open question

Synthesis ([syn/README.md](../syn/README.md)) shows `hbm4_txn_pool` is **40.5%** of a
pseudo-channel. At `TQ_DEPTH = 64` the system carries **16 384 in-flight transactions**, which
is almost certainly over-provisioned for row-hit-dominated streaming. Halving it would remove
roughly 4 M gate equivalents system-wide.

**This guide should say what depth the workload needs, and currently does not** — 64 was
inherited as a default, not derived. It is the highest-value open performance question.
