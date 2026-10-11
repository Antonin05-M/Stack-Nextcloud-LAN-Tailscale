#!/bin/bash
# =============================================================================
# Renouvellement quotidien du certificat TLS Nextcloud (Let's Encrypt, DNS-01)
# -----------------------------------------------------------------------------
# Installation : cp scripts/renew-nextcloud-cert.sh /usr/local/sbin/
#               chmod 700 /usr/local/sbin/renew-nextcloud-cert.sh
#
# Principe :
#   - `certbot renew` ne fait rien si le certificat n'est pas proche de
#     l'expiration (aucun reload Nginx inutile).
#   - si un nouveau certificat est émis, le deploy hook
#     certbot/hooks/deploy-marker.sh pose un marqueur dans certbot/lib.
#   - ce script détecte le marqueur, le retire, et recharge Nginx.
#
# Les identifiants de l'API DNS sont lus par le hook depuis le fichier
# secret /root/.config/cpanel/certbot-dns.env (chmod 600), monté en
# lecture seule dans le conteneur Certbot.
#
# Planifié chaque jour vers 04:30 par systemd/nextcloud-cert-renew.timer
# =============================================================================

set -Eeuo pipefail

COMPOSE_DIR="/opt/nextcloud"
MARKER="${COMPOSE_DIR}/certbot/lib/cert-deployed.marker"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cd "$COMPOSE_DIR"

log "Lancement de certbot renew..."
docker run --rm \
    -v "${COMPOSE_DIR}/certbot/etc:/etc/letsencrypt" \
    -v "${COMPOSE_DIR}/certbot/lib:/var/lib/letsencrypt" \
    -v "${COMPOSE_DIR}/certbot/log:/var/log/letsencrypt" \
    -v "${COMPOSE_DIR}/certbot/hooks:/hooks:ro" \
    -v "/root/.config/cpanel/certbot-dns.env:/run/secrets/cpanel.env:ro" \
    certbot/certbot:latest \
    renew --quiet

# --- Un nouveau certificat a-t-il été émis ? --------------------------------
if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    log "Un nouveau certificat a ete emis : rechargement de Nginx..."
    docker compose exec -T nginx nginx -t
    docker compose exec -T nginx nginx -s reload
    log "Nginx recharge."
else
    log "Aucun renouvellement necessaire."
fi

log "Verification Certbot terminee."
