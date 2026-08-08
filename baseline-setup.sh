#!/bin/sh
#
# Build the golden GUI baseline jails. Run once as root, safe to re-run: every
# phase skips work already done.
#
#   doas sh ~/.jails/baseline-setup.sh [linux|freebsd|all]
#
# Produces two jails that never run an application:
#
#   linbase   Debian 13 trixie under linuxulator, 172.16.0.11, devfs 21
#   guibase   FreeBSD 15.1-RELEASE thin, 172.16.0.10, devfs 20
#
# Both end stopped, boot=off, with a @golden snapshot. jail-new clones them.
#
# Does NOT touch /usr/local/etc/doas.conf.

set -eu

WHICH=${1:-all}

GW=172.16.0.1
BRIDGE=jailnatbridge
JUSER=acid
JUID=1001

LIN_JAIL=linbase
LIN_IP=172.16.0.11
LIN_REL=Debian13
LIN_SUITE=debian_trixie

BSD_JAIL=guibase
BSD_IP=172.16.0.10
BSD_REL=15.1-RELEASE

TUI_JAIL=tuibase
TUI_IP=172.16.1.10
TUI_BRIDGE=jailprivbridge

PREFIX=/usr/local/bastille
TEMPLATES=$PREFIX/templates/local
SRCDIR=$(cd "$(dirname "$0")" && pwd)

# host paths mounted read-only into every GUI jail at the same path. one source
# of truth, and ~/.local/share/icons alone is 592M so copies are out.
THEME_PATHS=".local/share/themes .local/share/icons .config/gtk-3.0 .config/gtk-4.0"

say()  { printf '\n==> %s\n' "$1"; }
skip() { printf '    (already done, skipping)\n'; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

# ---------------------------------------------------------------- templates
# installed first: both baselines apply them, and a stale copy under
# $TEMPLATES would silently build the wrong thing.
say "templates -> $TEMPLATES"
for t in guibase linbase tuibase; do
	[ -f "$SRCDIR/templates/local/$t/Bastillefile" ] || die "missing $SRCDIR/templates/local/$t/Bastillefile"
	mkdir -p "$TEMPLATES/$t"
	cp "$SRCDIR/templates/local/$t/"* "$TEMPLATES/$t/"
	chmod 0644 "$TEMPLATES/$t/"*
	echo "    $t"
done
# CP lands this on /usr/bin inside the jail, but bastille cp preserves nothing,
# so the template chmods it there. 0644 here is fine.

# ------------------------------------------------------------- jail-new
# installed here rather than by hand: the closing message tells the user to run
# `doas jail-new`, which only works if it is on root's PATH.
say "jail-new -> /usr/local/sbin"
[ -f "$SRCDIR/jail-new" ] || die "missing $SRCDIR/jail-new"
install -o root -g wheel -m 0755 "$SRCDIR/jail-new" /usr/local/sbin/jail-new
echo "    /usr/local/sbin/jail-new"

# ---------------------------------------------------------------- pf
# egress is default-deny per jail. without this the baselines cannot reach a
# package mirror, and every later phase fails in a confusing way.
say "pf rules for the baselines"
if grep -q 'j_base' /etc/pf.conf; then
	skip
else
	awk '
	/^# untrusted tier/ {
		print "# Golden baselines. Up only while being built or updated, and never"
		print "# both at once, so one rule covers them."
		print "j_base     = \"{ 172.16.0.10, 172.16.0.11 }\""
		print ""
		print
		next
	}
	/^# Anything else from a jail dies here/ {
		print "# Golden baselines: pkg(8) and apt only"
		print "pass in quick on $jail_if proto tcp from $j_base to any port { 80, 443 } keep state"
		print ""
		print
		next
	}
	{ print }
	' /etc/pf.conf > /tmp/pf.conf.base

	grep -q 'j_base' /tmp/pf.conf.base || die "pf.conf anchors not found, refusing to edit"

	pfctl -n -f /tmp/pf.conf.base
	cp /etc/pf.conf /etc/pf.conf.bak-base
	mv /tmp/pf.conf.base /etc/pf.conf
	pfctl -f /etc/pf.conf
	echo "    backup at /etc/pf.conf.bak-base"
fi

say "pf rules for the untrusted-tier baseline"
if grep -q 'j_base_priv' /etc/pf.conf; then
	skip
