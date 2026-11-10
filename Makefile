.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help clean check
help:
	@echo 'Simulation: cd sim; make run CASE=<case> | make run_wave view CASE=<case>'
	@echo 'Standalone: make -C dv/tb/standalone/nmu or dv/tb/standalone/nsu'
clean:
	python3 dv/scripts/clean.py
check:
	python3 -m pytest -q dv/scripts/test_gen_standalone_patterns.py dv/scripts/test_standalone_clean.py dv/scripts/test_coverage_build_key.py dv/scripts/test_tb_runner.py dv/scripts/test_verification_matrix.py
