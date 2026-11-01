#!/usr/bin/env bash
# ==============================================================================
# Script Name : hybrid-db-backup.sh
# Description : Production-Grade PostgreSQL/MySQL Backup & Rclone MinIO Sync
# Author      : Andriawan Maris (mail@marisandriawan.my.id)
# License     : MIT
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# 1. Bootstrap & Load Environment Configuration
# ------------------------------------------------------------------------------
ENV_FILE="${1:-$(dirname "$0")/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[FATAL] Environment configuration file not found at: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

TIMESTAMP="$(date +'%Y-%m-%d_%H%M%S')"
DATE_FOLDER="$(date +'%Y-%m')"
START_TIME="$(date +%s)"
HOSTNAME_SHORT="$(hostname -s)"
LOCK_FILE="/tmp/hybrid_db_backup_${DB_ENGINE}_${DB_NAME}.lock"
WORK_DIR="${LOCAL_BACKUP_DIR}/${DB_ENGINE}/${DATE_FOLDER}"

mkdir -p "$WORK_DIR"

# ------------------------------------------------------------------------------
# 2. Logging & Webhook Notification Helpers
# ------------------------------------------------------------------------------
log_info() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

send_notification() {
  local status="$1"
  local message="$2"

  if [[ -z "${WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  local payload
  payload=$(cat <<EOF
{
  "text": "[${status}] Hybrid DB Backup on *${HOSTNAME_SHORT}*\n• Database: \`${DB_NAME}\` (${DB_ENGINE})\n• Details: ${message}"
}
EOF
)
  curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

on_error() {
  local exit_code=$?
  local line_no=$1
  log_error "Backup pipeline failed with exit code ${exit_code} at line ${line_no}."
  send_notification "CRITICAL FAILURE" "Pipeline aborted at line ${line_no} (Exit code: ${exit_code}). Check /var/log/hybrid-backup.log immediately."
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# 3. Concurrency Protection (flock)
# ------------------------------------------------------------------------------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log_error "Another backup process is currently running for ${DB_NAME}. Exiting."
  exit 1
fi

log_info "Starting hybrid backup pipeline for database '${DB_NAME}' (${DB_ENGINE})..."

# ------------------------------------------------------------------------------
# 4. Pre-Flight Check: Verify Tailscale / On-Premise Node Reachability
# ------------------------------------------------------------------------------
if [[ -n "${TAILSCALE_MINIO_IP:-}" ]]; then
  log_info "Verifying connectivity to on-premise storage node (${TAILSCALE_MINIO_IP})..."
  if ! ping -c 2 -W 3 "$TAILSCALE_MINIO_IP" >/dev/null 2>&1; then
    log_error "On-premise MinIO node (${TAILSCALE_MINIO_IP}) is unreachable over Tailscale mesh."
    exit 1
  fi
fi

# ------------------------------------------------------------------------------
# 5. Execute Atomic Database Dump & Compression
# ------------------------------------------------------------------------------
BASE_FILENAME="${DB_NAME}_${TIMESTAMP}.sql.gz"
ARCHIVE_PATH="${WORK_DIR}/${BASE_FILENAME}"

if [[ "$DB_ENGINE" == "postgres" ]]; then
  log_info "Executing pg_dump for PostgreSQL database '${DB_NAME}'..."
  export PGPASSWORD="$DB_PASSWORD"
  pg_dump -h "${DB_HOST:-127.0.0.1}" \
          -p "${DB_PORT:-5432}" \
          -U "$DB_USER" \
          --no-owner \
          --no-privileges \
          --clean \
          --if-exists \
          "$DB_NAME" | gzip -9 > "$ARCHIVE_PATH"
  unset PGPASSWORD

elif [[ "$DB_ENGINE" == "mysql" ]]; then
  log_info "Executing mysqldump for MySQL/MariaDB database '${DB_NAME}'..."
  MYSQL_PWD="$DB_PASSWORD" mysqldump -h "${DB_HOST:-127.0.0.1}" \
                                     -P "${DB_PORT:-3306}" \
                                     -u "$DB_USER" \
                                     --single-transaction \
                                     --quick \
                                     --routines \
                                     --triggers \
                                     "$DB_NAME" | gzip -9 > "$ARCHIVE_PATH"
else
  log_error "Unsupported DB_ENGINE: '${DB_ENGINE}'. Use 'postgres' or 'mysql'."
  exit 1
fi

# ------------------------------------------------------------------------------
# 6. Verify Archive Integrity & Generate SHA-256 Checksum
# ------------------------------------------------------------------------------
log_info "Verifying gzip archive integrity..."
gzip -t "$ARCHIVE_PATH"

if [[ ! -s "$ARCHIVE_PATH" ]]; then
  log_error "Generated backup archive is empty (0 bytes): ${ARCHIVE_PATH}"
  exit 1
fi

# Optional GPG Symmetric Encryption
FINAL_ARTIFACT="$ARCHIVE_PATH"
if [[ "${ENABLE_GPG_ENCRYPTION:-false}" == "true" ]]; then
  log_info "Encrypting backup archive with AES-256 GPG..."
  gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --cipher-algo AES256 -c "$ARCHIVE_PATH"
  rm -f "$ARCHIVE_PATH"
  FINAL_ARTIFACT="${ARCHIVE_PATH}.gpg"
fi

log_info "Generating SHA-256 checksum manifest..."
(cd "$WORK_DIR" && sha256sum "$(basename "$FINAL_ARTIFACT")" > "$(basename "$FINAL_ARTIFACT").sha256")

ARTIFACT_SIZE="$(du -h "$FINAL_ARTIFACT" | awk '{print $1}')"
log_info "Backup artifact verified: $(basename "$FINAL_ARTIFACT") (${ARTIFACT_SIZE})"

# ------------------------------------------------------------------------------
# 7. Synchronize to Hybrid MinIO / S3 Storage via Rclone
# ------------------------------------------------------------------------------
REMOTE_TARGET="${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/${HOSTNAME_SHORT}/${DB_ENGINE}/${DATE_FOLDER}"
log_info "Syncing artifact and checksum to remote storage: ${REMOTE_TARGET}..."

rclone copy "$FINAL_ARTIFACT" "$REMOTE_TARGET" --transfers 2 --checkers 4 --quiet
rclone copy "${FINAL_ARTIFACT}.sha256" "$REMOTE_TARGET" --quiet

log_info "Remote synchronization to MinIO/S3 completed successfully."

# ------------------------------------------------------------------------------
# 8. Dual-Tier Retention Policy (Prune Expired Backups)
# ------------------------------------------------------------------------------
log_info "Pruning local backups older than ${LOCAL_RETENTION_DAYS:-7} days..."
find "${LOCAL_BACKUP_DIR}/${DB_ENGINE}" -type f \( -name "*.gz" -o -name "*.gpg" -o -name "*.sha256" \) -mtime +"${LOCAL_RETENTION_DAYS:-7}" -delete
find "${LOCAL_BACKUP_DIR}/${DB_ENGINE}" -type d -empty -delete

if [[ "${REMOTE_RETENTION_DAYS:-0}" -gt 0 ]]; then
  log_info "Pruning remote MinIO/S3 backups older than ${REMOTE_RETENTION_DAYS} days..."
  rclone delete "${RCLONE_REMOTE_NAME}:${RCLONE_BUCKET_NAME}/${HOSTNAME_SHORT}/${DB_ENGINE}" \
    --min-age "${REMOTE_RETENTION_DAYS}d" \
    --quiet || log_error "Non-fatal: Remote rclone prune encountered a warning."
fi

# ------------------------------------------------------------------------------
# 9. Final Telemetry & Exit
# ------------------------------------------------------------------------------
END_TIME="$(date +%s)"
DURATION="$((END_TIME - START_TIME))"

log_info "Backup pipeline finished cleanly in ${DURATION}s."
send_notification "SUCCESS" "Artifact \`$(basename "$FINAL_ARTIFACT")\` (${ARTIFACT_SIZE}) synced to \`${RCLONE_REMOTE_NAME}\` in ${DURATION}s."

exit 0
