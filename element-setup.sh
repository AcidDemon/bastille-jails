#!/bin/sh
#
# Install Element Desktop into the jail jail-new created, and install the
# launcher. Run as root, safe to re-run.
#
#   doas sh ~/.jails/element-setup.sh
#
# Run jail-new first:
#   doas jail-new -x ~/.jails/element.pf linbase element 172.16.0.50 \
#        config=home/acid/.config/Element
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

JAIL=element
JUSER=acid
JUID=1001
KEYRING=/usr/share/keyrings/element-io-archive-keyring.gpg
KEYURL=https://packages.element.io/debian/element-io-archive-keyring.gpg
REPO="deb [signed-by=$KEYRING] https://packages.element.io/debian/ default main"

PREFIX=/usr/local/bastille
ROOT=$PREFIX/jails/$JAIL/root
CFG=$ROOT/home/$JUSER/.config/Element
SRCDIR=$(cd "$(dirname "$0")" && pwd)

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -d "$ROOT" ] || die "no $JAIL jail -- run jail-new first"
jls -j "$JAIL" jid >/dev/null 2>&1 || bastille start "$JAIL"

say "0/5  netlink patch is live"
_ko=/boot/kernel/linux_common.ko
objdump -d "$_ko" 2>/dev/null | grep -q '\$0x1000000,' \
	|| die "$_ko does not carry the IFF_NETLINK_1 patch"
_kom=$(stat -f %m "$_ko")
_boot=$(sysctl -n kern.boottime | sed -e 's/.*{ sec = //' -e 's/,.*//')
[ "$_kom" -le "$_boot" ] \
	|| die "$_ko was written after the boot, the running kernel is unpatched, reboot first"
echo "    patched module predates the boot"

say "1/5  install element-desktop"
if bastille cmd "$JAIL" test -x /usr/bin/element-desktop >/dev/null 2>&1; then
	skip
else
	bastille cmd "$JAIL" apt-get install -y --no-install-recommends ca-certificates curl
	bastille cmd "$JAIL" sh -c "curl -fsSL '$KEYURL' -o '$KEYRING'" \
		|| die "could not fetch the element.io keyring from $KEYURL"
	[ -s "$ROOT$KEYRING" ] || die "keyring came back empty, check $KEYURL"
	bastille cmd "$JAIL" sh -c "echo '$REPO' > /etc/apt/sources.list.d/element-io.list"
	bastille cmd "$JAIL" apt-get update
	bastille cmd "$JAIL" apt-get install -y element-desktop || true
	bastille cmd "$JAIL" test -x /usr/bin/element-desktop >/dev/null 2>&1 \
		|| die "element-desktop did not install; check the repo suite in $REPO"
fi

say "1b/5 package state"
# dpkg --audit exits 0 whether or not it found anything, so judge the output
_audit=$(bastille cmd "$JAIL" dpkg --audit)
if [ -n "$_audit" ]; then
	printf '%s\n' "$_audit"
	die "packages are half-configured in $JAIL"
fi
echo "    dpkg audit clean"

say "2/5  profile on its own dataset"
jexec "$JAIL" sh -c 'df /home/acid/.config/Element' | grep -q jailstate \
	|| die "/home/$JUSER/.config/Element is not on its jailstate dataset"
mkdir -p "$CFG"
chown -R "$JUID:$JUID" "$ROOT/home/$JUSER/.config"
echo "    ok"

say "3/5  launcher"
install -o root -g wheel -m 0755 "$SRCDIR/element-jail" /usr/local/sbin/element-jail
echo "    /usr/local/sbin/element-jail"

say "4/5  desktop entry and icon"
APPS=/home/$JUSER/.local/share/applications
ICONS=/home/$JUSER/.local/share/icons/hicolor/512x512/apps
mkdir -p "$APPS" "$ICONS"

_png=$(find "$ROOT/opt/Element" "$ROOT/usr/share/icons" -name 'element*.png' 2>/dev/null | head -1)
if [ -n "$_png" ] && [ ! -e "$ICONS/element.png" ]; then
	cp "$_png" "$ICONS/element.png"
	echo "    icon from the jail"
fi

# doas is mandatory in Exec. without it clicking the entry does nothing,
# silently, because the launcher needs root to jexec and mount_nullfs.
cat > "$APPS/element-jail.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Element (jailed)
Comment=Matrix client, jailed
Exec=doas /usr/local/sbin/element-jail
Icon=element
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=Element
EOF
chown -R "$JUID:$JUID" "$APPS" "/home/$JUSER/.local/share/icons"
echo "    $APPS/element-jail.desktop"

say "5/5  ~/bin wrapper"
printf '#!/bin/sh\nexec doas /usr/local/sbin/element-jail "$@"\n' > "/home/$JUSER/bin/element-jail"
chown "$JUID:$JUID" "/home/$JUSER/bin/element-jail"
chmod 0755 "/home/$JUSER/bin/element-jail"
echo "    /home/$JUSER/bin/element-jail"

cat <<'DONE'

==> Element installed.

Add this line to /usr/local/etc/doas.conf:

    permit nopass acid as root cmd /usr/local/sbin/element-jail

Then launch with:  element-jail

Two things worth knowing:

  Screen sharing will not work. It needs xdg-desktop-portal and PipeWire
  reachable from the jail, which is the surface this design refuses. Voice and
  receiving video are unaffected.

  The end-to-end encryption keys live in the profile on
  zroot/jailstate/element/config. Destroying that dataset means re-verifying
  the session from another device, so set up key backup in Element once you
  are logged in.
DONE
