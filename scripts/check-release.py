#!/usr/bin/env python3
"""Read-only ConnDock source/bundle preflight. Does not sign, upload or edit an app."""
import argparse
import datetime
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

TEAM = '86HC8YA388'
BUNDLE = 'com.ruohai.conndock'
GROUP = TEAM + '.' + BUNDLE + '.mcp'
ROOT = Path(__file__).resolve().parents[1]
REASONS = {
    'NSPrivacyAccessedAPICategoryUserDefaults': {'CA92.1'},
    'NSPrivacyAccessedAPICategoryFileTimestamp': {'C617.1', '3B52.1'},
    'NSPrivacyAccessedAPICategorySystemBootTime': {'35F9.1'},
}


class ReleaseError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ReleaseError(code)


def read_plist(path):
    try:
        require(path.is_file() and path.stat().st_size <= 2 * 1024 * 1024, 'PLIST_MISSING_OR_TOO_LARGE')
        value = plistlib.loads(path.read_bytes())
        require(isinstance(value, dict), 'PLIST_STRUCTURE')
        return value
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise ReleaseError('PLIST_INVALID') from None


def validate_privacy(value, helper=False):
    require(value.get('NSPrivacyTracking') is False and value.get('NSPrivacyTrackingDomains') == []
            and value.get('NSPrivacyCollectedDataTypes') == [], 'PRIVACY_SCOPE')
    entries = value.get('NSPrivacyAccessedAPITypes')
    require(isinstance(entries, list), 'PRIVACY_CATEGORY')
    expected = set(REASONS) - ({'NSPrivacyAccessedAPICategoryUserDefaults'} if helper else set())
    seen = set()
    for entry in entries:
        require(isinstance(entry, dict), 'PRIVACY_CATEGORY')
        category = entry.get('NSPrivacyAccessedAPIType')
        require(category in expected and category not in seen, 'PRIVACY_CATEGORY')
        reasons = entry.get('NSPrivacyAccessedAPITypeReasons')
        require(isinstance(reasons, list) and len(reasons) == len(set(reasons))
                and set(reasons) == REASONS[category], 'PRIVACY_REASON')
        seen.add(category)
    require(seen == expected, 'PRIVACY_CATEGORY')


def validate_identity(info, platform, mode):
    expected_local = 'local.SSHClient.' + platform
    if mode == 'distribution':
        require(info.get('CFBundleIdentifier') == BUNDLE
                and info.get('ConnDockBuildConfiguration') == 'Release', 'DISTRIBUTION_IDENTITY')
    else:
        require(info.get('CFBundleIdentifier') in (BUNDLE, expected_local), 'BUNDLE_IDENTITY')
    version = info.get('CFBundleShortVersionString', '')
    build = info.get('CFBundleVersion', '')
    require(isinstance(version, str) and re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version)
            and isinstance(build, str) and re.fullmatch(r'[1-9]\d*(?:\.\d+){0,2}', build), 'BUILD_VERSION')
    if mode == 'distribution':
        decision = info.get('ITSAppUsesNonExemptEncryption')
        require(type(decision) is bool, 'EXPORT_COMPLIANCE_REVIEW_REQUIRED')
        if decision:
            require(isinstance(info.get('ITSEncryptionExportComplianceCode'), str)
                    and info['ITSEncryptionExportComplianceCode'].strip(), 'EXPORT_DOCUMENTATION_REQUIRED')


def validate_signature_team(team):
    require(team == TEAM, 'DISTRIBUTION_TEAM')


def validate_certificate_authorities(authorities):
    require(bool(authorities) and authorities[0].startswith(('Apple Distribution:', '3rd Party Mac Developer Application:')),
            'DISTRIBUTION_CERTIFICATE')


def validate_entitlements(values, platform, helper, mode):
    require(isinstance(values, dict), 'DISTRIBUTION_ENTITLEMENT')
    forbidden = ['get-task-allow', 'com.apple.security.get-task-allow',
                 'com.apple.security.cs.disable-library-validation',
                 'com.apple.security.cs.allow-unsigned-executable-memory',
                 'com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.inherit']
    if mode == 'distribution':
        require(not any(values.get(key) for key in forbidden), 'DISTRIBUTION_ENTITLEMENT')
        if not helper:
            require(values.get('com.apple.developer.icloud-container-identifiers') == ['iCloud.com.ruohai.conndock']
                    and values.get('com.apple.developer.icloud-container-environment') == 'Production'
                    and values.get('com.apple.developer.icloud-services') == ['CloudKit'], 'DISTRIBUTION_CLOUDKIT')
    if platform == 'macOS':
        require(values.get('com.apple.security.app-sandbox') is True
                and values.get('com.apple.security.network.client') is True, 'DISTRIBUTION_ENTITLEMENT')
        if mode == 'distribution':
            require(values.get('com.apple.security.application-groups') == [GROUP], 'DISTRIBUTION_ENTITLEMENT')
        if helper:
            require(not values.get('com.apple.security.network.server')
                    and not values.get('keychain-access-groups')
                    and not any(key.startswith('com.apple.developer.icloud') for key in values), 'DISTRIBUTION_ENTITLEMENT')
        else:
            require(values.get('com.apple.security.network.server') is True, 'DISTRIBUTION_ENTITLEMENT')
    else:
        require(not values.get('com.apple.security.application-groups')
                and not values.get('com.apple.security.network.server'), 'DISTRIBUTION_ENTITLEMENT')


