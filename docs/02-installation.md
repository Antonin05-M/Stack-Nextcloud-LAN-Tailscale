# 02 — Installation pas à pas

Prérequis : VM Debian 12 à jour, IP fixe, accès SSH, Docker + compose plugin
installés, disque de données monté sur `/mnt/data` (voir
[`01-architecture.md`](01-architecture.md)).

> La méthode recommandée : valider toute la stack en **HTTP** d'abord, puis
> basculer en HTTPS. Ne pas mélanger la mise au point TLS avec la première
> installation.

## Étape 0 — vérifier le disque de données

```bash
lsblk -f
findmnt /mnt/data
df -hT /mnt/data
cat /etc/fstab     # montage par UUID, SANS nofail
```

On veut un filesystem **ext4** (éviter NTFS/exFAT : le processus web doit
gérer les droits Unix). `nofail` doit être **absent** pour ce disque.

## Étape 1 — répertoires et droits

```bash
sudo mkdir -p /opt/nextcloud/nginx
sudo mkdir -p /mnt/data/nextcloud/data
sudo chown -R 33:33 /mnt/data/nextcloud/data   # www-data = UID 33
sudo chmod 750 /mnt/data/nextcloud/data
```

## Étape 2 — secrets

```bash
cd /opt/nextcloud
sudo cp .env.example .env
openssl rand -hex 32     # x3 : DB password, root password, secret JWT
sudo nano .env           # reporter les 3 valeurs
sudo chmod 600 .env
```

Le secret JWT doit être identique côté DocumentServer et côté connecteur
Nextcloud (obligatoire depuis ONLYOFFICE 7.2).

## Étape 3 — stack Compose

Copier `compose.yaml` et `nginx/default.conf` du repo dans `/opt/nextcloud`,
en adaptant les placeholders (domaine, IP VM, chemin de données).

Pour la première mise au point, partir du Nginx HTTP simple :

```nginx
server {
    listen 80;
    server_name _;
    client_max_body_size 10G;
    # ... location / -> http://nextcloud/ et /editors/ -> http://onlyoffice/
}
```

Puis :

```bash
docker compose config      # aucune erreur attendue
docker compose pull
docker compose up -d
docker compose ps         # db, redis, nextcloud, cron, onlyoffice, nginx : Up
```

> ONLYOFFICE demande **au moins 4 Go de RAM** ; prévoir 6 Go pour la VM si
> l'hyperviseur le permet.

## Étape 4 — assistant Nextcloud

Ouvrir `http://192.168.1.20` depuis le LAN. Les paramètres DB sont déjà
fournis par les variables d'environnement (hôte `db`, base `nextcloud`,
utilisateur `nextcloud`, mot de passe du `.env`). Créer le compte
administrateur.

## Étape 5 — cron Nextcloud

```bash
docker compose exec -u33 nextcloud ./occ background:cron
docker compose exec -u33 nextcloud ./occ config:app:get core backgroundjobs_mode
# attendu : cron
```

Le conteneur `cron` exécute ensuite `cron.php` automatiquement — mode
recommandé en production plutôt que les AJAX déclenchés par les visites.

## Étape 6 — vérifier Redis

```bash
docker compose exec -u33 nextcloud ./occ config:list system
# la configuration Redis doit apparaître (REDIS_HOST)
```

## Étape 7 — connecteur ONLYOFFICE

1. Nextcloud → **Applications** → chercher « ONLYOFFICE » → installer/activer.
2. **Paramètres → Administration → ONLYOFFICE** :
   - Adresse principale : `http://192.168.1.20/editors/` (URL publique du
     navigateur)
   - Clé secrète : la valeur de `ONLYOFFICE_JWT_SECRET` du `.env`
3. **Paramètres avancés du serveur** — c'est ici que l'architecture Docker
   devient propre :
   - Adresse ONLYOFFICE pour les requêtes internes depuis Nextcloud :
     `http://onlyoffice/`
   - Adresse Nextcloud pour les requêtes internes depuis ONLYOFFICE :
     `http://nextcloud/`

   Le trafic navigateur passe par Nginx, mais les conteneurs parlent entre
   eux directement sur le réseau Docker — mieux que de tout faire reboucler
   par l'IP de la VM.

