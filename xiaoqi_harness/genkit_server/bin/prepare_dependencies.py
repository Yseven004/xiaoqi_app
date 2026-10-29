"""Trusted installer, executed only inside the normal isolated sandbox."""
import hashlib
import json
import pathlib
import shutil
import shlex
import subprocess
import tempfile
import time
import tomllib
import urllib.parse
import zipfile


def run_dependency_command(command, **kwargs):
    remaining = _build_deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('Dependency build time budget exhausted')
    return subprocess.run(command, check=True, timeout=remaining, **kwargs)


def registry_requirements(values):
    from pip._vendor.packaging.requirements import Requirement
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise ValueError('Python project dependencies must be a list of requirement strings')
    for value in values:
        if Requirement(value).url is not None:
            raise ValueError('Python project dependencies must use PyPI names, not URL or local paths')
    return values


def project_metadata(folder):
    pyproject = folder / 'pyproject.toml'
    data = tomllib.loads(pyproject.read_text()) if pyproject.exists() else {}
    project = data.get('project', {})
    if not isinstance(project, dict):
        raise ValueError('Python project metadata must be a table')
    requirements = registry_requirements(project.get('dependencies', []))
    optional = project.get('optional-dependencies', {})
    if not isinstance(optional, dict):
        raise ValueError('Python optional dependencies must be named groups')
    for values in optional.values():
        registry_requirements(values)
    build = data.get('build-system')
    if build is not None:
        if not isinstance(build, dict):
            raise ValueError('Python build-system metadata must be a table')
        registry_requirements(build.get('requires', []))
    install_project = (folder / 'setup.py').exists() or build is not None or bool(project.get('name'))
    return requirements, sorted(optional), install_project


def copy_package(folder, destination):
    excluded = {'.git', '.npmrc', '.xiaoqi', 'node_modules', 'package-lock.json', 'npm-shrinkwrap.json'}
    destination.mkdir()
    for path in folder.rglob('*'):
        relative = path.relative_to(folder)
        if path.is_symlink() or any(part in excluded for part in relative.parts) or not path.is_file():
            continue
        output_path = destination / relative
        output_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, output_path)
    return excluded


def npm_bin_shim(folder, path):
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or not resolved.is_relative_to(folder.resolve()):
        raise ValueError('npm executable link escapes its dependency directory')
    target_name = 'node_modules/' + resolved.relative_to(folder.resolve()).as_posix()
    return ('#!/bin/sh\nexec ' + shlex.quote('/workspace/skill/' + target_name) + ' "$@"\n').encode()


