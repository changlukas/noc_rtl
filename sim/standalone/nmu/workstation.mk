ifneq ($(origin TESTBENCH),undefined)
$(error Select the directory: NMU loopback here; NMU/router/NSU in ../sim/)
endif
ifneq ($(strip $(CASE)),)
ifeq ($(filter $(CASE),$(shell cat cases.list)),)
$(error Unknown CASE '$(CASE)'; use make list)
endif
endif
include script/Makefile
.DEFAULT_GOAL := help
