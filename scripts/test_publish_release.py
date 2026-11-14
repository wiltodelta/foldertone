# /// script
# requires-python = ">=3.12"
# dependencies = ["pytest>=8"]
# ///
"""Run with: uv run --script scripts/test_publish_release.py"""

import io
import json
import sys
import urllib.error
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_release  # noqa: E402

TAG_MESSAGE = (
    "Foldertone 1.2.0\n\nFixed: something.\n"
    "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n"
)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_network(calls, *, released=False, tag="annotated", live="1.2.0"):
    def urlopen(request, timeout):
        if isinstance(request, str):
            calls.append(("GET", request))
            return FakeResponse(json.dumps({"results": [{"version": live}]}).encode())
        path = request.full_url.removeprefix(f"{publish_release.API}/repos/owner/repo")
        body = json.loads(request.data) if request.data else None
        calls.append((request.get_method(), path, body))
        if (path == "/releases/tags/v1.2.0" and not released) or (path == "/git/ref/tags/v1.2.0" and not tag):
            raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(b"{}"))
        if path.startswith("/git/ref/"):
            reply = {"object": {"type": "tag" if tag == "annotated" else "commit", "sha": "abc"}}
        elif path.startswith("/git/tags/"):
            reply = {"message": TAG_MESSAGE}
        else:
            reply = {"id": 1}
        return FakeResponse(json.dumps(reply).encode())

    return urlopen


def run(monkeypatch, calls, *args, **network):
    monkeypatch.setattr(publish_release.urllib.request, "urlopen", fake_network(calls, **network))
    monkeypatch.setenv("GITHUB_TOKEN", "secret-token")
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    return publish_release.main(list(args))


def writes(calls):
    return [call for call in calls if call[0] != "GET"]


def test_dry_run_sends_no_write(monkeypatch, caplog):
    calls = []
    caplog.set_level("INFO")
    assert run(monkeypatch, calls, "--dry-run") == 0
    assert writes(calls) == []
    assert "Dry run, not sending POST" in caplog.text
    assert "secret-token" not in caplog.text


def test_publishes_tag_subject_and_body_without_signature(monkeypatch):
    calls = []
    assert run(monkeypatch, calls) == 0
    assert writes(calls) == [
        ("POST", "/releases", {"tag_name": "v1.2.0", "name": "Foldertone 1.2.0", "body": "Fixed: something.\n"})
    ]


def test_existing_release_is_left_alone(monkeypatch):
    calls = []
    assert run(monkeypatch, calls, released=True) == 0
    assert writes(calls) == []


@pytest.mark.parametrize("tag", [None, "lightweight"])
def test_missing_or_lightweight_tag_fails_without_writing(monkeypatch, tag):
    calls = []
    assert run(monkeypatch, calls, tag=tag) == 1
    assert writes(calls) == []


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
