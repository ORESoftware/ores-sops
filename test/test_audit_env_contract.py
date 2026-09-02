from __future__ import annotations

import importlib.util
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / 'tools' / 'audit_env_contract.py'
SPEC = importlib.util.spec_from_file_location('audit_env_contract', MODULE_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


SAFE_FILES = {
    '.gitignore': '.env\nenv/dec/\n',
    '.sops.yaml': '''creation_rules:
  - path_regex: ^env/enc/.*\\.env\\.enc$
    age: age1examplepublicrecipient
''',
    'flake.nix': '''{
  description = "sops and age tools";
  outputs = { self }: { };
}
''',
    'justfile': '''encrypt:
  sops env/dec/app.env > env/enc/app.env.enc

decrypt:
  sops --decrypt env/enc/app.env.enc > env/dec/app.env
''',
    'env/enc/app.env.enc': '''API_TOKEN=ENC[AES256_GCM,data:ciphertext,iv:iv,tag:tag,type:str]
sops_age__list_0__map_recipient=ENC[AES256_GCM,data:recipient,iv:iv,tag:tag,type:str]
sops_mac=ENC[AES256_GCM,data:mac,iv:iv,tag:tag,type:str]
''',
}


class Repository:
    def __init__(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.root = Path(self._temp.name)
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)
        subprocess.run(['git', 'config', 'user.email', 'test@example.invalid'], cwd=self.root, check=True)
        subprocess.run(['git', 'config', 'user.name', 'Test'], cwd=self.root, check=True)

    def close(self) -> None:
        self._temp.cleanup()

    def write(self, path: str, content: str, mode: int | None = None) -> Path:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding='utf-8')
        if mode is not None:
            destination.chmod(mode)
        return destination

    def safe_contract(self) -> None:
        for path, content in SAFE_FILES.items():
            self.write(path, content)

    def add(self) -> None:
        subprocess.run(['git', 'add', '-f', '-A'], cwd=self.root, check=True)

    def findings(self):
        self.add()
        return AUDIT.audit(self.root)


class EncryptedEnvironmentContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repository()
        self.addCleanup(self.repo.close)
        self.repo.safe_contract()

    def codes(self) -> set[str]:
        return {finding.code for finding in self.repo.findings()}

    def test_safe_sops_age_just_nix_contract_passes(self) -> None:
        self.assertEqual(self.repo.findings(), [])

    def test_tracked_plaintext_dotenv_fails_closed(self) -> None:
        self.repo.write('.env', 'TOKEN=plaintext\n')
        self.assertIn('ENV001', self.codes())

    def test_tracked_decrypted_tree_fails_closed(self) -> None:
        self.repo.write('env/dec/app.env', 'TOKEN=plaintext\n')
        self.assertIn('ENV001', self.codes())

    def test_symlink_indirection_in_encrypted_tree_is_forbidden(self) -> None:
        target = self.repo.write('outside.env.enc', SAFE_FILES['env/enc/app.env.enc'])
        link = self.repo.root / 'env/enc/link.env.enc'
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, link)
        self.assertIn('PATH002', self.codes())

    def test_malformed_encrypted_file_is_rejected(self) -> None:
        self.repo.write('env/enc/app.env.enc', 'API_TOKEN=plaintext\n')
        codes = self.codes()
        self.assertIn('ENC004', codes)
        self.assertIn('ENC005', codes)

    def test_encrypted_file_must_not_be_executable(self) -> None:
        self.repo.write('env/enc/app.env.enc', SAFE_FILES['env/enc/app.env.enc'], mode=0o755)
        self.assertIn('ENC002', self.codes())

    def test_encrypted_filename_contract_is_enforced(self) -> None:
        self.repo.write('env/enc/app.env', SAFE_FILES['env/enc/app.env.enc'])
        self.assertIn('ENC001', self.codes())

    def test_missing_age_policy_anchor_is_rejected(self) -> None:
        self.repo.write('.sops.yaml', 'creation_rules:\n  - path_regex: env/enc\n')
        self.assertIn('POL003', self.codes())

    def test_decrypted_directory_must_be_ignored(self) -> None:
        self.repo.write('.gitignore', '.env\n')
        self.assertIn('POL012', self.codes())

    def test_root_dotenv_must_be_ignored(self) -> None:
        self.repo.write('.gitignore', 'env/dec/\n')
        self.assertIn('POL013', self.codes())


if __name__ == '__main__':
    unittest.main()
