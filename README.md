# anondns

A Zyxel Execution Environment (ZyEE) deployment unit that runs `dnscrypt-proxy` +
`dnsdist` on a Zyxel router: anonymized DNSCrypt upstream with a DoT (`:853`) front-end.

## Layout
```
package/control                          opkg control
package/data/sbin/anondns.sh             entrypoint (zyeed -n anondns runs this); memory env tuning
package/data/sbin/anondns_stop.sh        stop hook
package/data/opt/anondns/etc/*           configs (dnscrypt-proxy.toml, dnsdist.conf, lan-forward.conf, tls/)
package/data/bin/start.sh                EE entrypoint override (launches the supervisor at boot)
package/data/opt/anondns/{bin,lib}/*     cross-built binaries + bundled libs (gitignored)
build.sh                                 assemble the .ipk (gzip tarball, OpenWrt opkg format)
tools/openwrt/Dockerfile                 OpenWrt SDK build of dnscrypt-proxy + lean dnsdist
tools/openwrt/cross-build.sh             build in SDK, extract, bundle libs, patchelf
tools/gen-selfsigned-cert.sh             generate a DoT TLS cert/key
```

## Build

### 1. Cross-build the binaries (Docker)
Produces `arm_cortex-a7` (musl, hard-float) binaries and bundles dnsdist's shared-lib
closure under `package/data/opt/anondns/{bin,lib}`:
```sh
tools/openwrt/cross-build.sh
```
This uses the OpenWrt SDK image `openwrt/sdk:ipq40xx-generic-23.05.6` (ipq40xx == Cortex-A7;
23.05 feed = dnsdist 1.9.10, dnscrypt-proxy2 2.1.5). dnsdist is built lean: **OpenSSL + DoT
only** (DoH / GnuTLS / sodium / snmp / re2 / lmdb / dnstap off) to keep the memory footprint
small. Both binaries are `patchelf`'d to interpreter + rpath `/opt/anondns/lib`.

First run compiles boost/openssl/dnsdist and is slow; the SDK image is cached afterwards.
Verify a built binary without a device using qemu:
```sh
cd package/data/opt/anondns
qemu-arm lib/ld-musl-armhf.so.1 --library-path lib bin/dnsdist --version
```

### 2. TLS cert/key for the DoT listener
dnsdist's `addTLSLocal` needs `fullchain.pem` + `privkey.pem` in
`package/data/opt/anondns/etc/tls/`. **Certs are baked into the `.ipk` at build time**, so
renewing means regenerate → `./build.sh` → reinstall.

> **Upgrade behaviour:** nothing is marked as an opkg *conffile*, so a reinstall **overwrites
> every file** with the new build — configs *and* the TLS cert. That's deliberate: it's how
> you **renew an expired cert** (regenerate → `./build.sh` → reinstall) and how config updates
> in a new version actually take effect. The cert is supplied at build time, so just keep your
> `fullchain.pem`/`privkey.pem` under `package/data/opt/anondns/etc/tls/` and every (re)build
> carries the current one onto the device.

- **Self-signed** — fine for clients you control (`stubby` with an SPKI pin, `kdig +tls`).
  *Not* accepted by Android "Private DNS". The script prints the SPKI pin for client pinning:
  ```sh
  tools/gen-selfsigned-cert.sh dot.yourdomain.com   # + optional extra SAN hostnames/IPs
  ```
- **Let's Encrypt** — required for Android Private DNS / any client validating a public CA.
  Needs a domain pointing at the router's public IP. As a non-root user the easiest path is a
  DNS-01 challenge on any machine (no inbound port required):
  ```sh
  certbot certonly --manual --preferred-challenges dns -d dot.yourdomain.com
  cp /etc/letsencrypt/live/dot.yourdomain.com/{fullchain,privkey}.pem \
     package/data/opt/anondns/etc/tls/
  ```
  Renewal (~90 days) = rebuild + reinstall. If that cadence is annoying, prefer a long-lived
  self-signed cert with client pinning.

### 3. Assemble the package
```sh
./build.sh        # -> anondns_1.0_arm_cortex-a7.ipk
```

## Configuration notes

### dnscrypt-proxy.toml — pinned set, globally diverse, anonymized
A small set of ~13 DNSCrypt resolvers is **pinned** across continents (N.America / Europe /
Asia / Oceania / Middle East / S.America, plus a local Istanbul option). We do **not** load the
full public list: with hundreds of resolvers, dnscrypt-proxy's startup latency-probe storm
(concurrent DNSCrypt handshakes) blew past the 60 MB cgroup and got OOM-killed. With the pinned
set it still latency-ranks and adaptively load-balances (`lb_strategy='p2'`, `lb_estimator=true`)
to the fastest healthy ones for wherever the box runs, just probing ~13 instead of hundreds.
Quality bar: `require_dnssec/nolog/nofilter`.

- **Anonymization is cross-operator.** A relay only hides you if it's run by a *different*
  operator than the resolver (else one entity sees both your IP and your query). Each route's
  `via` list therefore excludes the resolver's own operator — e.g. dnscry.pt resolvers go via
  cryptostorm/scaleway/plan9/tiarap relays, and the cryptostorm `cs-*` resolvers go via
  scaleway/plan9/tiarap (never the cryptostorm `anon-cs-*` relays). `skip_incompatible=true`
  drops any pair a relay can't carry. We do **not** use a wildcard `server_name='*'`, which
  could silently pick a same-operator relay.
