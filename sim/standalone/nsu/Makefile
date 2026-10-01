.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
ROOT := $(abspath ../../..)
SOURCE ?= $(ROOT)/build/sim/stage
OUT := $(ROOT)/build/nsu-standalone/stage
CASE ?= request
.PHONY: help prepare compile run sim list clean
help:
	@echo 'make run CASE=context|request | make list | make clean'
prepare:
	python3 prepare.py --source "$(SOURCE)" --out "$(OUT)"
compile run: prepare
compile run sim list:
	$(MAKE) --no-print-directory -C "$(OUT)" $@ CASE=$(CASE)
clean:
	@if [ -f "$(OUT)/Makefile" ]; then $(MAKE) --no-print-directory -C "$(OUT)" clean; fi
