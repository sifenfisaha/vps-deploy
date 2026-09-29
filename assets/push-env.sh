#!/usr/bin/env bash
#
# Pushes the local production environment file to the host and restarts the
# service. Pairs with deploy.sh, which seeds the file on first provision and
# never touches it again; this is the command for every change after that.
#
#   ./scripts/push-env.sh            # upload, restart, health-check
#
# The local file is the source of truth. The host keeps a timestamped backup
# of the previous file, and if the service does not come back healthy with
# the new one, the backup is restored and the service restarted again — a bad
# edit costs a restart, not an outage.
#
# Never prints a value: the comparison with the host is by key name only.
#
# ---------------------------------------------------------------------------
# CONFIG — the same values as deploy.sh. Every one reads from the environment
# too (VPS_APP, VPS_HOST, …), so one script serves staging and production.
# ---------------------------------------------------------------------------

# Short name. The service unit, the system user, and /opt/<APP>.
APP="${VPS_APP:-myapp}"

# ssh target. The account needs sudo.
HOST="${VPS_HOST:-deploy@203.0.113.10}"

# Loopback port Caddy proxies to. The health check hits it directly.
PORT="${VPS_PORT:-3100}"

# The local file to upload. Never committed.
ENV_FILE="${VPS_ENV_FILE:-.env.production}"

# Env keys that must be present in ENV_FILE. Space separated; may be empty.
REQUIRED_ENV="${VPS_REQUIRED_ENV:-}"

# Path the health check requests.
HEALTH_PATH="${VPS_HEALTH_PATH:-/}"

# Backups of the previous file kept on the host.
KEEP_BACKUPS="${VPS_KEEP_BACKUPS:-5}"

# ---------------------------------------------------------------------------
# No configuration below this line.
# ---------------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

APP_DIR="/opt/$APP"
SHARED_DIR="$APP_DIR/shared"
REMOTE_ENV="$SHARED_DIR/.env"

# --- local checks -----------------------------------------------------------

[ -f "$ENV_FILE" ] || die "$ENV_FILE does not exist."
for key in $REQUIRED_ENV; do
	grep -qE "^$key=." "$ENV_FILE" || die "$ENV_FILE is missing $key"
done
if grep -qE "^PORT=" "$ENV_FILE" && ! grep -qE "^PORT=$PORT$" "$ENV_FILE"; then
	die "$ENV_FILE sets PORT to something other than $PORT, which is what Caddy proxies to."
fi
if git ls-files --error-unmatch "$ENV_FILE" >/dev/null 2>&1; then
	die "$ENV_FILE is tracked by git. Untrack it and add it to .gitignore before pushing it anywhere."
fi

# --- remote checks ----------------------------------------------------------

say "checking $HOST"
ssh "$HOST" "sudo test -d $SHARED_DIR" 2>/dev/null \
	|| die "$SHARED_DIR does not exist on $HOST. Run ./scripts/deploy.sh first; it provisions the host and seeds the file."

# Compare by key only, so no value is ever printed.
LOCAL_KEYS="$(grep -oE '^[A-Z0-9_]+=' "$ENV_FILE" | sort -u)"
REMOTE_KEYS="$(ssh "$HOST" "sudo cat $REMOTE_ENV 2>/dev/null" | grep -oE '^[A-Z0-9_]+=' | sort -u || true)"
if [ "$LOCAL_KEYS" = "$REMOTE_KEYS" ]; then
	echo "    same keys on both sides (values may differ)"
else
	echo "    keys only here:  $(comm -23 <(echo "$LOCAL_KEYS") <(echo "$REMOTE_KEYS") | tr -d '=' | tr '\n' ' ')"
	echo "    keys only there: $(comm -13 <(echo "$LOCAL_KEYS") <(echo "$REMOTE_KEYS") | tr -d '=' | tr '\n' ' ')"
fi

# --- upload -----------------------------------------------------------------

say "uploading $ENV_FILE -> $HOST:$REMOTE_ENV"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="$SHARED_DIR/.env.bak-$STAMP"
ssh "$HOST" "if sudo test -f $REMOTE_ENV; then sudo cp -a $REMOTE_ENV $BACKUP; fi"
rsync -a --chmod=F600 --rsync-path="sudo rsync" "$ENV_FILE" "$HOST:$REMOTE_ENV"
ssh "$HOST" "
	sudo chown $APP:$APP $REMOTE_ENV && sudo chmod 600 $REMOTE_ENV
	# Keep only the newest backups.
	sudo ls -1t $SHARED_DIR/.env.bak-* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | sudo xargs -r rm -f
"

# --- restart and verify, restoring on failure --------------------------------

say "restarting $APP"
ssh "$HOST" "
set -e
sudo systemctl restart $APP
healthy=0
for _ in \$(seq 1 30); do
	if curl -fsS -m 3 'http://127.0.0.1:$PORT$HEALTH_PATH' >/dev/null 2>&1; then healthy=1; break; fi
	sleep 1
done
if [ \"\$healthy\" -ne 1 ]; then
	echo '!! $APP did not come back with the new environment'
	if sudo test -f $BACKUP; then
		echo '   restoring the previous file and restarting'
		sudo cp -a $BACKUP $REMOTE_ENV
		sudo systemctl restart $APP
	fi
	sudo journalctl -u $APP -n 30 --no-pager -o cat
	exit 1
fi
if sudo test -f $BACKUP; then
	echo \"==> $APP is up with the new environment (previous file kept at $BACKUP)\"
else
	echo \"==> $APP is up with the new environment\"
fi
"
