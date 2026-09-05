#!/usr/bin/env bash
#
# MiroFish one-liner for Proxmox VE (Community-Scripts style)
# Host-side: creates/updates an LXC container and installs MiroFish inside.
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)"
#
# Alternative mit expliziter CT-ID:
#   CTID=150 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)"
#
set -euo pipefail

# ---------------------------------------------------------------- Variables --
APP="MiroFish"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main}"
INNER_SCRIPT_PATH="install/mirofish-install.sh"
# Muss zu INSTALLER_VERSION in install/mirofish-install.sh passen.
# Schutz vor veraltetem raw.githubusercontent.com-Cache: Bei Mismatch wird
# NICHT stillschweigend eine alte Version installiert, sondern neu geladen
# (Retry) bzw. per GitHub-API-Fallback geholt oder abgebrochen.
EXPECTED_INSTALLER_VERSION="2026-09-05-fix3"
GITHUB_REPO="${GITHUB_REPO:-HatchetMan111/MiroFish-Proxmox}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

CTID="${CTID:-150}"
HOSTNAME="${HOSTNAME:-mirofish}"
CPU="${CPU:-4}"
RAM="${RAM:-4096}"
SWAP="${SWAP:-512}"
DISK="${DISK:-12}"
STORAGE="${STORAGE:-local-lvm}"          # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # vztmpl storage
BRIDGE="${BRIDGE:-vmbr0}"
OS_TEMPLATE="${OS_TEMPLATE:-}"           # leer = auto (debian-12-standard)
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"

FRONTEND_PORT="3000"
BACKEND_PORT="5001"

# ------------------------------------------------------- Error chain / debug --
# Volle Fehlermeldungskette statt nur letzter Zeile (Anforderung #4).
# Bei Installationsfehlern: mit 'bash -x ...' erneut laufen lassen.
trap_err() {
  local ec=$?
  echo "==================================================================" >&2
  echo "[${APP}] FEHLER (exit=${ec})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Stack  :" >&2
  local i=0
  while caller $i >&2; do ((i++)); done
  echo "Hinweis: Re-run mit Debug-Log:" >&2
  # shellcheck disable=SC2016
  echo '  bash -x -c "$(wget -qLO - .../mirofish.sh)"' >&2
  echo "==================================================================" >&2
  exit "${ec}"
}
trap trap_err ERR

log()  { echo "[${APP}] $*"; }
die()  { echo "[${APP}] FEHLER: $*" >&2; exit 1; }

# ------------------------------------------------------------------ Checks ---
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden. Auf dem Proxmox-Host ausfuehren."
command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden. Auf dem Proxmox-Host ausfuehren."

# CTID aus $1 erlauben: 'bash mirofish.sh 150'
if [[ "${1:-}" =~ ^[0-9]{3,}$ ]]; then CTID="$1"; fi

# ------------------------------------------------------- Template handling ---
log "Aktualisiere Template-Liste (pveam update) ..."
pveam update

if [[ -z "${OS_TEMPLATE}" ]]; then
  # Debian 12: passt zu MiroFish requires-python >=3.11,<3.13 (Bookworm = Python 3.11).
  # Debian 13 (Trixie, Python 3.13) wuerde nur via uv-gemanagtem Python laufen.
  OS_TEMPLATE="$(pveam available --section system 2>/dev/null \
    | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1 || true)"
  [[ -n "${OS_TEMPLATE}" ]] || die "Kein debian-12-standard Template in 'pveam available' gefunden."
fi
log "OS-Template: ${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}"

if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${OS_TEMPLATE}"; then
  log "Lade Template ${OS_TEMPLATE} ..."
  pveam download "${TEMPLATE_STORAGE}" "${OS_TEMPLATE}"
else
  log "Template bereits vorhanden, kein Download noetig (idempotent)."
fi

# ------------------------------------------------------- Container create ----
if pct status "${CTID}" >/dev/null 2>&1; then
  log "Container ${CTID} existiert bereits -> kein pct create (idempotent)."
else
  log "Erstelle LXC ${CTID} (${CPU} vCPU, ${RAM} MB RAM, ${DISK}G Disk) ..."
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --cores "${CPU}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --ostype debian \
    --unprivileged "${UNPRIVILEGED}" \
    --features "nesting=1" \
    --onboot "${ONBOOT}" \
    --start 0
  log "Container ${CTID} erstellt."
fi

# onboot immer sicherstellen (reboot-sicher, Anforderung #6)
pct set "${CTID}" --onboot "${ONBOOT}" || true

# ------------------------------------------------------------------ Start ----
if [[ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]]; then
  log "Starte Container ${CTID} ..."
  pct start "${CTID}"
else
  log "Container ${CTID} laeuft bereits."
fi

