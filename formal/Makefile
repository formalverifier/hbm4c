# ---------------------------------------------------------------------------
# Formal verification driver.
#
# The RTL is SystemVerilog with packages, packed structs and enums.  Yosys's
# built-in Verilog frontend does not accept user types inside packed structs,
# so we front-end through sv2v -- the fallback documented in
# docs/06-verification-plan.md 2.  yosys-slang is the preferred front end where
# it is available; set FRONTEND=slang to use it.
#
#   make            run every proof
#   make divc       one proof
#   make clean
# ---------------------------------------------------------------------------
SHELL     := /bin/bash
RTL       := ../rtl
BUILD     := build
SV2V      ?= sv2v
SBY       ?= sby

PKG       := $(RTL)/pkg/hbm4_pkg.sv $(RTL)/pkg/hbm4_timing_pkg.sv

# Reduced geometry for proofs (see docs/06-verification-plan.md 4.8 and
# SCALING.md).  Full-scale runs use FV_DEFINES= on the command line.
FV_DEFINES ?= -DFV_SMALL

PROOFS := divc wdataram addrmap timing bankst colarb rowarb pool wbuf refresh nhi rdfifo ecc ecccache errlog linkecc scrub eccinit csr pmgr initseq

.PHONY: all clean $(PROOFS)
all: $(PROOFS)

# ---- sv2v conversion -------------------------------------------------------
# -DFORMAL exposes the embedded assertions in the RTL itself.
$(BUILD)/%.v:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$@ $(SRCS)

# ---- individual proofs -----------------------------------------------------
divc: SRCS := $(PKG) $(RTL)/fe/hbm4_divc.sv fv_divc.sv
divc:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/divc.v $(SRCS)
	$(SBY) -f divc.sby

addrmap: SRCS := $(PKG) $(RTL)/fabric/hbm4_hash.sv $(RTL)/fabric/hbm4_addr_slice.sv \
                 $(RTL)/fe/hbm4_divc.sv $(RTL)/fe/hbm4_addr_decode.sv fv_addr_slice_miter.sv
addrmap:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/addrmap.v $(SRCS)
	$(SBY) -f addrmap.sby

timing: SRCS := $(PKG) $(RTL)/core/hbm4_timing_engine.sv fv_timing_engine.sv
timing:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/timing.v $(SRCS)
	$(SBY) -f timing.sby

colarb: SRCS := $(PKG) $(RTL)/core/hbm4_rr_arb.sv $(RTL)/core/hbm4_col_arb.sv fv_col_arb.sv
colarb:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/colarb.v $(SRCS)
	$(SBY) -f colarb.sby

pool: SRCS := $(PKG) $(RTL)/core/hbm4_txn_pool.sv fv_txn_pool.sv
pool:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/pool.v $(SRCS)
	$(SBY) -f pool.sby

wbuf: SRCS := $(PKG) $(RTL)/fe/hbm4_wbuf.sv fv_wbuf.sv
wbuf:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/wbuf.v $(SRCS)
	$(SBY) -f wbuf.sby

refresh: SRCS := $(PKG) $(RTL)/core/hbm4_refresh.sv fv_refresh.sv
refresh:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/refresh.v $(SRCS)
	$(SBY) -f refresh.sby

rowarb: SRCS := $(PKG) $(RTL)/core/hbm4_rr_arb.sv $(RTL)/core/hbm4_row_arb.sv fv_row_arb.sv
rowarb:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/rowarb.v $(SRCS)
	$(SBY) -f rowarb.sby

bankst: SRCS := $(PKG) $(RTL)/core/hbm4_bank_state.sv fv_bank_state.sv
bankst:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/bankst.v $(SRCS)
	$(SBY) -f bankst.sby

nhi: SRCS := $(PKG) $(RTL)/fe/hbm4_nhi_target.sv fv_nhi_target.sv
nhi:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/nhi.v $(SRCS)
	$(SBY) -f nhi.sby

rdfifo: SRCS := $(PKG) $(RTL)/dfi/hbm4_rd_ptr_fifo.sv fv_rd_ptr_fifo.sv
rdfifo:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/rdfifo.v $(SRCS)
	$(SBY) -f rdfifo.sby

ecc: SRCS := $(PKG) $(RTL)/ras/hbm4_sys_ecc.sv fv_sys_ecc.sv
ecc:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/ecc.v $(SRCS)
	$(SBY) -f ecc.sby

