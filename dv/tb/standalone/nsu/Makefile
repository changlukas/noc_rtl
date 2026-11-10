.DEFAULT_GOAL := help
ROOT := $(abspath ../../../..)
.PHONY: help prepare compile run sim regress run_wave view list clean
help prepare compile run sim regress run_wave view list clean:
	$(MAKE) --no-print-directory -C "$(ROOT)/sim" $@ DIRECT_LINK=1
