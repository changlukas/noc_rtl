.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SCRIPTS := $(ROOT)/dv/scripts
PROFILE ?= $(ROOT)/dv/config/profile.yml
DIRECT_LINK ?= 0
TOPOLOGY_ARG = $(if $(TOPOLOGY),--topology "$(abspath $(TOPOLOGY))")
RECIPE := $(ROOT)/build/compile/recipes/$(notdir $(PROFILE))$(if $(filter 1,$(DIRECT_LINK)),.direct,).json
-include $(RECIPE:.json=.mk)
-include $(ROOT)/sim/environment.mk
CASE ?= ctrl_write_single
MODE ?= auto
TARGET ?= per_id
SEED ?= 1
JOBS ?= 1
WAVE ?= 1
PERF ?= 0
SCENARIO ?= unicast
TILE_RESULT := $(ROOT)/performance/unicast/tile-to-tile
MESH_RESULT := $(ROOT)/performance/unicast/mesh-traffic
CASE_DIR = $(subst _,-,$(patsubst perf_%,%,$(CASE)))
NEIGHBOR_SIZE = $(patsubst perf_neighbor_read_%,%,$(filter perf_neighbor_read_%,$(CASE)))
ifeq ($(SCENARIO),unicast)
ifeq ($(CASE),perf_ctrl_read_neighbor)
PERF_RESULT = $(TILE_RESULT)
else
PERF_RESULT = $(MESH_RESULT)/runs/$(or $(NEIGHBOR_SIZE),$(CASE_DIR))
endif
else
PERF_RESULT = $(ROOT)/performance/$(SCENARIO)/results/$(CASE_DIR)
endif
RESULTS ?= $(addprefix $(MESH_RESULT)/runs/,1kib 2kib 4kib 8kib 16kib 32kib bit-complement-1kib bit-complement-2kib bit-complement-4kib bit-complement-8kib bit-complement-16kib bit-complement-32kib transpose-1kib transpose-2kib transpose-4kib transpose-8kib transpose-16kib transpose-32kib uniform-1kib uniform-2kib uniform-4kib uniform-8kib uniform-16kib uniform-32kib shuffle-1kib shuffle-2kib shuffle-4kib shuffle-8kib shuffle-16kib shuffle-32kib)
override COVERAGE := 1
ifneq ($(filter run_wave view,$(MAKECMDGOALS)),)
override WAVE := 1
endif
BACKPRESSURE ?= 0
AW_WAIT_W ?= 0
READ_INTERLEAVE ?= 0
AXI_CLK_PERIOD_PS ?= 1000
NOC_CLK_PERIOD_PS ?= 1000
NOC_CLK_PHASE_PS ?= 0
RSP_DELAY ?= 2
SIM_TIMEOUT ?= 180
DIRECT_LINK ?= 0
RTL_ROUTER ?= 1
VCS ?= vcs
VCS_EXTRA ?=
VERDI_HOME ?= $(shell dirname $$(dirname $$(readlink -f $$(command -v verdi))))
PLI_DIR ?= $(VERDI_HOME)/share/PLI/VCS/linux64
export LD_LIBRARY_PATH := $(PLI_DIR)$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
export VCS_ARCH_OVERRIDE ?= linux
COVERAGE_METRICS := line+cond+fsm+tgl+branch+assert
SINGLE := $(ROOT)/build/regression/single$(if $(filter 1,$(DIRECT_LINK)),_direct,)
REPORT := $(SINGLE)/results/$(CASE)_$(MODE)_$(TARGET)_bp$(BACKPRESSURE)_aw$(AW_WAIT_W)_ri$(READ_INTERLEAVE)_s$(SEED)_c$(COVERAGE)_w$(WAVE)
WAVE_RC ?= $(ROOT)/dv/waves/signals.rc
REMOTE_ROOT ?= /home/mingwei/noc_rtl
WAVE_FLAGS := +define+DUMP_WAVE -P $(PLI_DIR)/novas.tab $(PLI_DIR)/pli.a
VCS_FLAGS := -ntb_opts uvm-1.2 -lca -pvalue+tb_top.AXI_CLK_PERIOD_PS=$(AXI_CLK_PERIOD_PS) -pvalue+tb_top.NOC_CLK_PERIOD_PS=$(NOC_CLK_PERIOD_PS) -pvalue+tb_top.NOC_CLK_PHASE_PS=$(NOC_CLK_PHASE_PS) -full64 -sverilog -assert svaext -override_timescale=1ps/1ps -debug_access+all -f files.f -top tb_top -pvalue+tb_top.RSP_DELAY_CYCLES=$(RSP_DELAY) -pvalue+tb_top.OUTPUT_REG_TYPE=$(REG_TYPE) -pvalue+tb_top.IO_FIFO_DEPTH=$(IO_FIFO_DEPTH) -pvalue+tb_top.INPUT_ID_WIDTH=$(INPUT_ID_WIDTH) -pvalue+tb_top.OUTPUT_ID_WIDTH=$(OUTPUT_ID_WIDTH) -pvalue+tb_top.MAX_OUTSTANDING_PER_ID=$(MAX_OUTSTANDING_PER_ID) -pvalue+tb_top.DEVICE_ID_WIDTH=$(DEVICE_ID_WIDTH) -pvalue+tb_top.CONTEXT_DEPTH=$(CONTEXT_DEPTH) -pvalue+tb_top.B_ROB_DEPTH=$(B_ROB_DEPTH) -pvalue+tb_top.R_ROB_DEPTH=$(R_ROB_DEPTH) -pvalue+tb_top.R_ROB_EN=$(R_ROB_EN)
VCS_FLAGS += $(VCS_EXTRA)
VCS_FLAGS += +define+NI_COVERAGE -cm $(COVERAGE_METRICS) -cm_hier coverage.hier
ifeq ($(DIRECT_LINK),1)
VCS_FLAGS += +define+TB_DIRECT_LINK
else ifneq ($(RTL_ROUTER),1)
$(error RTL router mesh is required when DIRECT_LINK is disabled)
endif
ifneq ($(filter _compile _sim _print,$(MAKECMDGOALS)),)
SIM := $(shell python3 -B "$(SCRIPTS)/build_key.py" --recipe "$(RECIPE)" --profile "$(abspath $(PROFILE))" $(TOPOLOGY_ARG) --flags="$(VCS) $(VCS_FLAGS) $(WAVE_FLAGS)" --coverage)
ifeq ($(strip $(SIM)),)
$(error Unable to select the prepared simulation build)
endif
endif
CAMPAIGN = $(shell python3 -c 'import json; print("$(ROOT)/"+json.load(open("$(ROOT)/build/regression/latest.json"))["campaign"])')
.PHONY: perf_multicast_plot perf_multicast_report perf_boundary_plot perf_cross_plot perf_interference_plot help perf perf_plot perf_latency_plot perf_tile_plot prepare sync compile run sim run_wave view regress verification report list clean print-build-dirs _compile _sim _view _verification _report
help:
	@echo "make gen_sam TOPOLOGY=<yaml>  Generate build/topology.sv for simulation"
	@printf '%s\n' 'make perf CASE=<case>         Measure an existing case; always save FSDB and a new permanent result' 'make prepare                  Generate inputs and a new coverage campaign' 'make run CASE=<case>           Compile and simulate' 'make run_wave view CASE=<case> Run with FSDB and open nWave' 'make verification JOBS=3       Run the prepared coverage matrix' 'make report                   Generate native URG coverage' 'make list                     List existing cases' 'make clean                    Remove new compile/regression outputs'
