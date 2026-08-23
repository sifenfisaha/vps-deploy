# vps-deploy

A [Claude Code](https://claude.com/claude-code) skill that puts a web service on
a plain VPS behind HTTPS, and leaves the project with one command that redeploys
it.

No Docker, no Kubernetes, no platform. A systemd unit, a Caddy vhost, and a
symlink.

```
/vps-deploy
```

Answer a few questions about your server and domain, and you get a running
service at `https://api.example.com`. Afterwards:

```bash
./scripts/deploy.sh          # build, ship, swap, restart, verify
```

## What you end up with

| | |
| --- | --- |
| **Process** | systemd unit, dedicated non-login user, restarts on failure, starts on boot |
| **TLS** | Caddy, certificate issued and renewed automatically |
| **Releases** | `/opt/<app>/releases/<git-sha>` with a `current` symlink |
| **Deploy** | Symlink swap plus a restart — milliseconds, not a rebuild |
| **Rollback** | The same swap, backwards |
| **Safety** | Failed health check rolls back automatically |
| **Isolation** | Hardened unit: read-only filesystem, private `/tmp`, memory cap |

```
/opt/myapp
├── current -> releases/a1b2c3d     # what systemd runs
├── releases/
│   ├── a1b2c3d/                    # this deploy
│   └── 9f8e7d6/                    # previous, one symlink away
└── shared/
    └── .env                        # mode 600, outlives every release
```

## Install

```bash
git clone https://github.com/sifenfisaha/vps-deploy.git ~/.claude/skills/vps-deploy
```

Then `/vps-deploy` in any project. For one project only, clone into
`.claude/skills/vps-deploy` inside that repo instead.

Update with `git -C ~/.claude/skills/vps-deploy pull`.

## What it asks you for

Four things it cannot work out on its own, and won't guess:

1. **SSH target** — `user@host`, with sudo.
2. **Domain** — the hostname to serve.
3. **DNS access** — who runs the zone. A Cloudflare API token lets it set the
   record for you; otherwise it tells you exactly what to create.
4. **Production secrets** — database URL, signing keys. These go straight to the
   server's environment file and never near the repo.

Everything else it reads from the project or the host: runtime and version,
which ports are already taken, whether Caddy is installed, whether the box
already runs something in production.

## What it does

1. **Inspects the host** — one round trip: OS, memory, runtimes, ports in use,
   existing services. If the box already serves production, it says so before
   changing anything.
2. **Works out how to build and start your app** — from `package.json`, a
   `Dockerfile`, `go.mod`, `requirements.txt`, or by asking.
3. **Sets up DNS** — or verifies it, and refuses to continue while the record
   points somewhere that will make certificate issuance fail.
4. **Writes `scripts/deploy.sh`** into your project, configured for it.
5. **Provisions the host** — service account, release layout, environment file,
   systemd unit, Caddy vhost. Only what's missing.
6. **Deploys and verifies** — build, upload, swap, restart, health check, then
   checks the public URL actually answers.

Run `./scripts/deploy.sh` again any time. It inspects first, so a provisioned
host skips straight to deploying.

## What it deliberately won't do

- **Build on the VPS.** A small box has under a gigabyte free and usually shares
  it with something already serving traffic. Builds happen on your machine; only
  the artifact travels.
- **Install system packages silently.** Adding a third-party apt repository and
  installing from it as root is your call. It tells you the command.
- **Invent secrets.** A generated database URL fails at boot and sends you
  looking in the wrong place.
- **Overwrite a shared config blind.** `/etc/caddy/Caddyfile` may route other
  people's traffic. Back up, append, validate, reload — restore on failure.
  `reload` is graceful; `restart` would drop every site on the box.
- **Claim success it didn't verify.** A fresh-host provision it couldn't test, a
  rollback branch it never triggered — it says so.

## Runtimes

Node, Bun, Python, Go, and static sites. See
[`reference/runtimes.md`](reference/runtimes.md) for the settings and the trap in
each — the Bun binary systemd can't see, Python virtualenvs that don't relocate,
Go's architecture mismatch, and the Node dependency no bundler will tell you
about.

## The DNS thing

The most common reason a first deployment stalls, and worth knowing before you
start: **a Cloudflare-proxied record makes every certificate request fail.**

With the orange cloud on, Let's Encrypt resolves your domain to Cloudflare
rather than your server. `http-01` gets a 404 from Cloudflare's edge;
`tls-alpn-01` can't negotiate through it. Both fail, and the error names a
Cloudflare IP — `104.*`, `172.67.*`, `2606:4700:*` — which is the tell.

Set the record to **DNS only** (grey cloud). Caddy retries for 30 days, so
fixing it afterwards needs no further action — the certificate appears a minute
or two later.

[`reference/dns.md`](reference/dns.md) covers this, the Cloudflare API calls to
automate the record, other providers, and IPv6.

## Contents

| File | |
| --- | --- |
| [`SKILL.md`](SKILL.md) | The procedure Claude follows |
| [`assets/deploy.sh`](assets/deploy.sh) | Provision-or-deploy script, templated per project |
| [`assets/build-node-bundle.mjs`](assets/build-node-bundle.mjs) | Builds a self-sufficient Node bundle |
| [`reference/dns.md`](reference/dns.md) | Records, the proxy trap, provider APIs |
| [`reference/runtimes.md`](reference/runtimes.md) | Per-runtime settings and traps |
| [`reference/provisioning.md`](reference/provisioning.md) | Everything created on the host, and why |
| [`reference/secrets.md`](reference/secrets.md) | Getting credentials there safely |
| [`reference/troubleshooting.md`](reference/troubleshooting.md) | Organised by symptom |

## Using the script without the skill

`assets/deploy.sh` stands alone. Copy it to `scripts/deploy.sh`, fill in the
config block at the top, make it executable:

```bash
APP="myapp"
HOST="deploy@203.0.113.10"
DOMAIN="api.example.com"
PORT="3100"
BUILD_CMD="npm run build"
BUNDLE_DIR="dist"
START_CMD="/usr/bin/node index.js"
```

Every value also reads from the environment (`VPS_APP`, `VPS_HOST`, …), so one
script serves staging and production.

## Requirements

**Workstation:** bash, ssh, rsync, git, and your project's build toolchain.

**Server:** any systemd Linux (Debian/Ubuntu tested), an account with sudo, your
app's runtime, and Caddy for TLS. Ports 80 and 443 reachable.

## Scope

Single host, single instance. That covers a great many services, and the
scheduler-style caveats of running two copies are real — background jobs that
tick in every process will double-run without a lock. When you outgrow it, the
release layout maps cleanly onto something bigger.

## Licence

MIT.
