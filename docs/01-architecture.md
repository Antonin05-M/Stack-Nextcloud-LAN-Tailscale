# 01 — Architecture

## Vue d'ensemble

Une **VM Debian 12** hébergée sur **Proxmox VE** fait tourner en Docker :

```
Nextcloud 34 (Apache) + MariaDB LTS + Redis + Cron + ONLYOFFICE 9.4 + Nginx
```

Le point d'entrée unique est **Nginx en TLS** (`:443`). Nextcloud et ONLYOFFICE
communiquent entre eux en HTTP sur le réseau Docker interne — le TLS se termine
au reverse proxy.

```
                 INTERNET
                    │
        aucun port 80/443 publié      X
                    │
   POSTE LAN ───────┴─────── POSTE DISTANT
                              │
                              │ Tailscale (subnet router + ACL)
                              ▼
              https://cloud.example.com  →  192.168.1.20 (IP privée)
                              │
                         NGINX :443 (TLS)
                    ┌───────┴───────┐
                    ▼               ▼
                NEXTCLOUD       ONLYOFFICE (/editors/)
                    │
              ┌─────┴─────┐
              ▼           ▼
           MARIADB      REDIS
```

## L'astuce centrale : nom DNS public → IP privée

Le DNS public contient un enregistrement :

```
cloud.example.com.  A  192.168.1.20
```

C'est **volontaire**. Le nom est résolvable partout, mais l'adresse est une
**IP privée RFC 1918, non routable depuis Internet** :

| Depuis | Résolution | Accessible ? |
|---|---|---|
| LAN | `192.168.1.20` | ✅ directement |
| Poste distant avec Tailscale (subnet routing `192.168.1.0/24`) | `192.168.1.20` | ✅ via le VPN |
| Internet sans VPN | `192.168.1.20` | ❌ non routable |

**Aucune redirection de port 80/443 n'est faite sur la box.**

> ⚠️ Certains DNS de box grand public filtrent la résolution d'un nom public
> vers une IP privée (réponse NXDOMAIN alors que 1.1.1.1 / 8.8.8.8 répondent
> correctement). Dans ce cas, utiliser un DNS public sur les postes concernés,
> ou mettre en place un split-DNS local.
>
> Diagnostic indépendant du DNS :
> ```bash
> curl -I --resolve cloud.example.com:443:192.168.1.20 https://cloud.example.com
> # attendu : 302 -> https://cloud.example.com/login
> ```

## Pourquoi un certificat Let's Encrypt est possible sans exposition

Le challenge **DNS-01** prouve le contrôle du domaine par un enregistrement
TXT `_acme-challenge.cloud.example.com` : Let's Encrypt **n'a jamais besoin de
joindre le serveur**. On obtient donc un certificat public valide pour un
serveur injoignable depuis Internet. Le renouvellement est automatisé via
l'API DNS de l'hébergeur (voir [`05-renouvellement-tls.md`](05-renouvellement-tls.md)).

## Hyperviseur (Proxmox VE)

- Mini-PC bare metal, SSD système pour PVE et le disque système des VM.
- **Disque de données ~2 To** présenté directement à la VM (pas un volume
  PVE) : il apparaît dans Debian comme `/dev/vda`, monté sur `/mnt/data`.
- **Disque de sauvegarde ~2 To** monté sur l'hyperviseur : `/mnt/backup-usb`.

### Montage du disque de données — le piège `nofail`

```
UUID=<UUID-DISQUE-DATA> /mnt/data ext4 noatime,discard,x-systemd.device-timeout=30s 0 2
```

**`nofail` est volontairement absent.** Si le disque de données ne monte pas,
le démarrage s'arrête là : Nextcloud ne peut pas écrire accidentellement dans
un faux `/mnt/data` sur le disque système. C'est un choix de sûreté assumé.

```bash
findmnt /mnt/data     # doit pointer sur le disque dédié
df -hT /mnt/data
```

### Disque de sauvegarde — ici `nofail` est volontaire

```
UUID=<UUID-DISQUE-BACKUP> /mnt/backup-usb ext4 defaults,noatime,nofail,x-systemd.device-timeout=30s 0 2
```

L'hyperviseur doit pouvoir démarrer même si le disque USB de backup est
absent. Pour éviter que PVE écrive sur son SSD système quand le disque est
démonté, le storage est déclaré avec `is_mountpoint` :

```bash
pvesm add dir usb-backup --path /mnt/backup-usb --content backup
pvesm set usb-backup --is_mountpoint 1
```

### Passage du disque de données à la VM

Le disque est attaché par `/dev/disk/by-id/` (stable), **exclu du backup VZDump** :

```
virtio1: /dev/disk/by-id/<ID-STABLE-DU-DISQUE>,discard=on,iothread=1,backup=0
```

`backup=0` est le point essentiel : VZDump ne copie pas ~2 To de données à
chaque sauvegarde de VM — c'est Restic qui gère les données applicatives.

## Répartition du stockage

| Élément | Stockage |
|---|---|
| Fichiers utilisateurs | `/mnt/data/nextcloud/data` (disque dédié) |
| Nextcloud config/apps | volume Docker `nextcloud` (disque système VM) |
| MariaDB | volume Docker `db` (disque système VM) |
| Redis | volatil (cache) |
| ONLYOFFICE | volumes Docker |
| Compose / secrets / Nginx | `/opt/nextcloud` |
| Certificats | `/opt/nextcloud/certbot/etc` |

Pourquoi ce découpage : si le disque de données a un problème, Docker,
MariaDB et la configuration restent fonctionnels et le diagnostic est simple.

## Accès distant : Tailscale

- Un **subnet router** publie la route `192.168.1.0/24` dans le tailnet.
- Les **ACL** n'autorisent chaque poste distant qu'à joindre les services
  nécessaires — pas de peer-to-peer généralisé.
- Le poste distant utilise exactement la même URL `https://cloud.example.com`
  que sur le LAN. Rien à changer côté Tailscale lors du passage en HTTPS.

## État final de référence

| Brique | État |
|---|---|
| Stack 6 services Docker | ✅ en production |
| HTTPS Let's Encrypt (DNS-01) + renouvellement auto | ✅ |
| Accès LAN + Tailscale, zéro port publié | ✅ |
| VZDump quotidien (VM, sans disque data) | ✅ |
| Restic chiffré quotidien + rétention hebdo | ✅ |
| Restaurations SQL et fichier testées | ✅ |
