# Secrets

The deployed app needs real credentials. Getting them onto the server without
leaving copies behind is a small amount of care that pays for itself.

## Rules

1. **Never commit the production environment file.** Add it to `.gitignore`
   before creating it, not after — `git rm --cached` leaves it in history, and
   history is what gets pushed.
2. **Never paste secrets into a chat, an issue, or a commit message.**
3. **Never put a secret on a command line.** Anyone on the host can read
   `/proc/<pid>/cmdline` while it runs. `DATABASE_URL=… node app.js` exposes it;
   an `EnvironmentFile` does not.
4. **Generate production values fresh.** Do not reuse the development secret.
   Sessions signed with a shared secret cross environments in ways nobody
   intended.
5. **Mode 600, owned by the service user.** Not world-readable, not group.

## Getting the file there

The deploy script rsyncs the local file to `shared/.env` on **first provision
only**, then chmods it 600 and never touches it again.

```bash
rsync -a --chmod=F600 --rsync-path="sudo rsync" .env.production <target>:/opt/<app>/shared/.env
ssh <target> 'sudo chown <app>:<app> /opt/<app>/shared/.env && sudo chmod 600 /opt/<app>/shared/.env'
```

Changing a value later is a deliberate act: edit it on the host and restart.

```bash
ssh -t <target> 'sudo -u <app> nano /opt/<app>/shared/.env && sudo systemctl restart <app>'
```

## Generating values

```bash
openssl rand -base64 32      # signing secrets, session keys
openssl rand -hex 32         # when the consumer wants hex
```

Anything with a minimum length has that minimum for a reason. Meet it.

## systemd's EnvironmentFile is not a shell

This is worth internalising, because the failure is silent and misleading.

`EnvironmentFile` parses `KEY=value` literally. No expansion, no quoting rules,
no command substitution. A value containing `&`, `|`, `;`, `$` or spaces arrives
intact — which is exactly what you want for connection strings like:

```
DATABASE_URL=postgresql://u:p@host/db?sslmode=verify-full&channel_binding=require
```

But **any script that loads the same file with `set -a; . .env` will mangle
it.** Bash reads `&` as a job-control operator and truncates the value there.
The variable then looks *unset* rather than wrong, sending you to look at the
wrong layer entirely.

For one-off commands needing the same environment, let systemd do the parsing:

```bash
sudo systemd-run --uid=<app> --gid=<app> --pipe --wait --collect \
  --property=WorkingDirectory=/opt/<app>/current \
  --property=EnvironmentFile=/opt/<app>/shared/.env \
  /usr/bin/node dist/migrate.js
```

This also keeps the credentials out of the process list, which
`DATABASE_URL=… node dist/migrate.js` would not.

## Rotating

1. Generate the new value.
2. Update `shared/.env` on the host.
3. `sudo systemctl restart <app>`.

Rotating a session-signing secret invalidates every existing session — everyone
is logged out. That is the intended effect; do it deliberately rather than
discovering it.

## If a secret leaks

Rotate it at the source first — the database, the provider, the auth system —
then update the host. Removing the file, or rewriting git history, does not
un-leak a credential that was pushed. Assume anything that reached a remote is
compromised and treat rotation as the fix.

## Checklist

- [ ] `.gitignore` covers the production env file
- [ ] `git log --all --full-history -- '*.env*'` shows nothing that matters
- [ ] Production secrets differ from development ones
- [ ] `shared/.env` is mode 600, owned by the service user
- [ ] No secret appears in any committed script, CI config, or `ExecStart`
