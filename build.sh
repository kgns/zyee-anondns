#!/bin/sh
# Build the anondns .ipk. Run after placing the armv7 binaries + libs under
# package/data/opt/anondns/{bin,lib} and TLS under package/data/opt/anondns/etc/tls.
set -eu
PKG=anondns
VER="${VER:-1.0}"          # override in CI, e.g. VER=1.2 ./build.sh (git tag drives it)
ARCH=arm_cortex-a7
# The .ipk MUST be named/hosted as ${PKG}_${VER}_${ARCH}.ipk and control's Package:
# MUST equal ${PKG}: zyeed verifies install by requiring the URL filename to start
# with "<package>_". Renaming it breaks install with DU fault 9027.
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/${PKG}_${VER}_${ARCH}.ipk"
STAGE="$ROOT/.stage"

# Sanity: binaries must be present.
for f in opt/anondns/bin/dnscrypt-proxy opt/anondns/bin/dnsdist; do
	[ -f "$ROOT/package/data/$f" ] || {
		echo "missing package/data/$f - cross-build the armv7 binary first" >&2
		exit 1
	}
done

rm -rf "$STAGE"; mkdir -p "$STAGE/ctrl"

# Permissions.
chmod 0755 "$ROOT"/package/data/sbin/*.sh
chmod 0755 "$ROOT"/package/data/bin/*.sh 2>/dev/null || true
chmod 0755 "$ROOT"/package/data/opt/anondns/bin/* 2>/dev/null || true

# control.tar.gz
# `awk 1` guarantees a trailing newline on control before we copy it.
awk 1 "$ROOT/package/control" > "$STAGE/ctrl/control"
sed -i "s/^Version:.*/Version: $VER/" "$STAGE/ctrl/control"
# DO NOT emit Installed-Size. The device's `/` is read-only dual-bank ubifs, so
# statvfs reports 0 KB free; with a known installed size, opkg's
# verify_pkg_installable fails ("Only have 0kb available on filesystem /") and
# zyeed reports DU fault 9018. opkg skips that check only when installed_size==0
# (i.e. the field is absent). zyeed runs plain `opkg --nodeps install` with no
# --force-space to inject, so the field must never be present. (opkg does not
# estimate size from data.tar.gz, so absent => 0 => check skipped.)
[ -f "$ROOT/package/conffiles" ] && cp "$ROOT/package/conffiles" "$STAGE/ctrl/conffiles" || true
( cd "$STAGE/ctrl" && tar --numeric-owner --owner=0 --group=0 -czf "$STAGE/control.tar.gz" ./ )

# data.tar.gz
( cd "$ROOT/package/data" && tar --numeric-owner --owner=0 --group=0 -czf "$STAGE/data.tar.gz" ./ )

# debian-binary + assemble.
#
# The .ipk is the OpenWrt-native format: a GZIP TARBALL whose members are
# ./debian-binary, ./data.tar.gz, ./control.tar.gz (in that order)
echo "2.0" > "$STAGE/debian-binary"
rm -f "$OUT"
( cd "$STAGE" && tar --numeric-owner --owner=0 --group=0 \
	-czf "$OUT" ./debian-binary ./data.tar.gz ./control.tar.gz )

rm -rf "$STAGE"
echo "built $OUT"
