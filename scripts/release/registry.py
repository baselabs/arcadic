#!/usr/bin/env python3
"""Keyless public Hex checks and release notes. Run with python3 -I."""

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

# A served or built archive larger than this, read or unpacked, is refused.
ARCHIVE_LIMIT = 256 * 1024 * 1024
COMMIT = re.compile(r"[0-9a-f]{40}")
NUMERIC = r"(?:0|[1-9][0-9]*)"
IDENTIFIER = rf"(?:{NUMERIC}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(
    rf"{NUMERIC}\.{NUMERIC}\.{NUMERIC}"
    rf"(?:-{IDENTIFIER}(?:\.{IDENTIFIER})*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


class Refusal(Exception):
    """A named reason to stop publication without exposing a response body."""


class Provenance(Refusal):
    """Served docs that name no commit on the published history; read-back never retries it."""


def download(url, missing_ok=False):
    request = urllib.request.Request(url, headers={"User-Agent": "release-verification/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read(ARCHIVE_LIMIT + 1)
                if len(data) > ARCHIVE_LIMIT:
                    raise Refusal(f"Registry response exceeds {ARCHIVE_LIMIT} bytes at {url}")
                return data
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            if status == 404 and missing_ok:
                return None
            if not 500 <= status < 600 or attempt == 2:
                raise Refusal(f"Registry lookup failed: HTTP {status} at {url}") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 2:
                raise Refusal(f"Registry lookup failed: no response from {url}") from None
        time.sleep(2)


def api(path):
    path = urllib.parse.quote(path, safe="/")
    data = download(f"https://hex.pm/api/packages/{path}", missing_ok=True)
    if data is None:
        return None
    try:
        result = json.loads(data)
    except (ValueError, UnicodeError):
        raise Refusal("Registry lookup returned invalid JSON") from None
    if not isinstance(result, dict):
        raise Refusal("Registry lookup returned an invalid object")
    return result


def release(name, version):
    result = api(f"{name}/releases/{version}")
    if result is not None:
        if not {"retirement", "checksum", "has_docs"} <= result.keys():
            raise Refusal(f"Incomplete release metadata for {name} {version}")
        if result["retirement"] is not None:
            raise Refusal(f"Hex release {name} {version} is retired; publication refused")
        if not isinstance(result["checksum"], str) or type(result["has_docs"]) is not bool:
            raise Refusal(f"Invalid release metadata for {name} {version}")
    return result


def changelog_section(version):
    text = Path("CHANGELOG.md").read_text(encoding="utf-8")
    headings = list(re.finditer(r"^##[ \t]+(.+)$", text, re.MULTILINE))
    for index, heading in enumerate(headings):
        title = heading.group(1)
        if title.split()[0] in (f"[{version}]", version):
            end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
            return text[heading.start():end].rstrip() + "\n"
    raise Refusal(f"CHANGELOG.md has no section for {version}; publication refused")


def refuse(name, version):
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--exit-code", "--tags", "origin", f"refs/tags/v{version}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise Refusal(f"Origin tag lookup failed for v{version}; publication refused") from None
    if result.returncode == 0:
        raise Refusal(f"Tag v{version} already exists on origin; publication refused")
    if result.returncode != 2:
        raise Refusal(f"Origin tag lookup failed with status {result.returncode}; publication refused")
    if api(name) is None:
        raise Refusal(f"The name {name} is not on Hex; a first publication is the owner's decision")
    release(name, version)
    changelog_section(version)
    print(f"Publication preflight passed for {name} {version}")


def regular_files(archive):
    """Every entry a plain file at a safe relative path, unpacked within ARCHIVE_LIMIT."""
    files, total = {}, 0
    for entry in archive.getmembers():
        path = PurePosixPath(entry.name)
        if (not entry.name or path.is_absolute() or ".." in path.parts
                or "\\" in entry.name or not entry.isfile()):
            raise Refusal(f"Unsafe archive entry: {entry.name}")
        name = str(path)
        if name == "." or name in files:
            raise Refusal(f"Duplicate or empty archive path: {entry.name}")
        total += entry.size
        if total > ARCHIVE_LIMIT:
            raise Refusal(f"Archive unpacks to more than {ARCHIVE_LIMIT} bytes")
        files[name] = archive.extractfile(entry).read()
    return files


def extract(files, destination):
    for name, data in files.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def inspect_docs(data, name, version):
    """Layout and provenance of a docs archive; returns the commit its release.json names."""
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            files = regular_files(archive)
    except (tarfile.TarError, OSError, EOFError):
        raise Refusal("Docs archive is not a readable gzip tar") from None
    if "index.html" not in files:
        raise Refusal("Docs archive has no index.html")
    if any(SEMVER.fullmatch(path.split("/")[0]) for path in files):
        raise Refusal("Top-level docs entries cannot match a semantic version")
    try:
        meta = json.loads(files.get("release.json", b"").decode("utf-8"))
    except (ValueError, UnicodeError):
        raise Provenance(f"Docs for {name} {version} carry no readable release.json") from None
    if (not isinstance(meta, dict) or set(meta) != {"package", "version", "commit"}
            or meta["package"] != name or meta["version"] != version
            or not isinstance(meta["commit"], str) or not COMMIT.fullmatch(meta["commit"])):
        raise Provenance(f"Docs release.json does not name {name} {version} and a full commit")
    return meta["commit"]


def inspect_build(name, version, commit, build, scratch):
    """Inspect the built archives; unpack the package for inspect_package.exs."""
    with tarfile.open(build / "package.tar", "r:") as archive:
        outer = regular_files(archive)
    if set(outer) != {"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"}:
        raise Refusal("Unexpected Hex package layout")
    extract(outer, scratch / "outer")
    with tarfile.open(fileobj=io.BytesIO(outer["contents.tar.gz"]), mode="r:gz") as archive:
        extract(regular_files(archive), scratch / "contents")
    if inspect_docs((build / "docs.tar.gz").read_bytes(), name, version) != commit:
        raise Refusal(f"Docs release.json does not name the built commit {commit}")
    print("Archive paths, file kinds, docs layout and release.json passed inspection")


def on_published_history(commit):
    """The commit is the dispatched commit or its ancestor; the checkout is that default-branch head."""
    def git(*args):
        try:
            return subprocess.run(["git", *args], capture_output=True, text=True, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise Refusal("Commit history lookup failed; publication refused") from None
    shallow = git("rev-parse", "--is-shallow-repository")
    if shallow.returncode != 0 or shallow.stdout.strip() != "false":
        raise Refusal("Read-back needs the full default-branch history; publication refused")
    if git("merge-base", "--is-ancestor", commit, "HEAD").returncode != 0:
        raise Provenance(f"Served docs name commit {commit}, which is not on the published history; publication refused")


def compare(name, version, build):
    """The package is the release: served package bytes must equal the build.

    Docs are a rendering of that package and a docs build is not byte-stable, so docs bytes
    are never compared. Hex accepts docs only for a release it serves, so served docs belong
    to the package just compared; they are reported present and kept.
    """
    package_bytes = (build / "package.tar").read_bytes()
    metadata = release(name, version)
    if metadata is None:
        return {"package": "missing", "docs": "missing"}
    digest = hashlib.sha256(package_bytes).hexdigest()
    slug = urllib.parse.quote(f"{name}-{version}", safe="")
    served = download(f"https://repo.hex.pm/tarballs/{slug}.tar")
    if served != package_bytes:
        raise Refusal(f"Package archive differs from Hex for {name} {version}; publication refused")
    if metadata["checksum"] != digest:
        raise Refusal(f"Hex checksum differs from package.tar for {name} {version}; publication refused")
    return {"package": "present", "docs": "present" if metadata["has_docs"] else "missing"}


def report(state):
    output = "".join(f"{key}={value}\n" for key, value in state.items())
    print(output, end="")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(output)


def verify(name, version, build, docs_output):
    """Read both archives back; inspect the served docs and write them for release-assets."""
    slug = urllib.parse.quote(f"{name}-{version}", safe="")
    for attempt in range(10):
        try:
            state = compare(name, version, build)
            served = download(f"https://repo.hex.pm/docs/{slug}.tar.gz", missing_ok=True)
            if state != {"package": "present", "docs": "present"} or served is None:
                raise Refusal(f"Hex does not yet serve both archives for {name} {version}")
            commit = inspect_docs(served, name, version)
            on_published_history(commit)
            docs_output.write_bytes(served)
            print(f"Verified package bytes and checksum, and served docs from published commit {commit}")
            report({"commit": commit})
            return
        except Provenance:
            raise
        except Refusal as error:
            if attempt == 9:
                raise
            print(f"{error}; read-back {attempt + 1}/10, retrying in 30 seconds", flush=True)
            time.sleep(30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("refuse", "compare", "verify"):
        sub = commands.add_parser(command)
        sub.add_argument("name")
        sub.add_argument("version")
        if command != "refuse":
            sub.add_argument("build", type=Path)
        if command == "verify":
            sub.add_argument("docs_output", type=Path)
    built = commands.add_parser("inspect-build")
    built.add_argument("name")
    built.add_argument("version")
    built.add_argument("commit")
    built.add_argument("build", type=Path)
    built.add_argument("scratch", type=Path)
    notes = commands.add_parser("notes")
    notes.add_argument("version")
    notes.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "notes":
            args.output.write_text(changelog_section(args.version), encoding="utf-8")
            return 0
        if not re.fullmatch(r"[a-z][a-z0-9_]*", args.name):
            raise Refusal("Invalid Hex package name")
        if not re.fullmatch(r"[0-9A-Za-z.+-]+", args.version):
            raise Refusal("Invalid release version")
        name = args.name
        version = args.version
        if args.command == "refuse":
            refuse(name, version)
        elif args.command == "compare":
            report(compare(name, version, args.build))
        elif args.command == "inspect-build":
            if not COMMIT.fullmatch(args.commit):
                raise Refusal("inspect-build needs the full commit being built")
            inspect_build(name, version, args.commit, args.build, args.scratch)
        else:
            verify(name, version, args.build, args.docs_output)
    except (Refusal, OSError) as error:
        message = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error::{message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
