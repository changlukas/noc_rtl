#!/usr/bin/env python3
"""Generate DV build recipes and inputs; canonical RTL/DV sources stay in the checkout."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
from gen_tb_top import emit_sam_pkg, num_vc, native_param
from gen_standalone_patterns import generate as generate_patterns, load_cases


def write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = text.replace("\r\n", "\n").encode("utf-8")
    if not path.is_file() or path.read_bytes() != data:
        path.write_bytes(data)


def recipe_path(profile_path, direct=False):
    return ROOT / "build/compile/recipes" / (Path(profile_path).name + (".direct" if direct else "") + ".json")


def attach_hardware(recipe, patterns):
    header = recipe["generated"]["ni_tb_params.svh"]
    for manifest in Path(patterns).rglob("manifest.json"):
        write_text(manifest.parent / "ni_tb_params.svh", header)


def selected_topology(topology_path, direct):
    default = "dv/config/topology.yml" if direct else "dv/config/topology/mesh_4x4.yml"
    return Path(topology_path or ROOT / default).resolve()


def topology_package(topo):
    import yaml
    return emit_sam_pkg(yaml.safe_load(topo.read_text()))


def prepare(out, profile_path=None, extra_catalog=None, direct=False, topology_path=None, patterns=True):
    import yaml
    profile_path = Path(profile_path or ROOT / "dv/config/profile.yml").resolve()
    profile = yaml.safe_load(profile_path.read_text())
    native_id_width = native_param("noc_payload_pkg", "AXI_ID_WIDTH")
    noc_id_width = profile.get("output_id_width", native_id_width)
    pattern_id_width = profile.get("input_id_width", noc_id_width)
    device_id_width = profile.get("device_id_width", noc_id_width)
    if type(noc_id_width) is not int or noc_id_width != native_id_width:
        raise ValueError("output_id_width must match native AXI_ID_WIDTH")
    if any(type(v) is not int or not 1 <= v <= 8 for v in (pattern_id_width, device_id_width)):
        raise ValueError("Source and device ID widths must be in [1, 8]")
    if pattern_id_width > noc_id_width:
        raise ValueError("NoC output_id_width must preserve input_id_width")
    vc_count = profile.get("num_dat_vc", num_vc())
    if "dat_vc_mode" in profile or type(vc_count) is not int or vc_count != num_vc():
        raise ValueError("DAT classes must match native DAT_NUM_VC")
    for key in ("context_depth", "io_fifo_depth", "max_outstanding_per_id", "b_rob_depth", "r_rob_depth"):
        value = profile.get(key, 2)
        if type(value) is not int or value < 1 or value & (value-1):
            raise ValueError(key + " must be a positive power of two")
    if profile.get("io_fifo_depth", 32) < 2:
        raise ValueError("io_fifo_depth must be at least 2")
    if profile.get("reg_type", 0) not in (0, 1, 2) or profile.get("r_rob_en", 1) not in (0, 1):
        raise ValueError("invalid register or read ROB mode")
    # Archived measurement profiles used the old name for this FIFO capacity.
    depth = profile.get("dat_rx_fifo_depth", profile.get("credit_depth", native_param("noc_unit_params_pkg", "DAT_RX_FIFO_DEPTH")))
    if type(depth) is not int or depth < 2 or depth & (depth-1):
        raise ValueError("DAT input FIFO depth must be a power of two >= 2")
    topo = selected_topology(topology_path, direct)
    parameters = dict(
        INPUT_ID_WIDTH=pattern_id_width, OUTPUT_ID_WIDTH=noc_id_width,
        DEVICE_ID_WIDTH=device_id_width, CONTEXT_DEPTH=profile.get("context_depth", 32),
        IO_FIFO_DEPTH=profile.get("io_fifo_depth", 32), OUTPUT_REG_TYPE=profile.get("reg_type", 0),
        MAX_OUTSTANDING_PER_ID=profile.get("max_outstanding_per_id", 32),
        B_ROB_DEPTH=profile.get("b_rob_depth", native_param("noc_unit_params_pkg", "NMU_ROB_B_DEPTH")),
        R_ROB_DEPTH=profile.get("r_rob_depth", native_param("noc_unit_params_pkg", "NMU_ROB_R_DEPTH")),
        R_ROB_EN=profile.get("r_rob_en", native_param("noc_unit_params_pkg", "NMU_R_ROB_EN")),
        NUM_DAT_VC=vc_count, DAT_VC_MODE=int(vc_count > 1), DAT_RX_FIFO_DEPTH=depth,
        DIRECT_LINK=int(direct), MON_ID_WIDTH=max(pattern_id_width, device_id_width))
    lines = (ROOT / "dv/filelists/rtl.f").read_text().splitlines()
    includes = [line[len("+incdir+"):] for line in lines if line.startswith("+incdir+")]
    for name in ("cc_onehot_to_bin.sv", "cc_lzc.sv", "cc_id_queue.sv"):
        lines.append("deps/common_cells-v2.0.0-beta.3/src/"+name)
    lines += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / "rtl/nsu").rglob("*.sv")) if not p.name.startswith("tb_")]
    lines += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / "rtl/ni").glob("*.sv"))]
    lines.append("deps/floonoc-dv/axi_reorder_compare.sv")
    includes += ["deps/floonoc-dv", "dv/tb", "dv/env", "dv/env/seq_lib", "dv/tests", "dv/coverage", "dv/checkers"]
    for dependency, package in (("tue", "tue_pkg.sv"), ("tvip-common", "tvip_common_pkg.sv"), ("tvip-axi", "tvip_axi_pkg.sv")):
        includes.append("deps/"+dependency+"/src")
        lines.append("deps/"+dependency+"/src/"+package)
    lines += ["dv/tb/ni_noc_if.sv", "dv/tb/ni_tb_if.sv", "dv/env/ni_test_pkg.sv", "dv/tb/tb_top.sv"]
    if not direct:
        lines += ["dv/coverage/router_coverage.sv", "dv/tb/router_mesh.sv"]
        lines += [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / "rtl/router").glob("*.sv"))]
    else:
        lines.append("dv/tb/standalone/nsu/ni_direct_link.sv")
    lines.append("dv/checkers/ni_arbiter_checks.sv")
    coverage = (ROOT / "dv/config/coverage.hier").read_text()
    if direct:
        coverage = "+module tb_top\n+tree tb_top.dut 0\n" + "".join("+tree tb_top.gen_node[%d].i_nsu 0\n" % n for n in range(4))
    generated = {"topology_pkg.sv": topology_package(topo),
        "ni_tb_params.svh": "".join("localparam int NI_{:<26} = {};\n".format(k,v) for k,v in parameters.items())}
    recipe = dict(commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT).decode().strip(), profile=profile, profile_path=profile_path.relative_to(ROOT).as_posix(),
        profile_text=profile_path.read_text(), topology_path=topo.relative_to(ROOT).as_posix(),
        topology_text=topo.read_text(), parameters=parameters, direct=direct,
        filelist=lines, includes=list(dict.fromkeys(includes)), generated=generated, coverage_hier=coverage)
    target = recipe_path(profile_path, direct)
    write_text(target, json.dumps(recipe, indent=2)+"\n")
    write_text(target.with_suffix(".mk"), "".join(
        ("REG_TYPE" if k=="OUTPUT_REG_TYPE" else k)+" ?= "+str(v)+"\n"
        for k,v in parameters.items() if k not in ("MON_ID_WIDTH", "DIRECT_LINK", "DAT_VC_MODE")))
    out = Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    write_text(out / "profile.yml", recipe["profile_text"])
    write_text(out / "topology.yml", recipe["topology_text"])
    write_text(out / "ni_tb_params.svh", generated["ni_tb_params.svh"])
    if patterns:
        prepare_patterns(out, profile, topo, pattern_id_width, direct, extra_catalog, recipe)
    return recipe


def prepare_patterns(out, profile, topo, pattern_id_width, direct, extra_catalog, recipe):
    patterns = out / "inputs"
    hardware = dict(response_fifo_depth=profile.get("io_fifo_depth", 32),
                    context_depth=profile.get("context_depth", 32))
    def generate(*args, **kwargs):
        return generate_patterns(*args, hardware=hardware, **kwargs)
    cases = generate(patterns, topo, id_width=pattern_id_width, profile="cosim")
    cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim",
                      catalog="cosim")
    if not direct:
        cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim",
                          catalog="router")
        cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim", catalog="mesh")
    if extra_catalog:
        cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim", catalog=extra_catalog)
    (patterns / "cases.list").write_text("\n".join(cases) + "\n")
    stress_catalog = "stress"
    cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim", catalog=stress_catalog)
    (patterns / "cases.list").write_text("\n".join(cases) + "\n")
    common_cases = [case["name"] for case in load_cases("base")
        if not (case.get("reset_warmup") or case.get("legacy_mixed") or case.get("require_stall"))]
    common_cases += [case["name"] for case in load_cases(stress_catalog)]
    if not direct:
        common_cases += [c["name"] for c in load_cases("router")]
        common_cases += [c["name"] for c in load_cases("mesh")]
    (out / "pattern.txt").write_text("\n".join(common_cases) + "\n")
    for mode in ("control", "data", "rand"):
        mode_cases = generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode)
        mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                               catalog="cosim")
        mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                               catalog=stress_catalog)
        if not direct:
            mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                                   catalog="router")
            mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode, catalog="mesh")
        (patterns / mode / "cases.list").write_text("\n".join(mode_cases) + "\n")
    variants = load_cases(stress_catalog)[:1]
    variants = [dict(variants[0], name="capacity_reuse_"+target, capacity_target=target)
                for target in ("per_id", "context", "rob")]
    base_cases = load_cases("base")
    variants += [dict(case, name=case["name"]+"_backpressure", count=64,
                     source_response_hold_cycles=4096 if case.get("require_buffered") else 1024,
                     response_hold_cycles=256 if case.get("require_buffered") else 0, response_hold_port=1,
                     response_backpressure=True)
                 for case in base_cases if case["name"] in ("single_id_reorder", "multi_id_out_of_order")]
    variant_catalog = out / "stress-variants.json"
    variant_catalog.write_text(json.dumps(dict(cases=variants), indent=2)+"\n")
    for mode in ("auto", "control", "data", "rand"):
        directory = patterns if mode == "auto" else patterns / mode
        existing = (directory / "cases.list").read_text().split()
        extra = generate(directory, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                         catalog=variant_catalog)
        (directory / "cases.list").write_text("\n".join(existing+extra)+"\n")
    attach_hardware(recipe, patterns)
    write_text(out / "pattern.txt", "\n".join(common_cases)+"\n")


if __name__ == "__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--out", default=str(ROOT / "build/regression/single"))
    p.add_argument("--profile", default=str(ROOT / "dv/config/profile.yml"))
    p.add_argument("--extra-catalog")
    p.add_argument("--topology")
    p.add_argument("--direct", action="store_true")
    p.add_argument("--emit-sam", metavar="FILE", help="Generate the simulation topology package at FILE")
    args=p.parse_args()
    if args.emit_sam:
        write_text(args.emit_sam, topology_package(selected_topology(args.topology, args.direct)))
    else:
        prepare(args.out, args.profile, args.extra_catalog, topology_path=args.topology, direct=args.direct)
    print(args.emit_sam or args.out)
