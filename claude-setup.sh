#!/bin/sh
#
# Fit out the claude jail: pf rdr to the allowlist, toolchain, linuxulator
# mounts, repo mounts, launcher. Run as root, safe to re-run.
#
#   doas sh ~/.jails/claude-setup.sh
#
# Run these first, in order:
#   doas sh ~/.jails/sniproxy-setup.sh
#   doas jail-new -n tuibase claude 172.16.1.70 home=home/acid
#
# No -x file: jail-new splices below the RFC1918 block, too late for either rule.
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=claude
JUSER=acid
JUID=1001
IP=172.16.1.70
PROXY=172.16.1.1
QUOTA=16G

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
sockstat -4 -l | grep -q "$PROXY:443" || die "sniproxy is not listening -- run sniproxy-setup.sh first"

# ------------------------------------------------------------------ 1. pf
# First: with -n the jail has no egress yet, so pkg would hang, not fail.
say "1/7  pf rdr to the allowlist"
if grep -q "^rdr on \$priv_if proto tcp from \$j_$JAIL" /etc/pf.conf; then
	skip
else
	awk -v name="$JAIL" -v addr="$PROXY" \
	    -v fanchor='# no LAN, no tailnet, and no reaching the trusted jails' '
	/^rdr-anchor/ {
		printf "# %s: 80/443 go to the sniproxy allowlist, never straight out\n", name
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
say "2/7  refquota"
zfs set refquota=$QUOTA "zroot/bastille/jails/$JAIL/root"
zfs get -H -o value refquota "zroot/bastille/jails/$JAIL/root" | sed 's/^/    /'

# --------------------------------------------------------------- 3. pkg
say "3/7  toolchain"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

if bastille cmd "$JAIL" test -x /usr/local/bin/claude >/dev/null 2>&1; then
	skip
else
	# claude-code is USES=linux:rl9, so it pulls linux_base-rl9. node and bash run the plugin hooks.
	bastille pkg -y "$JAIL" install claude-code node24 npm-node24 bash zsh git \
		ripgrep python312 gmake ca_root_nss
	bastille cmd "$JAIL" test -x /usr/local/bin/claude >/dev/null 2>&1 \
		|| die "claude did not install"
fi
[ -d "$ROOT/compat/linux" ] || die "linux_base-rl9 did not create /compat/linux"

# ------------------------------------------------------ 4. linuxulator fstab
# jail(8) reads mount.fstab before the jail exists, so /compat/linux must be there already.
say "4/7  linuxulator mounts"
mkdir -p "$ROOT/compat/linux/proc" "$ROOT/compat/linux/sys" \
	"$ROOT/compat/linux/dev/fd" "$ROOT/compat/linux/dev/shm"

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

# devfs first: dev/fd and dev/shm mount inside it, and a later devfs would hide them.
add_fstab "devfs $ROOT/compat/linux/dev devfs rw,ruleset=23 0 0" \
	"$ROOT/compat/linux/dev"
add_fstab "linprocfs $ROOT/compat/linux/proc linprocfs rw,nocover 0 0" \
	"$ROOT/compat/linux/proc"
add_fstab "linsysfs $ROOT/compat/linux/sys linsysfs rw,nocover 0 0" \
	"$ROOT/compat/linux/sys"
add_fstab "fdescfs $ROOT/compat/linux/dev/fd fdescfs rw,nocover,linrdlnk 0 0" \
	"$ROOT/compat/linux/dev/fd"
add_fstab "tmpfs $ROOT/compat/linux/dev/shm tmpfs rw,nocover,mode=1777 0 0" \
	"$ROOT/compat/linux/dev/shm"

# enforce_statfs 2 empties /compat/linux/proc/self/mounts and breaks getmntent.
bastille config "$JAIL" set enforce_statfs 1
echo "    enforce_statfs 1"

# ------------------------------------------------------------ 5. repo mounts
say "5/7  repo mounts"
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

# ------------------------------------------------------------- 6. restart
say "6/7  restart"
bastille stop "$JAIL" 2>/dev/null || true
bastille start "$JAIL"

ifconfig -j "$JAIL" -a 2>/dev/null | grep -qw "inet $IP" || die "$JAIL is not on $IP"
echo "    $JAIL up on $IP"

for d in proc sys dev/fd dev/shm; do
	jexec "$JAIL" sh -c "df /compat/linux/$d" >/dev/null 2>&1 \
		|| die "/compat/linux/$d did not mount"
done
echo "    4 linuxulator mounts live"

jexec "$JAIL" test -d /home/$JUSER/Workspace/repos || die "Workspace did not mount"
# plain "cmd && die" would trip set -e on the expected failure
if jexec "$JAIL" sh -c 'touch /home/acid/.jails/.wtest' 2>/dev/null; then
	rm -f /home/$JUSER/.jails/.wtest
	die ".jails mounted read-write -- it should be ro"
fi
echo "    Workspace rw, .jails ro"

jexec "$JAIL" /usr/local/bin/claude --version | sed 's/^/    /'

# ------------------------------------------------------------- 7. launcher
say "7/7  launcher"
# No ssh key in here, so invert the host's insteadOf or plugin refresh clones git@github.
jexec -l -u "$JUSER" "$JAIL" env PATH=/usr/local/bin:/bin:/usr/bin \
	git config --global url."https://github.com/".insteadOf "git@github.com:"

install -o root -g wheel -m 0755 "$SRCDIR/claude-jail" /usr/local/sbin/claude-jail
echo "    /usr/local/sbin/claude-jail"

mkdir -p "/home/$JUSER/bin"
printf '#!/bin/sh\nexec doas /usr/local/sbin/claude-jail "$@"\n' > "/home/$JUSER/bin/claude-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/claude-jail"
chmod 0755 "/home/$JUSER/bin/claude-jail"
echo "    /home/$JUSER/bin/claude-jail"

cat <<DONE

==> $JAIL is up.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/claude-jail

Then run it from a host terminal:  claude-jail

First start is an OAuth device flow: it prints a URL, the browser opens on the
host, the code goes back in. Settings can be copied by hand:

    cp ~/.claude/settings.json $ROOT/home/$JUSER/.claude/settings.json

Then rewrite the plugin marketplaces, because a "github" source makes Claude
Code clone over ssh and there is no key in here:

    jexec -l -u $JUSER $JAIL python3.12 /home/$JUSER/.jails/claude-marketplace-https.py

Do not copy ~/.claude.json. It holds the host oauthAccount block and the whole
prompt history.

No ssh key, no gh token and no card in the jail, so commits are unsigned and
push fails. Sign and push from the host.

The host install is untouched. Leave it until the jail has carried real work.
DONE
