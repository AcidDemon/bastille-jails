#!/bin/sh
#
# Route one jail's 80/443 through sniproxy instead of straight out. Run as root,
# safe to re-run.
#
#   doas sh ~/.jails/sniproxy-jail.sh NAME JAIL_IP PROXY_IP
#   doas sh ~/.jails/sniproxy-jail.sh element 172.16.0.50 172.16.0.2
#
# Adds PROXY_IP as a /32 alias on the jail's bridge, inserts the rdr, replaces
# the jail's direct 80/443 pass with one to the proxy, and drops its udp 443
# rule. That last one matters: Chromium prefers QUIC and would skip the proxy.
#
# sniproxy.conf needs a matching listener pair and table on PROXY_IP first.

set -eu

NAME=${1:-}
JAIL_IP=${2:-}
PROXY_IP=${3:-}

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -n "$NAME" ] && [ -n "$JAIL_IP" ] && [ -n "$PROXY_IP" ] \
	|| die "usage: $0 NAME JAIL_IP PROXY_IP"
[ "$(id -u)" = 0 ] || die "must run as root"
grep -q "j_$NAME" /etc/pf.conf || die "no j_$NAME macro in pf.conf"

case "$JAIL_IP" in
172.16.0.*)
	BRIDGE=jailnatbridge
	IF_MACRO='$jail_if'
	FANCHOR='# Jails reach neither the LAN, the tailnet, nor each other'
	;;
172.16.1.*)
	BRIDGE=jailprivbridge
	IF_MACRO='$priv_if'
	FANCHOR='# no LAN, no tailnet, and no reaching the trusted jails'
	;;
*)
	die "$JAIL_IP is on neither jail bridge"
	;;
esac

say "1/4  bridge alias"
if ifconfig "$BRIDGE" | grep -q "inet $PROXY_IP "; then
	skip
else
	ifconfig "$BRIDGE" alias "$PROXY_IP" netmask 255.255.255.255
	echo "    $PROXY_IP on $BRIDGE"
fi

# Find the next free alias index rather than clobbering an existing one.
n=0
while sysrc -n "ifconfig_${BRIDGE}_alias${n}" >/dev/null 2>&1; do
	if sysrc -n "ifconfig_${BRIDGE}_alias${n}" | grep -q "$PROXY_IP"; then
		n=""
		break
	fi
	n=$((n + 1))
done
if [ -n "$n" ]; then
	sysrc "ifconfig_${BRIDGE}_alias${n}=inet $PROXY_IP netmask 255.255.255.255"
else
	echo "    rc.conf alias already present"
fi

say "2/4  sniproxy is listening there"
sockstat -4 -l | grep -q "$PROXY_IP:443" || die "nothing on $PROXY_IP:443 -- add the listener to sniproxy.conf and rerun sniproxy-setup.sh"
sockstat -4 -l | grep -q "$PROXY_IP:80"  || die "nothing on $PROXY_IP:80"

say "3/4  pf"
if grep -q "^rdr on $IF_MACRO proto tcp from \$j_$NAME" /etc/pf.conf; then
	skip
else
	awk -v name="$NAME" -v addr="$PROXY_IP" -v ifm="$IF_MACRO" -v fanchor="$FANCHOR" '
	/^rdr-anchor/ {
		printf "# %s: 80/443 go to its sniproxy allowlist on %s\n", name, addr
		printf "rdr on %s proto tcp from $j_%s to any port { 80, 443 } -> %s\n", ifm, name, addr
		print ""
		print
		next
	}
	# the direct rules are what the rdr replaces, so they go
	$0 ~ ("^pass in quick on .* from \\$j_" name " to any port \\{ 80, 443 \\}") { next }
	$0 ~ ("^pass in quick on .* proto udp from \\$j_" name " to any port 443") { next }
	index($0, fanchor) == 1 {
		printf "# %s: the proxy only. Must precede the RFC1918 block below, which is quick.\n", name
		printf "pass in quick on %s proto tcp from $j_%s to %s port { 80, 443 } keep state\n", ifm, name, addr
		print ""
		print
		next
	}
	{ print }
	' /etc/pf.conf > "/tmp/pf.conf.$NAME"

	grep -q "^rdr on $IF_MACRO proto tcp from \$j_$NAME" "/tmp/pf.conf.$NAME" \
		|| die "pf.conf translation anchor not found, refusing to edit"
	grep -q "to $PROXY_IP port { 80, 443 }" "/tmp/pf.conf.$NAME" \
		|| die "pf.conf filter anchor not found, refusing to edit"
	# named exactly: the rdr repeats the same text, and the WebRTC rules must stay
	if grep -q "^pass in quick on .* from \$j_$NAME to any port { 80, 443 }" "/tmp/pf.conf.$NAME"; then
		die "the direct 80/443 pass for $NAME survived, refusing to apply a half change"
	fi
	if grep -q "^pass in quick on .* proto udp from \$j_$NAME to any port 443 " "/tmp/pf.conf.$NAME"; then
		die "the udp 443 pass for $NAME survived, so QUIC would skip the proxy"
	fi

	pfctl -n -f "/tmp/pf.conf.$NAME"
	cp /etc/pf.conf "/etc/pf.conf.bak-$NAME-proxy"
	mv "/tmp/pf.conf.$NAME" /etc/pf.conf
	pfctl -f /etc/pf.conf
	echo "    backup at /etc/pf.conf.bak-$NAME-proxy"
fi

say "4/4  rules now in force for $NAME"
pfctl -s nat 2>/dev/null | grep "$JAIL_IP" | sed 's/^/    /'
pfctl -s rules 2>/dev/null | grep "$JAIL_IP" | sed 's/^/    /'

cat <<DONE

==> $NAME now reaches the network only through $PROXY_IP.

Its WebRTC and other UDP rules are untouched, and sniproxy cannot see them.
udp 443 was removed on purpose, so the client falls back from QUIC to HTTP/2.

While its table is a catch-all, nothing is blocked by name, but non-TLS traffic
on 443 is dropped and every hostname is logged. Harvest the real set with:

    awk '{print \$8}' /var/log/sniproxy.log | sort -u

then replace the catch-all in ~/.jails/sniproxy.conf and rerun sniproxy-setup.sh.
DONE
