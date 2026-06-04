# Cross-build dnscrypt-proxy2 + a lean dnsdist for arm_cortex-a7 (musl, hard-float)
# using the official OpenWrt SDK. Produces .ipk files under /builder/bin which the
# host-side cross-build.sh extracts and re-bundles into the ZyEE DU.
#
#   ipq40xx == Cortex-A7  ->  package arch arm_cortex-a7 (the only arch the device opkg accepts)
#   23.05 feed            ->  dnsdist 1.9.10, dnscrypt-proxy2 2.1.5
# Pinned by digest for reproducibility (tag could move). To bump: pull the tag,
# `docker inspect --format='{{index .RepoDigests 0}}' openwrt/sdk:ipq40xx-generic-23.05.6`.
FROM openwrt/sdk:ipq40xx-generic-23.05.6@sha256:07175ef9bc88f184a1f46815779c7765a9ebb65d8adebaa7855e666cb9a5fe72

# Pull the two packages plus their feed-side build/runtime deps (boost, luajit, ...).
RUN ./scripts/feeds update base packages >/dev/null 2>&1 && \
    ./scripts/feeds install -d y dnsdist dnscrypt-proxy2

# Lean dnsdist feature set: just what dnsdist.conf needs (DoT front-end over OpenSSL).
# DoH / GnuTLS / sodium / snmp / re2 / lmdb / dnstap stay off to keep the bundle and
# RAM footprint small for the container memory cap.
RUN { \
      echo "CONFIG_PACKAGE_dnscrypt-proxy2=m"; \
      echo "CONFIG_PACKAGE_dnsdist=m"; \
      echo "CONFIG_DNSDIST_OPENSSL=y"; \
      echo "CONFIG_DNSDIST_DNS_OVER_TLS=y"; \
      echo "# CONFIG_DNSDIST_DNS_OVER_HTTPS is not set"; \
      echo "# CONFIG_DNSDIST_GNUTLS is not set"; \
      echo "# CONFIG_DNSDIST_SODIUM is not set"; \
      echo "# CONFIG_DNSDIST_NET_SNMP is not set"; \
      echo "# CONFIG_DNSDIST_RE2 is not set"; \
      echo "# CONFIG_DNSDIST_LMDB is not set"; \
      echo "# CONFIG_DNSDIST_DNSTAP is not set"; \
      echo "# CONFIG_DNSDIST_LIBEDIT is not set"; \
    } >> .config && \
    make defconfig && \
    grep -E "CONFIG_PACKAGE_(dnsdist|dnscrypt-proxy2)|CONFIG_DNSDIST_(OPENSSL|DNS_OVER_TLS|DNS_OVER_HTTPS|SODIUM)" .config

# Compile. boost/luajit/openssl deps build first; -j uses all cores.
RUN make -j"$(nproc)" \
      package/dnscrypt-proxy2/compile \
      package/dnsdist/compile \
    || make -j1 V=s \
      package/dnscrypt-proxy2/compile \
      package/dnsdist/compile

# Surface the produced ipks for easy extraction.
RUN mkdir -p /builder/out && \
    find /builder/bin -name '*.ipk' \
      \( -name 'dnsdist_*' -o -name 'dnscrypt-proxy2*' -o -name 'libstdcpp*' \
         -o -name 'luajit*' -o -name 'libluajit*' -o -name 'libopenssl*' \
         -o -name 'libcap*' -o -name 'libatomic*' -o -name 'libpthread*' \) \
      -exec cp -v {} /builder/out/ \; && \
    ls -la /builder/out
