---
name: vps-deploy
description: Put a web service on a plain VPS behind Caddy with HTTPS, in one command, and give the project a repeatable deploy afterwards. Use when the user wants to deploy, host, ship, or self-host a backend, API, or app on their own server or VPS (Hetzner, DigitalOcean, Linode, Vultr, EC2, a droplet, a box); when they ask to set up systemd, nginx or Caddy, a reverse proxy, a TLS or Let's Encrypt certificate, a custom API domain, zero-downtime releases, or rollback; when they ask why an ACME or certificate challenge is failing; or when they say "deploy this to my VPS", "host my backend", "make api.mydomain.com work", or run /vps-deploy.
---

# VPS deploy skill

Takes a service that runs locally and puts it on a VPS at `https://<domain>`, then
leaves the project with one command that redeploys it.

The end state:

- The app runs under **systemd** as a dedicated non-login user, restarted on
  failure and started on boot.
- **Caddy** terminates TLS and reverse-proxies to it on loopback. Certificates
  are issued and renewed automatically.
- Releases live in `/opt/<app>/releases/<rev>` with a `current` symlink. Deploy
  is a symlink swap plus a restart; **rollback is the same swap backwards**.
- A failed health check **rolls back automatically** — a bad build costs a
  restart, not an outage.
- `./scripts/deploy.sh` provisions a host that has never been deployed to, and
  deploys to one that has. Same command either way.
- `./scripts/push-env.sh` updates the production environment file on the host
  and restarts the service, restoring the previous file if it does not come
  back healthy. Secrets are edited locally, never over `ssh` + `nano`.

## The one rule that matters

**Never build on the VPS.** A small box has under a gigabyte of free memory and
usually shares it with things already serving traffic. Build on the workstation
or in CI, ship the artifact. Every step below assumes this.

## Phase 1 — collect what cannot be guessed

Ask for these together, in one message, and do not proceed without them. Never
invent a value here.

1. **SSH target** — `user@host`. The account needs passwordless `sudo`: the
   scripts run `rsync` under it, and rsync cannot prompt. Confirm it works:
   `ssh <target> 'echo ok; sudo -n true 2>&1 | head -1'`
2. **Domain** — the public hostname, e.g. `api.example.com`.
3. **DNS control** — who runs the zone, and whether they can give you an API
   token. See `reference/dns.md`. **This is the step most deployments die on.**
4. **Production environment values** — the real secrets. Read
   `reference/secrets.md` before touching these; they never enter the repo.

Then inspect the host once, before changing anything:

```bash
ssh <target> '
  echo "--- os ---";      . /etc/os-release && echo "$PRETTY_NAME"
  echo "--- memory ---";  free -m | awk "/Mem:/ {print \$7\" MB available\"}"
  echo "--- runtimes ---";for c in node bun python3 go docker caddy nginx; do printf "%-8s %s\n" "$c" "$(command -v $c || echo -)"; done
  echo "--- ports in use ---"; sudo ss -tlnp | awk "NR>1 {print \$4}" | sort -u
  echo "--- existing services ---"; systemctl list-units --type=service --state=running --no-legend | wc -l
'
```

Three things to take from that output:

- **Ports already taken.** Pick a free one for this app — 3100, 4000, 8090 are
  usually clear. Never assume 3000 is free; on a box that already hosts
  something, it usually is not.
- **Whether this box already serves production.** If it does, say so plainly
  before you change anything, and treat every shared file (`/etc/caddy/Caddyfile`
  above all) as something to back up and validate rather than overwrite.
- **Whether the runtime exists**, and at what version.

## Phase 2 — describe the project

Read the project to determine four things. Ask when the answer is not obvious;
guessing here produces a service that dies at boot.

| | What it means | Example |
| --- | --- | --- |
| `BUILD_CMD` | Produces the artifact locally | `pnpm build` |
| `BUNDLE_DIR` | The directory that gets uploaded | `dist/` |
| `START_CMD` | What systemd runs, from inside the release | `/usr/bin/node index.js` |
| `PORT` | Loopback port, free on the host | `3100` |

`reference/runtimes.md` covers Node, Bun, Python, Go, and static sites, and the
traps in each. Two that apply to all of them: `START_CMD` must begin with an
absolute path, because systemd refuses `./app`; and the *contents* of
`BUNDLE_DIR` become the release, so the entry point is addressed from the
release root — `index.js`, not `dist/index.js`.

**The bundle must be self-sufficient.** Whatever gets uploaded has to run with
only the runtime present — no `npm install` on the server. For Node that means
shipping `node_modules`, and `assets/build-node-bundle.mjs` builds a
production-only tree by reading the imports back out of the built files.

**Verify the artifact runs before shipping it.** Start it locally from the bundle
directory alone, with production-ish environment values, and curl its health
endpoint. This is the single highest-value check in the whole skill — it catches
a missing runtime dependency on the workstation, in seconds, instead of as a
boot loop on the server. `reference/runtimes.md` has the Node case, where a
transitively-required driver is invisible to the bundler and only shows up here.

## Phase 3 — DNS, before anything expects a certificate

