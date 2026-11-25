"""Shared packed address-map helper for the sim-side generators.

Used by gen_test_patterns.py and gen_tb_top.py to compute endpoint addresses
and preserve the same first-match rule order from topology configuration.

FlooNoC-shaped config (dv/config/topology/*.yml), read by pack_config():
    endpoints:
      - name: "tile"
        array: [4, 4]
        addr_range:
          - { base: 0x0, size: 0x2000000, stride: 0x100000000, space: memory }
    routers:
      - { name: "router", array: [4, 4] }
    connections:
      - { src: "tile", dst: "router", src_range: ..., dst_range: ..., dst_dir: 4 }
Member k of a range lands at base + stride * k, stride defaulting to size
(FlooNoC routing.py:440-449). The member's coordinate is its host router's,
taken from the connection: array index k is X-fast, k = (y << x_bits) | x, which
is this repo's node numbering and not FlooNoC's Y-fast one -- on a square mesh
the two produce the same SET of bases and transpose every coordinate.
dst_id = (y << X_WIDTH) | x.

pack_config() expands each range into ordered SAM rules.
"""

import re
from pathlib import Path


def native_param(package: str, name: str) -> int:
    """Read a literal integer or bit parameter from an existing native package."""
    source = (Path(__file__).resolve().parents[2] / "define" / (package + ".sv")).read_text(encoding="utf-8")
    value = re.search(r"\blocalparam\s+(?:int|bit)\s+" + re.escape(name)
                      + r"\s*=\s*(\d+|1'b[01])\s*;", source)
    if value is None:
        raise ValueError("Expected a native integer or bit parameter: " + package + "::" + name)
    literal = value.group(1)
    return int(literal[-1]) if "'b" in literal else int(literal)


X_WIDTH = native_param("noc_header_pkg", "X_WIDTH")

# Tile crossbar target order. Fixed, not inferred: it is what pins m0 to the
# config memory and the last target to the data memory in user_node_endpoint.
SPACE_ORDER = ("config", "memory", "peripheral")


def dst_id(x, y):
    """Coordinate-encoded node id = (y << X_WIDTH) | x."""
    return (y << X_WIDTH) | x


def _clog2(n):
    b = 0
    while (1 << b) < n:
        b += 1
    return b


# XYDirections (FlooNoC routing.py:245-252) -> the router port an endpoint hangs
# off. EJECT is the LOCAL port the tile owns; EAST/WEST are the x face and
# NORTH/SOUTH the y face.
# dst_dir is read as a port and nothing else: a peripheral shares its host
# router's coordinate, so FlooNoC's coordinate derivation for a non-router NI
# (network.py:354-363) must NOT be applied -- it would place the peripheral one
# step outside the mesh.
_PORT_OF_DST_DIR = {0: 2, 1: 1, 2: 2, 3: 1, 4: 0}


def router_array(cfg):
    """The single router array's (x_dim, y_dim).

    The router array IS the route coordinate space: a peripheral shares its host
    router's coordinate and takes none of its own, so this is also the tile count
    per axis. x must be a power of two -- the array index packs x into x_bits, so
    a non-power-of-two x leaves gaps in it.
    """
    routers = cfg["routers"]
    if len(routers) != 1:
        raise ValueError("config.routers: expected exactly one router array")
    x_dim, y_dim = int(routers[0]["array"][0]), int(routers[0]["array"][1])
    x_bits = _clog2(x_dim)
    if (1 << x_bits) != x_dim:
        raise ValueError(
            f"config: router array x {x_dim} must be a power of two -- the array index packs x "
            f"into {x_bits} bits, so a non-power-of-two x leaves gaps in it")
    return x_dim, y_dim


def members(endpoint):
    """Endpoint member count. Authored num wins; otherwise the array product."""
    if endpoint.get("num") is not None:
        return int(endpoint["num"])
    array = endpoint.get("array")
    if not array:
        return 1
    n = 1
    for d in array:
        n *= int(d)
    return n


def range_members(bounds, shape):
    """Expand inclusive array coordinates in the mesh's X-fast order."""
    if len(bounds) != len(shape) or len(shape) not in (1, 2):
        raise ValueError("connection range dimensions must match the array")
    axes = []
    for (first, last), size in zip(bounds, shape):
        if not 0 <= first <= last < size:
            raise ValueError("connection range outside array: {}".format(bounds))
        axes.append(range(first, last + 1))
    if len(axes) == 1:
        return list(axes[0])
    return [y * shape[0] + x for y in axes[1] for x in axes[0]]


def attachments(cfg, name, num, x_dim):
    """Member index -> {"x", "y", "port", "dir"}, off the connections naming this endpoint.

    Pair explicit member indices or inclusive source and router coordinate ranges.
    """
    x_bits = _clog2(x_dim)
    out = [None] * num
    for c in cfg.get("connections") or []:
        if c.get("src") != name:
            continue
        raw_direction = c["dst_dir"]
        named = {"North": 0, "East": 1, "South": 2, "West": 3, "Eject": 4}
        direction = named[raw_direction] if raw_direction in named else int(raw_direction)
        port = _PORT_OF_DST_DIR.get(direction)
        if port is None:
            raise ValueError(
                f"connection {name}: dst_dir {c['dst_dir']} is not an XYDirections value")
        if c.get("src_idx") is not None:
            pairs = list(zip(c["src_idx"], c["dst_idx"]))
        else:
            if "src_range" in c or "dst_range" in c:
                ep = next(e for e in cfg["endpoints"] if e["name"] == name)
                sources = range_members(c["src_range"], ep.get("array") or [num])
                targets = range_members(c["dst_range"], router_array(cfg))
                if len(sources) != len(targets):
                    raise ValueError("connection ranges must select equal member counts")
                pairs = zip(sources, targets)
            else:
                pairs = [(k, k) for k in range(num)]
        for src, dst in pairs:
            dst = int(dst)
            out[int(src)] = {"x": dst & (x_dim - 1), "y": dst >> x_bits, "port": port,
                             "dir": direction}
    for k, a in enumerate(out):
        if a is None:
            raise ValueError(f"endpoint {name}: member {k} has no connection")
    return out


