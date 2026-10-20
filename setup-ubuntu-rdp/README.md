# setup-ubuntu-rdp

Turn an Ubuntu server (VM, VPS or container) into a remote desktop you reach with any
RDP client: XFCE on Xorg through [xrdp](https://github.com/neutrinolabs/xrdp), with
Google Chrome.

```bash
git clone https://github.com/vibe-archi/ai-shell-tools.git
cd ai-shell-tools/setup-ubuntu-rdp
sudo ./setup-ubuntu-rdp.sh            # asks: SSH tunnel or public RDP, then a password
```

## What you get

- **An XFCE desktop** for a dedicated account (`desktop` by default, `--user` to change
  it), which is not a sudoer. Only the members of the `rdp-users` group can open a
  desktop session, never root.
- **A recent, patched xrdp** (>= 0.10.6.1) and xorgxrdp (>= 0.10.5): these versions fix
  about twenty CVEs published in 2026. When the Ubuntu repositories are older (Ubuntu
  26.04 has 0.10.1), the script **backports** them: it downloads the source packages of
  the next Ubuntu release from archive.ubuntu.com, signature checked by APT, builds them
  here as an unprivileged user, installs them, then removes the build tools.
- **Your choice of access**:
  - **SSH tunnel** (recommended): RDP only listens on `127.0.0.1`;
  - **public**: RDP listens on every interface, optionally restricted to one address or
    network (`--allow-from`) with an ufw rule, and **fail2ban** bans for 1 hour an
    address with 5 failed logins in 10 minutes.
- **TLS** (TLS 1.2/1.3), RFX codec, clipboard, dynamic resolution, sessions that survive
  a disconnection.
- **A UTF-8 session** even when the system has no locale (`--locale fr_FR.UTF-8` to
  choose it).
- **Google Chrome** from Google's official `.deb` (no Snap), with a targeted AppArmor
  fix in LXC containers.

## Connecting

Through an SSH tunnel, from Windows (keep the first command running):

```powershell
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:13389:127.0.0.1:3389 you@server.example.com
mstsc /v:127.0.0.1:13389
```

In public mode:

```powershell
mstsc /v:server.example.com:3389
```

Log in with the desktop account and its password. The certificate is self-signed, so
the client shows a warning the first time.

## Options

```
  --user NAME              Linux account of the desktop (default: desktop)
  --reset-password         set the password of an existing account again
  --local                  RDP only on 127.0.0.1, through an SSH tunnel (recommended)
  --public                 RDP on every interface (without --local/--public: asked)
  --allow-from ADDRESS     with --public: only this IP or network (needs ufw)
  --port N                 RDP port (default: 3389)
  --no-fail2ban            with --public: no fail2ban jail
  --locale NAME            UTF-8 locale of the session, e.g. fr_FR.UTF-8
  --source MODE            auto (default) | repo | backport | ppa
  --keep-build-deps        keep the packages installed to build the backport
  --no-chrome              don't install Google Chrome
  --chrome-apparmor MODE   auto | on | off
```

Running the script again is safe: it updates what needs to be, switches between local
and public access (the ufw rule follows), and rebuilds the backport when newer sources
are published. Run it over SSH or a console, after logging out of the desktop.

Exit codes: `0` everything checked, `2` done with warnings, anything else: stopped (see
the log in `/var/log/setup-ubuntu-rdp/`). Modified files are backed up in
`/var/backups/setup-ubuntu-rdp/`.

## Public access

xrdp has no protection of its own against password guessing. In public mode the script
installs **fail2ban** with an `xrdp-authfail` jail: an address that fails 5 logins in 10
minutes is banned for 1 hour. It reads the `AUTHFAIL` lines that xrdp-sesman writes for
this purpose (`/var/log/xrdp-sesman.log`), and the script checks that a ban really
reaches the firewall before opening RDP. Ubuntu's fail2ban package also guards SSH.

```bash
sudo fail2ban-client status xrdp-authfail              # banned addresses
sudo fail2ban-client set xrdp-authfail unbanip 1.2.3.4  # unban one
```

Also:

- use a long, unique password for the desktop account;
- restrict the port to your address: `--allow-from 203.0.113.7` (ufw), or your
  provider's firewall;
- in a container behind NAT, the host has to forward the port;
- `sudo ./setup-ubuntu-rdp.sh --local` closes it again.

## What it does not touch

IPv6, DNS, routes, Proxmox confinement, the SSH configuration. No `--no-sandbox` for
Chrome, no AppArmor "allow all", no Snap removal, no `apt full-upgrade`, no reboot.
The firewall is only changed for the public RDP port.

## Troubleshooting

```bash
journalctl -u xrdp -u xrdp-sesman -n 100 --no-pager
tail -n 100 /var/log/xrdp.log /var/log/xrdp-sesman.log
tail -n 100 ~desktop/.xsession-errors
```
