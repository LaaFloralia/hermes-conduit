#!/usr/bin/env python3
"""Run a release with a temporary Developer ID keychain.

Passwords go to security's interactive command parser on stdin, never its
argument list. OpenSSL extracts the key and certificate into private temporary
files, which are removed immediately after import into an isolated keychain.
"""

import base64
import binascii
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

SECURITY = "/usr/bin/security"
OPENSSL = "/opt/homebrew/bin/openssl"


class KeychainError(Exception):
    pass


def security_command(*arguments):
    """Feed a single command to security without exposing arguments in ps."""
    def quote(value):
        if any(character in value for character in "\x00\r\n"):
            raise KeychainError("keychain input contains unsupported characters")
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    command = " ".join(quote(str(item)) for item in arguments) + "\n"
    result = subprocess.run(
        [SECURITY, "-i"], input=command, text=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False,
    )
    # Interactive security can return success even after a command failed.
    # Do not echo diagnostics: they can contain commands and passwords. The
    # identity and dry-run checks below verify the resulting keychain instead.
    diagnostics = result.stderr.replace("security> ", "").strip()
    name = str(arguments[0]) if arguments and re.fullmatch(r"[a-z-]+", str(arguments[0])) else "operation"
    if result.returncode:
        raise KeychainError(f"temporary keychain {name} failed")
    if diagnostics:
        print(f"warning: temporary keychain {name} returned a diagnostic; checking the identity and key access", file=sys.stderr)


def check_signing_key(probe, identity):
    """Check key access without retaining or printing codesign diagnostics."""
    shutil.copyfile("/usr/bin/true", probe)
    os.chmod(probe, 0o700)
    cleared = subprocess.run(["/usr/bin/xattr", "-c", str(probe)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if cleared.returncode:
        print("warning: could not clear signing probe attributes; its result may be inconclusive", file=sys.stderr)
    try:
        checked = subprocess.run(
            ["/usr/bin/codesign", "--force", "--dryrun", "--timestamp=none", "--sign", identity, str(probe)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False, timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise KeychainError("the temporary signing key was not accessible without interaction") from None
    if checked.returncode:
        diagnostic = checked.stderr.lower()
        if any(marker in diagnostic for marker in ("-25308", "errsecinteractionnotallowed", "user interaction is not allowed",
                                                    "-25293", "errsecauthfailed", "access denied", "authorization denied")):
            raise KeychainError("the temporary signing key denied access without interaction")
        print("warning: the signing probe failed for an unclassified content or signing error; key access is unverified", file=sys.stderr)


def keychains():
    result = subprocess.run(
        [SECURITY, "list-keychains", "-d", "user"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode:
        raise KeychainError("cannot read the user keychain search list")
    return shlex.split(result.stdout)


def set_keychains(paths):
    result = subprocess.run(
        [SECURITY, "list-keychains", "-d", "user", "-s", *paths],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode:
        raise KeychainError("cannot update the user keychain search list")


def main():
    encoded = os.environ.pop("LAA_DEVID_P12_B64", "")
    password = os.environ.pop("LAA_DEVID_P12_PASSWORD", "")
    if not encoded or not password or len(sys.argv) < 2:
        raise KeychainError("Developer ID PKCS#12, its password, and a release command are required")
    if not Path(OPENSSL).is_file():
        raise KeychainError("Homebrew openssl@3 is required (brew install openssl@3)")
    try:
        p12 = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, binascii.Error):
        raise KeychainError("Developer ID PKCS#12 is not valid base64") from None
    if not p12:
        raise KeychainError("Developer ID PKCS#12 is empty")
    del encoded

    parent = Path.home() / ".config" / "laa" / "tmp-secrets"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(parent, 0o700)
    folder = Path(tempfile.mkdtemp(prefix="mac-sign.", dir=parent))
    keychain = str(folder / "release.keychain-db")
    p12_path = folder / "identity.p12"
    password_path = folder / "password"
    key_path = folder / "key.pem"
    certificate_path = folder / "certificate.pem"
    keychain_password = secrets.token_hex(32)
    created = False
    child = None

    def interrupt(signum, _frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)
        raise KeyboardInterrupt

    old_handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with os.fdopen(os.open(p12_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as stream:
            stream.write(p12)
        del p12
        if any(character in password for character in "\x00\r\n"):
            raise KeychainError("the PKCS#12 password contains unsupported characters")
        with os.fdopen(os.open(password_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as stream:
            stream.write(password)
        del password
        for output, options in ((key_path, ["-nocerts", "-nodes"]),
                                (certificate_path, ["-clcerts", "-nokeys"])):
            # Pre-create the output with restrictive permissions: the private
            # key must never inherit a permissive shell umask.
            os.close(os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            result = subprocess.run(
                [OPENSSL, "pkcs12", "-legacy", "-in", str(p12_path),
                 "-passin", f"file:{password_path}", *options, "-out", str(output)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            if result.returncode:
                raise KeychainError("cannot extract the Developer ID key and certificate")
        security_command("create-keychain", "-p", keychain_password, keychain)
        created = True
        security_command("unlock-keychain", "-p", keychain_password, keychain)
        security_command("set-keychain-settings", "-lut", "21600", keychain)
        security_command("import", str(key_path), "-k", keychain, "-T", "/usr/bin/codesign", "-T", SECURITY)
        security_command("import", str(certificate_path), "-k", keychain)
        for path in (p12_path, password_path, key_path, certificate_path):
            path.unlink()
        security_command("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, keychain)
        del keychain_password
        identities = subprocess.run(
            [SECURITY, "find-identity", "-v", "-p", "codesigning", keychain],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        match = re.search(r'(?m)^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"Developer ID Application:', identities.stdout)
        if identities.returncode or match is None:
            raise KeychainError("the imported keychain has no valid Developer ID Application identity")
        set_keychains([keychain, *keychains()])
        if keychain not in keychains():
            raise KeychainError("the temporary keychain was not added to the search list")
        # --dryrun performs the cryptographic operation and its access checks,
        # without writing a signature or sending anything to Apple.
        probe = folder / "signing-probe"
        check_signing_key(probe, match.group(1))
        probe.unlink()
        env = dict(os.environ, LAA_MAC_KEYCHAIN_ACTIVE="1")
        child = subprocess.Popen(sys.argv[1:], env=env)
        return child.wait()
    finally:
        primary_exception = sys.exc_info()[0] is not None
        cleanup_failed = False
        try:
            if child is not None and child.poll() is None:
                try:
                    child.terminate()
                    child.wait()
                except OSError:
                    cleanup_failed = True
            # Preserve changes to other keychains made while the release ran.
            if created:
                try:
                    current = keychains()
                    if keychain in current:
                        set_keychains([item for item in current if item != keychain])
                except (KeychainError, OSError):
                    cleanup_failed = True
                try:
                    deleted = subprocess.run([SECURITY, "delete-keychain", keychain],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    if deleted.returncode:
                        cleanup_failed = True
                except OSError:
                    cleanup_failed = True
        finally:
            try:
                shutil.rmtree(folder)
            except OSError:
                cleanup_failed = True
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
        if cleanup_failed:
            print("warning: could not fully clean up the temporary signing keychain", file=sys.stderr)
            if not primary_exception and (child is None or child.returncode == 0):
                raise KeychainError("temporary signing keychain cleanup failed")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (KeychainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
