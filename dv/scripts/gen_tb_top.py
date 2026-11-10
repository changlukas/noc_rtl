#!/usr/bin/env python3

"""Generate the shared topology/SAM package for NMU verification."""

import argparse
import sys
from pathlib import Path
import address_map
ROOT = Path(__file__).resolve().parents[2]

def load_topology(name: str) -> dict:
    import yaml
    path = ROOT / "dv/config/topology" / f"{name}.yml"
    topo = yaml.safe_load(path.read_text())
    _check_flit_capacity(topo, path)
    return topo

def num_vc() -> int:
    """DAT class count from the native unit configuration."""
    return native_param("noc_unit_params_pkg", "DAT_NUM_VC")


def native_param(package: str, name: str) -> int:
    """Read a literal integer or bit parameter from an existing native package."""
    import re
    source = (ROOT / "define" / (package + ".sv")).read_text(encoding="utf-8")
    value = re.search(r"\blocalparam\s+(?:int|bit)\s+" + re.escape(name)
                      + r"\s*=\s*(\d+|1'b[01])\s*;", source)
    if value is None:
        raise ValueError("Expected a native integer or bit parameter: " + package + "::" + name)
    literal = value.group(1)
    return int(literal[-1]) if "'b" in literal else int(literal)


def _check_flit_capacity(cfg: dict, path) -> None:
    """Check mesh dimensions against the native endpoint coordinate fields."""
    # Read straight off the router array rather than through
    # address_map.router_array(): this is a second, independent reader, and its
    # per-axis power-of-two report below is the stronger of the two checks.
    array = cfg["routers"][0]["array"]
    x_dim, y_dim = int(array[0]), int(array[1])
    cap_x = 1 << X_WIDTH
    cap_y = 1 << Y_WIDTH
    cap_nodes = 1 << DST_ID_WIDTH
    errors = []
    if x_dim < 2:
        errors.append(f"x_dim={x_dim} < 2 (mesh dimension minimum is 2; 1x1/1xN meshes are illegal)")
    if y_dim < 2:
        errors.append(f"y_dim={y_dim} < 2 (mesh dimension minimum is 2; 1x1/1xN meshes are illegal)")
    # Mirrors sam_yaml.hpp's load-time assert. Caught here so a non-power-of-two
    # topology fails at generate time rather than after elaborating a testbench
    # the model then aborts on.
    for axis, dim in (("x", x_dim), ("y", y_dim)):
        if dim & (dim - 1):
            errors.append(
                f"{axis}_dim={dim} is not a power of two (a collective mask wildcards a "
                f"clog2(dim)-bit coordinate field, so every index it names must be a node)")
    if x_dim > cap_x:
        errors.append(f"x_dim={x_dim} > 2^X_WIDTH={cap_x}")
    if y_dim > cap_y:
        errors.append(f"y_dim={y_dim} > 2^Y_WIDTH={cap_y}")
    if x_dim * y_dim > cap_nodes:
        errors.append(f"x_dim*y_dim={x_dim * y_dim} > 2^DST_ID_WIDTH={cap_nodes}")
    if errors:
        raise SystemExit(
            f"gen_tb_top: flit-capacity violated in {path}:\n"
            + "\n".join(f"  {e}" for e in errors)
        )

def _coord_id(x: int, y: int) -> int:
    """Coordinate-encoded node id = route_compute dst_id = (y<<X_WIDTH)|x."""
    return (y << X_WIDTH) | x

def _nodes(topo: dict):
    """Return ordered node list: [(idx, x, y, coord_id), ...] in (y,x) raster order.

    idx is the linear emit index (0..N-1) and doubles as the ARRAY position:
    array x = idx % x_dim, array y = idx // x_dim, which is what the emitted
    generate loop derives its neighbour wiring and boundary tie-off from. A
    router's route coordinate IS its array position, and coord_id is the routing
    id built from it.
    """
    x_dim, y_dim = address_map.router_array(topo)
    out = []
    idx = 0
    for y in range(y_dim):
        for x in range(x_dim):
            out.append((idx, x, y, _coord_id(x, y)))
            idx += 1
    return out, x_dim, y_dim

