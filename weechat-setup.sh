#!/bin/sh
#
# Install weechat into the jail jail-new created, migrate the host config,
# and install the launcher. Run as root, safe to re-run.
#
#   doas sh ~/.jails/weechat-setup.sh
#
# Run jail-new first:
#   doas jail-new -n -x ~/.jails/weechat.pf tuibase weechat 172.16.1.50 \
#        home=home/acid/.weechat
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=weechat
JUSER=acid
JUID=1001
SRC=/home/$JUSER/.config/weechat

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root
WHOME=$ROOT/home/$JUSER/.weechat
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

say "1/4  install weechat"
if bastille cmd "$JAIL" test -x /usr/local/bin/weechat >/dev/null 2>&1; then
	skip
else
	bastille pkg -y "$JAIL" install weechat
	bastille cmd "$JAIL" test -x /usr/local/bin/weechat >/dev/null 2>&1 \
		|| die "weechat did not install"
fi

say "2/4  config"
jexec "$JAIL" sh -c 'df /home/acid/.weechat' | grep -q jailstate \
	|| die "/home/$JUSER/.weechat is not on its jailstate dataset"

if [ -f "$WHOME/weechat.conf" ] || [ -f "$WHOME/irc.conf" ]; then
	skip
else
	[ -d "$SRC" ] || die "no host config at $SRC"
	cp -a "$SRC/." "$WHOME/"
	[ -f "$WHOME/irc.conf" ] || die "copy produced no irc.conf"
	echo "    $(find "$WHOME" -type f | wc -l | tr -d ' ') files from $SRC"
fi
chown -R "$JUID:$JUID" "$ROOT/home/$JUSER"

say "3/4  launcher"
install -o root -g wheel -m 0755 "$SRCDIR/weechat-jail" /usr/local/sbin/weechat-jail
echo "    /usr/local/sbin/weechat-jail"

say "4/4  ~/bin wrapper"
printf '#!/bin/sh\nexec doas /usr/local/sbin/weechat-jail "$@"\n' > "/home/$JUSER/bin/weechat-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/weechat-jail"
chmod 0755 "/home/$JUSER/bin/weechat-jail"
echo "    /home/$JUSER/bin/weechat-jail"

cat <<'DONE'

==> weechat installed.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/weechat-jail

Then run it from a host tmux pane:  weechat-jail

sec.conf is encrypted, so the first start needs:

    /secure passphrase

The host config in ~/.config/weechat is untouched. Delete it once the jailed
copy works.
DONE
