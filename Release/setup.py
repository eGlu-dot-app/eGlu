#!/usr/bin/env python3
"""Restore release credentials at session runtime, never during a snapshot build."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_VERSION = "2.10.0"
SPARKLE_SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SECRET_NAMES = (
    "ASC_PRIVATE_KEY", "ASC_KEY_ID", "ASC_ISSUER_ID",
    "IOS_DISTRIBUTION_P12_B64", "IOS_DISTRIBUTION_P12_PASSWORD",
    "MAC_DEVELOPER_ID_P12_B64", "MAC_DEVELOPER_ID_P12_PASSWORD", "SPARKLE_PRIVATE_KEY",
)


def run(args, *, data=None, check=True, secrets_allowed=()):
    private = set(SECRET_NAMES) | {"GH_TOKEN", "GITHUB_TOKEN", "GITHUB_TOKEN_EGLU"}
    env = {key: value for key, value in os.environ.items() if key not in private or key in secrets_allowed}
    try:
        result = subprocess.run(list(map(str, args)), input=data, capture_output=True, env=env, timeout=120)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{args[0]} {args[1]} timed out; check for a Keychain authorization prompt") from None
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode}); output withheld to protect credentials")
    return result


def security_command(args):
    # Send passwords through stdin, not process arguments or plaintext files.
    if any("\n" in str(arg) or "\r" in str(arg) or "\0" in str(arg) for arg in args):
        raise ValueError("Keychain command arguments cannot contain line breaks or NUL")
    line = " ".join('"' + str(arg).replace('\\', '\\\\').replace('"', '\\"') + '"' for arg in args)
    result = run(["security", "-i"], data=(line + "\n").encode())
    if re.search(rb"(?:SecKeychain|SecItem|error:|Error:|Usage:)", result.stderr):
        raise RuntimeError("Keychain operation failed; output withheld to protect credentials")


def asc(*args):
    return json.loads(run(["asc", *args], secrets_allowed=("ASC_PRIVATE_KEY", "ASC_KEY_ID", "ASC_ISSUER_ID")).stdout)


def keychain_password():
    # A domain-separated derivation avoids depending on the VM's login password.
    return hmac.new(os.environ["ASC_PRIVATE_KEY"].strip().encode(),
                    b"net.taehee.safience.release-signing-keychain.v2", hashlib.sha256).hexdigest()


def signing_identity(prefix, expected_name, team):
    script = '''require 'openssl'; require 'base64'; require 'json'
p = OpenSSL::PKCS12.new(Base64.decode64(ENV.fetch(ARGV[0] + '_P12_B64')), ENV.fetch(ARGV[0] + '_P12_PASSWORD'))
c = p.certificate
abort 'Certificate or private key invalid' unless p.key && c.check_private_key(p.key) && c.not_before <= Time.now && c.not_after > Time.now
puts JSON.generate({name: c.subject.to_a.assoc('CN')[1], team: c.subject.to_a.assoc('OU')[1],
  issuer: c.issuer.to_a.assoc('CN')[1], issuerUnit: c.issuer.to_a.assoc('OU')&.[](1),
  sha1: OpenSSL::Digest::SHA1.hexdigest(c.to_der).upcase, sha256: OpenSSL::Digest::SHA256.hexdigest(c.to_der)})'''
    identity = json.loads(run(["/usr/bin/ruby", "-e", script, prefix],
                              secrets_allowed=(prefix + "_P12_B64", prefix + "_P12_PASSWORD")).stdout)
    if not identity["name"].startswith(expected_name + ":") or identity["team"] != team:
        raise ValueError(f"{prefix} is not a {expected_name} identity for {team}")
    return identity


def complete_certificate_chain(identity, keychain):
    valid = run(["security", "find-identity", "-v", "-p", "codesigning", keychain]).stdout.decode()
    if identity["sha1"] in valid:
        return
    unit = identity.get("issuerUnit") or ""
    if identity["issuer"] != "Apple Worldwide Developer Relations Certification Authority" or not re.fullmatch(r"G[2-9]", unit):
        raise ValueError("Signing certificate is not trusted; install its Apple intermediate certificate")
    folder = ROOT / "build"
    folder.mkdir(exist_ok=True)
    certificate = folder / f"AppleWWDRCA{unit}.cer"
    with urllib.request.urlopen(f"https://www.apple.com/certificateauthority/{certificate.name}", timeout=30) as response:
        certificate.write_bytes(response.read())
    run(["security", "verify-cert", "-c", certificate, "-p", "basic"])
    run(["security", "add-certificates", "-k", keychain, certificate])
    valid = run(["security", "find-identity", "-v", "-p", "codesigning", keychain]).stdout.decode()
    if identity["sha1"] not in valid:
        raise ValueError("Signing certificate is still not trusted after installing its Apple intermediate")


def store_notary_credentials(keychain):
    # notarytool rejects pipes; its regular key file lives only on a RAM disk.
    output = run(["hdiutil", "attach", "-nomount", "ram://32768"]).stdout.decode()
    device = re.fullmatch(r"(/dev/disk[0-9]+)\s*", output)[1]
    key = None
    private = tempfile.TemporaryDirectory(prefix="notary-", dir=keychain.parent)
    try:
        label = "eGluNotary" + os.urandom(4).hex()
        run(["diskutil", "eraseVolume", "HFS+", label, device])
        run(["diskutil", "unmount", device])
        mount = Path(private.name) / "mount"
        mount.mkdir(mode=0o700)
        run(["diskutil", "mount", "-mountPoint", mount, device])
        info = plistlib.loads(run(["diskutil", "info", "-plist", device]).stdout)
        if info.get("MountPoint") != str(mount) or not os.path.ismount(mount):
            raise RuntimeError("RAM disk did not mount beneath the private directory")
        folder = Path(info["MountPoint"]) / "credentials"
        folder.mkdir(mode=0o700)
        key = folder / "AuthKey.p8"
        with os.fdopen(os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
            file.write(os.environ["ASC_PRIVATE_KEY"])
        run(["xcrun", "notarytool", "store-credentials", "safience", "--key", key, "--key-id",
             os.environ["ASC_KEY_ID"], "--issuer", os.environ["ASC_ISSUER_ID"], "--keychain", keychain])
    finally:
        try:
            if key is not None:
                key.unlink(missing_ok=True)
        finally:
            run(["hdiutil", "detach", "-force", device])
            private.cleanup()


def sparkle_tools():
    folder = ROOT / "build" / f"sparkle-{SPARKLE_VERSION}"
    folder.mkdir(parents=True, exist_ok=True)
    name = f"Sparkle-{SPARKLE_VERSION}.tar.xz"
    archive = folder / name
    if not archive.exists():
        run(["gh", "release", "download", SPARKLE_VERSION, "--repo", "sparkle-project/Sparkle",
             "--pattern", name, "--dir", folder], secrets_allowed=("GH_TOKEN", "GITHUB_TOKEN"))
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_SHA256:
        raise ValueError("Sparkle archive does not match the pinned digest")
    run(["/usr/bin/tar", "-xf", archive, "-C", folder])
    return folder / "bin"


def check_profile(profile, fingerprint, team, bundle, ios):
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Provisioning profile has expired")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("Provisioning profile belongs to another team")
    if fingerprint not in [hashlib.sha256(cert).hexdigest() for cert in profile["DeveloperCertificates"]]:
        raise ValueError("Provisioning profile does not contain the supplied signing certificate")
    entitlements = profile["Entitlements"]
    identifier = entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier"))
    required = {
        "com.apple.developer.icloud-container-identifiers": ["iCloud." + bundle],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Production",
        "aps-environment" if ios else "com.apple.developer.aps-environment": "production",
    }
    if identifier != team + "." + bundle or entitlements.get("get-task-allow", False):
        raise ValueError("Profile is not for distribution of this bundle")
    if ios:
        required["com.apple.developer.web-browser"] = True
        required["com.apple.developer.ubiquity-kvstore-identifier"] = team + "." + bundle
    for key, value in required.items():
        if not grants(entitlements.get(key), value):
            raise ValueError(f"Profile does not grant required entitlement: {key}")


def grants(actual, required):
    if isinstance(required, list):
        return all(grants(actual, item) for item in required)
    if isinstance(actual, list):
        return any(grants(item, required) for item in actual)
    if isinstance(actual, str) and isinstance(required, str):
        return re.fullmatch(re.escape(actual).replace(r"\*", ".*"), required) is not None
    return actual == required


def install_profile(profile_type, identity, team, bundle, create):
    bundles = asc("bundle-ids", "list", "--identifier", bundle, "--paginate")["data"]
    bundle_id = next(item["id"] for item in bundles if item["attributes"]["identifier"] == bundle)
    certificates = asc("certificates", "list", "--paginate")["data"]
    certificate_id = next(item["id"] for item in certificates if hashlib.sha256(
        base64.b64decode(item["attributes"]["certificateContent"])).hexdigest() == identity["sha256"])
    profiles = asc("profiles", "list", "--profile-type", profile_type, "--profile-state", "ACTIVE",
                   "--include", "bundleId,certificates", "--paginate")["data"]
    matches = [item for item in profiles if item["relationships"]["bundleId"]["data"]["id"] == bundle_id
               and any(cert["id"] == certificate_id for cert in item["relationships"]["certificates"]["data"])]
    if not matches:
        if not create:
            raise RuntimeError(f"No active {profile_type} profile matches this certificate; use --create-ios-profile for iOS only")
        print("Creating an iOS App Store profile with the existing certificate", flush=True)
        matches = [asc("profiles", "create", "--name", "eGlu App Store", "--profile-type", profile_type,
                       "--bundle", bundle_id, "--certificate", certificate_id)["data"]]
    failures = []
    for item in sorted(matches, key=lambda p: p["attributes"]["expirationDate"], reverse=True):
        attributes = item["attributes"]
        content = base64.b64decode(attributes["profileContent"])
        decoded = run(["security", "cms", "-D"], data=content).stdout
        profile = plistlib.loads(decoded)
        try:
            check_profile(profile, identity["sha256"], team, bundle, profile_type == "IOS_APP_STORE")
            break
        except ValueError as error:
            failures.append(str(error))
    else:
        raise ValueError("No matching profile has valid release entitlements: " + "; ".join(failures))
    folder = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    folder.mkdir(parents=True, exist_ok=True)
    suffix = ".mobileprovision" if profile_type == "IOS_APP_STORE" else ".provisionprofile"
    (folder / (profile["UUID"] + suffix)).write_bytes(content)
    print(f"Installed {attributes['name']} ({profile_type}, expires {attributes['expirationDate'][:10]})", flush=True)
    return attributes["name"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", required=True)
    parser.add_argument("--create-ios-profile", action="store_true", help="Allow creation of a missing iOS App Store profile")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Release signing requires macOS")
    missing = [name for name in SECRET_NAMES if not os.environ.get(name)]
    if missing:
        parser.error("Bind these secure secrets to this command: " + ", ".join(missing))
    os.environ["ASC_BYPASS_KEYCHAIN"] = "1"
    bundle = next(line.split("=", 1)[1].strip() for line in (ROOT / "Config/Signing.xcconfig").read_text().splitlines()
                  if line.startswith("PRODUCT_BUNDLE_IDENTIFIER"))
    state = Path.home() / ".local/share/eglu-release"
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    password = keychain_password()
    keychain = state / ("signing-" + hashlib.sha256(password.encode()).hexdigest()[:12] + ".keychain-db")
    if not keychain.exists():
        security_command(["create-keychain", "-p", password, keychain])
    security_command(["unlock-keychain", "-p", password, keychain])
    run(["security", "set-keychain-settings", "-lut", "21600", keychain])
    search = shlex.split(run(["security", "list-keychains", "-d", "user"]).stdout.decode())
    run(["security", "list-keychains", "-d", "user", "-s", keychain,
         *[path for path in search if not path.startswith(str(state) + "/")]])
    identities = []
    for prefix, kind in (("IOS_DISTRIBUTION", "Apple Distribution"), ("MAC_DEVELOPER_ID", "Developer ID Application")):
        identity = signing_identity(prefix, kind, args.team)
        identities.append(identity)
        known = run(["security", "find-identity", "-p", "codesigning", keychain]).stdout.decode()
        if identity["sha1"] not in known:
            with tempfile.TemporaryDirectory(prefix="eglu-signing-") as temp:
                archive = Path(temp) / "identity.p12"
                archive.write_bytes(base64.b64decode(os.environ[prefix + "_P12_B64"]))
                archive.chmod(0o600)
                security_command(["import", archive, "-k", keychain, "-f", "pkcs12", "-x", "-P",
                                  os.environ[prefix + "_P12_PASSWORD"], "-T", "/usr/bin/codesign"])
        complete_certificate_chain(identity, keychain)
        print(f"Restored {kind} for {args.team}", flush=True)
    print("Configuring signing Keychain access", flush=True)
    security_command(["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain])
    print("Restoring the existing Sparkle key", flush=True)
    tools = sparkle_tools()
    expected = re.search(r"SPARKLE_PUBLIC_KEY: (\S+)", (ROOT / "project.yml").read_text())[1]
    existing = run(["security", "find-generic-password", "-s", "https://sparkle-project.org",
                    "-a", "safience", keychain], check=False)
    if existing.returncode:
        value = os.environ["SPARKLE_PRIVATE_KEY"].strip()
        if len(base64.b64decode(value, validate=True)) not in (32, 96):
            raise ValueError("Sparkle private key must encode a seed or an existing key pair")
        security_command(["add-generic-password", "-s", "https://sparkle-project.org", "-a", "safience",
                          "-l", "Private key for signing Sparkle updates", "-T", tools / "generate_keys",
                          "-T", tools / "sign_update", "-w", value, keychain])
    partitions = ["apple-tool:", "apple:"]
    for name in ("generate_keys", "sign_update"):
        signature = run(["codesign", "-dv", "--verbose=4", tools / name]).stderr.decode()
        partitions.append("cdhash:" + re.search(r"(?m)^CDHash=(\w+)$", signature)[1])
    security_command(["set-generic-password-partition-list", "-a", "safience", "-s", "https://sparkle-project.org",
                      "-S", ",".join(partitions), "-k", password, keychain])
    public = run([tools / "generate_keys", "--account", "safience", "-p"]).stdout.decode().strip()
    if public != expected:
        raise ValueError("Stored Sparkle key does not match the configured public key; refusing to replace it")
    print("Sparkle public key matches project.yml", flush=True)
    store_notary_credentials(keychain)
    print("Notarization credentials validated and stored in the release Keychain", flush=True)
    ios = install_profile("IOS_APP_STORE", identities[0], args.team, bundle, args.create_ios_profile)
    mac = install_profile("MAC_APP_DIRECT", identities[1], args.team, bundle, False)
    config = Path.home() / ".config/eglu-release"
    config.mkdir(parents=True, exist_ok=True, mode=0o700)
    exports = {"DEVELOPMENT_TEAM": args.team, "ICLOUD": "1", "PROFILE": mac, "IOS_PROFILE": ios,
               "NOTARY_PROFILE": "safience", "NOTARY_KEYCHAIN": str(keychain), "ASC_BYPASS_KEYCHAIN": "1"}
    lines = ["# Generated non-secret settings. Do not source with shell tracing enabled.",
             'case $- in *x*) echo "Disable shell tracing before loading credentials" >&2; return 1;; esac']
    lines += [f"export {name}={shlex.quote(value)}" for name, value in exports.items()]
    environment = config / "environment.sh"
    environment.write_text("\n".join(lines) + "\n")
    environment.chmod(0o600)
    print(f"Ready. Load release settings: source {environment}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, StopIteration) as error:
        sys.exit(str(error) or "A matching signing resource was not found")