else
	awk '
	/^# untrusted tier/ {
		print "j_base_priv = \"172.16.1.10\""
		print ""
		print
		next
	}
	index($0, "block in log quick on $priv_if from $priv_net to any") == 1 {
		print "# tuibase: pkg(8) only"
		print "pass in quick on $priv_if proto tcp from $j_base_priv to any port { 80, 443 } keep state"
		print ""
		print
		next
	}
	{ print }
	' /etc/pf.conf > /tmp/pf.conf.basepriv

	grep -q 'j_base_priv' /tmp/pf.conf.basepriv || die "pf.conf anchors not found, refusing to edit"

	pfctl -n -f /tmp/pf.conf.basepriv
	cp /etc/pf.conf /etc/pf.conf.bak-basepriv
	mv /tmp/pf.conf.basepriv /etc/pf.conf
	pfctl -f /etc/pf.conf
	echo "    backup at /etc/pf.conf.bak-basepriv"
fi

# --------------------------------------------------------------- assertions
# every check is behavioural or run as root: see_other_uids=0 makes ps,
# sockstat and procstat lie to a non-root caller on this host.
check_devfs() {
	_jail=$1
	_want_dri=$2
	_want_shm=$3

	_n=$(jexec "$_jail" sh -c 'ls /dev | wc -l' | tr -d ' ')
	[ "$_n" -lt 40 ] || die "$_jail: /dev has $_n entries, ruleset is not applied"
	echo "    /dev entries: $_n"

	if jexec "$_jail" sh -c 'dd if=/dev/mem bs=1 count=1 of=/dev/null' 2>/dev/null; then
		die "$_jail: /dev/mem is readable, ruleset is not applied"
	fi
	echo "    /dev/mem blocked"

	if [ "$_want_dri" = yes ]; then
		jexec "$_jail" ls -d /dev/dri/renderD128 >/dev/null 2>&1 || die "$_jail: no /dev/dri/renderD128"
		echo "    /dev/dri present"
	else
		if jexec "$_jail" ls -d /dev/dri >/dev/null 2>&1; then
			die "$_jail: /dev/dri exists under a ruleset that should not unhide it"
		fi
		echo "    /dev/dri absent"
	fi

	if [ "$_want_shm" = yes ]; then
		jexec "$_jail" ls -d /dev/shm >/dev/null 2>&1 || die "$_jail: no /dev/shm"
		echo "    /dev/shm present"
	fi
}

# Do not name the interface. A FreeBSD jail runs /etc/rc, which renames
# e0b_<jail> to vnet0 from its own rc.conf; a Debian jail has no rc and keeps
# e0b_<jail>. Matching on the address instead works for both.
check_ip() {
	_jail=$1
	_ip=$2
	if ifconfig -j "$_jail" -a 2>/dev/null | grep -qw "inet $_ip"; then
		echo "    $_jail is up on $_ip"
	else
		echo "    interfaces in $_jail:" >&2
		ifconfig -j "$_jail" -a 2>&1 | sed 's/^/      /' >&2
		die "$_jail has no interface carrying $_ip"
	fi
}

mount_themes() {
	_jail=$1
	for p in $THEME_PATHS; do
		if grep -q " $PREFIX/jails/$_jail/root/home/$JUSER/$p " "$PREFIX/jails/$_jail/fstab" 2>/dev/null; then
			continue
		fi
		bastille mount "$_jail" "/home/$JUSER/$p" "/home/$JUSER/$p" nullfs ro 0 0
	done
}

# a baseline must carry no jailstate mount. update_fstab() in common.sh rewrites
# only the destination path of an fstab line, never the source, so every clone
# would silently share the baseline's dataset.
assert_no_jailstate() {
	! grep -q 'jailstate' "$PREFIX/jails/$1/fstab" || die "$1: fstab has a jailstate mount, clones would share it"
}

freeze() {
	_jail=$1
	say "freeze $_jail"
	assert_no_jailstate "$_jail"
	bastille stop "$_jail" 2>/dev/null || true
	bastille config "$_jail" set boot off
	# @golden has to track the current baseline: keeping a stale one means a
	# rollback would silently revert whatever this run just fixed. One level of
	# undo is kept as @golden-prev. Snapshots cost nothing here.
	if zfs list -t snapshot -H -o name "zroot/bastille/jails/$_jail@golden" >/dev/null 2>&1; then
		zfs destroy -r "zroot/bastille/jails/$_jail@golden-prev" 2>/dev/null || true
		# -r renames the snapshot on the dataset and every descendant, so both
		# jails/<name>@golden and jails/<name>/root@golden move together. The
		# target is a bare @name, which is the documented form.
		zfs rename -r "zroot/bastille/jails/$_jail@golden" @golden-prev
		echo "    previous @golden kept as @golden-prev"
	fi
	zfs snapshot -r "zroot/bastille/jails/$_jail@golden"
	echo "    snapshot zroot/bastille/jails/$_jail@golden"
}