def _peripherals(topo: dict):
    """Endpoints attached to a boundary port instead of EJECT, in member order.

    A peripheral has an NI and a test endpoint but no router. It SHARES its host
    router's coordinate and is told apart by the boundary port it hangs off:
    EAST/WEST are port 1, NORTH/SOUTH port 2. dst_dir is read as that port and
    never as a coordinate offset -- FlooNoC derives a non-router NI's coordinate
    from it, which here would place the peripheral one step outside the mesh.

    A corner router is legal: it has two free faces, and dst_dir says which one
    is meant.

    Returns [{"x", "y", "cid", "port", "router_idx", "dir"}, ...].
    Peripherals extend the ENDPOINT index space, not the node index space:
    nodes 0..N-1 stay the routers and peripheral p is endpoint N + p.
    """
    x_dim, y_dim = address_map.router_array(topo)
    out = []
    taken = set()
    for ep in topo["endpoints"]:
        for a in address_map.attachments(topo, ep["name"], address_map.members(ep), x_dim):
            if a["dir"] == _EJECT:
                continue
            x, y, direction = a["x"], a["y"], _DIR_NAME[a["dir"]]
            if not (0 <= x < x_dim and 0 <= y < y_dim):
                raise SystemExit(
                    f"gen_tb_top: peripheral {ep['name']} at (x={x},y={y}) is outside the "
                    f"{x_dim}x{y_dim} router array -- a peripheral shares a router's "
                    f"coordinate, it does not take one of its own")
            # Same rule sam_yaml.hpp's loader applies, checked here because the
            # generator is a second, independent reader of the same config: on an
            # edge router the named port has no neighbour and is terminal, while
            # on an interior router it carries a live inter-router link and
            # hanging a peripheral off it closes a channel dependency cycle.
            on_edge = {"WEST": x == 0, "EAST": x == x_dim - 1,
                       "SOUTH": y == 0, "NORTH": y == y_dim - 1}[direction]
            if not on_edge:
                raise SystemExit(
                    f"gen_tb_top: peripheral {ep['name']} at (x={x},y={y}) hangs off the "
                    f"{direction} port, an edge this coordinate is not on -- an interior "
                    f"router's port carries a live inter-router link, and hanging a "
                    f"peripheral off it closes a channel dependency cycle")
            if (x, y, direction) in taken:
                raise SystemExit(
                    f"gen_tb_top: two peripherals both claim (x={x},y={y}) {direction}")
            taken.add((x, y, direction))
            out.append({"x": x, "y": y, "cid": _coord_id(x, y), "port": a["port"],
                        "router_idx": y * x_dim + x, "dir": direction})
    return out

def _endpoints(nodes, peripherals):
    """Router nodes followed by peripherals, in (idx, x, y, coord_id, port) shape.

    The endpoint index space: 0..N-1 are the routers, N..N+P-1 the peripherals.
    Each entry carries its own ni_wrap, user_node_endpoint and NMU / NSU /
    dat_merge context; only the first N carry a router.

    port is what separates two endpoints at one coordinate: a router node is the
    tile on port 0 (LOCAL), a peripheral is the boundary port it hangs off.
    """
    return [(idx, x, y, cid, 0) for (idx, x, y, cid) in nodes] + \
           [(len(nodes) + p, per["x"], per["y"], per["cid"], per["port"])
            for p, per in enumerate(peripherals)]

