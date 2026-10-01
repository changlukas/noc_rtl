# Run inside the repository's Linux development environment.
.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
root := $(abspath ../../..)
include config.mk
output := $(CURDIR)/output/i$(ID_WIDTH)_n$(NOC_HALF_PERIOD)_b$(BUFFER_DEPTH)_r$(R_ROB_EN)
stage := $(output)/stage
SIMULATOR ?= verilator
CASE ?= ctrl_write_single
.PHONY: help prepare compile run sim regress run_wave view list clean
help:
	@echo 'make run CASE=<case> | make run_wave CASE=<case> | make view CASE=<case> | make clean'
prepare:
	NMU_TEST_OUTPUT="$(output)" NMU_ID_WIDTH=$(ID_WIDTH) NMU_NOC_HALF_PERIOD=$(NOC_HALF_PERIOD) NMU_BUFFER_DEPTH=$(BUFFER_DEPTH) NMU_READ_ROB=$(R_ROB_EN) bash "$(root)/rtl/nmu/top/test_nmu.sh" prepare
compile run regress run_wave: prepare
compile run sim regress run_wave view list:
	$(MAKE) --no-print-directory -C "$(stage)" $@ SIMULATOR=$(SIMULATOR) CASE=$(CASE)

# Clean every prepared profile without regenerating sources or patterns.
clean:
	@set -e; for task_stage in "$(CURDIR)"/output/*/stage; do \
	  if [[ -f "$$task_stage/files.f" ]]; then \
	    cp "$(root)/sim/standalone/common/clean.sh" "$$task_stage/script/clean.sh"; \
	    bash "$$task_stage/script/clean.sh"; \
	  fi; \
	done