Point the domain at the host and **verify it resolves** before Caddy tries to
issue a certificate. Read `reference/dns.md`.

The one that catches everyone: **a Cloudflare-proxied record (orange cloud)
makes every ACME challenge fail.** Let's Encrypt resolves the name to
Cloudflare, not the host, and both `http-01` and `tls-alpn-01` fail. The record
must be **DNS only / grey cloud**, at least until the certificate exists.

```bash
dig +short <domain> A     # must equal the VPS IP
```

If it shows Cloudflare addresses (`104.*`, `172.67.*`, `2606:4700:*`), stop and
fix the proxy setting. Do not continue and hope.

## Phase 4 — generate the deploy script

Copy `assets/deploy.sh` into the project as `scripts/deploy.sh`, fill in the
config block at the top with the values from Phases 1–3, and make it executable.

Do the same with `assets/push-env.sh` as `scripts/push-env.sh`. It takes the
same config block (`APP`, `HOST`, `PORT`, `ENV_FILE`, `REQUIRED_ENV`,
`HEALTH_PATH`), so fill it from the values you just used. It is how the user
changes a secret after the first deploy — see Phase 8.

Add script aliases to the project manifest. For Node, **use `deploy:server` or
similar, not `deploy`** — `pnpm deploy` is a built-in pnpm command that copies a
workspace package to a directory, so a script named `deploy` is shadowed by it
and silently does something else.

```json
{
  "scripts": {
    "deploy:server": "./scripts/deploy.sh",
    "deploy:env": "./scripts/push-env.sh"
  }
}
```

Commit both scripts, and for Node the `deploy-bundle-lock.json` the bundler
writes — it pins the bundle's full dependency tree. Never commit the
environment file.

## Phase 5 — run it

```bash
./scripts/deploy.sh
```

It inspects the host, provisions whatever is missing, then builds, uploads,
swaps the symlink, restarts, and health-checks. `reference/provisioning.md`
details each thing it creates and why.

Watch for the preflight line it prints. On a fresh host most fields read `no`;
on a provisioned one they all read `yes` and it goes straight to deploying.

## Phase 6 — verify honestly

Do not report success on the strength of the script exiting 0. Check:

```bash
curl -fsS https://<domain>/                      # TLS + routing + app
ssh <target> 'systemctl is-active <app>; systemctl is-enabled <app>'
ssh <target> 'readlink -f /opt/<app>/current'    # which release is live
ssh <target> 'sudo journalctl -u <app> -n 20 --no-pager'
```

Then confirm the parts that only matter later, because they are the ones nobody
notices until an outage:

- **Boot survival** — `systemctl is-enabled` must say `enabled`.
- **Rollback** — swap `current` to the previous release, confirm it answers,
  swap back. Do this between two *known-good* releases so it costs no downtime.
  A rollback path nobody has ever run is not a rollback path.

If anything fails, `reference/troubleshooting.md` is organised by symptom.

## Phase 7 — write it down

Leave a `DEPLOYMENT.md` in the project recording the host, the domain, the port
and **why that port**, the layout, the environment variables by name, the
redeploy command, the env-update command, and the rollback steps. Include whatever bit an outsider would
otherwise have to rediscover — the port collision, the DNS proxy setting, a
dependency the bundler hides.

## Phase 8 — changing the environment later

`deploy.sh` seeds `shared/.env` on first provision and never overwrites it, so a
redeploy cannot change a secret. When the user asks how to add or rotate a
value — a new origin in `CORS_ORIGINS`, a fresh signing key, a moved database —
the answer is: edit the local production env file, then

```bash
./scripts/push-env.sh        # or: pnpm deploy:env
```

It refuses if the file is tracked by git or missing a `REQUIRED_ENV` key, shows
which keys differ from the host **by name only** (no value is ever printed),
backs up the current file on the host, uploads, restarts, and health-checks.
If the service does not come back it restores the backup and restarts again, so
a typo in a connection string is a failed command, not downtime.

The local file is therefore the source of truth. Say so in `DEPLOYMENT.md`, and
never edit `shared/.env` directly on the host — the next push overwrites it.

Two things it deliberately does not do:

- **Ship code.** Env and code change on separate commands, so a config change
  never accidentally deploys half-finished work, and vice versa.
- **Print a value.** Even when a key is present on one side only, only the key
  name appears. `reference/secrets.md` explains why the values stay out of
  terminals and chat.

## Rules

- **Never build on the VPS.** Stated above; it is the one that gets ignored.
- **Never commit secrets.** `reference/secrets.md`.
- **Never overwrite a shared config without a backup and a validation step.**
  `/etc/caddy/Caddyfile` may already route other people's production traffic.
  Back up, append, `caddy validate`, then `reload` — restoring the backup if
  validation fails. `reload` is graceful; `restart` drops other sites.
- **Never install system packages silently on a box that is already serving.**
  Adding a third-party apt repository and installing from it as root is the
  user's call. Print the command and let them decide, or ask first.
- **Run the app as its own non-login user.** Never as root, never as the SSH
  user.
- **Report what you did not verify.** A fresh-host provision you could not test,
  a rollback branch you never triggered — say so.