def tile_targets(topo: dict, endpoints):
    """Each endpoint's own crossbar windows, in target PORT ORDER (m0 = config,
    m1 = data).

    Port order and field packing are ONE coupled invariant: target t occupies
    field t of the packed parameters, and user_node_endpoint puts the config
    memory on target 0 and the data memory on the last target. The check below
    is what stops an address_map.py SPACE_ORDER edit from transposing the two
    silently.

    Per node, not shared: the crossbar decodes on THIS node's windows so that
    anything the local initiator addresses elsewhere falls through to the
    default master port and goes onto the NoC. A request arriving from the
    fabric always lands in these windows -- the NSU rewrites its
    node-coordinate field to this node first (nsu::Depacketize::rebase_).

    Returns ({endpoint_idx: [{"space", "base", "size"}, ...]}, noc_egress_base).
    """
    _bases, entries = address_map.pack_config(topo)
    out = {}
    for idx, _x, _y, cid, port in endpoints:
        windows = address_map.node_windows(entries, cid, port)
        order = [w["space"] for w in windows]
        # Spelled out here rather than read back from address_map.SPACE_ORDER:
        # this is the cross-check on that constant, not a restatement of it.
        # Checked BEFORE the padding below, or every short row would read as
        # ragged-then-padded and the check would say nothing.
        expected = ["config", "memory"] if port == 0 else ["peripheral"]
        if order != expected:
            raise SystemExit(
                f"gen_tb_top: endpoint {idx} (port {port}) window order {order} must be "
                f"{expected} -- user_node_endpoint puts the config memory on target 0 and "
                f"the data memory on the last target (see address_map.SPACE_ORDER)")
        out[idx] = windows
    # The emitted parameters are RECTANGULAR -- [n_ep-1:0][TILE_TARGETS-1:0] --
    # so a one-window peripheral row beside a two-window tile row will not
    # elaborate. Pad the short rows to the widest instead of reshaping.
    #
    # A pad is a REAL range parked above every window, never an empty one.
    # size 0 at base 0 looks inert and is the opposite: addr_decode
    # (deps/common_cells-1.37.0/src/addr_decode_dync.sv:110-112) matches on
    #     addr >= start_addr && (addr < end_addr || end_addr == '0)
    # and end_addr == '0 means "end of address space" (documented at :56-57),
    # so start = end = 0 is a WILDCARD that matches every address. The match
    # loop has no break and the last match wins, and a pad sits at a higher
    # rule index than the real window it pads, so it would swallow the whole
    # map: fabric traffic would land in the pad's memory instead of the real
    # one, the local initiator would stop falling through to the NMU, and
    # nothing would ever be undecoded so the DECERR gate would go dead. None of
    # that fails elaboration.
    #
    # base = 2 * noc_egress_base is the first address above the egress aperture
    # -- user_node_endpoint.sv makes it [NOC_EGRESS_BASE, 2 * NOC_EGRESS_BASE),
    # end-exclusive -- so the pad overlaps nothing and warns about nothing.
    # start < end keeps check_start quiet (it fatals on start == end unless end
    # is the wildcard zero) and end != 0 keeps the pad out of the wildcard
    # branch. A zero SIZE is not an option here in either direction.
    egress = address_map.noc_egress_base(entries)
    width = max(len(w) for w in out.values())
    for idx, windows in out.items():
        # Staggered, so two pads in one row could never be the same rule twice.
        windows.extend({"space": None, "base": 2 * egress + k * _PAD_BYTES,
                        "size": _PAD_BYTES}
                       for k in range(width - len(windows)))
    return out, egress

def _is_power_of_two(value: int) -> bool:
    return value > 0 and (value & (value - 1)) == 0

def _sam_range_error(endpoint_name: str, detail: str) -> None:
    raise SystemExit(f"gen_tb_top: endpoint {endpoint_name}: {detail}")

def _validate_sam_ranges(topo: dict) -> None:
    """Reject ranges that cannot be represented by the generated address type."""
    addr_limit = 1 << ADDR_WIDTH
    for endpoint in topo["endpoints"]:
        if endpoint.get("sbr_port_protocol") is None:
            continue
        member_count = address_map.members(endpoint)
        for rule in endpoint["addr_range"]:
            try:
                base = int(rule["base"])
                size = int(rule["size"])
                stride = int(rule["stride"]) if rule.get("stride") is not None else size
            except (KeyError, TypeError, ValueError) as error:
                _sam_range_error(endpoint["name"], f"range has a non-integer field ({error})")
            if size <= 0 or size % _SAM_ALIGNMENT != 0:
                _sam_range_error(endpoint["name"],
                                 "range size must be positive and 4 KB aligned")
            if base < 0 or stride <= 0 or base % _SAM_ALIGNMENT != 0 or \
                    stride % _SAM_ALIGNMENT != 0:
                _sam_range_error(endpoint["name"],
                                 "range base and stride must be 4 KB aligned and non-negative")
            for member in range(member_count):
                start = base + stride * member
                end = start + size
                if start >= end or start >= addr_limit or end >= addr_limit:
                    _sam_range_error(endpoint["name"],
                                     "range expansion does not fit the canonical address width")

