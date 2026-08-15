#!/bin/sh
#
# Install feather into the jail jail-new created, give that jail the camera
# devices the QR scanner needs, and install the launcher. Run as root, safe to
# re-run.
#
#   doas sh ~/.jails/feather-setup.sh
#
# Run jail-new first:
#   doas jail-new -n -x ~/.jails/feather.pf guibase feather 172.16.0.60 \
#        wallets=home/acid/.Monero config=home/acid/.config/feather
#
# The package comes from the local ports tree, net-p2p/feather. Build it with:
#   doas poudriere bulk -j 151amd64 -p local net-p2p/feather
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=feather
JUSER=acid
JUID=1001

PKGDIR=/usr/local/poudriere/data/packages/151amd64-local/All
PKGFILE=feather-2.9.1_1.pkg

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"

say "1/8  devfs ruleset 22"
# ruleset 20 is GPU only. the scanner wants a camera, and webcamd publishes that
# through cuse from the host, so video* and cuse are enough: ugen* and usb/*
# stay hidden and no hardware wallet is reachable from in here.
if grep -q "add path 'video\*' mode 0660 group video" /etc/devfs.rules; then
	skip
elif grep -q 'gui_cam_jail=22' /etc/devfs.rules; then
	die "ruleset 22 exists without the video group rule. Delete the [gui_cam_jail=22] block from /etc/devfs.rules and re-run this script."
else
	cat >> /etc/devfs.rules <<'EOF'

[gui_cam_jail=22]
# ruleset 20 plus the camera. every include spelled out: devfs does not expand
# nested includes, so naming only $devfsrules_jail would skip the hide-all
# baseline and hide nothing.
add include $devfsrules_hide_all
add include $devfsrules_unhide_basic
add include $devfsrules_unhide_login
add include $devfsrules_jail
add path 'dri' unhide
add path 'dri/*' unhide
add path 'drm' unhide
add path 'drm/*' unhide
add path 'video*' unhide
add path 'cuse' unhide
# webcamd owns the nodes as webcamd:webcamd 0660, and gid 145 means nothing in
# the jail. Regrouping here rather than adding that gid to the jail keeps the
# change inside the jail's own devfs: guibase already puts acid in video.
add path 'video*' mode 0660 group video
EOF
	service devfs restart >/dev/null
	echo "    added and devfs reloaded"
fi

say "2/8  assign ruleset to the jail"
# jail-new copies the baseline's ruleset, which is 20. The camera is specific to
# this jail, so the switch happens here rather than in guibase.
if [ "$(bastille config "$JAIL" get devfs_ruleset 2>/dev/null || echo)" = 22 ]; then
	skip
	jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"
else
	bastille config "$JAIL" set devfs_ruleset 22
	bastille stop "$JAIL" 2>/dev/null || true
	bastille start "$JAIL"
	echo "    devfs_ruleset 22"
fi

jexec "$JAIL" test -c /dev/video0 2>/dev/null \
	|| echo "    warning: no /dev/video0 in the jail -- is webcamd running on the host?"

say "3/8  install feather"
# version-aware, not just "is the binary there": a PORTREVISION bump has to
# reach the jail, and the first thing one of those fixed was a wallet path.
WANT=${PKGFILE%.pkg}
if [ "$(jexec "$JAIL" pkg query '%n-%v' feather 2>/dev/null || true)" = "$WANT" ]; then
	skip
else
	[ -f "$PKGDIR/$PKGFILE" ] || die "no package at $PKGDIR/$PKGFILE -- build it with: poudriere bulk -j 151amd64 -p local net-p2p/feather"
	install -m 0644 "$PKGDIR/$PKGFILE" "$ROOT/tmp/$PKGFILE"
	# pkg pulls the dependencies, tor among them, from the jail's own repo
	jexec "$JAIL" pkg install -y "/tmp/$PKGFILE"
	rm -f "$ROOT/tmp/$PKGFILE"
	jexec "$JAIL" test -x /usr/local/bin/feather 2>/dev/null || die "feather did not install"
fi

say "4/8  tor"
jexec "$JAIL" sysrc tor_enable=YES >/dev/null
jexec "$JAIL" service tor status >/dev/null 2>&1 || jexec "$JAIL" service tor start
i=0
while ! jexec "$JAIL" sockstat -4lq -p 9050 2>/dev/null | grep -q 9050; do
	i=$((i + 1))
	[ "$i" -lt 100 ] || die "tor did not start listening on 9050"
	sleep 0.1
done
echo "    tor listening on 127.0.0.1:9050"

say "5/8  state and wallet directory"
for p in .Monero .config/feather; do
	jexec "$JAIL" sh -c "df /home/$JUSER/$p" | grep -q jailstate \
		|| die "/home/$JUSER/$p is not on its jailstate dataset"
	echo "    /home/$JUSER/$p on jailstate"
done

# feather stores its wallet directory in settings.json and only falls back to
# the built-in default when that key is missing, so seeding the file once is
# enough: nothing ever looks at ~/Monero. The port patches the default too,
# which upstream leaves undefined on FreeBSD.
CFG=$ROOT/home/$JUSER/.config/feather/settings.json
if [ -f "$CFG" ]; then
	echo "    settings.json exists, left alone"
