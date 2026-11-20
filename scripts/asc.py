# /// script
# requires-python = ">=3.12"
# dependencies = ["pyjwt[crypto]>=2.8"]
# ///
"""App Store Connect API steps for a Foldertone release.

`check` only reads. `release` creates or reuses the App Store version, writes the
App Store page in every language under metadata/ (What's New included), waits for
the uploaded build, attaches it and prepares a review submission; `--submit` sends
that submission, and `--dry-run` performs reads only and logs every write it would make.

Credentials come from ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file,
default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8). They never reach a log.
"""

import argparse
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import jwt

log = logging.getLogger("asc")
API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.wiltodelta.foldertone"
LOCALE = "en-US"
METADATA = Path(__file__).resolve().parent.parent / "metadata"
SUPPORT_URL = "https://wiltodelta.com/projects/foldertone/support/"
MARKETING_URL = "https://wiltodelta.com/projects/foldertone/"
PRIVACY_URL = "https://wiltodelta.com/projects/foldertone/privacy/"
# App Store Connect limits, in characters.
LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "description": 4000, "whatsNew": 4000}
# App information states in which the name and subtitle can still change.
EDITABLE_INFO = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}
# Stands in for the IDs of objects a dry run does not create.
DRY_RUN_ID = "dry-run"


class ASCError(RuntimeError):
    pass


class Client:
    def __init__(self, key_id: str, issuer_id: str, key_path: Path, dry_run: bool = False):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = key_path.read_text()
        self.dry_run = dry_run

    def token(self) -> str:
        now = int(time.time())
        claims = {"iss": self.issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
        return jwt.encode(claims, self.private_key, algorithm="ES256", headers={"kid": self.key_id})

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        if method != "GET" and self.dry_run:
            log.info("Dry run, not sending %s %s %s", method, path, json.dumps(body))
            return {"data": {"id": DRY_RUN_ID, "attributes": {}}}
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token())
        req.add_header("Content-Type", "application/json")
        log.info("Request %s %s %s", method, path, json.dumps(body) if body else "")
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                text = response.read().decode()
                log.info("Response %s %s: %s", response.status, path, text)
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            log.error("Request %s %s failed with %s: %s", method, path, error.code, text)
            raise ASCError(f"{method} {path} failed with {error.code}") from error

    def get(self, path: str, **params: str) -> dict:
        query = urllib.parse.urlencode(params)
        return self.request("GET", f"{path}?{query}" if query else path)


def app_id(client: Client) -> str:
    apps = client.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        raise ASCError(f"No app with bundle ID {BUNDLE_ID}")
    return apps[0]["id"]


def check(client: Client) -> None:
    app = app_id(client)
    versions = client.get(
        f"/v1/apps/{app}/appStoreVersions", **{"filter[platform]": "IOS", "limit": "5"}
    )["data"]
    for version in versions:
        attributes = version["attributes"]
        log.info("Version %s: %s", attributes["versionString"], attributes.get("appStoreState"))
    log.info("The API key can read app %s", app)


def find_or_create_version(client: Client, app: str, version: str) -> str:
    existing = client.get(
        f"/v1/apps/{app}/appStoreVersions",
        **{"filter[platform]": "IOS", "filter[versionString]": version},
    )["data"]
    if existing:
        state = existing[0]["attributes"].get("appStoreState")
        if state == "READY_FOR_SALE":
            raise ASCError(f"Version {version} is already on the App Store; bump MARKETING_VERSION")
        log.info("Reusing App Store version %s (%s, %s)", version, existing[0]["id"], state)
        return existing[0]["id"]
    created = client.request(
        "POST",
        "/v1/appStoreVersions",
        {
            "data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": version},
                "relationships": {"app": {"data": {"type": "apps", "id": app}}},
            }
        },
    )
    return created["data"]["id"]


def first_version(client: Client, app: str, version: str) -> bool:
    versions = client.get(f"/v1/apps/{app}/appStoreVersions", **{"filter[platform]": "IOS"})["data"]
    return all(v["attributes"]["versionString"] == version for v in versions)


def load_pages(directory: Path, version: str, whats_new: str | None) -> dict[str, dict]:
    """Reads the page of every locale; whats_new is the en-US text, None for a first version."""
    pages = {path.stem: json.loads(path.read_text()) for path in sorted((directory / "locales").glob("*.json"))}
    if LOCALE not in pages:
        raise ASCError(f"metadata/locales has no {LOCALE}.json")
    texts = {}
    if whats_new is not None:
        notes = json.loads((directory / "whats-new.json").read_text())
        if notes["version"] != version:
            raise ASCError(f"metadata/whats-new.json is for {notes['version']}; translate the notes for {version}")
        texts = {**notes["notes"], LOCALE: whats_new}
    for locale, page in pages.items():
        if whats_new is not None:
            if locale not in texts:
                raise ASCError(f"metadata/whats-new.json has no notes for {locale}")
            page["whatsNew"] = texts[locale]
        for field, limit in LIMITS.items():
            if field != "whatsNew" and not page.get(field):
                raise ASCError(f"{locale} has no {field}")
            if len(page.get(field) or "") > limit:
                raise ASCError(f"{locale} {field} is longer than {limit} characters")
    return pages


