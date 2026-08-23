# Runtimes

What to set for `BUILD_CMD`, `BUNDLE_DIR`, `START_CMD` and `RUNTIME_BIN`, and
the trap in each.

The rule underneath all of them: **whatever gets uploaded must run with only the
runtime present.** Nothing installs dependencies on the server.

## Verify the bundle before shipping it

Do this once per project, and again whenever dependencies change. It takes
seconds and catches the failures that otherwise appear as a boot loop on the
server, where they cost far more to diagnose.

```bash
cd <BUNDLE_DIR>
env $(grep -v '^#' ../.env.production | xargs) PORT=39999 <START_CMD>
# in another shell:
curl -fsS http://127.0.0.1:39999/
```

If it starts and answers here, it will start on the server. If it dies with a
missing module, you found it in the right place.

**Do not load the env file with `set -a; . .env`.** Values containing `&`, `|`
or `;` — which connection strings frequently do — are interpreted by the shell,
silently truncating the value. systemd's `EnvironmentFile` does no such parsing,
so the failure appears only in your test harness, and looks like the variable is
unset. Use `env $(grep -v '^#' file | xargs)` or export the keys individually.

## Node

```bash
BUILD_CMD="npm run build && node scripts/build-node-bundle.mjs"
BUNDLE_DIR="deploy-bundle"
START_CMD="/usr/bin/node dist/index.js"
RUNTIME_BIN="node"
```

`node_modules` has to travel. `assets/build-node-bundle.mjs` builds a
production-only tree by reading the bare imports back out of the built files and
resolving each to the version your lockfile picked.

**The trap: a bundler telling you a dependency is inlined does not mean it is
unnecessary.** A dependency left external can resolve its *own* driver at load
time, and nothing in your output names it. Two examples that cost real time:

- `drizzle-orm` stays external and imports `pg` itself. `pg` is an *optional*
  peer, so npm will not install it either. Result: `ERR_MODULE_NOT_FOUND:
  Cannot find package 'pg'` at boot, after a build that reported success.
- `prisma` needs its generated client and the platform-correct query engine
  binary in the bundle.

Anything reached only through an external package must be listed explicitly. The
local bundle test above is what surfaces it.

**In a monorepo,** dependencies resolve only from the workspace member that
declares them under pnpm's strict linking — a package belonging to
`packages/db` is not resolvable from `apps/server`. Resolve versions across
every workspace root, not just the app's.

**Do not build the production tree with a workspace filter.** Something like
`pnpm install --filter app... --prod --config.node-linker=hoisted` pulls in far
more than the bundle imports — hundreds of megabytes where tens will do. It is
fine inside a Docker layer that gets discarded; it is not fine over rsync.

## Bun

```bash
BUILD_CMD="bun build ./src/index.ts --target=bun --outdir=dist"
BUNDLE_DIR="dist"
START_CMD="/usr/local/bin/bun dist/index.js"
RUNTIME_BIN="bun"
```

Confirm where Bun actually lives: installed via the official script it lands in
`~/.bun/bin/bun`, which is **not on systemd's PATH** and may belong to another
user entirely. `ExecStart` needs the absolute path, and the service user must be
able to execute it. A bun installed under `/root` is unusable by a service
running as anyone else.

`bun build --compile` produces a single executable, which sidesteps this
neatly: `START_CMD="./myapp"`.

## Python

```bash
BUILD_CMD="python -m venv .venv-dist && .venv-dist/bin/pip install -r requirements.txt --target dist/deps && cp -r src dist/"
BUNDLE_DIR="dist"
START_CMD="/usr/bin/python3 -m gunicorn app:app --bind 127.0.0.1:3100"
RUNTIME_BIN="python3"
```

Python does not relocate cleanly. Two options that work:

1. **Build the virtualenv on the host once**, in `shared/`, outside the release
   directory, and point `START_CMD` at `/opt/<app>/shared/venv/bin/gunicorn`.
   Rebuild it only when requirements change. Note this contradicts "never build
   on the VPS" — it is the one justified exception, because a venv built
   elsewhere carries absolute paths.
2. **Ship a wheelhouse** and install from it offline on the host.

Anything with compiled extensions (`psycopg2`, `numpy`, `cryptography`) must be
built against the host's Python version and libc. Match them or use manylinux
wheels.

## Go

```bash
BUILD_CMD="CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/app ./cmd/server"
BUNDLE_DIR="dist"
START_CMD="./app"
RUNTIME_BIN="sh"
```

The easiest case: one static binary, no runtime to install. `RUNTIME_BIN=sh`
because the preflight wants *something* to check and there is no interpreter.

Match `GOARCH` to the host — `uname -m` on the server. `x86_64` is `amd64`,
`aarch64` is `arm64`. A wrong-architecture binary fails with a bare "Exec format
error" that explains nothing.

## Static sites

No systemd service at all. Upload the built files and let Caddy serve them:

```caddyfile
example.com {
    encode gzip zstd
    root * /opt/site/current
    file_server
    try_files {path} /index.html      # for SPA routing
}
```

Keep the same releases/`current` layout so rollback stays a symlink swap. Skip
the unit, the service user still owns the files, and Caddy needs read access.

## Choosing a port

Any free port above 1024. Check what is taken before choosing:

```bash
ssh <target> 'sudo ss -tlnp | awk "NR>1 {print \$4}" | sort -u'
```

**Do not assume 3000 is free.** On a box that already hosts anything it usually
is not, and the collision shows up as a service that starts, fails to bind, and
restarts forever — while the *other* app keeps answering on that port, so the
domain appears to work while serving the wrong thing.

Bind to `127.0.0.1`, never `0.0.0.0`, so the only public listener is Caddy. If
the framework binds all interfaces by default, a firewall rule is the fallback,
but binding correctly is better.