perf:
	@case "$(SCENARIO)" in unicast|interference|boundary|multicast) ;; *) echo "Invalid SCENARIO" >&2; exit 1;; esac
	@result="$(abspath $(or $(RESULT),$(PERF_RESULT)))"; \
	test ! -e "$$result" || { echo "Result already exists: $$result. Set RESULT to a new directory." >&2; exit 1; }; \
	$(MAKE) --no-print-directory -f "$(ROOT)/sim/Makefile" run PERF=1 WAVE=1 REPORT="$$result/runs/$(CASE)"
perf_multicast_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --multicast-plot "$(or $(RESULT),$(ROOT)/performance/multicast)"
perf_multicast_report: RESULTS = $(addprefix $(ROOT)/performance/multicast/results/, \
	row-seq-1kib-b1k row-tree-1kib row-hw-1kib \
	row-seq-2kib-b1k row-seq-2kib-b2k row-tree-2kib row-hw-2kib-retry \
	row-seq-4kib-b1k row-seq-4kib-b2k row-seq-4kib-b4k row-tree-4kib row-hw-4kib \
	row-seq-8kib-b1k row-seq-8kib-b2k row-seq-8kib-b4k row-seq-8kib-b8k row-tree-8kib row-hw-8kib \
	row-seq-16kib-b1k row-seq-16kib-b2k row-seq-16kib-b4k row-seq-16kib-b8k row-seq-16kib-b16k row-tree-16kib row-hw-16kib \
	row-seq-32kib-b1k row-seq-32kib-b2k row-seq-32kib-b4k row-seq-32kib-b8k row-seq-32kib-b16k row-seq-32kib-b32k row-tree-32kib row-hw-32kib)
