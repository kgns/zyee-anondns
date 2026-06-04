#!/bin/sh
# Started by: zyeed -n anondns  ->  /sbin/anondns.sh
# Foreground anchor for the container; respawns either daemon if it dies.
B=/opt/anondns/bin; E=/opt/anondns/etc
L=/opt/anondns/lib

# Do NOT export LD_LIBRARY_PATH globally. The EE's start.sh exports
# LD_LIBRARY_PATH=/lib:/usr/lib:/lib64; we must override it for OUR daemons, but
# if we export /opt/anondns/lib for the whole script then busybox sleep/kill/mkdir
# also try to load our musl libs (e.g. libcrypto.so.3) and crash with
# "internal error" — which makes the supervisor loop's `sleep` fail, spin without
# delay, and flood the log. So clear it here (the binaries carry RUNPATH=$L) and
# set LD_LIBRARY_PATH=$L inline ONLY on the daemon exec lines below.
unset LD_LIBRARY_PATH
mkdir -p /tmp/anondns

# Single-instance lock: this script is started by /bin/start.sh on every boot, and
# the ZyEE "Activate" button (web UI) can also launch it — without this guard a
# second supervisor would fight the first for :853/:5300. Exit if one is alive.
LOCK=/tmp/anondns/anondns.lock
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
	exit 0
fi
echo $$ > "$LOCK"

# dnsdist estimates it may want >1024 fds under TCP/DoT load; raise the soft limit.
ulimit -n 4096 2>/dev/null || true

start_dcp() {
	# Memory tuning for the 60 MB container cap (no root to raise it):
	#  - madvdontneed=1: return freed pages to the kernel immediately. Go's default
	#    MADV_FREE leaves them in RSS until pressure, which counts against the cgroup
	#    limit and can OOM us before the kernel reclaims. This is the biggest lever.
	#  - GOMAXPROCS=1: fewer per-P heap caches / OS threads on this multi-core SoC.
	#  - GOMEMLIMIT/GOGC: soft-cap the heap and collect aggressively.
	# Logs use >> (append): /tmp is tmpfs (counts against the 60 MB cgroup and is
	# NOT reclaimable), so cap_logs() truncates them; append mode makes that clean
	# (the daemon keeps writing at EOF after a truncate, no sparse-file growth).
	LD_LIBRARY_PATH=$L GODEBUG=madvdontneed=1 GOMAXPROCS=1 GOMEMLIMIT=24MiB GOGC=20 \
		"$B/dnscrypt-proxy" -config "$E/dnscrypt-proxy.toml" \
		>>/tmp/anondns/dcp.log 2>&1 &
	DCP=$!
}
start_dnd() {
	LD_LIBRARY_PATH=$L "$B/dnsdist" --supervised --disable-syslog -C "$E/dnsdist.conf" \
		>>/tmp/anondns/dnsdist.log 2>&1 &
	DND=$!
}

# Optional LAN integration (opt-in: only if etc/lan-forward.conf exists).
# Publishes a dnsmasq snippet (e.g. no-resolv + server=127.0.0.1#5300) into the
# host's conf-dir so the CPE's dnsmasq forwards LAN :53 to dnscrypt. The EE
# bind-mounts the host /var, so we can write it; but we CANNOT restart the host
# dnsmasq (separate PID namespace), so it takes effect on dnsmasq's next restart
# (typically when the WAN link comes up shortly after boot). /var is tmpfs, so we
# re-assert it each loop. Delete etc/lan-forward.conf to disable. (You must also
# point LAN clients at the router for DNS — DHCP option 6 — via the web UI.)
publish_lan_forward() {
	[ -f "$E/lan-forward.conf" ] || return 0
	[ -d /var/dnsmasq/conf.d ] || return 0
	cmp -s "$E/lan-forward.conf" /var/dnsmasq/conf.d/00-anondns.conf 2>/dev/null && return 0
	cp "$E/lan-forward.conf" /var/dnsmasq/conf.d/00-anondns.conf 2>/dev/null || true
}

# Keep each daemon log under ~512 KB (tmpfs/RAM): retain the most recent 128 KB.
cap_logs() {
	for f in /tmp/anondns/dcp.log /tmp/anondns/dnsdist.log; do
		[ -f "$f" ] || continue
		[ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt 524288 ] || continue
		tail -c 131072 "$f" > "$f.t" 2>/dev/null && cat "$f.t" > "$f"; rm -f "$f.t"
	done
}

cleanup() { kill "$DCP" "$DND" 2>/dev/null; rm -f "$LOCK"; exit 0; }

# Clean shutdown: shared host netns means an orphan keeps :853 bound and blocks restart.
trap cleanup TERM INT

start_dcp
sleep 1
start_dnd
publish_lan_forward

while :; do
	kill -0 "$DCP" 2>/dev/null || start_dcp
	kill -0 "$DND" 2>/dev/null || start_dnd
	cap_logs
	publish_lan_forward
	sleep 5
done
