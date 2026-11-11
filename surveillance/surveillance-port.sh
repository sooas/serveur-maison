#!/bin/bash
# ==========================================================================
#  Surveillance de la redirection de port VPN (Gluetun -> qBittorrent)
#  Lancé toutes les 5 min par surveillance-port.timer (systemd).
#  Ce qu'il écrit (echo) va dans le journal :
#      journalctl -u surveillance-port.service
#
#  Faiblesse corrigée : si Proton refuse la redirection de port AU MOMENT
#  où le tunnel s'ouvre ("[vpn] ... port forwarding for the first time"),
#  Gluetun n'insiste pas -> qBittorrent reste joignable par personne.
#  (Tunnel déjà ouvert, Gluetun réessaie seul toutes les 5 s : on le
#  laisse faire, d'où l'attente de confirmation avant d'agir.)
#
#  SÉCURITÉ : ce script ne touche JAMAIS au pare-feu de Gluetun. Pendant
#  une relance du tunnel, le kill switch reste actif (testé à l'étape 9).
# ==========================================================================
set -uo pipefail     # pas de -e : on teste nous-mêmes chaque résultat

ATTENTE_CONFIRMATION=60    # s : un renouvellement raté se répare en < 30 s
DELAI_ENTRE_RELANCES=900   # s : au plus 1 relance du tunnel / 15 min
# Dossier d'état : fourni par systemd (StateDirectory=), sinon pour un
# lancement à la main :
ETAT="${STATE_DIRECTORY:-$HOME/.local/state/surveillance-port}"
mkdir -p "$ETAT"

# api URL... : requête exécutée DANS Gluetun, seul endroit d'où le serveur
# de contrôle (127.0.0.1:8000) et qBittorrent (127.0.0.1:8080) répondent.
api()          { docker exec gluetun wget -qO- -T 10 "$@" 2>/dev/null; }
port_gluetun() { api http://127.0.0.1:8000/v1/portforward | sed -n 's/.*"port":\([0-9]*\).*/\1/p'; }
port_qbit()    { api http://127.0.0.1:8080/api/v2/app/preferences | grep -o '"listen_port":[0-9]*' | cut -d: -f2; }
etat_tunnel()  { api http://127.0.0.1:8000/v1/vpn/status | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p'; }
tunnel()       { api --method=PUT --header='Content-Type: application/json' \
                     --body-data="{\"status\":\"$1\"}" http://127.0.0.1:8000/v1/vpn/status; }

# --- 0. Sauvegarde en cours (elle arrête qBittorrent exprès) -> on ne gêne pas
case "$(systemctl show -p ActiveState --value sauvegarde.service)" in
  active|activating) echo "Sauvegarde en cours : rien à faire."; exit 0 ;;
esac

# --- 1. Gluetun doit tourner ET être en bonne santé
if [ "$(docker inspect -f '{{.State.Status}}' gluetun 2>/dev/null)" != running ]; then
  echo "Gluetun ne tourne pas : rien à faire (qBittorrent est coupé d'internet)."
  exit 0
fi
sante=$(docker inspect -f '{{.State.Health.Status}}' gluetun)
if [ "$sante" != healthy ]; then
  echo "Gluetun '$sante' : il relance le tunnel lui-même, on attend."
  exit 0
fi
if [ "$(etat_tunnel)" != running ]; then
  echo "Tunnel pas encore 'running' : on attend."
  exit 0
fi

# --- 2. qBittorrent : "created" = jamais démarré (bug 4 : Gluetun
#        brièvement malade au démarrage -> depends_on a renoncé)
etat_q=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null)
case "$etat_q" in
  running) ;;
  created)
    echo "qBittorrent créé mais jamais démarré : démarrage."
    docker start qbittorrent >/dev/null || { echo "ECHEC du démarrage."; exit 1; }
    exit 0 ;;
  *)  # exited = arrêté (par toi, probablement) : on respecte
    echo "qBittorrent '${etat_q:-absent}' : arrêt volontaire ? Rien à faire."
    exit 0 ;;
esac

# --- 3. Gluetun a-t-il obtenu un port auprès de Proton ?
p=$(port_gluetun)
if [ -z "$p" ] || [ "$p" = 0 ]; then
  echo "Aucun port redirigé. Nouvelle vérification dans ${ATTENTE_CONFIRMATION} s..."
  sleep "$ATTENTE_CONFIRMATION"
  p=$(port_gluetun)
fi
if [ -z "$p" ] || [ "$p" = 0 ]; then
  maintenant=$(date +%s)
  derniere=$(cat "$ETAT/derniere-relance" 2>/dev/null || echo 0)
  if (( maintenant - derniere < DELAI_ENTRE_RELANCES )); then
    echo "Toujours aucun port, mais tunnel relancé il y a $(( maintenant - derniere )) s : on patiente."
    exit 0
  fi
  echo "Toujours aucun port : relance du tunnel (nouveau tirage de serveur)."
  echo "$maintenant" > "$ETAT/derniere-relance"
  tunnel stopped; echo
  sleep 5
  tunnel running; echo
  echo "Relance demandée ; résultat vérifié au prochain passage."
  exit 0
fi

# --- 4. qBittorrent écoute-t-il sur CE port ?
q=$(port_qbit)
if [ -z "$q" ]; then
  echo "Port $p obtenu, mais qBittorrent ne répond pas encore : on attend."
  exit 0
fi
if [ "$q" != "$p" ]; then
  echo "qBittorrent écoute sur $q au lieu de $p : correction."
  api --post-data="json={\"listen_port\":$p}" http://127.0.0.1:8080/api/v2/app/setPreferences
  if [ "$(port_qbit)" = "$p" ]; then echo "Corrigé : $p."; exit 0; fi
  echo "ECHEC de la correction."; exit 1
fi

echo "OK : port $p (Gluetun = qBittorrent)."
