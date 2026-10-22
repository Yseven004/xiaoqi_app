import io
import json
import tempfile
import tarfile
import unittest
from pathlib import Path

import release_artifact as artifact

COMMIT = 'a' * 40


def make_bundle(root):
    source = root / 'input'
    (source / 'genkit_server/lib/src').mkdir(parents=True)
    (source / 'genkit_server/lib/src/release.dart').write_text("const releaseId = 'test';\nconst apiContractVersion = '18';\n")
    (source / 'genkit_server/pubspec.yaml').write_text('name: test\n')
    (source / 'deploy').mkdir()
    (source / 'deploy/compose.yaml').write_text('services: {}\n')
    (source / 'deploy/verify_store.py').write_text('# fixture verifier\n')
    (source / 'deploy/Caddyfile.docker').write_text('example.com { respond 200 }\n')
    with tarfile.open(root / 'source.tgz', 'w:gz') as tar:
        tar.add(source / 'genkit_server', arcname='genkit_server')
        tar.add(source / 'deploy', arcname='deploy')
    (root / 'images.tar.gz').write_bytes(b'fake docker image archive')
    manifest = dict(schema=1, release_id='test', api_contract_version='18', source_commit=COMMIT,
                    images=[dict(name=n, tag=n + ':build-' + COMMIT, id='sha256:' + 'b'*64, os='linux', architecture='amd64', size=1) for n in artifact.IMAGES],
                    sha256={n: artifact.sha(root / n) for n in ('source.tgz', 'images.tar.gz')})
    (root / 'manifest.json').write_text(json.dumps(manifest))
    rebuild(root)
    return root / 'release.tgz'


def rebuild(root):
    with tarfile.open(root / 'release.tgz', 'w:gz') as tar:
        for name in ('manifest.json', 'source.tgz', 'images.tar.gz'):
            tar.add(root / name, arcname=name)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = make_bundle(self.root)

    def test_valid_bundle_and_source(self):
        result = artifact.unpack(self.archive, self.root / 'out', COMMIT, 'test', '18')
        self.assertEqual(result['source_commit'], COMMIT)
        self.assertTrue((self.root / 'out/source/genkit_server/pubspec.yaml').is_file())

    def test_corrupt_image_rejected(self):
        (self.root / 'images.tar.gz').write_bytes(b'corrupt')
        rebuild(self.root)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            artifact.unpack(self.archive, self.root / 'out', COMMIT, 'test', '18')

    def test_wrong_contract_and_wrong_image_platform_rejected(self):
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            artifact.unpack(self.archive, self.root / 'wrong', COMMIT, 'test', '19')
        manifest = json.loads((self.root / 'manifest.json').read_text())
        manifest['images'][0]['architecture'] = 'arm64'
        (self.root / 'manifest.json').write_text(json.dumps(manifest))
        rebuild(self.root)
        with self.assertRaisesRegex(ValueError, 'platform'):
            artifact.unpack(self.archive, self.root / 'out', COMMIT, 'test', '18')

    def test_paths_links_duplicates_private_files_rejected_before_extraction(self):
        for name, kind in [('../escape', 'file'), ('deploy/single-server.env', 'file'), ('deploy/link', 'link'), ('deploy/file', 'duplicate')]:
            with self.subTest(name=name, kind=kind):
                archive = self.root / 'unsafe.tgz'
                with tarfile.open(archive, 'w:gz') as tar:
                    member = tarfile.TarInfo(name)
                    if kind == 'link':
                        member.type = tarfile.SYMTYPE
                        member.linkname = '/etc/passwd'
                        tar.addfile(member)
                    else:
                        member.size = 1
                        tar.addfile(member, io.BytesIO(b'x'))
                        if kind == 'duplicate':
                            tar.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    artifact.safe_extract(archive, self.root / 'unsafe-out')
                self.assertFalse((self.root / 'unsafe-out').exists())


if __name__ == '__main__':
    unittest.main()