def validate_profile(profile, bundle, platform, signed_entitlements=None, certificate=None):
    require(isinstance(profile, dict), 'DISTRIBUTION_PROFILE')
    values = profile.get('Entitlements', {})
    require(isinstance(values, dict), 'DISTRIBUTION_PROFILE')
    identifier = values.get('application-identifier', values.get('com.apple.application-identifier'))
    expiry = profile.get('ExpirationDate')
    require(isinstance(expiry, datetime.datetime), 'DISTRIBUTION_PROFILE')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    platforms = profile.get('Platform', [])
    require(TEAM in profile.get('TeamIdentifier', []) and identifier == TEAM + '.' + bundle
            and expiry > datetime.datetime.now(datetime.timezone.utc)
            and not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices')
            and not values.get('get-task-allow') and not values.get('com.apple.security.get-task-allow')
            and any(item in platforms for item in (['OSX', 'macOS'] if platform == 'macOS' else ['iOS'])), 'DISTRIBUTION_PROFILE')
    if signed_entitlements is not None:
        for key in ['com.apple.developer.icloud-container-identifiers',
                    'com.apple.developer.icloud-services', 'com.apple.developer.icloud-container-environment']:
            signed = signed_entitlements.get(key)
            allowed = values.get(key)
            require(signed is not None and allowed is not None, 'PROFILE_CLOUDKIT')
            requested = signed if isinstance(signed, list) else [signed]
            authorized = allowed if isinstance(allowed, list) else [allowed]
            require(all(item in authorized for item in requested), 'PROFILE_CLOUDKIT')
    if certificate is not None:
        certificates = profile.get('DeveloperCertificates')
        require(isinstance(certificates, list) and all(isinstance(item, bytes) for item in certificates)
                and isinstance(certificate, bytes) and bool(certificate) and certificate in certificates, 'PROFILE_CERTIFICATE')


def reject_secret_file(path):
    # Detect actual PEM bodies; marker literals in parsers and tests are harmless.
    if path.stat().st_size > 2 * 1024 * 1024:
        return
    value = path.read_text(encoding='utf-8', errors='replace')
    require(not re.search(r'-----BEGIN (?:OPENSSH |RSA |EC |ENCRYPTED )?PRIVATE KEY-----\s+[A-Za-z0-9+/=]{40,}', value), 'SOURCE_SECRET: ' + path.name)


def command(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
    require(result.returncode == 0, 'TOOL_FAILED: ' + Path(arguments[0]).name)
    return result.stdout, result.stderr


def check_source(root):
    validate_privacy(read_plist(root / 'apple/Privacy/PrivacyInfo.xcprivacy'))
    validate_privacy(read_plist(root / 'apple/Privacy/MCPHelper.xcprivacy'), helper=True)
    options = read_plist(root / 'apple/Release/ExportOptions.plist')
    require(options.get('method') == 'app-store-connect' and options.get('destination') == 'export'
            and options.get('teamID') == TEAM and options.get('manageAppVersionAndBuildNumber') is False,
            'EXPORT_OPTIONS_MUST_BE_LOCAL_ONLY')
    for directory in ['apple/Shared', 'apple/Features', 'apple/Apps', 'rust-core/crates', 'scripts']:
        for path in (root / directory).rglob('*'):
            if path.is_file() and path.suffix in {'.swift', '.rs', '.sh', '.py', '.plist', '.json', '.toml', '.xcprivacy'}:
                reject_secret_file(path)
    for platform in ['macOS', 'iOS']:
        icon = root / 'apple/Apps' / platform / 'Assets.xcassets/AppIcon.appiconset'
        contents = json.loads((icon / 'Contents.json').read_text(encoding='utf-8'))
        require(all((icon / item['filename']).is_file() for item in contents['images'] if 'filename' in item), 'APP_ICON_MISSING')
        require((icon / 'AppIcon-1024.png').is_file(), 'APP_ICON_1024_MISSING')


def signature(bundle):
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)])
    _, information = command(['/usr/bin/codesign', '-dvv', str(bundle)])
    match = re.search(rb'^TeamIdentifier=(.+)$', information, re.MULTILINE)
    validate_signature_team(match.group(1).decode('utf-8') if match else '')
    validate_certificate_authorities([item.decode('utf-8') for item in re.findall(rb'^Authority=(.+)$', information, re.MULTILINE)])
    output, error = command(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)])
    raw = output if b'<?xml' in output else error
    start = raw.find(b'<?xml')
    require(start >= 0, 'DISTRIBUTION_ENTITLEMENT')
    # Only temporary certificate files are written. Never alter the checked app
    # or print profile/certificate contents; the temporary directory is removed.
    with tempfile.TemporaryDirectory(prefix='ConnDock-release-cert-') as directory:
        prefix = str(Path(directory) / 'certificate')
        command(['/usr/bin/codesign', '-d', '--extract-certificates', prefix, str(bundle)])
        leaf = Path(prefix + '0').read_bytes()
    return plistlib.loads(raw[start:]), leaf


