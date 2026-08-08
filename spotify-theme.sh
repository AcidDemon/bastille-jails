#!/bin/sh
#
# Give the jailed Spotify a theme. Run as root, safe to re-run.
#
#   doas sh ~/.jails/spotify-theme.sh
#
# spotify-jail-setup.sh installed the spicetify CLI and ran `backup apply`, but
# never selected a theme, so the client renders stock.

set -eu

JAIL=spotify
JUSER=acid
THEME=catppuccin
SCHEME=mocha

SPICE=/home/$JUSER/.spicetify/spicetify
TDIR=/home/$JUSER/.config/spicetify/Themes/$THEME
RAW=https://raw.githubusercontent.com/catppuccin/spicetify/main/catppuccin

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root

say() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# spicetify writes under $HOME and refuses to run as root
injail() { jexec -l -u "$JUSER" "$JAIL" "$@"; }

[ "$(id -u)" = 0 ] || die "must run as root"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"
[ -x "$ROOT$SPICE" ] || die "no spicetify in $JAIL, rerun ~/bin/spotify-jail-setup.sh"

say "1/3  fetch $THEME"
if [ -s "$ROOT$TDIR/user.css" ]; then
	echo "    already present"
else
	injail mkdir -p "$TDIR"
	for f in color.ini user.css theme.js; do
		injail curl -fsSL -o "$TDIR/$f" "$RAW/$f" || die "could not fetch $f"
		[ -s "$ROOT$TDIR/$f" ] || die "$f came back empty"
		echo "    $f ($(wc -c < "$ROOT$TDIR/$f" | tr -d ' ') bytes)"
	done
fi

say "2/3  select it"
injail "$SPICE" config current_theme "$THEME" color_scheme "$SCHEME"
grep -E '^\s*(current_theme|color_scheme)' "$ROOT/home/$JUSER/.config/spicetify/config-xpui.ini" | sed 's/^/    /'

say "3/3  apply"
injail "$SPICE" apply

_cur=$(grep -E '^\s*current_theme' "$ROOT/home/$JUSER/.config/spicetify/config-xpui.ini" | sed 's/.*=[[:space:]]*//')
[ "$_cur" = "$THEME" ] || die "current_theme is '$_cur', expected '$THEME'"

cat <<DONE

==> $THEME/$SCHEME applied.

Restart the client to see it:  spotify-jail

Other schemes in the same theme: latte, frappe, macchiato, mocha.

    doas jexec -l -u $JUSER $JAIL $SPICE config color_scheme latte
    doas jexec -l -u $JUSER $JAIL $SPICE apply

If a Spotify update ever reverts the patch, spotify-client is held by apt, so
check that first:  doas jexec $JAIL apt-mark showhold
DONE
