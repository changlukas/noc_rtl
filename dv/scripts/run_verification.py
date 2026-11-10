#!/usr/bin/env python3
"""Run one prepared campaign through the canonical case runner."""
import argparse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess
import sys

p=argparse.ArgumentParser()
p.add_argument('--binary', required=True, type=Path)
p.add_argument('--campaign', required=True, type=Path)
p.add_argument('--jobs', type=int, default=1)
a=p.parse_args()
if a.jobs < 1:
    p.error('jobs must be positive')
campaign=a.campaign.resolve()
binary=a.binary.resolve()
runs=json.loads((campaign/'verification-runs.json').read_text())
report=campaign/'results'
report.mkdir(parents=True, exist_ok=True)
# A campaign is immutable after execution; prepare a new campaign to rerun.
if (campaign/'results.json').exists() or any(report.iterdir()):
    p.error('Campaign already has results; run make prepare for a new campaign')
selection=campaign/'coverage-tests.txt'
prefix=datetime.utcnow().strftime('reg_%Y%m%d_%H%M%S_%f_')
(campaign/'execution.json').write_text(json.dumps(dict(binary=str(binary),
    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
    plan_sha256=hashlib.sha256((campaign/'verification-runs.json').read_bytes()).hexdigest()), indent=2)+'\n')

def run_case(run):
    stimulus=campaign/run['stimulus']
    command=[sys.executable, str(Path(__file__).with_name('run.py')), '--binary', str(binary),
        '--case', run['case'], '--mode', run['mode'], '--seed', str(run['seed']), '--target', run['target'],
        '--inputs', str(stimulus.parent), '--stimulus', str(stimulus), '--campaign', str(campaign),
        '--coverage', '--coverage-name', prefix+run['tag'], '--report', str(report/run['tag'])]
    result=subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    (report/(run['tag']+'.driver.log')).write_text(result.stdout)
    return dict(run, returncode=result.returncode, binary=str(binary), command=command)

results={}
with ThreadPoolExecutor(max_workers=a.jobs) as pool:
    for future in as_completed([pool.submit(run_case,run) for run in runs]):
        result=future.result()
        results[result['tag']]=result
        (campaign/'results.json').write_text(json.dumps([results[r['tag']] for r in runs if r['tag'] in results],indent=2)+'\n')
        print(result['tag'], 'PASS' if result['returncode']==0 else 'FAIL', flush=True)
failed=any(r['returncode'] for r in results.values())
if not failed:
    selection.write_text(''.join(str(binary)+'/'+prefix+r['tag']+'\n' for r in runs))
raise SystemExit(int(failed))
