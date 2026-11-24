#!/usr/bin/env bash
# Builds Linux packages from a `flutter build linux --release` bundle.
#
#   packaging/linux/build-packages.sh <version> [bundle-dir] [out-dir]
#
# Produces:
#   courier-api_<version>_amd64.deb       (Debian / Ubuntu / Mint / Pop!_OS — apt)
#   courier-api-<version>-1.x86_64.rpm    (Fedora / RHEL / openSUSE — dnf / zypper)   [needs rpmbuild]
#   courier-linux-x64.tar.gz              (portable bundle)
#
# Layout installed by both packages:
#   /opt/courier-api/                     the Flutter bundle (binary, lib/, data/)
#   /usr/bin/courier-api                  symlink to the binary
#   /usr/share/applications/io.github.ranefattesingh.courier.desktop
#   /usr/share/icons/hicolor/<n>x<n>/apps/io.github.ranefattesingh.courier.png
#   /usr/share/doc/courier-api/copyright  (MIT license)
set -euo pipefail

VERSION="${1:?usage: build-packages.sh <version> [bundle-dir] [out-dir]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUNDLE="${2:-$ROOT/build/linux/x64/release/bundle}"
OUT="${3:-$ROOT/dist}"
PKG=courier-api
APP_ID=io.github.ranefattesingh.courier
SUMMARY="Desktop API client for HTTP, GraphQL, gRPC, WebSocket, MQTT, Kafka and more"
MAINTAINER="Fattesingh Rane <41385129+ranefattesingh@users.noreply.github.com>"
HOMEPAGE="https://github.com/ranefattesingh/courier"

[ -x "$BUNDLE/courier" ] || { echo "bundle not found at $BUNDLE (run: flutter build linux --release)" >&2; exit 1; }
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- staged filesystem tree
STAGE="$WORK/root"
mkdir -p "$STAGE/opt/$PKG" "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$STAGE/usr/share/doc/$PKG"
cp -a "$BUNDLE/." "$STAGE/opt/$PKG/"
ln -s "../../opt/$PKG/courier" "$STAGE/usr/bin/$PKG"
install -m 644 "$HERE/$APP_ID.desktop" "$STAGE/usr/share/applications/$APP_ID.desktop"
for dir in "$HERE"/icons/hicolor/*/; do
  size="$(basename "$dir")"
  install -Dm 644 "$dir/apps/courier.png" "$STAGE/usr/share/icons/hicolor/$size/apps/$APP_ID.png"
done
install -m 644 "$ROOT/LICENSE" "$STAGE/usr/share/doc/$PKG/copyright"
find "$STAGE" -type d -exec chmod 755 {} +

# ---------------------------------------------------------------- portable tarball
tar -C "$BUNDLE" -czf "$OUT/courier-linux-x64.tar.gz" .
echo "built $OUT/courier-linux-x64.tar.gz"

# ---------------------------------------------------------------- .deb
DEB="$WORK/deb"
cp -a "$STAGE" "$DEB"
mkdir -p "$DEB/DEBIAN"
INSTALLED_KB="$(du -sk "$DEB" --exclude=DEBIAN | cut -f1)"
cat > "$DEB/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: devel
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0t64 | libgtk-3-0, libegl1, libgles2
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Description: $SUMMARY
 Courier is a free, open-source, local-first API client. Organise requests in
 collections and nested folders, switch environments, and test REST, GraphQL,
 gRPC, WebSocket, Socket.IO, MQTT, Server-Sent Events, SOAP and Kafka with every
 common authentication scheme. No account or cloud sync required.
EOF
dpkg-deb --root-owner-group -Zxz --build "$DEB" "$OUT/${PKG}_${VERSION}_amd64.deb" >/dev/null
echo "built $OUT/${PKG}_${VERSION}_amd64.deb"

# ---------------------------------------------------------------- .rpm
if command -v rpmbuild >/dev/null 2>&1; then
  RPMTOP="$WORK/rpm"
  mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  sed -e "s|@VERSION@|$VERSION|g" -e "s|@SUMMARY@|$SUMMARY|g" -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
      -e "s|@STAGE@|$STAGE|g" -e "s|@PKG@|$PKG|g" -e "s|@APP_ID@|$APP_ID|g" \
      "$HERE/courier-api.spec.in" > "$RPMTOP/SPECS/$PKG.spec"
  rpmbuild --quiet -bb --define "_topdir $RPMTOP" --target x86_64 "$RPMTOP/SPECS/$PKG.spec"
  cp "$RPMTOP"/RPMS/x86_64/*.rpm "$OUT/"
  echo "built $(ls "$OUT"/*.rpm)"
else
  echo "rpmbuild not found — skipping .rpm (install the 'rpm' package to build it)" >&2
fi