# ============================================================ Debian baseline
build_linbase() {
	JAILDIR=$PREFIX/jails/$LIN_JAIL
	ROOT=$JAILDIR/root
	RELDIR=$PREFIX/releases/$LIN_REL

	say "1/9  linuxulator prerequisites"
	bastille setup -y linux
	# bastille wraps the debootstrap install in the same test as the kmod load,
	# so it installs nothing once the modules are up
	pkg info -e debootstrap || pkg install -y debootstrap

	say "2/9  bootstrap $LIN_REL"
	if [ -d "$RELDIR" ]; then skip; else bastille bootstrap "$LIN_SUITE"; fi

	say "3/9  create $LIN_JAIL"
	if [ -d "$ROOT/usr/bin" ] || [ -d "$ROOT/debootstrap" ]; then
		skip
	else
		# -L cannot be combined with -B (create.sh:919), so the bridge goes in
		# as the plain INTERFACE argument. this config is thrown away below, it
		# only has to get creation past validation.
		bastille create --no-boot -L "$LIN_JAIL" "$LIN_REL" "$LIN_IP" "$BRIDGE"
		bastille stop "$LIN_JAIL" 2>/dev/null || true
		# drop the alias the interim config left behind
		ifconfig "$BRIDGE" -alias "$LIN_IP" 2>/dev/null || true
	fi

	say "4/9  write jail.conf"
	if grep -q 'lo0 inet 127' "$JAILDIR/jail.conf" 2>/dev/null; then
		skip
	else
		[ -f "$JAILDIR/jail.conf" ] && cp "$JAILDIR/jail.conf" "$JAILDIR/jail.conf.bastille-orig"
		# bastille has no combined linux+vnet path. securelevel, osrelease,
		# exec.clean and exec.start='/bin/sh /etc/rc' from the VNET template are
		# all fatal in a Debian jail and are deliberately absent.
		cat > "$JAILDIR/jail.conf" <<EOF
$LIN_JAIL {
  host.hostname = $LIN_JAIL;
  path = $ROOT;
  mount.fstab = $JAILDIR/fstab;
  exec.consolelog = /var/log/bastille/${LIN_JAIL}_console.log;

  devfs_ruleset = 21;
  enforce_statfs = 1;
  allow.mount;
  allow.mount.devfs;
  allow.sysvipc;

  exec.start = '/bin/true';
  exec.stop = '/bin/true';
  persist;

  vnet;
  vnet.interface = e0b_$LIN_JAIL;
  exec.prestart += "epair0=\\\$(ifconfig epair create) && ifconfig \\\${epair0} up name e0a_$LIN_JAIL && ifconfig \\\${epair0%a}b up name e0b_$LIN_JAIL";
  exec.prestart += "ifconfig $BRIDGE addm e0a_$LIN_JAIL";
  exec.prestart += "ifconfig e0a_$LIN_JAIL description \\"vnet0 host interface for Bastille jail $LIN_JAIL\\"";
  exec.poststart += "ifconfig -j $LIN_JAIL lo0 inet 127.0.0.1/8 up";
  exec.poststart += "ifconfig -j $LIN_JAIL e0b_$LIN_JAIL inet $LIN_IP/24 up";
  exec.poststart += "route -j $LIN_JAIL add default $GW";
  exec.poststop  += "ifconfig e0a_$LIN_JAIL destroy";
}
EOF
	fi

	say "4b/9 fstab repairs"
	F=$JAILDIR/fstab
	# a devfs line with no ruleset= gets no ruleset at all, which makes the
	# devfs_ruleset jail parameter inert. this cost five days once already.
	if grep -q "ruleset=21" "$F"; then
		echo "    ruleset already set"
	else
		sed -i '' -E "s#^(devfs[[:space:]]+${ROOT}/dev[[:space:]]+devfs[[:space:]]+)rw([[:space:]])#\1rw,ruleset=21\2#" "$F"
		grep -q "ruleset=21" "$F" || die "failed to set devfs ruleset in $F"
		echo "    devfs ruleset=21"
	fi
	# create.sh:420 writes this for every -L jail regardless of template. it
	# hands the jail the host /tmp, session dbus socket and keyring included.
	if grep -q "^/tmp[[:space:]]" "$F"; then
		grep -v "^/tmp[[:space:]]" "$F" > "$F.new" || true
		mv "$F.new" "$F"
		echo "    dropped the host /tmp nullfs line"
	else
		echo "    no host /tmp line"
	fi

	say "4c/9 resolver"
	# the host's own resolv.conf is the Tailscale one and pf blocks it from the
	# jail net
	printf 'nameserver %s\n' "$GW" > "$ROOT/etc/resolv.conf"

	say "5/9  start and check the network"
	bastille stop "$LIN_JAIL" 2>/dev/null || true
	bastille start "$LIN_JAIL"
	check_ip "$LIN_JAIL" "$LIN_IP"

	say "6/9  debootstrap second stage"
	# bastille runs debootstrap --foreign and nothing ever finishes the job
	if [ -x "$ROOT/usr/bin/apt-get" ]; then
		skip
	elif [ -f "$ROOT/debootstrap/debootstrap" ]; then
		bastille cmd "$LIN_JAIL" /debootstrap/debootstrap --second-stage || true
		[ -x "$ROOT/usr/bin/apt-get" ] || die "second stage did not produce apt-get"
	else
		die "no apt-get and no debootstrap second stage to run"
	fi

	say "7/9  apply local/linbase"
	# prints "Jail IP not found" for VNET jails: template.sh runs jexec ifconfig
	# and a Debian root has none. error_notify, not fatal.
	bastille template "$LIN_JAIL" local/linbase --arg UID="$JUID" --arg USER="$JUSER"

	say "8/9  theme passthrough"
	mount_themes "$LIN_JAIL"
	bastille restart "$LIN_JAIL"

	say "9/9  gates"
	check_devfs "$LIN_JAIL" yes yes
	# dpkg --audit exits 0 whether or not it found anything, so judge the output
	_audit=$(jexec "$LIN_JAIL" dpkg --audit)
	if [ -n "$_audit" ]; then
		printf '%s\n' "$_audit"
		die "packages are half-configured in $LIN_JAIL"
	fi
	echo "    dpkg audit clean"
	jexec "$LIN_JAIL" getent passwd "$JUSER" >/dev/null || die "$JUSER missing in $LIN_JAIL"
	echo "    $JUSER resolves"
	jexec "$LIN_JAIL" getent passwd messagebus >/dev/null || die "sysusers-sh did not run"
	echo "    messagebus resolves (sysusers-sh works)"
	jexec "$LIN_JAIL" sh -c "ls /home/$JUSER/.local/share/themes >/dev/null" || die "theme mount not live"
	echo "    theme mount live"

	freeze "$LIN_JAIL"
}

