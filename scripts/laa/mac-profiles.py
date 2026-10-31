#!/usr/bin/env python3
"""Find or create the Mac Catalyst Developer ID profiles for the LAA app.

Reads ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID (an App Store Connect API key)
and the Developer ID Application certificate serial from --serial or
LAA_DEVID_SERIAL. Standard library only: openssl signs the API token.

Writes {bundle: {uuid, name}} to the path given as the first argument and
installs each profile under ~/Library/Developer/Xcode/UserData/Provisioning
Profiles/. Prints bundle, state and expiry only — never the key, the token,
the certificate serial, a profile UUID or a server-supplied profile name.
API failures report the method, path, status and safe machine-readable codes.

  ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... \
    /usr/bin/python3 scripts/laa/mac-profiles.py profiles.json --serial <serial>
"""

import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BUNDLES = ("com.laa-inc.laa", "com.laa-inc.laa.NotificationService")
PROFILE_TYPE = "MAC_CATALYST_APP_DIRECT"
CERTIFICATE_TYPE = "DEVELOPER_ID_APPLICATION_G2"
BASE_URL = "https://api.appstoreconnect.apple.com"
DEST = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
_TOKEN = ""


class ProfilesError(Exception):
    pass


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_length(data, offset):
    if offset >= len(data):
        raise ProfilesError("cannot read the signature openssl returned")
    first = data[offset]
    if first < 0x80:
        return first, offset + 1
    count = first & 0x7F
    if count == 0 or count > 4 or offset + 1 + count > len(data):
        raise ProfilesError("cannot read the signature openssl returned")
    return int.from_bytes(data[offset + 1:offset + 1 + count], "big"), offset + 1 + count


def der_integers(data):
    """Return the two 32-byte integers of an ECDSA DER signature."""
    if not data or data[0] != 0x30:
        raise ProfilesError("cannot read the signature openssl returned")
    length, offset = der_length(data, 1)
    end = offset + length
    values = []
    while offset < end:
        if data[offset] != 0x02:
            raise ProfilesError("cannot read the signature openssl returned")
        length, offset = der_length(data, offset + 1)
        if offset + length > end:
            raise ProfilesError("cannot read the signature openssl returned")
        values.append(data[offset:offset + length].lstrip(b"\0").rjust(32, b"\0"))
        offset += length
    if len(values) != 2:
        raise ProfilesError("cannot read the signature openssl returned")
    return values


