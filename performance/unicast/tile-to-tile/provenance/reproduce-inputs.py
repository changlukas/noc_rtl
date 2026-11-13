#!/usr/bin/env python3
"""Reproduce this run's inputs with the snapshotted existing generator."""
from pathlib import Path
import sys,json,tempfile,hashlib
root=Path(__file__).resolve().parents[1]
source=root/'provenance/source'
sys.path.insert(0,str(source/'dv/scripts'))
from gen_standalone_patterns import generate
run=next((root/'runs').iterdir());recipe=json.loads((root/'config/recipe.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
 out=Path(tmp)
 generate(out,root/'config/compiled-sam-entries.json',id_width=recipe['parameters']['INPUT_ID_WIDTH'],catalog='performance_unicast',profile='cosim',seed=1,case_name=run.name,hardware=dict(response_fifo_depth=recipe['parameters']['IO_FIFO_DEPTH']))
 (out/run.name/'ni_tb_params.svh').write_text(recipe['generated']['ni_tb_params.svh'])
 generated=out/run.name; actual=run/'inputs'
 assert sorted(p.name for p in generated.iterdir())==sorted(p.name for p in actual.iterdir())
 for path in generated.iterdir(): assert path.read_bytes()==(actual/path.name).read_bytes(),path.name
 print(run.name,'input reproduction passed')
