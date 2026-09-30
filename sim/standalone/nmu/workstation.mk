.DEFAULT_GOAL := help
TESTBENCH ?= standalone
CASE_NAMES := $(shell cat cases.list)
ifneq ($(strip $(CASE)),)
ifeq ($(filter $(CASE),$(CASE_NAMES)),)
$(error Unknown CASE '$(CASE)'; use make list)
endif
endif
ifeq ($(TESTBENCH),cosim)
RUN_DIR := cosim
else ifeq ($(TESTBENCH),standalone)
RUN_DIR := script
else
$(error TESTBENCH must be standalone or cosim)
endif

.PHONY: help list compile run sim regress run_wave run_wave_view nWave view report clean
help:
	@echo 'make list | make run CASE=<case> TESTBENCH=standalone|cosim'
	@echo 'make sim CASE=<case> | make regress'
	@echo 'make run_wave_view CASE=<case> | make nWave CASE=<case>'
	@echo 'make clean'
list:
	@cat pattern_list.txt
compile run sim run_wave run_wave_view nWave:
	$(MAKE) --no-print-directory -C $(RUN_DIR) $@
regress: compile
	@set -e; while read -r name; do $(MAKE) --no-print-directory -C $(RUN_DIR) sim CASE=$$name; done < cases.list
view:
	$(MAKE) --no-print-directory -C $(RUN_DIR) nWave
report clean:
	$(MAKE) --no-print-directory -C script $@
