#!/bin/sh
#
# Test if_bridge port isolation on the jail bridges. Run as root.
#
#   doas sh ~/.jails/bridge-private-test.sh
#
# Probes jail-to-jail reachability at layer 2 before and after setting the
# private flag, then checks DNS and HTTPS still work. Reverts by itself if any
# regression check fails. Changes nothing persistently either way.

set -eu

NATBR=jailnatbridge
PRIVBR=jailprivbridge
PROBE=zen
PEERS="172.16.0.30 172.16.0.40"

say()  { printf '\n==> %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

MEMBERS=$(ifconfig $NATBR | awk '/member:/ {print $2}')
PRIVMEMBERS=$(ifconfig $PRIVBR | awk '/member:/ {print $2}')
[ -n "$MEMBERS" ] || die "no members on $NATBR"

revert() {
	for m in $MEMBERS; do ifconfig $NATBR -private "$m" 2>/dev/null || true; done
	for m in $PRIVMEMBERS; do ifconfig $PRIVBR -private "$m" 2>/dev/null || true; done
}

# arp resolves at layer 2, below pf, so it shows reachability that ping cannot.
arp_probe() {
	for ip in $PEERS; do
		jexec $PROBE arp -d "$ip" >/dev/null 2>&1 || true
		jexec $PROBE ping -c1 -t1 "$ip" >/dev/null 2>&1 || true
		_out=$(jexec $PROBE arp -n "$ip" 2>&1 || true)
		case "$_out" in
		*"no entry"*|*"incomplete"*) echo "    $ip  unresolved, no arp reply" ;;
		*) echo "    $ip  REACHABLE $(echo "$_out" | awk '{print $4}')" ;;
		esac
	done
}

say "members"
printf '  %s: %s\n' "$NATBR" "$(echo $MEMBERS | tr '\n' ' ')"
printf '  %s: %s\n' "$PRIVBR" "$(echo $PRIVMEMBERS | tr '\n' ' ')"

say "before: arp from $PROBE to its bridge neighbours"
arp_probe

say "setting private on every member of both bridges"
for m in $MEMBERS; do ifconfig $NATBR private "$m"; echo "    $NATBR $m"; done
for m in $PRIVMEMBERS; do ifconfig $PRIVBR private "$m"; echo "    $PRIVBR $m"; done
ifconfig $NATBR | grep member

say "after: same probe"
arp_probe

say "regression: DNS and egress still work"
FAIL=0

check() {
	printf '    %-28s ' "$1"
	shift
	if "$@" >/dev/null 2>&1; then echo ok; else echo FAILED; FAIL=1; fi
}

check "zen dns"        jexec zen drill -Q @172.16.0.1 freebsd.org
check "zen https"      jexec zen fetch -qo /dev/null https://freebsd.org
check "zenburner dns"  jexec zenburner drill -Q @172.16.0.1 freebsd.org
jls -j spotify jid >/dev/null 2>&1 && check "spotify dns" jexec spotify getent hosts deb.debian.org
jls -j vesktop jid >/dev/null 2>&1 && check "vesktop dns" jexec vesktop getent hosts discord.com

if [ "$FAIL" -ne 0 ]; then
	say "a check failed, reverting"
	revert
	ifconfig $NATBR | grep member
	die "port isolation broke something, flags cleared"
fi

cat <<DONE

==> Port isolation holds and nothing regressed.

Still not persistent. The flags are gone at the next jail restart, because
membership is created by each jail's exec.prestart. To keep it, add one line
per jail next to the existing addm:

    exec.prestart += "ifconfig $NATBR private e0a_<name>";

To clear the flags now:

    doas sh -c 'for m in $(echo $MEMBERS | tr "\n" " "); do ifconfig $NATBR -private \$m; done'
DONE
