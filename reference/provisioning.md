# What provisioning creates

Everything the script makes on a fresh host, and why. Read this before running
it against a box that already serves traffic.

## Layout

```
/opt/<app>
├── current -> releases/<rev>   # what the service runs
├── releases/
│   ├── <rev>/                  # one uploaded bundle
│   └── <older>/                # kept for rollback
└── shared/
    └── .env                    # mode 600, outlives every release
```

**`current` is a symlink, and that is the whole design.** The unit's
`WorkingDirectory` points at it; systemd resolves it when the service starts.
Deploying is repointing it and restarting. Rolling back is repointing it the
other way. Both are atomic and take milliseconds, so a bad release costs a
restart rather than a rebuild.

The swap is done as `ln -sfn` to a temp name followed by `mv -Tf`, because
`ln -sfn` onto an existing symlink-to-a-directory can create the link *inside*
the target instead of replacing it. `mv -Tf` is atomic and has no such edge.

`shared/` exists so a deploy never has to recreate configuration. The
environment file is written once and outlives every release.

## The service account

A system user named after the app: no login shell, no password, home set to the
app directory.

```bash
useradd --system --home-dir /opt/<app> --shell /usr/sbin/nologin <app>
```

Not root, and not the SSH user. If the app is compromised, the blast radius
should be the app's own files.

## The systemd unit

```ini
[Service]
User=<app>
WorkingDirectory=/opt/<app>/current
EnvironmentFile=/opt/<app>/shared/.env
ExecStart=<start command>
Restart=always
RestartSec=3
```

`Restart=always` covers crashes; `WantedBy=multi-user.target` with
`systemctl enable` covers reboots. **Both are needed** — a service that survives
crashes but not reboots looks fine until the host restarts at 3am.

The hardening block is not decoration on a shared box:

| Directive | Effect |
| --- | --- |
| `ProtectSystem=strict` | Whole filesystem read-only, including `/opt/<app>` |
| `ProtectHome=true` | No access to `/home`, `/root` |
| `PrivateTmp=true` | Its own `/tmp`, invisible to other services |
| `NoNewPrivileges=true` | Cannot gain privileges via setuid |
| `MemoryMax=512M` | A leak here cannot starve neighbours |

`ProtectSystem=strict` means **the app cannot write anywhere**. If it needs to
(uploads, caches, SQLite), add an explicit `ReadWritePaths=/opt/<app>/shared/data`
and put it under `shared/` so it survives releases. Raise `MemoryMax` if the app
legitimately needs more — but set it, so one service cannot take the host down.

## Caddy

One block appended to `/etc/caddy/Caddyfile`:

```caddyfile
api.example.com {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3100
}
```

TLS is automatic: Caddy obtains and renews the certificate, redirects HTTP to
HTTPS, and serves HTTP/2.

**That file may already route other people's production traffic.** So: back it
up, append, `caddy validate`, and only then `systemctl reload caddy` — restoring
the backup if validation fails. `reload` is graceful and keeps existing
connections; `restart` drops every site on the box, not just yours.

## What it deliberately does not do

**Install system packages.** Adding a third-party apt repository and installing
from it as root changes a machine in ways the owner should agree to. The script
reports the missing runtime and stops.

**Create the environment file.** It holds real secrets. An invented value fails
at boot anyway, usually with a message that sends you looking in the wrong
place.

**Touch DNS.** It cannot know the provider or hold the credentials. See
`dns.md`.

**Open firewall ports.** Only 80 and 443 need to be reachable, and those are
usually already open. The app's port stays on loopback deliberately.

## Verifying a provision

```bash
ssh <target> '
  id <app>
  ls -la /opt/<app>
  readlink -f /opt/<app>/current
  sudo ls -l /opt/<app>/shared/.env          # must be 600, owned by <app>
  systemctl is-active <app>; systemctl is-enabled <app>
  sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
'
```

Then the two that only matter later: reboot survival (`is-enabled` → `enabled`)
and rollback. Exercise the rollback between two known-good releases so it costs
nothing, and do it *before* you need it.
