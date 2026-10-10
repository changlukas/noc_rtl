.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help prepare sync run run_wave view regress verification report clean check
help:
	@echo 'make prepare | make run CASE=<case> | make verification | make report'
	@echo 'Standalone: make -C sim/standalone/nmu or sim/standalone/nsu'
prepare sync run run_wave view regress verification report clean:
	$(MAKE) -C sim $@
check:
	python3 specgen/tools/codegen.py --check
	python3 -m pytest -q specgen/tests sim/tools/test_gen_standalone_patterns.py sim/tools/test_standalone_clean.py sim/tools/test_coverage_build_key.py sim/tools/test_tb_runner.py sim/tools/test_verification_matrix.py