def _collective_selectors(entries: list, x_dim: int, y_dim: int) -> dict:
    """Return representable X/Y selector pairs for each collective-capable space."""
    selectors = {}
    for space in ("config", "memory"):
        space_entries = [entry for entry in entries
                         if entry["space"] == space and entry["port"] == 0]
        by_coord = {(entry["x"], entry["y"]): entry for entry in space_entries}
        if len(space_entries) != x_dim * y_dim or len(by_coord) != len(space_entries):
            continue
        origin = by_coord.get((0, 0))
        x_neighbor = by_coord.get((1, 0))
        if origin is None or x_neighbor is None:
            continue
        stride = x_neighbor["base"] - origin["base"]
        if not _is_power_of_two(stride):
            continue
        if any(entry["size"] != origin["size"] for entry in space_entries):
            continue
        if any(entry["base"] != origin["base"] + (y * x_dim + x) * stride
               for (x, y), entry in by_coord.items()):
            continue
        x_len = (x_dim - 1).bit_length()
        y_len = (y_dim - 1).bit_length()
        offset = stride.bit_length() - 1
        field_mask = (((1 << x_len) - 1) << offset) | \
                     (((1 << y_len) - 1) << (offset + x_len))
        if origin["base"] & field_mask or origin["size"] > stride:
            continue
        if offset + x_len + y_len > ADDR_WIDTH:
            continue
        selectors[space] = ((offset, x_len), (offset + x_len, y_len))
    return selectors

def _sam_rules(topo: dict):
    """Expand YAML rules and attach collective metadata for package emission."""
    _validate_sam_ranges(topo)
    _bases, entries = address_map.pack_config(topo)
    _nodes_, x_dim, y_dim = _nodes(topo)
    selectors = _collective_selectors(entries, x_dim, y_dim)

    rules = []
    for entry in entries:
        collective_enabled = bool(entry.get("en_collective", False))
        if collective_enabled:
            if entry["space"] not in selectors:
                raise SystemExit("gen_tb_top: collective layout is not representable for "
                                 f"{entry['space']} space")
            mask_x, mask_y = selectors[entry["space"]]
        else:
            mask_x = (0, 0)
            mask_y = (0, 0)
        rules.append({
            **entry,
            "mask_x": mask_x,
            "mask_y": mask_y,
        })
    return rules

def _emit_sam_declarations(sam_rules):
    lines = []
    w = lines.append
    w("    localparam int unsigned ADDR_WIDTH = noc_payload_pkg::AXI_ADDR_WIDTH;")
    w(f"    localparam int unsigned SAM_NUM_RULES = {len(sam_rules)};")
    w("    localparam int unsigned SAM_MASK_SEL_FIELD_W = $clog2(ADDR_WIDTH + 1);")
    w("")
    w("    typedef noc_sam_pkg::sam_addr_t sam_addr_t;")
    w("    typedef noc_sam_pkg::sam_mask_sel_t sam_mask_sel_t;")
    w("    typedef noc_sam_pkg::sam_result_t sam_result_t;")
    w("    typedef noc_sam_pkg::sam_rule_t sam_rule_t;")
    w("    localparam sam_rule_t [SAM_NUM_RULES-1:0] SAM = '{")
    for authored_index, rule in enumerate(sam_rules):
        generated_index = len(sam_rules) - 1 - authored_index
        comma = "," if generated_index else ""
        w(f"        // Authored rule {authored_index}: SAM[{generated_index}]")
        w("        " +
          f"{generated_index}: '{{idx: '{{dst_id: "
          f"'{{port_id: noc_header_pkg::PORT_ID_WIDTH'({rule['port']}), "
          f"y: noc_header_pkg::Y_WIDTH'({rule['dst_id']} >> noc_header_pkg::X_WIDTH), "
          f"x: noc_header_pkg::X_WIDTH'({rule['dst_id']})}}, "
          f"is_data: 1'b{int(rule['space'] != 'config')}, "
          f"mask_x: '{{offset: SAM_MASK_SEL_FIELD_W'({rule['mask_x'][0]}), "
          f"len: SAM_MASK_SEL_FIELD_W'({rule['mask_x'][1]})}}, "
          f"mask_y: '{{offset: SAM_MASK_SEL_FIELD_W'({rule['mask_y'][0]}), "
          f"len: SAM_MASK_SEL_FIELD_W'({rule['mask_y'][1]})}}}}, "
          f"start_addr: ADDR_WIDTH'(64'h{rule['base']:012X}), "
          f"end_addr: ADDR_WIDTH'(64'h{rule['base'] + rule['size']:012X})}}{comma}")
    w("    };")
    return lines

