#!/bin/bash
set -euo pipefail

###########################################################
#  PVE-SCRIPTS-LOCAL - HEALTHCHECK + CHECK DES SCRIPTS    #
###########################################################

# === CONFIG ===
WEBHOOK="<DISCORD_WEBHOOK_URL>"

APP_DIR="/opt/ProxmoxVE-Local"
LOCAL_SCRIPTS_DIR="${APP_DIR}/scripts"

STATE_DIR="/var/lib/pve-scripts-local"
LOG_DIR="/var/log/pve-scripts-local"
MAX_DISCORD_CHARS=1900   # marge sous 2000

mkdir -p "$STATE_DIR" "$LOG_DIR"

BASELINE="${STATE_DIR}/scripts_baseline.txt"
NOW="$(date '+%Y-%m-%dT%H-%M-%S%z')"
LOG_FILE="${LOG_DIR}/pve-scripts-local_status_${NOW}.log"

timestamp() {
    date '+[%Y-%m-%dT%H:%M:%S%z]'
}

log() {
    echo "$(timestamp) $*" >>"$LOG_FILE"
}

# === jq (prérequis) ===
if ! command -v jq >/dev/null 2>&1; then
    echo "$(timestamp) jq non trouvé, installation..." >>"$LOG_FILE"
    apt update -y >>"$LOG_FILE" 2>&1
    apt install -y jq >>"$LOG_FILE" 2>&1
fi

# === INFOS SYSTEME ===
OS_NAME="$(
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${PRETTY_NAME}"
    else
        echo "Debian (inconnu)"
    fi
)"

HOSTNAME="$(hostname)"
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "${IP_ADDR}" ]; then
    IP_ADDR="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || echo 'N/A')"
fi

UPTIME_HUMAN="$(uptime -p 2>/dev/null | sed 's/^up //')"
UPTIME_SINCE="$(uptime -s 2>/dev/null || echo 'N/A')"
LOADAVG="$(cut -d' ' -f1-3 /proc/loadavg)"
MEM_SUMMARY="$(free -h | awk 'NR==2 {print $3 "/" $2 " used"}')"

DISK_SUMMARY="$(df -h / "$APP_DIR" 2>/dev/null | awk 'NR==1 {print} NR>1 {print}')"

# === INFOS PVE SCRIPTS LOCAL ===
APP_VERSION="N/A"
[ -f "${APP_DIR}/VERSION" ] && APP_VERSION="$(tr -d '\r\n' < "${APP_DIR}/VERSION")"

NODE_VERSION="$(node -v 2>/dev/null || echo 'node non trouvé')"

SERVICE_STATUS="inconnu"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet pvescriptslocal; then
        SERVICE_STATUS="active"
    else
        SERVICE_STATUS="$(systemctl is-active pvescriptslocal 2>/dev/null || echo 'not-found')"
    fi
else
    SERVICE_STATUS="systemctl non disponible"
fi

APP_HTTP_STATUS="N/A"
if command -v curl >/dev/null 2>&1; then
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 'http://127.0.0.1:3000' || echo '')"
    if [ -n "$HTTP_CODE" ]; then
        APP_HTTP_STATUS="UP (HTTP ${HTTP_CODE})"
    else
        APP_HTTP_STATUS="DOWN (pas de réponse HTTP sur 127.0.0.1:3000)"
    fi
else
    APP_HTTP_STATUS="curl non installé"
fi

# === HEADER LOG ===
echo "$(timestamp) ===== Etat du conteneur pve-scripts-local =====" >"$LOG_FILE"
log "OS              : $OS_NAME"
log "Hostname        : $HOSTNAME"
log "Adresse IP      : $IP_ADDR"
log "Uptime (humain) : $UPTIME_HUMAN"
log "Uptime depuis   : $UPTIME_SINCE"
log "Charge moyenne  : $LOADAVG"
log "Mémoire         : $MEM_SUMMARY"
log ""
log "===== Etat PVE Scripts Local ====="
log "Répertoire APP  : $APP_DIR"
log "Version APP     : $APP_VERSION"
log "Version Node    : $NODE_VERSION"
log "Service         : $SERVICE_STATUS"
log "HTTP (3000)     : $APP_HTTP_STATUS"
log ""
log "===== Disques (df -h) ====="
printf '%s\n' "$DISK_SUMMARY" >>"$LOG_FILE"
log ""

# === INFOS SCRIPTS LOCAUX ===
if [ -d "$LOCAL_SCRIPTS_DIR" ]; then
    SCRIPT_COUNT="$(find "$LOCAL_SCRIPTS_DIR" -type f 2>/dev/null | wc -l || echo 0)"
    SCRIPTS_SIZE="$(du -sh "$LOCAL_SCRIPTS_DIR" 2>/dev/null | awk '{print $1}' || echo '0')"
else
    SCRIPT_COUNT=0
    SCRIPTS_SIZE="0"
fi

log "===== Scripts locaux dans ${LOCAL_SCRIPTS_DIR} ====="
log "Nombre de fichiers : $SCRIPT_COUNT"
log "Taille totale      : $SCRIPTS_SIZE"
log ""

