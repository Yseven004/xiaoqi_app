"""Trusted installer, executed only inside the normal isolated sandbox."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import zipfile

source = pathlib.Path('/workspace/skill')
output = pathlib.Path('/workspace/output/dependencies.zip')
with tempfile.TemporaryDirectory(dir='/workspace/work') as temp:
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
        # Copy only this package's files. Registry/config/lock policy remains
        # installer-owned; lifecycle code runs solely in this sandbox.
        excluded = {'.git', '.npmrc', '.xiaoqi', 'node_modules', 'package-lock.json', 'npm-shrinkwrap.json'}
        for path in source.rglob('*'):
            relative = path.relative_to(source)
            if path.is_symlink() or any(part in excluded for part in relative.parts) or not path.is_file():
                continue
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        initial = {p.relative_to(target).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in target.rglob('*') if p.is_file() and not p.is_symlink()}
        normalized = {key: value for key, value in package.items()
                      if key not in {'workspaces', 'overrides', 'resolutions', 'publishConfig',
                                     'packageManager', 'allowScripts', 'trustedDependencies', 'pnpm', 'yarn'}}
        normalized['private'] = True
        normalized.setdefault('scripts', {})
        (target / 'package.json').write_text(json.dumps(normalized))
        common = ['--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org']
        subprocess.run(['npm', 'install', '--package-lock-only', *common], cwd=target, check=True, timeout=40)
        npm_lock = json.loads((target / 'package-lock.json').read_text())
        for name, value in npm_lock['packages'].items():
            if not name:
                continue
            if not value.get('resolved', '').startswith('https://registry.npmjs.org/') or not value.get('integrity', '').startswith('sha512-'):
                raise ValueError('npm dependency must have registry origin and SHA512 integrity')
        subprocess.run(['npm', 'ci', *common], cwd=target, check=True, timeout=40)
        # Newer npm versions use a per-package script policy. Derive it from
        # verified resolved identities, rather than bypassing all script policy.
        normalized['allowScripts'] = {
            name.rsplit('node_modules/', 1)[-1]: True
            for name, value in npm_lock['packages'].items()
            if name and value.get('hasInstallScript')
        }
        (target / 'package.json').write_text(json.dumps(normalized))
        subprocess.run(['npm', 'rebuild', '--offline', '--ignore-scripts=false', '--foreground-scripts',
                        '--no-audit', '--no-fund'], cwd=target, check=True, timeout=60)
        if 'build' in normalized['scripts']:
            subprocess.run(['npm', 'run', 'build', '--offline', '--ignore-scripts=false'],
                           cwd=target, check=True, timeout=60)
        subprocess.run(['npm', 'prune', '--omit=dev', '--ignore-scripts', '--offline', '--no-audit', '--no-fund'],
                       cwd=target, check=True, timeout=30)
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
        if (source / 'package.json').exists():
            for path in sorted(target.rglob('*')):
                relative = path.relative_to(target)
                if (path.is_symlink() or not path.is_file() or
                    any(part in excluded for part in relative.parts) or relative.as_posix() == 'package.json'):
                    continue
                if initial.get(relative.as_posix()) == hashlib.sha256(path.read_bytes()).hexdigest():
                    continue
                total += path.stat().st_size
                if total > 40 * 1024 * 1024:
                    raise ValueError('Built files exceed sandbox size limit (40 MB)')
                archive.write(path, '.xiaoqi/built/' + relative.as_posix())
        archive.writestr('.xiaoqi/dependency-lock.json', json.dumps(lock))
    if output.stat().st_size > 10 * 1024 * 1024:
        raise ValueError('Dependency archive exceeds 10 MB')
    print('Dependencies prepared: ' + hashlib.sha256(output.read_bytes()).hexdigest())
