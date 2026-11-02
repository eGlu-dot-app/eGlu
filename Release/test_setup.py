import copy
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release_setup", Path(__file__).with_name("setup.py"))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            "TeamIdentifier": ["TEAM"],
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "DeveloperCertificates": [b"certificate"],
            "Entitlements": {
                "application-identifier": "TEAM.test.app",
                "com.apple.developer.icloud-container-identifiers": ["iCloud.test.app"],
                "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
                "com.apple.developer.icloud-container-environment": ["Development", "Production"],
                "aps-environment": "production",
                "com.apple.developer.web-browser": True,
                "com.apple.developer.ubiquity-kvstore-identifier": "TEAM.test.app",
            },
        }

    def check(self, profile=None, ios=True):
        setup.check_profile(profile or self.profile, hashlib.sha256(b"certificate").hexdigest(), "TEAM", "test.app", ios)

    def test_ios_distribution_profile(self):
        self.check()

    def test_mac_profile(self):
        entitlements = self.profile["Entitlements"]
        entitlements["com.apple.application-identifier"] = entitlements.pop("application-identifier")
        entitlements["com.apple.developer.aps-environment"] = entitlements.pop("aps-environment")
        self.check(ios=False)

    def test_apple_wildcard_grants(self):
        self.profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        self.profile["Entitlements"]["com.apple.developer.ubiquity-kvstore-identifier"] = "TEAM.*"
        self.check()
        self.assertFalse(setup.grants("OTHER.*", "TEAM.test.app"))

    def test_valid_older_profile_is_used(self):
        invalid = copy.deepcopy(self.profile)
        invalid["Entitlements"].pop("com.apple.developer.icloud-services")
        self.profile["UUID"] = "test-profile"
        profiles = []
        for name, date, content in (("Invalid", "2099-02-01", b"invalid"), ("Valid", "2099-01-01", b"valid")):
            profiles.append({"attributes": {"name": name, "expirationDate": date,
                "profileContent": base64.b64encode(content).decode()}, "relationships": {
                "bundleId": {"data": {"id": "bundle"}}, "certificates": {"data": [{"id": "cert"}]}}})
        responses = [{"data": [{"id": "bundle", "attributes": {"identifier": "test.app"}}]},
                     {"data": [{"id": "cert", "attributes": {"certificateContent": base64.b64encode(b"certificate").decode()}}]},
                     {"data": profiles}]
        def decode(*args, data):
            value = invalid if data == b"invalid" else self.profile
            value = copy.deepcopy(value)
            value["ExpirationDate"] = value["ExpirationDate"].replace(tzinfo=None)
            return subprocess.CompletedProcess([], 0, plistlib.dumps(value), b"")
        with tempfile.TemporaryDirectory() as home, patch.object(setup.Path, "home", return_value=Path(home)), \
             patch.object(setup, "asc", side_effect=responses), patch.object(setup, "run", side_effect=decode):
            name = setup.install_profile("IOS_APP_STORE", {"sha256": hashlib.sha256(b"certificate").hexdigest()}, "TEAM", "test.app", False)
            self.assertEqual(name, "Valid")

    def test_subprocesses_receive_only_their_required_secrets(self):
        values = {name: "test-private-value" for name in setup.SECRET_NAMES}
        values["GH_TOKEN"] = "test-github-token"
        with patch.dict(setup.os.environ, values), patch.object(setup.subprocess, "run") as run:
            run.return_value.returncode = 0
            setup.run(["tool", "command"])
            self.assertFalse(set(values) & set(run.call_args.kwargs["env"]))
            setup.run(["asc", "command"], secrets_allowed=("ASC_KEY_ID",))
            self.assertEqual(set(values) & set(run.call_args.kwargs["env"]), {"ASC_KEY_ID"})

    def test_untrusted_sparkle_archive_is_not_extracted(self):
        with tempfile.TemporaryDirectory() as root, patch.object(setup, "ROOT", Path(root)), patch.object(setup, "run") as run:
            folder = Path(root) / "build" / f"sparkle-{setup.SPARKLE_VERSION}"
            folder.mkdir(parents=True)
            (folder / f"Sparkle-{setup.SPARKLE_VERSION}.tar.xz").write_bytes(b"untrusted archive")
            with self.assertRaisesRegex(ValueError, "pinned digest"):
                setup.sparkle_tools()
            run.assert_not_called()

    def test_notary_key_is_removed_and_ram_disk_detached_on_failure(self):
        paths = {}
        def command(args):
            if args[:2] == ["hdiutil", "attach"]:
                output = b"/dev/disk999\n"
            elif args[:2] == ["diskutil", "mount"]:
                paths["mount"] = args[3]
                output = b""
            elif args[:2] == ["diskutil", "info"]:
                output = plistlib.dumps({"MountPoint": str(paths["mount"])})
            elif args[:2] == ["xcrun", "notarytool"]:
                paths["key"] = args[5]
                self.assertEqual(paths["key"].stat().st_mode & 0o777, 0o600)
                self.assertEqual(paths["key"].read_text(), "unit-test-value")
                raise RuntimeError("notary failure")
            else:
                output = b""
            return subprocess.CompletedProcess(args, 0, output, b"")
        values = {"ASC_PRIVATE_KEY": "unit-test-value", "ASC_KEY_ID": "test-id", "ASC_ISSUER_ID": "test-issuer"}
        with tempfile.TemporaryDirectory() as root, patch.dict(setup.os.environ, values), \
             patch.object(setup.os.path, "ismount", return_value=True), patch.object(setup, "run", side_effect=command) as run:
            with self.assertRaisesRegex(RuntimeError, "notary failure"):
                setup.store_notary_credentials(Path(root) / "test.keychain-db")
            self.assertFalse(paths["key"].exists())
            self.assertEqual(run.call_args.args[0], ["hdiutil", "detach", "-force", "/dev/disk999"])

    def test_invalid_identity_and_entitlements(self):
        for key, value in (("TeamIdentifier", ["OTHER"]), ("DeveloperCertificates", [b"other"]),
                           ("ExpirationDate", datetime.now(timezone.utc) - timedelta(days=1))):
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile[key] = value
                with self.assertRaises(ValueError):
                    self.check(profile)
        for key, value in (("aps-environment", "development"), ("get-task-allow", True),
                           ("com.apple.developer.web-browser", False),
                           ("com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
                           ("application-identifier", "TEAM.other")):
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    self.check(profile)

    def test_passwords_are_not_process_arguments(self):
        with patch.object(setup, "run") as run:
            run.return_value.stderr = b""
            setup.security_command(["unlock-keychain", "-p", 'sensitive"password', "test.keychain"])
            self.assertEqual(run.call_args.args[0], ["security", "-i"])
            self.assertNotIn("sensitive", str(run.call_args.args))

    def test_keychain_command_injection_is_rejected(self):
        with self.assertRaises(ValueError):
            setup.security_command(["unlock-keychain", "-p", "password\ndelete-keychain other"])


if __name__ == "__main__":
    unittest.main()
