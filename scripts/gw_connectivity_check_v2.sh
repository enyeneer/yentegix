#!/bin/sh
# ============================================================
# Gateway Connectivity Check v1

# Usage: sh gw_connectivity_check_v2.sh [interface]   (default: eth0.2)
# ============================================================

IFACE="${1:-eth0.2}"
TARGET="app.centegix.com"

echo ""
echo "===== Centegix Gateway Connectivity Check v1 ($IFACE) ====="
echo "Running on $(uname -n 2>/dev/null) at $(date)"

# ---- 1. Link state (Layer 1/2) ----
echo ""
echo "1. Interface $IFACE link state:"
if ip link show "$IFACE" 2>/dev/null | grep -q "state UP"; then
  echo "   $IFACE is UP"
else
  echo "   $IFACE is DOWN or not found"
fi

# ---- 2. IPv4 address (skip 169.254.x.x = APIPA = DHCP failed) ----
echo ""
echo "2. IP address on $IFACE:"
PRIMARY_IP=""
for IP in $(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2}'); do
  CLEAN_IP=$(echo "$IP" | cut -d/ -f1)
  case "$CLEAN_IP" in
    169.254.*) echo "   WARNING: APIPA address $CLEAN_IP — DHCP failed" ;;
    *) PRIMARY_IP="$CLEAN_IP"; break ;;
  esac
done
if [ -n "$PRIMARY_IP" ]; then
  echo "   IP Address: $PRIMARY_IP"
else
  echo "   No valid IP assigned"
fi

# ---- 3. DHCP or static ----
echo ""
echo "3. IP assignment type:"
if ps | grep "udhcpc.*$IFACE" | grep -v grep >/dev/null; then
  echo "   $IFACE is using DHCP (udhcpc active)"
else
  echo "   $IFACE appears to be static (no udhcpc process)"
fi

# ---- 4. Default gateway on this interface + reachability ----
echo ""
DEFAULT_GW=$(ip route show dev "$IFACE" 2>/dev/null | awk '/default/ {print $3}')
echo "4. Default gateway on $IFACE: ${DEFAULT_GW:-none found}"
if [ -n "$DEFAULT_GW" ]; then
  if ping -c 2 -I "$IFACE" -W 2 "$DEFAULT_GW" >/dev/null 2>&1; then
    echo "   Ping to $DEFAULT_GW: reachable"
  else
    echo "   Ping to $DEFAULT_GW: UNREACHABLE (local L3 problem)"
  fi
fi

# ---- 5. [NEW] Which WAN actually owns the default route? ----
# If this shows a cellular interface instead of $IFACE, the gateway has
# failed over — Ethernet path is down or degraded.
echo ""
echo "5. Active default route (the WAN carrying traffic right now):"
ip route show default 2>/dev/null | sed 's/^/   /'

# ---- 6. Internet reachability via ICMP (pinned to $IFACE) ----
# Two beacons (Zach's addition): if Google fails but the CENTEGIX detection
# server answers, egress isn't dead — something is filtering selectively
# (and the gateway's own failover logic may see a different picture than us).
echo ""
echo "6. ICMP test via $IFACE:"
if ping -c 5 -I "$IFACE" -W 4 8.8.8.8 >/dev/null 2>&1; then
  echo "   8.8.8.8 (Google DNS) reachable"
else
  echo "   8.8.8.8 (Google DNS) UNREACHABLE via $IFACE"
fi
if ping -c 3 -I "$IFACE" -W 4 35.243.210.132 >/dev/null 2>&1; then
  echo "   35.243.210.132 (CENTEGIX detection server) reachable"
else
  echo "   35.243.210.132 (CENTEGIX detection server) UNREACHABLE via $IFACE"
fi

# ---- 7. [NEW] DNS configuration — WHICH resolver are we using? ----
# Ethernet should show the local network's DNS; cellular shows the SIM/carrier
# DNS; a V1 behind an InHand should show 192.168.2.1.
echo ""
echo "7. Configured DNS resolvers (/etc/resolv.conf):"
cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | sed 's/^/   /'

