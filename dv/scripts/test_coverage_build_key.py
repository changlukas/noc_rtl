"""Canonical source and generated configuration invalidate the build cache."""
import json
from pathlib import Path
from build_key import materialize


def setup_recipe(root):
    for name in ('dv/config/profile.yml','dv/config/topology.yml','rtl/dut.sv',
                 'deps/common_cells-v2.0.0-beta.3/src/cc_fifo.sv'):
        p=root/name
        p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text('')
    recipe=dict(profile_path='dv/config/profile.yml',profile_text='',topology_path='dv/config/topology.yml',topology_text='',
        filelist=['rtl/dut.sv','deps/common_cells-v2.0.0-beta.3/src/cc_fifo.sv'],includes=[],
        generated={'ni_tb_params.svh':'localparam int NI_R_ROB_EN = 1;\n'},coverage_hier='')
    path=root/'recipe.json'
    path.write_text(json.dumps(recipe))
    return path,recipe


def test_coverage_hierarchy_invalidates_only_coverage_build(tmp_path):
    path,recipe=setup_recipe(tmp_path)
    normal=materialize(tmp_path,path,'')
    coverage=materialize(tmp_path,path,'',True)
    recipe['coverage_hier']='+tree tb_top.dut 0\n'
    path.write_text(json.dumps(recipe))
    assert materialize(tmp_path,path,'')==normal
    assert materialize(tmp_path,path,'',True)!=coverage


def test_hardware_include_changes_sv_key(tmp_path):
    path,recipe=setup_recipe(tmp_path)
    original=materialize(tmp_path,path,'')
    recipe['generated']['ni_tb_params.svh']='localparam int NI_R_ROB_EN = 0;\n'
    path.write_text(json.dumps(recipe))
    assert materialize(tmp_path,path,'')!=original
    # Old retained build trees must not participate in hashing or recursive inputs.
    retained=tmp_path/'build/sim/stage/repo/old.sv'
    retained.parent.mkdir(parents=True)
    retained.write_text('old snapshot')
    before=materialize(tmp_path,path,'')
    retained.write_text('unrelated history')
    assert materialize(tmp_path,path,'')==before
    (tmp_path/'rtl/dut.sv').write_text('module dut; endmodule')
    assert materialize(tmp_path,path,'')!=before
