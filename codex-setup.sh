#!/bin/sh
#
# Fit out the codex jail: pf rdr to its own allowlist, toolchain, repo mounts,
# launcher. Run as root, safe to re-run.
#
#   doas sh ~/.jails/codex-setup.sh
#
# Run these first, in order:
#   doas sh ~/.jails/sniproxy-setup.sh
#   doas jail-new -n tuibase codex 172.16.1.60 home=home/acid
#
# codex is a native FreeBSD ELF, so none of claude's linuxulator work applies.
# It proxies through 172.16.1.2, not .1, so the two jails cannot share an
# allowlist.
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=codex
JUSER=acid
JUID=1001
IP=172.16.1.60
PROXY=172.16.1.2
QUOTA=8G

PREFIX=/usr/local/bastille
JAILDIR=$PREFIX/jails/$JAIL
ROOT=$JAILDIR/root
FSTAB=$JAILDIR/fstab
SRCDIR=$(cd "$(dirname "$0")" && pwd)

# host path : jail path : mode
MOUNTS="/home/acid/Workspace:home/acid/Workspace:rw
/home/acid/.dotfiles:home/acid/.dotfiles:rw
/home/acid/.jails:home/acid/.jails:ro
/usr/ports:usr/ports:ro
/usr/src:usr/src:ro"

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"
grep -q "j_$JAIL" /etc/pf.conf || die "no j_$JAIL macro in pf.conf -- run jail-new first"
sockstat -4 -l | grep -q "$PROXY:443" || die "sniproxy is not on $PROXY -- run sniproxy-setup.sh first"

# ------------------------------------------------------------------ 1. pf
# First: with -n the jail has no egress yet, so pkg would hang, not fail.
say "1/6  pf rdr to the allowlist"
if grep -q "^rdr on \$priv_if proto tcp from \$j_$JAIL" /etc/pf.conf; then
	skip
else
	awk -v name="$JAIL" -v addr="$PROXY" \
	    -v fanchor='# no LAN, no tailnet, and no reaching the trusted jails' '
	/^rdr-anchor/ {
		printf "# %s: 80/443 go to its own sniproxy allowlist on %s\n", name, addr
		printf "rdr on $priv_if proto tcp from $j_%s to any port { 80, 443 } -> %s\n", name, addr
		print ""
		print
		next
	}
	index($0, fanchor) == 1 {
		printf "# %s: the proxy only. Must precede the RFC1918 block below, which is quick.\n", name
		printf "pass in quick on $priv_if proto tcp from $j_%s to %s port { 80, 443 } keep state\n", name, addr
		print ""
		print
		next
	}
	{ print }
	' /etc/pf.conf > "/tmp/pf.conf.$JAIL"

	grep -q "^rdr on \$priv_if proto tcp from \$j_$JAIL" "/tmp/pf.conf.$JAIL" \
		|| die "pf.conf anchors not found, refusing to edit"
	grep -q "^pass in quick on \$priv_if proto tcp from \$j_$JAIL" "/tmp/pf.conf.$JAIL" \
		|| die "pf.conf filter anchor not found, refusing to edit"

	pfctl -n -f "/tmp/pf.conf.$JAIL"
	cp /etc/pf.conf "/etc/pf.conf.bak-$JAIL-rdr"
	mv "/tmp/pf.conf.$JAIL" /etc/pf.conf
	pfctl -f /etc/pf.conf
	echo "    backup at /etc/pf.conf.bak-$JAIL-rdr"
fi

# --------------------------------------------------------------- 2. quota
say "2/6  refquota"
zfs set refquota=$QUOTA "zroot/bastille/jails/$JAIL/root"
zfs get -H -o value refquota "zroot/bastille/jails/$JAIL/root" | sed 's/^/    /'

# ----------------------------------------------------------------- 3. pkg
say "3/6  toolchain"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