perf_multicast_report:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" python3 -B "$(SCRIPTS)/performance.py" --multicast-results $(foreach directory,$(RESULTS),"$(directory)") --output "$(ROOT)/performance/multicast"
perf_tile_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --tile-to-tile "$(or $(RESULT),$(TILE_RESULT))"
perf_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --results $(foreach directory,$(RESULTS),"$(directory)") --output "$(or $(RESULT),$(MESH_RESULT))"
CROSS_RESULT ?= $(ROOT)/performance/interference/results/cross
perf_cross_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --cross-results $(foreach directory,$(patsubst %/validation.json,%,$(wildcard $(CROSS_RESULT)/*/validation.json)),"$(directory)") --output "$(ROOT)/performance/interference"
BOUNDARY_RESULT ?= $(ROOT)/performance/boundary
perf_boundary_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --boundary-results $(foreach directory,$(patsubst %/validation.json,%,$(wildcard $(BOUNDARY_RESULT)/results/read-*/validation.json $(BOUNDARY_RESULT)/results/narrow-*/validation.json)),"$(directory)") --output "$(BOUNDARY_RESULT)"
INTERFERENCE_RESULT ?= $(ROOT)/performance/interference/results/separate
perf_interference_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --interference-results $(foreach directory,$(patsubst %/validation.json,%,$(wildcard $(INTERFERENCE_RESULT)/*/validation.json)),"$(directory)") --output "$(INTERFERENCE_RESULT)"
perf_latency_plot: RESULTS = $(foreach pattern,neighbor bit-complement transpose uniform shuffle,$(addprefix $(MESH_RESULT)/runs/$(pattern)-,zero 0p001 0p01 0p05 0p1 0p15 0p2 0p25 0p3 0p4 0p5))
perf_latency_plot:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" MPLCONFIGDIR="$(ROOT)/build/perf_plot_deps/cache" python3 -B "$(SCRIPTS)/performance.py" --latency-results $(foreach directory,$(RESULTS),"$(directory)") --output "$(or $(RESULT),$(MESH_RESULT))"
.PHONY: gen_sam
gen_sam:
	PYTHONPATH="$(ROOT)/build/perf_plot_deps/site-packages$${PYTHONPATH:+:$$PYTHONPATH}" python3 -B "$(SCRIPTS)/prepare.py" --emit-sam "$(ROOT)/build/topology.sv" $(TOPOLOGY_ARG) $(if $(filter 1,$(DIRECT_LINK)),--direct,)

.PHONY: prepare-single
prepare-single:
	python3 -B "$(SCRIPTS)/prepare.py" --out "$(SINGLE)" $(TOPOLOGY_ARG) --profile "$(PROFILE)" $(if $(filter 1,$(DIRECT_LINK)),--direct,) $(if $(filter multicast,$(SCENARIO)),--extra-catalog performance_multicast,)
prepare: prepare-single
	$(if $(filter 1,$(DIRECT_LINK)),@true,python3 -B "$(SCRIPTS)/prepare_ni_verification.py" --out "$(ROOT)/build/regression/$$(date -u +%Y%m%dT%H%M%S_%N)" --profile "$(PROFILE)" $(TOPOLOGY_ARG))
sync:
	python3 -B "$(SCRIPTS)/sync_nmu_workstation.py" --source "$(ROOT)" --remote-dir "$(REMOTE_ROOT)"
compile run sim run_wave view verification report print-build-dirs:
	@test "$@" = report || test -s "$(RECIPE)" || { echo 'Run make prepare on the development machine, then synchronize first' >&2; exit 1; }
	$(MAKE) --no-print-directory -f "$(ROOT)/sim/Makefile" $(if $(filter compile,$@),_compile,$(if $(filter run run_wave,$@),_compile _sim,$(if $(filter sim,$@),_sim,$(if $(filter view,$@),_view,$(if $(filter verification,$@),_compile _verification,$(if $(filter report,$@),_report,_print)))))) WAVE=$(WAVE) COVERAGE=$(COVERAGE)
_compile:
	@test -n "$(SIM)" || exit 1
	@if ! python3 -B "$(SCRIPTS)/build_key.py" --valid "$(SIM)"; then cd "$(SIM)" && { printf '%s\n' '$(VCS) $(VCS_FLAGS) $(WAVE_FLAGS) -Mdir=$(SIM)/csrc -o $(SIM)/simv' > compile-command.txt; $(VCS) $(VCS_FLAGS) $(WAVE_FLAGS) -Mdir="$(SIM)/csrc" -o "$(SIM)/simv" -l compile.log && python3 -B "$(SCRIPTS)/build_key.py" --complete "$(SIM)"; }; fi
	@python3 -B "$(SCRIPTS)/build_key.py" --complete "$(SIM)"
_sim:
	python3 -B "$(SCRIPTS)/run.py" --binary "$(SIM)/simv" --inputs "$(SINGLE)/inputs" --campaign "$(SINGLE)" --case "$(CASE)" --mode "$(MODE)" --target "$(TARGET)" --seed "$(SEED)" --timeout-seconds "$(SIM_TIMEOUT)" $(if $(filter 1,$(BACKPRESSURE)),--backpressure,) --report "$(REPORT)" $(if $(filter 1,$(AW_WAIT_W)),--aw-wait-w,) $(if $(filter 1,$(READ_INTERLEAVE)),--read-interleave,) $(if $(filter 1,$(WAVE)),--wave,) $(if $(filter 1,$(PERF)),--perf --scenario "$(SCENARIO)",) $(if $(filter 1,$(COVERAGE)),--coverage,)
ifeq ($(WAVE),1)
	@sed 's|@FSDB@|$(REPORT)/$(CASE).fsdb|g' "$(WAVE_RC)" > "$(REPORT)/$(CASE).rc"
endif
_view:
	@test -s "$(REPORT)/$(CASE).fsdb" || { echo 'Run make run_wave CASE=$(CASE) first' >&2; exit 1; }
	@sed 's|@FSDB@|$(REPORT)/$(CASE).fsdb|g' "$(WAVE_RC)" > "$(REPORT)/$(CASE).rc"
	@nohup "$(VERDI_HOME)/bin/nWave" -ssf "$(REPORT)/$(CASE).fsdb" -sswr "$(REPORT)/$(CASE).rc" > "$(REPORT)/verdi.log" 2>&1 < /dev/null &
_verification:
	python3 -B "$(SCRIPTS)/run_verification.py" --binary "$(SIM)/simv" --campaign "$(CAMPAIGN)" --jobs $(JOBS)
_report:
	@test -s "$(CAMPAIGN)/coverage-tests.txt" || { echo 'Run make verification first' >&2; exit 1; }
	urg -full64 -dir "$$(python3 -B "$(SCRIPTS)/build_key.py" --campaign "$(CAMPAIGN)")" -tests "$(CAMPAIGN)/coverage-tests.txt" -report "$(CAMPAIGN)/coverage" -format both -show tests
_print:
	@test "$$(readlink -f "$(ROOT)/build/compile/current")" = "$(SIM)" && python3 -B "$(SCRIPTS)/build_key.py" --valid "$(SIM)" || { echo "Run make compile to select the current source/configuration" >&2; exit 1; }
	@echo $(ROOT)/build/compile/current
regress: verification
list:
	@cat "$(ROOT)/dv/config/pattern_list.txt"
clean:
	python3 -B "$(SCRIPTS)/clean.py"
