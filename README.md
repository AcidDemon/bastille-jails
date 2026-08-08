# Jail baselines

Staging area for the golden baseline jails and the scripts that clone them.
Everything here needs root to install, so the files live in `~/.jails` and get
copied into place by the setup scripts.

Written for one FreeBSD 15.1 host. The addresses, bridge names, jail list and
the local kernel patch it depends on are all specific to that machine, so read
it as a worked example rather than something to run unedited. The parts likely
to be useful elsewhere are the traps at the bottom.

## What this replaces

Adding a jail used to mean re-running the eleven phases of
`~/bin/spotify-jail-setup.sh` with the names changed. Now a baseline jail is
built once, frozen, and cloned.

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

    doas jail-new -n -x ~/.jails/weechat.pf tuibase weechat 172.16.1.50 \
         home=home/acid/.weechat
    doas sh ~/.jails/weechat-setup.sh

`baseline-setup.sh` takes `linux`, `freebsd`, `tui` or `all`. Each setup script
ends by printing the one `doas.conf` line it will not write itself.

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
    spotify-jail  vesktop-jail  weechat-jail launchers
    vesktop.pf  weechat.pf                   per-app pf extras
    vesktop-setup.sh  weechat-setup.sh       per-app install

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
