# Frappe / ERPNext v15 — Custom Docker Setup

Production-ready Docker Compose stack for Frappe Framework and ERPNext v15, with host Nginx as a reverse proxy. Nginx is intentionally excluded from the compose stack — your host Nginx proxies into it.

---

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

---

## Prerequisites

| Requirement | Minimum Version |
|-------------|-----------------|
| Docker Engine | 24+ |
| Docker Compose plugin | v2.20+ |
| Host Nginx | 1.18+ |
| Certbot (optional, for SSL) | any |

---

## Repository Structure

```
.
├── Dockerfile            # Multi-stage build: Ubuntu 22.04, Python 3.11, Node 20, Frappe + ERPNext
├── docker-compose.yml    # Full production stack (no Nginx inside)
├── env.example           # All required environment variables
├── frappe-nginx.conf     # Host Nginx config — copy to /etc/nginx/sites-available/
└── custom_apps/          # Place custom app source folders here (see step 3)
```

---

## Setup Guide

### Step 1 — Clone and configure environment

```bash
git clone <your-repo-url> frappe_customdocker
cd frappe_customdocker

cp env.example .env
```

Edit `.env` and set the required values:

```dotenv
# Image name produced by docker build
CUSTOM_IMAGE=frappe-erpnext-v15
IMAGE_TAG=latest

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

> **MariaDB note:** `DB_HOST`, `DB_PORT`, `DB_USER`, `REDIS_*` usually do not need changing.

---

### Step 2 — Add custom apps (optional)

Create a `custom_apps/` directory and clone your app sources into it:

```bash
mkdir -p custom_apps
cd custom_apps
git clone https://github.com/your-org/your_custom_app
cd ..
```

Then uncomment the relevant lines in [Dockerfile](Dockerfile) (steps 13 and 14):

```dockerfile
# Step 13 — install the app
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench get-app file:///home/frappe/custom_apps/your_custom_app --resolve-deps

# Step 14 — add --app your_custom_app to the bench build command
RUN bench build --app frappe --app erpnext --app your_custom_app --force
```

---

### Step 3 — Build the Docker image

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

---

### Step 4 — Start the stack

```bash
docker compose up -d
docker compose ps        # verify all containers are running/healthy
docker compose logs -f backend   # tail logs
```

---

### Step 5 — Create the Frappe site

Run this once after all containers are healthy:

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

To also install a custom app at site creation time, append `--install-app your_custom_app`.

---

### Step 6 — Configure host Nginx

Copy the provided Nginx config to the host:

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

---

### Step 7 — SSL with Let's Encrypt (recommended)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d erp.mycompany.com
```

Certbot will automatically modify your Nginx config and set up auto-renewal. After that, uncomment the HTTPS server block at the bottom of [frappe-nginx.conf](frappe-nginx.conf) and also uncomment the HTTP→HTTPS redirect in the port 80 block.

---

## Common Operations

### View logs

```bash
docker compose logs -f backend       # Gunicorn access/error logs
docker compose logs -f worker_short  # Background job logs
docker compose logs -f scheduler     # Scheduled task logs
docker compose logs -f mariadb       # DB logs
```

### Restart a single service

```bash
docker compose restart backend
```

### Run a bench command inside the container

```bash
docker compose exec backend bash -c "cd /home/frappe/frappe-bench && bench <command>"
```

### Rebuild after code changes

```bash
docker compose build --no-cache
docker compose up -d
```

### Stop the stack

```bash
docker compose down          # stops containers, keeps volumes
docker compose down -v       # ⚠ also deletes all data volumes
```

---

## Container Reference

| Container | Image | Port (host) | Purpose |
|-----------|-------|-------------|---------|
| `frappe_configurator` | custom | — | One-shot: writes `common_site_config.json` |
| `frappe_backend` | custom | `127.0.0.1:8000` | Gunicorn WSGI server |
| `frappe_socketio` | custom | `127.0.0.1:9000` | Node.js Socket.IO |
| `frappe_worker_short` | custom | — | Short/default queue worker |
| `frappe_worker_long` | custom | — | Long/default queue worker |
| `frappe_scheduler` | custom | — | Frappe beat scheduler |
| `frappe_redis_cache` | redis:7-alpine | — | Cache (allkeys-lru) |
| `frappe_redis_queue` | redis:7-alpine | — | Job queue + pub/sub (AOF) |
| `frappe_mariadb` | mariadb:10.6 | — | Database (internal only) |

---

## Named Volumes

| Volume | Purpose |
|--------|---------|
| `frappe_v15_sites` | Frappe sites directory (site configs, files, assets) |
| `frappe_v15_logs` | Bench logs |
| `frappe_v15_mariadb` | MariaDB data directory |
| `frappe_v15_redis_cache` | Redis cache data |
| `frappe_v15_redis_queue` | Redis queue data (AOF persistence) |

---

## Tuning

### Gunicorn workers

Set in `.env` based on your CPU count:

```dotenv
GUNICORN_WORKERS=4   # 2 × CPU cores
GUNICORN_THREADS=4
```

### MariaDB InnoDB buffer pool

The compose file sets `innodb_buffer_pool_size=1G`. For servers with more RAM, edit [docker-compose.yml](docker-compose.yml) under the `mariadb` service command flags.

### Worker scaling

To handle high background-job volume, add replicas in compose:

```yaml
worker_short:
  deploy:
    replicas: 2
```

> **Never** scale the `scheduler` service — only one instance must run at a time.

---

## Troubleshooting

**Configurator fails on first start**
- Check MariaDB and Redis are healthy: `docker compose ps`
- Inspect logs: `docker compose logs configurator`

**Site not found / 404 after creation**
- Ensure `FRAPPE_SITE_NAME` in `.env` matches the domain you used in `bench new-site`
- Verify Nginx `server_name` matches the domain

**WebSockets not working (live updates broken)**
- Check Nginx is proxying `/socket.io` to port 9000
- Confirm `frappe_socketio` container is running

**MariaDB connection refused**
- MariaDB is internal-only and not exposed to the host by design
- Connect via: `docker compose exec mariadb mysql -uroot -p`
