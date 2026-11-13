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


def fake_api(calls, existing_version):
    def urlopen(request, timeout):
        path = request.full_url.removeprefix(asc.API)
        calls.append((request.get_method(), path))
        if path.startswith("/v1/apps?"):
            body = {"data": [{"id": "app1"}]}
        elif "/appStoreVersions?" in path:
            state = "READY_FOR_SALE" if existing_version == "released" else "PREPARE_FOR_SUBMISSION"
            version = {"id": "ver1", "attributes": {"versionString": "1.2.0", "appStoreState": state}}
            body = {"data": [version] if existing_version else []}
        elif "appStoreVersionLocalizations" in path:
            body = {"data": [{"id": "loc1"}]}
        elif path.startswith("/v1/builds?"):
            body = {"data": [{"id": "build1", "attributes": {"processingState": "VALID"}}]}
        elif path.startswith("/v1/reviewSubmissions?"):
            body = {"data": []}
        else:
            body = {"data": {"id": "new1", "attributes": {}}}
        return FakeResponse(json.dumps(body).encode())

    return urlopen


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
def test_dry_run_sends_only_reads(monkeypatch, client_factory, existing_version):
    calls = []
    monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, existing_version))
    asc.release(client_factory(True), "1.2.0", "4", "Notes", submit=True, timeout=1)
    assert calls and all(method == "GET" for method, _ in calls)


def test_submit_flag_controls_sending(monkeypatch, client_factory):
    for submit in (False, True):
        calls = []
        monkeypatch.setattr(asc.urllib.request, "urlopen", fake_api(calls, True))
        asc.release(client_factory(False), "1.2.0", "4", "Notes", submit=submit, timeout=1)
        sent = ("PATCH", "/v1/reviewSubmissions/new1") in calls
        assert sent == submit
        assert ("PATCH", "/v1/appStoreVersions/ver1/relationships/build") in calls


def test_released_version_is_refused(monkeypatch, client_factory):
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
