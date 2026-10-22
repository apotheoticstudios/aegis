"""Exercise World upgrades with synthetic archives and tools; no network or personal data."""
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'Apps/AegisApp/Resources/World/world-setup.sh'


class WorldSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='world-example-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'gods-eye-view'
        (self.app / 'dist').mkdir(parents=True)
        (self.app / 'dist/index.html').write_text('Example previous globe')
        (self.app / '.aegis-commit').write_text('example-old-revision')
        (self.root / 'node/bin').mkdir(parents=True)
        source = SCRIPT.read_text()
        version = re.search(r'^node_version=(.+)$', source, re.M)[1]
        self.commit = re.search(r'^commit=(.+)$', source, re.M)[1]
        self.tool('node', '#!/bin/bash\nprintf "%s\\n" ' + version + '\n')
        self.tool('npm', '''#!/bin/bash
set -e
if [ "$1" = run ]; then
    [ "${EXAMPLE_BUILD_FAIL:-0}" = 0 ] || exit 3
    mkdir -p dist
    printf 'Example new globe' > dist/index.html
    [ ! -f .env.local ] || cp .env.local "$AEGIS_WORLD_DIR/example-settings-at-build"
fi
''')
        cache = self.root / 'cache'
        cache.mkdir()
        archive = cache / ('gods-eye-view-' + self.commit + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            for name, data in [('package.json', b'{}'), ('config/cctv_sources.example-default.json', b'[]')]:
                item = tarfile.TarInfo('example-globe/' + name)
                item.size = len(data)
                tar.addfile(item, io.BytesIO(data))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.script = self.root / 'world-setup.sh'
        self.script.write_text(re.sub(r'^app_sha=.+$', 'app_sha=' + digest, source, flags=re.M))

    def tool(self, name, source):
        path = self.root / 'node/bin' / name
        path.write_text(source)
        path.chmod(0o755)

    def run_setup(self, fail=False):
        environment = {'PATH': '/usr/bin:/bin', 'AEGIS_WORLD_DIR': str(self.root), 'EXAMPLE_BUILD_FAIL': str(int(fail))}
        return subprocess.run(['/bin/bash', str(self.script)], env=environment, text=True, capture_output=True)

    def test_upgrade_preserves_settings_before_build_and_keeps_local_camera_catalogs(self):
        settings = 'CCTV_SOURCES_FILE=config/cctv_sources.example-local.json\nCCTV_FORCE_AUSTIN=1\n'
        (self.app / '.env.local').write_text(settings)
        (self.app / '.env.production.local').write_text('EXAMPLE_SETTING=example\n')
        (self.app / 'config').mkdir()
        (self.app / 'config/cctv_sources.example-local.json').write_text('[{"id":"example-camera"}]')
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / '.env.local').read_text(), settings)
        self.assertEqual((self.root / 'example-settings-at-build').read_text(), settings)
        self.assertEqual((self.app / '.env.production.local').read_text(), 'EXAMPLE_SETTING=example\n')
        self.assertEqual((self.app / '.env.local').stat().st_mode & 0o777, 0o600)
        self.assertIn('example-camera', (self.app / 'config/cctv_sources.example-local.json').read_text())
        self.assertEqual((self.app / '.aegis-commit').read_text().strip(), self.commit)

    def test_failed_build_preserves_the_installed_globe_and_settings(self):
        (self.app / '.env.local').write_text('EXAMPLE_SETTING=example\n')
        result = self.run_setup(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / 'dist/index.html').read_text(), 'Example previous globe')
        self.assertEqual((self.app / '.env.local').read_text(), 'EXAMPLE_SETTING=example\n')
        self.assertEqual((self.app / '.aegis-commit').read_text(), 'example-old-revision')

    def test_current_revision_is_left_in_place(self):
        (self.app / '.aegis-commit').write_text(self.commit)
        result = self.run_setup(fail=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / 'dist/index.html').read_text(), 'Example previous globe')

    def test_symlinked_settings_are_not_copied(self):
        example = self.root / 'example-not-a-setting'
        example.write_text('Example unrelated content')
        (self.app / '.env.local').symlink_to(example)
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app / '.env.local').exists())
        self.assertEqual(example.read_text(), 'Example unrelated content')


if __name__ == '__main__':
    unittest.main()
