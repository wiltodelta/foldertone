# /// script
# requires-python = ">=3.12"
# ///
"""Publish the GitHub release for the version the App Store currently sells.

The App Store releases a version after review, at a time no local step controls,
so CI runs this on a schedule. It reads the live version from the public iTunes
Lookup API and, when the annotated tag v<version> exists without a GitHub release,
publishes one titled with the tag subject and described by the tag body, the same
text as What's New. `--dry-run` performs the reads and logs the release it would
create.

GITHUB_TOKEN (or GH_TOKEN) authorizes the GitHub API and GITHUB_REPOSITORY names the
repository. The token never reaches a log.
"""

import argparse
import json
import logging
import os
import sys
import urllib.error
import urllib.request

log = logging.getLogger("publish_release")
BUNDLE_ID = "app.foldertone"
LOOKUP = f"https://itunes.apple.com/lookup?bundleId={BUNDLE_ID}"
API = "https://api.github.com"
DEFAULT_REPOSITORY = "wiltodelta/foldertone"
SIGNATURE = "-----BEGIN SSH SIGNATURE-----"


class PublishError(RuntimeError):
    pass


class GitHub:
    def __init__(self, repository: str, token: str, dry_run: bool = False):
        self.repository = repository
        self.token = token
        self.dry_run = dry_run

    def request(self, method: str, path: str, body: dict | None = None) -> dict | None:
        """Return the decoded response, or None for 404."""
        url = f"{API}/repos/{self.repository}{path}"
        if method != "GET" and self.dry_run:
            log.info("Dry run, not sending %s %s %s", method, url, json.dumps(body))
            return None
        log.info("Request %s %s %s", method, url, json.dumps(body) if body is not None else "")
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                text = response.read().decode()
        except urllib.error.HTTPError as error:
            text = error.read().decode()
            if error.code == 404:
                log.info("Response 404 %s: %s", url, text)
                return None
            log.error("GitHub %s %s failed with %s: %s", method, url, error.code, text)
            raise PublishError(f"GitHub {method} {path} failed with {error.code}") from error
        log.info("Response %s: %s", url, text)
        return json.loads(text)


def live_version() -> str:
    log.info("Request GET %s", LOOKUP)
    with urllib.request.urlopen(LOOKUP, timeout=60) as response:
        text = response.read().decode()
    log.info("Response %s: %s", LOOKUP, text)
    results = json.loads(text).get("results", [])
    if not results:
        raise PublishError(f"The App Store lookup returned no app for {BUNDLE_ID}")
    return results[0]["version"]


def tag_message(github: GitHub, tag: str) -> str:
    ref = github.request("GET", f"/git/ref/tags/{tag}")
    if ref is None:
        raise PublishError(f"The App Store sells {tag[1:]}, but the repository has no tag {tag}")
    if ref["object"]["type"] != "tag":
        raise PublishError(f"{tag} must be annotated; its body is the release notes")
    message = github.request("GET", f"/git/tags/{ref['object']['sha']}")["message"]
    return message.split(SIGNATURE, 1)[0]


def publish(github: GitHub) -> str:
    tag = "v" + live_version()
    if github.request("GET", f"/releases/tags/{tag}") is not None:
        return f"{tag} is already published"
    subject, _, body = tag_message(github, tag).strip().partition("\n")
    body = body.strip()
    if not body:
        raise PublishError(f"{tag} has no body for the release notes")
    github.request("POST", "/releases", {"tag_name": tag, "name": subject, "body": body + "\n"})
    return f"{'Would publish' if github.dry_run else 'Published'} {subject} from {tag}"


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="read only and log the release it would create")
    args = parser.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        log.error("Set GITHUB_TOKEN or GH_TOKEN")
        return 1
    github = GitHub(os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPOSITORY), token, args.dry_run)
    try:
        log.info(publish(github))
    except PublishError as error:
        log.error("%s", error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
