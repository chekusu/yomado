#!/usr/bin/env python3
"""Disposable hosted-runner identity/permission setup; never a product feature."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import secrets
import shlex
import subprocess
import sys
import time


def run(command, *, data=None, timeout=30):
    label = Path(command[0]).name
    if label in {"security", "openssl"}:
        label += " " + command[1]
    elif label == "codesign":
        label += " " + Path(command[-1]).name
    print("[update-runtime] guest identity command: " + label, flush=True)
    try:
        result = subprocess.run(command, input=data, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"guest setup command {label} timed out") from None
    if result.returncode:
        # Keep private temporary key locations/password arguments out of logs.
        if Path(command[0]).name == "codesign":
            # codesign receives no password. Retain its error reason while
            # suppressing temporary paths and bounding arbitrary diagnostics.
            diagnostic = result.stderr
            for argument in sorted((x for x in command if x.startswith("/")), key=len, reverse=True):
                diagnostic = diagnostic.replace(argument, "<fixture-path>")
            diagnostic = re.sub(r"/(?:Users|private|var|tmp)/[^\n:]*", "<fixture-path>", diagnostic)
            print("[update-runtime] codesign diagnostic: " + diagnostic[:1600], file=sys.stderr, flush=True)
        raise RuntimeError(f"guest setup command {label} exited {result.returncode}")
    return result.stdout, result.stderr


def check_guest(directory):
    user = pwd.getpwuid(os.getuid()).pw_name
    # GitHub's hosted macOS, or a Hayabuild job in a fresh VM of its own (runs-on: [hayabuild-macos, vm]).
    hosted = os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted" and user == "runner"
    hayabuild_vm = os.environ.get("HAYABUILD_DISPOSABLE_VM") == "1" and user == "admin"
    if not (os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_OS") == "macOS" and
            (hosted or hayabuild_vm)):
        raise RuntimeError("Refusing identity/permission changes outside a disposable hosted runner")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    directory = Path(directory).resolve()
    if not directory.is_relative_to(temporary) or directory == temporary:
        raise RuntimeError("Fixture private directory must be below RUNNER_TEMP")
    return directory


def setup(directory):
    directory.mkdir(mode=0o700)
    # Capture before create-keychain, which may itself change the search list.
    original_search_list = keychain_search_list()
    (directory / "original-search-list.json").write_text(json.dumps(original_search_list))
    password = secrets.token_hex(24)
    config = directory / "codesign.cnf"
    config.write_text("""[req]
distinguished_name=dn
x509_extensions=code
prompt=no
[dn]
CN=yomado disposable runtime identity
[code]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyCertSign
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
    key, cert, p12 = (directory / name for name in ("codesign.key", "codesign.crt", "identity.p12"))
    keychain = directory / "identity.keychain-db"
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-sha256",
         "-config", str(config), "-keyout", str(key), "-out", str(cert)])
    fingerprint = run(["openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1"])[0]
    fingerprint = fingerprint.strip().split("=", 1)[1].replace(":", "")
    if not re.fullmatch(r"[A-Fa-f0-9]{40}", fingerprint):
        raise RuntimeError("Invalid fixture certificate fingerprint")
    # Write only public identity metadata before trust setup, so even failed
    # setup can delete precisely this certificate rather than a matching name.
    (directory / "identity.json").write_text(json.dumps({"fingerprint": fingerprint}))
    compatibility = ["-legacy"] if run(["openssl", "version"])[0].startswith("OpenSSL 3") else []
    run(["openssl", "pkcs12", "-export", *compatibility, "-inkey", str(key), "-in", str(cert),
         "-out", str(p12), "-passout", "pass:" + password])
    run(["security", "create-keychain", "-p", password, str(keychain)])
    run(["security", "set-keychain-settings", "-lut", "3600", str(keychain)])
    run(["security", "unlock-keychain", "-p", password, str(keychain)])
    run(["security", "import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign"])
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)])
    # Hosted runners have noninteractive sudo, while a per-user trust change
    # requests GUI authentication. Only this disposable certificate is added.
    run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "codeSign",
         "-k", "/Library/Keychains/System.keychain", str(cert)])
    # --keychain narrows codesign's lookup but does not replace its user search
    # list requirement. Preserve the runner's existing entries and exact order.
    run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *original_search_list])
    verify_signing_identity(directory, fingerprint)