source = pathlib.Path('/workspace/skill')
output = pathlib.Path('/workspace/output/dependencies.zip')
_build_deadline = time.monotonic() + 570  # Reserve 30 seconds for runner export/cleanup.
with tempfile.TemporaryDirectory(dir='/workspace/work') as temp:
    root = pathlib.Path(temp)
    lock = {'schema': 1, 'python': [], 'npm': {}}
    requirements, optional_groups, install_project = project_metadata(source)
    lock['python_optional_groups'] = optional_groups
    python_project = root / 'python-source' if install_project else None
    source_hash = None
    if python_project is not None:
        copy_package(source, python_project)
        digest = hashlib.sha256()
        for path in sorted(python_project.rglob('*')):
            if path.is_file():
                content = path.read_bytes()
                digest.update(json.dumps([path.relative_to(python_project).as_posix(), len(content)]).encode())
                digest.update(content)
        source_hash = digest.hexdigest()
    if (source / 'requirements.txt').exists() or requirements or install_project:
        requested = []
        if (source / 'requirements.txt').exists():
            requested += ['-r', str(source / 'requirements.txt')]
        requested += [str(python_project)] if python_project is not None else requirements
        run_dependency_command(['python3', '-m', 'pip', 'install', '--disable-pip-version-check',
                        '--no-input', '--no-compile', '--only-binary=:all:', '--ignore-installed', '--use-pep517',
                        '--index-url', 'https://pypi.org/simple', '--report', str(root / 'pip.json'),
                        '--target', str(root / 'python'), *requested])
        for item in json.loads((root / 'pip.json').read_text())['install']:
            download = item['download_info']
            if python_project is not None and download.get('dir_info') is not None and download.get('url') == python_project.as_uri():
                lock['python'].append({'name': item['metadata']['name'], 'version': item['metadata']['version'],
                                       'source': 'local_project', 'source_sha256': source_hash})
                continue
            origin = urllib.parse.urlsplit(download['url'])
            if origin.scheme != 'https' or origin.hostname != 'files.pythonhosted.org':
                raise ValueError('Python dependency must have a PyPI archive origin')
            hashes = download['archive_info']['hashes']
            if 'sha256' not in hashes:
                raise ValueError('Python dependency has no SHA256')
            lock['python'].append({'name': item['metadata']['name'], 'version': item['metadata']['version'], 'hashes': hashes})
    if (source / 'package.json').exists():
        package = json.loads((source / 'package.json').read_text())
        target = root / 'node'
        # Copy only this package's files. Registry/config/lock policy remains
        # installer-owned; lifecycle code runs solely in this sandbox.
        excluded = copy_package(source, target)
        initial = {p.relative_to(target).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in target.rglob('*') if p.is_file() and not p.is_symlink()}
        normalized = {key: value for key, value in package.items()
                      if key not in {'workspaces', 'overrides', 'resolutions', 'publishConfig',
                                     'packageManager', 'allowScripts', 'trustedDependencies', 'pnpm', 'yarn'}}
        normalized['private'] = True
        normalized.setdefault('scripts', {})
        (target / 'package.json').write_text(json.dumps(normalized))
        common = ['--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org']
        run_dependency_command(['npm', 'install', '--package-lock-only', *common], cwd=target)
        npm_lock = json.loads((target / 'package-lock.json').read_text())
        for name, value in npm_lock['packages'].items():
            if not name:
                continue
            if not value.get('resolved', '').startswith('https://registry.npmjs.org/') or not value.get('integrity', '').startswith('sha512-'):
                raise ValueError('npm dependency must have registry origin and SHA512 integrity')
        run_dependency_command(['npm', 'ci', *common], cwd=target)
        # Newer npm versions use a per-package script policy. Derive it from
        # verified resolved identities, rather than bypassing all script policy.
        normalized['allowScripts'] = {
            name.rsplit('node_modules/', 1)[-1]: True
            for name, value in npm_lock['packages'].items()
            if name and value.get('hasInstallScript')
        }
        (target / 'package.json').write_text(json.dumps(normalized))
        run_dependency_command(['npm', 'rebuild', '--offline', '--ignore-scripts=false', '--foreground-scripts',
                        '--no-audit', '--no-fund'], cwd=target)
        if 'build' in normalized['scripts']:
            run_dependency_command(['npm', 'run', 'build', '--offline', '--ignore-scripts=false'], cwd=target)
        run_dependency_command(['npm', 'prune', '--omit=dev', '--ignore-scripts', '--offline', '--no-audit', '--no-fund'],
                       cwd=target)
        lock['npm'] = npm_lock
    total = 0
    executable_files = []
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for folder, prefix in [(root / 'python', '.xiaoqi/python'), (root / 'node/node_modules', 'node_modules')]:
            for path in sorted(folder.rglob('*')):
                if path.is_symlink():
                    # npm's bin links become regular, task-local shims. Never
                    # dereference arbitrary links or export a host path.
                    if prefix == 'node_modules' and path.parent.name == '.bin':
                        name = prefix + '/' + path.relative_to(folder).as_posix()
                        shim = npm_bin_shim(folder, path)
                        total += len(shim)
                        if total > 40 * 1024 * 1024:
                            raise ValueError('Dependencies exceed sandbox size limit (40 MB)')
                        archive.writestr(name, shim)
                        executable_files.append(name)
                    continue
                if not path.is_file():
                    continue
                total += path.stat().st_size
                if total > 40 * 1024 * 1024:
                    raise ValueError('Dependencies exceed sandbox size limit (40 MB)')
                archive.write(path, prefix + '/' + path.relative_to(folder).as_posix())
                if path.stat().st_mode & 0o111:
                    executable_files.append(prefix + '/' + path.relative_to(folder).as_posix())
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
                if path.stat().st_mode & 0o111:
                    executable_files.append(relative.as_posix())
        lock['executables'] = sorted(executable_files)
        archive.writestr('.xiaoqi/dependency-lock.json', json.dumps(lock))
    if output.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('Dependency archive exceeds 20 MB')
    print('Dependencies prepared: ' + hashlib.sha256(output.read_bytes()).hexdigest())
