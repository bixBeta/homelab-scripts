# homelab-scripts

Small, dependency-light scripts for a self-hosted server reached over
[Tailscale](https://tailscale.com): moving files to and from FTP/FTPS
servers, alerting before Tailscale keys expire, syncing a clipboard between
a Mac and a Wayland Linux box, and keeping RustDesk reachable.

Nothing here needs an account, an agent, or a framework — POSIX `sh`, a
stdlib-only Python script, and Docker where a tool would otherwise have to
be installed.

No credentials are committed. Every secret lives in a local copy or an
environment variable; the templates ship with placeholders.

## ftp/

**`ftp-mirror.sh`** — download a folder from an FTP/FTPS server, or upload
one to it, in a background Docker container that survives closing SSH.
Written for sequencing-core deliveries, which tend to be large, slow, and
resumed more than once.

```sh
cp ftp/ftp-mirror.sh ftp-mirror-myrun.sh
# edit the settings block: DIRECTION, FTP_USER, FTP_PASS, REMOTE_DIR, LOCAL_DIR
sh ftp-mirror-myrun.sh          # start or resume
sh ftp-mirror-myrun.sh status   # downloading / finished OK / FAILED
sh ftp-mirror-myrun.sh logs     # follow progress
```

Things it gets right that cost real debugging time:

- **The password never appears** in the command line, `ps`, or
  `docker inspect` — it reaches `lftp` through an environment variable set
  inside the container.
- **TLS is forced before login.** Without an explicit `-u user`, `lftp`
  logs in anonymously, and it never encrypts anonymous logins — so a server
  demanding encryption rejects you with a confusing 550.
- **Symlinked source trees upload correctly.** Nextflow `publishDir` writes
  symlinks into `work/`; `lftp` would try `SITE SYMLINK`, which FTP servers
  reject, transferring nothing. `FOLLOW_SYMLINKS=yes` adds `--dereference`,
  and `EXTRA_MOUNT` mounts the run root read-only at the same absolute path
  so those link targets resolve inside the container.
- **`--no-perms`** on uploads, because many servers reject `SITE CHMOD`/`MFF`
  and `lftp` otherwise fails every file *after* transferring it.
- **Never deletes** anything on either side; uploads mount the source
  read-only.
- **Works under restricted Docker wrappers.** Set `DOCKER="docker1"` for
  Cornell BioHPC's wrapper, which renames containers and only mounts
  permitted directories.

## tailscale/

**`push-to-tailnet.sh`** — copy files *out of* a machine that can only reach
your tailnet outbound (a cluster login node, a box behind a corporate VPN)
onto any tailnet machine that accepts your SSH key.

```sh
sh push-to-tailnet.sh results/ myserver:/data/incoming/
sh push-to-tailnet.sh -n results/ 100.x.y.z:/data/      # dry run
```

`-n` dry run, `-k` keep symlinks (default sends what they point at), `-q`
quiet, `-l` list every tailnet machine with its ssh alias, online state and
whether your key gets in. A trailing slash on the source copies its
contents. It never deletes anything on the far side.

```
$ sh push-to-tailnet.sh -l
ALIAS    MACHINE                ADDRESS          STATE    SSH
mac      my-laptop              100.x.y.z        online   ok
zima     my-server              100.x.y.z        online   ok
storm    spare-box              100.x.y.z        offline  -
```

It exists because inbound SSH to such machines often requires two-factor
auth, which can't be automated — so the transfer has to be pushed, not
pulled. It starts `tailscaled` in userspace mode if needed (no root, no tun
device) and routes SSH through that daemon's SOCKS proxy, since a userspace
node can't make ordinary outbound connections.

**`ts-key-expiry-check.py`** — warn before a Tailscale node's key expires.
Stdlib only, no dependencies. Credentials come from `TS_CLIENT_ID`,
`TS_CLIENT_SECRET` and `ALERT_URL` — Slack, Discord or
[ntfy](https://ntfy.sh), detected from the URL. Flags: `--dry-run`, `--all`,
`--report`.

```sh
TS_CLIENT_ID=… TS_CLIENT_SECRET=… ALERT_URL=https://ntfy.sh/your-topic \
  python3 tailscale/ts-key-expiry-check.py --all
```

Tailscale has no built-in expiry notification ([#4688](https://github.com/tailscale/tailscale/issues/4688),
[#12745](https://github.com/tailscale/tailscale/issues/12745),
[#14647](https://github.com/tailscale/tailscale/issues/14647)), and an
expired key on a headless box means losing remote access to it entirely.

Use an **OAuth client** with read-only `devices:core` scope, not an API
access token — access tokens expire after 90 days, so an expiry monitor
built on one dies of expiry.

Two details worth knowing if you adapt it: Discord's Cloudflare returns
**403 error 1010** to Python's default `Python-urllib` user agent, so it
sends a real one; and nodes with expiry disabled report no expiry date at
all, which is how the script tells them apart.

**`n8n-tailscale-key-expiry.json`** — the same check as an
[n8n](https://n8n.io) workflow. Daily, high-priority alert inside the
warning window, plus a low-key all-clear one day a week, so silence on that
day means the workflow itself broke rather than everything being fine.
Fill the `REPLACE_WITH_…` placeholders in n8n, not in the file. Set the
container's `GENERIC_TIMEZONE`, or the schedule runs on UTC.

**`ts-netcheck.sh`** — capture a Mac's routes, DNS resolvers and
connectivity *while* Tailscale is connected, for diagnosing "my internet
dies when Tailscale is on". Run it during the problem; it needs no working
internet and writes a single text file.

## clipboard/

Clipboard sync between a Mac and a Wayland Linux machine (Hyprland/`wl-clipboard`)
over Tailscale. Both directions are triggered from the Mac, so the Linux box
never needs a way into it.

- **`omarchy-clip-setup.sh`** — run once on the Linux machine, inside the
  desktop session. Paste your Mac's public key into `PUBKEY` first. It
  installs `clipd`, a forced command pinned to that key accepting only
  `copy` and `paste`, so the key can never open a shell even if it leaks.
- **`clip-to-omarchy`** / **`clip-from-omarchy`** — put in `~/.local/bin`
  and bind to hotkeys with the Shortcuts app. `clip-to-omarchy` works as a
  Quick Action: it sends the selected text, falling back to the clipboard.
  Set its Receive type to **Text only**, or with nothing selected macOS
  passes the frontmost *app* and you send its path.

Both refuse to send empty content, so an image on the clipboard can't blank
the other machine's, and they report results as notifications with a short
preview. Clipboard text is passed to AppleScript as an argument, never
spliced into the script source, so quotes or AppleScript syntax in what you
copied can't break or hijack the call.

Needs an SSH config entry on the Mac:

```
Host omarchy-clip
  HostName <linux tailnet IP>
  User <linux user>
  IdentityFile ~/.ssh/omarchy_clip
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 5
  RequestTTY no
```

## rustdesk/

**`com.local.rustdesk-server.plist`** — a launchd agent that keeps
RustDesk's background server running, so a Mac stays reachable over the
tailnet on port 21118 without the app window open.

```sh
cp rustdesk/com.local.rustdesk-server.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.rustdesk-server.plist
```

Pairs with RustDesk's **direct IP access over a tailnet and no ID server**:
peers connect to `100.x.y.z` directly, so no rendezvous or relay server is
involved. Set the ID and relay servers to `127.0.0.1` rather than leaving
them blank — blank silently falls back to RustDesk's public servers. The
status dot then never turns green, which is expected and doesn't affect
direct connections.

It's a user agent, so it runs only while you're logged in; reaching the Mac
from the login screen would need RustDesk's system service, which requires
admin rights and is often blocked on managed machines.

## License

MIT
