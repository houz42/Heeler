#!/usr/bin/env python3
"""Build dependency-free Node broker distributions for the Heeler installer."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--os', choices=['darwin', 'linux'], required=True)
    parser.add_argument('--arch', choices=['arm64', 'x64'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,32}', args.version) or args.version in {'.', '..'}:
        parser.error('invalid version')
    root = Path(__file__).resolve().parents[1]
    args.output.mkdir(parents=True, exist_ok=True)
    name = f'heeler-chat-broker-{args.version}-{args.os}-{args.arch}.tar.gz'
    target = args.output / name
    if target.exists():
        parser.error('refusing to overwrite an existing versioned artifact')
    files = [(p.relative_to(root).as_posix(), p.read_bytes(), 0o644)
             for directory, pattern in [('src', '*.mjs'), ('adapters/omp', '*.ts')]
             for p in sorted((root / directory).glob(pattern))]
    files.extend([
        ('package.json', (root / 'package.json').read_bytes(), 0o644),
        ('bin/broker.mjs', (root / 'bin/broker.mjs').read_bytes(), 0o644),
        ('bin/broker', b'#!/bin/sh\nexec node "$(dirname "$0")/broker.mjs" "$@"\n', 0o755),
        ('manifest.json', json.dumps({'version': args.version, 'os': args.os,
                                     'arch': args.arch}).encode() + b'\n', 0o644),
    ])
    with tarfile.open(target, 'w:gz') as archive:
        for relative, data, mode in files:
            info = tarfile.TarInfo('broker/' + relative)
            info.size, info.mode, info.mtime = len(data), mode, 0
            archive.addfile(info, io.BytesIO(data))
    checksum_path = args.output / 'checksums.json'
    checksums = json.loads(checksum_path.read_text()) if checksum_path.exists() else {}
    checksums[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    temporary = checksum_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(checksums, indent=2, sort_keys=True) + '\n')
    temporary.replace(checksum_path)
    print(target)
    print(checksums[name])


if __name__ == '__main__':
    main()