- **Latency vs. availability:** anonymization adds one relay hop. For raw speed over privacy,
  comment out `[anonymized_dns]` (direct queries); to bias toward throughput set `lb_strategy`
  to `'ph'` (fastest half) or a number N.
- Refresh resolver/relay names occasionally against the live
  [public-resolvers.md](https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md)
  / [relays.md](https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/relays.md);
  unknown names are ignored, so the list degrades gracefully. If you change servers, re-verify
  the operator of each resolver and relay so the cross-operator routing still holds.
- ODoH is documented as an optional widen-availability add-on at the bottom of the file.

### Memory — designed to fit the 60 MB cap without root
The container's `lxc.cgroup.memory.limit_in_bytes` is 60 MB and raising it needs **root**. To work
for a standard user we instead shrink both daemons to a **~30–40 MB combined working set**:

- **dnscrypt-proxy** (`anondns.sh`): `GODEBUG=madvdontneed=1` (return freed pages to the kernel
  immediately — Go's default MADV_FREE leaves them in RSS where the cgroup counts them, the
  single biggest lever), `GOMAXPROCS=1`, `GOMEMLIMIT=24MiB`, `GOGC=20`; small `cache_size` /
  `max_clients` in the toml.
- **dnsdist** (`dnsdist.conf`): `setRingBuffersSize(100,1)` (default 10 000/shard),
  `setMaxUDPOutstanding(1024)` (default 65 535), `setMaxTCPClientThreads(1)`, packet cache 1000.

Only **anonymous** RSS counts toward an OOM — the bundled `.so`s and binary code are
file-backed and reclaimable. After install, confirm the footprint as a standard user
(`top`, or `cat /sys/fs/cgroup/memory/.../memory.max_usage_in_bytes`); if tight, drop
`GOMEMLIMIT` to `20MiB` and lower `max_clients`/cache further.

## Deploy
Host the `.ipk` on a LAN HTTP server, then use the router's Deployment Unit tab
(URL + unique UUID + Execution Environment `anondns`). No root required — the daemons are tuned
to run within the stock 60 MB cap (raising it is optional and root-only).

> **CRITICAL — do not rename the `.ipk`.** Host and install it under its exact build name
> `anondns_<version>_<arch>.ipk` (the standard opkg naming `<package>_<version>_<arch>.ipk`).
> The router matches the installed package against the URL filename, so the filename must begin
> with `<package>_` — keep `package/control`'s `Package:` equal to that prefix (`anondns`).
> Renaming the file (e.g. `anondns.ipk`) makes the install report a failure even though the
> files land correctly. Use the build's own name and you'll never hit this.

**Auto-start on reboot.** This firmware does *not* act on an Execution Unit's `AutoStart` flag
at cold boot — the container comes up and runs `zyeed -n anondns`, but no EU daemons launch
until a live management trigger (web-UI "Activate" / ACS). So the DU ships its own
`/bin/start.sh` (overwriting the EE-generated one) which launches the `/sbin/anondns.sh`
supervisor directly at every boot, then keeps `zyeed -n anondns` as the foreground anchor.
`anondns.sh` self-locks, so a later manual "Activate" won't double-start it. (The EE only
regenerates `start.sh` when the Execution Environment is re-created — reinstall the DU after that.)

## LAN-wide anonymized DNS (optional)
By default the stack is reachable on `:5300` (plain) and `:853` (DoT). To make **every LAN
client** resolve anonymously without per-client config, route the CPE's own dnsmasq through
dnscrypt — two parts:

1. **Point clients at the router (persistent, web UI).** In LAN Setup → DHCP → DNS, set the
   handed-out DNS to **DNS Relay / the router (`192.168.1.1`)** instead of any custom upstreams
   (e.g. `1.1.1.1, 8.8.8.8`). Otherwise clients query those directly and bypass the router.
2. **Make dnsmasq forward to dnscrypt.** The DU ships `etc/lan-forward.conf`
   (`no-resolv` + `server=127.0.0.1#5300`); `anondns.sh` publishes it to the host's dnsmasq
   conf-dir (`/var/dnsmasq/conf.d/00-anondns.conf`) on boot via the EE's bind-mounted `/var`.
   Delete that file to disable. Because the container can't restart the host dnsmasq (separate
   PID namespace) and `/var` is tmpfs, it takes effect on dnsmasq's next restart — usually at
   WAN-up shortly after boot. Force it immediately with `/etc/init.d/dnsmasq.sh restart`.

dnsdist (`:853` DoT) and the LAN path both terminate at dnscrypt-proxy, so all of it goes out
anonymized. (Verify on the router by temporarily adding `[query_log]` to `dnscrypt-proxy.toml`
and watching client query names appear; remove it afterward to keep no-logging.)

Verify on device:
```sh
logread | tail
ps w | grep -E 'dnsdist|dnscrypt-proxy'
```