def keychain_search_list(*, timeout=30):
    entries = shlex.split(run(["security", "list-keychains", "-d", "user"], timeout=timeout)[0])
    if not all(Path(value).is_absolute() for value in entries):
        raise RuntimeError("Unexpected user keychain search list")
    return entries


def restore_search_list(directory):
    original = json.loads((directory / "original-search-list.json").read_text())
    if (not isinstance(original, list) or
            not all(isinstance(value, str) and Path(value).is_absolute() and "\x00" not in value for value in original)):
        raise RuntimeError("Invalid original keychain search list")
    run(["security", "list-keychains", "-d", "user", "-s", *original], timeout=8)
    if keychain_search_list(timeout=8) != original:
        raise RuntimeError("Original keychain search list was not restored exactly")


def verify_signing_identity(directory, fingerprint):
    keychain = directory / "identity.keychain-db"
    valid_identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)])[0]
    identities = re.findall(r"\b[A-Fa-f0-9]{40}\b", valid_identities)
    expected = fingerprint.upper() in {x.upper() for x in identities}
    listed = keychain.resolve() in {Path(value).resolve() for value in keychain_search_list()}
    print("[update-runtime] temporary signing identities: " + json.dumps({
        "validCount": len(identities), "expectedPresent": expected,
        "searchListContainsPrivateKeychain": listed}), flush=True)
    if not expected or not listed:
        raise RuntimeError("Temporary signing identity is not available to codesign")


def fixture_app(directory, app):
    app = app.resolve()
    if not app.is_relative_to(directory.parent) or app.suffix != ".app":
        raise RuntimeError("App must be contained in this fixture's private temporary directory")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    identifier = info.get("CFBundleIdentifier")
    if (info.get("YMHostedDisposableFixture") is not True or not isinstance(identifier, str) or
            not identifier.startswith("dev.chekusu.yomado.fixture.")):
        raise RuntimeError("Only marked disposable fixture applications may be signed or authorized")
    return app, info


def sign(directory, app):
    app, _ = fixture_app(directory, app)
    identity = json.loads((directory / "identity.json").read_text())
    verify_signing_identity(directory, identity["fingerprint"])
    framework = app / "Contents/Frameworks/Sparkle.framework"
    components = [framework / name for name in (
        "Versions/B/XPCServices/Installer.xpc", "Versions/B/XPCServices/Downloader.xpc",
        "Versions/B/Autoupdate", "Versions/B/Updater.app")]
    for component in components + [framework, app]:
        if not component.resolve().is_relative_to(app):
            raise RuntimeError("Fixture nested code must remain inside its application bundle")
        run(["codesign", "--force", "--sign", identity["fingerprint"], "--keychain",
             str(directory / "identity.keychain-db"), "--timestamp=none", str(component)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])


def requirement(app):
    output = "\n".join(run(["codesign", "-d", "-r-", str(app)]))
    lines = [line[len("designated => "):] for line in output.splitlines() if line.startswith("designated => ")]
    if len(lines) != 1 or "identifier" not in lines[0] or not any(x in lines[0] for x in ("anchor", "certificate")):
        raise RuntimeError("Fixture identity needs a certificate-bound designated requirement")
    return lines[0]


