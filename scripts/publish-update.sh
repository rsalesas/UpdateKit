#!/bin/bash
# Write the appcast.json an UpdateKit app reads.
#
#   scripts/publish-update.sh \
#       --version 1.4.0 \
#       --dmg-url https://dl.example.app/1.4.0/example-1.4.0.dmg \
#       --zip build/example-1.4.0.zip \
#       --zip-url https://dl.example.app/1.4.0/example-1.4.0.zip \
#       --min-macos 15.0 \
#       --notes "One line for the update notice." \
#       --output build/appcast.json
#
# Only --version, --dmg-url and --output are required. Without --zip the manifest
# carries no archive, and apps fall back to opening the DMG.
#
# This writes the file; uploading is yours. The order matters:
#   1. the versioned DMG and ZIP (immutable — never overwrite a published version),
#   2. any mutable "latest" download alias,
#   3. appcast.json LAST, served no-cache.
# An app must never see a manifest advertising a version whose bytes aren't there yet.
#
# Point --dmg-url and --zip-url at IMMUTABLE versioned paths, never a "latest" alias:
# a client holding this manifest's checksum must fetch exactly the bytes it describes.
set -euo pipefail

VERSION="" DMG_URL="" ZIP="" ZIP_URL="" MIN_MACOS="" NOTES="" OUTPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION="$2"; shift 2 ;;
        --dmg-url)   DMG_URL="$2"; shift 2 ;;
        --zip)       ZIP="$2"; shift 2 ;;
        --zip-url)   ZIP_URL="$2"; shift 2 ;;
        --min-macos) MIN_MACOS="$2"; shift 2 ;;
        --notes)     NOTES="$2"; shift 2 ;;
        --output)    OUTPUT="$2"; shift 2 ;;
        *) echo "publish-update: unknown option $1" >&2; exit 2 ;;
    esac
done

if [ -z "$VERSION" ] || [ -z "$DMG_URL" ] || [ -z "$OUTPUT" ]; then
    echo "publish-update: --version, --dmg-url and --output are required" >&2
    exit 2
fi
if [ -n "$ZIP" ] && [ -z "$ZIP_URL" ]; then
    echo "publish-update: --zip needs --zip-url" >&2
    exit 2
fi

ZIP_SHA="" ZIP_SIZE=""
if [ -n "$ZIP" ]; then
    ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
    ZIP_SIZE=$(stat -f%z "$ZIP")
fi

python3 - "$OUTPUT" "$VERSION" "$DMG_URL" "$NOTES" "$ZIP_URL" "$ZIP_SHA" "$ZIP_SIZE" \
    "$MIN_MACOS" <<'PY'
import json, sys
path, version, dmg_url, notes, zip_url, zip_sha, zip_size, min_macos = sys.argv[1:9]
manifest = {"version": version, "url": dmg_url}
if min_macos:
    manifest["minimumSystemVersion"] = min_macos
if notes:
    manifest["notes"] = notes
# Both fields or neither: the checksum is the only thing standing between "we fetched
# bytes" and "we ran them", so an archive URL without one must never be published.
if zip_url and zip_sha and zip_size:
    manifest["archive"] = zip_url
    manifest["sha256"] = zip_sha
    manifest["archiveSize"] = int(zip_size)
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
echo "Wrote $OUTPUT"