# === FONCTION ETAT COURANT DES SCRIPTS ===
generate_state() {
    if [ ! -d "$LOCAL_SCRIPTS_DIR" ]; then
        return 0
    fi
    # format : chemin_relatif|taille|mtime_epoch
    find "$LOCAL_SCRIPTS_DIR" -type f -printf '%P|%s|%T@\n' 2>/dev/null | sort
}

TMP_CURRENT="$(mktemp)"
TMP_BASE_FILES="$(mktemp)"
TMP_CUR_FILES="$(mktemp)"
TMP_MODIFIED="$(mktemp)"

generate_state >"$TMP_CURRENT" || true

SUMMARY_CHANGES=""

if [ ! -s "$BASELINE" ]; then
    # Première exécution -> baseline
    cp "$TMP_CURRENT" "$BASELINE"
    log "Première exécution : baseline des scripts créée."
    log "Tous les fichiers actuels ($SCRIPT_COUNT) sont considérés comme l'état de référence."
    SUMMARY_CHANGES="Initialisation de la baseline des scripts ($SCRIPT_COUNT fichiers)."
else
    # Comparaison avec baseline existante
    cut -d'|' -f1 "$BASELINE" >"$TMP_BASE_FILES"
    cut -d'|' -f1 "$TMP_CURRENT" >"$TMP_CUR_FILES"

    NEW_FILES="$(comm -13 "$TMP_BASE_FILES" "$TMP_CUR_FILES" || true)"
    DEL_FILES="$(comm -23 "$TMP_BASE_FILES" "$TMP_CUR_FILES" || true)"
    COMMON_FILES="$(comm -12 "$TMP_BASE_FILES" "$TMP_CUR_FILES" || true)"

    : >"$TMP_MODIFIED"
    if [ -n "$COMMON_FILES" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            base_line="$(grep -F "^$f|" "$BASELINE" || true)"
            cur_line="$(grep -F "^$f|" "$TMP_CURRENT" || true)"
            if [ -n "$base_line" ] && [ -n "$cur_line" ] && [ "$base_line" != "$cur_line" ]; then
                echo "$f" >>"$TMP_MODIFIED"
            fi
        done <<< "$COMMON_FILES"
    fi

    NEW_COUNT="$(printf '%s\n' "$NEW_FILES" | sed '/^$/d' | wc -l)"
    DEL_COUNT="$(printf '%s\n' "$DEL_FILES" | sed '/^$/d' | wc -l)"
    MOD_COUNT="$(sed '/^$/d' "$TMP_MODIFIED" | wc -l)"

    log "===== Changements dans ${LOCAL_SCRIPTS_DIR} ====="
    log "Nouveaux fichiers : $NEW_COUNT"
    if [ "$NEW_COUNT" -gt 0 ]; then
        printf '%s\n' "$NEW_FILES" | sed 's/^/  + /' >>"$LOG_FILE"
    fi

    log "Fichiers supprimés : $DEL_COUNT"
    if [ "$DEL_COUNT" -gt 0 ]; then
        printf '%s\n' "$DEL_FILES" | sed 's/^/  - /' >>"$LOG_FILE"
    fi

    log "Fichiers modifiés : $MOD_COUNT"
    if [ "$MOD_COUNT" > 0 ]; then
        sed 's/^/  * /' "$TMP_MODIFIED" >>"$LOG_FILE"
    fi

    SUMMARY_CHANGES="${NEW_COUNT} nouveau(x), ${DEL_COUNT} supprimé(s), ${MOD_COUNT} modifié(s)."
fi

# Mise à jour de la baseline
mv "$TMP_CURRENT" "$BASELINE"
rm -f "$TMP_BASE_FILES" "$TMP_CUR_FILES" "$TMP_MODIFIED"

log ""
log "Fin du rapport pour pve-scripts-local."

# === MESSAGE DISCORD (RESUME) ===
SUMMARY=$(
cat <<EOF
📦 **[pve-scripts-local] Etat LXC & scripts**

- Hostname    : $HOSTNAME
- IP          : $IP_ADDR
- OS          : $OS_NAME
- Uptime      : $UPTIME_HUMAN (depuis $UPTIME_SINCE)
- Charge      : $LOADAVG
- Mémoire     : $MEM_SUMMARY

- App dir     : $APP_DIR
- Version APP : $APP_VERSION
- Node        : $NODE_VERSION
- Service     : $SERVICE_STATUS
- HTTP :3000  : $APP_HTTP_STATUS

- Scripts loc : $SCRIPT_COUNT fichiers, $SCRIPTS_SIZE
- Changements : $SUMMARY_CHANGES

(Log détaillé en pièce jointe.)
EOF
)

LEN=${#SUMMARY}
if [ "$LEN" -gt "$MAX_DISCORD_CHARS" ]; then
    SUMMARY="${SUMMARY:0:$MAX_DISCORD_CHARS}"
    SUMMARY="${SUMMARY%?}...
(Contenu tronqué, voir la pièce jointe.)"
fi

PAYLOAD_JSON="$(printf '%s\n' "$SUMMARY" | jq -Rs '{content: .}')"

# === ENVOI DISCORD AVEC FICHIER JOINT ===
curl -sS -X POST \
  -F "payload_json=$PAYLOAD_JSON" \
  -F "file=@${LOG_FILE};type=text/plain" \
  "$WEBHOOK" >/dev/null 2>&1
