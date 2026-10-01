.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(abspath ..)
RTL_STAGE ?= $(ROOT)/sim/standalone/nmu/output/i8_n5_b128_r1/stage
CASE ?= ctrl_write_single
OUT := $(ROOT)/build/sim/stage
.PHONY: help prepare lint sync compile run sim regress run_wave view list clean
help:
	@echo 'make run CASE=<case> | make run_wave CASE=<case> | make view CASE=<case> | make clean'
prepare:
	python3 prepare.py --rtl-stage "$(RTL_STAGE)" --out "$(OUT)"
lint: prepare
	cd "$(OUT)" && verilator --lint-only --timescale-override 1ps/1ps --timing --assert -Wno-fatal -f files.f --top-module tb_top -GRTL_NSU=1
sync: prepare
	python3 "$(ROOT)/sim/tools/sync_nmu_workstation.py" --source "$(OUT)" --remote-dir /home/mingwei/noc_project/sim

compile run regress run_wave: prepare
compile run sim regress run_wave view list:
	$(MAKE) --no-print-directory -C "$(OUT)" $@ CASE=$(CASE)
clean:
	@if [ -f "$(OUT)/Makefile" ]; then $(MAKE) --no-print-directory -C "$(OUT)" clean; fi