log "Warte auf Netzwerk im Container ..."
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then break; fi
  if [[ "$i" == "30" ]]; then die "Container hat kein Netzwerk (ping 8.8.8.8 schlaegt fehl)."; fi
  sleep 2
done

# ------------------------------------------------------- Inner script push ---
TMP_INNER="$(mktemp)"
trap 'rm -f "${TMP_INNER:-}"' EXIT

installer_hat_marker() {
  grep -q "INSTALLER_VERSION=\"${EXPECTED_INSTALLER_VERSION}\"" "${TMP_INNER}" 2>/dev/null
}

# raw.githubusercontent.com cacht aggressiv (Query-String-Bypass wirkt nicht
# zuverlaessig). Deshalb: Version marker pruefen, Retry mit Wartezeit, danach
# Fallback ueber die GitHub-Contents-API (base64, eigener Cache, i.d.R. frisch).
INNER_OK=0
for attempt in $(seq 1 6); do
  INNER_URL="${REPO_RAW_BASE}/${INNER_SCRIPT_PATH}?cb=${RANDOM}$(date +%s)"
  log "Lade Installer (Versuch ${attempt}/6): ${REPO_RAW_BASE}/${INNER_SCRIPT_PATH}"
  if wget -qO "${TMP_INNER}" "${INNER_URL}" && installer_hat_marker; then
    log "Installer-Version ${EXPECTED_INSTALLER_VERSION} bestaetigt."
    INNER_OK=1
    break
  fi
  log "Installer-Version ${EXPECTED_INSTALLER_VERSION} noch nicht im CDN (veralteter Cache), warte 20s ..."
  sleep 20
done

if [[ "${INNER_OK}" != "1" ]]; then
  log "Fallback: lade Installer ueber GitHub-API ..."
  API_JSON="$(mktemp)"
  if curl -fsSL --max-time 30 \
      "https://api.github.com/repos/${GITHUB_REPO}/contents/${INNER_SCRIPT_PATH}?ref=${GITHUB_BRANCH}" \
      -o "${API_JSON}" \
    && python3 -c "import json,base64,sys; d=json.load(open('${API_JSON}')); sys.stdout.buffer.write(base64.b64decode(d['content']))" > "${TMP_INNER}" \
    && installer_hat_marker; then
    log "Installer per API-Fallback geladen (Version ${EXPECTED_INSTALLER_VERSION} bestaetigt)."
    INNER_OK=1
  fi
  rm -f "${API_JSON}"
fi

if [[ "${INNER_OK}" != "1" ]]; then
  die "Geladener Installer hat NICHT Version ${EXPECTED_INSTALLER_VERSION} (CDN-Cache veraltet). 5-10 Min warten und erneut laufen lassen. Diagnose: wget -qO- ${REPO_RAW_BASE}/${INNER_SCRIPT_PATH} | grep INSTALLER_VERSION"
fi
bash -n "${TMP_INNER}" || die "Syntaxfehler im geladenen Installer (bash -n fehlgeschlagen)."
pct push "${CTID}" "${TMP_INNER}" /root/mirofish-install.sh
rm -f "${TMP_INNER}"; trap - EXIT

log "Fuehre Installation im Container aus (kann mehrere Minuten dauern: Node+Python+Build) ..."
pct exec "${CTID}" -- bash /root/mirofish-install.sh

# ------------------------------------------------------------------ Verify ---
CT_IP="$(pct exec "${CTID}" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -n "${CT_IP:-}" ]] || CT_IP="<LXC-IP>"

echo ""
echo "=================================================================="
echo " ${APP} Installation abgeschlossen"
echo "=================================================================="
echo " Container : ${CTID} (${HOSTNAME})"
echo " Frontend  : http://${CT_IP}:${FRONTEND_PORT}"
echo " Backend   : http://${CT_IP}:${BACKEND_PORT}/health  (API: /api/...)"

if [[ "${CT_IP}" != "<LXC-IP>" ]]; then
  if wget -qO- --timeout=5 "http://${CT_IP}:${FRONTEND_PORT}" >/dev/null 2>&1; then
    echo " Check    : Frontend antwortet auf Port ${FRONTEND_PORT} (OK)"
  else
    echo " Check    : Frontend antwortet NICHT (Fehlerkette oben pruefen)."
    echo "            Im Container: systemctl status mirofish-backend nginx; journalctl -u mirofish-backend -e --no-pager"
  fi
fi
echo ""
echo " Naechste Schritte:"
echo "  1) API-Keys eintragen (Platzhalter!):"
echo "       pct enter ${CTID}"
echo "       nano /opt/mirofish/.env   # LLM_API_KEY, ZEP_API_KEY setzen"
echo "       systemctl restart mirofish-backend"
echo "  2) Update:  pct exec ${CTID} -- bash /root/mirofish-install.sh"
echo "  3) Löschen: pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
