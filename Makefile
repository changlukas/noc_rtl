.DEFAULT_GOAL := help
.NOTPARALLEL:
TESTBENCH ?= standalone
SIMULATOR ?= vcs
CASE ?= ctrl_write_single
STANDALONE_STAGE := $(CURDIR)/sim/standalone/nmu/output/i8_n5_b128_r1/stage
REMOTE_DIR ?= /home/mingwei/noc_project/nmu-standalone
.PHONY: help prepare sync compile run sim regress run_wave run_wave_view nWave clean check
help:
	@echo 'make prepare | make sync'
	@echo 'make run TESTBENCH=standalone SIMULATOR=verilator CASE=ctrl_write_single'
	@echo 'Workstation: make run TESTBENCH=cosim CASE=ctrl_write_single'
prepare:
	$(MAKE) -C sim/standalone/nmu prepare
	$(MAKE) -C sim/cosim/nmu prepare RTL_STAGE=$(STANDALONE_STAGE)
sync: prepare
	python3 sim/tools/sync_nmu_workstation.py --source $(STANDALONE_STAGE) --remote-dir $(REMOTE_DIR)
	python3 sim/tools/sync_nmu_workstation.py --source build/nmu-cosim/stage --remote-dir $(REMOTE_DIR)/cosim
compile run regress run_wave run_wave_view nWave: prepare
compile run sim regress run_wave run_wave_view nWave:
	$(MAKE) -C sim/$(if $(filter cosim,$(TESTBENCH)),cosim,standalone)/nmu $@ SIMULATOR=$(SIMULATOR) CASE=$(CASE)
check:
	python3 specgen/tools/codegen.py --check
	python3 -m pytest -q specgen/tests sim/tools/test_gen_standalone_patterns.py sim/tools/test_standalone_clean.py

clean:
	$(MAKE) -C sim/standalone/nmu clean
