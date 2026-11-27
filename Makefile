.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help build compile sim test clean check
help:
	@echo 'make build                Prepare system-test inputs and compile the VCS testbench'
	@echo 'make compile              Compile an already prepared configuration'
	@echo 'make sim CASE=<case>      Run one case with the compiled configuration'
	@echo 'make test                 Prepare, compile and run the seven system checks'
	@echo 'make clean                Remove build/compile and build/regression'
	@echo 'Simulation: cd sim; make run CASE=<case> | make run_wave view CASE=<case>'
	@echo 'Standalone: make -C dv/tb/standalone/nmu or dv/tb/standalone/nsu'
build:
	$(MAKE) -f sim/Makefile prepare-single
	$(MAKE) -f sim/Makefile compile
compile sim clean:
	$(MAKE) -f sim/Makefile $@
test: export WAVE = 0
test: build
	@set -e; for c in ctrl_read_single ctrl_write_single data_read_single data_write_single reset_recovery; do \
		$(MAKE) -f sim/Makefile sim CASE=$$c MODE=auto TARGET=per_id BACKPRESSURE=0; \
	done
	$(MAKE) -f sim/Makefile sim CASE=single_id_reorder MODE=data TARGET=per_id BACKPRESSURE=1
	$(MAKE) -f sim/Makefile sim CASE=capacity_reuse MODE=data TARGET=rob BACKPRESSURE=0
check:
	python3 -m pytest -q dv/scripts/test_gen_standalone_patterns.py dv/scripts/test_standalone_clean.py dv/scripts/test_coverage_build_key.py dv/scripts/test_tb_runner.py dv/scripts/test_verification_matrix.py