def _emit_endpoint_declarations(topo):
    nodes, x_dim, y_dim = _nodes(topo)
    peripherals = _peripherals(topo)
    endpoints = _endpoints(nodes, peripherals)
    # Endpoint PORT_ID names an axis; the mesh table names a physical router port.
    ports = ["LOCAL"] * len(nodes) + [p["dir"] for p in peripherals]
    node_indices = list(range(len(nodes))) + [p["router_idx"] for p in peripherals]
    count = len(endpoints)
    lines = [f"    localparam int unsigned X_DIM = {x_dim};",
             f"    localparam int unsigned Y_DIM = {y_dim};",
             f"    localparam int unsigned NUM_ENDPOINTS = {count};",
             "    localparam noc_header_pkg::endpoint_id_t [NUM_ENDPOINTS-1:0] ENDPOINT_ID = '{"]
    for i, (_, x, y, _, port) in enumerate(endpoints):
        comma = "," if i + 1 < count else ""
        lines.append(f"        {i}: '{{port_id: noc_header_pkg::PORT_ID_WIDTH'({port}), "
                     f"y: noc_header_pkg::Y_WIDTH'({y}), x: noc_header_pkg::X_WIDTH'({x})}}{comma}")
    lines += ["    };",
              "    localparam logic [NUM_ENDPOINTS-1:0][31:0] ENDPOINT_NODE = '{"]
    lines += [f"        {i}: 32'd{node}{',' if i + 1 < count else ''}"
              for i, node in enumerate(node_indices)]
    lines += ["    };",
              "    localparam logic [NUM_ENDPOINTS-1:0][31:0] ENDPOINT_PORT = '{"]
    lines += [f"        {i}: noc_unit_params_pkg::router_port(noc_unit_params_pkg::{port})"
              f"{',' if i + 1 < count else ''}" for i, port in enumerate(ports)]
    return lines + ["    };"]


def emit_sam_pkg(topo):
    """SAM-only package for block co-simulation without mesh/tile crossbars."""
    return "\n".join([
        "`timescale 1ns/1ps",
        "// Generated from the co-simulation topology; do not edit.",
        "package topology_pkg;",
        *_emit_endpoint_declarations(topo),
        *_emit_sam_declarations(_sam_rules(topo)),
        "endpackage : topology_pkg", "",
    ])

