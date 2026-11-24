#!/usr/bin/env bash
# Prints the release version: the git tag (v1.2.3 → 1.2.3) when building a tag,
# otherwise the version in pubspec.yaml (without the +build suffix).
set -euo pipefail
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" == v* ]]; then
  echo "${GITHUB_REF_NAME#v}"
else
  grep -E '^version:' "$(dirname "$0")/../pubspec.yaml" | sed -E 's/version:[[:space:]]*//; s/\+.*//'
fi
