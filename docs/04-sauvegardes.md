# 04 — Sauvegardes & restauration

## Stratégie : deux outils, deux rôles

| | **VZDump** (hyperviseur) | **Restic** (VM, chiffré) |
|---|---|---|
| Contenu | Disque système de la VM uniquement (150 Go) | Fichiers + config + stack + dump MariaDB |
| Fréquence | 03:00 quotidien (job PVE) | 01:00 quotidien (systemd) |
| Rétention | 3 j / 2 sem / 3 mois (PVE) | 7 j / 4 sem / 6 mois (forget hebdo) |
| Rôle | Reconstruire vite Debian + Docker | **Référence** : cohérence applicative |

Le disque de données (~2 To) est **volontairement exclu du VZDump**
(`backup=0`). Un VZDump de 03:00 avec un disque de données ayant évolué
jusqu'à 10:00 donnerait fichiers et base à des dates différentes :
**VZDump seul n'est PAS une restauration complète de Nextcloud.** Restic
remet fichiers + config + base au même snapshot.

### Ce que contient chaque snapshot Restic

| Élément | Restauré |
|---|---|
| `/mnt/data/nextcloud/data` (fichiers utilisateurs) | ✅ |
| Volume Docker Nextcloud (`config.php`, apps) | ✅ |
| `/opt/nextcloud` (compose, .env, nginx, certificats) | ✅ |
| `nextcloud.sql` (dump cohérent `--single-transaction`) | ✅ |
| Redis | ❌ (volatil, inutile) |

### Chiffrement Restic

- Dépôt **chiffré**, mot de passe dans `/root/.config/restic/nextcloud-password`
  (chmod 600), conservé **aussi hors de l'infrastructure** (gestionnaire de
  mots de passe). **Sans cette clé, les sauvegardes sont irrécupérables.**
- Dépôt distant : `sftp:pve-restic:/mnt/backup-usb/restic/nextcloud`, via un
  compte `restic` dédié sur l'hyperviseur — **sans sudo**, SSH par clé
  uniquement, et `AllowUsers` restreint à la VM (`restic@192.168.1.20`).

### Dépôt Restic (première installation)

```bash
apt install -y restic
mkdir -p /root/.config/restic && chmod 700 /root/.config/restic
openssl rand -base64 48 > /root/.config/restic/nextcloud-password
chmod 600 /root/.config/restic/nextcloud-password
mkdir -p /var/cache/restic-nextcloud && chmod 700 /var/cache/restic-nextcloud

export RESTIC_REPOSITORY='sftp:pve-restic:/mnt/backup-usb/restic/nextcloud'
export RESTIC_PASSWORD_FILE='/root/.config/restic/nextcloud-password'
export RESTIC_CACHE_DIR='/var/cache/restic-nextcloud'
restic init && restic check
```

### SSH côté VM (`/root/.ssh/config`)

```
Host pve-restic
    HostName 192.168.1.10
    Port 2222
    User restic
    IdentityFile /root/.ssh/id_ed25519_restic
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 240
```

### Installation des scripts/timers

```bash
cp scripts/backup-nextcloud-restic.sh /usr/local/sbin/ && chmod 700 /usr/local/sbin/backup-nextcloud-restic.sh
cp scripts/maintenance-restic-nextcloud.sh /usr/local/sbin/ && chmod 700 /usr/local/sbin/maintenance-restic-nextcloud.sh
sudo cp systemd/nextcloud-restic-*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-restic-backup.timer nextcloud-restic-maintenance.timer
systemctl list-timers --all | grep nextcloud
```

## Cas principal : perte complète de la VM

### A. Vérifier les sauvegardes (hyperviseur)

```bash
findmnt /mnt/backup-usb && pvesm status
ls -lh /mnt/backup-usb/dump/      # ou pvesm list usb-backup --content backup
```

Choisir le dernier VZDump **réussi** de la VM.

### B. Restaurer la VM

```bash
qmrestore /mnt/backup-usb/dump/vzdump-qemu-<VMID>-....vma.zst <VMID> --storage local-lvm
qm config <VMID>
```

