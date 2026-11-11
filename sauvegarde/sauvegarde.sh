#!/bin/bash
# ==========================================================================
#  Sauvegarde quotidienne du serveur maison (restic)
#  Lancée par la minuterie systemd sauvegarde.timer (04h30), en tant que
#  saaos. Journal : journalctl -u sauvegarde
# ==========================================================================
set -euo pipefail   # arrêt à la 1re erreur, variable inconnue = erreur

export RESTIC_REPOSITORY=/mnt/telechargements/sauvegardes/restic
export RESTIC_PASSWORD_FILE=/home/saaos/.config/restic/mot-de-passe
COMPOSE="docker compose -f /home/saaos/serveur-maison/compose.yaml"
APPS="jellyfin navidrome qbittorrent"   # applis qui écrivent des bases

journal() { echo "[$(date '+%F %T')] $*"; }

# 1. Garde-fou : le disque est monté avec "nofail". S'il manque, le dossier
#    /mnt/telechargements existe quand même (vide) SUR LE SSD SYSTÈME :
#    sans ce test, la sauvegarde remplirait le SSD système en silence.
if ! mountpoint -q /mnt/telechargements; then
	journal "ERREUR : /mnt/telechargements n'est pas monté. Annulé."
	exit 1
fi

# 2. Arrêt des applis : une base SQLite copiée pendant une écriture peut
#    être incohérente. "trap" garantit le redémarrage MÊME si la suite
#    échoue (sinon une erreur laisserait Jellyfin éteint).
redemarrer() { journal "Redémarrage : $APPS"; $COMPOSE start $APPS; }
journal "Arrêt : $APPS"
$COMPOSE stop $APPS
trap redemarrer EXIT

# 3. Sauvegarde (chiffrée, dédupliquée)
journal "Sauvegarde..."
restic backup --tag quotidienne \
	--exclude /srv/appdata/jellyfin/cache \
	--exclude /srv/appdata/navidrome/cache \
	/srv/appdata \
	/home/saaos/serveur-maison \
	/etc/fstab /etc/default/grub /etc/network/interfaces \
	/etc/systemd/logind.conf.d \
	/etc/fail2ban/jail.d /etc/fail2ban/filter.d/caddy-auth.conf \
	/etc/apt/sources.list.d

# 4. Redémarrage immédiat (le ménage qui suit peut être long)
trap - EXIT
redemarrer

# 5. Rétention : 7 quotidiennes, 4 hebdomadaires, 6 mensuelles
journal "Ménage des anciennes sauvegardes..."
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6

# 6. Contrôle d'intégrité du dépôt
restic check
journal "Sauvegarde terminée avec succès."
