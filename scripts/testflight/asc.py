#!/usr/bin/env python3
"""App Store Connect API helper for TestFlight distribution.

  asc.py groups                      list TestFlight groups (also checks the API key)
  asc.py distribute --platform ios --version 1.7.9 --build 9 \
      --groups "Internal,Beta" [--notes-file notes.txt] [--timeout 3600]
                                     wait for the uploaded build to finish
                                     processing, set "What to Test", add it to
                                     the groups, and submit it for beta review
                                     if any group is external.

Config: ~/.config/lyrplay/testflight.env (KEY=VALUE lines) or the environment:
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file), TESTFLIGHT_GROUPS
"""
import argparse
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

BASE = "https://api.appstoreconnect.apple.com/v1"


def _tls_context():
    """python.org Python ships without CA certificates; fall back to certifi
    or the macOS system bundle."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    if os.path.exists("/etc/ssl/cert.pem"):
        return ssl.create_default_context(cafile="/etc/ssl/cert.pem")
    return ssl.create_default_context()


TLS = _tls_context()
BUNDLE_ID = "elm.LMS-StreamTest"
CONFIG_PATH = os.path.expanduser("~/.config/lyrplay/testflight.env")
PLATFORMS = {"ios": "IOS", "tvos": "TV_OS"}


def load_config():
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"')
    for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH", "TESTFLIGHT_GROUPS"):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not cfg.get(k)]
    if missing:
        sys.exit(f"Missing {', '.join(missing)} — set them in {CONFIG_PATH}")
    cfg["ASC_KEY_PATH"] = os.path.expanduser(cfg["ASC_KEY_PATH"])
    return cfg


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_token(cfg):
    """ES256 JWT, 20-minute lifetime (Apple's maximum)."""
    with open(cfg["ASC_KEY_PATH"], "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    now = int(time.time())
    header = {"alg": "ES256", "kid": cfg["ASC_KEY_ID"], "typ": "JWT"}
    payload = {"iss": cfg["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    r, s = utils.decode_dss_signature(key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256())))
    return f"{signing_input}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class APIError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body


def api(cfg, method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {make_token(cfg)}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60, context=TLS) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise APIError(e.code, e.read().decode(errors="replace")) from None


def app_id(cfg):
    apps = api(cfg, "GET", f"/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"No app with bundle ID {BUNDLE_ID} visible to this API key")
    return apps[0]["id"]


def beta_groups(cfg, app):
    return api(cfg, "GET", f"/apps/{app}/betaGroups?limit=200")["data"]


def cmd_groups(cfg, _args):
    app = app_id(cfg)
    for g in beta_groups(cfg, app):
        a = g["attributes"]
        kind = "internal" if a.get("isInternalGroup") else "external"
        extra = " (gets every build automatically)" if a.get("hasAccessToAllBuilds") else ""
        print(f"{a['name']}  [{kind}]{extra}")


def cmd_check_build(cfg, args):
    """Refuse a build number App Store Connect already has, or one older
    than its newest build of this version (an old checkout, not a new cut)."""
    app = app_id(cfg)
    found = api(cfg, "GET", f"/builds?filter[app]={app}"
                f"&filter[preReleaseVersion.version]={args.version}"
                f"&filter[preReleaseVersion.platform]={PLATFORMS[args.platform]}"
                f"&limit=200&fields[builds]=version")["data"]
    existing = sorted(int(b["attributes"]["version"]) for b in found if b["attributes"]["version"].isdigit())
    build = int(args.build)
    if build in existing:
        sys.exit(f"Build {args.version} ({build}) is already in App Store Connect")
    if existing and build < existing[-1]:
        sys.exit(f"Build {build} is older than the newest uploaded build ({existing[-1]}) — "
                 f"wrong branch? Cut a new build number first")
    print(f"Build number OK ({args.version}: newest uploaded is {existing[-1] if existing else 'none'})")


def wait_for_build(cfg, app, platform, version, build, timeout):
    query = (f"/builds?filter[app]={app}&filter[version]={build}"
             f"&filter[preReleaseVersion.version]={version}"
             f"&filter[preReleaseVersion.platform]={PLATFORMS[platform]}")
    deadline = time.time() + timeout
    last_state = None
    while True:
        found = api(cfg, "GET", query)["data"]
        state = found[0]["attributes"]["processingState"] if found else "NOT_YET_VISIBLE"
        if state != last_state:
            print(f"Build {version} ({build}) {platform}: {state}", flush=True)
            last_state = state
        if state == "VALID":
            return found[0]["id"]
        if state in ("FAILED", "INVALID"):
            sys.exit(f"App Store Connect rejected the build: {state}")
        if time.time() > deadline:
            sys.exit(f"Timed out after {timeout}s waiting for processing (last state {state})")
        time.sleep(30)


def set_what_to_test(cfg, build_id, notes):
    existing = api(cfg, "GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
    loc = next((l for l in existing if l["attributes"]["locale"] == "en-US"), None)
    if loc:
        api(cfg, "PATCH", f"/betaBuildLocalizations/{loc['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
    else:
        api(cfg, "POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": notes},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    print("Set What to Test")


def cmd_distribute(cfg, args):
    names = [n.strip() for n in (args.groups or cfg.get("TESTFLIGHT_GROUPS", "")).split(",") if n.strip()]
    if not names:
        sys.exit("No groups given (--groups or TESTFLIGHT_GROUPS)")
    app = app_id(cfg)
    groups = {g["attributes"]["name"]: g for g in beta_groups(cfg, app)}
    unknown = [n for n in names if n not in groups]
    if unknown:
        sys.exit(f"Unknown TestFlight group(s): {', '.join(unknown)}. Known: {', '.join(groups)}")

    build_id = wait_for_build(cfg, app, args.platform, args.version, args.build, args.timeout)

    if args.notes_file:
        with open(args.notes_file) as f:
            notes = f.read().strip()
        if notes:
            set_what_to_test(cfg, build_id, notes[:4000])

    needs_review = False
    for name in names:
        a = groups[name]["attributes"]
        if a.get("isInternalGroup") and a.get("hasAccessToAllBuilds"):
            print(f"{name}: internal group gets every build automatically")
            continue
        api(cfg, "POST", f"/betaGroups/{groups[name]['id']}/relationships/builds",
            {"data": [{"type": "builds", "id": build_id}]})
        print(f"Added to {name}")
        if not a.get("isInternalGroup"):
            needs_review = True

    if needs_review:
        try:
            api(cfg, "POST", "/betaAppReviewSubmissions", {"data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
            print("Submitted for TestFlight beta review")
        except APIError as e:
            # 409 when already submitted or approved; report, don't fail.
            print(f"Beta review submission not accepted: {e}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("groups")
    c = sub.add_parser("check-build")
    c.add_argument("--platform", choices=PLATFORMS, required=True)
    c.add_argument("--version", required=True)
    c.add_argument("--build", required=True)
    d = sub.add_parser("distribute")
    d.add_argument("--platform", choices=PLATFORMS, required=True)
    d.add_argument("--version", required=True)
    d.add_argument("--build", required=True)
    d.add_argument("--groups")
    d.add_argument("--notes-file")
    d.add_argument("--timeout", type=int, default=3600)
    args = p.parse_args()
    cfg = load_config()
    try:
        {"groups": cmd_groups, "check-build": cmd_check_build, "distribute": cmd_distribute}[args.cmd](cfg, args)
    except APIError as e:
        sys.exit(f"App Store Connect API error: {e}")


if __name__ == "__main__":
    main()