def pack_config(cfg):
    """Expand a FlooNoC-shaped config into (bases, entries).

    bases:   {dst_id: base} for the memory space only -- gen_test_patterns.py
             and gen_tb_top.py want the node's data-class base, not a config
             aperture.
    entries: ordered [{"x", "y", "size", "base", "dst_id", "space", "port"}, ...].

    Each endpoint with address ranges contributes SAM rules.
    """
    if cfg.get("routing", {}).get("use_id_table", True) is not True:
        raise ValueError("routing.use_id_table must be true; offset decode is deferred")
    x_dim, y_dim = router_array(cfg)
    entries = []
    for ep in cfg["endpoints"]:
        if not ep.get("addr_range"):
            continue
        num = members(ep)
        attach = attachments(cfg, ep["name"], num, x_dim)
        for r in ep["addr_range"]:
            base, size = int(r["base"]), int(r["size"])
            stride = int(r["stride"]) if r.get("stride") is not None else size
            space = r.get("space", "memory")
            # Spelled out rather than tested against SPACE_ORDER: that constant
            # is the tile crossbar's TARGET order, and reordering the targets
            # must not change which spaces a range may declare.
            if space not in ("config", "memory", "peripheral"):
                raise ValueError(
                    f"endpoint {ep['name']}: space {space!r} is not a declared space")
            # Same rule as SamTable::validate (addr_trans.hpp): a zero or
            # misaligned size aborts at simulation load, but a NEGATIVE one only
            # trips there by accident, through the base+size overflow assert.
            # Refused here so the generators reject the config they packed from.
            if size <= 0 or size % 0x1000 != 0:
                raise ValueError(
                    f"endpoint {ep['name']}: range size {size:#x} must be positive "
                    f"and 4 KB aligned")
            for k in range(num):
                x, y, port = attach[k]["x"], attach[k]["y"], attach[k]["port"]
                if not (x < x_dim and y < y_dim):
                    raise ValueError(
                        f"endpoint {ep['name']}: member {k} outside mesh {x_dim}x{y_dim}")
                entries.append({"x": x, "y": y, "size": size, "base": base + stride * k,
                                "dst_id": dst_id(x, y), "space": space, "port": port,
                                "en_collective": r.get("en_collective", False) is True})
    bases = {e["dst_id"]: e["base"] for e in entries if e["space"] == "memory" and e["port"] == 0}
    return bases, entries


def node_windows(entries, node_id, port):
    """One endpoint's own region per space, in SPACE_ORDER, present spaces only.

    Keyed on (node_id, port), not on node_id alone: a peripheral shares its host
    router's coordinate and is told apart by the boundary port it hangs off, so
    matching the coordinate alone would stamp a peripheral's window into that
    router's crossbar decode as if it were the tile's. Port 0 is the tile on the
    router's LOCAL port and takes the config and memory windows; a peripheral
    port takes its own single window.

    This is what the tile crossbar decodes on: a request that reached this
    endpoint -- either from its own initiator or from the fabric -- names an
    address in one of these ranges, or it is not this endpoint's. The NSU
    rewrites an arriving address's node-coordinate field to this node before the
    crossbar sees it (nsu::Depacketize::rebase_), so a collective replica
    carrying the request's own address lands here like any unicast.

    Sizes are exact, not rounded: pulp axi_xbar states a rule as start/end, so
    a window need not be a power of two.

    Returns [{"space", "base", "size"}, ...].
    """
    out = []
    for space in SPACE_ORDER:
        for e in entries:
            if (e["dst_id"] == node_id and e.get("port", 0) == port
                    and e.get("space", "memory") == space):
                out.append({"space": space, "base": e["base"], "size": e["size"]})
                break
    return out


def noc_egress_base(entries):
    """Base of the tile crossbar's NoC egress aperture.

    A collective write names a SET of nodes, so "is this address mine" has no
    answer -- but a tile crossbar decodes addresses and nothing else. A
    collective whose address names the issuing node's own region would be
    answered locally and never reach the NI, and the fabric would never
    replicate it.
    The endpoint offsets such a write into this aperture, which the crossbar
    has a rule for pointing at the NI, and takes the offset back off on the way
    out (user_node_endpoint.sv).

    Derived from the map, never declared: the first power of two at or above
    the top of the map. Every node window therefore sits below it by
    construction, so the aperture cannot collide with a real region however the
    map grows -- which a hand-picked spare address bit could not promise.
    """
    top = max(e["base"] + e["size"] for e in entries)
    base = 0x1000
    while base < top:
        base <<= 1
    return base