def token():
    key_path = os.environ.get("ASC_KEY_PATH", "")
    key_id = os.environ.get("ASC_KEY_ID", "")
    issuer_id = os.environ.get("ASC_ISSUER_ID", "")
    if not key_path or not key_id or not issuer_id:
        raise ProfilesError("ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID are required")
    if not Path(key_path).is_file():
        raise ProfilesError("ASC_KEY_PATH does not name a readable key file")
    now = int(time.time())
    header = base64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = base64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 900,
                                   "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = header + b"." + claims
    openssl = "/usr/bin/openssl" if Path("/usr/bin/openssl").is_file() else shutil.which("openssl")
    if not openssl:
        raise ProfilesError("openssl is required to sign the App Store Connect token")
    result = subprocess.run(
        [openssl, "dgst", "-sha256", "-sign", key_path],
        input=signing_input, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode:
        raise ProfilesError("cannot sign the App Store Connect token with ASC_KEY_PATH")
    return (signing_input + b"." + base64url(b"".join(der_integers(result.stdout)))).decode()


def api(method, path, body=None):
    request = urllib.request.Request(
        BASE_URL + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + _TOKEN, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Server-supplied error details can echo names or device identifiers.
        codes = []
        try:
            for item in json.load(error).get("errors", []):
                code = item.get("code", "")
                if isinstance(code, str) and re.fullmatch(r"[A-Z_]+(?:\.[A-Z_]+)*", code) and ("_" in code or "." in code):
                    codes.append(code)
        except (ValueError, TypeError, AttributeError):
            pass
        suffix = f" ({', '.join(sorted(set(codes)))})" if codes else ""
        raise ProfilesError(f"{method} {path.split('?')[0]} -> HTTP {error.code}{suffix}") from None
    except (urllib.error.URLError, TimeoutError):
        raise ProfilesError(f"{method} {path.split('?')[0]} -> unreachable") from None


def install_profile(path, content):
    """Install a new profile without changing a pre-existing UUID path."""
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
    except FileExistsError:
        if not path.is_file():
            raise ProfilesError("existing provisioning profile path is not a file") from None
        return

    created_stat = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
    except BaseException:
        try:
            if os.path.samestat(path.lstat(), created_stat):
                path.unlink()
        except FileNotFoundError:
            pass
        raise


def main():
    if len(sys.argv) < 2:
        raise ProfilesError("usage: mac-profiles.py OUTPUT.json [--serial SERIAL]")
    output_path = Path(sys.argv[1])
    serial = os.environ.get("LAA_DEVID_SERIAL", "")
    arguments = sys.argv[2:]
    while arguments:
        if arguments[0] == "--serial" and len(arguments) > 1:
            serial = arguments[1]
            arguments = arguments[2:]
        else:
            raise ProfilesError(f"unknown argument: {arguments[0]}")

    global _TOKEN
    _TOKEN = token()

    query = urllib.parse.urlencode({
        "filter[certificateType]": CERTIFICATE_TYPE,
        "fields[certificates]": "serialNumber,expirationDate",
        "limit": "200",
    })
    certificates = api("GET", "/v1/certificates?" + query).get("data", [])
    if serial:
        certificate = next((item for item in certificates
                            if item["attributes"]["serialNumber"].upper() == serial.upper()), None)
        if certificate is None:
            raise ProfilesError("no Developer ID Application certificate matches the serial from the keychain")
    else:
        if len(certificates) != 1:
            raise ProfilesError(f"expected one Developer ID Application certificate, found {len(certificates)}; pass --serial")
        certificate = certificates[0]
    print("certificate: found, expires", certificate["attributes"]["expirationDate"][:10])

    DEST.mkdir(parents=True, exist_ok=True)
    profiles = {}
    for bundle in BUNDLES:
        query = urllib.parse.urlencode({
            "filter[identifier]": bundle,
            "fields[bundleIds]": "identifier,platform",
            "limit": "20",
        })
        bundle_ids = api("GET", "/v1/bundleIds?" + query).get("data", [])
        bundle_id = next((item for item in bundle_ids
                          if item["attributes"]["identifier"] == bundle), None)
        if bundle_id is None:
            raise ProfilesError(f"bundle id missing: {bundle}")

        query = urllib.parse.urlencode({
            "fields[profiles]": "name,profileType,profileState,uuid,expirationDate",
            "limit": "200",
        })
        existing = None
        for profile in api("GET", f"/v1/bundleIds/{bundle_id['id']}/profiles?" + query).get("data", []):
            attributes = profile["attributes"]
            if attributes["profileType"] != PROFILE_TYPE or attributes["profileState"] != "ACTIVE":
                continue
            query = urllib.parse.urlencode({"fields[certificates]": "serialNumber", "limit": "50"})
            linked = api("GET", f"/v1/profiles/{profile['id']}/certificates?" + query).get("data", [])
            if any(item["attributes"]["serialNumber"].upper() == certificate["attributes"]["serialNumber"].upper()
                   for item in linked):
                existing = profile
                break

        if existing is not None:
            query = urllib.parse.urlencode({"fields[profiles]": "name,uuid,profileContent,expirationDate"})
            profile = api("GET", f"/v1/profiles/{existing['id']}?" + query)
            state = "existing"
        else:
            profile = api("POST", "/v1/profiles", {"data": {
                "type": "profiles",
                "attributes": {"name": f"LAA Mac Developer ID {bundle}", "profileType": PROFILE_TYPE},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
                },
            }})
            state = "created"

        attributes = profile["data"]["attributes"]
        content = base64.b64decode(attributes["profileContent"], validate=True)
        profile_uuid = attributes["uuid"]
        try:
            if str(uuid.UUID(profile_uuid)) != profile_uuid.lower():
                raise ValueError
        except (ValueError, AttributeError, TypeError):
            raise ProfilesError("App Store Connect returned an invalid profile UUID") from None
        path = DEST / f"{profile_uuid}.provisionprofile"
        install_profile(path, content)
        profiles[bundle] = {"uuid": attributes["uuid"], "name": attributes["name"]}
        print(f"{bundle}: {state} platform={bundle_id['attributes']['platform']} "
              f"expires {attributes['expirationDate'][:10]}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(profiles, stream, indent=1)
        stream.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (ProfilesError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
