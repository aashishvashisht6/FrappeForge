<p align="center">
  <img src="https://frappe.io/files/frappe-favicon.svg" width="72" height="72" alt="FrappeForge logo" />
</p>

<h1 align="center">FrappeForge</h1>

<p align="center">
  A production-ready Docker Compose stack for Frappe Framework / ERPNext v15 — host Nginx reverse proxy, one-command automated setup.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Frappe-v15-0089FF" alt="Frappe v15">
  <img src="https://img.shields.io/badge/ERPNext-v15-0089FF" alt="ERPNext v15">
  <img src="https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white" alt="Docker Compose">
  <img src="https://img.shields.io/badge/Ubuntu-22.04%2B-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 22.04+">
</p>

## Introduction

**FrappeForge** is a production-oriented Docker Compose setup for running **Frappe Framework and ERPNext v15**. It builds a multi-stage image (Ubuntu 22.04, Python 3.11, Node 20) containing Frappe + ERPNext, and runs it as a full set of isolated containers — Gunicorn backend, Socket.IO, short/long RQ workers, a dedicated beat scheduler, split-purpose Redis instances, and MariaDB — all wired together on an internal Docker network.

Nginx is **intentionally excluded from the container stack**: your host's own Nginx installation proxies into the backend and Socket.IO containers on `127.0.0.1`. This keeps SSL termination, multiple domains, and multi-bench hosting on one server simple to manage with tools you already know (`certbot`, `nginx -t`, `systemctl reload nginx`), while every Frappe-specific process stays reproducible and disposable inside Docker.

The project targets anyone who wants a real ERPNext production deployment on a single VPS or dedicated server — without hand-rolling `bench setup production`, and without giving up the ability to run several independent benches side by side.

## Features

### 🐳 Production Docker Stack
- **Multi-stage image** — Ubuntu 22.04 LTS, Python 3.11, Node 20 LTS, `bench` 5.x, WeasyPrint/wkhtmltopdf PDF rendering deps, and Frappe's own font set, all baked in
- **Isolated services** — dedicated containers for the Gunicorn backend, Socket.IO, `worker_short`, `worker_long`, the beat scheduler, cache Redis, queue Redis, and MariaDB, each with its own restart policy and healthcheck
- **One-shot configurator** — writes `common_site_config.json` (DB/Redis hosts, ports) before any app container starts, so every container shares identical config with zero manual drift
- **Sane queue separation** — cache Redis (`allkeys-lru`, no persistence) is kept apart from queue Redis (`noeviction`, AOF persistence) so cache pressure can never evict an in-flight background job

### 🌐 Host-Nginx Reverse Proxy
- Nginx runs on the **host**, not in a container — `frappe-nginx.conf` proxies `/` to the backend and `/socket.io` (with WebSocket upgrade headers) to the Socket.IO container
- Only `backend` and `socketio` bind to `127.0.0.1`; MariaDB and both Redis instances are internal-only and never reach the host network
- Built-in Let's Encrypt / Certbot flow — one command adds a working HTTPS server block and auto-renewal

### 🏢 Multi-Bench Ready
- Every tunable that could collide across instances — `COMPOSE_PROJECT_NAME`, `BACKEND_PORT`, `SOCKETIO_PORT`, `NETWORK_NAME`, and all `VOLUME_*` names — lives in `.env`, so you can clone this repo N times and run N fully isolated Frappe stacks on one host
- [`docs/SETUP.md`](docs/SETUP.md) walks through a real two-bench example end to end, including the Nginx upstream-renaming steps

### 🧩 Custom App Support
- Custom apps are fetched **directly from git during the image build** — set `CUSTOM_APPS` in `.env` to `git_url|branch` (semicolon-separated for more than one), no local clone or Dockerfile edits needed
- App names are auto-detected from the built image at site-creation time and installed automatically, so repo-name-vs-app-name mismatches are never an issue
- **Private github.com repos** are supported via a BuildKit secret (`GITHUB_TOKEN`) rather than embedding a token in the URL — a plain build arg would leak into `docker history` forever. `scripts/setup.sh` prompts for the token when needed and passes it through in-memory only; it's never written to `.env` or any compose file

