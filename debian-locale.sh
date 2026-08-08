#!/bin/sh
#
# Generate en_US.UTF-8 in Debian jails that predate the locales step in
# templates/local/linbase. Run as root, safe to re-run.
#
#   doas sh ~/.jails/debian-locale.sh [jail ...]
#
# jexec -l carries the host login class, which /etc/login.conf sets to
# lang=en_US.UTF-8, but debootstrap generates only C.utf8. perl warns on every
# invocation and anything locale-aware falls back to C.

set -eu

PREFIX=/usr/local/bastille

say() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

if [ $# -gt 0 ]; then
	JAILS="$*"
else
	JAILS=""
	for d in "$PREFIX"/jails/*/; do
		j=$(basename "$d")
		# baselines are frozen against @golden, so editing one here would leave
		# the snapshot behind. baseline-setup.sh re-applies and re-freezes.
		case "$j" in guibase|linbase|tuibase) continue ;; esac
		[ -f "$d/root/etc/debian_version" ] && JAILS="$JAILS $j"
	done
fi
[ -n "$JAILS" ] || die "no Debian jails found"

for j in $JAILS; do
	say "$j"
	[ -f "$PREFIX/jails/$j/root/etc/debian_version" ] || { echo "    not a Debian jail, skipping"; continue; }

	_was_down=no
	jls -j "$j" jid >/dev/null 2>&1 || { bastille start "$j" >/dev/null; _was_down=yes; }

	# ask locale(1), not the filesystem: glibc 2.41 compiles into
	# /usr/lib/locale/locale-archive rather than a directory per locale
	if bastille cmd "$j" sh -c 'locale -a 2>/dev/null | grep -qi "^en_US\.utf"'; then
		echo "    en_US.UTF-8 already generated"
	else
		bastille cmd "$j" sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales'
		bastille cmd "$j" sh -c "sed -i -E 's/^#[[:space:]]*(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen"
		bastille cmd "$j" locale-gen
		bastille cmd "$j" sh -c "printf 'LANG=en_US.UTF-8\n' > /etc/default/locale"
		bastille cmd "$j" sh -c 'locale -a 2>/dev/null | grep -qi "^en_US\.utf"' \
			|| die "$j: locale-gen ran but locale -a still does not list en_US.utf8"
		echo "    generated"
	fi

	# the warning comes from perl, so let perl be the check
	if bastille cmd "$j" perl -e 'exit 0' 2>&1 | grep -q 'locale'; then
		die "$j: perl still warns about locales"
	fi
	echo "    perl quiet"

	[ "$_was_down" = yes ] && { bastille stop "$j" >/dev/null; echo "    stopped again"; }
done

cat <<'DONE'

==> Done.

New jails get this from templates/local/linbase. To fold it into the frozen
baseline so future clones carry it:

    doas sh ~/.jails/baseline-setup.sh linux
DONE
