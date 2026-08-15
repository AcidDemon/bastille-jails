# Jail baselines

Staging area for the golden baseline jails and the scripts that clone them.
Everything here needs root to install, so the files live in `~/.jails` and get
copied into place by the setup scripts.

Written for one FreeBSD 15.1 host. The addresses, bridge names, jail list and
the local kernel patch it depends on are all specific to that machine, so read
it as a worked example rather than something to run unedited. The parts likely
to be useful elsewhere are the traps at the bottom.

## What this replaces

Adding a jail used to mean re-running a twenty-phase provisioning script with
the names changed. Now a baseline jail is built once, frozen, and cloned.

    guibase   FreeBSD 15.1 thin, 172.16.0.10, devfs 20, jailnatbridge
    linbase   Debian 13 under linuxulator, 172.16.0.11, devfs 21, jailnatbridge
    tuibase   FreeBSD 15.1 thin, 172.16.1.10, devfs 4, jailprivbridge

All three end stopped, `boot=off`, with a `@golden` snapshot, and none ever runs
an application. `bastille clone` does a full `zfs send | recv`, so a clone is
independent of its baseline and the baseline can be updated without touching it.

`guibase` and `linbase` carry fonts, Mesa, libglvnd and pulseaudio, and their
rulesets unhide `/dev/dri`. `tuibase` has `ca_root_nss` and a user, runs under
bastille's stock ruleset 4, and sits on the untrusted bridge. A terminal client
gets no GPU device and no shared segment with the browsers.

## Order

    doas sh ~/.jails/baseline-setup.sh all

    doas jail-new -x ~/.jails/vesktop.pf linbase vesktop 172.16.0.40 \
         config=home/acid/.config/vesktop
    doas sh ~/.jails/vesktop-setup.sh

    doas jail-new -x ~/.jails/element.pf linbase element 172.16.0.50 \
         config=home/acid/.config/Element
    doas sh ~/.jails/element-setup.sh

    doas jail-new -n -x ~/.jails/weechat.pf tuibase weechat 172.16.1.50 \
         home=home/acid/.weechat
    doas sh ~/.jails/weechat-setup.sh

    doas jail-new -n -x ~/.jails/feather.pf guibase feather 172.16.0.60 \
         wallets=home/acid/.Monero config=home/acid/.config/feather
    doas sh ~/.jails/feather-setup.sh

    doas sh ~/.jails/sniproxy-setup.sh
    doas jail-new -n tuibase claude 172.16.1.70 home=home/acid
    doas sh ~/.jails/claude-setup.sh

    doas jail-new -n tuibase codex 172.16.1.60 home=home/acid
    doas sh ~/.jails/codex-setup.sh

    doas sh ~/.jails/sniproxy-jail.sh element 172.16.0.50 172.16.0.2
    doas sh ~/.jails/sniproxy-jail.sh vesktop 172.16.0.40 172.16.0.3
    doas sh ~/.jails/sniproxy-jail.sh spotify 172.16.0.30 172.16.0.4

`baseline-setup.sh` takes `linux`, `freebsd`, `tui` or `all`. Each setup script
ends by printing the one `doas.conf` line it will not write itself.

feather is the only jail on ruleset 22, ruleset 20 plus `video*` and `cuse` for
the QR scanner, and the only one whose pf file lets nothing but tor out. Its
setup script writes that ruleset and switches the jail to it. See
`feather-design.md` for why the boundary sits where it does.

spotify needs `-x` for tcp 4070, its legacy access point, on top of the
defaults. Its theme is a separate step, because spicetify ships with none
selected and applying nothing leaves the client looking stock:

    doas sh ~/.jails/spotify-setup.sh
    doas sh ~/.jails/spotify-theme.sh

`-n` drops the default `tcp { 80, 443 }` and `udp 443` rules, leaving only what
`-x` supplies. weechat wants neither port 80 nor any UDP.

