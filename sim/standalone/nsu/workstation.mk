.DEFAULT_GOAL := help
SHELL := /bin/bash
.NOTPARALLEL:
CASE ?= request
VCS ?= vcs
export VCS_ARCH_OVERRIDE ?= linux
ifeq ($(CASE),context)
TOP := tb_nsu_context_buffer
PASS := NSU_CONTEXT_PASS
else ifeq ($(CASE),request)
TOP := tb_nsu_elaborate
PASS := NSU_REQUEST_PASS
else
$(error Unknown CASE '$(CASE)'; use make list)
endif
FLAGS := -full64 -sverilog -assert svaext -override_timescale=1ns/1ps -f files.f repo/sim/standalone/nsu/$(TOP).sv -top $(TOP)
KEY := $(shell cat SHA256SUMS Makefile | sha256sum | cut -c1-12)
BUILD := $(CURDIR)/build/$(CASE)_$(KEY)
.PHONY: help list compile run sim clean
help:
	@echo 'make run CASE=context|request | make list | make clean'
	@echo 'Existing NSU focused tests. Full read/write patterns: ../sim/'
list:
	@cat pattern.txt
$(BUILD)/simv:
	@mkdir -p $(BUILD)
	$(VCS) $(FLAGS) -Mdir=$(BUILD)/csrc -o $@ -l $(BUILD)/compile.log
compile: $(BUILD)/simv
run: compile sim
sim:
	@test -x $(BUILD)/simv || { echo 'Run make run first' >&2; exit 1; }
	@set -o pipefail; $(BUILD)/simv | tee $(BUILD)/run.log
	@grep -q '$(PASS)' $(BUILD)/run.log
clean:
	@bash clean.sh
