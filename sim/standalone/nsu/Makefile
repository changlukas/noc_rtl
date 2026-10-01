.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(abspath ../../..)
RTL_STAGE ?= $(ROOT)/sim/standalone/nmu/output/i8_n5_b128_r1/stage
OUT := $(ROOT)/build/nsu-standalone/stage
CASE ?= ctrl_write_single
.PHONY: help prepare compile run sim regress run_wave view list clean
help:
	@echo 'make run CASE=<case> | make run_wave CASE=<case> | make view CASE=<case> | make clean'
prepare:
	python3 prepare.py --rtl-stage "$(RTL_STAGE)" --out "$(OUT)"
compile run regress run_wave: prepare
compile run sim regress run_wave view list:
	$(MAKE) --no-print-directory -C "$(OUT)" $@ CASE=$(CASE)
clean:
	@if [ -f "$(OUT)/Makefile" ]; then $(MAKE) --no-print-directory -C "$(OUT)" clean; fi
