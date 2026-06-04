#!/bin/sh
# Stopped by: zyeed -n anondns  ->  /sbin/anondns_stop.sh
pkill -f /opt/anondns/bin/dnsdist        2>/dev/null
pkill -f /opt/anondns/bin/dnscrypt-proxy 2>/dev/null
exit 0
