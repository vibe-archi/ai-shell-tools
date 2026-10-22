# setup-ubuntu-rdp

Turn an Ubuntu VPS into a **remote desktop** you open from any computer with an RDP
client: a full XFCE desktop with Google Chrome, running on the server, shown on your
screen.

```bash
git clone https://github.com/vibe-archi/ai-shell-tools.git
cd ai-shell-tools/setup-ubuntu-rdp
sudo ./setup-ubuntu-rdp.sh   # asks: account name, SSH tunnel or public RDP, password
```

**No GPU needed.** The desktop is drawn in the server's memory (Xorg with the
[xorgxrdp](https://github.com/neutrinolabs/xorgxrdp) driver, software rendering) and
sent to your client as compressed images (RFX codec, encoded by the CPU). Any VPS,
virtual machine or container works, including ones with no `/dev/dri` at all.

## What you get

- **An XFCE desktop** for a dedicated account (its name is asked the first time,
  `desktop` by default, or `--user`) with its own password. It is not a sudoer. Only
  the members of the `rdp-users` group can open a desktop session, never root.
- **Sessions that survive**: close the RDP window and the desktop keeps running;
  connect again and you find it as you left it. Log out from the XFCE menu to end it.
- **Your choice of access**:
  - **SSH tunnel** (recommended): RDP only listens on the server's `127.0.0.1`, you
    reach it through an SSH tunnel;
  - **public**: RDP listens on every interface, optionally restricted to one address
    or network (`--allow-from`, ufw rule), and **fail2ban** bans for 1 hour an address
    with 5 failed logins in 10 minutes.
- **A recent, patched xrdp** (>= 0.10.6.1) and xorgxrdp (>= 0.10.5): these versions
  fix about twenty CVEs published in 2026. When the Ubuntu repositories are older
  (Ubuntu 26.04 has 0.10.1), the script **backports** them: it downloads the source
  packages of the next Ubuntu release from archive.ubuntu.com, signature checked by
  APT, builds them on the server as an unprivileged user, installs them, then removes
  the build tools.
- **TLS 1.2/1.3**, clipboard sharing, resizing with the client window.
- **A UTF-8 session** even when the server has no locale configured (`--locale
  fr_FR.UTF-8` for another language).
- **Google Chrome** from Google's official package (no Snap), with a targeted AppArmor
  fix when the server is an LXC container.

## Requirements

- **Ubuntu 24.04 or later** with systemd: a VPS, a virtual machine or an LXC
  container (never run it on a Proxmox host itself).
- **amd64** for Chrome (`--no-chrome` on other architectures).
- **Resources**: XFCE alone is light; Chrome is not. Count about 2 vCPU and 2 GB of RAM
  for a usable desktop, 4 GB or more if you browse a lot. The backport build needs a
  few hundred MB of temporary disk space.
- An SSH access with sudo, and a terminal: the script asks a few questions.

Missing packages are installed with apt. Plan about 10 minutes when the backport has to
be built, a few minutes otherwise.

## Connecting

Any RDP client works: Windows, Linux or macOS. Log in with the desktop account and its
password. The server's certificate is self-signed, so clients warn about it the first
time.

**SSH tunnel mode.** RDP only listens on the server's `127.0.0.1`: whatever your
computer runs, first open a tunnel and keep it open while you use the desktop (any
account you reach over SSH; add `-i key` or `-p port` as usual):

```bash
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:13389:127.0.0.1:3389 you@server.example.com
```

then point the RDP client at `127.0.0.1:13389`.

**Public mode.** Point the RDP client at `server.example.com:3389` directly.

| Your computer | RDP client (tunnel mode shown) |
| --- | --- |
| Windows | `mstsc /v:127.0.0.1:13389` (Remote Desktop Connection, built in) |
| Linux | `xfreerdp3 /v:127.0.0.1:13389 /u:desktop /dynamic-resolution +clipboard` (FreeRDP 3; `xfreerdp` with FreeRDP 2), or Remmina |
| macOS | Windows App (Microsoft), add a PC: `127.0.0.1:13389` |

## Options

```
  --user NAME              account of the desktop, created if needed (asked the first time)
  --reset-password         set the password of an existing account again
  --local                  RDP only on 127.0.0.1, through an SSH tunnel (recommended)
  --public                 RDP on every interface (without --local/--public: asked)
  --allow-from ADDRESS     with --public: only this IP or network (needs ufw); "any" lifts it
  --port N                 RDP port (default: 3389)
  --no-fail2ban            with --public: no fail2ban jail (--fail2ban puts it back)
  --locale NAME            UTF-8 locale of the session, e.g. fr_FR.UTF-8
  --source MODE            where xrdp comes from: auto (default) | repo | backport | ppa
  --keep-build-deps        keep the packages installed to build the backport
  --no-chrome              don't install Google Chrome
  --chrome-apparmor MODE   auto | on | off
```

## Running it again, switching the access mode

Running the script again is safe: it updates what needs to be and rebuilds the backport
when newer sources are published. It remembers your choices (account, access mode,
port, address restriction, locale, fail2ban) in `/etc/setup-ubuntu-rdp/settings`, so a
plain re-run keeps them; options change them.

Run it over SSH or a console, after logging out of the desktop (XFCE menu > Log Out: a
mere disconnection keeps the session running, and the script won't touch xrdp then).

```bash
sudo ./setup-ubuntu-rdp.sh --public                          # tunnel -> public
sudo ./setup-ubuntu-rdp.sh --public --allow-from 203.0.113.7 # public, from one address
sudo ./setup-ubuntu-rdp.sh --allow-from any                  # lift the restriction
sudo ./setup-ubuntu-rdp.sh --local                           # back to the SSH tunnel
```

The ufw rule and the fail2ban jail follow the mode.

Exit codes: `0` everything checked, `2` done with warnings, anything else: stopped (the
log is in `/var/log/setup-ubuntu-rdp/`). Modified files are backed up in
`/var/backups/setup-ubuntu-rdp/`.

## Public access and fail2ban

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
- behind NAT (a container on a host, for example), the host has to forward the port;
- `sudo ./setup-ubuntu-rdp.sh --local` closes it again.

## What it does not touch

IPv6, DNS, routes, Proxmox confinement, the SSH configuration. No `--no-sandbox` for
Chrome, no AppArmor "allow all", no Snap removal, no `apt full-upgrade`, no reboot. The
firewall is only changed for the public RDP port.

## Troubleshooting

```bash
journalctl -u xrdp -u xrdp-sesman -n 100 --no-pager
tail -n 100 /var/log/xrdp.log /var/log/xrdp-sesman.log
tail -n 100 ~desktop/.xsession-errors
```

- **The script stops with "An xrdp session exists"**: log out of the desktop (XFCE
  menu > Log Out), then run it again.
- **Login refused**: check the account name and its password, and that it is in the
  `rdp-users` group (`id desktop`).
- **Black screen, then disconnected**: look at `~/.xsession-errors` of the account.

## Tested on

Ubuntu 26.04 (an LXC container on Proxmox, 4 vCPU, 8 GB), xrdp and xorgxrdp
backported from Ubuntu 26.10, FreeRDP 3 (`sdl-freerdp`) on Windows through an SSH
tunnel. Ubuntu 24.04 and public mode have not been tested end to end yet.