def grant(directory, old, new, evidence):
    old, old_info = fixture_app(directory, old)
    new, new_info = fixture_app(directory, new)
    client = old_info.get("CFBundleIdentifier")
    if client != "dev.chekusu.yomado.fixture.occupied" or new_info.get("CFBundleIdentifier") != client:
        raise RuntimeError("Permission setup is restricted to the occupied fixture bundle")
    before, after = requirement(old), requirement(new)
    if before != after:
        raise RuntimeError("Fixture versions do not have the same designated requirement")
    for app in (old, new):
        run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + before, str(app)])
    blob_path = directory / "occupied.csreq"
    run(["csreq", "-r", "=" + before, "-b", str(blob_path)])
    blob = blob_path.read_bytes()
    def quote(value):
        if value is None:
            return "NULL"
        if isinstance(value, bytes):
            return "X'" + value.hex() + "'"
        if isinstance(value, int):
            return str(value)
        return "'" + value.replace("'", "''") + "'"
    report = {"bundleID": client, "sameDesignatedRequirement": True, "bothBuildsSatisfyRequirement": True,
              "requirementSHA256": hashlib.sha256(blob).hexdigest(), "databases": []}
    databases = [("system", Path("/Library/Application Support/com.apple.TCC/TCC.db")),
                 ("user", Path.home() / "Library/Application Support/com.apple.TCC/TCC.db")]
    for label, database in databases:
        schema = json.loads(run(["sudo", "-n", "sqlite3", "-json", str(database), "PRAGMA table_info(access);"])[0])
        columns = {row["name"] for row in schema}
        required = {"service", "client", "client_type", "auth_value", "auth_reason", "auth_version", "csreq"}
        if not required.issubset(columns):
            raise RuntimeError("Unsupported guest TCC schema")
        for service in ("kTCCServiceAccessibility", "kTCCServiceScreenCapture"):
            values = {"service": service, "client": client, "client_type": 0, "auth_value": 2,
                      "auth_reason": 4, "auth_version": 1, "csreq": blob, "policy_id": None,
                      "indirect_object_identifier_type": 0, "indirect_object_identifier": "UNUSED",
                      "indirect_object_code_identity": None, "flags": 0, "last_modified": int(time.time()),
                      "pid": None, "pid_version": None, "boot_uuid": "UNUSED", "last_reminded": int(time.time())}
            values = {k: v for k, v in values.items() if k in columns}
            sql = "INSERT OR REPLACE INTO access (" + ",".join(values) + ") VALUES (" + ",".join(quote(v) for v in values.values()) + ");"
            run(["sudo", "-n", "sqlite3", str(database)], data=sql)
            sql = "SELECT auth_value,hex(csreq) AS requirement FROM access WHERE service=" + quote(service) + " AND client=" + quote(client) + " AND client_type=0;"
            rows = json.loads(run(["sudo", "-n", "sqlite3", "-json", str(database), sql])[0])
            if len(rows) != 1 or rows[0]["auth_value"] != 2 or rows[0]["requirement"].lower() != blob.hex():
                raise RuntimeError("Guest permission record did not retain the exact code requirement")
        report["databases"].append({"scope": label, "accessibility": "allowed", "screenCapture": "allowed", "exactRequirement": True})
    evidence.write_text(json.dumps(report, indent=2) + "\n")


def main():
    action, raw_directory, *arguments = sys.argv[1:]
    directory = check_guest(raw_directory)
    if action == "setup" and not arguments:
        setup(directory)
    elif action == "restore-search-list" and not arguments:
        restore_search_list(directory)
    elif action == "sign" and len(arguments) == 1:
        sign(directory, Path(arguments[0]))
    elif action == "grant" and len(arguments) == 3:
        grant(directory, *(Path(value) for value in arguments))
    else:
        raise RuntimeError("Invalid fixture setup action")
    print("[update-runtime] guest identity action completed: " + action, flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        # TimeoutExpired embeds command arguments, including ephemeral passwords.
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("[update-runtime] guest identity setup failed: " + detail, file=sys.stderr)
        sys.exit(1)
