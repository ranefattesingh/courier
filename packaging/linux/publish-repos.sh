#!/usr/bin/env bash
# Adds new .deb/.rpm packages to signed apt and dnf repositories in a static site
# directory (served by GitHub Pages from the gh-pages branch).
#
#   packaging/linux/publish-repos.sh <packages-dir> <site-dir> <gpg-key-id> <base-url>
#
# Requires: apt-ftparchive (apt-utils), createrepo_c, rpmsign (rpm), gpg with the
# private key imported. Keeps the newest $KEEP versions of each package.
#
# Resulting layout:
#   <site>/courier.gpg                       public signing key (ASCII armored)
#   <site>/apt/pool/main/*.deb
#   <site>/apt/dists/stable/{Release,Release.gpg,InRelease,main/binary-amd64/Packages{,.gz}}
#   <site>/rpm/*.rpm, <site>/rpm/repodata/…, <site>/rpm/courier.repo
set -euo pipefail

PKGS="${1:?packages dir}"
SITE="${2:?site dir}"
KEY="${3:?gpg key id}"
BASE="${4:?base url, e.g. https://ranefattesingh.github.io/courier}"
KEEP="${KEEP:-5}"

prune() { # keep the newest $KEEP files matching a glob in a directory
  local dir="$1" pattern="$2"
  ls -1 "$dir"/$pattern 2>/dev/null | sort -V | head -n -"$KEEP" | xargs -r rm -f
}

mkdir -p "$SITE"
gpg --armor --export "$KEY" > "$SITE/courier.gpg"

# ---------------------------------------------------------------- apt
APT="$SITE/apt"
mkdir -p "$APT/pool/main" "$APT/dists/stable/main/binary-amd64"
cp "$PKGS"/*.deb "$APT/pool/main/"
prune "$APT/pool/main" 'courier-api_*_amd64.deb'
(
  cd "$APT"
  apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
  gzip -9fk dists/stable/main/binary-amd64/Packages
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Courier \
    -o APT::FTPArchive::Release::Label=Courier \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    release dists/stable > dists/stable/Release
  gpg --batch --yes --default-key "$KEY" -abs -o dists/stable/Release.gpg dists/stable/Release
  gpg --batch --yes --default-key "$KEY" --clearsign -o dists/stable/InRelease dists/stable/Release
)

# ---------------------------------------------------------------- dnf / yum / zypper
RPM="$SITE/rpm"
mkdir -p "$RPM"
for f in "$PKGS"/*.rpm; do
  cp "$f" "$RPM/"
  rpmsign --define "_gpg_name $KEY" --addsign "$RPM/$(basename "$f")" >/dev/null
done
prune "$RPM" 'courier-api-*.x86_64.rpm'
createrepo_c --update "$RPM" >/dev/null
gpg --batch --yes --default-key "$KEY" --detach-sign --armor "$RPM/repodata/repomd.xml"
cat > "$RPM/courier.repo" <<EOF
[courier]
name=Courier
baseurl=$BASE/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$BASE/courier.gpg
EOF

# The landing page and docs are published separately by packaging/publish-website.sh.
touch "$SITE/.nojekyll"
echo "repositories updated in $SITE"
