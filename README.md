# MiroFish für Proxmox VE (Community-Scripts-Stil)

Lokale, einzeilige Installation von [MiroFish](https://github.com/666ghj/MiroFish)
(schwärmintelligente Simulations-Engine, Python-Flask-Backend + Vue/Vite-Frontend)
als **LXC-Container** auf Proxmox VE.

- **Standard:** LXC, Debian 12, 4 vCPU, 4 GB RAM, 20 GB Disk, unprivileged, `onboot: 1`
  (20 GB wegen torch/CUDA-Abhängigkeiten; bestehende Container werden per `pct resize` automatisch vergrößert)
- **Modus:** Production-Build (`npm run build` → nginx auf `:3000`, Backend `:5001`)
- **Keys:** Platzhalter-`.env` (keine interaktive Abfrage) — echte Keys nach der Installation eintragen

> Debian 12 statt 13: MiroFish braucht `requires-python >=3.11,<3.13`
> (Bookworm = Python 3.11). Unter Debian 13 nur via uv-gemanagtem Python möglich.

## Installation (Einzeiler)

Auf dem **Proxmox-Host als root** ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)"
```

Nützliche Varianten:

```bash
# andere CT-ID / Ressourcen (Variablen oben im Script, alle per Env übersteuerbar)
CTID=150 CPU=4 RAM=4096 DISK=20 STORAGE=local-lvm BRIDGE=vmbr0 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)"

# anderer Upstream-Branch/Fork von MiroFish (im Container-Script)
APP_REPO=https://github.com/666ghj/MiroFish.git APP_BRANCH=main \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)"

# Debug-Log bei Fehlern (volle Kette, Anforderung #4)
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/MiroFish-Proxmox/main/install/mirofish.sh)" 2>&1 | tee /root/mirofish-host.log
```

Erwartete Ausgabe (Ende):

```text
[MiroFish] Fertig. Web UI: http://<LXC-IP>:3000  (Backend: :5001/health)
==================================================================
 MiroFish Installation abgeschlossen
==================================================================
 Container : 150 (mirofish)
 Frontend  : http://<LXC-IP>:3000
 Backend   : http://<LXC-IP>:5001/health  (API: /api/...)
 Check    : Frontend antwortet auf Port 3000 (OK)

 Naechste Schritte:
  1) API-Keys eintragen (Platzhalter!):
       pct enter 150
       nano /opt/mirofish/.env   # LLM_API_KEY, ZEP_API_KEY setzen
       systemctl restart mirofish-backend
```

Danach: `http://<LXC-IP>:3000` öffnen.

## API-Keys nachtragen (Pflicht)

MiroFish hat **keine Einstellungs-UI für Keys** (verifiziert im Upstream-Code:
keine Settings-Seite, kein Config-Endpunkt – nur Graph/Simulation/Report-APIs).
Die Keys stehen ausschließlich in der `.env`-Datei auf dem Container:

```bash
pct enter 150
nano /opt/mirofish/.env
systemctl restart mirofish-backend
journalctl -u mirofish-backend -f   # Start beobachten
curl -fsS http://127.0.0.1:5001/health
```

| Variable | Wofür | Woher |
|---|---|---|
| `LLM_API_KEY` | Pflicht: treibt Agenten/Simulation | OpenAI-kompatibler Anbieter, z. B. [Alibaba Bailian](https://bailian.console.aliyun.com/) (`qwen-plus`), OpenAI, DeepSeek o. ä. |
| `LLM_BASE_URL` | API-Endpunkt (OpenAI-Format) | z. B. `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `LLM_MODEL_NAME` | Modellname | z. B. `qwen-plus` |
| `ZEP_API_KEY` | Pflicht: Agenten-Gedächtnis (Knowledge-Graph) | [app.getzep.com](https://app.getzep.com/) (Free-Quota reicht für einfache Nutzung) |

Hinweis: Upstream warnt vor hohem Verbrauch – erste Simulationen mit < 40 Runden testen.

## Update

Idempotent — einfach erneut laufen lassen (Host-Script erkennt existierenden Container,
Container-Script macht `git pull` + rebuild + restart):

```bash
# auf dem Proxmox-Host
pct exec 150 -- bash /root/mirofish-install.sh
```

## Reboot-Test

```bash
pct reboot 150
sleep 15
pct exec 150 -- systemctl is-active mirofish-backend nginx
pct exec 150 -- curl -fsS http://127.0.0.1:5001/health
pct exec 150 -- curl -fsS http://127.0.0.1:3000/ -o /dev/null -w "frontend %{http_code}\n"
```

## Deinstallation

```bash
pct stop 150
pct destroy 150
```

## Dateien

| Datei | Zweck |
|---|---|
| `install/mirofish.sh` | Host-Script: Template, `pct create`, `pct push` + `pct exec`, Verifikation, finale URL |
| `install/mirofish-install.sh` | LXC-Script: Node 22, uv, App-Checkout, `.env`-Platzhalter, `uv sync`, Frontend-Build, systemd + nginx, Checks |
| `install/mirofish-backend.service` | Referenz der installierten systemd-Unit (`Restart=always`, `After=network-online.target`) |
| `install/nginx-mirofish.conf` | Referenz des nginx-VHosts (`:3000` → `dist/`, `/api/` → `:5001`) |

Beide Scripts: `set -euo pipefail`, idempotent, volle Fehlerkette
(Befehl + `caller`-Stack + relevante `journalctl`/`nginx -t`-Auszüge).
