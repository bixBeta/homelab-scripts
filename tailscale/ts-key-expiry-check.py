#!/usr/bin/env python3
"""Warn via Slack when any Tailscale node's key is close to expiring.

Nodes with key expiry disabled are skipped -- they cannot expire.

Env:
  TS_CLIENT_ID      Tailscale OAuth client id      (required)
  TS_CLIENT_SECRET  Tailscale OAuth client secret  (required)
  ALERT_URL         Slack / Discord / ntfy URL     (required unless --dry-run)
  ALERT_TYPE        slack | discord | ntfy -- only needed when ALERT_URL's
                    host doesn't identify it (e.g. self-hosted ntfy)
  ALERT_MENTION     who to ping. A bare Discord user id (digits) is wrapped
                    as <@id>; anything else is used verbatim, so Slack's
                    <@U0123ABC> or <!subteam^...> work too. Ignored by ntfy,
                    which pushes unconditionally.
  TS_TAILNET        tailnet name, default "-" (the credential's own tailnet)
  WARN_DAYS         warn this many days ahead, default 7

Flags:
  --dry-run  print what would be sent, send nothing
  --all      tabulate every device, not just ones near expiry
  --report   send an all-clear digest even when nothing is expiring, so a
             weekly run proves the checker is still alive

Exit codes: 0 nothing to report or alert sent, 1 error.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API = "https://api.tailscale.com/api/v2"

# Discord sits behind Cloudflare, which 403s Python's default
# "Python-urllib/3.x" User-Agent before the request reaches the API.
USER_AGENT = "ts-key-expiry-check/1.0 (+homelab monitor)"


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def post_form(url, data):
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def get_json(url, token):
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def detect_alert_type(url):
    host = urllib.parse.urlparse(url).hostname or ""
    if "hooks.slack.com" in host:
        return "slack"
    if "discord.com" in host or "discordapp.com" in host:
        return "discord"
    if "ntfy" in host:
        return "ntfy"
    return None


def render_digest(healthy, disabled, total, alert_type):
    """All-clear heartbeat: short, so it reads on a lock screen.

    Its job is to prove the checker still runs -- silence for months is
    indistinguishable from a broken monitor.
    """
    bold = {"slack": "*", "discord": "**", "ntfy": ""}[alert_type]
    dated = sorted([h for h in healthy if h[1] is not None], key=lambda x: x[2])
    lines = [f"{bold}Tailscale keys: all clear{bold}"]
    if dated:
        name, expires, days, _ = dated[0]
        lines.append(f"Nearest: {name} in {days}d ({expires:%Y-%m-%d})")
    lines.append(f"{total} devices checked, {disabled} with expiry disabled")
    return "\n".join(lines)


def render(expired, expiring, alert_type):
    """Same content, per-service markup."""
    bold = {"slack": "*", "discord": "**", "ntfy": ""}[alert_type]
    lines = []
    for name, expires, days in expired:
        lines.append(f"EXPIRED {abs(days)}d ago: {bold}{name}{bold} ({expires:%Y-%m-%d})")
    for name, expires, days in expiring:
        when = "today" if days == 0 else f"in {days}d"
        lines.append(f"expires {when}: {bold}{name}{bold} ({expires:%Y-%m-%d})")
    body = "\n".join(lines)
    tail = "Re-authenticate the machine, or disable key expiry in the admin console."
    if alert_type == "ntfy":
        return f"Tailscale key expiry\n{body}\n{tail}"
    return f"{bold}Tailscale key expiry{bold}\n{body}\n_{tail}_"


def format_mention(raw):
    """Bare digits are a Discord user id; anything else is passed through."""
    if not raw:
        return ""
    raw = raw.strip()
    if raw.isdigit():
        return f"<@{raw}> "
    if not raw.startswith(("<", "@")):
        # A bare username posts as inert text and pings nobody.
        print(
            f"warning: ALERT_MENTION={raw!r} looks like a username, not a user id. "
            "Send '\\@name' in Discord to reveal the numeric id.",
            file=sys.stderr,
        )
    return f"{raw} "


def send(url, alert_type, text, mention=""):
    if alert_type == "ntfy":
        data, headers = text.encode(), {
            "Title": "Tailscale key expiry",
            "Priority": "high",
            "Tags": "warning",
        }
    else:
        key = "text" if alert_type == "slack" else "content"
        payload = {key: mention + text}
        if alert_type == "discord" and mention:
            # Without this, a webhook's mention can render but not ping.
            payload["allowed_mentions"] = {"parse": ["users", "roles"]}
        data = json.dumps(payload).encode()
        headers = {"Content-Type": "application/json"}
    headers["User-Agent"] = USER_AGENT
    req = urllib.request.Request(url, data=data, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in (200, 204):
            fail(f"{alert_type} returned HTTP {r.status}")


def tabulate(rows):
    """rows: (name, expires, days, status) -> aligned text table.

    Terminal and log only. Notification bodies stay unpadded because
    ntfy/Discord render in a proportional font, where padding is noise.
    """
    headers = ("MACHINE", "EXPIRES", "DAYS", "STATUS")
    body = [
        (name, f"{expires:%Y-%m-%d}", str(days), status)
        for name, expires, days, status in rows
    ]
    widths = [
        max(len(h), *(len(r[i]) for r in body)) for i, h in enumerate(headers)
    ]
    line = "  ".join("-" * w for w in widths).rstrip()
    out = ["  ".join(h.ljust(w) for h, w in zip(headers, widths)).rstrip(), line]
    for r in body:
        # Right-align DAYS; it's the column you scan.
        cells = [
            r[i].rjust(widths[i]) if i == 2 else r[i].ljust(widths[i])
            for i in range(4)
        ]
        out.append("  ".join(cells).rstrip())
    return "\n".join(out)


def parse_ts(value):
    """RFC3339 -> aware datetime, or None if absent/zero-valued."""
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    # Tailscale uses year 1 as the zero value for "no expiry".
    return dt if dt.year > 2000 else None


def main():
    dry_run = "--dry-run" in sys.argv
    show_all = "--all" in sys.argv
    report = "--report" in sys.argv

    client_id = os.environ.get("TS_CLIENT_ID")
    client_secret = os.environ.get("TS_CLIENT_SECRET")
    alert_url = os.environ.get("ALERT_URL")
    tailnet = os.environ.get("TS_TAILNET", "-")

    if not client_id or not client_secret:
        fail("TS_CLIENT_ID and TS_CLIENT_SECRET must be set")
    if not alert_url and not dry_run:
        fail("ALERT_URL must be set (or pass --dry-run)")

    alert_type = os.environ.get("ALERT_TYPE") or (
        detect_alert_type(alert_url) if alert_url else None
    )
    if alert_type is None and dry_run:
        # No URL to infer from -- say so rather than implying a service.
        print("note: ALERT_URL is not set, showing plain formatting", file=sys.stderr)
        alert_type = "ntfy"
    if alert_type not in ("slack", "discord", "ntfy"):
        fail(
            f"could not tell what {alert_url!r} is -- "
            "set ALERT_TYPE to slack, discord or ntfy"
        )

    try:
        warn_days = int(os.environ.get("WARN_DAYS", "7"))
    except ValueError:
        fail("WARN_DAYS must be an integer")

    try:
        token = post_form(
            f"{API}/oauth/token",
            {
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "client_credentials",
            },
        )["access_token"]
    except (urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
        fail(f"could not get an OAuth token: {e}")

    try:
        devices = get_json(f"{API}/tailnet/{tailnet}/devices", token)["devices"]
    except (urllib.error.URLError, KeyError, json.JSONDecodeError) as e:
        fail(f"could not list devices: {e}")

    now = datetime.now(timezone.utc)
    expiring, expired, healthy, disabled = [], [], [], 0

    for d in devices:
        name = d.get("name", d.get("hostname", d.get("id", "?"))).split(".")[0]
        if d.get("keyExpiryDisabled"):
            disabled += 1
            healthy.append((name, None, None, "expiry disabled"))
            continue
        expires = parse_ts(d.get("expires"))
        if expires is None:
            continue
        days = (expires - now).days
        if days < 0:
            expired.append((name, expires, days))
        elif days <= warn_days:
            expiring.append((name, expires, days))
        else:
            healthy.append((name, expires, days, "ok"))

    if show_all:
        rows = (
            [(n, e, d, "EXPIRED") for n, e, d in sorted(expired, key=lambda x: x[2])]
            + [(n, e, d, "expiring") for n, e, d in sorted(expiring, key=lambda x: x[2])]
            + sorted(
                [h for h in healthy if h[1] is not None], key=lambda x: x[2]
            )
        )
        print(tabulate(rows))
        for name, _, _, status in healthy:
            if status == "expiry disabled":
                print(f"{name}: expiry disabled, cannot expire")

    if not expiring and not expired:
        print(
            f"ok: no keys expiring within {warn_days} days "
            f"({len(devices)} devices checked, {disabled} with expiry disabled)"
        )
        if not report:
            return
        text = render_digest(healthy, disabled, len(devices), alert_type)
        if dry_run:
            print(f"[{alert_type}]\n{text}")
            return
        try:
            send(alert_url, alert_type, text)
        except urllib.error.URLError as e:
            fail(f"could not post to {alert_type}: {e}")
        print(f"sent all-clear digest via {alert_type}")
        return

    print(tabulate(
        [(n, e, d, "EXPIRED") for n, e, d in sorted(expired, key=lambda x: x[2])]
        + [(n, e, d, "expiring") for n, e, d in sorted(expiring, key=lambda x: x[2])]
    ))

    expired.sort(key=lambda x: x[2])
    expiring.sort(key=lambda x: x[2])
    text = render(expired, expiring, alert_type)
    mention = "" if alert_type == "ntfy" else format_mention(os.environ.get("ALERT_MENTION"))

    if dry_run:
        print(f"[{alert_type}]\n{mention}{text}")
        return

    try:
        send(alert_url, alert_type, text, mention)
    except urllib.error.URLError as e:
        fail(f"could not post to {alert_type}: {e}")

    print(f"alerted on {len(expiring) + len(expired)} device(s) via {alert_type}")


if __name__ == "__main__":
    main()
