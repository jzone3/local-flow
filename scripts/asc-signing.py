#!/usr/bin/env python3
"""App Store signing for the iOS app through the App Store Connect API (no Xcode cloud signing).

  setup    make sure both bundle IDs exist with App Groups on, create a temporary Apple Distribution
           certificate and App Store profiles, write the .p12 + profiles + ExportOptions.plist
  cleanup  delete the profiles and revoke the temporary certificate

Env: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID, RUNNER_TEMP, GITHUB_RUN_NUMBER.
"""
import base64, json, os, plistlib, sys, time, urllib.error, urllib.request

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

APP_GROUP = "group.com.jzone3.LocalFlow"
BUNDLES = {"com.jzone3.LocalFlow.iOS": "Local Flow iOS",
           "com.jzone3.LocalFlow.iOS.Keyboard": "Local Flow iOS Keyboard"}
API = "https://api.appstoreconnect.apple.com/v1"
TMP = os.environ.get("RUNNER_TEMP", "/tmp")
STATE = os.path.join(TMP, "asc-signing.json")
P12_PASSWORD = "localflow"


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        if e.code in ok:
            return e.code, {}
        sys.exit(f"{method} {path} failed: {e.code} {raw[:600]}")


def bundle_id(identifier, name):
    _, res = call("GET", f"/bundleIds?filter[identifier]={identifier}&filter[platform]=IOS&limit=200")
    match = [d for d in res["data"] if d["attributes"]["identifier"] == identifier]
    if match:
        bid = match[0]["id"]
    else:
        _, res = call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes":
                      {"identifier": identifier, "name": name, "platform": "IOS"}}})
        bid = res["data"]["id"]
        print(f"Created App ID {identifier}")
    _, caps = call("GET", f"/bundleIds/{bid}/bundleIdCapabilities")
    if not any(c["attributes"]["capabilityType"] == "APP_GROUPS" for c in caps["data"]):
        call("POST", "/bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
             "attributes": {"capabilityType": "APP_GROUPS"},
             "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}}}}})
        print(f"Turned on App Groups for {identifier}")
    return bid


def profile_groups(content):
    data = base64.b64decode(content)
    start, end = data.index(b"<?xml"), data.index(b"</plist>") + len(b"</plist>")
    ents = plistlib.loads(data[start:end]).get("Entitlements", {})
    return ents.get("com.apple.security.application-groups", [])


def setup():
    team = os.environ["APPLE_TEAM_ID"]
    run = os.environ.get("GITHUB_RUN_NUMBER", str(int(time.time())))
    ids = {ident: bundle_id(ident, name) for ident, name in BUNDLES.items()}

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Local Flow CI")]))
           .sign(key, hashes.SHA256()))
    _, res = call("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION",
        "csrContent": csr.public_bytes(serialization.Encoding.PEM).decode()}}})
    cert_id = res["data"]["id"]
    state = {"certificate": cert_id, "profiles": []}
    json.dump(state, open(STATE, "w"))
    cert = x509.load_der_x509_certificate(base64.b64decode(res["data"]["attributes"]["certificateContent"]))
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1())
           .build(P12_PASSWORD.encode()))
    open(os.path.join(TMP, "dist.p12"), "wb").write(
        pkcs12.serialize_key_and_certificates(b"Local Flow CI", key, cert, None, enc))
    print(f"Created temporary distribution certificate {cert_id}")

    mapping, missing = {}, []
    for ident, bid in ids.items():
        _, res = call("POST", "/profiles", {"data": {"type": "profiles",
            "attributes": {"name": f"Local Flow CI {ident.split('.')[-1]} {run}", "profileType": "IOS_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bid}},
                              "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})
        attrs = res["data"]["attributes"]
        state["profiles"].append(res["data"]["id"])
        json.dump(state, open(STATE, "w"))
        open(os.path.join(TMP, f"{attrs['uuid']}.mobileprovision"), "wb").write(base64.b64decode(attrs["profileContent"]))
        mapping[ident] = attrs["name"]
        if APP_GROUP not in profile_groups(attrs["profileContent"]):
            missing.append(ident)
    if missing:
        sys.exit(f"App Group {APP_GROUP} is not assigned to: {', '.join(missing)}. In developer.apple.com → "
                 "Identifiers, create the App Group if needed, then open each App ID → App Groups → Configure "
                 "and tick it. (The API can't assign App Groups.)")

    plistlib.dump({"method": "app-store-connect", "destination": "export", "teamID": team,
                   "signingStyle": "manual", "signingCertificate": "Apple Distribution",
                   "provisioningProfiles": mapping, "manageAppVersionAndBuildNumber": False,
                   "uploadSymbols": True}, open(os.path.join(TMP, "ExportOptions.plist"), "wb"))

    _, apps = call("GET", "/apps?filter[bundleId]=com.jzone3.LocalFlow.iOS")
    print("App Store Connect app record:", "found" if apps["data"] else "MISSING (create it before uploading)")


def cleanup():
    if not os.path.exists(STATE):
        return
    state = json.load(open(STATE))
    for pid in state["profiles"]:
        call("DELETE", f"/profiles/{pid}", ok=(204, 404))
    call("DELETE", f"/certificates/{state['certificate']}", ok=(204, 404))
    print("Removed temporary certificate and profiles")


if __name__ == "__main__":
    {"setup": setup, "cleanup": cleanup}[sys.argv[1]]()
