#!/bin/bash
# ==========================================================================
#  Routine MENSUELLE : mise à jour des images des conteneurs
#  Lancement (pas besoin de sudo) :  ~/serveur-maison/maintenance/mise-a-jour.sh
#
#  Pourquoi pas automatique ? Une nouvelle version peut transformer une base
#  de données (Jellyfin surtout) ou changer un réglage : on veut une
#  sauvegarde fraîche AVANT, quelqu'un pour vérifier APRÈS, et un retour
#  en arrière possible.
#
#  Retour en arrière : les anciennes images restent sur le disque jusqu'à
#  la PROCHAINE exécution (ménage de l'étape 2). Le bilan affiche la
#  commande exacte. Si la base a été transformée : restaurer aussi
#  /srv/appdata/<appli> depuis restic (voir HISTORIQUE, étape 14).
# ==========================================================================
set -euo pipefail

cd /home/saaos/serveur-maison
export RESTIC_REPOSITORY=/mnt/telechargements/sauvegardes/restic
export RESTIC_PASSWORD_FILE=/home/saaos/.config/restic/mot-de-passe
AGE_MAX_SAUVEGARDE=$((26 * 3600))   # 26 h : la sauvegarde tourne à 04h30
ETAT="$HOME/.local/state/mise-a-jour"
mkdir -p "$ETAT"
AVANT="$ETAT/images-avant-$(date +%F-%H%M).txt"

etape()  { echo; echo "=== $* ==="; }
arreter() { echo "ARRÊT : $*" >&2; exit 1; }

# --------------------------------------------------------------------------
etape "1. Vérifications préalables"
case "$(systemctl show -p ActiveState --value sauvegarde.service)" in
  active|activating) arreter "une sauvegarde est en cours, réessaie après." ;;
esac
mountpoint -q /mnt/telechargements || arreter "disque des sauvegardes absent."

# Date de la dernière sauvegarde (--no-lock : simple lecture, ne bloque
# pas une sauvegarde qui démarrerait en même temps)
derniere=$(restic snapshots --no-lock --latest 1 --json \
           | grep -o '"time":"[^"]*"' | tail -n 1 | cut -d'"' -f4)
[ -n "$derniere" ] || arreter "aucune sauvegarde trouvée."
age=$(( $(date +%s) - $(date -d "$derniere" +%s) ))
echo "Dernière sauvegarde : il y a $(( age / 3600 )) h $(( age % 3600 / 60 )) min."
if (( age > AGE_MAX_SAUVEGARDE )); then
  arreter "sauvegarde trop ancienne. Lance d'abord :
  sudo systemctl start sauvegarde.service   (puis relance ce script)"
fi

# --------------------------------------------------------------------------
etape "2. Ménage : images remplacées lors de la mise à jour PRÉCÉDENTE"
# "dangling" = image qui n'a plus de nom (son nom est passé à la nouvelle
# version). On les a gardées un mois pour pouvoir revenir en arrière.
docker image prune -f

# --------------------------------------------------------------------------
etape "3. Versions actuelles (notées dans $AVANT)"
SERVICES=$(docker compose config --services)
for s in $SERVICES; do   # container_name = nom du service partout
  printf '%s %s %s\n' "$s" \
    "$(docker inspect -f '{{.Config.Image}}' "$s")" \
    "$(docker inspect -f '{{.Image}}' "$s")"
done | tee "$AVANT"

# --------------------------------------------------------------------------
etape "4. Téléchargement des nouvelles images"
docker compose pull

# --------------------------------------------------------------------------
etape "5. Application (seuls les conteneurs dont l'image a changé sont recréés)"
docker compose up -d

echo "Attente que tout soit démarré (Gluetun 'healthy', 3 min maxi)..."
ok=non
for _ in $(seq 36); do
  g=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null || echo absent)
  q=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null || echo absent)
  # Bug 4 : Gluetun brièvement malade -> depends_on renonce -> "created"
  if [ "$g" = healthy ] && [ "$q" = created ]; then
    echo "qBittorrent resté 'created' (bug 4) : on le démarre."
    docker compose up -d qbittorrent
  fi
  pas_lances=$(docker compose ps -a --format '{{.Service}} {{.State}}' | grep -vc ' running$' || true)
  if [ "$g" = healthy ] && [ "$pas_lances" = 0 ]; then ok=oui; break; fi
  sleep 5
done
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
[ "$ok" = oui ] || arreter "tout n'a pas redémarré en 3 min (voir ci-dessus, et docker compose logs <service>)."

# --------------------------------------------------------------------------
etape "6. Bilan"
change=0
while read -r s ref ancien; do
  nouveau=$(docker inspect -f '{{.Image}}' "$s")
  version=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$s" 2>/dev/null || true)
  if [ "$nouveau" = "$ancien" ]; then
    echo "  $s : inchangé ${version:+($version)}"
  else
    change=$((change + 1))
    echo "  $s : MIS À JOUR ${version:+-> $version}"
    echo "      retour arrière : docker tag ${ancien#sha256:} $ref && docker compose up -d $s"
  fi
done < "$AVANT"
echo "$change conteneur(s) mis à jour."

# --------------------------------------------------------------------------
etape "7. Redirection de port VPN"
# Si Gluetun a été recréé, le tunnel vient de s'ouvrir : on laisse 90 s
# à Proton, puis la surveillance (étape 16) vérifie / corrige.
for _ in $(seq 18); do
  p=$(docker exec gluetun wget -qO- -T 5 http://127.0.0.1:8000/v1/portforward 2>/dev/null \
      | sed -n 's/.*"port":\([0-9]*\).*/\1/p' || true)
  [ -n "$p" ] && [ "$p" != 0 ] && break
  sleep 5
done
./surveillance/surveillance-port.sh || true

# --------------------------------------------------------------------------
etape "8. Système (Debian, Docker, Tailscale)"
# La liste date du dernier "apt update" (fait chaque nuit par
# unattended-upgrades). Les paquets de sécurité Debian s'installent seuls ;
# Docker et Tailscale restent ici, à faire à la main.
maj=$(apt list --upgradable 2>/dev/null | tail -n +2 || true)
if [ -n "$maj" ]; then
  echo "$maj"
  echo "-> à installer : sudo apt update && sudo apt full-upgrade"
else
  echo "Aucun paquet en attente."
fi
if [ -f /var/run/reboot-required ]; then
  echo "REDÉMARRAGE NÉCESSAIRE, demandé par :"
  sed 's/^/  /' /var/run/reboot-required.pkgs 2>/dev/null || true
  echo "-> sudo reboot   (tout redémarre seul ; vérifier ensuite : docker compose ps)"
else
  echo "Pas de redémarrage nécessaire."
fi

# Date de cette exécution réussie : lue par rappel-connexion.sh (message
# affiché à chaque connexion SSH quand la routine date de plus de 30 jours)
date +%s > "$ETAT/derniere-execution"