if bastille cmd "$JAIL" test -x /usr/local/bin/codex >/dev/null 2>&1; then
	skip
else
	bastille pkg -y "$JAIL" install codex node24 npm-node24 bash zsh git \
		ripgrep python312 gmake ca_root_nss
	bastille cmd "$JAIL" test -x /usr/local/bin/codex >/dev/null 2>&1 \
		|| die "codex did not install"
fi

# ------------------------------------------------------------ 4. repo mounts
say "4/6  repo mounts"
add_fstab() {
	_line=$1
	_dst=$2
	if grep -q " $_dst " "$FSTAB"; then
		echo "    $_dst present"
	else
		echo "$_line" >> "$FSTAB"
		echo "    $_dst added"
	fi
}

# heredoc, not a pipe: die() in a piped while only kills the subshell
while IFS=: read -r src dst mode; do
	[ -n "$src" ] || continue
	[ -e "$src" ] || die "$src does not exist on the host"

	# thin jails symlink usr/src into the release; nullfs needs a real dir
	if [ -L "$ROOT/$dst" ]; then
		rm "$ROOT/$dst"
		echo "    replaced symlink $ROOT/$dst"
	fi
	mkdir -p "$ROOT/$dst"
	chown "$JUID:$JUID" "$ROOT/$dst"

	add_fstab "$src $ROOT/$dst nullfs $mode 0 0" "$ROOT/$dst"
done <<MOUNTLIST
$MOUNTS
MOUNTLIST

# ------------------------------------------------------------- 5. restart
say "5/6  restart"
bastille stop "$JAIL" 2>/dev/null || true
bastille start "$JAIL"

ifconfig -j "$JAIL" -a 2>/dev/null | grep -qw "inet $IP" || die "$JAIL is not on $IP"
echo "    $JAIL up on $IP"

# An agent spawns shell commands, and a missing ptmx makes those fail before exec.
if ! jexec "$JAIL" test -c /dev/ptmx; then
	echo "    no /dev/ptmx under ruleset 4, switching to 23"
	bastille config "$JAIL" set devfs_ruleset 23
	bastille restart "$JAIL"
	jexec "$JAIL" test -c /dev/ptmx || die "still no /dev/ptmx -- is ruleset 23 defined in /etc/devfs.rules?"
fi
echo "    /dev/ptmx present"

jexec "$JAIL" test -d /home/$JUSER/Workspace/repos || die "Workspace did not mount"
if jexec "$JAIL" sh -c 'touch /home/acid/.jails/.wtest' 2>/dev/null; then
	rm -f /home/$JUSER/.jails/.wtest
	die ".jails mounted read-write -- it should be ro"
fi
echo "    Workspace rw, .jails ro"

jexec "$JAIL" /usr/local/bin/codex --version | sed 's/^/    /'

# ------------------------------------------------------------- 6. launcher
say "6/6  launcher"
install -o root -g wheel -m 0755 "$SRCDIR/codex-jail" /usr/local/sbin/codex-jail
echo "    /usr/local/sbin/codex-jail"

mkdir -p "/home/$JUSER/bin"
printf '#!/bin/sh\nexec doas /usr/local/sbin/codex-jail "$@"\n' > "/home/$JUSER/bin/codex-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/codex-jail"
chmod 0755 "/home/$JUSER/bin/codex-jail"
echo "    /home/$JUSER/bin/codex-jail"

cat <<DONE

==> $JAIL is up.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/codex-jail

Then run it from a host terminal:  codex-jail

The host ~/.codex is not copied. It holds no credentials anyway, so the jail
starts unauthenticated and logs in on its own.

Egress goes to $PROXY, a separate sniproxy table from claude's. codex cannot
reach Anthropic endpoints and claude cannot reach OpenAI ones. Adding a domain
means editing the right table in ~/.jails/sniproxy.conf.

No ssh key, no gh token and no card in the jail, so commits are unsigned and
push fails. Sign and push from the host.
DONE
