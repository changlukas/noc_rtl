# AXI ordering monitor

Source: `pulp-platform/FlooNoC`, revision `6ea0648407e7d989b7ec3a1ce6eaa2045b7cd114`, `hw/test/axi_reorder_compare.sv`.

Local adaptations:
- Buffer observed W beats until their AW destination is known; do not change DUT stimulus timing.
- Compare W data only on asserted WSTRB lanes; use existing axi_pkg byte-lane functions for narrow R transfers.
- Match only the oldest pending request per source ID at each destination; allow different IDs to overtake. Associate W bursts with the matched AW and map responses by downstream ID.
- Clear pending records on reset and suppress channel sampling during reset; comparisons are unchanged.
- Sample dynamic queue status on the falling clock edge for VCS 2017 compatibility.

The monitor observes source AXI and all destination AXI interfaces. It checks request forwarding and per-ID response order. It does not inspect internal NoC tags or prove ROB coverage. Identical same-ID B payloads cannot distinguish two already available responses.

The TB removes NI-local AWUSER metadata from the source monitor view; WUSER/ARUSER match the tied-off DUT input. Addresses are compared unchanged because this co-simulation does not enable NSU address rebasing. Diagnostic formatting uses VCS-supported field widths.

When IDs are remapped, simultaneously reorderable requests must be distinguishable by the remaining AXI header fields. Identical headers across different source IDs are ambiguous at this observation boundary; current generated cases use distinct addresses.

Run `make check_ordering_checker` in the prepared co-simulation directory for the focused positive and negative tests.
