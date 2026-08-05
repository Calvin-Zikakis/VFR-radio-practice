#!/usr/bin/env bash
# Regenerate web/src/core/drills.generated.json from the Swift drill library.
# Run this after editing any drill in Packages/VFRCore/Sources/VFRCore/Drills.swift
# so the web client and the iOS app stay in sync.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/web/src/core/drills.generated.json"
(cd "$repo/Packages/VFRCore" && swift run GenerateDrills) > "$out"
echo "Wrote $out ($(wc -c < "$out" | tr -d ' ') bytes, $(grep -c '"id"' "$out") ids)"
