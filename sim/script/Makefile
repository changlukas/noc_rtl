.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(CURDIR)
-include profile.mk
CASE ?= ctrl_write_single
JOBS ?= 1
WAVE ?= 0
COVERAGE ?= 0
ifneq ($(filter verification report,$(MAKECMDGOALS)),)
override COVERAGE := 1
endif
COVERAGE_METRICS := line+cond+fsm+tgl+branch+assert
ifneq ($(filter run_wave view,$(MAKECMDGOALS)),)
override WAVE := 1
endif
MODE ?= auto
BACKPRESSURE ?= 0
TARGET ?= per_id
SEED ?= 1
AXI_CLK_PERIOD_PS ?= 1000
NOC_CLK_PERIOD_PS ?= 1000
NOC_CLK_PHASE_PS ?= 0
RSP_DELAY ?= 2
REG_TYPE ?= 0
B_ROB_DEPTH ?= $(shell python3 -c 'import re; print(re.search(r"NMU_ROB_B_DEPTH\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
R_ROB_DEPTH ?= $(shell python3 -c 'import re; print(re.search(r"NMU_ROB_R_DEPTH\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
R_ROB_EN ?= $(shell python3 -c 'import re; print(re.search(r"NMU_R_ROB_EN\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
IO_FIFO_DEPTH ?= 32
-include environment.mk
DIRECT_LINK ?= 0
DEVICE_ID_WIDTH ?= $(shell python3 -c 'import re; print(re.search(r"NSU_AXI_ID_WIDTH\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
CONTEXT_DEPTH ?= 32
INPUT_ID_WIDTH ?= $(shell python3 -c 'import re; print(re.search(r"AXI_ID_WIDTH\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
OUTPUT_ID_WIDTH ?= $(shell python3 -c 'import re; print(re.search(r"NOC_ID_WIDTH\s*=\s*(\d+)", open("repo/specgen/generated/sv/ni_params_pkg.sv").read()).group(1))')
MAX_OUTSTANDING_PER_ID ?= 32
WAVE_RC ?= $(ROOT)/signals.rc
CXX ?= g++
VCS ?= vcs
VCS_HOME ?= $(shell dirname $$(dirname $$(readlink -f $$(command -v $(VCS)))))
VERDI_HOME ?= $(shell dirname $$(dirname $$(readlink -f $$(command -v verdi))))
PLI_DIR ?= $(VERDI_HOME)/share/PLI/VCS/linux64
export LD_LIBRARY_PATH := $(PLI_DIR)$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
export VCS_ARCH_OVERRIDE ?= linux
BUILD := $(ROOT)/build
REPORT := $(BUILD)/report$(if $(filter 1,$(COVERAGE)),_coverage,)_wave$(WAVE)$(if $(filter-out auto,$(MODE)),/$(MODE),)$(if $(filter 1,$(BACKPRESSURE)),/backpressure,)$(if $(filter capacity_reuse,$(CASE)),/$(TARGET),)$(if $(filter-out 1,$(SEED)),/seed$(SEED),)
INCLUDES := -Irepo/ref_model/dpi -Irepo/ref_model/c_model/include -Irepo/ref_model/c_model/tests/common -Irepo/specgen/generated/cpp -Ideps/yaml-cpp/include -Ideps/yaml-cpp/src -I$(VCS_HOME)/include
CPPFLAGS := -std=c++17 -O1 -fPIC -DYAML_CPP_STATIC_DEFINE $(INCLUDES)
YAML_SRC := $(wildcard deps/yaml-cpp/src/*.cpp)
YAML_HEADERS := $(if $(wildcard deps/yaml-cpp/include),$(shell find deps/yaml-cpp/include deps/yaml-cpp/src -name '*.h' -o -name '*.hpp'),)
ifeq ($(WAVE),1)
WAVE_FLAGS := +define+DUMP_WAVE -P $(PLI_DIR)/novas.tab $(PLI_DIR)/pli.a
endif
VCS_FLAGS := -ntb_opts uvm-1.2 -lca -pvalue+tb_top.AXI_CLK_PERIOD_PS=$(AXI_CLK_PERIOD_PS) -pvalue+tb_top.NOC_CLK_PERIOD_PS=$(NOC_CLK_PERIOD_PS) -pvalue+tb_top.NOC_CLK_PHASE_PS=$(NOC_CLK_PHASE_PS) -full64 -sverilog -assert svaext -override_timescale=1ps/1ps -debug_access+all -f files.f -top tb_top -pvalue+tb_top.RSP_DELAY_CYCLES=$(RSP_DELAY) -pvalue+tb_top.OUTPUT_REG_TYPE=$(REG_TYPE) -pvalue+tb_top.IO_FIFO_DEPTH=$(IO_FIFO_DEPTH) -pvalue+tb_top.INPUT_ID_WIDTH=$(INPUT_ID_WIDTH) -pvalue+tb_top.OUTPUT_ID_WIDTH=$(OUTPUT_ID_WIDTH) -pvalue+tb_top.MAX_OUTSTANDING_PER_ID=$(MAX_OUTSTANDING_PER_ID) -pvalue+tb_top.DEVICE_ID_WIDTH=$(DEVICE_ID_WIDTH) -pvalue+tb_top.CONTEXT_DEPTH=$(CONTEXT_DEPTH) -pvalue+tb_top.B_ROB_DEPTH=$(B_ROB_DEPTH) -pvalue+tb_top.R_ROB_DEPTH=$(R_ROB_DEPTH) -pvalue+tb_top.R_ROB_EN=$(R_ROB_EN)
ifeq ($(COVERAGE),1)
VCS_FLAGS += +define+NI_COVERAGE -cm $(COVERAGE_METRICS) -cm_hier coverage.hier
endif
ifeq ($(DIRECT_LINK),0)
DPI := $(BUILD)/dpi_$(shell python3 build_key.py cpp "$(CPPFLAGS) $(CXX)")
YAML_BUILD := $(BUILD)/yaml_$(shell python3 build_key.py yaml "$(CPPFLAGS) $(CXX)")
DPI_DEP := $(DPI)/libnmu_cmodel.so
DPI_LINK := -LDFLAGS "-L$(DPI) -Wl,-rpath,$(DPI) -lnmu_cmodel"
else
VCS_FLAGS += +define+TB_DIRECT_LINK
DPI_DEP :=
DPI_LINK :=
endif
SIM := $(BUILD)/vcs_wave$(WAVE)_$(shell python3 build_key.py sv "$(VCS_FLAGS) $(WAVE_FLAGS) $(DPI)")
YAML_OBJ := $(patsubst deps/yaml-cpp/src/%.cpp,$(YAML_BUILD)/%.o,$(YAML_SRC))
.PHONY: help list compile run sim regress run_wave view clean corrupt
help:
	@printf '%s\n' \
	 'make run CASE=<case>        Compile and simulate' \
	 'make run_wave CASE=<case>   Compile and simulate with FSDB' \
	 'make view CASE=<case>       Open existing FSDB and signal groups' \
	 'make clean                 Remove simulation and GUI output' \
	 'make list                  List the 18 test cases'
list:
	@cat pattern_list.txt
ifeq ($(DIRECT_LINK),0)
$(YAML_BUILD)/%.o: deps/yaml-cpp/src/%.cpp $(YAML_HEADERS)
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) -c $< -o $@
# Project sources are already in the directory hash. Their synchronized mtimes
# must not invalidate a previously compiled profile. Vendor headers retain the
# normal dependency because the DPI key does not hash them.
$(DPI)/cmodel_dpi.o: $(YAML_HEADERS)
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) -c repo/ref_model/dpi/cmodel_dpi.cpp -o $@
$(DPI)/libnmu_cmodel.so: $(DPI)/cmodel_dpi.o $(YAML_OBJ)
	$(CXX) -shared -static-libstdc++ -static-libgcc -Wl,-Bsymbolic -o $@ $^ -pthread
endif
$(SIM)/simv: $(DPI_DEP)
	@mkdir -p $(SIM) $(REPORT)
	@cp SHA256SUMS $(REPORT)/source-SHA256SUMS
	$(VCS) $(VCS_FLAGS) -Mdir=$(SIM)/csrc -o $@ $(DPI_LINK) $(WAVE_FLAGS) -l $(REPORT)/compile.log
	@cp ni_tb_params.svh $(SIM)/ni_tb_params.svh
compile: $(SIM)/simv
run: compile sim
sim:
	python3 run.py --binary "$(SIM)/simv" --case "$(CASE)" --mode "$(MODE)" --target "$(TARGET)" --seed "$(SEED)" $(if $(filter 1,$(BACKPRESSURE)),--backpressure,) --report "$(REPORT)" $(if $(filter 1,$(WAVE)),--wave,) $(if $(filter 1,$(COVERAGE)),--coverage,)
regress: compile
	@set -e; while read name; do $(MAKE) --no-print-directory sim CASE=$$name; done < pattern.txt
corrupt: compile
	python3 run.py --binary "$(SIM)/simv" --case data_read_single --report "$(REPORT)" --corrupt
run_wave: run

view:
	@test -f "$(REPORT)/$(CASE).fsdb" || { echo 'Run make run_wave CASE=$(CASE) first' >&2; exit 1; }
	@cat "$(WAVE_RC)" | sed 's|@FSDB@|$(REPORT)/$(CASE).fsdb|g' > "$(REPORT)/$(CASE).rc"
	$(VERDI_HOME)/bin/nWave -ssf "$(REPORT)/$(CASE).fsdb" -sswr "$(REPORT)/$(CASE).rc"

clean:
	@bash "$(ROOT)/clean.sh"

.PHONY: print-build-dirs
print-build-dirs:
	@echo $(DPI)
	@echo $(YAML_BUILD)
	@echo $(SIM)

.PHONY: check_ordering_checker
check_ordering_checker:
	python3 test_ordering_checker.py

.PHONY: verification report
verification:
	$(MAKE) --no-print-directory compile COVERAGE=1
	python3 run_verification.py --jobs $(JOBS)
report:
	@test -s verification_results/coverage-tests.txt || { echo 'Run make verification first' >&2; exit 1; }
	urg -full64 -dir "$(SIM)/simv.vdb" -tests verification_results/coverage-tests.txt -report "$(BUILD)/coverage" -format both -show tests
