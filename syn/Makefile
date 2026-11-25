YOSYS ?= yosys
SV2V  ?= sv2v
RTL   := ../rtl
SRCS  := $(RTL)/pkg/hbm4_pkg.sv $(RTL)/pkg/hbm4_timing_pkg.sv \
         $(wildcard $(RTL)/fabric/*.sv) $(wildcard $(RTL)/fe/*.sv) \
         $(wildcard $(RTL)/core/*.sv) $(wildcard $(RTL)/dfi/*.sv) \
         $(wildcard $(RTL)/ras/*.sv) $(wildcard $(RTL)/global/*.sv) \
         $(RTL)/slice/hbm4_pc_slice.sv

.PHONY: all check clean
all: build/slice.v
	@mkdir -p rpt
	$(YOSYS) -q synth.ys
	@echo "--- logic depth ---"; grep "Longest topological path" rpt/ltp.txt | head -1
	@echo "--- loops (must be 0) ---"; grep -c "Detected loop" synth.log || true

check: build/slice.v
	$(YOSYS) -q check.ys && echo "no combinational loops"

build/slice.v: $(SRCS)
	@mkdir -p build rpt
	$(SV2V) -DSYNTHESIS --write=$@ $(SRCS)

clean:
	rm -rf build rpt *.log
