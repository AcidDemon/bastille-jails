#!/bin/sh
#
# Install sniproxy as the egress allowlist for the jails that use it. Run as
# root, safe to re-run.
#
#   doas sh ~/.jails/sniproxy-setup.sh
#
# Run once before the first proxied jail. Per-jail pf rules come from
# sniproxy-jail.sh, or from claude-setup.sh and codex-setup.sh.

set -eu

CONF=/usr/local/etc/sniproxy.conf
LOG=/var/log/sniproxy.log
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -f "$SRCDIR/sniproxy.conf" ] || die "no sniproxy.conf next to this script"

ADDRS=$(awk '/^listen /{split($2,a,":"); print a[1]}' "$SRCDIR/sniproxy.conf" | sort -u)
[ -n "$ADDRS" ] || die "no listen addresses in sniproxy.conf"

say "1/6  package"
if pkg info -e sniproxy; then
	skip
else
	pkg install -y sniproxy
fi
[ -x /usr/local/sbin/sniproxy ] || die "sniproxy did not install"

say "2/6  config"
install -o root -g wheel -m 0644 "$SRCDIR/sniproxy.conf" "$CONF"
echo "    $CONF"

say "3/6  log file"
# sniproxy drops to nobody after binding, so it needs to own the log
touch "$LOG"
chown nobody:nobody "$LOG"
chmod 0640 "$LOG"
echo "    $LOG"

say "4/6  bridge addresses"
# sniproxy will not start if a listen address is missing, so alias them first.
for a in $ADDRS; do
	case "$a" in
	172.16.0.*) bridge=jailnatbridge ;;
	172.16.1.*) bridge=jailprivbridge ;;
	*) die "$a is on neither jail bridge" ;;
	esac

	if ifconfig "$bridge" | grep -q "inet $a "; then
		echo "    $a already on $bridge"
		continue
	fi

	ifconfig "$bridge" alias "$a" netmask 255.255.255.255
	echo "    $a aliased on $bridge"

	n=0
	while sysrc -n "ifconfig_${bridge}_alias${n}" >/dev/null 2>&1; do
		n=$((n + 1))
	done
	sysrc "ifconfig_${bridge}_alias${n}=inet $a netmask 255.255.255.255"
done

say "5/6  rc.conf"
sysrc sniproxy_enable=YES

say "6/6  start"
service sniproxy restart

for a in $ADDRS; do
	sockstat -4 -l | grep -q "$a:443" || die "sniproxy is not listening on $a:443 -- check $LOG and syslog"
	sockstat -4 -l | grep -q "$a:80"  || die "sniproxy is not listening on $a:80"
done
echo "    listening on: $(echo $ADDRS | tr '\n' ' ')"

# A table that matches nothing still listens, so probe the SNI path itself.
probe() {
	echo | timeout 10 openssl s_client -connect "$1:443" -servername "$2" >/dev/null 2>&1
}

probe 172.16.1.1 api.anthropic.com || die "172.16.1.1 refused api.anthropic.com"
probe 172.16.1.2 api.openai.com    || die "172.16.1.2 refused api.openai.com"
if probe 172.16.1.1 api.openai.com; then
	die "the claude address reached an OpenAI endpoint -- tables are crossed"
fi
if probe 172.16.1.2 api.anthropic.com; then
	die "the codex address reached an Anthropic endpoint -- tables are crossed"
fi
echo "    agent allowlists verified, and the two do not overlap"

cat <<DONE

==> sniproxy is up.

Allowlists are the table blocks in $CONF. sniproxy rereads them on
SIGHUP, so try "service sniproxy reload" first and fall back to restart if the
rc script does not wire it up.

element, vesktop and spotify are on catch-all tables: nothing is blocked by
name yet, but non-TLS traffic on 443 is dropped and every hostname is logged.
Harvest the real set with:

    awk '{print \$8}' $LOG | sort -u

Every accepted and refused name lands in $LOG. Read it when
something in a jail cannot reach where it expects to.
DONE
