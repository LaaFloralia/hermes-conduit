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
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode:
        raise KeychainError("temporary keychain operation failed")


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
        if identities.returncode or "Developer ID Application:" not in identities.stdout:
            raise KeychainError("the imported keychain has no valid Developer ID Application identity")
        set_keychains([keychain, *keychains()])
        if keychain not in keychains():
            raise KeychainError("the temporary keychain was not added to the search list")
        env = dict(os.environ, LAA_MAC_KEYCHAIN_ACTIVE="1")
        child = subprocess.Popen(sys.argv[1:], env=env)
        return child.wait()
    finally:
        try:
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait()
            # Preserve changes to other keychains made while the release ran.
            if created:
                try:
                    current = keychains()
                    if keychain in current:
                        set_keychains([item for item in current if item != keychain])
                finally:
                    deleted = subprocess.run([SECURITY, "delete-keychain", keychain],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    if deleted.returncode:
                        raise KeychainError("could not delete the temporary signing keychain")
        finally:
            shutil.rmtree(folder)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (KeychainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
