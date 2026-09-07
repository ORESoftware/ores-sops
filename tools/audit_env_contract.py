#!/usr/bin/env python3
"""Fail-closed audit for the encrypted environment-file repository contract."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import os
import re
import subprocess
import sys
from typing import Iterable

MAX_ENCRYPTED_ENV_BYTES = 1_048_576
ALLOWED_ENV_SUFFIXES = ('.example', '.sample', '.template')
ENC_METADATA_NAMES = {'README.md', '.gitkeep'}
CONTROL_CHARACTERS = re.compile(r'[\x00-\x1f\x7f]')


@dataclass(frozen=True, order=True)
class Finding:
    code: str
    path: str
    message: str

    def render(self) -> str:
        location = f' [{self.path}]' if self.path else ''
        return f'{self.code}{location}: {self.message}'


def _git_entries(root: Path) -> list[tuple[str, str]]:
    try:
        raw = subprocess.check_output(
            ['git', 'ls-files', '-s', '-z'],
            cwd=root,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError('unable to enumerate tracked files with git ls-files') from error

    entries: list[tuple[str, str]] = []
    for record in raw.decode('utf-8', errors='surrogateescape').split('\0'):
        if not record:
            continue
        metadata, separator, path = record.partition('\t')
        if not separator:
            raise RuntimeError('unexpected git ls-files output')
        mode = metadata.split(' ', 1)[0]
        entries.append((path, mode))
    return entries


def _is_allowed_example(path: PurePosixPath) -> bool:
    name = path.name.lower()
    return name.endswith(ALLOWED_ENV_SUFFIXES) or name in {
        '.env.example',
        '.env.sample',
        '.env.template',
    }


def _looks_like_plaintext_env(path: PurePosixPath) -> bool:
    lowered_parts = tuple(part.lower() for part in path.parts)
    name = path.name.lower()
    if len(lowered_parts) >= 2 and lowered_parts[0:2] == ('env', 'dec'):
        return True
    if _is_allowed_example(path):
        return False
    if name == '.env' or name.startswith('.env.'):
        return True
    if name.endswith(('.env.dec', '.env.decrypted', '.decrypted', '.plaintext')):
        return True
    if name in {'secrets.env', 'credentials.env', 'age.key', 'agekey', 'age-key.txt'}:
        return True
    return False


def _is_encrypted_env(path: PurePosixPath) -> bool:
    parts = tuple(part.lower() for part in path.parts)
    return len(parts) >= 3 and parts[0:2] == ('env', 'enc') and path.name not in ENC_METADATA_NAMES


def _read_text(path: Path, *, limit: int | None = None) -> str:
    data = path.read_bytes()
    if limit is not None and len(data) > limit:
        raise ValueError(f'file exceeds {limit} bytes')
    if b'\x00' in data:
        raise ValueError('file contains NUL bytes')
    return data.decode('utf-8')


def _audit_encrypted_file(root: Path, rel: PurePosixPath, mode: str) -> list[Finding]:
    findings: list[Finding] = []
    path_text = rel.as_posix()
    if not rel.name.endswith('.env.enc'):
        findings.append(Finding(
            'ENC001',
            path_text,
            'encrypted environment files must end with .env.enc',
        ))
    if mode != '100644':
        findings.append(Finding(
            'ENC002',
            path_text,
            'encrypted environment files must be regular, non-executable mode 100644 files',
        ))

    absolute = root / rel
    try:
        text = _read_text(absolute, limit=MAX_ENCRYPTED_ENV_BYTES)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        findings.append(Finding('ENC003', path_text, f'unreadable encrypted environment file: {error}'))
        return findings

    lowered = text.lower()
    if 'enc[' not in lowered or 'sops' not in lowered or 'age' not in lowered:
        findings.append(Finding(
            'ENC004',
            path_text,
            'file must contain SOPS ciphertext and Age metadata',
        ))

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        if key.startswith('sops_'):
            continue
        if not value.startswith('ENC['):
            findings.append(Finding(
                'ENC005',
                path_text,
                f'line {line_number} appears to contain a plaintext value',
            ))
    return findings


def _contains_ignore_rule(text: str, target: str) -> bool:
    normalized_target = target.strip('/').lower()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#') or line.startswith('!'):
            continue
        normalized = line.strip('/').lower().removesuffix('/**').removesuffix('/*')
        if normalized == normalized_target:
            return True
    return False


def _audit_policy_anchors(root: Path, tracked: set[str]) -> list[Finding]:
    findings: list[Finding] = []

    sops_path = next((name for name in ('.sops.yaml', '.sops.yml') if name in tracked), None)
    if sops_path is None:
        findings.append(Finding('POL001', '', 'a tracked .sops.yaml or .sops.yml is required'))
    else:
        try:
            text = _read_text(root / sops_path).lower()
        except (OSError, UnicodeDecodeError, ValueError) as error:
            findings.append(Finding('POL002', sops_path, f'unable to read SOPS policy: {error}'))
        else:
            for token in ('creation_rules', 'path_regex', 'age'):
                if token not in text:
                    findings.append(Finding('POL003', sops_path, f'SOPS policy must contain {token}'))

    if 'flake.nix' not in tracked:
        findings.append(Finding('POL004', '', 'a tracked flake.nix is required for reproducible tooling'))
    else:
        try:
            flake = _read_text(root / 'flake.nix').lower()
        except (OSError, UnicodeDecodeError, ValueError) as error:
            findings.append(Finding('POL005', 'flake.nix', f'unable to read flake: {error}'))
        else:
            if 'sops' not in flake or 'age' not in flake:
                findings.append(Finding('POL006', 'flake.nix', 'flake must make both SOPS and Age available'))

    just_path = next((name for name in ('justfile', 'Justfile') if name in tracked), None)
    if just_path is None:
        findings.append(Finding('POL007', '', 'a tracked justfile or Justfile is required'))
    else:
        try:
            just = _read_text(root / just_path).lower()
        except (OSError, UnicodeDecodeError, ValueError) as error:
            findings.append(Finding('POL008', just_path, f'unable to read Just policy: {error}'))
        else:
            for token in ('sops', 'env/enc', 'env/dec'):
                if token not in just:
                    findings.append(Finding('POL009', just_path, f'Just policy must reference {token}'))

    if '.gitignore' not in tracked:
        findings.append(Finding('POL010', '', 'a tracked .gitignore is required'))
    else:
        try:
            ignore = _read_text(root / '.gitignore')
        except (OSError, UnicodeDecodeError, ValueError) as error:
            findings.append(Finding('POL011', '.gitignore', f'unable to read .gitignore: {error}'))
        else:
            if not _contains_ignore_rule(ignore, 'env/dec'):
                findings.append(Finding('POL012', '.gitignore', 'env/dec must be ignored recursively'))
            if not _contains_ignore_rule(ignore, '.env'):
                findings.append(Finding('POL013', '.gitignore', 'the root .env file must be ignored'))

    return findings


def audit(root: Path, entries: Iterable[tuple[str, str]] | None = None) -> list[Finding]:
    root = root.resolve()
    tracked_entries = list(entries) if entries is not None else _git_entries(root)
    tracked = {path for path, _mode in tracked_entries}
    findings: list[Finding] = []

    for raw_path, mode in tracked_entries:
        rel = PurePosixPath(raw_path)
        if rel.is_absolute() or '..' in rel.parts or CONTROL_CHARACTERS.search(raw_path):
            findings.append(Finding('PATH001', raw_path, 'tracked path is unsafe for secret automation'))
            continue

        if _looks_like_plaintext_env(rel):
            findings.append(Finding(
                'ENV001',
                rel.as_posix(),
                'plaintext or decrypted environment material must not be tracked',
            ))

        secret_scoped = _looks_like_plaintext_env(rel) or _is_encrypted_env(rel) or rel.parts[:2] in {
            ('env', 'enc'),
            ('env', 'dec'),
        }
        if secret_scoped and mode == '120000':
            findings.append(Finding(
                'PATH002',
                rel.as_posix(),
                'symlinks are forbidden in encrypted/decrypted environment paths',
            ))

        if _is_encrypted_env(rel):
            findings.extend(_audit_encrypted_file(root, rel, mode))

    findings.extend(_audit_policy_anchors(root, tracked))
    return sorted(set(findings))


def main() -> int:
    root = Path(os.environ.get('ORES_SOPS_AUDIT_ROOT', Path(__file__).resolve().parents[1]))
    try:
        findings = audit(root)
    except RuntimeError as error:
        print(f'AUDIT001: {error}', file=sys.stderr)
        return 2

    if findings:
        print(f'ores-sops contract audit failed with {len(findings)} finding(s):', file=sys.stderr)
        for finding in findings:
            print(f'- {finding.render()}', file=sys.stderr)
        return 1

    print('ores-sops contract audit passed')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