## Files

    templates/local/guibase/Bastillefile     FreeBSD GUI baseline
    templates/local/linbase/Bastillefile     Debian GUI baseline
    templates/local/linbase/sysusers-sh      systemd-sysusers stand-in
    templates/local/tuibase/Bastillefile     terminal baseline
    baseline-setup.sh                        builds and freezes the baselines
    jail-new                                 clones one into an app jail
    bridge-private-test.sh                   proves bridge port isolation works
    bridge-private-persist.sh                makes it survive a jail restart
    launcher-consistency.sh                  normalises paths and desktop entries
    debian-locale.sh                         generates en_US.UTF-8 in Debian jails
    <app>-jail                               launchers, root-owned once installed
    <app>.pf                                 per-app pf extras
    <app>-setup.sh                           per-app install
    spotify-theme.sh                         catppuccin for spicetify
    sniproxy.conf                            egress allowlist, shared by agent jails
    sniproxy-setup.sh                        installs it and proves it filters
    claude-marketplace-https.py              turns github plugin sources into https URLs
    claude-git-trace.sh                      shims git in the jail to unredact its stderr
    codex-setup.sh                           the same for codex, minus linuxulator
    sniproxy-jail.sh                         routes an existing jail's 80/443 through the proxy
    feather-design.md                        why the wallet jail looks like it does

Apps covered by a setup script: spotify, vesktop, element, weechat, claude. zen
and zenburner predate the tooling and have launchers only.

`baseline-setup.sh` copies the templates to
`/usr/local/bastille/templates/local/` before applying them, so this directory
stays the source of truth.

## Launcher layout

Two files per app, and the split is a security boundary, not a style choice.

    ~/bin/<app>-jail               one line, unprivileged, owned by acid
    /usr/local/sbin/<app>-jail     the real launcher, root-owned 0755

The doas rule points at the second one only:

    permit nopass acid as root cmd /usr/local/sbin/<app>-jail

Both halves carry the `-jail` suffix so it is always obvious which one starts.
`~/bin/zen` is kept as well, because `/usr/local/bin/zen` exists and `~/bin`
comes first on PATH: dropping it would quietly hand the short name to the
unjailed browser.

**Run the wrapper directly: `spotify-jail`, not `doas spotify-jail`.** It already
calls doas itself. `doas spotify-jail` asks doas to run a command named
"spotify-jail", which no rule names, and fails with
`doas: Operation not permitted`. That message means the invocation was wrong,
not that anything is broken.

Never add a doas rule for the `~/bin` wrapper to make `doas <app>` work. Those
files are writable by acid, so a rule running one as root turns a one-line edit
into root. The privileged half has to stay root-owned and outside acid's reach.

## Bridge port isolation

pf blocks jail-to-jail traffic by IP, but jails sharing a bridge share a
broadcast domain and can still ARP each other. `ifconfig <bridge> private <member>`
stops a member forwarding to any other private member, while leaving its path to
the bridge address intact, so DNS and NAT still work.

Measured with `bridge-private-test.sh`: before, zen resolved spotify's MAC;
after, the ARP entry stayed `(incomplete)` and all five DNS and HTTPS checks
still passed.

`bridge-private-persist.sh` adds the `exec.prestart` line to the existing app
jails. It skips the baselines on purpose, because `clone.sh` rewrites `addm` but
has no sed for `private e0a_<name>`, so a clone would inherit a line naming an
interface it does not have. `jail-new` adds the line per jail instead.

## The agent jail

`claude` runs Claude Code, and it is the only jail whose workload is the repos
themselves. It gets `~/Workspace` and `~/.dotfiles` read-write, `~/.jails`,
`/usr/ports` and `/usr/src` read-only, all at the host path, because
`~/.claude/projects` keys its session history by encoded absolute path.

It gets no ssh key, no gh token and no card, so commits land unsigned and push
fails. Signing and pushing stay on the host. Egress is the same story: no direct
443 at all, only a pf `rdr` to sniproxy, which allows a list of names and refuses
everything else. The refusal shows up in the jail as a TLS handshake failure and
in `/var/log/sniproxy.log` as `-> NONE [name]`.

