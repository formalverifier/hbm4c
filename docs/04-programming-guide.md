# 04 — Programming Guide

**HBM4 Memory Controller · Rev 1.3**

For the firmware or driver engineer. Covers the register map, the boot sequence, runtime
tuning, and error handling.

---

## 1. Register map

APB4, 32-bit, on `clk_cfg`. The supervisor presents a unified aperture; per-stack blocks are
windowed.

### 1.1 Top-level layout

| Address | Block |
|---|---|
| `0x0000_0000` | Supervisor: ID, capability, boot control, global IRQ |
| `0x0000_0100` | Global address map: mode, `H_ST`/`H_PC` masks, `ECC_EN`, `STACK_ILV` |
| `0x0001_0000 + s×0x1_0000` | **Per-stack window**, `s` = 0…`N_STACK`−1 |

### 1.2 Supervisor block

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x000` | `ID` | RO | `0x48424D34` ("HBM4") |
| `0x004` | `VERSION` | RO | `{major[7:0], minor[7:0], patch[15:0]}` |
| `0x008` | `CAP0` | RO | `{N_STACK, N_PC, TQ_DEPTH, WBUF_DEPTH}` as built |
| `0x00C` | `CAP1` | RO | `{SYSECC_EN, RFM_MODE_MAX, PG_GROUP, …}` |
| `0x010` | `BOOT_CTRL` | RW | `[0]` start, `[1]` degraded-boot enable, `[2]` warm |
| `0x014` | `BOOT_STATUS` | RO | `[3:0]` per-stack done, `[7:4]` per-stack fail, `[8]` ctrl_ready |
| `0x018` | `IRQ_STATUS` | W1C | aggregated; see §5.1 |
| `0x01C` | `IRQ_MASK` | RW | |
| `0x020` | `PERF_SNAPSHOT` | WO | write 1 → freeze all 256 PC counters coherently |
| `0x024` | `TIMESTAMP` | RO | free-running 48-bit global, low word |

### 1.3 Global address map

| Offset | Name | Description |
|---|---|---|
| `0x100` | `AMAP_MODE` | `[2:0]` STREAM/LOCAL/CLOSE/NUMA/RAW, `[4:3]` `STACK_ILV`, `[8]` `ECC_EN` |
| `0x104`–`0x10C` | `H_ST[1:0]` | 31-bit XOR masks for `stack_id` (2 registers) |
| `0x110`–`0x127` | `H_PC[5:0]` | 31-bit XOR masks for `pc_id` (6 registers) |
| `0x1F0` | `AMAP_LOCK` | **sticky**; write 1 to lock. Never clears except by cold reset. |

> ⚠️ **The `H_ST`/`H_PC` values here must exactly match the `cfg` bundle you drive into every
> `HBM4_ADDR_SLICE` instance in your fabric.** A mismatch corrupts memory with no error
> indication. Program the CSRs and the fabric from **one** source structure in your driver,
> then lock.

### 1.4 Per-stack window

| Offset | Block |
|---|---|
| `+0x0000` | Stack global: init control/status, DFI config |
| `+0x0100` | Local map: `H_BG[1:0]`, `H_BA[2:0]`, page policy |
| `+0x0200` | **DRAM timing** — ~40 fields, in core clocks, double-buffered |
| `+0x0400` | Refresh: `tREFI`, `tRFC`, policy, RFM/DRFM |
| `+0x0500` | Scheduler policy — see §1.5 |
| `+0x0600` | RAS: enables, thresholds, poison, scrub, error log |
| `+0x0800` | Power: LP thresholds, DVFS, per-PC enable/gate |
| `+0x1000` | Init/training: sequencer control, script RAM window |
| `+0x2000 + pc×0x40` | Per-PC status and performance counters (64 instances) |

### 1.5 Scheduler policy (`+0x0500`) — the tuning knobs

| Offset | Name | Default | Range | Effect |
|---|---|---|---|---|
| `+0x00` | `WR_HI` | 96 | 8…`WBUF_DEPTH` | leave READ when writes reach this |
| `+0x04` | `WR_LO` | 16 | 0…`WR_HI`−8 | leave WRITE when writes fall to this |
| `+0x08` | `WR_BURST_CREDIT` | 128 | 8…1024 | max writes per drain |
| `+0x0C` | `WR_AGE_LIMIT` | 4096 | 64…65535 | starvation guard, clocks |
| `+0x10` | `AGE_TICK` | 512 | 32…8192 | QoS escalation period |
| `+0x14` | `PAGE_POLICY` | OPEN | OPEN/ADAPTIVE/CLOSE | |
| `+0x18` | `IDLE_PRE_THRESH` | 64 | 8…4096 | ADAPTIVE close threshold |
| `+0x1C` | `ACT_LOOKAHEAD` | tRCD+4 | 4…255 | activation horizon |
| `+0x20` | `HOIST_MAX` | 8 | 0…31 | 0 disables group hoisting |
| `+0x24` | `WR_PREEMPT_EN` | 1 | 0/1 | urgent reads preempt a write drain |
| `+0x28` | `RMW_COALESCE_WIN` | 128 | 0…4096 | partial-write merge window |

### 1.6 Timing block (`+0x0200`) — double-buffered

Write to the **shadow** set, then commit atomically:

```
  +0x1F8  TIMING_SHADOW_SEL   [0]  0 = write active set, 1 = write shadow set
  +0x1FC  TIMING_COMMIT       WO   write 1 -> swap shadow and active on the next
                                   quiescent boundary; self-clears when done
