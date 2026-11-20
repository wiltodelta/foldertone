# /// script
# requires-python = ">=3.12"
# dependencies = ["pyjwt[crypto]>=2.8", "pytest>=8"]
# ///
"""Run with: uv run --script scripts/test_asc.py"""

import io
import json
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc  # noqa: E402


class FakeResponse(io.BytesIO):
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_api(calls, existing_version, earlier_versions=True, open_items=None, bodies=None, current=None):
    def urlopen(request, timeout):
        path = request.full_url.removeprefix(asc.API)
        calls.append((request.get_method(), path))
        if bodies is not None and request.data:
            bodies.append((request.get_method(), path, json.loads(request.data)))
        if path.startswith("/v1/apps?"):
            body = {"data": [{"id": "app1"}]}
        elif "/appStoreVersions?" in path:
            state = "READY_FOR_SALE" if existing_version == "released" else "PREPARE_FOR_SUBMISSION"
            version = {"id": "ver1", "attributes": {"versionString": "1.2.0", "appStoreState": state}}
            body = {"data": [version] if existing_version else []}
            if earlier_versions and "versionString" not in path:
                earlier = {"id": "ver0", "attributes": {"versionString": "1.1.1", "appStoreState": "READY_FOR_SALE"}}
                body["data"].append(earlier)
        elif "appStoreVersionLocalizations?" in path:
            body = {"data": [{"id": "loc1", "attributes": {"locale": "en-US", **(current or {})}}]}
        elif path.startswith("/v1/apps/app1/appInfos"):
            body = {"data": [{"id": "info0", "attributes": {"state": "READY_FOR_DISTRIBUTION"}},
                             {"id": "info1", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        elif "appInfoLocalizations?" in path:
            body = {"data": [{"id": "infoloc1", "attributes": {"locale": "en-US"}}]}
        elif path.startswith("/v1/builds?"):
            body = {"data": [{"id": "build1", "attributes": {"processingState": "VALID"}}]}
        elif path.startswith("/v1/reviewSubmissions?"):
            body = {"data": [{"id": "sub1"}] if open_items is not None else []}
        elif path.startswith("/v1/reviewSubmissions/sub1/items?"):
            body = {"data": open_items}
        else:
            body = {"data": {"id": "new1", "attributes": {}}}
        return FakeResponse(json.dumps(body).encode())

    return urlopen


@pytest.fixture
def metadata(tmp_path, monkeypatch):
    directory = tmp_path / "metadata"
    (directory / "locales").mkdir(parents=True)
    for locale in ("en-US", "ru"):
        page = {"name": "Foldertone", "subtitle": "Sub " + locale, "description": "Text", "keywords": "a,b"}
        (directory / "locales" / f"{locale}.json").write_text(json.dumps(page))
    (directory / "whats-new.json").write_text(json.dumps({"version": "1.2.0", "notes": {"ru": "Заметки"}}))
    monkeypatch.setattr(asc, "METADATA", directory)
    return directory


@pytest.fixture
def client_factory(tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    path = tmp_path / "AuthKey_TEST.p8"
    path.write_bytes(pem)
    return lambda dry_run: asc.Client("TEST", "issuer", path, dry_run)


@pytest.mark.parametrize("existing_version", [True, False])
def test_dry_run_sends_only_reads(monkeypatch, metadata, client_factory, existing_version):
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, existing_version))
    asc.release(client_factory(True), "1.2.0", "4", "Notes", submit=True, timeout=1)
    assert calls and all(method == "GET" for method, _ in calls)


def test_submit_flag_controls_sending(monkeypatch, metadata, client_factory):
    for submit in (False, True):
        calls = []
        monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True))
        asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=submit, timeout=1)
        sent = ("PATCH", "/v1/reviewSubmissions/new1") in calls
        assert sent == submit
        assert ("PATCH", "/v1/appStoreVersions/ver1/relationships/build") in calls