# =========================================================== FreeBSD baseline
build_guibase() {
	JAILDIR=$PREFIX/jails/$BSD_JAIL

	say "1/5  create $BSD_JAIL"
	# jail.conf is the marker bastille's own rc.d uses to decide a jail exists
	if [ -f "$JAILDIR/jail.conf" ]; then
		skip
	else
		# thin, the -B default. a thin jail's .bastille nullfs source lives under
		# releasesdir, a different prefix from the one update_fstab rewrites, so
		# clones keep working and cost only their own pkg payload.
		bastille create --no-boot -B "$BSD_JAIL" "$BSD_REL" "$BSD_IP" "$BRIDGE"
	fi

	say "2/5  start"
	# bastille create leaves the jail running, and `bastille start` on a
	# running jail is an error. do not swallow it with || true, that hid the
	# real failure here once already.
	jls -j "$BSD_JAIL" jid >/dev/null 2>&1 || bastille start "$BSD_JAIL"
	check_ip "$BSD_JAIL" "$BSD_IP"

	say "3/5  apply local/guibase"
	bastille template "$BSD_JAIL" local/guibase --arg UID="$JUID" --arg USER="$JUSER"

	say "4/5  devfs ruleset and theme passthrough"
	bastille config "$BSD_JAIL" set devfs_ruleset 20
	mount_themes "$BSD_JAIL"
	bastille restart "$BSD_JAIL"

	say "5/5  gates"
	# ruleset 20 has no shm unhide, and a native jail does not need one
	check_devfs "$BSD_JAIL" yes no
	jexec "$BSD_JAIL" id "$JUSER" >/dev/null || die "$JUSER missing in $BSD_JAIL"
	echo "    $JUSER resolves"
	jexec "$BSD_JAIL" sh -c 'fc-list | wc -l' | grep -qv '^0$' || die "no fonts in $BSD_JAIL"
	echo "    fonts present"
	jexec "$BSD_JAIL" sh -c "ls /home/$JUSER/.local/share/themes >/dev/null" || die "theme mount not live"
	echo "    theme mount live"

	freeze "$BSD_JAIL"
}

