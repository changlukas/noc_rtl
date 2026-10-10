.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(abspath ..)
CASE ?= ctrl_write_single
REMOTE_ROOT ?= /home/mingwei/noc_project
PROFILE ?= $(ROOT)/sim/profile.yml
OUT ?= $(ROOT)/build/sim/stage
.PHONY: help prepare sync compile run sim regress run_wave view list clean
help:
	@echo 'make run CASE=<case> | make run_wave CASE=<case> | make view CASE=<case> | make clean'
prepare:
	python3 prepare.py --out "$(OUT)" --profile "$(PROFILE)"
sync: prepare
	python3 "$(ROOT)/sim/tools/sync_nmu_workstation.py" --source "$(OUT)" --remote-dir "$(REMOTE_ROOT)/sim"

compile run regress run_wave: prepare
compile run sim regress run_wave view list:
	$(MAKE) --no-print-directory -C "$(OUT)" $@ CASE=$(CASE)
clean:
	@if [ -f "$(OUT)/Makefile" ]; then $(MAKE) --no-print-directory -C "$(OUT)" clean; fi

.PHONY: verification report
verification:
	python3 tools/prepare_ni_verification.py --out "$(OUT)" --profile "$(PROFILE)"
	$(MAKE) --no-print-directory -C "$(OUT)" verification
report:
	$(MAKE) --no-print-directory -C "$(OUT)" report
