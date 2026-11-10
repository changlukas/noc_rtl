#!/usr/bin/env python3
"""Materialize a build from canonical sources and a portable generated recipe."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
COMPAT = 'deps/common_cells-v2.0.0-beta.3/src/cc_fifo.sv'


def normalized(path):
    return path.read_bytes().replace(b'\r\n', b'\n')


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.is_file() or path.read_bytes() != data:
        path.write_bytes(data)


def materialize(root, recipe_path, flags, coverage=False):
    root = Path(root).resolve()
    recipe_path = Path(recipe_path).resolve()
    recipe = json.loads(recipe_path.read_text())
    for key in ('profile', 'topology'):
        if normalized(root / recipe[key+'_path']).decode() != recipe[key+'_text']:
            raise ValueError(key+' changed; run make prepare again')
    generated = dict(recipe['generated'])
    if coverage:
        generated['coverage.hier'] = recipe['coverage_hier']
    includes = [root / name for name in recipe['includes']]
    sources = [(line[3:] if line.startswith('-v ') else line) for line in recipe['filelist'] if line and not line.startswith(('+', '#'))]
    contents = {}
    def collect(name):
        if name in contents or name in generated:
            return
        path = root / name
        data = normalized(path)
        contents[name] = data
        for match in re.findall(rb'`include\s+"([^"\n]+)"', data):
            header = match.decode()
            if header in generated or header == 'uvm_macros.svh':
                continue
            candidates = [path.parent / header] + [directory / header for directory in includes]
            found = next((p for p in candidates if p.is_file()), None)
            if found is None:
                raise ValueError('Unresolved include '+header+' in '+name)
            collect(found.relative_to(root).as_posix())
    for name in sources:
        collect(name)
    # The recipe/generator and native source closure determine reuse, never build history.
    for path in (root / 'dv/scripts').glob('*.py'):
        if path.name in ('prepare.py', 'gen_tb_top.py', 'build_key.py', 'address_map.py'):
            contents[path.relative_to(root).as_posix()] = normalized(path)
    if contents[COMPAT] and contents[COMPAT].count(b'FifoDepth[PtrWidth-1:0] - 1') != 2:
        raise ValueError('Pinned cc_fifo wrap expressions changed; review VCS compatibility')
    compat = contents[COMPAT].replace(b'FifoDepth[PtrWidth-1:0] - 1', b"PtrWidth'(FifoDepth - 1)")
    generated['cc_fifo.sv'] = compat.decode()
    descriptor = dict(recipe=recipe, flags=flags, coverage=coverage)
    if not coverage:
        descriptor['recipe'] = dict(recipe)
        descriptor['recipe'].pop('coverage_hier', None)
    digest = hashlib.sha256(json.dumps(descriptor, sort_keys=True).encode())
    for name, data in sorted(contents.items()):
        digest.update(name.encode()+b'\0'+data)
    build = root / 'build/compile' / digest.hexdigest()[:12]
    for name, data in generated.items():
        write(build / name, data.encode())
    lines = ['+incdir+'+str(build)]
    lines += ['+incdir+'+str(directory) for directory in includes]
    for line in recipe['filelist']:
        if not line or line.startswith('#') or line.startswith('+incdir+'):
            continue
        prefix = '-v ' if line.startswith('-v ') else ''
        if prefix:
            line = line[3:]
        if line == COMPAT:
            line = str(build / 'cc_fifo.sv')
        elif not line.startswith('+'):
            line = str(build / line) if line in generated else str(root / line)
        lines.append(prefix+line)
    write(build / 'files.f', ('\n'.join(lines)+'\n').encode())
    manifest = ''.join(hashlib.sha256(data).hexdigest()+'  '+name+'\n' for name,data in sorted(contents.items()))
    manifest += ''.join(hashlib.sha256(text.encode()).hexdigest()+'  @generated/'+name+'\n' for name,text in sorted(generated.items()))
    write(build / 'SHA256SUMS', manifest.encode())
    try:
        commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=str(root), stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.CalledProcessError):
        commit = recipe.get("commit")
    descriptor.update(commit=commit, build_id=build.name, source_root=str(root),
                      source_manifest_sha256=hashlib.sha256(manifest.encode()).hexdigest())
    if not (build / 'compile-success.json').is_file():
        write(build / 'config.json', (json.dumps(descriptor,indent=2)+'\n').encode())
    return build


def file_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def finish_compile(build):
    record = dict(sha256={name:file_hash(build/name) for name in
        ('simv', 'config.json', 'SHA256SUMS', 'compile-command.txt')})
    write(build/'compile-success.json', (json.dumps(record,indent=2)+'\n').encode())


def valid_compile(build):
    try:
        record=json.loads((build/'compile-success.json').read_text())
        return all(file_hash(build/name)==digest for name,digest in record['sha256'].items())
    except (OSError, ValueError, KeyError):
        return False


def campaign_binary(campaign):
    record=json.loads((campaign/'execution.json').read_text())
    binary=Path(record['binary'])
    if file_hash(binary)!=record['binary_sha256'] or not valid_compile(binary.parent):
        raise ValueError('Campaign binary or compile provenance changed')
    return binary


if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--recipe', type=Path)
    p.add_argument('--flags', default='')
    p.add_argument('--coverage', action='store_true')
    p.add_argument('--complete', type=Path)
    p.add_argument('--valid', type=Path)
    p.add_argument('--campaign', type=Path)
    a=p.parse_args()
    if a.complete:
        finish_compile(a.complete)
    elif a.valid:
        raise SystemExit(0 if valid_compile(a.valid) else 1)
    elif a.campaign:
        print(str(campaign_binary(a.campaign))+'.vdb')
    elif a.recipe:
        print(materialize(ROOT, a.recipe, a.flags, a.coverage))
    else:
        p.error('recipe, complete, valid or campaign is required')