def read_strings(path):
    require(path.is_file() and path.stat().st_size <= 64 * 1024, 'LOCAL_NETWORK_LOCALIZATION')
    try:
        value = plistlib.loads(path.read_bytes())
    except plistlib.InvalidFileException:
        output, _ = command(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', str(path)])
        value = plistlib.loads(output)
    require(isinstance(value, dict), 'LOCAL_NETWORK_LOCALIZATION')
    return value


def check_app(app, mode):
    app = app.resolve()
    require(app.is_dir() and app.suffix == '.app', 'APP_PATH')
    platform = 'macOS' if (app / 'Contents/Info.plist').is_file() else 'iOS'
    base = app / 'Contents' if platform == 'macOS' else app
    info = read_plist(base / 'Info.plist')
    validate_identity(info, platform, mode)
    if mode == 'local':
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    require(info.get('CFBundleExecutable') == 'ConnDock', 'APP_EXECUTABLE')
    executable = base / 'MacOS/ConnDock' if platform == 'macOS' else base / 'ConnDock'
    output, _ = command(['/usr/bin/xcrun', 'lipo', '-archs', str(executable)])
    require(output.strip() == b'arm64', 'APP_ARCHITECTURE')
    resources = base / 'Resources' if platform == 'macOS' else base
    validate_privacy(read_plist(resources / 'PrivacyInfo.xcprivacy'))
    require(bool(info.get('NSLocalNetworkUsageDescription')), 'LOCAL_NETWORK_DESCRIPTION')
    for language in ['en', 'zh-Hans']:
        value = read_strings(resources / (language + '.lproj/InfoPlist.strings'))
        require(isinstance(value.get('NSLocalNetworkUsageDescription'), str)
                and value['NSLocalNetworkUsageDescription'].strip(), 'LOCAL_NETWORK_LOCALIZATION')
    require(not any(app.rglob('ConnDockIntegration.json')) and not any(app.rglob('MCPTest*.json')), 'PACKAGED_TEST_CONFIGURATION')
    if mode == 'distribution':
        entitlements, certificate = signature(app)
        validate_entitlements(entitlements, platform, False, mode)
        profile = base / ('embedded.provisionprofile' if platform == 'macOS' else 'embedded.mobileprovision')
        require(profile.is_file() and profile.stat().st_size <= 2 * 1024 * 1024, 'DISTRIBUTION_PROFILE')
        raw, _ = command(['/usr/bin/security', 'cms', '-D', '-i', str(profile)])
        validate_profile(plistlib.loads(raw), info['CFBundleIdentifier'], platform, entitlements, certificate)
    if platform == 'macOS':
        helper = base / 'Helpers/ConnDockMCP.app'
        helper_info = read_plist(helper / 'Contents/Info.plist')
        require(helper_info.get('CFBundleIdentifier') == info['CFBundleIdentifier'] + '.mcp'
                and helper_info.get('CFBundleVersion') == info['CFBundleVersion'], 'HELPER_IDENTITY_VERSION')
        validate_privacy(read_plist(helper / 'Contents/Resources/PrivacyInfo.xcprivacy'), helper=True)
        output, _ = command(['/usr/bin/xcrun', 'lipo', '-archs', str(helper / 'Contents/MacOS/conndock-mcp')])
        require(output.strip() == b'arm64', 'HELPER_ARCHITECTURE')
        if mode == 'distribution':
            helper_entitlements, _ = signature(helper)
            validate_entitlements(helper_entitlements, 'macOS', True, mode)
    else:
        require(not (base / 'Helpers').exists(), 'IOS_MUST_NOT_PACKAGE_MCP')
    return platform


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only', action='store_true')
    parser.add_argument('--mode', choices=['local', 'distribution'], default='distribution')
    parser.add_argument('--app', type=Path)
    arguments = parser.parse_args()
    try:
        check_source(ROOT)
        if not arguments.source_only:
            require(arguments.app is not None, 'APP_ARGUMENT_REQUIRED')
            platform = check_app(arguments.app, arguments.mode)
            print(json.dumps({'status': 'passed', 'scope': arguments.mode, 'platform': platform, 'app': str(arguments.app), 'distribution_checks_passed': arguments.mode == 'distribution', 'apple_submission_accepted': False}, ensure_ascii=False))
        else:
            print(json.dumps({'status': 'passed', 'scope': 'source-only', 'distribution_accepted': False}))
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        code = str(error) if isinstance(error, ReleaseError) else type(error).__name__
        print(json.dumps({'status': 'blocked', 'code': code, 'distribution_accepted': False}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
