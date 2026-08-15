# feather jail

Design for running the Monero wallet in a jail, decided 2026-08-12.

A wallet is worth isolating in a way a music client is not. What follows keeps
the existing framework intact and adds one new devfs ruleset.

## Shape

Clone `guibase` into `feather` on the NAT tier at `172.16.0.60`. The private
tier would be the tighter default, but tor has to reach guard nodes on 443 and
9001, and `jailprivbridge` cannot, so NAT it is. The jail itself still gets no
general egress; see below.

    doas jail-new -n -x ~/.jails/feather.pf guibase feather 172.16.0.60 \
         wallets=home/acid/.Monero config=home/acid/.config/feather

Two state datasets. Wallet keys are the one thing here that cannot be rebuilt,
so they live outside the jail root and snapshot on their own.

The wallet directory is set by seeding `settings.json` before the first launch.
feather reads that key and only falls back to a built-in default when it is
missing, so nothing ever looks at `~/Monero`. The built-in default is worth
knowing about anyway: upstream guards it with
`#if defined(Q_OS_LINUX) or defined(Q_OS_MAC)` and an `#elif` for Windows, so on
FreeBSD `Utils::defaultWalletDir()` runs off the end of a non-void function and
returns whatever happens to be in the register. clang says so during the build.
The port patches that, along with four other Linux-only branches that apply
just as well here.

## Devices

New ruleset 22, ruleset 20 plus `video*` and `cuse`. The QR scanner needs a
camera; it does not need USB. webcamd runs on the host and publishes the camera
as a cuse device, so the jail sees `/dev/video0` without any `ugen*` access at
all.

Hardware wallets are deliberately out of scope. Reaching a Trezor means
unhiding `usb/*` and `ugen*`, which hands the jail every USB device on the
machine, keyboard included. That is a worse trade than not using a Trezor from
inside this jail.

## Egress

tor runs inside the jail and listens on the jail's own loopback. feather is
started with `--use-local-tor` and points at an onion remote node. pf lets tor
out and nothing else:

    pass in quick on $jail_if proto tcp from $j_feather to any port { 443, 9001, 9030 } keep state

`jail-new -n` drops the default web rules, so feather has no clearnet path.
A compromised wallet process can reach exactly one thing, the SOCKS port beside
it. Sync over onion is slower, which is the cost of that.

## Theme

The host session runs qt6ct with Kvantum and `catppuccin-mocha-blue`, icons
`Colloid-Catppuccin-Dark`. The jail gets the same: `qt6ct` and `Kvantum` are
installed inside it, `~/.config/qt6ct` and `~/.config/Kvantum` come in as
read-only nullfs mounts the way guibase already handles the GTK theme paths, and
the launcher exports `QT_QPA_PLATFORMTHEME=qt6ct` and `QT_STYLE_OVERRIDE=kvantum`.
`~/.local/share/icons` was already mounted by the baseline.

feather's own `skin` setting has to be `Native` for any of that to show. Its
default is `"light"`, which is not even one of the skins the app registers, so
it resolves to an empty stylesheet and the window comes up in raw Qt Fusion.
Anything other than `Native` paints feather's own stylesheet over Kvantum.

## Install

`feather-setup.sh`, shaped like the other setup scripts: copy the
poudriere-built package into the jail, `pkg -j feather install` it so the FreeBSD
repo resolves its dependencies, install and enable tor, seed the config with an
onion node, print the doas line.

The package comes from the local ports tree, `net-p2p/feather`, built in
poudriere as `151amd64-local`. It is the same package the host would install,
scanner and Trezor support included. Trezor support is compiled in but unusable
here, and that is fine: it costs nothing at runtime.

## Launchers

The usual pair. `~/bin/feather-jail` calls the root-owned
`/usr/local/sbin/feather-jail`, which starts the jail if needed and execs
`jexec -l -u acid` with the Wayland, pulse and dbus environment the other GUI
jails use.

## Order

1. Add ruleset 22 to `/etc/devfs.rules`, restart devfs.
2. `jail-new` as above, with `feather.pf` in place first.
3. Set `devfs_ruleset = 22` on the jail and restart it.
4. Run `feather-setup.sh`.
5. Install the launcher pair and the doas rule.
6. Verify.

## Verification

- `jexec feather sockstat -4l | grep 9050` shows tor listening.
- From inside the jail, a clearnet probe to a public Monero node on 18081 fails.
- feather opens a window under Hyprland and reaches its onion node.
- `/dev/video0` exists in the jail and the scanner enumerates it.
- A test wallet writes into the `wallets` dataset, confirmed with `zfs list`.
