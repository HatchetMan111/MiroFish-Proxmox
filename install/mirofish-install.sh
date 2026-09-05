#!/usr/bin/env bash
#
# MiroFish LXC installer (laeuft IM Container via pct exec).
# Wird vom Host-Script install/mirofish.sh per pct push + pct exec aufgerufen,
# kann aber auch direkt im Container erneut laufen (idempotent, Update-faehig).
#
#   bash /root/mirofish-install.sh
#
# Installiert: Node 22, uv, nginx, MiroFish (Backend Python + Frontend Build),
# systemd-Service mirofish-backend, nginx-VHost auf Port 3000.
#
set -euo pipefail

# ---------------------------------------------------------------- Variables --
APP="MiroFish"
# Version des Installers. Das Host-Script prueft diesen Marker nach dem
# Download (Schutz vor veraltetem CDN-Cache bei raw.githubusercontent.com).
# Bei jeder Aenderung hier: Version erhoehen + EXPECTED_INSTALLER_VERSION
# in install/mirofish.sh angleichen.
INSTALLER_VERSION="2026-09-05-fix3"
APP_DIR="/opt/mirofish"
APP_REPO="${APP_REPO:-https://github.com/666ghj/MiroFish.git}"
APP_BRANCH="${APP_BRANCH:-main}"
FRONTEND_PORT="3000"
BACKEND_PORT="5001"
NODE_MAJOR="22"

# ------------------------------------------------------- Error chain / debug --
# Anforderung: immer komplette Fehlermeldungskette (Stacktrace, stderr/stdout,
# Exit-Codes, Logs), niemals nur letzte Zeile.
trap_err() {
  local ec=$?
  echo "==================================================================" >&2
  echo "[${APP}] INSTALL-FEHLER (exit=${ec})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Stack  :" >&2
  local i=0
  while caller $i >&2; do ((i++)); done
  echo "--- relevante Logs (falls vorhanden) ---" >&2
  journalctl -u mirofish-backend --no-pager -n 50 >&2 || true
  nginx -t 2>&1 >&2 || true
  echo "Tipp: bash -x /root/mirofish-install.sh 2>&1 | tee /root/mirofish-install.log" >&2
  echo "==================================================================" >&2
  exit "${ec}"
}
trap trap_err ERR