### ⚙️ Automated Setup Script
- [`scripts/setup.sh`](scripts/setup.sh) automates everything in the [Setup Guide](#setup-guide) below: distro-agnostic Docker/Nginx/Certbot install, `.env` generation (strong random passwords if you don't supply your own), Frappe/ERPNext **version selection (v14/v15/v16)**, interactive custom-app collection, image build, stack startup, site creation, host Nginx (including `/assets`), and optional SSL — interactive or fully unattended via flags

### 🔧 Tuned for Production
- Gunicorn `workers`/`threads` and MariaDB's InnoDB buffer pool, log file size, and connection limits are all set to sensible production defaults and easy to retune per `.env`
- Named volumes for sites, logs, MariaDB data, and both Redis stores survive `docker compose down` (only `-v` removes them) — safe to rebuild the image without touching data

## Architecture

```
[Browser]
    │
    ▼
[Host Nginx :80 / :443]
    ├── proxy_pass  http://127.0.0.1:8000  →  backend   (Gunicorn)
    └── proxy_pass  http://127.0.0.1:9000  →  socketio  (Node.js)

Inside Docker network (frappe-net):
    backend      :8000   Gunicorn WSGI server
    socketio     :9000   Socket.IO real-time server
    worker_short         RQ worker — short + default queues
    worker_long          RQ worker — long + default queues
    scheduler            Frappe beat scheduler (single instance)
    redis_cache  :6379   Page/query cache  (allkeys-lru, no persistence)
    redis_queue  :6379   Job queue + pub/sub (noeviction, AOF persistence)
    mariadb      :3306   Database (internal only, NOT exposed to host)
```

Startup order: `mariadb` + `redis_*` → `configurator` (one-shot) → all app containers.

## Repository Structure

```
.
├── Dockerfile             # Multi-stage build: Ubuntu 22.04, Python 3.11, Node 20, Frappe + ERPNext
├── docker-compose.yml     # Full production stack (no Nginx inside)
├── env.example            # All required environment variables
├── frappe-nginx.conf      # Host Nginx config — copy to /etc/nginx/sites-available/
├── scripts/
│   └── setup.sh           # Automated end-to-end setup script (see below)
└── docs/
    └── SETUP.md           # Detailed setup guide, incl. multi-bench walkthrough
```

## Setup Guide

### Option A — Automated (recommended)

```bash
git clone https://github.com/aashishvashisht6/FrappeForge FrappeForge
cd FrappeForge
./scripts/setup.sh --domain erp.mycompany.com
```

Run it with no flags and it asks for everything interactively:

1. **Dependencies** — installs Docker Engine + Compose plugin (via `get.docker.com`, works across virtually any Linux distro), plus Nginx and Certbot using whichever of `apt`/`dnf`/`yum`/`pacman`/`zypper`/`apk` is detected, if they aren't already present
2. **Basic configuration** — domain, Compose project name, Gunicorn workers, and passwords (randomly generated if left blank). Backend/Socket.IO host ports are checked live against what's already listening on the machine and default to the first free port from 8000/9000 — so running the script again for a second bench on the same host suggests non-colliding ports automatically instead of defaulting back to 8000/9000
3. **Frappe/ERPNext version** — pick **14**, **15**, or **16**; the script maps it to the right `FRAPPE_BRANCH`/`ERPNEXT_BRANCH` and a matching Node.js version for the image build
4. **Custom apps** — asks whether to add one; if yes, prompts for a git URL and branch, then asks again, looping until you say no
5. **`.env` generation** — written from `env.example`, with volume and network names auto-namespaced by project name so multiple benches never collide
6. **Build + start** — builds the image and brings the stack up, waiting for MariaDB/Redis/the configurator to become healthy
7. **Site creation** — installs ERPNext and every custom app actually present in the built image (detected from the container, not guessed)
8. **Host Nginx** — installs and enables the config for your domain, including the `/assets` static-file location backed by the bind-mounted `sites` volume
9. **SSL** — optionally requests a Let's Encrypt certificate via Certbot

Run `./scripts/setup.sh --help` for all available flags (non-interactive mode, `--frappe-version`, `--custom-app`, skipping Nginx/SSL, custom ports for multi-bench, etc.).

### Option B — Manual, step by step

<details>
<summary>Expand for the manual walkthrough</summary>

#### Step 1 — Clone and configure environment

```bash
git clone https://github.com/aashishvashisht6/FrappeForge FrappeForge
cd FrappeForge

cp env.example .env
```

Edit `.env` and set the required values:

```dotenv
# Image name produced by docker build
CUSTOM_IMAGE=frappe-erpnext-v15
IMAGE_TAG=latest

# Docker Compose project name — prefixes all container and network names
COMPOSE_PROJECT_NAME=frappe

# Your actual domain — becomes the site folder name AND the MariaDB database name
FRAPPE_SITE_NAME=erp.mycompany.com

# MariaDB passwords — use strong values in production
DB_ROOT_PASSWORD=root@123
DB_PASSWORD=some_strong_app_password

# Gunicorn tuning — set WORKERS to 2 × CPU cores
GUNICORN_WORKERS=2
GUNICORN_THREADS=4

# Host ports your Nginx will proxy_pass to
BACKEND_PORT=8000
SOCKETIO_PORT=9000
```

> **Note:** `DB_HOST`, `DB_PORT`, `DB_USER`, `REDIS_*`, `VOLUME_*`, and `NETWORK_NAME` usually do not need changing for a single bench setup.

#### Step 2 — Add custom apps (optional)

Custom apps are fetched directly from git during the image build. Set `CUSTOM_APPS` in `.env` to a `git_url|branch` pair (branch optional), separating multiple apps with `;`:

```dotenv
CUSTOM_APPS=https://github.com/your-org/your_custom_app|version-15
```

No Dockerfile edits needed — `bench get-app` runs for each entry at build time and `bench build` picks up assets for every app automatically.

#### Step 3 — Build the Docker image

```bash
docker compose build
```

Build arguments you can override:

```bash
docker compose build \
  --build-arg FRAPPE_BRANCH=version-15 \
  --build-arg ERPNEXT_BRANCH=version-15 \
  --build-arg NODE_VERSION=20.19.1
```

> The first build takes 15–30 minutes as it installs all Python/Node dependencies and builds frontend assets. Subsequent builds are faster thanks to Docker layer caching.

#### Step 4 — Start the stack

```bash
docker compose up -d
docker compose ps        # verify all containers are running/healthy
docker compose logs -f backend   # tail logs
```

#### Step 5 — Create the Frappe site

```bash
docker compose exec backend \
  bench new-site \
    --no-mariadb-socket \
    --admin-password=admin \
    --db-root-password="${DB_ROOT_PASSWORD}" \
    --install-app erpnext \
    --set-default \
    "${FRAPPE_SITE_NAME}"
```

To also install a custom app at site creation time, append `--install-app your_custom_app` (the app name is whatever `bench get-app` derived it as — check `docker compose exec backend ls apps`).

#### Step 6 — Configure host Nginx

```bash
sudo cp frappe-nginx.conf /etc/nginx/sites-available/frappe-erp
```

Edit the `server_name` directive to match your domain:

```nginx
# /etc/nginx/sites-available/frappe-erp
server_name erp.mycompany.com;   # ← your domain here
```

Enable the site and reload Nginx:

```bash
sudo ln -s /etc/nginx/sites-available/frappe-erp /etc/nginx/sites-enabled/frappe-erp
sudo nginx -t          # test config syntax
sudo systemctl reload nginx
```

#### Step 7 — SSL with Let's Encrypt (recommended)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d erp.mycompany.com
```

Certbot will automatically modify your Nginx config and set up auto-renewal. After that, uncomment the HTTPS server block at the bottom of [frappe-nginx.conf](frappe-nginx.conf) and also uncomment the HTTP→HTTPS redirect in the port 80 block.

</details>

See [`docs/SETUP.md`](docs/SETUP.md) for the full prerequisite-install walkthrough and a complete **multi-bench** (two independent Frappe stacks on one server) example.

## Common Operations

#### View logs

```bash
docker compose logs -f backend       # Gunicorn access/error logs
docker compose logs -f worker_short  # Background job logs
docker compose logs -f scheduler     # Scheduled task logs
docker compose logs -f mariadb       # DB logs
```

#### Restart a single service

```bash
docker compose restart backend
```

#### Run a bench command inside the container

```bash
docker compose exec backend bash -c "cd /home/frappe/frappe-bench && bench <command>"
```

#### Rebuild after code changes

```bash
docker compose build --no-cache
docker compose up -d
```

#### Stop the stack

```bash
docker compose down          # stops containers, keeps volumes
docker compose down -v       # ⚠ also deletes all data volumes
```

## Container Reference

Container names follow the Docker Compose v2 pattern `{COMPOSE_PROJECT_NAME}-{service}-1`. With the default `COMPOSE_PROJECT_NAME=frappe`:

| Container | Image | Port (host) | Purpose |
|-----------|-------|-------------|---------|
| `frappe-configurator-1` | custom | — | One-shot: writes `common_site_config.json` |
| `frappe-backend-1` | custom | `127.0.0.1:8000` | Gunicorn WSGI server |
| `frappe-socketio-1` | custom | `127.0.0.1:9000` | Node.js Socket.IO |
| `frappe-worker_short-1` | custom | — | Short/default queue worker |
| `frappe-worker_long-1` | custom | — | Long/default queue worker |
| `frappe-scheduler-1` | custom | — | Frappe beat scheduler |
| `frappe-redis_cache-1` | redis:7-alpine | — | Cache (allkeys-lru) |
| `frappe-redis_queue-1` | redis:7-alpine | — | Job queue + pub/sub (AOF) |
| `frappe-mariadb-1` | mariadb:10.6 | — | Database (internal only) |

## Named Volumes

Volume names are configurable via `VOLUME_*` variables in `.env`. Defaults:

| Volume (`VOLUME_*` key) | Default name | Purpose |
|-------------------------|--------------|---------|
| `VOLUME_SITES` | `frappe_v15_sites` | Frappe sites directory (site configs, files, assets) |
| `VOLUME_LOGS` | `frappe_v15_logs` | Bench logs |
| `VOLUME_MARIADB` | `frappe_v15_mariadb` | MariaDB data directory |
| `VOLUME_REDIS_CACHE` | `frappe_v15_redis_cache` | Redis cache data |
| `VOLUME_REDIS_QUEUE` | `frappe_v15_redis_queue` | Redis queue data (AOF persistence) |

## Tuning

#### Gunicorn workers

Set in `.env` based on your CPU count:

```dotenv
GUNICORN_WORKERS=4   # 2 × CPU cores
GUNICORN_THREADS=4
```

#### MariaDB InnoDB buffer pool

The compose file sets `innodb_buffer_pool_size=1G`. For servers with more RAM, edit [docker-compose.yml](docker-compose.yml) under the `mariadb` service command flags.

#### Worker scaling

To handle high background-job volume, add replicas in compose:

```yaml
worker_short:
  deploy:
    replicas: 2
```

> **Never** scale the `scheduler` service — only one instance must run at a time.

## Troubleshooting

**Configurator fails on first start**
- Check MariaDB and Redis are healthy: `docker compose ps`
- Inspect logs: `docker compose logs -f configurator`

**Site not found / 404 after creation**
- Ensure `FRAPPE_SITE_NAME` in `.env` matches the domain you used in `bench new-site`
- Verify Nginx `server_name` matches the domain

**WebSockets not working (live updates broken)**
- Check Nginx is proxying `/socket.io` to port 9000
- Confirm `frappe_socketio` container is running

**MariaDB connection refused**
- MariaDB is internal-only and not exposed to the host by design
- Connect via: `docker compose exec mariadb mysql -uroot -p`

## Contributing

1. **Fork this repository** using the "Fork" button on [aashishvashisht6/FrappeForge](https://github.com/aashishvashisht6/FrappeForge).

2. **Create a branch** for your fix or feature:

   ```bash
   git checkout -b my-fix-or-feature
   ```

3. **Make your change**, then commit and push it to your fork:

   ```bash
   git push origin my-fix-or-feature
   ```

4. **Open a pull request** from your fork's branch against this repository's `develop` branch, describing what changed and why.

## Bugs and Feature Requests

Found a bug or have an idea? Please [open an issue](https://github.com/aashishvashisht6/FrappeForge/issues/new).
