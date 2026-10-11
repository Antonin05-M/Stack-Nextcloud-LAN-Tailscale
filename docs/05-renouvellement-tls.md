# 05 — Renouvellement automatique du certificat TLS

## Principe

Le certificat de `cloud.example.com` est renouvelé automatiquement par
**Certbot (Let's Encrypt)** via un challenge **DNS-01**. Aucun port 80/443
n'est exposé pour cette opération.

```
systemd (04:30 + délai aléatoire)
        ↓
certbot renew  (conteneur Docker)
        ↓
hook : API DNS de l'hébergeur (cPanel)
        ↓
création temporaire  _acme-challenge.cloud.example.com  TXT ...
        ↓
validation Let's Encrypt
        ↓
suppression du TXT
        ↓
nouveau certificat
        ↓
deploy hook : marqueur
        ↓
script : nginx -t + reload Nginx
```

Si aucun renouvellement n'est nécessaire : aucune modification, aucun
reload.

## Accès API DNS

Un token API dédié est créé dans cPanel. Le fichier de credentials :

```
/root/.config/cpanel/certbot-dns.env     # chmod 600
```

```
CPANEL_HOST="..."
CPANEL_USER="..."
CPANEL_TOKEN="..."
CPANEL_ZONE="example.com"
```

**Ne jamais commité ce fichier** (le vrai fichier reste hors du repo ;
`.gitignore` exclut `*.env`).

> ⚠️ Dépendance connue : certains hébergeurs protègent l'API par un WAF qui
> rejette les appels non whitelistés ("One moment, please..."). L'IP publique
> du site hébergeant la VM doit être autorisée chez l'hébergeur. **Si cette
> IP publique change, les renouvellements peuvent échouer.** Contrôler :
> ```bash
> curl -4 https://ifconfig.me ; echo
> ```

Test de l'API :

```bash
source /root/.config/cpanel/certbot-dns.env
curl -sS \
  -H "Authorization: cpanel ${CPANEL_USER}:${CPANEL_TOKEN}" \
  "https://${CPANEL_HOST}:2083/execute/DNS/lookup?domain=cloud.example.com" \
  | jq '(.result // .) | {status,errors}'
# attendu : { "status": 1, "errors": null }
```

## Hooks Certbot

Le hook DNS du repo (`certbot/hooks/cpanel_dns.py`, **exemple générique à
adapter à votre hébergeur**) réalise :

- `add` → création du TXT `_acme-challenge`
- `remove` → suppression du TXT exact utilisé pour le challenge

Il lit `CERTBOT_IDENTIFIER` / `CERTBOT_VALIDATION` fournis par Certbot, et
les credentials dans `/run/secrets/cpanel.env` (monté depuis
`/root/.config/cpanel/certbot-dns.env`).

Le hook `deploy-marker.sh` pose un marqueur dans `/var/lib/letsencrypt`
(visible côté hôte dans `certbot/lib/`) quand un nouveau certificat est
réellement émis.

### Enregistrement des hooks dans le certificat existant

Le renouvellement d'un certificat obtenu en `--manual` devient automatisable
en éditant le renewal conf :

```
/opt/nextcloud/certbot/etc/renewal/cloud.example.com.conf
```

```ini
authenticator = manual
manual_auth_hook = /hooks/cpanel_dns.py add
manual_cleanup_hook = /hooks/cpanel_dns.py remove
```

Contrôle :

```bash
grep -E 'authenticator|manual_auth_hook|manual_cleanup_hook|pref_challs' \
    /opt/nextcloud/certbot/etc/renewal/cloud.example.com.conf
```

## Test complet (sans toucher à la production)

```bash
docker run --rm \
  -v /opt/nextcloud/certbot/etc:/etc/letsencrypt \
  -v /opt/nextcloud/certbot/lib:/var/lib/letsencrypt \
  -v /opt/nextcloud/certbot/log:/var/log/letsencrypt \
  -v /opt/nextcloud/certbot/hooks:/hooks:ro \
  -v /root/.config/cpanel/certbot-dns.env:/run/secrets/cpanel.env:ro \
  certbot/certbot:latest \
  renew --dry-run
# attendu : "all simulated renewals succeeded"
```

À refaire tous les quelques mois, ou après toute modification
DNS / cPanel / Certbot.

## Automatisation systemd

```bash
cp scripts/renew-nextcloud-cert.sh /usr/local/sbin/
chmod 700 /usr/local/sbin/renew-nextcloud-cert.sh
sudo cp systemd/nextcloud-cert-renew.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-cert-renew.timer
```

Le timer déclenche le service chaque jour vers 04:30 avec
`RandomizedDelaySec=1800`. Le script lance `certbot renew`, et ne recharge
Nginx **que** si le marqueur de déploiement est présent.

## Exploitation

```bash
systemctl list-timers nextcloud-cert-renew.timer    # une date dans NEXT
journalctl -u nextcloud-cert-renew.service -n 100 --no-pager
```

- Fonctionnement normal : `Aucun renouvellement necessaire.`
- Après renouvellement réel : `TXT ajoute` / `TXT supprime`,
  `Un nouveau certificat a ete emis`, `nginx -t OK`, `Nginx recharge`.

Test manuel immédiat : `systemctl start nextcloud-cert-renew.service`
(un état `inactive (dead)` est **normal** pour un service oneshot — vérifier
`status=0/SUCCESS`).

Date du certificat réellement présenté :

```bash
echo | openssl s_client \
  -connect cloud.example.com:443 -servername cloud.example.com 2>/dev/null \
  | openssl x509 -noout -dates
```

## Diagnostic en cas de panne

1. Vérifier le timer systemd
2. Lire `journalctl -u nextcloud-cert-renew.service`
3. Vérifier l'IP publique actuelle (whitelist hébergeur)
4. Tester l'API cPanel (commande ci-dessus)
5. Vérifier le token cPanel
6. Vérifier les hooks Certbot
7. Lancer `renew --dry-run`
8. Vérifier `nginx -t`

Si l'API répond à nouveau "One moment, please...", la **première suspicion
est la whitelist d'IP chez l'hébergeur**.