# ---- 8. [NEW] DNS resolution test — the haiku step ----
echo ""
echo "8. DNS resolution test for $TARGET:"
if nslookup "$TARGET" >/dev/null 2>&1; then
  echo "   $TARGET resolves OK"
  nslookup "$TARGET" 2>/dev/null | awk '/^Address/ && !/#53/ {print "   ->", $NF}'
else
  echo "   FAILED to resolve $TARGET  <-- it was DNS"
fi

# ---- 9. [NEW] TCP + TLS test to the real endpoint ----
# ICMP can pass while TCP 443 is blocked (and vice versa). This tests
# DNS + TCP handshake + TLS handshake in one shot. ANY http code (200,
# 301, 403...) = full path works. 000 = connection or TLS failed.
echo ""
echo "9. HTTPS (TCP 443 + TLS) test to $TARGET:"
HTTP_CODE=$(curl -s -o /dev/null --connect-timeout 10 --max-time 20 \
  -w "%{http_code}" "https://$TARGET" 2>/dev/null)
if [ "$HTTP_CODE" != "000" ] && [ -n "$HTTP_CODE" ]; then
  echo "   SUCCESS — HTTP $HTTP_CODE (DNS + TCP + TLS all good)"
else
  echo "   FAILED — could not complete TCP/TLS to $TARGET:443"
  echo "   (If steps 6+8 passed but this fails: firewall is blocking 443,"
  echo "    or a content filter / SSL inspection is breaking TLS.)"
fi

# ---- 10. Established connections ----
echo ""
echo "10. Active ESTABLISHED connections (bound to ${PRIMARY_IP:-n/a}):"
if [ -n "$PRIMARY_IP" ]; then
  netstat -anp 2>/dev/null | grep "$PRIMARY_IP" | grep "ESTABLISHED" | sed 's/^/   /'
else
  echo "   Skipped — no valid IP on $IFACE"
fi

# ---- 11. Does this gateway answer pings? ----
echo ""
echo "11. ICMP echo policy:"
ICMP_IGNORE=$(cat /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null)
if [ "$ICMP_IGNORE" = "0" ]; then
  echo "   0 — gateway RESPONDS to ping (normal)"
else
  echo "   $ICMP_IGNORE — gateway IGNORES pings (don't let a customer 'ping test' fool you)"
fi

# ---- 12. Interface error counters ----
# Non-zero/climbing errors or drops = physical-layer suspicion (cable, port,
# duplex). Run twice a few minutes apart to see if they're climbing.
echo ""
echo "12. Interface statistics for $IFACE:"
ip -stats link show "$IFACE" 2>/dev/null | sed 's/^/   /'

# ---- 13. External IP + ISP (the cellular tell) ----
# If the org line shows the district's ISP -> on Ethernet.
# If it shows Verizon/AT&T/T-Mobile -> the gateway is riding CELLULAR.
echo ""
echo "13. Public IP and ISP (cellular detector):"
echo "   Org: $(curl -s --connect-timeout 10 ipinfo.io/org 2>/dev/null)"
echo "   IP:  $(curl -s --connect-timeout 10 https://ipv4.ident.me 2>/dev/null)"

# ---- 14. [NEW] Clock sanity (TLS dies if the clock is wrong) ----
# Certificates carry Not-Before/Not-After validity dates. A gateway that
# booted with a bad clock fails EVERY TLS handshake with everything open.
# Compare these two lines — they should agree within seconds.
echo ""
echo "14. Clock sanity check:"
echo "   Local : $(date -u)"
echo "   Server: $(curl -sI --connect-timeout 10 http://google.com 2>/dev/null | grep -i '^date:' | cut -d' ' -f2-)"

# ---- 15. Tradition ----
echo ""
echo " It's not DNS..."
echo " There's no way it's DNS..."
echo " It was DNS"
echo ""
echo "===== Diagnostics Complete ====="
