"""Trusted installer, executed only inside the normal isolated sandbox."""
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile

source = pathlib.Path('/workspace/skill')
output = pathlib.Path('/workspace/output/dependencies.zip')
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    lock = {'schema': 1, 'python': [], 'npm': {}}
    if (source / 'requirements.txt').exists():
        subprocess.run(['python3', '-m', 'pip', 'install', '--disable-pip-version-check',
                        '--no-input', '--only-binary=:all:', '--ignore-installed',
                        '--index-url', 'https://pypi.org/simple', '--report', str(root / 'pip.json'),
                        '--target', str(root / 'python'), '-r', str(source / 'requirements.txt')],
                       check=True, timeout=85)
        for item in json.loads((root / 'pip.json').read_text())['install']:
            hashes = item['download_info']['archive_info']['hashes']
            if 'sha256' not in hashes:
                raise ValueError('Python dependency has no SHA256')
            lock['python'].append({'name': item['metadata']['name'], 'version': item['metadata']['version'], 'hashes': hashes})
    if (source / 'package.json').exists():
        package = json.loads((source / 'package.json').read_text())
        target = root / 'node'
        target.mkdir()
        # Ignore package scripts, workspace configuration, overrides, lockfiles,
        # local paths, and registry settings supplied by the repository.
        (target / 'package.json').write_text(json.dumps({'private': True, 'dependencies': package.get('dependencies', {}),
                                                        'optionalDependencies': package.get('optionalDependencies', {})}))
        common = ['--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org']
        subprocess.run(['npm', 'install', '--package-lock-only', *common], cwd=target, check=True, timeout=40)
        npm_lock = json.loads((target / 'package-lock.json').read_text())
        for name, value in npm_lock['packages'].items():
            if not name:
                continue
            if not value.get('resolved', '').startswith('https://registry.npmjs.org/') or not value.get('integrity', '').startswith('sha512-'):
                raise ValueError('npm dependency must have registry origin and SHA512 integrity')
            if value.get('hasInstallScript'):
                raise ValueError('npm dependency needs a lifecycle/build script; unsupported')
        subprocess.run(['npm', 'ci', *common], cwd=target, check=True, timeout=40)
        lock['npm'] = npm_lock
    total = 0
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for folder, prefix in [(root / 'python', '.xiaoqi/python'), (root / 'node/node_modules', 'node_modules')]:
            for path in sorted(folder.rglob('*')):
                if path.is_symlink():
                    continue
                if not path.is_file():
                    continue
                total += path.stat().st_size
                if total > 40 * 1024 * 1024:
                    raise ValueError('Dependencies exceed sandbox size limit (40 MB)')
                archive.write(path, prefix + '/' + path.relative_to(folder).as_posix())
        archive.writestr('.xiaoqi/dependency-lock.json', json.dumps(lock))
    if output.stat().st_size > 10 * 1024 * 1024:
        raise ValueError('Dependency archive exceeds 10 MB')
    print('Dependencies prepared: ' + hashlib.sha256(output.read_bytes()).hexdigest())