```bash
docker compose exec -u33 nextcloud ./occ onlyoffice:documentserver --check
# attendu : "... is successfully connected"
```

Créer un document (+ Nouveau → Document) pour valider l'éditeur.

## Étape 8 — Tailscale (accès distant)

Subnet routing `192.168.1.0/24` déjà opérationnel côté hyperviseur, ACL
restreintes. **Aucun port Nextcloud/Nginx ne doit être NATé sur la box** —
l'accès distant passe exclusivement par Tailscale.

## Étape 9 — sous-domaine DNS public → IP privée

Chez l'hébergeur DNS, ajouter **sans toucher aux enregistrements existants** :

```
Nom : cloud   Type : A   Valeur : 192.168.1.20   TTL : 300
```

Cela n'ouvre aucun port. Vérifier :

```bash
nslookup cloud.example.com
curl -I http://cloud.example.com
# "Accès via un domaine non approuvé" = DNS+Nginx OK, reste trusted_domains
```

## Étape 10 — trusted domains Nextcloud

```bash
docker compose exec -u33 nextcloud \
    ./occ config:system:set trusted_domains 1 --value=nextcloud
docker compose exec -u33 nextcloud \
    ./occ config:system:set trusted_domains 2 --value=cloud.example.com
docker compose exec -u33 nextcloud \
    ./occ config:system:get trusted_domains
# attendu : 192.168.1.20, nextcloud, cloud.example.com
```

## Étape 11 — certificat Let's Encrypt (DNS-01)

```bash
cd /opt/nextcloud
mkdir -p certbot/etc certbot/lib certbot/log

docker run --rm -it \
  -v /opt/nextcloud/certbot/etc:/etc/letsencrypt \
  -v /opt/nextcloud/certbot/lib:/var/lib/letsencrypt \
  -v /opt/nextcloud/certbot/log:/var/log/letsencrypt \
  certbot/certbot:latest \
  certonly --manual --preferred-challenges dns \
  -d cloud.example.com
```

Certbot affiche une valeur TXT. Créer chez l'hébergeur DNS :

```
_acme-challenge.cloud.example.com  TXT  <VALEUR_CERTBOT>
```

Vérifier la propagation puis valider dans Certbot :

```bash
nslookup -type=TXT _acme-challenge.cloud.example.com 1.1.1.1
```

Le certificat est émis dans `certbot/etc/live/cloud.example.com/`.

## Étape 12 — passer Nginx en HTTPS

Remplacer `nginx/default.conf` par la version TLS du repo (blocs 80→301 et
443 ssl), puis :

```bash
docker compose up -d --force-recreate nginx
docker compose exec nginx nginx -t     # syntax is ok / test is successful
```

Dire à Nextcloud qu'il est derrière un proxy HTTPS :

```bash
docker compose exec -u33 nextcloud \
    ./occ config:system:set overwriteprotocol --value=https
docker compose exec -u33 nextcloud \
    ./occ config:system:set overwrite.cli.url --value=https://cloud.example.com
```

## Étape 13 — ONLYOFFICE en HTTPS

Dans les paramètres du connecteur, changer uniquement l'adresse publique :
`https://cloud.example.com/editors/`. **Laisser les URL internes en HTTP**
(`http://onlyoffice/`, `http://nextcloud/`) : le TLS protège la partie
navigateur ↔ reverse proxy, les conteneurs restent sur le réseau Docker.

```bash
docker compose exec -u33 nextcloud ./occ onlyoffice:documentserver --check
# attendu : "Document server https://cloud.example.com/editors/ ... successfully connected"
```

## Étape 14 — automatiser le renouvellement TLS

Suivre [`05-renouvellement-tls.md`](05-renouvellement-tls.md) (hook API DNS +
systemd). Ne pas activer HSTS tant que HTTPS et ONLYOFFICE ne sont pas
parfaitement validés.

## Vérifications finales

```bash
docker compose ps
docker compose exec -u33 nextcloud ./occ status
curl -I https://cloud.example.com    # 200 ou 302 -> /login
```
