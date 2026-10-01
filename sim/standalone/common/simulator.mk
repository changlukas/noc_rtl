# One source/config/pattern snapshot; only simulator and waveform backends differ.
.DEFAULT_GOAL := run
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
script_dir := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
package_dir := $(abspath $(script_dir)/..)
include $(script_dir)/config.mk
ifneq ($(filter run_wave view,$(MAKECMDGOALS)),)
override WAVE := 1
endif
SIMULATOR ?= vcs
CASE ?= ctrl_write_single
MODE ?= auto
SEED ?= 1
PYTHON ?= python3
VCS ?= vcs
VERILATOR ?= verilator
NWAVE ?= nWave
WAVE_RC ?= $(script_dir)/nWaveLog/signals.rc
VERDI_HOME ?= /cadtools/synopsys/verdi/M-2017.03-SP1
PLI_DIR ?= $(VERDI_HOME)/share/PLI/VCS/linux64
# Keep the caller environment intact; extend only child-process library lookup.
export LD_LIBRARY_PATH := $(PLI_DIR)$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
export VCS_ARCH_OVERRIDE ?= linux
VCS_EXTRA ?=
VERILATOR_EXTRA ?=
SIM_EXTRA ?=
top := tb_nmu_standalone
run_dir ?= $(package_dir)/build/$(SIMULATOR)_i$(ID_WIDTH)_n$(NOC_HALF_PERIOD)_b$(BUFFER_DEPTH)_r$(R_ROB_EN)_wave$(WAVE)
run_dir := $(abspath $(run_dir))
# Generated compilation files must use the workstation's local clock, not NFS mtime.
vcs_cache_root := /tmp/noc-vcs-$(shell id -u)-$(shell cd "$(package_dir)" && pwd -P | tr -d '\n' | cksum | cut -d' ' -f1)
vcs_work_dir := $(vcs_cache_root)/i$(ID_WIDTH)_n$(NOC_HALF_PERIOD)_b$(BUFFER_DEPTH)_r$(R_ROB_EN)_wave$(WAVE)
report_dir := $(run_dir)/report
wave_dir := $(run_dir)/waves
filelist := $(package_dir)/files.f
wave_ext := fsdb
ifeq ($(SIMULATOR),verilator)
wave_ext := fst
endif
case_label := $(if $(CASE),$(CASE)_$(MODE)_s$(SEED),$(PATTERN))
wave_file ?= $(wave_dir)/$(case_label).$(wave_ext)

VCS_FLAGS := -full64 -sverilog -assert svaext -override_timescale=1ns/1ps -debug_access+all \
    +lint=TFIPC-L +lint=PCWM -Mdir=$(vcs_work_dir)/csrc -f $(filelist) -top $(top) \
    -pvalue+$(top).ID_WIDTH=$(ID_WIDTH) \
    -pvalue+$(top).NOC_HALF_PERIOD=$(NOC_HALF_PERIOD) \
    -pvalue+$(top).BUFFER_DEPTH=$(BUFFER_DEPTH) \
    -pvalue+$(top).R_ROB_EN=$(R_ROB_EN) -o $(vcs_work_dir)/simv
VERILATOR_FLAGS := --binary --timing --assert -j 1 -Wno-fatal \
    -Werror-WIDTHEXPAND -Werror-WIDTHTRUNC -Werror-LATCH \
    $(package_dir)/repo/rtl/nmu/top/nmu_lint.vlt \
    --top-module $(top) -f $(filelist) --Mdir $(run_dir)/csrc -o $(run_dir)/simv \
    -GID_WIDTH=$(ID_WIDTH) -GNOC_HALF_PERIOD=$(NOC_HALF_PERIOD) \
    -GBUFFER_DEPTH=$(BUFFER_DEPTH) -GR_ROB_EN=$(R_ROB_EN)
ifeq ($(WAVE),1)
VCS_FLAGS += +define+DUMP_WAVE -P $(PLI_DIR)/novas.tab $(PLI_DIR)/pli.a
VERILATOR_FLAGS += +define+DUMP_WAVE --trace-fst
endif

.PHONY: help sanity_check compile run sim regress block_regress legacy_regress run_wave view fault report clean list
help:
	@printf '%s\n' \
	 'make run CASE=<case>        Compile and simulate' \
	 'make run_wave CASE=<case>   Compile and simulate with waveform' \
	 'make view CASE=<case>       Open existing waveform and signal groups' \
	 'make clean                 Remove simulation and GUI output' \
	 'make list                  List the 15 test cases'

list:
	@cat "$(package_dir)/pattern_list.txt"

case_list := $(firstword $(wildcard $(package_dir)/cases.list $(package_dir)/cases/standalone/cases.list))

