# Troubleshooting

Organised by what you observe.

## Start here

Establish which layer is broken before changing anything. These four commands
separate app, routing, TLS and DNS:

```bash
ssh <target> 'curl -sS -o /dev/null -w "app on loopback: %{http_code}\n" http://127.0.0.1:<port>/'
curl -sS -o /dev/null -w "public https:     %{http_code}\n" https://<domain>/
dig +short <domain> A
ssh <target> 'systemctl is-active <app>; sudo journalctl -u <app> -n 30 --no-pager -o cat'
```

- Loopback works, public fails → **routing, TLS or DNS**.
- Loopback fails → **the app**. The journal has the reason.

## The service will not stay up

```bash
ssh <target> 'sudo journalctl -u <app> -n 50 --no-pager -o cat'
```

**`ERR_MODULE_NOT_FOUND` / `ImportError` / `cannot find module`** — the bundle is
incomplete. Something is required at runtime that the build did not include,
often reached through an external dependency rather than named in your code. See
`runtimes.md`; reproduce it locally from the bundle directory alone.

**`status=203/EXEC`** — systemd could not execute `ExecStart`. The interpreter
path is wrong, or the binary is not executable, or it lives somewhere the
service user cannot read (`/root/.bun/bin/bun` is the classic). `ExecStart` needs
an absolute path.

**`status=200/CHDIR`** — `WorkingDirectory` does not exist. Usually `current`
points at a release that was pruned.

**`EADDRINUSE`** — something else holds the port.
`sudo ss -tlnp | grep :<port>`. Note the service may keep restarting while the
*other* process happily serves that port, so the domain appears to work but
returns the wrong app.

**Read-only filesystem** — `ProtectSystem=strict` is doing its job. Add
`ReadWritePaths=` for the directory the app needs, under `shared/`.

**Environment validation failure at boot** — a variable is missing or malformed.
Check what systemd actually loaded:

```bash
ssh <target> 'sudo systemctl show <app> -p Environment'
```

If a value looks truncated at a `&` or `;`, something parsed the env file with a
shell. systemd does not; whatever wrote the file did.

## Certificate will not issue

```bash
ssh <target> 'sudo journalctl -u caddy -n 50 --no-pager | grep -iE "acme|obtain|challenge"'
```

**`"Invalid response ... 404"` with a `104.*`, `172.67.*` or `2606:4700:*`
address** — the record is Cloudflare-proxied. That IP is the tell. See
`dns.md`; turn the proxy off.

**`"Cannot negotiate ALPN protocol acme-tls/1"`** — same cause, the other
challenge type.

**`"no such host"` / timeout** — the record does not exist or has not
propagated. `dig +short @1.1.1.1 <domain> A`.

**`"connection refused"`** — port 80 or 443 unreachable. Check the provider's
firewall *and* the host's: `sudo ufw status`.

**Rate limited** — Let's Encrypt allows 5 failures per hostname per hour. Fix
the cause, then wait; retrying immediately makes it worse. Caddy backs off on
its own and keeps trying for 30 days.

Once DNS is corrected, **do nothing**. Caddy retries automatically and the
certificate usually appears within a minute or two. A `curl` immediately after
the DNS change will still fail — check the log before concluding anything:

```bash
ssh <target> 'sudo journalctl -u caddy -f | grep -i acme'   # wait for "certificate obtained successfully"
```

## HTTPS works but returns the wrong thing

**502 Bad Gateway** — Caddy is up, the app is not answering on that port.
Check the app on loopback.

**A different site's content** — two vhosts claim the same hostname, or the port
in `reverse_proxy` belongs to another service. `sudo grep -n <domain> /etc/caddy/Caddyfile`.

**Redirect loop** — Cloudflare proxy in "Flexible" SSL mode talking HTTP to a
Caddy that redirects HTTP to HTTPS. Set Cloudflare to **Full (strict)**, or turn
the proxy off.

**CORS failures from the browser** — the app's allowed-origin setting does not
match the caller exactly. Scheme, host and port all count, and a trailing slash
breaks the match. Note that an allowed-origin header appearing on a response to
an unexpected origin is usually correct behaviour: the server states its one
allowed origin and the *browser* compares. Its presence is not proof the policy
is open.

## Deploy fails partway

**`mv: cannot move ... No such file or directory`** — `/opt/<app>/releases` does
not exist. Provisioning did not complete; re-run.

**`chown: invalid user`** — the service user was not created. Same cause.

**Permission denied on `/opt/<app>`** — the SSH account lacks sudo, or sudo
requires a password and no TTY was allocated. Use `ssh -t`.

**rsync "command not found"** — install rsync on the host.

**Health check fails and it rolls back** — working as designed. The journal
lines it printed are from the *new* release. The old one is serving again.

## Rollback

```bash
ssh <target> 'ls -1t /opt/<app>/releases'
ssh <target> 'sudo ln -sfn /opt/<app>/releases/<previous> /opt/<app>/current && sudo systemctl restart <app>'
```

A migration already applied is **not** undone by this. Rolling code back onto a
migrated database only works if the migration was backward-compatible — which is
an argument for making them so.

## Recovering the Caddyfile

The script backs it up before touching it:

```bash
ssh <target> 'ls -1t /etc/caddy/Caddyfile.bak-*'
ssh <target> 'sudo cp /etc/caddy/Caddyfile.bak-<stamp> /etc/caddy/Caddyfile && sudo systemctl reload caddy'
```

Always `caddy validate` before reloading. An invalid file plus a `restart` takes
down every site on the box.

## Host-level checks

```bash
ssh <target> 'df -h /; free -m; uptime'
ssh <target> 'sudo journalctl -u <app> --since "1 hour ago" | grep -ci "out of memory"'
```

A disk full of old releases or journals produces symptoms that look like
anything else. Releases are pruned to the last few; journals are not — `sudo
journalctl --vacuum-time=14d` if needed.
