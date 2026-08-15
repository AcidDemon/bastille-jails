#!/bin/sh
#
# Install spotify-client and spicetify into the jail jail-new created. Run as
# root, safe to re-run against a live spotify.
#
#   doas sh ~/.jails/spotify-setup.sh
#
# Run jail-new first:
#   doas jail-new linbase spotify 172.16.0.30 \
#        config=home/acid/.config/spotify
#
# Spotify needs one extra pf rule beyond the defaults, port 4070, the legacy
# access point. Add it with -x or by hand.
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=spotify
JUSER=acid
JUID=1001

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

say "1/4  install spotify-client"
if [ -x "$ROOT/usr/bin/spotify" ]; then
	skip
else
	bastille cmd "$JAIL" apt-get install -y --no-install-recommends ca-certificates curl gnupg
	bastille cmd "$JAIL" install -d /etc/apt/keyrings
	bastille cmd "$JAIL" sh -c \
	  'curl -fsSL https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc | gpg --dearmor -o /etc/apt/keyrings/spotify.gpg'
	[ -s "$ROOT/etc/apt/keyrings/spotify.gpg" ] || die "keyring came back empty"
	bastille cmd "$JAIL" sh -c \
	  'echo "deb [signed-by=/etc/apt/keyrings/spotify.gpg] https://repository.spotify.com stable non-free" > /etc/apt/sources.list.d/spotify.list'
	bastille cmd "$JAIL" apt-get update
	# apt exits nonzero on half-configured systemd packages even when
	# spotify-client itself lands, so check the binary, not the exit code
	bastille cmd "$JAIL" apt-get install -y spotify-client || true
	bastille cmd "$JAIL" dpkg --configure -a || true
	[ -x "$ROOT/usr/bin/spotify" ] || die "spotify-client did not install"
fi

# Pin-Priority -1 does not hold a package, it makes it uninstallable, and apt
# then falls back to the 2013-era spotify-client-0.9.17.
rm -f "$ROOT/etc/apt/preferences.d/spotify-pin"

say "2/4  install spicetify"
if [ -x "$ROOT/home/$JUSER/.spicetify/spicetify" ]; then
	skip
else
	# the installer prompts for Marketplace on /dev/tty, which a jexec has not
	bastille cmd "$JAIL" su - "$JUSER" -c \
	  'curl -fsSL https://raw.githubusercontent.com/spicetify/cli/main/install.sh | sh' || true
	[ -x "$ROOT/home/$JUSER/.spicetify/spicetify" ] || die "spicetify did not install"
fi

say "3/4  apply spicetify"
if [ -e "$ROOT/home/$JUSER/.config/spicetify/config-xpui.ini" ]; then
	skip
else
	# spicetify rewrites files under here, and spotify came from a package manager
	bastille cmd "$JAIL" chmod -R a+wr /usr/share/spotify
	# spotify writes prefs on first launch, spicetify refuses to run without it
	mkdir -p "$ROOT/home/$JUSER/.config/spotify"
	[ -e "$ROOT/home/$JUSER/.config/spotify/prefs" ] || \
		: > "$ROOT/home/$JUSER/.config/spotify/prefs"
	chown -R "$JUID:$JUID" "$ROOT/home/$JUSER/.config"

	if ! bastille cmd "$JAIL" su - "$JUSER" -c '$HOME/.spicetify/spicetify backup apply'; then
		# a backup that no longer matches the client cannot be repaired in place.
		# restore pristine files from the package, drop it, take a fresh one.
		echo "    stale backup, reinstalling the client and re-taking it"
		bastille cmd "$JAIL" apt-mark unhold spotify-client || true
		bastille cmd "$JAIL" apt-get install --reinstall -y spotify-client || true
		rm -rf "$ROOT/home/$JUSER/.config/spicetify/Backup" \
		       "$ROOT/home/$JUSER/.spicetify/Backup"
		bastille cmd "$JAIL" chmod -R a+wr /usr/share/spotify
		bastille cmd "$JAIL" su - "$JUSER" -c \
		  '$HOME/.spicetify/spicetify backup apply' || true
	fi
	[ -e "$ROOT/home/$JUSER/.config/spicetify/config-xpui.ini" ] \
		|| die "spicetify apply produced no config-xpui.ini"
fi

say "4/4  hold the client"
# without the hold an update overwrites the patched files and reverts the theme
bastille cmd "$JAIL" apt-mark hold spotify-client
bastille cmd "$JAIL" apt-mark showhold | grep -qx spotify-client \
	|| die "the hold did not take"
echo "    spotify-client held"

say "launcher"
install -o root -g wheel -m 0755 "$SRCDIR/spotify-jail" /usr/local/sbin/spotify-jail
printf '#!/bin/sh\nexec doas /usr/local/sbin/spotify-jail "$@"\n' > "/home/$JUSER/bin/spotify-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/spotify-jail"
chmod 0755 "/home/$JUSER/bin/spotify-jail"
echo "    /usr/local/sbin/spotify-jail and ~/bin/spotify-jail"

cat <<'DONE'

==> spotify installed.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/spotify-jail

A theme is a separate step, spicetify ships none selected:

    doas sh ~/.jails/spotify-theme.sh

Then launch with:  spotify-jail
DONE