log() { echo "[${APP}] $*"; }
die() { echo "[${APP}] FEHLER: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
# pct exec setzt nur ein minimales PATH (ohne /root/.local/bin, teils ohne
# /usr/local/bin). Deshalb PATH hier explizit erweitern, sonst ist frisch
# installiertes uv/node-Zubehoer im selben Lauf nicht auffindbar.
export PATH="/root/.local/bin:/usr/local/bin:/usr/local/sbin:${PATH}"
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ------------------------------------------------------------------ System ---
log "Installer-Version: ${INSTALLER_VERSION}"
log "OS-Check ..."
cat /etc/os-release | head -n3 || true

log "APT: update + Basis-Abhaengigkeiten ..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git iproute2 procps \
  build-essential python3 nginx openssl

# -------------------------------------------------------------------- Node ---
if command -v node >/dev/null 2>&1; then
  log "Node bereits installiert: $(node -v) (idempotent, kein Reinstall)."
else
  log "Installiere Node.js ${NODE_MAJOR}.x (Nodesource) ..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
fi
log "Node: $(node -v), npm: $(npm -v)"

# ---------------------------------------------------------------------- uv ---
UV_BIN="$(command -v uv 2>/dev/null || echo /root/.local/bin/uv)"
if [[ -x "${UV_BIN}" ]]; then
  log "uv bereits installiert: $(${UV_BIN} --version) (idempotent, kein Reinstall)."
else
  log "Installiere uv ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ln -sf /root/.local/bin/uv /usr/local/bin/uv
  hash -r
  UV_BIN="$(command -v uv 2>/dev/null || echo /root/.local/bin/uv)"
  [[ -x "${UV_BIN}" ]] || die "uv-Installation fehlgeschlagen (weder im PATH noch unter /root/.local/bin/uv)."
fi
log "uv: $(${UV_BIN} --version) (${UV_BIN})"

# -------------------------------------------------------------- App checkout --
if [[ -d "${APP_DIR}/.git" ]]; then
  log "Repo existiert -> git pull (idempotent/Update) ..."
  git -C "${APP_DIR}" fetch origin "${APP_BRANCH}" --depth 1
  git -C "${APP_DIR}" checkout "${APP_BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${APP_BRANCH}"
else
  log "Klone ${APP_REPO} (${APP_BRANCH}) nach ${APP_DIR} ..."
  rm -rf "${APP_DIR}"
  git clone --depth 1 --branch "${APP_BRANCH}" "${APP_REPO}" "${APP_DIR}"
fi
log "Checkout: $(git -C "${APP_DIR}" rev-parse --short HEAD)"

# -------------------------------------------------------------------- .env ---
# Platzhalter-Modus (gewaehlt): keine interaktiven Keys. Datei nur anlegen,
# wenn sie fehlt; vorhandene Keys NIE ueberschreiben (idempotent).
if [[ ! -f "${APP_DIR}/.env" ]]; then
  log "Lege Platzhalter ${APP_DIR}/.env an (bitte spaeter echte Keys eintragen) ..."
  cat > "${APP_DIR}/.env" <<'EOF'
# MiroFish env (Platzhalter - bitte echte Keys eintragen, dann: systemctl restart mirofish-backend)
# Doku: https://github.com/666ghj/MiroFish#1-configure-environment-variables
LLM_API_KEY=change-me
LLM_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
LLM_MODEL_NAME=qwen-plus
ZEP_API_KEY=change-me
FLASK_HOST=0.0.0.0
FLASK_PORT=5001
FLASK_DEBUG=False
EOF
else
  log ".env existiert bereits -> wird NICHT ueberschrieben (idempotent)."
fi

# ------------------------------------------------------------ Backend setup --
log "Backend: uv sync ..."
cd "${APP_DIR}/backend"
"${UV_BIN}" sync --frozen
VENV_PY="${APP_DIR}/backend/.venv/bin/python"
[[ -x "${VENV_PY}" ]] || die "venv-Python fehlt: ${VENV_PY}"
log "Backend venv: $(${VENV_PY} --version)"

# ----------------------------------------------------------- Frontend build --
log "Frontend: npm ci + build (Production-Build) ..."
cd "${APP_DIR}/frontend"
if [[ -d node_modules ]]; then
  log "node_modules existiert -> npm ci laeuft trotzdem sauber durch (reproduzierbar)."
fi
npm ci
npm run build
[[ -f "${APP_DIR}/frontend/dist/index.html" ]] || die "Frontend-Build fehlgeschlagen: dist/index.html fehlt."
log "Frontend-Build OK: $(du -sh "${APP_DIR}/frontend/dist" | cut -f1) in frontend/dist"

# ------------------------------------------------------- systemd: backend ----
log "Systemd-Unit mirofish-backend ..."
cat > /etc/systemd/system/mirofish-backend.service <<EOF
[Unit]
Description=MiroFish Backend (Flask, Port ${BACKEND_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/backend/.venv/bin/python run.py
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mirofish-backend

# ------------------------------------------------------------ nginx: :3000 ---
# Web UI-Anforderung: erreichbar unter http://[LXC-IP]:3000, bind 0.0.0.0.
log "Nginx-VHost auf Port ${FRONTEND_PORT} (dist + /api-Proxy auf :${BACKEND_PORT}) ..."
cat > /etc/nginx/sites-available/mirofish <<EOF
server {
  listen ${FRONTEND_PORT} default_server;
  listen [::]:${FRONTEND_PORT} default_server;
  server_name _;

  root ${APP_DIR}/frontend/dist;
  index index.html;

  # SPA fallback (Vue Router)
  location / {
    try_files \$uri \$uri/ /index.html;
  }

  # Frontend ruft /api auf -> Proxy zum Flask-Backend (Upstream nutzt 5001)
  location /api/ {
    proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }

  location = /health {
    proxy_pass http://127.0.0.1:${BACKEND_PORT}/health;
  }
}
EOF
ln -sf /etc/nginx/sites-available/mirofish /etc/nginx/sites-enabled/mirofish
# Default-Site darf Port 3000 nicht blockieren; :80 bleibt unberuehrt.
nginx -t
systemctl enable nginx
systemctl restart nginx

# ------------------------------------------------------------------ Start ----
log "Starte/Restart mirofish-backend ..."
systemctl restart mirofish-backend

# ----------------------------------------------------------------- Verify ----
log "Verifikation: Service + HTTP-Checks ..."
sleep 3
systemctl is-active --quiet mirofish-backend \
  || { journalctl -u mirofish-backend --no-pager -n 100; die "mirofish-backend ist nicht active."; }
log "systemctl is-active mirofish-backend: $(systemctl is-active mirofish-backend)"

# Backend direkt (Platzhalter-Keys: /health antwortet auch ohne echte Keys)
if curl -fsS --max-time 10 "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null; then
  log "Backend-Check OK: http://localhost:${BACKEND_PORT}/health antwortet."
  curl -fsS --max-time 10 "http://127.0.0.1:${BACKEND_PORT}/health" || true
else
  journalctl -u mirofish-backend --no-pager -n 100
  die "Backend antwortet nicht auf localhost:${BACKEND_PORT}/health."
fi

# Frontend via nginx
if curl -fsS --max-time 10 "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null; then
  log "Frontend-Check OK: http://localhost:${FRONTEND_PORT}/ antwortet."
else
  journalctl -u nginx --no-pager -n 50 || true
  nginx -T || true
  die "Frontend antwortet nicht auf localhost:${FRONTEND_PORT}/."
fi

CT_IP="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
echo ""
echo "[${APP}] Fertig. Web UI: http://${CT_IP:-<LXC-IP>}:${FRONTEND_PORT}  (Backend: :${BACKEND_PORT}/health)"
echo "[${APP}] Wichtig: ${APP_DIR}/.env mit echten LLM_API_KEY/ZEP_API_KEY fuellen, dann: systemctl restart mirofish-backend"