# ============================================================== TUI baseline
build_tuibase() {
	JAILDIR=$PREFIX/jails/$TUI_JAIL

	say "1/5  create $TUI_JAIL"
	if [ -f "$JAILDIR/jail.conf" ]; then
		skip
	else
		bastille create --no-boot -B "$TUI_JAIL" "$BSD_REL" "$TUI_IP" "$TUI_BRIDGE"
	fi

	say "2/5  start"
	jls -j "$TUI_JAIL" jid >/dev/null 2>&1 || bastille start "$TUI_JAIL"
	check_ip "$TUI_JAIL" "$TUI_IP"

	say "2b/5 default route"
	# bastille_network_gateway is one global value, 172.16.0.1, which is off-link
	# for a jail on 172.16.1.0/24.
	_gw=$(ifconfig "$TUI_BRIDGE" | awk '/inet /{print $2; exit}')
	[ -n "$_gw" ] || die "no inet address on $TUI_BRIDGE"
	_cur=$(sysrc -f "$JAILDIR/root/etc/rc.conf" -n defaultrouter 2>/dev/null || echo "")
	if [ "$_cur" = "$_gw" ]; then
		echo "    defaultrouter already $_gw"
	else
		sysrc -f "$JAILDIR/root/etc/rc.conf" defaultrouter="$_gw" >/dev/null
		bastille restart "$TUI_JAIL" >/dev/null
		echo "    defaultrouter $_cur -> $_gw, jail restarted"
	fi

	# drill hangs on an unroutable resolver rather than failing, so cap it.
	timeout 10 jexec "$TUI_JAIL" drill -Q @172.16.0.1 freebsd.org >/dev/null 2>&1 \
		|| die "$TUI_JAIL cannot resolve via 172.16.0.1 with defaultrouter $_gw"
	echo "    dns via 172.16.0.1 works"

	say "3/5  apply local/tuibase"
	bastille template "$TUI_JAIL" local/tuibase --arg UID="$JUID" --arg USER="$JUSER"

	say "4/5  devfs ruleset"
	# 4 is bastille's stock jail ruleset. no dri, no shm.
	bastille config "$TUI_JAIL" set devfs_ruleset 4
	bastille restart "$TUI_JAIL"

	say "5/5  gates"
	check_devfs "$TUI_JAIL" no no
	jexec "$TUI_JAIL" id "$JUSER" >/dev/null || die "$JUSER missing in $TUI_JAIL"
	echo "    $JUSER resolves"
	# the plist file. cert.pem is a post-install symlink and not guaranteed.
	jexec "$TUI_JAIL" sh -c 'test -s /usr/local/share/certs/ca-root-nss.crt' \
		|| die "no trust store in $TUI_JAIL"
	echo "    ca_root_nss present"

	freeze "$TUI_JAIL"
}

case "$WHICH" in
	linux)   build_linbase ;;
	freebsd) build_guibase ;;
	tui)     build_tuibase ;;
	all)     build_linbase; build_guibase; build_tuibase ;;
	*)       die "usage: $0 [linux|freebsd|tui|all]" ;;
esac

cat <<'DONE'

==> Baselines ready.

Spin up an app jail from one of them:

    doas jail-new linbase NAME 172.16.0.NN state=home/acid/.config/NAME
    doas jail-new guibase NAME 172.16.0.NN

Both baselines are stopped with boot=off and a @golden snapshot. To update one,
start it, change it, re-run this script, and it will re-freeze. To undo a bad
update:

    doas zfs rollback -r zroot/bastille/jails/linbase@golden
DONE