What the jail does not close: those repos are writable, so `.git/hooks` and
`.git/config` are under its control, and a planted pre-push hook or
`core.fsmonitor` runs on the host at the next git command. `exports.sh` pins
both through `GIT_CONFIG_KEY_*`, which ranks with `git -c` and beats repo
config. `~/.jails` is read-only for the same class of reason, since `jail-new`
runs as root through doas. `~/.dotfiles` is read-write by choice, which leaves
the chezmoi `run_after_*` scripts reachable, so `chezmoi diff` before an apply
is the compensating control.

codex gets its own jail rather than sharing this one. The jails would be
equivalent at the file level, but an OAuth refresh token is remotely usable and
neither vendor's agent should be able to read the other's. The same split runs
through the egress: sniproxy listens on `172.16.1.1` for claude and on the alias
`172.16.1.2` for codex, with a table each, so codex cannot reach Anthropic
endpoints and claude cannot reach OpenAI ones. `sniproxy-setup.sh` asserts that
both directions fail before it exits.

codex needs none of the linuxulator work. It is a native FreeBSD ELF, so no
`/compat` mounts and no `enforce_statfs` change, though it does get the same
`/dev/ptmx` check, since an agent that spawns shell commands hits the same wall
claude did.

## Proxied jails

sniproxy reads the TLS ClientHello, matches the server name against a table and
connects to that name itself. A forged SNI therefore reaches only the host it
names. Each jail gets its own address, so no two share a table:

    172.16.1.1  claude      172.16.0.2  element
    172.16.1.2  codex       172.16.0.3  vesktop
                            172.16.0.4  spotify

Everything but `172.16.1.1` is a `/32` alias, created by `sniproxy-setup.sh` from
the `listen` lines in the config, because sniproxy refuses to start if an address
it wants is not on an interface.

`sniproxy-jail.sh` does the pf side for a jail that already exists. It inserts the
`rdr`, replaces the jail's direct `80, 443` pass with one to the proxy, and
**removes its `udp 443` rule**. That removal is the point rather than a side
effect: Chromium prefers QUIC, and a jail left with UDP 443 skips the proxy
entirely and the whole exercise achieves nothing. WebRTC rules on 3478, 5349 and
the high range are untouched, and sniproxy cannot see that traffic at all, so
voice stays exactly as open as it was.

element, vesktop and spotify start on catch-all tables. Nothing is blocked by
name, but non-TLS traffic on 443 is already dropped and every hostname is logged,
which is how the real list gets written:

    awk '{print $8}' /var/log/sniproxy.log | sort -u

Three jails are deliberately not proxied. tor negotiates TLS with randomised SNI,
so `feather` cannot be matched and would break. `zen` and `zenburner` are general
browsers, where an allowlist for the whole web is not a control. `weechat` is
half-eligible: 6697 and 7000 are TLS, but 6667 is plaintext IRC and sniproxy has
no parser for it.

## What a baseline may not contain

No `zroot/jailstate` mount. `update_fstab()` in bastille's `common.sh` rewrites
only the destination path of an fstab line and never the source, so every clone
would end up sharing the baseline's dataset. `baseline-setup.sh` asserts this
before freezing, and `jail-new` asserts that nothing in a fresh clone still
names its baseline.

## Traps this encodes

Each of these cost a debugging session at least once.

`bastille_network_gateway` is one global value, `172.16.0.1`. A jail on
`jailprivbridge` gets an off-link gateway, so `route add default` fails and it
has no route out. The address is still assigned, so an IP check passes and only
DNS or `pkg` reveals it. `baseline-setup.sh` derives the gateway from the bridge.
Note `drill` hangs and exits 124 against an unroutable resolver rather than
failing fast, so any probe needs a `timeout`.

An fstab `devfs` line with no `ruleset=` option gets no ruleset at all, which
makes the `devfs_ruleset` jail parameter inert. Linux jails take devfs from
fstab, so this is where the ruleset has to go, and it has to be 21 rather than
20 because 20 has no `shm` unhide and `/dev/shm` would disappear.