@pytest.mark.parametrize("earlier_versions", [True, False])
def test_whats_new_only_after_first_version(monkeypatch, metadata, client_factory, earlier_versions):
    calls, bodies = [], []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True, earlier_versions, bodies=bodies))
    asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=False, timeout=1)
    pages = {
        body["data"]["attributes"].get("locale", "en-US"): body["data"]["attributes"]
        for method, path, body in bodies
        if "appStoreVersionLocalizations" in path
    }
    assert set(pages) == {"en-US", "ru"}
    expected = {"en-US": "Notes", "ru": "Заметки"} if earlier_versions else {"en-US": None, "ru": None}
    assert {locale: page.get("whatsNew") for locale, page in pages.items()} == expected


def test_every_locale_is_written(monkeypatch, metadata, client_factory):
    calls, bodies = [], []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True, bodies=bodies))
    asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=False, timeout=1)
    assert ("PATCH", "/v1/appStoreVersionLocalizations/loc1") in calls
    assert ("PATCH", "/v1/appInfoLocalizations/infoloc1") in calls
    created = {
        (path, body["data"]["attributes"]["locale"])
        for method, path, body in bodies
        if method == "POST" and path.endswith("Localizations")
    }
    assert ("/v1/appStoreVersionLocalizations", "ru") in created
    assert ("/v1/appInfoLocalizations", "ru") in created
    info = next(b for m, p, b in bodies if m == "POST" and p == "/v1/appInfoLocalizations")
    assert info["data"]["relationships"]["appInfo"]["data"]["id"] == "info1"
    assert info["data"]["attributes"]["subtitle"] == "Sub ru"


def test_unchanged_locale_is_not_rewritten(monkeypatch, metadata, client_factory):
    current = {
        "description": "Text",
        "keywords": "a,b",
        "whatsNew": "Notes",
        "supportUrl": asc.SUPPORT_URL,
        "marketingUrl": asc.MARKETING_URL,
    }
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True, current=current))
    asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=False, timeout=1)
    assert ("PATCH", "/v1/appStoreVersionLocalizations/loc1") not in calls
    assert ("POST", "/v1/appStoreVersionLocalizations") in calls


@pytest.mark.parametrize("problem", ["stale notes", "missing notes", "long subtitle"])
def test_bad_metadata_is_refused_before_writing(monkeypatch, metadata, client_factory, problem):
    if problem == "stale notes":
        (metadata / "whats-new.json").write_text(json.dumps({"version": "1.1.0", "notes": {"ru": "x"}}))
    elif problem == "missing notes":
        (metadata / "whats-new.json").write_text(json.dumps({"version": "1.2.0", "notes": {}}))
    else:
        page = {"name": "Foldertone", "subtitle": "x" * 31, "description": "Text", "keywords": "a"}
        (metadata / "locales" / "ru.json").write_text(json.dumps(page))
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True))
    with pytest.raises(asc.ASCError):
        asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=True, timeout=1)
    assert all(method == "GET" for method, _ in calls)


def test_repository_metadata_is_valid():
    notes = json.loads((asc.METADATA / "whats-new.json").read_text())
    pages = asc.load_pages(asc.METADATA, notes["version"], "Notes")
    assert len(pages) > 1 and all(page["name"] == "Foldertone" for page in pages.values())


@pytest.mark.parametrize("has_version", [True, False])
def test_reused_submission_gets_the_version(monkeypatch, metadata, client_factory, has_version):
    calls = []
    item = {"id": "item1", "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": "ver1"}}}}
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True, open_items=[item] if has_version else []))
    asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=True, timeout=1)
    added = ("POST", "/v1/reviewSubmissionItems") in calls
    assert added == (not has_version)
    assert ("POST", "/v1/reviewSubmissions") not in calls
    assert ("PATCH", "/v1/reviewSubmissions/sub1") in calls


def test_released_version_is_refused(monkeypatch, metadata, client_factory):
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, "released"))
    with pytest.raises(asc.ASCError, match="already on the App Store"):
        asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=True, timeout=1)
    assert all(method == "GET" for method, _ in calls)


def test_token_never_logged(monkeypatch, client_factory, caplog):
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True))
    client = client_factory(False)
    caplog.set_level("INFO")
    asc.check(client)
    assert "Bearer" not in caplog.text and "BEGIN" not in caplog.text


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