def emit_topology_pkg(topo: dict) -> str:
    """Address-map package for the selected configuration: TILE_BASE_ADDR /
    TILE_SIZE / NOC_EGRESS_BASE / the peripheral table, computed exactly as
    emit_tb_top computes them for tb_top's own parameter block -- relocated
    here, not re-derived. Mirrors FlooNoC's floo_axi_mesh_noc_pkg supplying
    Sam[] to tb_floo_axi_mesh.sv.

    The package NAME is fixed, its CONTENTS vary with CONFIG: sim/tb/
    tb_noc_mesh.sv carries one `import`, so two configurations cannot coexist
    in a build tree without regenerating -- FlooNoC's property too.
    """
    nodes, x_dim, y_dim = _nodes(topo)
    n = len(nodes)
    peripherals = _peripherals(topo)
    endpoints = _endpoints(nodes, peripherals)
    n_ep = len(endpoints)
    sam_rules = _sam_rules(topo)
    per_node, noc_egress_base = tile_targets(topo, endpoints)
    n_targets = max(len(w) for w in per_node.values())
    # Same cast and row order as emit_tb_top's TILE_BASE_ADDR/TILE_SIZE: packed,
    # descending, field t is target t and row i is node i.
    def _rows(key):
        return ", ".join(
            "{" + ", ".join(f"ADDR_WIDTH'(64'h{t[key]:X})"
                             for t in reversed(per_node[i])) + "}"
            for i in reversed(range(n_ep)))
    tile_base_addr = _rows("base")
    tile_size = _rows("size")

    geom = topo["name"]
    pkg = "topology_pkg"
    guard = pkg.upper() + "_SVH"
    # Sized max(N_PERIPH, 1): a packed array cannot have zero elements
    # (noc_fabric.sv's N_PERIPH_MAX parameter mirrors the same constraint).
    periph_width = max(len(peripherals), 1)
    # Packed, descending, as PERIPH_NODE/PERIPH_PORT in the fabric
    # instantiation: field p is peripheral p, so element [0] is the LSB byte.
    node_bits = ", ".join(f"8'd{per['router_idx']}" for per in reversed(peripherals)) \
        if peripherals else "8'd0"
    port_bits = ", ".join(f"8'd{per['port']}" for per in reversed(peripherals)) \
        if peripherals else "8'd0"

    lines = []
    w = lines.append
    w("`timescale 1ns/1ps")
    w("")
    w("// AUTO-GENERATED by dv/scripts/gen_tb_top.py --emit-topology-pkg")
    w(f"// Geometry: {geom}  ({x_dim}x{y_dim}, {len(peripherals)} peripheral(s))")
    w("// DO NOT EDIT - modify the generator or dv/config/topology/*.yml instead.")
    w("//")
    w("// Address-map constants for the selected configuration: TILE_BASE_ADDR /")
    w("// TILE_SIZE / NOC_EGRESS_BASE / the peripheral table, the same values emit_tb_top")
    w("// stamps into tb_top's own parameter block. Mirrors FlooNoC's")
    w("// floo_axi_mesh_noc_pkg supplying Sam[] to tb_floo_axi_mesh.sv.")
    w("")
    w(f"`ifndef {guard}")
    w(f"`define {guard}")
    w("")
    w(f"package {pkg};")
    w("")
    lines.extend(_emit_endpoint_declarations(topo))
    w(f"    localparam int unsigned NUM_NODES = {n};")
    lines.extend(_emit_sam_declarations(sam_rules))
    w(f"    localparam int unsigned TILE_TARGETS = {n_targets};")
    w(f"    localparam logic [{n_ep - 1}:0][TILE_TARGETS-1:0][ADDR_WIDTH-1:0] TILE_BASE_ADDR = "
      f"{{{tile_base_addr}}};")
    w(f"    localparam logic [{n_ep - 1}:0][TILE_TARGETS-1:0][ADDR_WIDTH-1:0] TILE_SIZE = "
      f"{{{tile_size}}};")
    w(f"    localparam logic [ADDR_WIDTH-1:0] NOC_EGRESS_BASE = "
      f"ADDR_WIDTH'(64'h{noc_egress_base:X});")
    w(f"    localparam longint unsigned REGION_BYTES = 64'h{_DEFAULT_REGION_BYTES:X};")
    w("")
    w(f"    localparam int unsigned N_PERIPH = {len(peripherals)};")
    w(f"    localparam logic [{periph_width - 1}:0][7:0] PERIPH_NODE = {{{node_bits}}};")
    w(f"    localparam logic [{periph_width - 1}:0][7:0] PERIPH_PORT = {{{port_bits}}};")
    w("")
    w(f"endpackage : {pkg}")
    w("")
    w(f"`endif  // {guard}")
    return "\n".join(lines) + "\n"

X_WIDTH = native_param("noc_header_pkg", "X_WIDTH")
Y_WIDTH = native_param("noc_header_pkg", "Y_WIDTH")
DST_ID_WIDTH = X_WIDTH + Y_WIDTH
ADDR_WIDTH = native_param("noc_payload_pkg", "AXI_ADDR_WIDTH")
_SAM_ALIGNMENT = 0x1000
_EJECT = 4
_DIR_NAME = {0: "NORTH", 1: "EAST", 2: "SOUTH", 3: "WEST"}
_DEFAULT_REGION_BYTES = 0x1000
_PAD_BYTES = 0x1000

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--topology", default="mesh_2x2")
    parser.add_argument("--emit-topology-pkg", action="store_true")
    parser.add_argument("--print-num-vc", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()
    if args.print_num_vc:
        print(num_vc())
    else:
        output = Path(args.out or ROOT / "build/topology_pkg.sv")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(emit_topology_pkg(load_topology(args.topology)))

