#!/bin/sh
# Check the public origin and Hex without a registry key or persisted checkout token.
set -eu

: "${PACKAGE_NAME:?PACKAGE_NAME must name the Hex package}"
: "${VERSION:?VERSION must be the version read from mix.exs}"

refused=0
if git ls-remote --exit-code --tags origin "refs/tags/v$VERSION" > /dev/null; then
    printf '::error::Version %s is already tagged\n' "$VERSION" >&2
    refused=1
else
    status=$?
    if [ "$status" -ne 2 ]; then
        printf '::error::Tag lookup failed with status %s\n' "$status" >&2
        exit "$status"
    fi
fi

status=$(curl --silent --show-error --location --retry 3 --max-time 60 \
    --output /dev/null --write-out '%{http_code}' \
    "https://hex.pm/api/packages/$PACKAGE_NAME/releases/$VERSION")
case "$status" in
    200)
        printf '::error::Version %s is already published on Hex\n' "$VERSION" >&2
        refused=1
        ;;
    404) ;;
    *)
        printf '::error::Hex lookup failed with HTTP %s\n' "$status" >&2
        exit 1
        ;;
esac

if [ "$refused" -eq 0 ]; then
    printf 'Version %s is untagged and unpublished\n' "$VERSION"
fi
exit "$refused"