Mesa without libglvnd is half a stack. `libegl-mesa0` and `mesa-dri` ship the
drivers; `libEGL.so.1` comes from `libegl1` on Debian and `libglvnd` on FreeBSD.
Electron dlopens it at runtime, so it is never a recorded dependency, and
without it every EGL display type fails and the process dies on SIGTRAP.

`bastille create -L` writes a `/tmp` nullfs line into the jail fstab regardless
of template, handing over the host `/tmp` with its session dbus and keyring
sockets. `baseline-setup.sh` strips it.

`bastille clone` rewrites `vnet.interface` but none of the three
`exec.poststart` lines that assign the address, so a cloned Debian jail comes up
inconsistent and still on the baseline's IP. `jail-new` writes jail.conf
wholesale for the Debian flavor instead of trusting the rewrite.

Jail names are capped at 11 characters and may not contain a hyphen: `e0a_<name>`
has to fit `IF_NAMESIZE`, and bastille writes `ifconfig_e0b_<name>_name` through
`sysrc`, which rejects hyphens. That is why the Debian baseline jail is called
`linbase`.

`systemd-sysusers` cannot lock `/etc/.pwd.lock` under linuxulator and
`systemd-tmpfiles` reads a mounted linprocfs as absent. Both are replaced through
`dpkg-divert` rather than `mv`, so a later package upgrade cannot quietly restore
the real binaries.

Launch GUI apps with `jexec -l -u`, never `bastille cmd` plus `su -c`. The app
forks during startup, the wrapper shell exits, bastille tears down, and the real
processes are orphaned. It presents as a clean `exit=0`.

`jexec -l` keeps HOME, SHELL, TERM and USER, drops everything else including
LANG, and sets `PATH=/bin:/usr/bin`. Terminal apps need LANG passed and an
absolute path to anything under `/usr/local`.

Claude Code builds `git@github.com:owner/repo` from a plugin marketplace whose
source is `github`, so installing or refreshing one needs an ssh key. A jail
without one reports `ERR_STREAM_PREMATURE_CLOSE` and redacts git's stderr, which
reads like a network fault and is not: the same clone by hand over https
succeeds. `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` in the launcher aims at the cause;
`CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1` stops it deleting the
evidence. `claude-git-trace.sh` shims git in the jail when the redacted error is
all there is to go on.

A sniproxy table entry is a pattern and a target, and the target `*` means the
name the client asked for, on the listener's port. A pattern with no target
parses, starts, and listens, so every socket check passes while the log records
`-> NONE` for every connection and nothing reaches anywhere.

`/etc/pf.conf` blocks RFC1918 from the untrusted tier with a `quick` rule, and
`172.16.1.1` is inside that range. pf translates before it filters, so a `rdr` to
the bridge address only survives if its `pass` sits above that block. `jail-new`
splices below it, which is why `claude` has no `-x` file and `claude-setup.sh`
places both rules itself.

`/compat/linux` does not exist until `linux_base-rl9` is installed, and `jail(8)`
reads `mount.fstab` before the jail is created. The four linuxulator lines
therefore go in after the first `pkg` run, never at create time. Their
`enforce_statfs` has to be 1: bastille generates 2, which empties
`/compat/linux/proc/self/mounts` and breaks glibc `getmntent`.

A FreeBSD jail running Linux binaries needs all five mounts `/etc/rc.d/linux`
makes, `devfs` at `/compat/linux/dev` included, and `devfs` has to come first in
fstab because `dev/fd` and `dev/shm` sit inside it. `kern_alternate_path` tries
`/compat/linux/<path>` and falls back to the real one, which covers opening
`/dev/null` and makes the mount look redundant. It is not: without it the Linux
side has no `/dev/ptmx`, so anything allocating a pty fails. That presents as a
subprocess which never execs, with no error from the program that tried.

That devfs needs ruleset 23, not the stock 4. Ruleset 4 hides `shm`, so the
mountpoint for the shm tmpfs disappears underneath the devfs and the jail refuses
to start with `No such file or directory`. Ruleset 23 is 4 plus `shm` unhide,
which is the same reason ruleset 21 exists for the Debian baseline.
