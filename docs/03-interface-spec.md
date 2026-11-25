# 03 — Interface Specification

**HBM4 Memory Controller · Rev 1.3**

Signal-level definition of every controller boundary, with timing diagrams. This is the
document to hand to whoever writes the fabric adapter, the PHY glue, or the driver.

Three interfaces:

| Interface | Direction | Clock | Count |
|---|---|---|---|
| **NHI** — Native Host Interface | host ↔ controller | `clk_core` (1 GHz) | 256 (one per pseudo-channel) |
| **DFI** — DDR PHY Interface | controller ↔ PHY | `clk_core` = `dfi_clk` | 128 (one per HBM channel) |
| **APB4** — configuration | host ↔ controller | `clk_cfg` | 1 |

Every timing diagram below has an editable WaveDrom source in [`waves/`](waves/). Paste the
`.json` into wavedrom.com or open it with the WaveDrom VS Code extension.

---

## 1. NHI — Native Host Interface

### 1.1 Design intent

A tagged, credit-metered, out-of-order request/response interface at exactly the DRAM access
granularity (32 B). Deliberately minimal: no burst descriptors, no ID-ordering matrix, no
exclusive access, no protocol FSM, and **no `ready` on the request channel**.

One port per pseudo-channel. Port *i* is hardwired to pseudo-channel *i*. There is no routing
inside the controller — [`HBM4_ADDR_SLICE`](#4-hbm4_addr_slice) in your fabric decides which
port a request goes to.

### 1.2 Request channel — host → controller

| Signal | Dir | Width | Description |
|---|---|---|---|
| `req_valid` | in | 1 | Request present. May be asserted only while the host holds ≥1 credit. |
| `req_wr` | in | 1 | 0 = read, 1 = write |
| `req_blk` | in | 25 | PC-local **block** address, 32 B units. Direct output of `HBM4_ADDR_SLICE`. |
| `req_tag` | in | 8 | Host-chosen. Echoed on the response. Must be unique among the host's outstanding **reads** on this port. |
| `req_be` | in | 32 | Write byte enables, one per byte. All-ones is the fast path. Ignored for reads. |
| `req_qos` | in | 2 | 0 = bulk, 1 = normal, 2 = high, 3 = urgent |
| `req_poison` | in | 1 | Write carries known-bad data; store poison. Requires `SYSECC_EN`. |
| `req_last` | in | 1 | Advisory: end of a contiguous stream. Permits early page close. Never affects correctness. |
| `req_credit` | **out** | 1 | One-cycle pulse. Returns one credit. |

### 1.3 Write-data channel — host → controller

Separate from the request channel so a host can pipeline addresses ahead of data.

| Signal | Dir | Width | Description |
|---|---|---|---|
| `wd_valid` | in | 1 | |
| `wd_ready` | out | 1 | |
| `wd_data` | in | 256 | One 32 B access, one beat |

**Association rule:** write-data beats pair with write **requests in order**. The *n*-th
`wd_valid & wd_ready` beat belongs to the *n*-th `req_valid & req_wr` request. There is no
tag on `wd`. Data may lag or lead its request by up to `WD_SKEW` beats (default 8).

### 1.4 Response channel — controller → host

| Signal | Dir | Width | Description |
|---|---|---|---|
| `rsp_valid` | out | 1 | |
| `rsp_ready` | in | 1 | See the stall rule in §1.6 |
| `rsp_tag` | out | 8 | Echo of `req_tag` |
| `rsp_data` | out | 256 | Read data. Undefined when `rsp_wack` is set. |
| `rsp_err` | out | 2 | 0 = ok, 1 = corrected, 2 = uncorrectable/poison, 3 = access fault |
| `rsp_wack` | out | 1 | This beat is a write completion, not read data |

### 1.5 Timing

**Basic read.** `req_tag` is echoed verbatim, so the host never tracks ordering.

![NHI read](waves/wave-01-nhi-read.svg)

**Out-of-order return.** Tags 07, 08, 09 issue in that order; 08 hit an open row and returns
first. Key on the tag, never on arrival order.

![NHI out of order](waves/wave-02-nhi-out-of-order.svg)

**Write with data skew.** Requests at cycles 1–2, data at cycles 3–4, `wack` later.

![NHI write](waves/wave-03-nhi-write.svg)

**Credit flow control.** A credit *is* the permission to send; there is no request-channel
handshake.

![NHI credits](waves/wave-04-nhi-credit.svg)

### 1.6 Rules the host must obey

| # | Rule | Consequence of breaking it |
|---|---|---|
| H1 | Assert `req_valid` only while holding ≥1 credit | Transaction pool overflow — dropped request, no error signalled |
| H2 | `req_tag` unique among outstanding **reads** on this port | Two responses collide; data delivered to the wrong consumer |
| H3 | Supply write data within `WD_SKEW` beats of the request | Write-data FIFO underflow, port stalls |
| H4 | Do not hold `rsp_ready` low longer than `RSP_STALL_MAX` | Back-pressure reaches the DRAM bus; IRQ raised |
| H5 | Never re-order write data beats relative to write requests | Data written to the wrong address — **silent corruption** |

H2 and H5 are the dangerous ones: neither is detectable by the controller, and both corrupt
data silently. The verification kit ships NHI protocol assertions
([06-verification-plan.md §4.7](06-verification-plan.md)) — bind them to your fabric adapter
and leave them enabled in simulation.

### 1.7 Ordering contract

**Guaranteed:**

- **G1** A read following a write to the same 32 B block, on the same port, returns the new
  data (enforced by the write-buffer hazard check).
- **G2** Writes to the same block on the same port complete in order.
- **G3** `rsp_wack` is issued only once the write is visible to subsequent reads.

**Not guaranteed:**

- Response ordering, in general.
- **Any ordering between different ports.** Different pseudo-channels are entirely
  independent memories. If your consistency model needs cross-port ordering, the fabric must
  fence: wait for all outstanding `wack`s before issuing the dependent read.

> ⚠️ This bites people. Two accesses that look adjacent in system address usually land on
> *different* pseudo-channels (§7.2 of [02-architecture.md](02-architecture.md) — a +32 B
> stride changes the stack). There is no ordering between them.

---

## 2. DFI — PHY interface

DFI 6.x-style, frequency ratio **1:2** (`dfi_clk` = `clk_core` = CK/2). One instance per HBM
channel; two pseudo-channel slices share one instance and use the per-pseudo-channel command
and data sub-buses.

### 2.1 Per pseudo-channel, per core clock

| Group | Width | Notes |
|---|---|---|
| `dfi_row_cmd` | 2 × `ROW_CMD_W` | 2 CK phases. ACT / PRE / REF / RFM. |
| `dfi_col_cmd` | 2 × `COL_CMD_W` | 2 CK phases, but **≤1 valid per core clock** (C1) |
| `dfi_wrdata` | 256 | One BL8 burst = one core clock |
| `dfi_wrdata_mask` | 32 | DM / byte enables |
| `dfi_rddata` | 256 | |
| `dfi_rddata_valid` | 1 | |
| `dfi_lecc_*` | per-direction sideband | Link ECC (§10.1 of the architecture doc) |

### 2.2 Steady state — the three constraints on one screen

![DFI steady state](waves/wave-05-dfi-steady-state.svg)

- **C1** exactly one column command per clock — the column port is one wide and saturated.
- **C2** the bank group changes every clock (colours) — `tCCD_S`, not `tCCD_L`.
- **C3** the row bus issues ACTs in parallel, for free.

### 2.3 The bank-group penalty

What C2 costs when you get the address map wrong:

![Bank group penalty](waves/wave-06-bank-group-penalty.svg)

### 2.4 Read/write turnaround

![Turnaround](waves/wave-07-read-write-turnaround.svg)

### 2.5 Per-bank refresh

REFsb on the row bus; the column bus never notices.

![Per-bank refresh](waves/wave-10-per-bank-refresh.svg)

### 2.6 Phase selection

Only one column command may issue per core clock, but it may sit on CK phase 0 or 1. The
adapter tracks the last issued phase and places the next command on whichever phase exactly
satisfies `tCCD_S`. Without this, a half-cycle of drift accumulates and eventually costs a
whole issue slot.

### 2.7 Read-data return

The adapter keeps a **read-pointer FIFO** per pseudo-channel: push the transaction-pool index
at column-command issue, pop on `dfi_rddata_valid`. This decouples the controller from the
exact PHY latency — only `RD_FIFO_DEPTH` (default 32) must exceed the maximum round trip. The
real value is measured during training (boot step 10) and written to a CSR.

> **Integration note.** If your PHY's `dfi_rddata_valid` latency is not deterministic within a
> known bound, tell us. The FIFO handles jitter; it does not handle unbounded latency.

### 2.8 Mode-register access

MRS travels on the column bus. The stack sequencer serialises it against traffic with a
per-PC `mrs_request` handshake: quiesce the PC, issue, resume. Used for init programming,
temperature polling, on-die ECC status, PPR, and lane repair.

---

## 3. APB4 — configuration

Standard APB4 on `clk_cfg`, 32-bit data, 16-bit address within each window.

![APB CSR](waves/wave-11-apb-csr.svg)

| Signal | Dir | Width |
|---|---|---|
| `pclk`, `presetn` | in | 1, 1 |
| `psel`, `penable`, `pwrite` | in | 1 each |
| `paddr` | in | 32 |
| `pwdata`, `prdata` | in / out | 32 / 32 |
| `pready`, `pslverr` | out | 1, 1 |

`pslverr` is asserted for: an unmapped address, a write to a `LOCK`ed register, or a CSR
access to a stack that is not out of reset. See
[04-programming-guide.md](04-programming-guide.md) for the register map.

---

## 4. `HBM4_ADDR_SLICE`

Shipped as `rtl/fabric/hbm4_addr_slice.sv`. **You instantiate this in your fabric**, once per
requester port.

```systemverilog
module hbm4_addr_slice #(
  parameter int N_STACK = 4
) (
  input  logic [37:0] sys_addr,     // byte address, 0 .. 240 GB usable
  input  hbm4_slice_cfg_t cfg,      // mirror of the CSR hash image
  output logic [ 1:0] stack_id,
  output logic [ 5:0] pc_id,
  output logic [24:0] pc_blk        // -> req_blk on NHI port {stack_id, pc_id}
);
```

Purely combinational: bit-select plus XOR reduction, ~200 gates, zero latency. No arithmetic
and no divide — the divide-by-30 that inline ECC needs lives inside the controller.

**The contract.** `cfg` must be the same hash image programmed into the controller's CSRs. If
the two disagree, requests are decoded to different DRAM locations by the fabric and by the
controller, and **memory is corrupted with no error indication anywhere**. This is the
highest-consequence, lowest-visibility failure mode in the system, which is why:

- the hash is one shared RTL source (`rtl/fabric/hbm4_hash.sv`), instantiated by both paths;
- a formal miter proves the two decode paths agree for every input under every legal `cfg`
  ([06-verification-plan.md](06-verification-plan.md), P-MAP-3);
- the hash CSRs are **lockable**, and the driver locks them before enabling traffic.

---

## 5. Parameter summary

Parameters that change the interfaces:

| Parameter | Default | Effect on interfaces |
|---|---|---|
| `N_STACK` | 4 | `stack_id` width; number of NHI ports = `N_STACK × 64` |
| `TQ_DEPTH` | 64 | initial credit count on every NHI port |
| `WD_SKEW` | 8 | how far write data may lag its request |
| `SYSECC_EN` | 1 | usable capacity 15/16; enables `req_poison` |
| `RSP_STALL_MAX` | 256 | when a stalled `rsp_ready` raises an IRQ |
| `RD_FIFO_DEPTH` | 32 | maximum tolerable PHY read round trip |

Full parameter list: [05-integration-guide.md](05-integration-guide.md).
