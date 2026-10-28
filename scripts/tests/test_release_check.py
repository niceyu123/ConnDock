import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location('release_check', Path(__file__).parents[1] / 'check-release.py')
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


def manifest():
    return {'NSPrivacyTracking': False, 'NSPrivacyTrackingDomains': [], 'NSPrivacyCollectedDataTypes': [],
            'NSPrivacyAccessedAPITypes': [
                {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']},
                {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryFileTimestamp', 'NSPrivacyAccessedAPITypeReasons': ['C617.1', '3B52.1']},
                {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategorySystemBootTime', 'NSPrivacyAccessedAPITypeReasons': ['35F9.1']}]}


class ReleaseCheckTests(unittest.TestCase):
    def test_privacy_rejects_missing_or_incompatible_reasons(self):
        release.validate_privacy(manifest(), helper=False)
        bad = manifest()
        bad['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'] = ['35F9.1']
        with self.assertRaisesRegex(release.ReleaseError, 'PRIVACY_REASON'):
            release.validate_privacy(bad, helper=False)
        bad = manifest()
        bad['NSPrivacyAccessedAPITypes'].pop()
        with self.assertRaisesRegex(release.ReleaseError, 'PRIVACY_CATEGORY'):
            release.validate_privacy(bad, helper=False)

    def test_privacy_cannot_claim_no_tracking_when_tracking_is_enabled(self):
        for field, value in [('NSPrivacyTracking', True), ('NSPrivacyTrackingDomains', ['tracker.invalid']), ('NSPrivacyCollectedDataTypes', [{}])]:
            bad = manifest()
            bad[field] = value
            with self.assertRaisesRegex(release.ReleaseError, 'PRIVACY_SCOPE'):
                release.validate_privacy(bad, helper=False)

    def test_distribution_rejects_local_and_unclassified_ssh_encryption(self):
        info = {'CFBundleIdentifier': 'local.SSHClient.macOS', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'ConnDockBuildConfiguration': 'Local'}
        with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_IDENTITY'):
            release.validate_identity(info, platform='macOS', mode='distribution')
        info.update(CFBundleIdentifier='com.ruohai.conndock', ConnDockBuildConfiguration='Release')
        with self.assertRaisesRegex(release.ReleaseError, 'EXPORT_COMPLIANCE'):
            release.validate_identity(info, platform='macOS', mode='distribution')
        info['ITSAppUsesNonExemptEncryption'] = True
        with self.assertRaisesRegex(release.ReleaseError, 'EXPORT_DOCUMENTATION'):
            release.validate_identity(info, platform='macOS', mode='distribution')
        info['ITSEncryptionExportComplianceCode'] = 'test-fixture-review-code'
        release.validate_identity(info, platform='macOS', mode='distribution')

    def test_distribution_rejects_adhoc_debugger_and_helper_privilege_changes(self):
        main = {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                'com.apple.security.network.server': True, 'com.apple.security.application-groups': ['86HC8YA388.com.ruohai.conndock.mcp'],
                'com.apple.developer.icloud-container-identifiers': ['iCloud.com.ruohai.conndock'],
                'com.apple.developer.icloud-container-environment': 'Production',
                'com.apple.developer.icloud-services': ['CloudKit']}
        helper = {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                  'com.apple.security.application-groups': ['86HC8YA388.com.ruohai.conndock.mcp']}
        release.validate_entitlements(main, platform='macOS', helper=False, mode='distribution')
        for field in ['com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation', 'com.apple.security.inherit']:
            bad = dict(helper, **{field: True})
            with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_ENTITLEMENT'):
                release.validate_entitlements(bad, platform='macOS', helper=True, mode='distribution')
        with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_TEAM'):
            release.validate_signature_team('not set')

    def test_development_certificate_and_cloudkit_environment_are_not_distribution(self):
        with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_CERTIFICATE'):
            release.validate_certificate_authorities(['Apple Development: Fixture (86HC8YA388)'])
        release.validate_certificate_authorities(['Apple Distribution: Fixture (86HC8YA388)'])
        with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_CLOUDKIT'):
            release.validate_entitlements({}, platform='iOS', helper=False, mode='distribution')

    def test_profile_is_bound_to_team_bundle_platform_and_expiry(self):
        import datetime
        profile = {'TeamIdentifier': ['86HC8YA388'], 'ExpirationDate': datetime.datetime(2099, 1, 1),
                   'Platform': ['OSX'], 'Entitlements': {'com.apple.application-identifier': '86HC8YA388.com.ruohai.conndock', 'get-task-allow': False}}
        release.validate_profile(profile, 'com.ruohai.conndock', 'macOS')
        for key, value in [('TeamIdentifier', ['OTHERTEAM']), ('ExpirationDate', datetime.datetime(2000, 1, 1)), ('Platform', ['iOS']), ('ProvisionedDevices', ['fixture-device']), ('ProvisionsAllDevices', True)]:
            bad = dict(profile, **{key: value})
            with self.assertRaisesRegex(release.ReleaseError, 'DISTRIBUTION_PROFILE'):
                release.validate_profile(bad, 'com.ruohai.conndock', 'macOS')

    def test_profile_must_authorize_actual_cloudkit_entitlements_and_leaf_certificate(self):
        import datetime
        cloud = {'com.apple.developer.icloud-container-identifiers': ['iCloud.com.ruohai.conndock'],
                 'com.apple.developer.icloud-container-environment': 'Production',
                 'com.apple.developer.icloud-services': ['CloudKit']}
        profile = {'TeamIdentifier': ['86HC8YA388'], 'ExpirationDate': datetime.datetime(2099, 1, 1),
                   'Platform': ['OSX'], 'DeveloperCertificates': [b'fixture-certificate'],
                   'Entitlements': dict(cloud, **{'com.apple.application-identifier': '86HC8YA388.com.ruohai.conndock'})}
        release.validate_profile(profile, 'com.ruohai.conndock', 'macOS', cloud, b'fixture-certificate')
        with self.assertRaisesRegex(release.ReleaseError, 'PROFILE_CERTIFICATE'):
            release.validate_profile(profile, 'com.ruohai.conndock', 'macOS', cloud, b'other-certificate')
        profile['Entitlements']['com.apple.developer.icloud-container-environment'] = 'Development'
        with self.assertRaisesRegex(release.ReleaseError, 'PROFILE_CLOUDKIT'):
            release.validate_profile(profile, 'com.ruohai.conndock', 'macOS', cloud, b'fixture-certificate')

    def test_local_check_still_rejects_wrong_bundle_or_missing_version(self):
        info = {'CFBundleIdentifier': 'local.SSHClient.iOS', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1', 'ConnDockBuildConfiguration': 'Local'}
        release.validate_identity(info, platform='iOS', mode='local')
        with self.assertRaisesRegex(release.ReleaseError, 'BUNDLE_IDENTITY'):
            release.validate_identity(info, platform='macOS', mode='local')
        info['CFBundleVersion'] = ''
        with self.assertRaisesRegex(release.ReleaseError, 'BUILD_VERSION'):
            release.validate_identity(info, platform='iOS', mode='local')

    def test_compiled_binary_permission_strings_are_read_as_a_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'InfoPlist.strings'
            path.write_bytes(plistlib.dumps({'NSLocalNetworkUsageDescription': 'Selected SSH servers only'}, fmt=plistlib.FMT_BINARY))
            self.assertEqual(release.read_strings(path)['NSLocalNetworkUsageDescription'], 'Selected SSH servers only')

    def test_literal_secret_fixture_is_detected_without_returning_contents(self):
        secret = ('-----BEGIN OPENSSH PRIVATE KEY-----\n' + 'Q' * 80 + '\n-----END OPENSSH PRIVATE KEY-----')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.swift'
            path.write_text(secret, encoding='utf-8')
            with self.assertRaisesRegex(release.ReleaseError, 'SOURCE_SECRET') as caught:
                release.reject_secret_file(path)
            self.assertNotIn('Q' * 40, str(caught.exception))


if __name__ == '__main__':
    unittest.main()
