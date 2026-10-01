.DEFAULT_GOAL := help
.NOTPARALLEL:
STANDALONE_STAGE := $(CURDIR)/sim/standalone/nmu/output/i8_n5_b128_r1/stage
REMOTE_DIR ?= /home/mingwei/noc_project/nmu-standalone
.PHONY: help prepare sync check
help:
	@echo 'make prepare | make sync | make check'
	@echo 'Simulation: cd sim/standalone/nmu or sim/cosim/nmu; make run CASE=<case>'
prepare:
	$(MAKE) -C sim/standalone/nmu prepare
	$(MAKE) -C sim/cosim/nmu prepare RTL_STAGE=$(STANDALONE_STAGE)
sync: prepare
	python3 sim/tools/sync_nmu_workstation.py --source $(STANDALONE_STAGE) --remote-dir $(REMOTE_DIR)
	python3 sim/tools/sync_nmu_workstation.py --source build/nmu-cosim/stage --remote-dir $(REMOTE_DIR)/cosim
check:
	python3 specgen/tools/codegen.py --check
	python3 -m pytest -q specgen/tests sim/tools/test_gen_standalone_patterns.py sim/tools/test_standalone_clean.py
