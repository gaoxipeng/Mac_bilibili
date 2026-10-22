#!/usr/bin/env python3
"""Package a Release using a stable certificate identity (never ad-hoc).

Usage: python3 scripts/package-release.py --identity '<certificate SHA-1>'
Build first with Xcode. For public distribution, prefer a Developer ID identity
and notarization; Apple Development is usable for the current local builds.
"""
import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--identity', required=True, help='Apple Development or Developer ID certificate, not -')
parser.add_argument('--app', type=pathlib.Path, default=pathlib.Path('build_release/DerivedData/Build/Products/Release/bilibili.app'))
args = parser.parse_args()
if args.identity.strip() in ('', '-'):
    parser.error('A stable signing certificate is required for Keychain continuity')
with (args.app / 'Contents/Info.plist').open('rb') as stream:
    version = plistlib.load(stream)['CFBundleShortVersionString']
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version):
    parser.error('Unexpected version format')
staged = pathlib.Path('build_release') / ('staging-' + version) / 'bilibili.app'
staged.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(args.app), str(staged)], check=True)
with tempfile.TemporaryDirectory(prefix='bilibili-signing-') as temporary:
    # Third-party frameworks can contain expired upstream signatures. Replace
    # those first, then sign the outer application with the persistent identity.
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(staged)], check=True)
    entitlements = pathlib.Path(temporary) / 'release.entitlements'
    original = pathlib.Path('bilibili/bilibili.entitlements')
    with original.open('rb') as stream:
        rights = plistlib.load(stream)
    rights.pop('com.apple.security.get-task-allow', None)
    with entitlements.open('wb') as stream:
        plistlib.dump(rights, stream)
    subprocess.run(['codesign', '--force', '--sign', args.identity, '--entitlements', str(entitlements), str(staged)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
requirement = subprocess.run(['codesign', '-d', '-r-', str(staged)], capture_output=True, text=True, check=True)
requirement_text = requirement.stdout + requirement.stderr
if 'anchor apple' not in requirement_text or 'designated => cdhash' in requirement_text:
    raise RuntimeError('App does not have a stable Apple certificate-based identity')
archive = pathlib.Path('release') / ('bilibili-' + version + '-macOS.zip')
archive.parent.mkdir(exist_ok=True)
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(staged), str(archive)], check=True)
subprocess.run(['unzip', '-tq', str(archive)], check=True)
print('Packaged:', archive)
print('Install source:', staged)
print('SHA-256:', hashlib.sha256(archive.read_bytes()).hexdigest())
