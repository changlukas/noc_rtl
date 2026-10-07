.DEFAULT_GOAL := help
.NOTPARALLEL:
STANDALONE_STAGE := $(CURDIR)/sim/standalone/nmu/output/i8_n5_b128_r1/stage
REMOTE_ROOT ?= /home/mingwei/noc_project
.PHONY: help prepare sync check
help:
	@echo 'make prepare | make sync | make check'
	@echo 'Simulation directories: sim/standalone/nmu, sim/standalone/nsu, sim/'
prepare:
	$(MAKE) -C sim/standalone/nmu prepare
	$(MAKE) -C sim prepare RTL_STAGE=$(STANDALONE_STAGE)
	$(MAKE) -C sim/standalone/nsu prepare
sync: prepare
	python3 sim/tools/sync_nmu_workstation.py --source $(STANDALONE_STAGE) --remote-dir $(REMOTE_ROOT)/nmu-standalone
	python3 sim/tools/sync_nmu_workstation.py --source build/nsu-standalone/stage --remote-dir $(REMOTE_ROOT)/nsu-standalone
	python3 sim/tools/sync_nmu_workstation.py --source build/sim/stage --remote-dir $(REMOTE_ROOT)/sim
check:
	python3 specgen/tools/codegen.py --check
	python3 -m pytest -q specgen/tests sim/tools/test_gen_standalone_patterns.py sim/tools/test_standalone_clean.py sim/tools/test_coverage_build_key.py sim/tools/test_tb_runner.py sim/tools/test_verification_matrix.py
