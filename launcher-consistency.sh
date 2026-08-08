#!/bin/sh
#
# Normalise the GUI jail launchers. Run once as root, safe to re-run.
#
#   doas sh ~/.jails/launcher-consistency.sh
#
# Four changes:
#   1. spotify-jail moves /usr/local/bin -> /usr/local/sbin, joining zen-jail
#      and zenburner-jail. vesktop-jail is already written for sbin.
#   2. spotify-jail gains --in-process-gpu, which the linbase note
#      prescribes for chromium under linuxulator.
#   3. desktop entries normalise to <app>-jail.desktop, and spotify gets one.
#   4. the inert ~/bin/zen-jail copy goes away.
#
# Does NOT touch /usr/local/etc/doas.conf. That edit is printed at the end and
# has to happen in the same sitting: while the launcher lives in sbin and the
# rule still names bin, `spotify-jail` is denied.

set -eu

JUSER=acid
JUID=1001
HOME_DIR=/home/$JUSER
APPS=$HOME_DIR/.local/share/applications
ICONS=$HOME_DIR/.local/share/icons/hicolor/scalable/apps
SRCDIR=$(cd "$(dirname "$0")" && pwd)

OLD=/usr/local/bin/spotify-jail
NEW=/usr/local/sbin/spotify-jail

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

# ------------------------------------------------------------ 1. spotify-jail
say "1/4  spotify-jail -> $NEW"
[ -f "$SRCDIR/spotify-jail" ] || die "missing $SRCDIR/spotify-jail"
grep -q -- '--in-process-gpu' "$SRCDIR/spotify-jail" || die "$SRCDIR/spotify-jail lacks --in-process-gpu"

install -o root -g wheel -m 0755 "$SRCDIR/spotify-jail" "$NEW"
echo "    installed $NEW"

if [ -e "$OLD" ]; then
	rm -f "$OLD"
	echo "    removed $OLD"
else
	echo "    $OLD already gone"
fi

# --------------------------------------------------------------- 2. wrapper
say "2/4  ~/bin wrappers"
printf '#!/bin/sh\nexec doas %s "$@"\n' "$NEW" > "$HOME_DIR/bin/spotify-jail"
chown "$JUID:$JUID" "$HOME_DIR/bin/spotify-jail"
chmod 0755 "$HOME_DIR/bin/spotify-jail"
echo "    ~/bin/spotify-jail -> $NEW"

# ~/bin/zen-jail is a copy of /usr/local/sbin/zen-jail. edits to it do nothing,
# the same trap as the ~/bin/niri-session copy.
if [ -e "$HOME_DIR/bin/zen-jail" ]; then
	if cmp -s "$HOME_DIR/bin/zen-jail" /usr/local/sbin/zen-jail; then
		rm -f "$HOME_DIR/bin/zen-jail"
		echo "    removed the inert ~/bin/zen-jail copy"
	else
		# it differs from the installed one, so it may hold unmerged edits
		mv "$HOME_DIR/bin/zen-jail" "$HOME_DIR/bin/zen-jail.differs-from-installed"
		echo "    ~/bin/zen-jail DIFFERS from the installed launcher"
		echo "    kept as ~/bin/zen-jail.differs-from-installed -- diff it, then delete"
	fi
else
	echo "    no ~/bin/zen-jail"
fi

# --------------------------------------------------------- 3. desktop entries
say "3/4  desktop entries"
mkdir -p "$APPS" "$ICONS"

# zenburner.desktop is the odd one out; every other entry is <app>-jail.desktop
if [ -e "$APPS/zenburner.desktop" ]; then
	mv "$APPS/zenburner.desktop" "$APPS/zenburner-jail.desktop"
	echo "    zenburner.desktop -> zenburner-jail.desktop"
else
	echo "    zenburner-jail.desktop already named correctly"
fi

if [ -e "$APPS/spotify-jail.desktop" ]; then
	echo "    spotify-jail.desktop exists"
else
	# doas is mandatory in Exec. without it clicking the entry does nothing,
	# silently, because the launcher needs root to jexec and mount_nullfs.
	cat > "$APPS/spotify-jail.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Spotify (jailed)
Comment=Music client, jailed
Exec=doas $NEW
Icon=spotify-client
Terminal=false
Categories=Audio;Music;Player;AudioVideo;
StartupWMClass=spotify
EOF
	echo "    wrote spotify-jail.desktop"
fi

# pull the icon out of the jail so the host menu can render it
SROOT=/usr/local/bastille/jails/spotify/root
PNGDIR=$HOME_DIR/.local/share/icons/hicolor/256x256/apps
if [ -e "$PNGDIR/spotify-client.png" ]; then
	echo "    icon present"
else
	_png=$(find "$SROOT/usr/share/spotify" -name 'spotify-linux-256.png' 2>/dev/null | head -1)
	if [ -n "$_png" ]; then
		mkdir -p "$PNGDIR"
		cp "$_png" "$PNGDIR/spotify-client.png"
		echo "    icon from the jail"
	else
		echo "    no spotify icon in the jail, the entry falls back to a generic one"
	fi
fi

chown -R "$JUID:$JUID" "$HOME_DIR/.local/share/applications" "$HOME_DIR/.local/share/icons"

# ------------------------------------------------------------------ 4. verify
say "4/4  verify"
for f in /usr/local/sbin/zen-jail /usr/local/sbin/zenburner-jail "$NEW"; do
	[ -x "$f" ] || die "missing $f"
	printf '    %s\n' "$f"
done
[ -e "$OLD" ] && die "$OLD still exists"
grep -q -- '--in-process-gpu' "$NEW" || die "$NEW lacks --in-process-gpu"
echo "    all launchers in /usr/local/sbin, --in-process-gpu present"

cat <<DONE

==> Now edit /usr/local/etc/doas.conf.

REPLACE the existing spotify line (do not just add a second one, or the stale
bin path lingers as a dead rule):

    -permit nopass acid as root cmd /usr/local/bin/spotify-jail
    +permit nopass acid as root cmd $NEW

Until that edit lands, \`spotify-jail\` is denied: the launcher has moved and the
rule still names the old path.

Check it with, which parses the config and executes nothing:

    doas -C /usr/local/etc/doas.conf $NEW

Then launch with:  spotify-jail

Note on invocation: the ~/bin wrappers already call doas themselves, so run
them directly. \`doas spotify-jail\` asks doas to run "spotify-jail", which no rule names,
and fails with "Operation not permitted". Do not add a rule for the wrapper to
make that work -- ~/bin/spotify-jail is writable by acid, so a rule running it as
root would be a privilege escalation. The wrapper stays unprivileged and the
rule keeps pointing at the root-owned -jail script.
DONE
