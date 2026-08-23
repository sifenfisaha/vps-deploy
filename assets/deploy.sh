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
# ---------------------------------------------------------------------------
# CONFIG — fill this in. Every value can be overridden from the environment,
# so one script serves staging and production.
# ---------------------------------------------------------------------------

# Short name. Becomes the service unit, the system user, and /opt/<APP>.
APP="${VPS_APP:-myapp}"

# ssh target. The account needs sudo. Key auth strongly preferred.
HOST="${VPS_HOST:-deploy@203.0.113.10}"

# Public hostname. Drives the Caddy vhost AND the final health check, so a
# deploy to a different host can never be confirmed by the old host answering.
DOMAIN="${VPS_DOMAIN:-api.example.com}"

# Loopback port. Must be free on the host — check before choosing.
PORT="${VPS_PORT:-3100}"

# Produces BUNDLE_DIR locally.
BUILD_CMD="${VPS_BUILD_CMD:-pnpm build}"

# The directory that gets uploaded. Must run with only the runtime present:
# no dependency installation happens on the server.
BUNDLE_DIR="${VPS_BUNDLE_DIR:-dist}"

# What systemd runs, relative to the release directory. Absolute interpreter.
START_CMD="${VPS_START_CMD:-/usr/bin/node index.js}"

# Optional: applied with --migrate, before the restart, in the new release.
MIGRATE_CMD="${VPS_MIGRATE_CMD:-}"

# Binary that must exist on the host for START_CMD to work.
RUNTIME_BIN="${VPS_RUNTIME_BIN:-node}"

# Local file seeding the remote environment on FIRST provision only. Never
# committed, never overwritten on later deploys.
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
# Preflight. One round trip that reports what the host already has; everything
# below keys off it, so a provisioned host does no setup work.
# ---------------------------------------------------------------------------
say "inspecting $HOST"

STATE="$(ssh "$HOST" "
	printf 'runtime=%s\n' \"\$(command -v $RUNTIME_BIN || true)\"
	printf 'caddy=%s\n'   \"\$(command -v caddy || true)\"
	printf 'user=%s\n'    \"\$(id -u $APP >/dev/null 2>&1 && echo yes || echo no)\"
	printf 'layout=%s\n'  \"\$([ -d $APP_DIR/releases ] && [ -d $APP_DIR/shared ] && echo yes || echo no)\"
	printf 'env=%s\n'     \"\$(sudo test -f $APP_DIR/shared/.env && echo yes || echo no)\"
	printf 'unit=%s\n'    \"\$([ -f /etc/systemd/system/$APP.service ] && echo yes || echo no)\"
	printf 'vhost=%s\n'   \"\$(sudo grep -qs '^$DOMAIN' /etc/caddy/Caddyfile && echo yes || echo no)\"
	printf 'portfree=%s\n' \"\$(sudo ss -tlnH \"sport = :$PORT\" 2>/dev/null | grep -q . && echo no || echo yes)\"
")"

get() { printf '%s\n' "$STATE" | sed -n "s/^$1=//p" | head -1; }

HAS_RUNTIME="$(get runtime)"; HAS_CADDY="$(get caddy)"; HAS_USER="$(get user)"
HAS_LAYOUT="$(get layout)";   HAS_ENV="$(get env)";     HAS_UNIT="$(get unit)"
HAS_VHOST="$(get vhost)";     PORT_FREE="$(get portfree)"

printf '    runtime=%s caddy=%s user=%s layout=%s env=%s unit=%s vhost=%s port_%s_free=%s\n' \
	"${HAS_RUNTIME:-none}" "${HAS_CADDY:-none}" "$HAS_USER" "$HAS_LAYOUT" \
	"$HAS_ENV" "$HAS_UNIT" "$HAS_VHOST" "$PORT" "$PORT_FREE"

[ -n "$HAS_RUNTIME" ] || die "$HOST has no '$RUNTIME_BIN'.
   Install it there, then re-run. Installing system packages on a box that may
   already be serving traffic is your call, not this script's."

# Only a problem before the unit exists — afterwards the listener is us.
if [ "$PORT_FREE" = no ] && [ "$HAS_UNIT" = no ]; then
	die "port $PORT is already in use on $HOST by something else.
   Pick a free one: VPS_PORT=<port> $0"
fi

