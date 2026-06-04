#!/usr/bin/env bash
# Generate a self-signed TLS cert/key for dnsdist's DoT listener and drop it into
#   package/data/opt/anondns/etc/tls/{fullchain.pem,privkey.pem}
#
# Self-signed is fine for DoT clients you control (e.g. stubby with an SPKI pin,
# or `kdig +tls` for testing). It will NOT be accepted by Android "Private DNS",
# which requires a publicly-trusted CA — for that use Let's Encrypt (see README).
#
# Usage:  tools/gen-selfsigned-cert.sh  dot.example.com  [extra-SAN ...]
set -euo pipefail
CN="${1:?usage: gen-selfsigned-cert.sh <hostname> [extra-SAN ...]}"; shift || true
HERE="$(cd "$(dirname "$0")" && pwd)"
TLS="$HERE/../package/data/opt/anondns/etc/tls"
mkdir -p "$TLS"

# Build subjectAltName list (DoT clients match the hostname against the SAN).
san="DNS:$CN"
for s in "$@"; do
	case "$s" in
		*[0-9].[0-9]*) san="$san,IP:$s" ;;   # looks like an IP
		*)             san="$san,DNS:$s" ;;
	esac
done

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
	-nodes -days 3650 \
	-subj "/CN=$CN" -addext "subjectAltName=$san" \
	-keyout "$TLS/privkey.pem" -out "$TLS/fullchain.pem"
chmod 0600 "$TLS/privkey.pem"; chmod 0644 "$TLS/fullchain.pem"

echo
echo "Wrote: $TLS/fullchain.pem  +  privkey.pem   (CN=$CN, SAN=$san)"
echo "SPKI pin (for client pinning, e.g. stubby tls_pubkey_pinset):"
openssl x509 -in "$TLS/fullchain.pem" -pubkey -noout \
	| openssl pkey -pubin -outform der 2>/dev/null \
	| openssl dgst -sha256 -binary | openssl enc -base64 | sed 's/^/  sha256: /'
