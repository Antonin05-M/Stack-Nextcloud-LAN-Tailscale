#!/usr/bin/env python3
# =============================================================================
# Hook DNS-01 Certbot — hébergeur avec API cPanel (UAPI)
# -----------------------------------------------------------------------------
# Crée/supprime automatiquement l'enregistrement TXT _acme-challenge
# pendant le challenge DNS-01 de Let's Encrypt. Aucun port 80/443 exposé.
#
# ⚠️ EXEMPLE GÉNÉRIQUE, fourni à titre pédagogique : adaptez-le à votre
# hébergeur et validez CHAQUE opération manuellement avant production
# (lecture zone, création TXT, propagation, suppression TXT).
#
# Utilisation (enregistré dans le renewal conf du certificat) :
#   manual_auth_hook    = /hooks/cpanel_dns.py add
#   manual_cleanup_hook = /hooks/cpanel_dns.py remove
#
# Les identifiants API proviennent du fichier secret monté dans le
# conteneur Certbot : /run/secrets/cpanel.env contenant :
#   CPANEL_HOST="exemple.tld"
#   CPANEL_USER="utilisateur"
#   CPANEL_TOKEN="token-api"
#   CPANEL_ZONE="example.com"
#
# Certbot fournit automatiquement :
#   CERTBOT_IDENTIFIER  -> domaine validé (ex. cloud.example.com)
#   CERTBOT_VALIDATION  -> valeur TXT du challenge
# =============================================================================

import json
import os
import ssl
import sys
import urllib.parse
import urllib.request

ENV_FILE = "/run/secrets/cpanel.env"
API_PORT = 2083
TIMEOUT = 30

# Certains hébergeurs protègent l'API par un WAF : si un rejet TLS/WAF
# apparaît, vérifier d'abord la whitelist d'IP côté hébergeur.
SSL_CONTEXT = ssl.create_default_context()


def log(msg: str) -> None:
    print(f"[cpanel_dns] {msg}")


def fail(msg: str) -> None:
    log(f"ERREUR : {msg}")
    sys.exit(1)


def load_env(path: str) -> dict:
    """Charge un fichier KEY="VALUE" sans évaluer quoi que ce soit."""
    values = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError as exc:
        fail(f"impossible de lire {path} ({exc})")
    for required in ("CPANEL_HOST", "CPANEL_USER", "CPANEL_TOKEN", "CPANEL_ZONE"):
        if required not in values:
            fail(f"variable {required} absente de {path}")
    return values


def uapi(env: dict, module: str, function: str, params: dict) -> dict:
    """Appelle l'API UAPI cPanel et renvoie `result`."""
    query = urllib.parse.urlencode(params)
    url = f"https://{env['CPANEL_HOST']}:{API_PORT}/execute/{module}/{function}?{query}"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"cpanel {env['CPANEL_USER']}:{env['CPANEL_TOKEN']}",
            "User-Agent": "certbot-dns-hook/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT, context=SSL_CONTEXT) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError) as exc:  # noqa: F821 (urllib.error importé implicitement)
        fail(f"appel {module}/{function} impossible ({exc})")

    # Un WAF mal contourné répond en HTML ("One moment, please...") -> JSON KO
    if payload.get("status") != 1:
        fail(f"API {module}/{function} en échec : {payload.get('errors')}")
    return payload.get("result", payload)


def add_record(env: dict, fqdn: str, txt_value: str) -> None:
    """Crée l'enregistrement TXT du challenge."""
    log(f"ajout TXT {fqdn} ...")
    uapi(env, "DNS", "add_record", {
        "domain": env["CPANEL_ZONE"],
        "name": fqdn,
        "type": "TXT",
        "ttl": 300,
        "txtdata": txt_value,
    })
    log("TXT ajoute.")


def remove_record(env: dict, fqdn: str, txt_value: str) -> None:
    """Supprime l'enregistrement TXT exact utilisé pour le challenge.

    On relit la zone pour retrouver la ligne (serial) correspondant à la
    valeur du challenge, puis on supprime uniquement cette ligne.
    """
    log(f"recherche du TXT {fqdn} a supprimer...")
    records = uapi(env, "DNS", "lookup", {"domain": fqdn})
    matches = [
        record for record in (records if isinstance(records, list) else [])
        if record.get("type") == "TXT"
        and str(record.get("txtdata", "")).strip('"') == txt_value
    ]
    if not matches:
        log("aucun TXT correspondant trouve (deja supprime ?) — rien a faire.")
        return
    for record in matches:
        line = record.get("line")
        if line is None:
            fail("la ligne du TXT est introuvable dans la reponse DNS/lookup")
        uapi(env, "DNS", "remove_record", {
            "domain": env["CPANEL_ZONE"],
            "name": fqdn,
            "type": "TXT",
            "line": line,
        })
        log(f"TXT supprime (ligne {line}).")


def main() -> None:
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    fqdn = os.environ.get("CERTBOT_IDENTIFIER", "")
    txt_value = os.environ.get("CERTBOT_VALIDATION", "")
    if action not in ("add", "remove"):
        fail("usage : cpanel_dns.py {add|remove}")
    if not fqdn or not txt_value:
        fail("variables CERTBOT_IDENTIFIER / CERTBOT_VALIDATION absentes "
             "(ce script doit etre appele par Certbot)")

    env = load_env(ENV_FILE)
    fqdn = f"_acme-challenge.{fqdn}"

    if action == "add":
        add_record(env, fqdn, txt_value)
    else:
        remove_record(env, fqdn, txt_value)


if __name__ == "__main__":
    main()