### C. Rattacher le disque de données AVANT de démarrer

```bash
qm config <VMID> | grep virtio1
# si absent :
qm set <VMID> --virtio1 /dev/disk/by-id/<ID-STABLE-DU-DISQUE>,discard=on,iothread=1,backup=0
qm start <VMID>
```

**Conserver impérativement `backup=0`.**

### D. Vérifier dans la VM

```bash
findmnt /mnt/data && df -hT /mnt/data
```

**Si `/mnt/data` n'est pas monté, ne pas démarrer Nextcloud** (c'est le but
du montage sans `nofail`).

### E. Arrêter la stack et restaurer Restic

```bash
cd /opt/nextcloud && docker compose down

export RESTIC_REPOSITORY='sftp:pve-restic:/mnt/backup-usb/restic/nextcloud'
export RESTIC_PASSWORD_FILE='/root/.config/restic/nextcloud-password'
export RESTIC_CACHE_DIR='/var/cache/restic-nextcloud'

restic snapshots --tag nextcloud
SNAP=<ID>       # antérieur au sinistre ET terminé avec succès, pas aveuglément latest

restic restore "$SNAP" --target / \
    --include '/mnt/data/nextcloud/data' \
    --include '/var/lib/docker/volumes/nextcloud_nextcloud/_data' \
    --include '/opt/nextcloud' \
    --include '/var/backups/nextcloud/nextcloud.sql'
```

> Restic remet les fichiers du snapshot mais **ne supprime pas** les fichiers
> créés après le snapshot. C'est préférable à une suppression automatique
> (récupération manuelle possible). **Ne pas lancer `occ files:scan --all`
> aveuglément après restauration** : cela réintroduirait les fichiers
> postérieurs au snapshot.

### F. Réimporter MariaDB

```bash
head -n 10 /var/backups/nextcloud/nextcloud.sql     # "MariaDB dump" attendu

docker compose up -d db redis
# on remplace la base restaurée par le dump cohérent du snapshot :
docker compose exec -T db sh -c \
    'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
        DROP DATABASE IF EXISTS \`$MARIADB_DATABASE\`;
        CREATE DATABASE \`$MARIADB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"'

docker compose exec -T db sh -c \
    'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
    < /var/backups/nextcloud/nextcloud.sql

docker compose up -d
```

### G. Vérifications post-restauration

```bash
docker compose ps
docker compose exec -u33 nextcloud ./occ status
docker compose exec -u33 nextcloud ./occ maintenance:mode --off
docker compose exec -u33 nextcloud ./occ config:app:get core backgroundjobs_mode   # cron
docker compose exec -u33 nextcloud ./occ config:system:get trusted_domains
docker compose exec -u33 nextcloud ./occ config:system:get overwriteprotocol      # https
docker compose exec -u33 nextcloud ./occ onlyoffice:documentserver --check
```

Test navigateur : connexion, fichiers présents, ouverture + modification
d'un document, HTTPS.

### H. Relancer les sauvegardes

```bash
systemctl list-timers --all | grep nextcloud-restic
systemctl start nextcloud-restic-backup.service
restic snapshots --tag nextcloud     # le nouveau snapshot doit apparaître
```

## Variantes de sinistre

**Disque de données également perdu** : installer un nouveau disque, ext4,
monter sur `/mnt/data`, recréer `mkdir -p /mnt/data/nextcloud/data`, puis
restauration Restic normale — **Restic reconstruit intégralement les
données utilisateurs**.

**Hyperviseur perdu** (disques de données et de backup survivent) :
réinstaller Proxmox → monter le disque de backup par UUID → recréer le
storage `usb-backup` → restaurer le VZDump → rattacher le disque de données
→ démarrer → restauration Restic → import MariaDB → up.

## À conserver hors infrastructure

- **Le mot de passe Restic** (sans lui : dépôt chiffré inutilisable) —
  gestionnaire de mots de passe externe.
- La présente procédure (copie hors Nextcloud).
- Les informations DNS et, le cas échéant, la clé/secret du domaine.
