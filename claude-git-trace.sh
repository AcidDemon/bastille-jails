#!/bin/sh
#
# Capture what Claude Code actually runs when a plugin clone fails. It redacts
# git's stderr, so the real error only shows up by shimming git in the jail.
#
#   doas sh ~/.jails/claude-git-trace.sh install
#   claude-jail          then run /plugin, then quit
#   doas sh ~/.jails/claude-git-trace.sh show
#   doas sh ~/.jails/claude-git-trace.sh remove

set -eu

R=/usr/local/bastille/jails/claude/root
G=$R/usr/local/bin/git
LOG=$R/tmp/git-shim.log

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
[ -d "$R" ] || { echo "no claude jail at $R" >&2; exit 1; }

case "${1:-}" in
install)
	[ -f "$G.real" ] || mv "$G" "$G.real"
	cat > "$G" <<'SHIM'
#!/bin/sh
{
	printf '\n--- %s cwd=%s\n' "$(date +%T)" "$(pwd)"
	printf 'argv: %s\n' "$*"
	env | sort | sed 's/^/  env /'
} >> /tmp/git-shim.log 2>&1
/usr/local/bin/git.real "$@" 2>>/tmp/git-shim.log
rc=$?
echo "exit=$rc" >> /tmp/git-shim.log
exit $rc
SHIM
	chmod 0755 "$G"
	: > "$LOG"
	chmod 0666 "$LOG"
	echo "shim on. run claude-jail, then /plugin, then quit, then: $0 show"
	;;
show)
	[ -f "$LOG" ] || { echo "no log: git was never executed" >&2; exit 1; }
	tail -80 "$LOG"
	;;
remove)
	[ -f "$G.real" ] && mv "$G.real" "$G"
	echo "git restored"
	;;
*)
	echo "usage: $0 install|show|remove" >&2
	exit 1
	;;
esac
