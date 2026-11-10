#!/usr/bin/env python3
"""Synchronize manifest-owned sources, rejecting divergent workstation edits."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

REMOTE=r'''import base64,hashlib,json,os,re,sys
payload=json.load(sys.stdin)
root=os.path.realpath(payload['root'])
manifest=os.path.join(root,'build/source-SHA256SUMS')
previous={}
if os.path.isfile(manifest):
    for line in open(manifest):
        digest,name=line.rstrip('\n').split('  ',1)
        previous[name]=digest

def target(name):
    path=os.path.realpath(os.path.join(root,name))
    if not path.startswith(root+os.sep):
        raise RuntimeError('Sync path escapes checkout: '+name)
    return path

def read(path):
    with open(path,'rb') as stream:
        return stream.read().replace(b'\r\n',b'\n')

pending=[]
conflicts=[]
for entry in payload['files']:
    name=entry['path']
    path=target(name)
    data=base64.b64decode(entry['data'])
    if hashlib.sha256(data).hexdigest()!=entry['sha256']:
        raise RuntimeError('Transfer checksum mismatch: '+name)
    if os.path.isfile(path):
        current=read(path)
        # This is the user's workstation-local selection, not a Make override.
        if name=='define/noc_unit_params_pkg.sv':
            value=re.search(rb'(\bFIFO_TYPE\s*=\s*)([01])',current)
            if value:
                data=re.sub(rb'(\bFIFO_TYPE\s*=\s*)[01]',lambda m:m.group(1)+value.group(2),data)
        if name=='sim/environment.mk':
            data=current
        digest=hashlib.sha256(current).hexdigest()
        if current!=data and digest not in [previous.get(name)]+entry.get('baseline',[]):
            conflicts.append(dict(path=name,sha256=digest))
    pending.append((name,path,data))
if conflicts:
    print('NOC_SYNC_CONFLICTS='+json.dumps(conflicts))
    raise RuntimeError('Preflight rejected divergent files; no files were changed')
updated=0
for name,path,data in pending:
    if not os.path.isfile(path) or open(path,'rb').read()!=data:
        os.makedirs(os.path.dirname(path),exist_ok=True)
        with open(path,'wb') as stream:
            stream.write(data)
        os.chmod(path,0o644)
        updated+=1
retained=[]
removed=0
for name in payload.get('retired',[]):
    path=target(name)
    if os.path.isfile(path):
        digest=hashlib.sha256(read(path)).hexdigest()
        if digest in [previous.get(name)]+payload.get('baseline',{}).get(name,[]):
            archive=target('build/sync-backup/'+digest+'/'+name)
            os.makedirs(os.path.dirname(archive),exist_ok=True)
            with open(archive,'wb') as stream:
                stream.write(open(path,'rb').read())
            os.unlink(path)
            removed+=1
        else:
            retained.append(name)
os.makedirs(os.path.dirname(manifest),exist_ok=True)
with open(manifest,'w') as stream:
    for name,path,data in sorted(pending):
        if read(path)!=data:
            raise RuntimeError('Readback mismatch: '+name)
        stream.write(hashlib.sha256(data).hexdigest()+'  '+name+'\n')
print('NOC_SYNC_RESULT='+json.dumps(dict(root=root,updated=updated,verified=len(pending),removed=removed,retained_modified=retained)))
'''


def payload(source):
    source=Path(source).resolve()
    names=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','--',
        'define','rtl','deps','dv','sim','Makefile','.gitignore'],cwd=source).decode().splitlines()
    names=[n for n in names if (source/n).is_file() and not any(p.startswith('.') for p in Path(n).parts[:-1])]
    generated=list((source/'build/compile/recipes').glob('*'))
    single=source/'build/regression/single'
    generated += [p for p in single.rglob('*') if p.is_file() and 'results' not in p.relative_to(single).parts]
    direct=source/'build/regression/single_direct'
    generated += [p for p in direct.rglob('*') if p.is_file() and 'results' not in p.relative_to(direct).parts]
    latest=source/'build/regression/latest.json'
    if latest.is_file():
        generated.append(latest)
        campaign=source/json.loads(latest.read_text())['campaign']
        generated += [p for p in campaign.iterdir() if p.is_file() and p.name not in
                      ('results.json', 'execution.json', 'coverage-tests.txt', 'passed-tests.txt')]
        generated += [p for p in (campaign/'inputs').rglob('*') if p.is_file()]
    names += [p.relative_to(source).as_posix() for p in generated]
    baseline={}
    # Known pre-migration contents permit safe upgrades, never arbitrary remote bytes.
    old=source/'build/sim/stage/SHA256SUMS'
    if old.is_file():
        for line in old.read_text().splitlines():
            digest,name=line.split('  ',1)
            name=name[5:] if name.startswith('repo/') else name
            if name.startswith(('define/','rtl/','deps/')):
                baseline.setdefault(name,[]).append(digest)
    supplied=source/'build/source-migration-baseline.json'
    if supplied.is_file():
        for name,digests in json.loads(supplied.read_text()).items():
            baseline.setdefault(name,[]).extend(digests)
    retired=subprocess.check_output(['git','ls-files','--deleted'],cwd=source).decode().splitlines()
    tracked = subprocess.check_output(['git','ls-tree','-r','HEAD'],cwd=source).decode().splitlines()
    blobs = {line.split('\t',1)[1]:line.split()[2] for line in tracked}
    known = [name for name in sorted(set(names+retired)) if name in blobs]
    raw = subprocess.check_output(['git','cat-file','--batch'],cwd=source,input=''.join(blobs[name]+'\n' for name in known).encode())
    offset=0
    for name in known:
        end=raw.index(b'\n',offset)
        size=int(raw[offset:end].split()[-1])
        data=raw[end+1:end+1+size].replace(b'\r\n',b'\n')
        baseline.setdefault(name,[]).append(hashlib.sha256(data).hexdigest())
        offset=end+size+2
    entries=[]
    for name in sorted(set(names)):
        data=(source/name).read_bytes().replace(b'\r\n',b'\n')
        entries.append(dict(path=name,sha256=hashlib.sha256(data).hexdigest(),data=base64.b64encode(data).decode(),baseline=baseline.get(name,[])))
    return dict(files=entries,retired=retired,baseline=baseline)


def sync(source,host,remote_dir,ssh,key):
    transfer=payload(source)
    transfer['root']=remote_dir
    code=base64.b64encode(REMOTE.encode()).decode()
    command='python3 -B -c "import base64;exec(base64.b64decode(\''+code+'\'))"'
    result=subprocess.run([ssh,'-i',key,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',host,command],
        input=json.dumps(transfer).encode(),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
    output=result.stdout.decode(errors='replace')
    for line in output.splitlines():
        if line.startswith('NOC_SYNC_'):
            print(line)
    if result.returncode or 'NOC_SYNC_RESULT=' not in output:
        raise RuntimeError(output)


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--source',required=True)
    p.add_argument('--host',default=os.environ.get('REMOTE_HOST','mingwei@172.16.16.16'))
    p.add_argument('--remote-dir',default='/home/mingwei/noc_rtl')
    p.add_argument('--ssh',default=os.environ.get('SSH','ssh'))
    p.add_argument('--key',default=os.environ.get('SSH_KEY',str(Path.home()/'.ssh/noc_workstation_ed25519')))
    a=p.parse_args()
    sync(a.source,a.host,a.remote_dir,a.ssh,a.key)