def write_localizations(client: Client, kind: str, parent: str, parent_id: str, wanted: dict[str, dict]) -> None:
    """Brings each locale's localization of a version or app information to the wanted attributes,
    creating missing ones and leaving unchanged ones alone."""
    existing = {}
    if parent_id != DRY_RUN_ID:
        path = f"/v1/{parent}s/{parent_id}/{kind}"
        existing = {item["attributes"]["locale"]: item for item in client.get(path, limit="200")["data"]}
    for locale, attributes in wanted.items():
        current = existing.get(locale)
        if current is None:
            relationship = {parent: {"data": {"type": parent + "s", "id": parent_id}}}
            body = {"type": kind, "attributes": {"locale": locale, **attributes}, "relationships": relationship}
            client.request("POST", f"/v1/{kind}", {"data": body})
        elif any(current["attributes"].get(field) != value for field, value in attributes.items()):
            body = {"type": kind, "id": current["id"], "attributes": attributes}
            client.request("PATCH", f"/v1/{kind}/{current['id']}", {"data": body})


def write_version_pages(client: Client, version_id: str, pages: dict[str, dict]) -> None:
    fields = ("description", "keywords", "whatsNew")
    wanted = {
        locale: {**{field: page[field] for field in fields if field in page}, "supportUrl": SUPPORT_URL, "marketingUrl": MARKETING_URL}
        for locale, page in pages.items()
    }
    write_localizations(client, "appStoreVersionLocalizations", "appStoreVersion", version_id, wanted)


def write_app_info(client: Client, app: str, pages: dict[str, dict]) -> None:
    infos = client.get(f"/v1/apps/{app}/appInfos")["data"]
    editable = [
        info["id"]
        for info in infos
        if {info["attributes"].get("state"), info["attributes"].get("appStoreState")} & EDITABLE_INFO
    ]
    if not editable and not client.dry_run:
        raise ASCError("No editable app information; the new version should have created one")
    # A dry run before the new version exists has no editable app information yet.
    info = editable[0] if editable else DRY_RUN_ID
    wanted = {
        locale: {"name": page["name"], "subtitle": page["subtitle"], "privacyPolicyUrl": PRIVACY_URL}
        for locale, page in pages.items()
    }
    write_localizations(client, "appInfoLocalizations", "appInfo", info, wanted)


def wait_for_build(client: Client, app: str, version: str, build: str, timeout: int) -> str:
    deadline = time.monotonic() + timeout
    while True:
        builds = client.get(
            "/v1/builds",
            **{
                "filter[app]": app,
                "filter[version]": build,
                "filter[preReleaseVersion.version]": version,
            },
        )["data"]
        state = builds[0]["attributes"].get("processingState") if builds else "NOT_FOUND"
        if state == "VALID":
            return builds[0]["id"]
        if client.dry_run:
            log.info("Dry run, build %s (%s) is %s; not waiting", version, build, state)
            return DRY_RUN_ID
        if state in {"FAILED", "INVALID"}:
            raise ASCError(f"Build {version} ({build}) processing ended as {state}")
        if time.monotonic() >= deadline:
            raise ASCError(f"Build {version} ({build}) is still {state} after {timeout} seconds")
        log.info("Build %s (%s) is %s; checking again in 30 seconds", version, build, state)
        time.sleep(30)


def prepare_submission(client: Client, app: str, version_id: str, submit: bool) -> None:
    open_submissions = client.get(
        "/v1/reviewSubmissions",
        **{"filter[app]": app, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"},
    )["data"]
    items = []
    if open_submissions:
        submission = open_submissions[0]["id"]
        items = client.get(f"/v1/reviewSubmissions/{submission}/items", include="appStoreVersion")["data"]
    else:
        submission = client.request(
            "POST",
            "/v1/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )["data"]["id"]
    # A run that failed after creating the submission leaves it without the version.
    if not any(
        (item["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == version_id
        for item in items
    ):
        client.request(
            "POST",
            "/v1/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                    },
                }
            },
        )
    if not submit:
        log.info("Review submission %s is ready; rerun with --submit to send it", submission)
        return
    client.request(
        "PATCH",
        f"/v1/reviewSubmissions/{submission}",
        {"data": {"type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}},
    )
    log.info("Submitted review submission %s", submission)


def release(
    client: Client,
    version: str,
    build: str,
    whats_new: str,
    submit: bool,
    timeout: int,
) -> None:
    app = app_id(client)
    first = first_version(client, app, version)
    if first:
        log.info("Version %s is the app's first, which has no What's New; skipping it", version)
    # Every page is read and checked before the first write.
    pages = load_pages(METADATA, version, None if first else whats_new)
    version_id = find_or_create_version(client, app, version)
    write_version_pages(client, version_id, pages)
    write_app_info(client, app, pages)
    build_id = wait_for_build(client, app, version, build, timeout)
    client.request(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
    )
    prepare_submission(client, app, version_id, submit)


def client_from_environment(dry_run: bool) -> Client:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer_id = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer_id:
        raise ASCError("Set ASC_KEY_ID and ASC_ISSUER_ID; see .env.example")
    default = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    key_path = Path(os.environ.get("ASC_KEY_PATH") or default).expanduser()
    if not key_path.is_file():
        raise ASCError(f"Missing API key file {key_path}")
    return Client(key_id, issuer_id, key_path, dry_run)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="read only and log planned writes")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="verify that the key can read the app")
    release_parser = commands.add_parser("release", help="prepare an App Store version for review")
    release_parser.add_argument("--version", required=True)
    release_parser.add_argument("--build", required=True)
    release_parser.add_argument("--whats-new-file", required=True, type=Path)
    release_parser.add_argument("--submit", action="store_true", help="send the review submission")
    release_parser.add_argument("--timeout", type=int, default=1800, help="seconds to wait for processing")
    args = parser.parse_args(argv)
    try:
        client = client_from_environment(args.dry_run)
        if args.command == "check":
            check(client)
        else:
            whats_new = args.whats_new_file.read_text().strip()
            release(client, args.version, args.build, whats_new, args.submit, args.timeout)
    except ASCError as error:
        log.error("%s", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