sanity_check:
	@if [[ -n "$(CASE)" ]]; then grep -Fxq "$(CASE)" "$(package_dir)/cases/standalone/cases.list" || { echo "Unknown CASE" >&2; exit 1; }; fi
	@test -f "$(filelist)" || { echo 'Use the synchronized simulation directory (files.f missing)' >&2; exit 1; }
	@case "$(SIMULATOR)" in vcs|verilator) ;; *) echo 'SIMULATOR must be vcs or verilator' >&2; exit 1;; esac
	@case "$(PATTERN)" in neighbor|uniform_random|hotspot|directed) ;; *) echo 'Invalid PATTERN' >&2; exit 1;; esac
	@case "$(WAVE)" in 0|1) ;; *) echo 'WAVE must be 0 or 1' >&2; exit 1;; esac
	@mkdir -p "$(report_dir)" "$(wave_dir)"

compile: sanity_check
	@printf '%s\n' 'SIMULATOR=$(SIMULATOR)' 'WAVE=$(WAVE)' 'ID_WIDTH=$(ID_WIDTH)' \
	 'NOC_HALF_PERIOD=$(NOC_HALF_PERIOD)' 'BUFFER_DEPTH=$(BUFFER_DEPTH)' \
	 'R_ROB_EN=$(R_ROB_EN)' 'VCS_FLAGS=$(VCS_FLAGS)' \
	 'VERILATOR_FLAGS=$(VERILATOR_FLAGS)' 'VCS_EXTRA=$(VCS_EXTRA)' \
	 'VERILATOR_EXTRA=$(VERILATOR_EXTRA)' > "$(report_dir)/build-config.txt"
	@cp "$(package_dir)/SHA256SUMS" "$(report_dir)/source-SHA256SUMS"
ifeq ($(SIMULATOR),vcs)
	@command -v "$(VCS)" >/dev/null || { echo 'Initialize the workstation VCS environment first' >&2; exit 1; }
ifeq ($(WAVE),1)
	@test -r "$(PLI_DIR)/novas.tab" -a -r "$(PLI_DIR)/pli.a" || { echo 'Set VERDI_HOME or PLI_DIR to the installed Verdi PLI directory' >&2; exit 1; }
endif
	@mkdir -m 700 "$(vcs_cache_root)" 2>/dev/null || \
	  [[ -d "$(vcs_cache_root)" && ! -L "$(vcs_cache_root)" && -O "$(vcs_cache_root)" ]]
	@test ! -L "$(vcs_work_dir)"
	@mkdir -p "$(vcs_work_dir)"
	cd "$(package_dir)" && $(VCS) $(VCS_FLAGS) $(VCS_EXTRA) -l "$(report_dir)/compile.log"
	@cp "$(vcs_work_dir)/simv" "$(run_dir)/simv"
	@mkdir -p "$(run_dir)/simv.daidir"
	@cp -a "$(vcs_work_dir)/simv.daidir/." "$(run_dir)/simv.daidir/"
else
	cd "$(package_dir)" && $(VERILATOR) $(VERILATOR_FLAGS) $(VERILATOR_EXTRA) 2>&1 | tee "$(report_dir)/compile.log"
endif

run: compile sim

sim: sanity_check
	@test -x "$(run_dir)/simv" || { echo 'No binary for this configuration. Run: make run CASE=$(CASE)'  >&2; exit 1; }
	@args=(); stim="$(package_dir)/cases/$(PATTERN)"; if [[ -n "$(CASE)" ]]; then \
	  stim="$(run_dir)/patterns/$(MODE)_s$(SEED)/$(CASE)"; \
	  $(PYTHON) "$(package_dir)/repo/sim/tools/gen_standalone_patterns.py" \
	    --out "$$(dirname "$$stim")" --topology "$(package_dir)/cases/topology.json" \
	    --catalog "$(package_dir)/repo/sim/test_patterns/standalone/cases.json" \
	    --id-width $(ID_WIDTH) --case "$(CASE)" --mode "$(MODE)" --seed "$(SEED)"; mapfile -t args < "$$stim/schedule.txt"; \
	elif [[ "$(PATTERN)" == directed ]]; then \
	  args+=(+require_reorder); \
	  if [[ $(BUFFER_DEPTH) == 8 && $(R_ROB_EN) == 1 ]]; then args+=(+require_pressure); fi; \
	fi; cd "$(package_dir)"; "$(run_dir)/simv" \
	  +stim_dir="$$stim" +run_dir="$(run_dir)" \
	  +wave_file="$(wave_file)" "$${args[@]}" $(SIM_EXTRA) \
	  2>&1 | tee "$(report_dir)/$(case_label).log"
	@grep -q 'PASS NMU standalone' "$(report_dir)/$(case_label).log"
	@echo 'PASS: $(case_label)'

