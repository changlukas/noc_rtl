#!/usr/bin/env python3
"""Prepare co-simulation sources using the existing standalone RTL dependency list."""
import argparse
import hashlib
from pathlib import Path
import shutil
import json
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sim/tools"))
from gen_tb_top import emit_sam_pkg, num_vc
from gen_standalone_patterns import generate as generate_patterns


def prepare(rtl_stage, out, profile_path=None, extra_catalog=None, direct=False):
    rtl_stage, out = Path(rtl_stage).resolve(), Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    profile = yaml.safe_load(Path(profile_path or ROOT / "sim/profile.yml").read_text())
    noc_id_width = profile.get("output_id_width", 3)
    # Wrapper records use the generated AXI width; NMU external width can be overridden separately.
    pattern_id_width = profile.get("input_id_width", noc_id_width)
    if type(noc_id_width) is not int or not 1 <= noc_id_width <= 8:
        raise ValueError("output_id_width must be in [1, 8]")
    if type(pattern_id_width) is not int or not 1 <= pattern_id_width <= 8:
        raise ValueError("input_id_width must be in [1, 8]")
    device_id_width = profile.get("device_id_width", noc_id_width)
    if type(device_id_width) is not int or not 1 <= device_id_width <= 8:
        raise ValueError("device_id_width must be in [1, 8]")
    if pattern_id_width > noc_id_width:
        raise ValueError("NoC output_id_width must preserve input_id_width")
    vc_count = profile.get("num_dat_vc", num_vc())
    vc_mode = profile.get("dat_vc_mode", 0)
    if vc_count not in (1, 2, 4, 8) or vc_mode not in (0, 1) or (vc_mode == 1 and vc_count < 2):
        raise ValueError("invalid DAT VC count/mode")
    for key in ("context_depth", "io_fifo_depth", "max_outstanding_per_id", "b_rob_depth", "r_rob_depth"):
        if key in profile:
            value = profile[key]
            if type(value) is not int or value < 1 or value & (value - 1):
                raise ValueError(key + " must be a positive power of two")
    if profile.get("io_fifo_depth", 32) < 2:
        raise ValueError("io_fifo_depth must be at least 2 for CDC")
    if profile.get("reg_type", 0) not in (0, 1, 2) or profile.get("r_rob_en", 1) not in (0, 1):
        raise ValueError("invalid register or read ROB mode")
    source_list = []
    def copy(source, relative):
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != source.read_bytes():
            shutil.copyfile(source, target)
    for line in (rtl_stage / "files.f").read_text().splitlines():
        if line.startswith("+define+"):
            source_list.append(line)
            continue
        if line.startswith("+incdir+"):
            relative = line[len("+incdir+"):]
            source = ROOT / relative[5:] if relative.startswith("repo/") else rtl_stage / relative
            for path in source.rglob("*"):
                if path.is_file():
                    copy(path, str(Path(relative) / path.relative_to(source)))
            source_list.append(line)
            continue
        flag = "-v " if line.startswith("-v ") else ""
        relative = line[len(flag):]
        if Path(relative).name in ("tb_nmu_standalone.sv", "tb_nmu_elaborate.sv"):
            continue
        if Path(relative).name == "topology_pkg.sv":
            source_list.append("topology_pkg.sv")
            continue
        source = ROOT / relative[5:] if relative.startswith("repo/") else rtl_stage / relative
        copy(source, relative)
        source_list.append(flag + relative)
    nsu_sources = [ROOT / "deps/common_cells-v2.0.0-beta.3/src" / name
                   for name in ("cc_onehot_to_bin.sv", "cc_lzc.sv", "cc_id_queue.sv")]
    nsu_sources += sorted(path for path in (ROOT / "rtl/nsu").rglob("*.sv")
                          if not path.name.startswith("tb_"))
    for source in nsu_sources:
        relative = str(source.relative_to(ROOT))
        copy(source, "repo/" + relative)
        source_list.append("repo/" + relative)
    for relative in (f"specgen/generated/sv/noc_types_pkg_vc{vc_count}.sv",
                     "ref_model/top/router_wrap.sv", "ref_model/top/nsu_wrap.sv",
                     "deps/common_cells-1.37.0/src/delta_counter.sv",
                     "deps/common_cells-1.37.0/src/counter.sv",
                     "deps/common_cells-1.37.0/src/stream_delay.sv",
                     "deps/common_cells-1.37.0/src/lfsr_16bit.sv",
                     "deps/axi-0.39.7/src/axi_delayer.sv",
                     "deps/axi-0.39.7/src/axi_sim_mem.sv",
                     "deps/floonoc-dv/axi_reorder_compare.sv",
                     "sim/tb_top.sv"):
        if direct and relative.startswith("ref_model/top/"):
            continue
        copy(ROOT / relative, "repo/" + relative)
        source_list.append("repo/" + relative)
    copy(ROOT / "sim/dv/ni_stress.svh", "repo/sim/dv/ni_stress.svh")
    copy(ROOT / "sim/dv/ni_coverage.svh", "repo/sim/dv/ni_coverage.svh")
    copy(ROOT / "sim/dv/ni_resource_coverage.sv", "repo/sim/dv/ni_resource_coverage.sv")
    copy(ROOT / "sim/dv/ni_arbiter_checks.sv", "repo/sim/dv/ni_arbiter_checks.sv")
    source_list.append("repo/sim/dv/ni_arbiter_checks.sv")
    source_list += ["+incdir+repo/sim/dv", "repo/sim/dv/ni_resource_coverage.sv"]
    copy(ROOT / "sim/script/coverage.hier", "coverage.hier")
    if direct:
        relative = "sim/standalone/nsu/ni_direct_link.sv"
        copy(ROOT / relative, "repo/" + relative)
        source_list.append("repo/" + relative)
    for relative in (
        "sim/dv/tb_axi_reorder_compare.sv",
        "rtl/common/tests/tb_axi_id_remap.sv",
        "rtl/common/tests/nmu_id_remap_fixture.sv",
        "deps/axi-0.39.7/src/axi_id_remap.sv",
        "rtl/nmu/ordering/tb_ordering.sv",
        "rtl/nmu/request_packetize/request_inject_tb_dut.sv",
        "rtl/nmu/request_packetize/tb_request_packetize.sv",
        "rtl/nmu/request_packetize/tb_request_packetize_stall.sv",
        "rtl/nmu/request_packetize/tb_request_packetize_stress.sv",
        "rtl/nmu/response_depacketize/tb_response_depacketize.sv",
    ):
        copy(ROOT / relative, "repo/" + relative)
    for path in (ROOT / "deps/floonoc-dv").rglob("*"):
        if path.is_file() and path.suffix != ".sv":
            copy(path, "repo/" + str(path.relative_to(ROOT)))
    topo = ROOT / "sim/topology.yml"
    (out / "topology_pkg.sv").write_text(emit_sam_pkg(yaml.safe_load(topo.read_text())))
    (out / "files.f").write_text("\n".join(source_list) + "\n")
    patterns = (out / "generated_patterns") if profile_path else ROOT / f"sim/test_patterns/cosim/generated/i{pattern_id_width}"
    hardware = dict(response_fifo_depth=profile.get("io_fifo_depth", 32),
                    context_depth=profile.get("context_depth", 32))
    def generate(*args, **kwargs):
        return generate_patterns(*args, hardware=hardware, **kwargs)
    cases = generate(patterns, topo, id_width=pattern_id_width, profile="cosim")
    cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim",
                      catalog=ROOT / "sim/test_patterns/cosim/cases.json")
    if extra_catalog:
        cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim", catalog=extra_catalog)
    (patterns / "cases.list").write_text("\n".join(cases) + "\n")
    stress_catalog = ROOT / "sim/test_patterns/stress/cases.json"
    cases += generate(patterns, topo, id_width=pattern_id_width, profile="cosim", catalog=stress_catalog)
    (patterns / "cases.list").write_text("\n".join(cases) + "\n")
    common_cases = [case["name"] for case in json.loads(
        (ROOT / "sim/test_patterns/standalone/cases.json").read_text())["cases"]
        if not (case.get("reset_warmup") or case.get("legacy_mixed") or case.get("require_stall"))]
    common_cases += [case["name"] for case in json.loads(stress_catalog.read_text())["cases"]]
    (out / "pattern.txt").write_text("\n".join(common_cases) + "\n")
    for mode in ("control", "data", "rand"):
        mode_cases = generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode)
        mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                               catalog=ROOT / "sim/test_patterns/cosim/cases.json")
        mode_cases += generate(patterns / mode, topo, id_width=pattern_id_width, profile="cosim", mode=mode,
                               catalog=stress_catalog)
        (patterns / mode / "cases.list").write_text("\n".join(mode_cases) + "\n")
    variants = json.loads(stress_catalog.read_text())["cases"][:1]
    variants = [dict(variants[0], name="capacity_reuse_"+target, capacity_target=target)
                for target in ("per_id", "context", "rob")]
    base_cases = json.loads((ROOT / "sim/test_patterns/standalone/cases.json").read_text())["cases"]
    variants += [dict(case, name=case["name"]+"_backpressure", count=64, source_response_hold_cycles=1024,
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
    for path in patterns.rglob("*"):
        if path.is_file():
            copy(path, str(Path("patterns") / path.relative_to(patterns)))
    for name in ("signals.rc", "topology.yml", "README.md", "pattern_list.txt"):
        copy(ROOT / "sim" / name, name)
    if not direct:
        for directory in ("ref_model/dpi", "ref_model/c_model/include", "ref_model/c_model/tests/common",
                          "specgen/generated/cpp"):
            for path in (ROOT / directory).rglob("*"):
                if path.is_file():
                    copy(path, "repo/" + str(path.relative_to(ROOT)))
        yaml_source = ROOT / "deps/yaml-cpp"
        for directory in ("include", "src"):
            for path in (yaml_source / directory).rglob("*"):
                if path.is_file():
                    copy(path, "deps/yaml-cpp/" + str(path.relative_to(yaml_source)))
        for path in yaml_source.glob("LICENSE*"):
            copy(path, "deps/yaml-cpp/" + path.name)
    # One profile drives both generated languages and every DAT receiver.
    sys.path.insert(0, str(ROOT / "specgen"))
    constants = yaml.safe_load((ROOT / "specgen/source/constants.yaml").read_text())
    depth = profile["credit_depth"]
    if not isinstance(depth, int) or depth < 2 or depth & (depth - 1):
        raise ValueError("DAT credit depth must be a power of two and at least 2")
    constants["noc"]["CREDIT_DEPTH"]["default"] = depth
    constants["noc"]["DAT_NUM_VC"]["default"] = vc_count
    constants["noc"]["DAT_VC_MODE"]["default"] = vc_mode
    constants["axi"]["AXI_ID_WIDTH"]["default"] = noc_id_width
    # The active RTL NSU selects device width through profile.mk; the Router uses NoC IDs.
    constants["nsu"]["AXI_ID_WIDTH"]["default"] = noc_id_width
    constants["nsu"]["MAX_ACTIVE_IDS"]["default"] = 1 << constants["nsu"]["AXI_ID_WIDTH"]["default"]
    from tools.elaborate.profile import emit as emit_profile
    emit_profile(ROOT, out, constants, noc_id_width)
    (out / "profile.yml").write_text(yaml.safe_dump(profile, sort_keys=False))
    (out / "profile.mk").write_text(f"INPUT_ID_WIDTH ?= {pattern_id_width}\nOUTPUT_ID_WIDTH ?= {noc_id_width}\n")
    with (out / "profile.mk").open("a") as stream:
        for key, symbol in (("device_id_width", "DEVICE_ID_WIDTH"),
                            ("context_depth", "CONTEXT_DEPTH"), ("io_fifo_depth", "IO_FIFO_DEPTH"),
                            ("reg_type", "REG_TYPE"), ("max_outstanding_per_id", "MAX_OUTSTANDING_PER_ID"),
                            ("b_rob_depth", "B_ROB_DEPTH"), ("r_rob_depth", "R_ROB_DEPTH"),
                            ("r_rob_en", "R_ROB_EN")):
            if key in profile:
                stream.write(f"{symbol} ?= {profile[key]}\n")
    (out / "environment.mk").write_text("DIRECT_LINK := %d\n" % int(direct))
    if direct:
        (out / "signals.rc").write_text((out / "signals.rc").read_text().replace("Router Links", "Direct Links"))
    copy(ROOT / "sim/script/Makefile", "Makefile")
    copy(ROOT / "sim/script/run.py", "run.py")
    copy(ROOT / "sim/standalone/common/clean.sh", "clean.sh")
    copy(ROOT / "sim/script/test_pipeline.py", "test_pipeline.py")
    copy(ROOT / "sim/script/test_ordering_checker.py", "test_ordering_checker.py")
    copy(ROOT / "sim/script/build_key.py", "build_key.py")
    for name in ("coverage_plan.json", "coverage_report.py"):
        retired = out / name
        if retired.exists():
            retired.unlink()
    retired = out / "repo/rtl/nmu/request_path/id_remap.sv"
    if retired.exists():
        retired.unlink()
    names = [path for path in out.rglob("*") if path.is_file() and
             path.name != "SHA256SUMS" and "build" not in path.relative_to(out).parts]
    (out / "SHA256SUMS").write_text("".join(
        hashlib.sha256(path.read_bytes()).hexdigest() + "  " +
        str(path.relative_to(out)) + "\n" for path in sorted(names)))
    print(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--rtl-stage", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--extra-catalog")
    args = parser.parse_args()
    prepare(args.rtl_stage, args.out, args.profile, args.extra_catalog)
