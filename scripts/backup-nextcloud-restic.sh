#!/bin/bash
# =============================================================================
# Sauvegarde quotidienne Nextcloud — Restic (chiffré, incrémental)
# -----------------------------------------------------------------------------
# Installation : cp scripts/backup-nextcloud-restic.sh /usr/local/sbin/
#               chmod 700 /usr/local/sbin/backup-nextcloud-restic.sh
#
# Séquence :
#   1. verrou anti-double sauvegarde (flock)
#   2. vérification du montage /mnt/data (refuse de tourner sinon)
#   3. mode maintenance Nextcloud ON  (trap garanti pour le OFF)
#   4. dump MariaDB cohérent (--single-transaction)
#   5. snapshot Restic : données + volume config + /opt/nextcloud + dump SQL
#
# ⚠️ Adaptez RESTIC_REPOSITORY si votre alias SSH / chemin diffèrent.
# Dépôt distant sur l'hyperviseur : sftp:pve-restic:/mnt/backup-usb/restic/nextcloud
# =============================================================================

set -Eeuo pipefail
umask 077

COMPOSE_DIR="/opt/nextcloud"
STAGING_DIR="/var/backups/nextcloud"
SQL_DUMP="${STAGING_DIR}/nextcloud.sql"

export RESTIC_REPOSITORY="sftp:pve-restic:/mnt/backup-usb/restic/nextcloud"
export RESTIC_PASSWORD_FILE="/root/.config/restic/nextcloud-password"
export RESTIC_CACHE_DIR="/var/cache/restic-nextcloud"

MAINTENANCE=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    rc=$?
    trap - EXIT
    if [ "$MAINTENANCE" -eq 1 ]; then
        log "Desactivation du mode maintenance..."
        cd "$COMPOSE_DIR"
        docker compose exec -T -u 33 nextcloud \
            ./occ maintenance:mode --off || true
    fi
    rm -f "$SQL_DUMP"
    if [ "$rc" -eq 0 ]; then
        log "Sauvegarde terminee avec succes."
    else
        log "ERREUR : sauvegarde interrompue (code $rc)."
    fi
    exit "$rc"
}

trap cleanup EXIT INT TERM

# --- Verrou : une seule sauvegarde à la fois -------------------------------
exec 9>/run/lock/nextcloud-restic.lock
if ! flock -n 9; then
    log "Une sauvegarde est deja en cours."
    exit 1
fi

cd "$COMPOSE_DIR"

# --- Vérifications préalables ----------------------------------------------
log "Verification du montage des donnees..."
if ! mountpoint -q /mnt/data; then
    log "ERREUR : /mnt/data n'est pas monte."
    exit 1
fi

log "Verification du depot Restic..."
restic snapshots --latest 1 >/dev/null

NC_CONTAINER="$(docker compose ps -q nextcloud)"
if [ -z "$NC_CONTAINER" ]; then
    log "ERREUR : conteneur Nextcloud introuvable."
    exit 1
fi

# Détermination des chemins réels des volumes via docker inspect
# (indépendante du nom du projet Compose)
NC_HTML_SOURCE="$(
    docker inspect "$NC_CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/var/www/html"}}{{.Source}}{{end}}{{end}}'
)"
NC_DATA_SOURCE="$(
    docker inspect "$NC_CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/var/www/html/data"}}{{.Source}}{{end}}{{end}}'
)"

if [ -z "$NC_HTML_SOURCE" ] || [ -z "$NC_DATA_SOURCE" ]; then
    log "ERREUR : impossible de determiner les volumes Nextcloud."
    exit 1
fi

log "Volume Nextcloud : $NC_HTML_SOURCE"
log "Donnees Nextcloud : $NC_DATA_SOURCE"

mkdir -p "$STAGING_DIR"

# --- Mode maintenance + dump SQL cohérent -----------------------------------
log "Activation du mode maintenance..."
docker compose exec -T -u 33 nextcloud \
    ./occ maintenance:mode --on
MAINTENANCE=1

log "Dump MariaDB..."
docker compose exec -T db sh -c \
    'exec mariadb-dump \
        --single-transaction \
        --default-character-set=utf8mb4 \
        -u"$MARIADB_USER" \
        -p"$MARIADB_PASSWORD" \
        "$MARIADB_DATABASE"' \
    > "$SQL_DUMP"

if [ ! -s "$SQL_DUMP" ]; then
    log "ERREUR : le dump MariaDB est vide."
    exit 1
fi

log "Dump MariaDB OK : $(du -h "$SQL_DUMP" | cut -f1)"

# --- Snapshot Restic ---------------------------------------------------------
log "Demarrage de Restic..."
restic backup \
    --tag nextcloud \
    "$NC_DATA_SOURCE" \
    "$NC_HTML_SOURCE" \
    "$COMPOSE_DIR" \
    "$SQL_DUMP"

log "Snapshot Restic cree."

# --- Sortie propre -----------------------------------------------------------
log "Desactivation du mode maintenance..."
docker compose exec -T -u 33 nextcloud \
    ./occ maintenance:mode --off
MAINTENANCE=0

rm -f "$SQL_DUMP"

log "Sauvegarde Nextcloud terminee."
