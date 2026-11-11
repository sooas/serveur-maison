#!/bin/bash
# ==========================================================================
#  Rappel affiché à chaque ouverture de session (SSH ou console)
#  Appelé depuis ~/.bashrc. Doit rester RAPIDE (< 1 s) et ne rien modifier.
#  Ne dit rien d'alarmant quand tout va bien : une seule ligne verte.
# ==========================================================================
SEUIL_JOURS=30
ETAT="$HOME/.local/state/mise-a-jour/derniere-execution"
alertes=()

# 1. Routine mensuelle des conteneurs (maintenance/mise-a-jour.sh)
if [ -f "$ETAT" ]; then
  jours=$(( ( $(date +%s) - $(cat "$ETAT") ) / 86400 ))
  if (( jours >= SEUIL_JOURS )); then
    alertes+=("Routine de mise à jour faite il y a $jours jours -> ~/serveur-maison/maintenance/mise-a-jour.sh")
  fi
else
  alertes+=("Routine de mise à jour jamais lancée -> ~/serveur-maison/maintenance/mise-a-jour.sh")
fi

# 2. Redémarrage demandé par un paquet (nouveau noyau...)
if [ -f /var/run/reboot-required ]; then
  alertes+=("Redémarrage nécessaire ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)) -> sudo reboot")
fi

# 3. Paquets en attente (Docker, Tailscale : jamais installés seuls)
n=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
if (( n > 0 )); then
  alertes+=("$n paquet(s) en attente -> sudo apt update && sudo apt full-upgrade")
fi

# 4. Services systemd en échec (une sauvegarde ratée, par exemple)
echecs=$(systemctl list-units --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -n "$echecs" ]; then
  alertes+=("Service(s) en échec : $echecs-> systemctl status <nom>")
fi

# Affichage (\e[...m = couleurs du terminal : 32 vert, 33 jaune, 0 normal)
if (( ${#alertes[@]} == 0 )); then
  printf '\e[32m[serveur] Tout est à jour, aucun service en échec.\e[0m\n'
else
  printf '\e[33m[serveur] A faire :\e[0m\n'
  printf '  - %s\n' "${alertes[@]}"
fi