else
	# skin defaults to "light", which is not one of the names registered in
	# WindowManager::initSkins(), so it resolves to an empty stylesheet and the
	# app comes up in raw Qt Fusion. "Native" is the one that defers to the Qt
	# platform theme, which step 7 supplies as Kvantum/catppuccin-mocha-blue; any
	# other value paints feather's own stylesheet over it.
	printf '{\n    "walletDirectory": "/home/%s/.Monero",\n    "skin": "Native"\n}\n' "$JUSER" > "$CFG"
	echo "    walletDirectory -> /home/$JUSER/.Monero, skin -> Native"
fi

# an earlier version of this script left one behind
if [ -L "$ROOT/home/$JUSER/Monero" ]; then
	rm -f "$ROOT/home/$JUSER/Monero"
	echo "    removed the old ~/Monero symlink"
fi

# Not chown -R over the home directory: guibase mounts the theme paths under
# .local/share/themes read-only, chown fails on those, and under set -e that
# takes the whole script down. jail-new already owns the dataset mountpoints.
chown "$JUID:$JUID" "$ROOT/home/$JUSER" "$ROOT/home/$JUSER/.config" "$CFG"

say "6/8  launcher"
install -o root -g wheel -m 0755 "$SRCDIR/feather-jail" /usr/local/sbin/feather-jail
echo "    /usr/local/sbin/feather-jail"
printf '#!/bin/sh\nexec doas /usr/local/sbin/feather-jail "$@"\n' > "/home/$JUSER/bin/feather-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/feather-jail"
chmod 0755 "/home/$JUSER/bin/feather-jail"
echo "    /home/$JUSER/bin/feather-jail"

say "7/8  qt theme"
# The host stack is qt6ct -> Kvantum -> catppuccin-mocha-blue with
# Colloid-Catppuccin-Dark icons. The icons already arrive through guibase's
# THEME_PATHS mount; the two Qt config directories do not, so they get the same
# read-only nullfs treatment rather than a second copy to keep in sync.
if jexec "$JAIL" test -f /usr/local/lib/qt6/plugins/styles/libkvantum.so 2>/dev/null; then
	skip
else
	jexec "$JAIL" pkg install -y qt6ct Kvantum
	jexec "$JAIL" test -f /usr/local/lib/qt6/plugins/styles/libkvantum.so \
		|| die "Kvantum style plugin missing after install"
fi

for p in .config/qt6ct .config/Kvantum; do
	if grep -q " $ROOT/home/$JUSER/$p " "$PREFIX/jails/$JAIL/fstab" 2>/dev/null; then
		echo "    $p already mounted"
	else
		[ -d "/home/$JUSER/$p" ] || die "no /home/$JUSER/$p on the host to mount"
		bastille mount "$JAIL" "/home/$JUSER/$p" "/home/$JUSER/$p" nullfs ro 0 0
		echo "    mounted $p read-only"
	fi
done

say "8/8  desktop entry"
APPS=/home/$JUSER/.local/share/applications
PNGDIR=/home/$JUSER/.local/share/icons/hicolor/256x256/apps
mkdir -p "$APPS" "$PNGDIR"

# doas is mandatory in Exec: the launcher needs root for jexec and
# mount_nullfs, and without it clicking the entry does nothing, silently.
if [ -f "$APPS/feather-jail.desktop" ]; then
	echo "    feather-jail.desktop exists"
else
	cat > "$APPS/feather-jail.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Feather (jailed)
Comment=Monero wallet, jailed
Exec=doas /usr/local/sbin/feather-jail
Icon=feather
Terminal=false
Categories=Network;Finance;
StartupWMClass=feather
EOF
	echo "    wrote feather-jail.desktop"
fi

# the package installs its icons inside the jail, where the host menu cannot
# see them. StartupWMClass=feather matches what upstream's own .desktop sets.
ICON=$ROOT/usr/local/share/icons/hicolor/256x256/apps/feather.png
if [ -f "$PNGDIR/feather.png" ]; then
	echo "    icon present"
elif [ -f "$ICON" ]; then
	install -m 0644 "$ICON" "$PNGDIR/feather.png"
	echo "    icon copied out of the jail"
else
	echo "    warning: no icon at $ICON -- the menu entry will render blank"
fi
chown -R "$JUID:$JUID" "$APPS" "/home/$JUSER/.local/share/icons"

cat <<'DONE'

==> feather installed.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/feather-jail

Then start it from the host:  feather-jail

The jail has no clearnet route. Everything leaves through the tor beside it, so
a node that will not connect is expected until Settings -> Network shows the
proxy in use; clearnet node addresses still work, they just exit through tor.

Hardware wallets do not work in here and are not meant to: reaching a Trezor
needs ugen* and usb/*, which would expose every USB device on the machine.

Wallet keys live on zroot/jailstate/feather/wallets, mounted at ~/.Monero in
the jail and outside the jail root. Snapshot that dataset, not the jail.
DONE
