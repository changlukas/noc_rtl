# NMU loopback test configuration.
ID_WIDTH ?= $(shell python3 -B -c 'import re; print(re.search(r"AXI_ID_WIDTH\s*=\s*(\d+)", open("../../../../define/noc_payload_pkg.sv").read()).group(1))')
NOC_HALF_PERIOD ?= 5
BUFFER_DEPTH ?= 128
R_ROB_EN ?= 1
PATTERN ?= neighbor
WAVE ?= 0
patterns := neighbor uniform_random hotspot directed
