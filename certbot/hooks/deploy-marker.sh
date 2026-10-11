#!/bin/sh
# =============================================================================
# Deploy hook Certbot — marqueur de renouvellement
# -----------------------------------------------------------------------------
# Appelé par Certbot uniquement quand un NOUVEAU certificat est réellement
# émis. On pose un marqueur dans /var/lib/letsencrypt (monté du côté hôte
# dans ./certbot/lib) : le script renew-nextcloud-cert.sh le détecte et
# recharge alors Nginx. Si aucun renouvellement n'est nécessaire, aucun
# marqueur, aucun reload.
# =============================================================================

set -eu

MARKER="/var/lib/letsencrypt/cert-deployed.marker"

touch "$MARKER" 2>/dev/null || true

echo "[deploy-marker] Nouveau certificat emis : marqueur $MARKER cree."
