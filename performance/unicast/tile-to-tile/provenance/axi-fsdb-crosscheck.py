#!/usr/bin/env python3
"""Offline cross-check of this run's FSDB against accepted AXI events; no simulation."""
from pathlib import Path
import csv,json,subprocess
root=Path(__file__).resolve().parents[1]
run=next((root/'runs').iterdir())
case=run.name
destination={'perf_ctrl_read_neighbor':1,'perf_ctrl_read_h3':3,'perf_ctrl_read_h6':15,'perf_cal_data_read_1kib':1,'perf_cal_data_read_4kib':1}[case]
command=['fsdb2vcd',str(run/(case+'.fsdb')),'-o',str(run/'interfaces.vcd'),'-s','/tb_top','-level','3']
(root/'provenance/fsdb-conversion-command.json').write_text(json.dumps(command,indent=2)+'\n')
with (run/'fsdb2vcd.log').open('w') as log: subprocess.check_call(command,stdout=log,stderr=subprocess.STDOUT,cwd=str(run))
def extract(path, destination):
    """Sample the stable values immediately before each rising AXI clock edge."""
    scope, signals = [], {}
    values = {}
    events = []
    with open(path) as stream:
        header = []
        for line in stream:
            header.append(line)
            fields = line.split()
            if not fields:
                continue
            if fields[0] == '$scope':
                scope.append(fields[2])
            elif fields[0] == '$upscope':
                scope.pop()
            elif fields[0] == '$var':
                signals['.'.join(scope + [fields[4]])] = fields[3]
            elif fields[0] == '$enddefinitions':
                break
        if '1ps' not in ''.join(header):
            raise ValueError('Expected the archived 1ps VCD timescale')
        clock = signals['tb_top.clk']
        reset = signals['tb_top.axi_rst_n']
        prefixes = {
            'source': 'tb_top.gen_node[0].source_bus.',
            'device': 'tb_top.gen_node[%d].device_bus.' % destination,
        }
        def signal(before, role, name):
            code = signals[prefixes[role] + name]
            value = before.get(code, 'x')
            if any(c in value.lower() for c in 'xz'):
                raise ValueError('Unknown sampled ' + role + '.' + name)
            return int(value, 2)

        def sample(time_ps, updates):
            before = values.copy()
            after = dict(before, **updates)
            if before.get(clock) == '0' and after.get(clock) == '1' and before.get(reset) == '1':
                for role in prefixes:
                    for channel in ['aw', 'w', 'b', 'ar', 'r']:
                        valid = channel + 'valid'
                        ready = channel + 'ready'
                        if not (signal(before, role, valid) and signal(before, role, ready)):
                            continue
                        row = dict(time_ps=time_ps, role=role, endpoint=0 if role == 'source' else destination, channel=channel)
                        fields = {'aw': ['id', 'addr', 'len', 'size', 'burst'],
                                  'ar': ['id', 'addr', 'len', 'size', 'burst'],
                                  'w': ['strb', 'last'], 'b': ['id', 'resp'],
                                  'r': ['id', 'resp', 'last']}[channel]
                        for field in fields:
                            key = channel + field
                            row[field] = signal(before, role, key)
                        if channel == 'w':
                            row['useful_bytes'] = bin(row['strb']).count('1')
                        events.append(row)
            values.update(updates)

        time_ps = 0
        updates = {}
        for line in stream:
            text = line.strip()
            if not text or text.startswith('$'):
                continue
            if text.startswith('#'):
                sample(time_ps, updates)
                updates = {}
                time_ps = int(text[1:])
            elif text[0] in 'bB':
                parts = text[1:].split()
                if len(parts) == 2:
                    updates[parts[1]] = parts[0]
            elif text[0] in '01xXzZ':
                updates[text[1:]] = text[0]
        sample(time_ps, updates)
    return events



events=extract(run/'interfaces.vcd',destination)
with (run/'axi-events.csv').open() as f: actual=list(csv.DictReader(f))
actual=[r for r in actual if r['channel'] not in ('RESET','ENABLE','SOURCE_DONE') and ((r['role']=='source' and int(r['endpoint'])==0) or (r['role']=='device' and int(r['endpoint'])==destination))]
# Subscriber callback order between endpoints on the same clock edge is unspecified.
# Compare the same accepted events in a canonical time/interface/channel order.
def event_key(row): return (int(row['time_ps']),row['role'],int(row['endpoint']),row['channel'].lower())
actual.sort(key=event_key)
events.sort(key=event_key)
assert len(actual)==len(events),(len(actual),len(events))
for a,b in zip(actual,events):
 for key,value in b.items():
  if key=='useful_bytes': continue
  observed=a[key]
  if key=='channel': observed=observed.lower()
  elif key!='role': observed=int(observed,16 if key in ('addr','strb') else 10)
  assert observed==value,(key,observed,value,a,b)
(root/'tables/fsdb-events.json').write_text(json.dumps(events,indent=2)+'\n')
v=json.loads((root/'validation.json').read_text());v['offline_calibration_comparison']='passed_against_this_run_FSDB';v['compared_events']=len(events);(root/'validation.json').write_text(json.dumps(v,indent=2)+'\n')
print(case,'FSDB comparison passed',len(events),'events')
