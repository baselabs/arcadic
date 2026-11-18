#!/usr/bin/env python3
"""Keyless public Hex checks and release notes. Run with python3 -I."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class Refusal(Exception):
    """A named reason to stop publication without exposing a response body."""


def download(url, missing_ok=False):
    request = urllib.request.Request(url, headers={"User-Agent": "release-verification/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
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


def compare(name, version, build):
    package_bytes = (build / "package.tar").read_bytes()
    docs_bytes = (build / "docs.tar.gz").read_bytes()
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
    docs = "missing"
    if metadata["has_docs"]:
        served = download(f"https://repo.hex.pm/docs/{slug}.tar.gz")
        if served != docs_bytes:
            raise Refusal(f"Docs archive differs from Hex for {name} {version}; publication refused")
        docs = "present"
    return {"package": "present", "docs": docs}


def report(state):
    output = "".join(f"{key}={value}\n" for key, value in state.items())
    print(output, end="")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(output)


def verify(name, version, build):
    for attempt in range(10):
        try:
            state = compare(name, version, build)
            if state != {"package": "present", "docs": "present"}:
                raise Refusal(f"Hex does not yet serve both archives for {name} {version}")
            print(f"Verified package, docs, and checksum for {name} {version}")
            return
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
    notes = commands.add_parser("notes")
    notes.add_argument("version")
    notes.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "notes":
            args.output.write_text(changelog_section(args.version), encoding="utf-8")
            return
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
        else:
            verify(name, version, args.build)
    except (Refusal, OSError) as error:
        message = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error::{message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