ecccache: SRCS := $(PKG) $(RTL)/ras/hbm4_ecc_cache.sv fv_ecc_cache.sv
ecccache:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/ecccache.v $(SRCS)
	$(SBY) -f ecccache.sby

errlog: SRCS := $(PKG) $(RTL)/ras/hbm4_err_log.sv fv_err_log.sv
errlog:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/errlog.v $(SRCS)
	$(SBY) -f errlog.sby

linkecc: SRCS := $(PKG) $(RTL)/ras/hbm4_sys_ecc.sv $(RTL)/ras/hbm4_link_ecc.sv fv_link_ecc.sv
linkecc:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/linkecc.v $(SRCS)
	$(SBY) -f linkecc.sby

scrub: SRCS := $(PKG) $(RTL)/ras/hbm4_scrub.sv fv_scrub.sv
scrub:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/scrub.v $(SRCS)
	$(SBY) -f scrub.sby

eccinit: SRCS := $(PKG) $(RTL)/ras/hbm4_ecc_init.sv fv_ecc_init.sv
eccinit:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/eccinit.v $(SRCS)
	$(SBY) -f eccinit.sby

csr: SRCS := $(PKG) $(RTL)/global/hbm4_csr.sv fv_csr.sv
csr:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/csr.v $(SRCS)
	$(SBY) -f csr.sby

pmgr: SRCS := $(PKG) $(RTL)/global/hbm4_pmgr.sv fv_pmgr.sv
pmgr:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/pmgr.v $(SRCS)
	$(SBY) -f pmgr.sby

wdataram: SRCS := $(PKG) $(RTL)/fe/hbm4_wdata_ram.sv fv_wdata_ram.sv
wdataram:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/wdataram.v $(SRCS)
	$(SBY) -f wdataram.sby

initseq: SRCS := $(PKG) $(RTL)/global/hbm4_init_seq.sv fv_init_seq.sv
initseq:
	@mkdir -p $(BUILD)
	$(SV2V) -E Assert -DFORMAL $(FV_DEFINES) --write=$(BUILD)/initseq.v $(SRCS)
	$(SBY) -f initseq.sby

clean:
	rm -rf $(BUILD) divc addrmap timing bankst colarb rowarb pool wbuf refresh nhi rdfifo ecc ecccache errlog linkecc scrub eccinit csr pmgr initseq

# ---------------------------------------------------------------------------
# stale -- refuse to trust a proof run against an out-of-date netlist.
#
# Every target above regenerates build/*.v with sv2v before calling sby, so
# `make` is always safe.  Running `sby -f <block>.sby` DIRECTLY is not: sby reads
# the build/*.v already on disk, so it happily proves the PREVIOUS revision of
# the RTL and reports PASS.  That is a false-assurance failure -- the proof is
# green and says nothing about the code you just wrote.
#
# It is easy to do by accident when iterating on one block.  This target makes it
# detectable instead of silent.
# ---------------------------------------------------------------------------
.PHONY: lock
# ---------------------------------------------------------------------------
# Two concurrent `make` runs in this directory regenerate build/*.v underneath
# each other: one proof reads a netlist another has half-written, and the result
# is meaningless in whichever direction the race happens to fall -- including
# green.  mutate.sh already takes this lock; the top-level targets now do too,
# because it is trivially easy to start a second regression while the first is
# still going and never notice.
#
# Usage: make guarded    (rather than bare `make`)
.PHONY: guarded
guarded:
	@mkdir .sby.lock 2>/dev/null || { echo "another run holds .sby.lock; wait or rmdir it"; exit 1; }
	@trap 'rmdir .sby.lock 2>/dev/null' EXIT INT TERM; $(MAKE) all

.PHONY: stale
stale:
	@stale=0; \
	for v in $(BUILD)/*.v; do \
	  [ -e "$$v" ] || continue; \
	  for s in $(RTL)/*/*.sv fv_*.sv; do \
	    if [ "$$s" -nt "$$v" ]; then \
	      echo "STALE: $$v is older than $$s"; stale=1; break; \
	    fi; \
	  done; \
	done; \
	if [ $$stale -eq 1 ]; then \
	  echo "-> a proof run against these netlists would prove the OLD rtl; run 'make'"; \
	  exit 1; \
	else echo "netlists are up to date"; fi
