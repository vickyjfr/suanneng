import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('install_nas', Path(__file__).resolve().parents[2] / 'deploy/install_nas.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallerChecks(unittest.TestCase):
    def test_preserves_existing_secrets_and_quoted_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'agent.env'
            path.write_text('SE9_DEVICE_NAME="Living room NAS"\nSE9_AGENT_PROXY_TOKEN=abc#def\n')
            values = installer.read_env(path)
            self.assertEqual(values['SE9_AGENT_PROXY_TOKEN'], 'abc#def')
            self.assertEqual(values['SE9_DEVICE_NAME'], 'Living room NAS')
            with patch.object(installer.os, 'chown'):
                installer.write_env(path, values, 0)
            self.assertEqual(installer.read_env(path), values)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_rejects_unsupported_existing_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'agent.env'
            path.write_text('export SE9_KEY_FILE=/identity.pem\n')
            with self.assertRaises(ValueError):
                installer.read_env(path)

    def test_refuses_macos_binaries_and_wrong_linux_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'se9_agent'
            path.write_bytes(b'\xcf\xfa\xed\xfe' + bytes(16))
            with self.assertRaisesRegex(ValueError, 'not a Linux ELF'):
                installer.verify_binary(path)
            header = bytearray(20)
            header[:6] = b'\x7fELF\x02\x01'
            header[18:20] = struct.pack('<H', 62)
            path.write_bytes(header)
            with patch.object(installer.platform, 'machine', return_value='aarch64'):
                with self.assertRaisesRegex(ValueError, 'does not match'):
                    installer.verify_binary(path)

    def test_does_not_execute_older_binaries_for_configuration_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'se9_agent'
            path.write_bytes(b'old agent')
            with patch.object(installer.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'old build'):
                    installer.verify_defaults(path, 'expected-key')
                run.assert_not_called()

    def test_rejects_a_build_pinned_to_a_different_cloud_key(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'se9_agent'
            path.write_bytes(b'SE9_NAS_EMBEDDED_CONFIG_V2')
            info = '{"configVersion":2,"cloudOrigin":"https://123.56.147.51:8443","cloudPublicKeySha256":"different-key","rtcCompiled":true}'
            with patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, info, '')):
                with self.assertRaisesRegex(ValueError, 'unexpected cloud address/key'):
                    installer.verify_defaults(path, 'expected-key')

    def test_refuses_missing_runtime_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'se9_agent'
            header = bytearray(20)
            header[:6] = b'\x7fELF\x02\x01'
            header[18:20] = struct.pack('<H', 183)
            path.write_bytes(header)
            with patch.object(installer.platform, 'machine', return_value='aarch64'), patch.object(installer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'libnice.so => not found', '')):
                with self.assertRaisesRegex(ValueError, 'Missing runtime libraries'):
                    installer.verify_binary(path)

if __name__ == '__main__':
    unittest.main()
