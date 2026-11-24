#!/usr/bin/env bash
# Copies the website (website/) into the GitHub Pages site directory, next to the apt and
# dnf repositories that publish-repos.sh maintains there.
#
#   packaging/publish-website.sh <site-dir>
#
# Files from the previous deploy are listed in <site>/.website-files and removed first, so
# pages deleted from website/ disappear from the site. The repository folders (apt/, rpm/)
# and courier.gpg are never touched.
set -euo pipefail

SITE="${1:?site dir}"
SRC="$(cd "$(dirname "$0")/../website" && pwd)"
MANIFEST="$SITE/.website-files"

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r f; do
    case "$f" in
      ""|apt/*|rpm/*|courier.gpg|.git/*) continue ;;
    esac
    rm -f "$SITE/$f"
  done < "$MANIFEST"
fi

(cd "$SRC" && find . -type f ! -name '.DS_Store' | sed 's#^\./##' | sort) > "$MANIFEST.new"
while IFS= read -r f; do
  mkdir -p "$SITE/$(dirname "$f")"
  cp "$SRC/$f" "$SITE/$f"
done < "$MANIFEST.new"
mv "$MANIFEST.new" "$MANIFEST"
find "$SITE" -mindepth 1 -type d -empty ! -path "$SITE/.git*" -delete
touch "$SITE/.nojekyll"
echo "website copied into $SITE ($(wc -l < "$MANIFEST") files)"