```

> A torn timing update is indistinguishable from a scheduler bug and is near-impossible to
> debug in silicon. Never write the active set while traffic runs — that is what the shadow
> set is for. DVFS depends on this (§4).

### 1.7 Lockable registers

`AMAP_LOCK` (`0x01F0`) locks: address map mode, all 13 hash masks, `ECC_EN`, `RFM_MODE`, and
the timing block. After locking, writes are dropped, `pslverr` asserts, and
`IRQ_STATUS.LOCKED_WRITE` sets.

**Lock before enabling traffic.** These are the registers whose corruption is silent.

---

## 2. Boot sequence

```c
void hbm4_boot(void) {
    /* 1. Identify and sanity-check the build against what the driver expects */
    assert(rd32(ID) == 0x48424D34);
    cap = rd32(CAP0);

    /* 2. Load the training script into each stack's sequencer RAM.
     *    The script is vendor- and stack-revision-specific; ship it with the driver. */
    for (s = 0; s < N_STACK; s++)
        load_script(s, phy_training_script, sizeof(phy_training_script));

    /* 3. Program DRAM timing from the datasheet, converted to core clocks.
     *    Write the ACTIVE set here - nothing is running yet. */
    for (s = 0; s < N_STACK; s++)
        program_timing(s, &datasheet_timings);

    /* 4. Program the address map and hash masks.
     *    CRITICAL: the same struct drives the fabric's HBM4_ADDR_SLICE cfg. */
    program_addr_map(&amap_cfg);
    fabric_program_slicers(&amap_cfg);      /* your fabric, same struct */

    /* 5. Refresh, RAS, scheduler policy */
    for (s = 0; s < N_STACK; s++) {
        program_refresh(s, &datasheet_timings);
        program_ras(s, .sysecc = 1, .scrub = 1, .rfm = DRFM);
        program_sched(s, &default_policy);
    }

    /* 6. LOCK.  After this, the silent-corruption registers are immutable. */
    wr32(AMAP_LOCK, 1);

    /* 7. Start.  All stacks train in parallel; all channels within a stack too. */
    wr32(BOOT_CTRL, BOOT_START);
    while (!(rd32(BOOT_STATUS) & CTRL_READY)) {
        if (rd32(BOOT_STATUS) & STACK_FAIL_MASK)
            return handle_training_failure(rd32(BOOT_STATUS));
        udelay(100);
    }
    /* ECC region init happens inside step 7 and is why this takes ~50 ms. */
}
```

**Expected boot time:** ~20 ms of training plus ~31 ms of ECC region initialisation
(`256 GB / 8.19 TB/s`). Budget 50 ms.

> ⚠️ **Do not skip ECC region init.** With `SYSECC_EN` on, reading a block whose ECC column
> was never written returns a random check field and reports a spurious uncorrectable error.
> `ECCINIT_MODE = LAZY` trades boot time for a bitmap lookup on the write path and a
> materially more complex failure surface. Use `FULL` unless boot time is a hard requirement.

---

## 3. Runtime tuning

Tuning is measurement-driven. The workflow is always: snapshot counters → compute → adjust
one knob → re-measure. Recipes are in
[07-performance-guide.md](07-performance-guide.md); here is the mechanism.

### 3.1 Reading counters coherently

```c
void snapshot(perf_t *out) {
    wr32(PERF_SNAPSHOT, 1);                 /* freezes all 256 PCs at once */
    for (s = 0; s < N_STACK; s++)
        for (pc = 0; pc < 64; pc++)
            read_pc_counters(s, pc, &out->pc[s][pc]);
    wr32(PERF_SNAPSHOT, 0);
}
```

Without the global freeze, per-PC counters are sampled at different times and cross-PC
imbalance — the thing you are usually hunting — is unmeasurable.

### 3.2 Counters worth watching

| Counter | Use |
|---|---|
| `COL_IDLE_WITH_PENDING` | **the master inefficiency metric.** Cycles where the column bus was idle but work was queued. Everything else explains this number. |
| `ROW_HIT` / `ROW_MISS` / `ROW_CONFLICT` | address-map health |
| `TURNAROUND_EVENTS`, `TURNAROUND_CYCLES` | is `WR_HI`/`WR_BURST_CREDIT` right? |
| `REFRESH_COUNT`, `REFRESH_URGENT` | urgent refreshes mean the opportunistic path is failing |
| `ECC_CACHE_MISS`, `ECC_RMW` | high RMW means partial writes are not coalescing |
| `LAT_ACC` / `LAT_COUNT` | mean latency |
| `QUEUE_OCC_HIST` | is `TQ_DEPTH` adequate? |

### 3.3 What is safe to change at runtime

| Safe with traffic running | Requires quiesce | Locked after boot |
|---|---|---|
| `WR_HI`, `WR_LO`, `WR_BURST_CREDIT` | `PAGE_POLICY` | address map mode |
| `WR_AGE_LIMIT`, `AGE_TICK` | `ACT_LOOKAHEAD` | all hash masks |
| `HOIST_MAX`, `WR_PREEMPT_EN` | `SCRUB_RATE` | `ECC_EN` |
| IRQ masks, thresholds | power thresholds | `RFM_MODE`, timing |

---

## 4. DVFS

```c
int hbm4_dvfs(int stack, const timing_t *new_timings, int new_freq) {
    wr32(ST(stack, TIMING_SHADOW_SEL), 1);        /* target the shadow set */
    program_timing_regs(stack, new_timings);
    wr32(ST(stack, TIMING_SHADOW_SEL), 0);

    request_self_refresh(stack);                   /* all 64 PCs must vote idle */
    if (!wait_self_refresh(stack, TIMEOUT)) return -EBUSY;

    phy_set_frequency(stack, new_freq);            /* vendor PHY call */
    run_retrain_script(stack);

    wr32(ST(stack, TIMING_COMMIT), 1);             /* atomic swap */
    exit_self_refresh(stack);
    return 0;
}
```

> With `STACK_ILV = FINE`, every stream touches every stack, so a single stack at a lower
> frequency throttles the whole system. Either change all stacks together, or use `NUMA`
> interleave and let software place work.

---

## 5. Error handling

### 5.1 Interrupt sources

| Bit | Source | Severity | Action |
|---|---|---|---|
| 0 | Link ECC corrected, threshold crossed | warn | schedule a link retrain |
| 1 | Link ECC uncorrectable after retries | **error** | log; data already returned as `rsp_err=2` |
| 2 | System ECC corrected, threshold crossed | warn | consider page retirement |
| 3 | System ECC uncorrectable | **error** | poison propagated; log the address |
| 4 | On-die ECC status changed | warn | a die is degrading |
| 5 | `ALERT_n` from DRAM | **error** | read the DRAM status registers |
| 6 | RAA overflow (row hammer) | **error** | `RFM_MODE` is misconfigured |
| 7 | `rsp_ready` stalled past `RSP_STALL_MAX` | warn | **your host is the bottleneck** |
| 8 | Write to a locked register | warn | driver bug — find it |
| 9 | Training or retrain failure | **fatal** | stack unusable |
| 10 | Scrub found an uncorrectable error | **error** | latent fault; retire the page |

### 5.2 Reading the error log

```c
void drain_error_log(int stack) {
    /* Read the sticky first-error latch FIRST - it survives a storm. */
    first = read_first_error(stack);
    log_event(&first);

    while (rd32(ST(stack, ERRLOG_STATUS)) & ERRLOG_VALID) {
        e = read_errlog_entry(stack);
        log_event(&e);
        wr32(ST(stack, ERRLOG_POP), 1);
    }
    wr32(ST(stack, ERRLOG_FIRST_CLR), 1);     /* only after you have recorded it */
}
```

The 16-entry FIFO will overflow during a real fault storm. The first-error latch is separate
and sticky precisely so the *first* event — the one that explains the rest — survives.

### 5.3 Poison

A poisoned block returns `rsp_err = 2` and raises **no new error event**. That is deliberate:
one fault yields one log entry, not thousands as the poisoned data is re-read. If you see
`rsp_err = 2` with no corresponding log entry, you are reading previously poisoned data, not
observing a new fault.

### 5.4 Repair

PPR and lane repair are **firmware-invoked, never autonomous** — repair resources are finite
and the policy belongs to software.

```c
int hbm4_repair_row(int stack, int pc, int bank, int row, bool hard) {
    quiesce_channel(stack, pc >> 1);
    r = run_script(stack, hard ? SCRIPT_HARD_PPR : SCRIPT_SOFT_PPR,
                   .pc = pc, .bank = bank, .row = row);
    if (r == 0) r = run_script(stack, SCRIPT_RETRAIN_CHANNEL, .ch = pc >> 1);
    resume_channel(stack, pc >> 1);
    return r;
}
```

Hard PPR is **irreversible** and the spare rows are few. Gate it behind a threshold policy
and record every use in non-volatile storage — otherwise a reboot loop can exhaust every
spare in the stack.

---

## 6. Driver checklist

- [ ] Driver and RTL versions checked against `ID` / `VERSION` / `CAP0` / `CAP1`
- [ ] Timing values derived from **the vendor datasheet**, not from the shipped placeholders
- [ ] Address map programmed into CSRs **and** fabric slicers from one source struct
- [ ] `AMAP_LOCK` written before traffic is enabled
- [ ] ECC region initialisation completed (or `LAZY` consciously chosen)
- [ ] IRQ handler covers all 11 sources in §5.1
- [ ] First-error latch read before draining the log
- [ ] Hard-PPR usage gated by policy and recorded persistently
- [ ] Performance counters read via the global snapshot, never individually

---

## Rev 1.0 — boot handshake

The driver's boot responsibilities changed when the training path was implemented (OPEN-10).

### Sequence

1. Release reset.
2. Program the address map, hash masks, `ECC_EN` and the timing set.
3. Set **`AMAP_LOCK`**. Post-lock writes to those registers are refused with `pslverr` and
   raise an interrupt — that is a driver bug, and it is reported rather than silently applied.
4. Assert `boot_start`.
5. Wait for `ctrl_ready`, checking `boot_failed`.
6. Only then issue traffic.

### What `ctrl_ready` now means

Before Rev 1.0 it meant "the sequencer reached the end of its script." It now means the device
has been through `PRECHARGE ALL`, mode-register programming, ZQ calibration and PHY training,
with every step acknowledged by the interface it was directed at.

`boot_failed` asserts if any stack failed. **A failed boot is terminal** — the watchdog fires
on a script that cannot make progress, and the correct response is a cold reset, not a retry.

### After any reset, go back to step 1

Not a recommendation. A reset clears the controller's model of the device but not the device
itself; the boot sequence is what re-synchronises them. The hardware enforces it — slices
cannot reach the DRAM until `boot_done` — so the practical consequence of skipping it is a
controller that never issues anything, rather than one that issues something wrong.
