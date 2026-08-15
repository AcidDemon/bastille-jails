#!/bin/sh
#
# Install sniproxy as the egress allowlist for the agent jails. Run as root,
# safe to re-run.
#
#   doas sh ~/.jails/sniproxy-setup.sh
#
# Run once, before the first agent jail. The pf rdr comes from <jail>-setup.sh.

set -eu

CONF=/usr/local/etc/sniproxy.conf
LOG=/var/log/sniproxy.log
BRIDGE=jailprivbridge
ADDR=172.16.1.1
ALIAS=172.16.1.2
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

say "1/5  package"
if pkg info -e sniproxy; then
	skip
else
	pkg install -y sniproxy
fi
[ -x /usr/local/sbin/sniproxy ] || die "sniproxy did not install"

say "2/5  config"
[ -f "$SRCDIR/sniproxy.conf" ] || die "no sniproxy.conf next to this script"
install -o root -g wheel -m 0644 "$SRCDIR/sniproxy.conf" "$CONF"
echo "    $CONF"

say "3/5  log file"
# sniproxy drops to nobody after binding, so it needs to own the log
touch "$LOG"
chown nobody:nobody "$LOG"
chmod 0640 "$LOG"
echo "    $LOG"

say "4/5  bridge alias"
# One listener address per jail. /32 so it does not claim the subnet twice.
if ifconfig "$BRIDGE" | grep -q "inet $ALIAS "; then
	skip
else
	ifconfig "$BRIDGE" alias "$ALIAS" netmask 255.255.255.255
	echo "    $ALIAS on $BRIDGE"
fi
sysrc "ifconfig_${BRIDGE}_alias0=inet $ALIAS netmask 255.255.255.255"
sysrc sniproxy_enable=YES

say "5/5  start"
service sniproxy restart

# The bridge address is the only place it should ever answer.
for a in "$ADDR" "$ALIAS"; do
	sockstat -4 -l | grep -q "$a:443" || die "sniproxy is not listening on $a:443 -- check $LOG and syslog"
	sockstat -4 -l | grep -q "$a:80"  || die "sniproxy is not listening on $a:80"
done

sockstat -4 -l | grep sniproxy | sed 's/^/    /'

# A table that matches nothing still listens, so probe the SNI path itself.
probe() {
	echo | timeout 10 openssl s_client -connect "$1:443" -servername "$2" >/dev/null 2>&1
}

for a in "$ADDR" "$ALIAS"; do
	probe "$a" pkg.freebsd.org \
		|| die "$a refused an allowlisted name -- table entries need a target, see sniproxy.conf(5)"
	if probe "$a" nowhere.invalid; then
		die "$a allowed an unlisted name -- the table is not filtering"
	fi
done

# The two tables must not be interchangeable, or the split buys nothing.
probe "$ADDR" api.anthropic.com || die "$ADDR refused api.anthropic.com"
probe "$ALIAS" api.openai.com   || die "$ALIAS refused api.openai.com"
if probe "$ADDR" api.openai.com; then
	die "the claude address reached an OpenAI endpoint -- tables are crossed"
fi
if probe "$ALIAS" api.anthropic.com; then
	die "the codex address reached an Anthropic endpoint -- tables are crossed"
fi
echo "    allowlists verified, and the two do not overlap"

cat <<DONE

==> sniproxy is up on $ADDR.

The allowlist is the "table agents" block in $CONF. sniproxy rereads it on
SIGHUP, so try "service sniproxy reload" first and fall back to restart if the
rc script does not wire it up.

Every accepted and refused name lands in $LOG. Read it when
something in a jail cannot reach where it expects to.
DONE