regress: compile
	@while read -r name; do $(MAKE) --no-print-directory -f "$(script_dir)/Makefile" sim CASE=$$name; done < "$(case_list)"

block_regress: compile
	@while read -r name; do \
	  case "$$name" in ctrl_*|data_*|request_rand) modes=auto ;; *) modes="control data rand" ;; esac; \
	  for mode in $$modes; do $(MAKE) --no-print-directory -f "$(script_dir)/Makefile" sim CASE=$$name MODE=$$mode run_dir="$(run_dir)"; done; \
	done < "$(package_dir)/cases/standalone/cases.list"
	@$(MAKE) --no-print-directory -f "$(script_dir)/Makefile" fault run_dir="$(run_dir)"

legacy_regress: compile
	@for pattern in $(patterns); do \
	  $(MAKE) --no-print-directory -f "$(script_dir)/Makefile" sim CASE= PATTERN=$$pattern run_dir="$(run_dir)"; \
	done
	@$(MAKE) --no-print-directory -f "$(script_dir)/Makefile" fault run_dir="$(run_dir)"
	@$(MAKE) --no-print-directory -f "$(script_dir)/Makefile" report run_dir="$(run_dir)"

# Some simulators return zero after $fatal; require the expected checker diagnostic.
fault: sanity_check
	@test -x "$(run_dir)/simv"
	@cd "$(package_dir)"; "$(run_dir)/simv" \
	  +stim_dir="$(package_dir)/cases/directed" +corrupt_rsp \
	  +wave_file="$(wave_dir)/corrupt.$(wave_ext)" 2>&1 | tee "$(report_dir)/corrupt.log" || :
	@grep -q 'R data/lane/order/last mismatch' "$(report_dir)/corrupt.log"
	@echo 'PASS: expected corruption was detected'
	@args=(); mapfile -t args < "$(package_dir)/cases/standalone/data_read_burst/schedule.txt"; \
	  cd "$(package_dir)"; "$(run_dir)/simv" "$${args[@]}" \
	  +stim_dir="$(package_dir)/cases/standalone/data_read_burst" +corrupt_rsp \
	  +wave_file="$(wave_dir)/corrupt_dat.$(wave_ext)" 2>&1 | tee "$(report_dir)/corrupt_dat.log" || :
	@grep -q 'R data/lane/order/last mismatch' "$(report_dir)/corrupt_dat.log"
	@echo 'PASS: expected DAT corruption was detected'


run_wave: run

view:
	@test -f "$(wave_file)" || { echo 'Run make run_wave first' >&2; exit 1; }
	@test -f "$(WAVE_RC)" || { echo 'Waveform RC template missing: $(WAVE_RC)' >&2; exit 1; }
	@sed 's|@FSDB@|$(wave_file)|g' "$(WAVE_RC)" > "$(run_dir)/$(case_label).rc"
	@cd "$(script_dir)" && $(NWAVE) -ssf "$(wave_file)" -sswr "$(run_dir)/$(case_label).rc" &

report:
	@test -d "$(report_dir)" || { echo 'No report directory yet' >&2; exit 1; }
	tar -czf "$(package_dir)/nmu-$(SIMULATOR)-results.tar.gz" -C "$(run_dir)" report
	@echo 'Reports: $(package_dir)/nmu-$(SIMULATOR)-results.tar.gz'

clean:
	@bash "$(script_dir)/clean.sh"

.PHONY: dat_regress
dat_regress:
	NMU_DAT_STAGE="$(package_dir)" NMU_DAT_TEST_OUTPUT="$(package_dir)/build/dat_$(SIMULATOR)_wave$(WAVE)" SIMULATOR=$(SIMULATOR) WAVE=$(WAVE) bash "$(package_dir)/repo/rtl/nmu/response_depacketize/test_response_depacketize.sh"

.PHONY: in_order_perf
in_order_perf: compile
	bash "$(script_dir)/perf.sh" "$(package_dir)" "$(run_dir)" "$(PYTHON)" "$(wave_ext)" "$(ID_WIDTH)"

.PHONY: out_of_order_perf
out_of_order_perf: compile
	bash "$(script_dir)/perf.sh" "$(package_dir)" "$(run_dir)" "$(PYTHON)" "$(wave_ext)" "$(ID_WIDTH)" out_of_order

.PHONY: mixed_perf
mixed_perf: compile
	bash "$(script_dir)/perf.sh" "$(package_dir)" "$(run_dir)" "$(PYTHON)" "$(wave_ext)" "$(ID_WIDTH)" mixed

.PHONY: verification
verification:
	cd "$(package_dir)" && $(PYTHON) script/test_verification.py
