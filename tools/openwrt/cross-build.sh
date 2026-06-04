#!/usr/bin/env bash
# Cross-build dnscrypt-proxy + dnsdist for arm_cortex-a7 via the OpenWrt SDK (Docker),
# then stage the binaries + dnsdist's shared-lib closure into
#   package/data/opt/anondns/{bin,lib}
# ready for ../../build.sh to assemble the .ipk.
#
# Requires: docker, patchelf, readelf (binutils), ar, tar.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMG=anondns-sdk
LIBDIR=/opt/anondns/lib                       # on-device install path
LOADER=ld-musl-armhf.so.1
WORK="$HERE/.out"                             # extraction scratch (gitignored)
DEST_BIN="$REPO/package/data/opt/anondns/bin"
DEST_LIB="$REPO/package/data/opt/anondns/lib"

echo "==> [1/6] docker build SDK image ($IMG) — first run compiles boost/openssl/dnsdist, be patient"
docker build -t "$IMG" "$HERE"

echo "==> [2/6] extract .ipk artifacts + toolchain libs from the image"
rm -rf "$WORK"; mkdir -p "$WORK/ipks" "$WORK/rootfs" "$WORK/toolchain"
cid="$(docker create "$IMG")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker cp "$cid:/builder/out/." "$WORK/ipks/"
# musl loader, libc, libgcc_s, libstdc++, libatomic live in the toolchain staging dir.
tdir="$(docker run --rm "$IMG" sh -c 'ls -d /builder/staging_dir/toolchain-*/lib | head -1')"
docker cp "$cid:$tdir/." "$WORK/toolchain/"

echo "==> [3/6] unpack ipk payloads into a merged rootfs"
for ipk in "$WORK"/ipks/*.ipk; do
	echo "    - $(basename "$ipk")"
	tmp="$(mktemp -d)"
	# OpenWrt .ipk = gzip tarball (./data.tar.gz, ./control.tar.gz); Debian-style = ar archive.
	if tar -tzf "$ipk" >/dev/null 2>&1; then
		( cd "$tmp" && tar -xzf "$ipk" && tar -xzf data.tar.gz -C "$WORK/rootfs" )
	else
		( cd "$tmp" && ar x "$ipk" && tar -xzf data.tar.gz -C "$WORK/rootfs" )
	fi
	rm -rf "$tmp"
done

# Search roots for resolving NEEDED libraries.
SEARCH=("$WORK/rootfs/usr/lib" "$WORK/rootfs/lib" "$WORK/toolchain")

find_lib() {  # $1 = soname -> echo absolute path or empty
	local name="$1" d
	for d in "${SEARCH[@]}"; do
		[ -e "$d/$name" ] && { readlink -f "$d/$name"; return; }
	done
}

echo "==> [4/6] stage binaries"
rm -f "$DEST_BIN"/dnsdist "$DEST_BIN"/dnscrypt-proxy
# dnscrypt-proxy: the .ipk binary keeps its section headers (Go binaries aren't sstripped).
cp "$WORK/rootfs/usr/sbin/dnscrypt-proxy" "$DEST_BIN/dnscrypt-proxy" 2>/dev/null \
	|| cp "$WORK/rootfs/usr/bin/dnscrypt-proxy" "$DEST_BIN/dnscrypt-proxy"
# dnsdist: the .ipk binary is sstripped (no section-header table) so patchelf can't touch it.
# Grab the pre-final .pkgdir copy instead — GNU-stripped, KEEPS section headers — then
# strip it ourselves with the toolchain (also keeps the SHT) to shed debug bloat (~65M -> ~2M).
pkgdir_dnsdist="$(docker run --rm "$IMG" sh -c \
	'ls /builder/build_dir/target-*/dnsdist-mini/dnsdist-*/.pkgdir/dnsdist/usr/bin/dnsdist 2>/dev/null | head -1')"
[ -n "$pkgdir_dnsdist" ] || { echo "FATAL: .pkgdir dnsdist not found in image" >&2; exit 1; }
docker cp "$cid:$pkgdir_dnsdist" "$DEST_BIN/dnsdist"
tc_strip="$(docker run --rm "$IMG" sh -c \
	'ls /builder/staging_dir/toolchain-*/bin/arm-openwrt-linux-strip 2>/dev/null | head -1')"
docker run --rm -v "$DEST_BIN:/w" "$IMG" "$tc_strip" --strip-all /w/dnsdist
chmod 0755 "$DEST_BIN/dnsdist" "$DEST_BIN/dnscrypt-proxy"

echo "==> [5/6] resolve shared-lib closure (both binaries) into $DEST_LIB"
# clear previously bundled libs (keep .gitkeep)
find "$DEST_LIB" -type f ! -name '.gitkeep' -delete
declare -A seen=()
queue=("$DEST_BIN/dnsdist" "$DEST_BIN/dnscrypt-proxy")
while [ "${#queue[@]}" -gt 0 ]; do
	cur="${queue[0]}"; queue=("${queue[@]:1}")
	while read -r need; do
		[ -n "$need" ] || continue
		[ -n "${seen[$need]:-}" ] && continue
		seen[$need]=1
		src="$(find_lib "$need")"
		if [ -z "$src" ]; then
			echo "    !! MISSING: $need (NEEDED by $(basename "$cur"))" >&2
			continue
		fi
		base="$(basename "$src")"
		cp -n "$src" "$DEST_LIB/$base"
		# preserve the soname symlink if it differs from the real file
		[ "$base" = "$need" ] || ln -sf "$base" "$DEST_LIB/$need"
		echo "    + $need -> $base"
		queue+=("$src")
	done < <(readelf -d "$cur" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')
done

# musl loader (the dynamic linker is not listed as NEEDED).
loader_src="$(find_lib "$LOADER")"
[ -z "$loader_src" ] && loader_src="$(ls "$WORK"/toolchain/ld-musl-*.so.1 2>/dev/null | head -1)"
[ -n "$loader_src" ] || { echo "FATAL: musl loader not found" >&2; exit 1; }
cp -n "$loader_src" "$DEST_LIB/$LOADER"
echo "    + loader -> $(basename "$loader_src")"

# Dedup: in musl, libc.so IS the dynamic loader (same file). If both got staged,
# replace the libc.so copy with a symlink to the loader to save ~3 MB on disk.
if [ -e "$DEST_LIB/libc.so" ] && cmp -s "$DEST_LIB/libc.so" "$DEST_LIB/$LOADER"; then
	ln -sf "$LOADER" "$DEST_LIB/libc.so"
	echo "    = libc.so -> $LOADER (dedup, saved ~3 MB)"
fi

echo "==> [6/6] patchelf both binaries: interpreter + rpath -> $LIBDIR"
# Default musl interpreter is /lib/ld-musl-armhf.so.1, which does not exist on the
# glibc host rootfs; repoint it (and the lib search path) at the bundled copy.
for b in dnsdist dnscrypt-proxy; do
	patchelf --set-interpreter "$LIBDIR/$LOADER" --set-rpath "$LIBDIR" "$DEST_BIN/$b"
done

echo
echo "Staged binaries:"
file "$DEST_BIN/dnsdist" "$DEST_BIN/dnscrypt-proxy" 2>/dev/null || ls -l "$DEST_BIN"
echo "Bundled libs:"
ls -l "$DEST_LIB"
echo
echo "dnsdist NEEDED + interp:"
readelf -d "$DEST_BIN/dnsdist" | grep -E 'NEEDED|RUNPATH|RPATH' || true
patchelf --print-interpreter "$DEST_BIN/dnsdist"
echo
echo "Done. Now run: $REPO/build.sh"
