#!/bin/sh
#
# Make bridge port isolation persistent for the existing app jails. Run as root,
# safe to re-run.
#
#   doas sh ~/.jails/bridge-private-persist.sh
#
# Adds one exec.prestart line per jail and sets the flag live, so no restart is
# needed. Run bridge-private-test.sh first.
#
# Skips the baselines on purpose: clone rewrites addm but not
# `private e0a_<name>`, so a clone would set it on an interface it does not have.
# jail-new adds the line per jail instead.

set -eu

PREFIX=/usr/local/bastille
JAILS="zen spotify vesktop zenburner"

say() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

for j in $JAILS; do
	conf=$PREFIX/jails/$j/jail.conf
	[ -f "$conf" ] || { echo "no $j, skipping"; continue; }

	say "$j"

	br=$(sed -n "s/.*ifconfig \([A-Za-z0-9_]*\) addm e0a_$j.*/\1/p" "$conf" | head -1)
	[ -n "$br" ] || die "$j: no addm line in $conf, cannot tell which bridge"
	echo "    bridge $br"

	if grep -q "private e0a_$j" "$conf"; then
		echo "    jail.conf already has it"
	else
		cp "$conf" "$conf.bak-private"
		awk -v line="  exec.prestart += \"ifconfig $br private e0a_$j\";" '
		/^}/ && !ins { print line; ins = 1 }
		{ print }
		' "$conf.bak-private" > "$conf"
		grep -q "private e0a_$j" "$conf" || die "$j: failed to add the line"
		echo "    jail.conf updated, backup at $conf.bak-private"
	fi

	if jls -j "$j" jid >/dev/null 2>&1; then
		ifconfig "$br" private "e0a_$j"
		echo "    set live"
	else
		echo "    not running, takes effect at next start"
	fi
done

say "member flags"
for b in jailnatbridge jailprivbridge; do
	printf '  %s\n' "$b"
	ifconfig "$b" | awk '/member:/ {print "    " $2 " " $3}'
done

cat <<'DONE'

Every member above should carry PRIVATE. A jail without it can still ARP its
neighbours on the same bridge.
DONE
