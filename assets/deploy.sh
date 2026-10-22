#!/usr/bin/env bash
#
# Provisions a VPS if it has never been deployed to, then deploys to it.
# Same command either way.
#
#   ./scripts/deploy.sh              # build and deploy the current tree
#   ./scripts/deploy.sh --migrate    # run MIGRATE_CMD before the restart
#
# Runs from a workstation or CI, never on the server: a small box has under a
# gigabyte of free memory and usually shares it with things already serving
# traffic. Only the built artifact travels.
#
# The ssh account needs passwordless sudo. The upload runs rsync under sudo,
# and rsync has no terminal to type a password into.
#
# ---------------------------------------------------------------------------
# CONFIG — fill this in. Every value can be overridden from the environment,
# so one script serves staging and production.
# ---------------------------------------------------------------------------

# Short name. Becomes the service unit, the system user, and /opt/<APP>.
APP="${VPS_APP:-myapp}"

# ssh target. The account needs passwordless sudo. Key auth strongly preferred.
HOST="${VPS_HOST:-deploy@203.0.113.10}"

# Public hostname. Drives the Caddy vhost AND the final health check, so a
# deploy to a different host can never be confirmed by the old host answering.
DOMAIN="${VPS_DOMAIN:-api.example.com}"

# Loopback port. Must be free on the host — check before choosing.
PORT="${VPS_PORT:-3100}"

# Produces BUNDLE_DIR locally.
BUILD_CMD="${VPS_BUILD_CMD:-pnpm build}"

# The directory that gets uploaded. Its *contents* become the release, so the
# entry point sits at the release root. Must run with only the runtime
# present: no dependency installation happens on the server.
BUNDLE_DIR="${VPS_BUNDLE_DIR:-dist}"

# What systemd runs, from inside the release directory. The executable must be
# an absolute path — systemd refuses "./app" — so a binary that ships inside
# the release is /opt/<APP>/current/<name>.
START_CMD="${VPS_START_CMD:-/usr/bin/node index.js}"

# Optional: applied with --migrate, before the restart, in the new release.
MIGRATE_CMD="${VPS_MIGRATE_CMD:-}"

# Binary that must exist on the host for START_CMD to work.
RUNTIME_BIN="${VPS_RUNTIME_BIN:-node}"

# Local file seeding the remote environment on FIRST provision only. Never
# committed, never overwritten on later deploys — push-env.sh does that.
ENV_FILE="${VPS_ENV_FILE:-.env.production}"

# Env keys that must be present in ENV_FILE. Space separated; may be empty.
REQUIRED_ENV="${VPS_REQUIRED_ENV:-}"

# Path the health check requests.
HEALTH_PATH="${VPS_HEALTH_PATH:-/}"

# Releases kept on disk for rollback.
KEEP="${VPS_KEEP:-5}"

# ---------------------------------------------------------------------------

set -euo pipefail

APP_DIR="/opt/$APP"
MIGRATE=no
[ "${1:-}" = "--migrate" ] && MIGRATE=yes

cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config sanity. These values are spliced into commands that run as root on
# the host, so anything that is not plain is rejected here, where the message
# can say what is wrong.
# ---------------------------------------------------------------------------
[[ "$APP" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "APP must be a plain lowercase name, got '$APP'"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]  || die "DOMAIN must be a hostname, got '$DOMAIN'"
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "PORT must be 1-65535, got '$PORT'"
[[ "$KEEP" =~ ^[0-9]+$ ]]            || die "KEEP must be a number, got '$KEEP'"
case "$HEALTH_PATH" in
	/*) ;;
	*)  die "HEALTH_PATH must start with /, got '$HEALTH_PATH'" ;;
esac
[[ "$HEALTH_PATH" != *[[:space:]\'\"]* ]] || die "HEALTH_PATH cannot contain spaces or quotes, got '$HEALTH_PATH'"
[[ "$MIGRATE_CMD" != *[\'\"]* ]]            || die "MIGRATE_CMD cannot contain quotes"

# systemd rejects a relative ExecStart outright, with an error that only shows
# up in the journal after the restart. Catch it before anything is uploaded.
EXEC_BIN="${START_CMD%% *}"
case "$EXEC_BIN" in
	/*) ;;
	*)  die "START_CMD must begin with an absolute path; systemd refuses '$EXEC_BIN'.
   A binary that ships inside the release is $APP_DIR/current/<name>." ;;
esac
# A binary inside the release does not exist until the release is uploaded,
# so only an interpreter installed on the host can be checked ahead of time.
case "$EXEC_BIN" in
	"$APP_DIR"/*) CHECK_EXEC=no ;;
	*)            CHECK_EXEC=yes ;;
esac

# ---------------------------------------------------------------------------
# Preflight. One round trip that reports what the host already has; everything
# below keys off it, so a provisioned host does no setup work.
# ---------------------------------------------------------------------------
say "inspecting $HOST"

STATE="$(ssh "$HOST" "
	printf 'sudo=%s\n'     \"\$(sudo -n true 2>/dev/null && echo yes || echo no)\"
	printf 'runtime=%s\n'  \"\$(command -v $RUNTIME_BIN || true)\"
	printf 'exec=%s\n'     \"\$([ $CHECK_EXEC = no ] || [ -x '$EXEC_BIN' ] && echo yes || echo no)\"
	printf 'curl=%s\n'     \"\$(command -v curl || true)\"
	printf 'rsync=%s\n'    \"\$(command -v rsync || true)\"
	printf 'caddy=%s\n'    \"\$(command -v caddy || true)\"
	printf 'user=%s\n'     \"\$(id -u $APP >/dev/null 2>&1 && echo yes || echo no)\"
	printf 'layout=%s\n'   \"\$(sudo -n test -d $APP_DIR/releases && sudo -n test -d $APP_DIR/shared && echo yes || echo no)\"
	printf 'env=%s\n'      \"\$(sudo -n test -f $APP_DIR/shared/.env && echo yes || echo no)\"
	printf 'unit=%s\n'     \"\$([ -f /etc/systemd/system/$APP.service ] && echo yes || echo no)\"
	printf 'live=%s\n'     \"\$(sudo -n readlink -e $APP_DIR/current 2>/dev/null || true)\"
	printf 'vhost=%s\n'    \"\$(sudo -n caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null | grep -qsF '\"$DOMAIN\"' && echo yes || echo no)\"
	printf 'portfree=%s\n' \"\$(if out=\$(sudo -n ss -tlnH 'sport = :$PORT' 2>/dev/null); then [ -n \"\$out\" ] && echo no || echo yes; else echo unknown; fi)\"
")"

get() { printf '%s\n' "$STATE" | sed -n "s/^$1=//p" | head -1; }

HAS_SUDO="$(get sudo)";     HAS_RUNTIME="$(get runtime)"; HAS_EXEC="$(get exec)"
HAS_CURL="$(get curl)";     HAS_RSYNC="$(get rsync)";     HAS_CADDY="$(get caddy)"
HAS_USER="$(get user)";     HAS_LAYOUT="$(get layout)";   HAS_ENV="$(get env)"
HAS_UNIT="$(get unit)";     LIVE="$(get live)";           HAS_VHOST="$(get vhost)"
PORT_FREE="$(get portfree)"

# Every other field is read through sudo, so without it they are all wrong.
[ "$HAS_SUDO" = yes ] || die "$HOST: sudo needs a password for this account, or is missing.
   Passwordless sudo is required — rsync runs under it and cannot prompt.
   On the host:  echo '<user> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/<user>"

printf '    runtime=%s caddy=%s user=%s layout=%s env=%s unit=%s vhost=%s port_%s_free=%s\n' \
	"${HAS_RUNTIME:-none}" "${HAS_CADDY:-none}" "$HAS_USER" "$HAS_LAYOUT" \
	"$HAS_ENV" "$HAS_UNIT" "$HAS_VHOST" "$PORT" "$PORT_FREE"
[ -z "$LIVE" ] || printf '    live=%s\n' "$LIVE"

[ -n "$HAS_RUNTIME" ] || die "$HOST has no '$RUNTIME_BIN'.
   Install it there, then re-run. Installing system packages on a box that may
   already be serving traffic is your call, not this script's."
[ "$HAS_EXEC" = yes ] || die "$HOST has nothing a non-root user can execute at $EXEC_BIN
   ('$RUNTIME_BIN' resolves to $HAS_RUNTIME for the ssh account).
   Point START_CMD at where the runtime actually lives on the host."
[ -n "$HAS_CURL" ]  || die "$HOST has no curl; the health check needs it. Install it there, then re-run."
[ -n "$HAS_RSYNC" ] || die "$HOST has no rsync; the upload needs it. Install it there, then re-run."

# Only a problem before the unit exists — afterwards the listener is us.
case "$PORT_FREE" in
	no) [ "$HAS_UNIT" = yes ] || die "port $PORT is already in use on $HOST by something else.
   Pick a free one: VPS_PORT=<port> $0" ;;
	unknown) warn "could not tell whether port $PORT is free on $HOST (ss failed); carrying on" ;;
esac

# ---------------------------------------------------------------------------
# Provision the parts that are ours. Each step is skipped when already present.
# ---------------------------------------------------------------------------
if [ "$HAS_USER" = no ] || [ "$HAS_LAYOUT" = no ]; then
	say "creating service account and layout"
	ssh "$HOST" "
		set -e
		id -u $APP >/dev/null 2>&1 || sudo -n useradd --system --home-dir $APP_DIR --shell /usr/sbin/nologin $APP
		sudo -n mkdir -p $APP_DIR/releases $APP_DIR/shared
		sudo -n chown -R $APP:$APP $APP_DIR
	"
fi

if [ "$HAS_ENV" = no ]; then
	# Never generated. It holds the real secrets, and an invented value would
	# fail at boot anyway.
	[ -f "$ENV_FILE" ] || die "$HOST has no $APP_DIR/shared/.env and there is no local $ENV_FILE to seed it from.
   Create $ENV_FILE with the production values, then re-run.
   It must not be committed — add it to .gitignore."

	for key in $REQUIRED_ENV; do
		grep -qE "^$key=." "$ENV_FILE" || die "$ENV_FILE is missing $key"
	done

	say "seeding $APP_DIR/shared/.env from $ENV_FILE"
	rsync -a --chmod=F600 --rsync-path="sudo -n rsync" "$ENV_FILE" "$HOST:$APP_DIR/shared/.env"
	ssh "$HOST" "sudo -n chown $APP:$APP $APP_DIR/shared/.env && sudo -n chmod 600 $APP_DIR/shared/.env"
fi

if [ "$HAS_UNIT" = no ]; then
	say "installing $APP.service"
	UNIT_TMP="$(mktemp)"
	cat > "$UNIT_TMP" <<-UNIT
		[Unit]
		Description=$APP
		After=network-online.target
		Wants=network-online.target

		[Service]
		# exec, not simple: a start fails right away when the executable is
		# missing, instead of reporting success and dying a moment later.
		Type=exec
		User=$APP
		Group=$APP
		# A symlink into releases/<rev>. systemd resolves it at start, so the
		# restart after the swap is what actually cuts over.
		WorkingDirectory=$APP_DIR/current
		EnvironmentFile=$APP_DIR/shared/.env
		ExecStart=$START_CMD
		Restart=always
		RestartSec=3
		SyslogIdentifier=$APP
		LimitNOFILE=65536

		# The host may run unrelated production workloads. Keep this boxed in.
		NoNewPrivileges=true
		PrivateTmp=true
		PrivateDevices=true
		ProtectSystem=strict
		ProtectHome=true
		ProtectKernelTunables=true
		ProtectKernelModules=true
		ProtectControlGroups=true
		ProtectClock=true
		RestrictSUIDSGID=true
		RestrictNamespaces=true
		RestrictRealtime=true
		RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
		CapabilityBoundingSet=
		SystemCallArchitectures=native
		LockPersonality=true
		MemoryMax=512M

		[Install]
		WantedBy=multi-user.target
	UNIT
	rsync -a --rsync-path="sudo -n rsync" "$UNIT_TMP" "$HOST:/etc/systemd/system/$APP.service"
	rm -f "$UNIT_TMP"
	# rsync -a kept the workstation's owner on the file. A unit that root loads
	# must belong to root, or whichever host account shares that uid could
	# edit it. Enabled but not started: there is no release to run yet.
	ssh "$HOST" "sudo -n chown root:root /etc/systemd/system/$APP.service && sudo -n chmod 644 /etc/systemd/system/$APP.service && sudo -n systemctl daemon-reload && sudo -n systemctl enable $APP >/dev/null 2>&1"
fi

# ---------------------------------------------------------------------------
# Build and ship. Identical whether the host was just provisioned or has been
# serving for months.
# ---------------------------------------------------------------------------
REV="$(git rev-parse --short HEAD 2>/dev/null || echo manual)"
if ! git diff --quiet HEAD 2>/dev/null; then
	# Otherwise two different builds land under one release name.
	REV="${REV}-dirty-$(date +%H%M%S)"
fi
if [ "$LIVE" = "$APP_DIR/releases/$REV" ]; then
	# Deploying the live revision again under the same name would delete the
	# directory the service is running from and leave nothing to roll back to.
	REV="${REV}-$(date +%H%M%S)"
fi

say "building $REV"
eval "$BUILD_CMD"
[ -d "$BUNDLE_DIR" ] || die "$BUILD_CMD did not produce $BUNDLE_DIR"
[ "$(cd "$BUNDLE_DIR" && pwd -P)" != "$(pwd -P)" ] || die "BUNDLE_DIR must be a build output directory, not the project root"

say "uploading to $HOST"
# Straight into the release tree, as root: no world-writable /tmp with a name
# anyone can predict from the git log, no tmpfs to fill, and promotion below
# is a rename on the same filesystem. o-rwx keeps the code from other accounts.
INCOMING="$APP_DIR/releases/.incoming-$REV"
rsync -az --delete --chmod=o-rwx --rsync-path="sudo -n rsync" "$BUNDLE_DIR/" "$HOST:$INCOMING/"

say "promoting $REV"
# -t so a migration that prints progress gets a terminal.
ssh -t "$HOST" "
set -euo pipefail
NEW=$APP_DIR/releases/$REV
LIVE=\$(sudo -n readlink -e $APP_DIR/current 2>/dev/null || true)

sudo -n rm -rf \$NEW
sudo -n mv $INCOMING \$NEW
sudo -n chown -R $APP:$APP \$NEW
# Stamp with the deploy time. rsync preserved the bundle's build time, and the
# prune below orders by mtime, so without this an incremental build could sort
# the live release as the oldest.
sudo -n touch \$NEW

if [ '$MIGRATE' = 'yes' ] && [ -n '$MIGRATE_CMD' ]; then
	echo '==> migrating'
	sudo -n systemd-run --uid=$APP --gid=$APP --pipe --wait --collect \
		--property=WorkingDirectory=\$NEW \
		--property=EnvironmentFile=$APP_DIR/shared/.env \
		$MIGRATE_CMD
fi

swap() {
	sudo -n ln -sfn \"\$1\" $APP_DIR/current.tmp
	sudo -n mv -Tf $APP_DIR/current.tmp $APP_DIR/current
	sudo -n chown -h $APP:$APP $APP_DIR/current
}
healthy() {
	for _ in \$(seq 1 \"\$1\"); do
		if systemctl is-active --quiet $APP && curl -fsS -m 3 'http://127.0.0.1:$PORT$HEALTH_PATH' >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	return 1
}

swap \"\$NEW\"
# A refused restart (start limit hit, unit rejected) must reach the rollback
# below rather than abort here, so its status is ignored; health decides.
sudo -n systemctl reset-failed $APP 2>/dev/null || true
sudo -n systemctl restart $APP || true

if ! healthy 30; then
	echo '!! health check failed; journal of the new release:'
	sudo -n journalctl -u $APP -n 40 --no-pager -o cat
	if [ -n \"\$LIVE\" ] && [ -d \"\$LIVE\" ] && [ \"\$LIVE\" != \"\$NEW\" ]; then
		echo \"!! rolling back to \$LIVE\"
		swap \"\$LIVE\"
		sudo -n systemctl reset-failed $APP 2>/dev/null || true
		sudo -n systemctl restart $APP || true
		if healthy 30; then
			echo \"==> \$LIVE is serving again\"
		else
			echo \"!! \$LIVE did not come back either; $APP is down\"
		fi
	else
		echo '!! nothing to roll back to; $APP is down'
	fi
	exit 1
fi

# Keep the newest releases by deploy time; rollback is then a symlink swap.
# The live release is never on the list.
( ls -1dt $APP_DIR/releases/*/ 2>/dev/null | grep -vxF \"\$NEW/\" || true ) | tail -n +$KEEP | sudo -n xargs -r rm -rf
sudo -n find $APP_DIR/releases -maxdepth 1 -name '.incoming-*' -mtime +1 -exec rm -rf {} +

echo \"==> \$(readlink -f $APP_DIR/current) is live on :$PORT\"
"

# ---------------------------------------------------------------------------
# Public routing. Added once, never by rewriting a shared file blind.
# ---------------------------------------------------------------------------
if [ "$HAS_VHOST" = no ]; then
	if [ -z "$HAS_CADDY" ]; then
		warn "$HOST has no caddy, so nothing serves $DOMAIN publicly."
		printf '   The app is healthy on 127.0.0.1:%s. Install Caddy and re-run,\n' "$PORT"
		printf '   or put your own reverse proxy in front of that port.\n'
	else
		say "adding the $DOMAIN vhost"
		ssh "$HOST" "
			set -e
			BAK=/etc/caddy/Caddyfile.bak-\$(date +%Y%m%d%H%M%S)
			if sudo -n test -f /etc/caddy/Caddyfile; then
				sudo -n cp -a /etc/caddy/Caddyfile \"\$BAK\"
			else
				sudo -n install -D -m 644 -o root -g root /dev/null /etc/caddy/Caddyfile
				BAK=
			fi
			printf '\n%s {\n    encode gzip zstd\n    reverse_proxy 127.0.0.1:%s\n}\n' '$DOMAIN' '$PORT' | sudo -n tee -a /etc/caddy/Caddyfile >/dev/null
			if out=\$(sudo -n caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
				if systemctl is-active --quiet caddy; then
					sudo -n systemctl reload caddy && echo 'caddy reloaded'
				else
					sudo -n systemctl enable --now caddy >/dev/null 2>&1 && echo 'caddy started'
				fi
			else
				echo '!! the Caddyfile does not validate with the new block; restoring the backup' >&2
				printf '%s\n' \"\$out\" >&2
				if [ -n \"\$BAK\" ]; then sudo -n cp -a \"\$BAK\" /etc/caddy/Caddyfile; else sudo -n rm -f /etc/caddy/Caddyfile; fi
				exit 1
			fi
		"
	fi
fi

# ---------------------------------------------------------------------------
# Verify the public URL. Derived from DOMAIN, never hardcoded, so a deploy to a
# new host cannot be confirmed by the old one answering. A vhost added seconds
# ago has no certificate yet — Caddy obtains one in the background, usually in
# well under a minute — so the first deploy gets more patience than a redeploy.
# ---------------------------------------------------------------------------
say "verifying https://$DOMAIN$HEALTH_PATH"
if [ "$HAS_VHOST" = no ]; then TRIES=18; else TRIES=3; fi
PUBLIC_OK=no
for i in $(seq 1 "$TRIES"); do
	if curl -fsS -m 20 -o /dev/null -w '    HTTP %{http_code} from %{remote_ip}\n' "https://$DOMAIN$HEALTH_PATH"; then
		PUBLIC_OK=yes
		break
	fi
	if [ "$i" -lt "$TRIES" ]; then
		printf '    not yet (%s/%s); waiting\n' "$i" "$TRIES"
		sleep 5
	fi
done

if [ "$PUBLIC_OK" = yes ]; then
	say "deployed $REV to $DOMAIN"
else
	warn "$DOMAIN did not answer over HTTPS."
	printf '   The app itself is healthy on the host, so this is DNS, TLS or routing.\n'
	[ -n "$HAS_CADDY" ] || printf '   %s has no caddy: nothing is serving the domain. Install it and re-run.\n' "$HOST"
	printf '   Check first:  dig +short %s A     -> must be this host\n' "$DOMAIN"
	printf '   If that shows Cloudflare addresses, the record is proxied (orange\n'
	printf '   cloud) and every ACME challenge will fail. Set it to DNS only.\n'
	printf '   Then:  ssh %s "sudo journalctl -u caddy -n 30 --no-pager | grep -i acme"\n' "$HOST"
	exit 1
fi
