# Serveur maison : Jellyfin, Navidrome et seedbox sous VPN

Un vieux ThinkPad recyclé en serveur multimédia allumé 24h/24 :

- **Jellyfin** : films et séries, accessible depuis internet en HTTPS ;
- **Navidrome** : musique, accessible depuis internet en HTTPS ;
- **qBittorrent** : seedbox enfermée dans un tunnel **Proton VPN**, avec
  **kill switch** : si le VPN tombe, qBittorrent n'a plus aucun accès à internet,
  et aucune fuite d'IP (IPv4 ou IPv6) n'est possible.

Projet réalisé pas à pas en s'aidant de claude code, dont j'ai fais réaliser un historique des
differentes commandes et bugs rencontrés tout du long. Il est disponible ici > [`HISTORIQUE.txt`](HISTORIQUE.txt).

## Matériel

| Élément | Rôle |
|---|---|
| ThinkPad X1 Carbon 3e gen (sans batterie), Debian 13 sans bureau | Le serveur |
| SSD interne 128 Go | Système + configurations des applis |
| SSD Crucial X9 1 To (USB) | Bibliothèque de médias (`/mnt/medias`) |
| SSD Samsung 860 EVO 1 To (ex-PS4, boîtier USB) | Téléchargements + sauvegardes (`/mnt/telechargements`) |
| Dock OneLink Pro | Connexion Ethernet |

## Architecture

```
                    Internet
        ┌──────────────┴───────────────────┐
        │ HTTPS (443)                       │ Tunnel WireGuard chiffré
        ▼                                   ▼
   Livebox (redirection 80/443)        Proton VPN (Suisse...)
        │                                   ▲
        ▼                                   │
 ┌──────────────────────── Serveur (Docker) ─┼───────────────────┐
 │  Caddy (reverse proxy + certificats)      │                   │
 │    ├── jellyfin.xxx.duckdns.org ─► Jellyfin                   │
 │    └── navidrome.xxx.duckdns.org ─► Navidrome                 │
 │                                           │                   │
 │  Gluetun (client VPN + pare-feu) ◄────────┘                   │
 │    └── qBittorrent (partage le réseau de Gluetun = kill switch)│
 │                                                               │
 │  DuckDNS (met à jour l'IP publique de la box)                 │
 └───────────────────────────────────────────────────────────────┘
   Administration à distance : Tailscale uniquement (jamais exposée)
```

## Contenu du dépôt

| Fichier / dossier | Rôle |
|---|---|
| `compose.yaml` | Définition des 6 conteneurs (gluetun, qbittorrent, jellyfin, navidrome, duckdns, caddy) |
| `Caddyfile` | Reverse proxy HTTPS (certificats Let's Encrypt automatiques) |
| `.env.exemple` | Modèle du fichier des secrets (le vrai `.env` n'est jamais publié) |
| `gluetun/` | Droits d'accès au serveur de contrôle de Gluetun |
| `surveillance/` | Script + minuterie systemd : vérifie que le port redirigé par Proton est bien celui de qBittorrent |
| `sauvegarde/` | Sauvegardes automatiques avec restic |
| `maintenance/` | Routine de mises à jour |
| `systemd/` | Docker attend que les disques soient montés avant de démarrer |
| `fail2ban/` | Bannissement des robots qui tentent des mots de passe |
| `apt/` | Mises à jour de sécurité automatiques de Debian |
| `tailscale/` | Dépôt de paquets Tailscale |
| `HISTORIQUE.txt` | **Le journal complet du projet** |

## Les grandes étapes

0. État des lieux
1. Préparation des disques (effacement, ext4)
2. Montage automatique (`/etc/fstab`)
3. Serveur allumé 24h/24 (veille désactivée)
4. Adresse IP fixe (bail DHCP statique sur la Livebox)
5. Installation de Docker
6. Organisation des dossiers
7. Tunnel VPN (Gluetun + Proton VPN WireGuard, redirection de port)
8. qBittorrent dans le réseau de Gluetun
9. Test du kill switch
10. Jellyfin et Navidrome (accès local)
11. Accès depuis internet (DuckDNS, Caddy, HTTPS, fail2ban)
12. Élargissement des serveurs VPN
13. Tailscale (administration à distance sans rien exposer)
14. Sauvegardes (restic + minuterie systemd, test de restauration)
15. Protection « disque absent »
16. Surveillance automatique du port VPN
17. Routine de mises à jour
18. Test de redémarrage complet

## Remettre en service

```bash
cp .env.exemple .env && nano .env && chmod 600 .env
docker compose config --quiet   # vérifie la syntaxe
docker compose up -d
docker exec qbittorrent curl -s https://ifconfig.co   # doit afficher l'IP du VPN, PAS celle de la box
```

Les chemins (`/mnt/medias`, `/mnt/telechargements`, `/srv/appdata`) et le
détail de chaque étape sont expliqués dans `HISTORIQUE.txt`.
