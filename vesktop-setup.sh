#!/bin/sh
#
# Install vesktop into the jail jail-new created, migrate the Vencord config
# out of the NixOS export, and install the launcher.
#
#   doas sh ~/.jails/vesktop-setup.sh
#
# Run jail-new first:
#   doas jail-new -x ~/.jails/vesktop.pf linbase vesktop 172.16.0.40 \
#        config=home/acid/.config/vesktop
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=vesktop
JUSER=acid
JUID=1001
DEB=/usr/ports/distfiles/vesktop_1.6.5_amd64.deb
ZIP=/home/acid/vesktop.zip

# Explicit, not whatever PATH resolves. /etc/login.conf puts /usr/bin ahead of
# /usr/local/bin, and /usr/bin/unzip is bsdunzip from libarchive, which chokes
# on this archive's zip64 fields with "Malformed 64-bit uncompressed size" and
# returns nothing. Info-ZIP from archivers/unzip reads it correctly.
UNZIP_BIN=/usr/local/bin/unzip

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root
CFG=$ROOT/home/$JUSER/.config/vesktop
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

# The linuxulator netlink patch has to be in the RUNNING kernel, not just in
# /boot/kernel. Without it rtnl_if_flags_to_linux() drops IFF_NETLINK_1 and no
# Linux binary ever sees IFF_LOWER_UP, so chromium's address_tracker_linux.cc
# resolves CONNECTION_NONE and vesktop renders that as "no internet".
#
# Do NOT probe /compat/linux/sys/class/net/*/flags for this. linsysfs builds
# that file from linux_ifflags() -> bsd_to_linux_ifflags() in linux.c, which
# returns unsigned short and so structurally cannot carry LOWER_UP (1 << 16),
# and has no case for it either. It reads 0x1043 on a patched kernel too. Only
# the netlink path was patched, and netlink is what chromium reads.
#
# So: confirm the installed module carries the patch, and that it predates the
# boot, which means the loaded copy is that one.
say "0/5  netlink patch is live"
_ko=/boot/kernel/linux_common.ko
objdump -d "$_ko" 2>/dev/null | grep -q '\$0x1000000,' \
	|| die "$_ko does not carry the IFF_NETLINK_1 patch -- rebuild sys/modules/linux_common"
_kom=$(stat -f %m "$_ko")
_boot=$(sysctl -n kern.boottime | sed -e 's/.*{ sec = //' -e 's/,.*//')
if [ "$_kom" -gt "$_boot" ]; then
	die "$_ko was written $(date -r "$_kom" '+%F %T'), after the boot at $(date -r "$_boot" '+%F %T') -- the running kernel still has the old translation, reboot first"
fi
echo "    patched module predates the boot, loaded copy is patched"

# ------------------------------------------------------------------ 1. install
# update-alternatives makes /usr/bin/vesktop a symlink to
# /etc/alternatives/vesktop, an absolute path that only resolves inside the
# jail. A host-side [ -x "$ROOT/usr/bin/vesktop" ] follows it to the host's own
# /etc/alternatives, finds nothing, and reports a successful install as failed.
have_vesktop() {
	bastille cmd "$JAIL" test -x /usr/bin/vesktop >/dev/null 2>&1
}

say "1/5  install vesktop"
if have_vesktop; then
	skip
else
	[ -f "$DEB" ] || die "missing $DEB"
	# no apt-get and no network needed: the baseline already carries the whole
	# Electron runtime, and trixie's t64 packages Provides: the old names the
	# .deb asks for.
	cp "$DEB" "$ROOT/root/"
	bastille cmd "$JAIL" dpkg -i "/root/$(basename "$DEB")" || true
	rm -f "$ROOT/root/$(basename "$DEB")"
	have_vesktop || die "vesktop did not install"
fi

say "1b/5 package state"
# the postinst runs `unshare --user true`, which fails under linuxulator, so it
# takes the chmod 4755 chrome-sandbox branch instead. irrelevant: the launcher
# passes --no-sandbox.
# dpkg --audit exits 0 whether or not it found anything, so judge the output
_audit=$(bastille cmd "$JAIL" dpkg --audit)
if [ -n "$_audit" ]; then
	printf '%s\n' "$_audit"
	die "packages are half-configured in $JAIL"
fi
echo "    dpkg audit clean"

# ------------------------------------------------------------------- 2. config
say "2/5  Vencord config"
mkdir -p "$CFG/settings"

if [ -s "$CFG/settings/settings.json" ]; then
	skip
else
	[ -f "$ZIP" ] || die "missing $ZIP"
	[ -x "$UNZIP_BIN" ] || die "need $UNZIP_BIN (pkg install unzip); the base bsdunzip cannot read this archive"
	# 8.1K of the archive's 103M is worth moving: 179 plugin entries and the
	# Catppuccin Mocha themeLink, which is fetched at runtime and so depends on
	# the HTTPS egress rule.
	"$UNZIP_BIN" -p "$ZIP" vesktop/settings/settings.json > "$CFG/settings/settings.json"
	# bsdunzip writes its error to stderr and nothing to stdout, so a silent
	# truncation shows up here as an empty or absurdly small file
	[ -s "$CFG/settings/settings.json" ] || die "extracted an empty settings.json"
	[ "$(head -c1 "$CFG/settings/settings.json")" = '{' ] \
		|| die "settings.json does not start with '{' -- extraction produced garbage"
	echo "    settings/settings.json ($(wc -c < "$CFG/settings/settings.json" | tr -d ' ') bytes)"