# ---------------------------------------------------------------------------
# Provision the parts that are ours. Each step is skipped when already present.
# ---------------------------------------------------------------------------
if [ "$HAS_USER" = no ] || [ "$HAS_LAYOUT" = no ]; then
	say "creating service account and layout"
	ssh -t "$HOST" "
		set -e
		id -u $APP >/dev/null 2>&1 || sudo useradd --system --home-dir $APP_DIR --shell /usr/sbin/nologin $APP
		sudo mkdir -p $APP_DIR/releases $APP_DIR/shared
		sudo chown -R $APP:$APP $APP_DIR
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
	rsync -a --chmod=F600 --rsync-path="sudo rsync" "$ENV_FILE" "$HOST:$APP_DIR/shared/.env"
	ssh "$HOST" "sudo chown $APP:$APP $APP_DIR/shared/.env && sudo chmod 600 $APP_DIR/shared/.env"
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
		Type=simple
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

		# The host may run unrelated production workloads. Keep this boxed in.
		NoNewPrivileges=true
		PrivateTmp=true
		ProtectSystem=strict
		ProtectHome=true
		ProtectKernelTunables=true
		ProtectKernelModules=true
		ProtectControlGroups=true
		RestrictSUIDSGID=true
		LockPersonality=true
		MemoryMax=512M

		[Install]
		WantedBy=multi-user.target
	UNIT
	rsync -a --rsync-path="sudo rsync" "$UNIT_TMP" "$HOST:/etc/systemd/system/$APP.service"
	rm -f "$UNIT_TMP"
	# Enabled but not started: there is no release to run until the deploy below.
	ssh "$HOST" "sudo chmod 644 /etc/systemd/system/$APP.service && sudo systemctl daemon-reload && sudo systemctl enable $APP >/dev/null"
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

say "building $REV"
eval "$BUILD_CMD"
[ -d "$BUNDLE_DIR" ] || die "$BUILD_CMD did not produce $BUNDLE_DIR"

say "uploading to $HOST"
rsync -az --delete "$BUNDLE_DIR/" "$HOST:/tmp/$APP-$REV/"

say "promoting $REV"
# -t so sudo can prompt when the account is not passwordless.
ssh -t "$HOST" "
set -euo pipefail

PREV=\$(readlink -f $APP_DIR/current 2>/dev/null || true)

sudo rm -rf $APP_DIR/releases/$REV
sudo mv /tmp/$APP-$REV $APP_DIR/releases/$REV
sudo chown -R $APP:$APP $APP_DIR/releases/$REV

if [ '$MIGRATE' = 'yes' ] && [ -n '$MIGRATE_CMD' ]; then
	echo '==> migrating'
	sudo systemd-run --uid=$APP --gid=$APP --pipe --wait --collect \
		--property=WorkingDirectory=$APP_DIR/releases/$REV \
		--property=EnvironmentFile=$APP_DIR/shared/.env \
		$MIGRATE_CMD
fi

sudo ln -sfn $APP_DIR/releases/$REV $APP_DIR/current.tmp
sudo mv -Tf $APP_DIR/current.tmp $APP_DIR/current
sudo chown -h $APP:$APP $APP_DIR/current
sudo systemctl restart $APP

healthy=0
for _ in \$(seq 1 30); do
	if curl -fsS -m 3 'http://127.0.0.1:$PORT$HEALTH_PATH' >/dev/null 2>&1; then
		healthy=1
		break
	fi
	sleep 1
done

if [ \"\$healthy\" -ne 1 ]; then
	echo '!! health check failed'
	if [ -n \"\$PREV\" ] && [ -d \"\$PREV\" ]; then
		echo \"!! rolling back to \$PREV\"
		sudo ln -sfn \"\$PREV\" $APP_DIR/current.tmp
		sudo mv -Tf $APP_DIR/current.tmp $APP_DIR/current
		sudo chown -h $APP:$APP $APP_DIR/current
		sudo systemctl restart $APP
	fi
	sudo journalctl -u $APP -n 40 --no-pager -o cat
	exit 1
fi

# Keep the most recent releases; rollback is then a symlink swap.
ls -1dt $APP_DIR/releases/*/ 2>/dev/null | tail -n +$((KEEP + 1)) | sudo xargs -r rm -rf

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
		ssh -t "$HOST" "
			set -e
			sudo cp -a /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-\$(date +%Y%m%d%H%M%S)
			printf '\n%s {\n    encode gzip zstd\n    reverse_proxy 127.0.0.1:%s\n}\n' '$DOMAIN' '$PORT' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
			if sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
				sudo systemctl reload caddy && echo 'caddy reloaded'
			else
				echo '!! Caddyfile invalid, restoring backup' >&2
				sudo cp -a \"\$(ls -1t /etc/caddy/Caddyfile.bak-* | head -1)\" /etc/caddy/Caddyfile
				exit 1
			fi
		"
	fi
fi

# ---------------------------------------------------------------------------
# Verify the public URL. Derived from DOMAIN, never hardcoded, so a deploy to a
# new host cannot be confirmed by the old one answering.
# ---------------------------------------------------------------------------
say "verifying https://$DOMAIN$HEALTH_PATH"
if curl -fsS -m 20 "https://$DOMAIN$HEALTH_PATH"; then
	printf '\n'
	say "deployed $REV to $DOMAIN"
else
	printf '\n'
	warn "$DOMAIN did not answer over HTTPS."
	printf '   The app itself is healthy on the host, so this is DNS, TLS or routing.\n'
	printf '   Check first:  dig +short %s A     -> must be this host\n' "$DOMAIN"
	printf '   If that shows Cloudflare addresses, the record is proxied (orange\n'
	printf '   cloud) and every ACME challenge will fail. Set it to DNS only.\n'
	printf '   Then:  ssh %s "sudo journalctl -u caddy -n 30 --no-pager | grep -i acme"\n' "$HOST"
	exit 1
fi
