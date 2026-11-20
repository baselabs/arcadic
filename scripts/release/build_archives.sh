#!/usr/bin/env bash
# Keyless project build. Inspect and seal the exact archives that publication uploads.
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: build_archives.sh OUTDIR" >&2
    exit 1
fi
if [ "${MIX_ENV:-}" != dev ]; then
    echo "::error::Archive builds require MIX_ENV=dev" >&2
    exit 1
fi

root=$(pwd -P)
expected_hex=$(cat scripts/release/hex-version)
hex_info=$(mix hex.info)
actual_hex=$(printf '%s\n' "$hex_info" | awk '$1 == "Hex:" { print $2 }')
if [ "$actual_hex" != "$expected_hex" ]; then
    printf '::error::Archive builds require Hex %s; installed %s\n' "$expected_hex" "$actual_hex" >&2
    exit 1
fi

mkdir -p "$1"
out=$(cd "$1" && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' 0
trap 'exit 1' HUP INT TERM
mkdir "$scratch/empty"

VERSION=$(mix run --no-start --no-compile --no-deps-check -e 'IO.puts(Mix.Project.config()[:version])')
export VERSION

mix hex.build --output "$out/package.tar"
mix hex.build --output "$scratch/package.tar"
cmp "$out/package.tar" "$scratch/package.tar"

# The package is the release and must rebuild byte for byte. Docs render that package and
# a docs build is not byte-stable, so they are built once and inspected, never compared.
rm -rf doc
mix docs --warnings-as-errors
(
    cd "$scratch/empty"
    mix run --no-mix-exs "$root/scripts/release/docs_archive.exs" "$root/doc" "$out/docs.tar.gz"
)

# Validate paths and file kinds before extracting, including in the nested tarball.
python3 -I - "$out/package.tar" "$scratch" "$out/docs.tar.gz" <<'PY'
import io
import re
import sys
import tarfile
from pathlib import Path, PurePosixPath

package, scratch, docs = map(Path, sys.argv[1:])


def regular_files(archive):
    files = {}
    for entry in archive.getmembers():
        path = PurePosixPath(entry.name)
        if (not entry.name or path.is_absolute() or ".." in path.parts
                or "\\" in entry.name or not entry.isfile()):
            raise SystemExit(f"::error::Unsafe archive entry: {entry.name}")
        name = str(path)
        if name == "." or name in files:
            raise SystemExit(f"::error::Duplicate or empty archive path: {entry.name}")
        files[name] = archive.extractfile(entry).read()
    return files


def extract(files, destination):
    for name, data in files.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


with tarfile.open(package, "r:") as archive:
    outer = regular_files(archive)
if set(outer) != {"VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"}:
    raise SystemExit("::error::Unexpected Hex package layout")
extract(outer, scratch / "outer")
with tarfile.open(fileobj=io.BytesIO(outer["contents.tar.gz"]), mode="r:gz") as archive:
    extract(regular_files(archive), scratch / "contents")

with tarfile.open(docs, "r:gz") as archive:
    files = regular_files(archive)
if "index.html" not in files:
    raise SystemExit("::error::Docs archive has no index.html")
numeric = r"(?:0|[1-9][0-9]*)"
identifier = rf"(?:{numeric}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
semver = re.compile(
    rf"{numeric}\.{numeric}\.{numeric}"
    rf"(?:-{identifier}(?:\.{identifier})*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
if any(semver.fullmatch(name.split("/")[0]) for name in files):
    raise SystemExit("::error::Top-level docs entries cannot match a semantic version")
print("Archive paths, file kinds, and docs layout passed inspection")
PY

elixir scripts/inspect_package.exs "$scratch/contents" "$scratch/outer/metadata.config"
(
    cd "$out"
    sha256sum package.tar docs.tar.gz > SHA256SUMS
    chmod a-w package.tar docs.tar.gz SHA256SUMS
)