fi

# written fresh rather than extracted. arRPC binds 127.0.0.1:6463 inside the
# jail and nothing else lives there to talk to it. hardwareVideoAcceleration
# wants VAAPI through linuxulator alongside --in-process-gpu, which is not a
# working combination -- flip it back later if that changes.
if [ -s "$CFG/settings.json" ]; then
	echo "    settings.json exists, leaving it"
else
	cat > "$CFG/settings.json" <<'EOF'
{
  "discordBranch": "stable",
  "minimizeToTray": true,
  "arRPC": false,
  "splashColor": "rgb(205, 214, 244)",
  "splashBackground": "rgb(17, 17, 27)",
  "hardwareVideoAcceleration": false,
  "enableSplashScreen": false
}
EOF
	echo "    settings.json"
fi

# state.json is deliberately not carried: its windowBounds are 5100px wide from
# a multi-monitor NixOS box and the window would open off-screen.

# Vesktop fetches the Vencord bundle from api.github.com on first run. That API
# gives 60 requests/hour per IP unauthenticated, shared by everything behind
# this NAT, and the failure path is an unhandled rejection inside a Promise.all:
# a 403 hangs the first-run dialog after Save rather than degrading. The archive
# already carries a built copy, so ship it and drop the dependency.
VF=$CFG/sessionData/vencordFiles
if [ -s "$VF/vencordDesktopRenderer.js" ]; then
	echo "    vencordFiles present"
else
	[ -f "$ZIP" ] || die "missing $ZIP"
	[ -x "$UNZIP_BIN" ] || die "need $UNZIP_BIN (pkg install unzip)"
	# archive paths start with vesktop/, so extracting into .config lands them
	# at .config/vesktop/sessionData/vencordFiles/
	"$UNZIP_BIN" -o -q -d "$(dirname "$CFG")" "$ZIP" 'vesktop/sessionData/vencordFiles/*'
	[ -s "$VF/vencordDesktopRenderer.js" ] || die "vencordFiles did not extract to $VF"
	echo "    vencordFiles ($(ls -1 "$VF" | wc -l | tr -d ' ') files)"
fi

chown -R "$JUID:$JUID" "$ROOT/home/$JUSER/.config"

# ----------------------------------------------------------------- 3. launcher
say "3/5  launcher"
install -o root -g wheel -m 0755 "$SRCDIR/vesktop-jail" /usr/local/sbin/vesktop-jail
echo "    /usr/local/sbin/vesktop-jail"

# ------------------------------------------------------------- 4. desktop entry
say "4/5  desktop entry and icon"
APPS=/home/$JUSER/.local/share/applications
ICONS=/home/$JUSER/.local/share/icons/hicolor/scalable/apps
mkdir -p "$APPS" "$ICONS"

_svg=$ROOT/usr/share/icons/hicolor/scalable/apps/vesktop.svg
[ -f "$_svg" ] || _svg=$(find "$ROOT/opt/Vesktop" -name 'vesktop.svg' 2>/dev/null | head -1)
if [ -n "$_svg" ] && [ -f "$_svg" ]; then
	cp "$_svg" "$ICONS/vesktop.svg"
	echo "    icon"
fi

# doas is mandatory here. without it clicking the entry does nothing, silently.
cat > "$APPS/vesktop-jail.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Vesktop
Comment=Discord client, jailed
Exec=doas /usr/local/sbin/vesktop-jail
Icon=vesktop
Terminal=false
Categories=Network;InstantMessaging;
StartupWMClass=Vesktop
EOF
chown -R "$JUID:$JUID" "/home/$JUSER/.local/share/applications" "/home/$JUSER/.local/share/icons"
echo "    $APPS/vesktop-jail.desktop"

# ------------------------------------------------------------------ 5. wrapper
say "5/5  ~/bin wrapper"
printf '#!/bin/sh\nexec doas /usr/local/sbin/vesktop-jail "$@"\n' > "/home/$JUSER/bin/vesktop"
chown "$JUID:$JUID" "/home/$JUSER/bin/vesktop"
chmod 0755 "/home/$JUSER/bin/vesktop"
echo "    /home/$JUSER/bin/vesktop"

cat <<'DONE'

==> vesktop installed.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/vesktop-jail

Then launch with:  vesktop

Two things worth knowing:

  Screen sharing will not work. It needs xdg-desktop-portal and PipeWire
  reachable from the jail, which is the surface this design refuses. Voice and
  receiving video are unaffected.

  ~/vesktop.zip holds a plaintext cookie database. Deleting it revokes nothing
  -- and rm -P is meaningless on ZFS anyway. Once logged in, use Discord
  settings, Devices, log out of all known devices. Then rm the zip.
DONE
