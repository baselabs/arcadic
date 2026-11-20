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
# release.json names the commit the docs were built from: the run's GITHUB_SHA, checked out here.
commit=${GITHUB_SHA:-}
if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::Archive builds require GITHUB_SHA, the full commit being built" >&2
    exit 1
fi
head=$(git rev-parse HEAD)
if [ "$head" != "$commit" ]; then
    printf '::error::Checkout %s is not GITHUB_SHA %s\n' "$head" "$commit" >&2
    exit 1
fi
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
name=$(mix run --no-start --no-compile --no-deps-check \
    -e 'c = Mix.Project.config(); IO.puts(c[:package][:name] || c[:app])')

mix hex.build --output "$out/package.tar"
mix hex.build --output "$scratch/package.tar"
cmp "$out/package.tar" "$scratch/package.tar"

# The package is the release and must rebuild byte for byte. Docs render that package and
# a docs build is not byte-stable, so they are built once and inspected, never compared.
rm -rf doc
mix docs --warnings-as-errors
python3 -I -c 'import json, sys; print(json.dumps(dict(zip(("package", "version", "commit"), sys.argv[1:]))))' \
    "$name" "$VERSION" "$commit" > doc/release.json
(
    cd "$scratch/empty"
    mix run --no-mix-exs "$root/scripts/release/docs_archive.exs" "$root/doc" "$out/docs.tar.gz"
)

# Paths, file kinds, the Hex layout, docs layout and release.json, before any extraction.
python3 -I scripts/release/registry.py inspect-build "$name" "$VERSION" "$commit" "$out" "$scratch"

elixir scripts/inspect_package.exs "$scratch/contents" "$scratch/outer/metadata.config"
(
    cd "$out"
    sha256sum package.tar docs.tar.gz > SHA256SUMS
    chmod a-w package.tar docs.tar.gz SHA256SUMS
)
