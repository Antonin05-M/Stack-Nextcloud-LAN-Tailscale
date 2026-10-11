#!/bin/bash
# =============================================================================
# Maintenance hebdomadaire du dépôt Restic Nextcloud
# -----------------------------------------------------------------------------
# Installation : cp scripts/maintenance-restic-nextcloud.sh /usr/local/sbin/
#               chmod 700 /usr/local/sbin/maintenance-restic-nextcloud.sh
#
# Rétention : 7 quotidiennes / 4 hebdomadaires / 6 mensuelles, puis prune
# et vérification d'intégrité du dépôt (restic check).
#
# Planifié chaque dimanche 06:00 par systemd/nextcloud-restic-maintenance.timer
# =============================================================================

set -Eeuo pipefail
umask 077

export RESTIC_REPOSITORY='sftp:pve-restic:/mnt/backup-usb/restic/nextcloud'
export RESTIC_PASSWORD_FILE='/root/.config/restic/nextcloud-password'
export RESTIC_CACHE_DIR='/var/cache/restic-nextcloud'

echo "=== Retention Restic ==="
restic forget \
    --host docker \
    --tag nextcloud \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune

echo "=== Verification du depot ==="
restic check

echo "=== Maintenance terminee ==="
