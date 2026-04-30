# FrappeForge — Setup Guide

This guide walks you through setting up **Frappe / ERPNext v15** using Docker and Docker Compose, with **Nginx running on the host machine** as a reverse proxy.

> Tested primarily on **Ubuntu**, but the Docker portion works identically on any Linux distribution. Only the host-level package-install commands (Docker, Nginx, Certbot) differ by distro.

---

## Prerequisites

You need the following installed on the host machine before starting:

| Requirement           | Minimum Version |
| --------------------- | --------------- |
| Docker Engine         | 24+             |
| Docker Compose plugin | v2.20+          |
| Host Nginx            | 1.18+           |
| Certbot (for SSL)     | any             |
| Git                   | any             |

### Install Docker Engine + Compose plugin (Ubuntu)

Uninstall any old Docker packages, then install from Docker's official APT repository:

```bash
# Remove old versions (if any)
sudo apt remove docker docker-engine docker.io containerd runc

# Install prerequisites
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's APT repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine + Compose plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add your user to the `docker` group so you can run `docker` without `sudo`:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verify the installation:

```bash
docker --version
docker compose version
```

### Install Nginx (Ubuntu)

```bash
sudo apt update
sudo apt install -y nginx
sudo systemctl enable --now nginx
```

Verify:

```bash
nginx -v
sudo systemctl status nginx
```

### Install Certbot (for SSL, optional but recommended)

```bash
sudo apt install -y certbot python3-certbot-nginx
```

---

## Single Bench Setup

### Step 1 — Clone the repository

```bash
git clone https://github.com/aashishvashisht6/FrappeForge bench1
cd bench1
```

### Step 2 — Create your environment file

```bash
cp env.example .env
```

### Step 3 — Configure environment variables

```bash
nano .env
```

Set the following values:

```dotenv
COMPOSE_PROJECT_NAME=frappe

CUSTOM_IMAGE=frappe-erpnext-v15
IMAGE_TAG=latest

FRAPPE_SITE_NAME=erp.company.com

DB_ROOT_PASSWORD=your_strong_root_password
DB_PASSWORD=your_strong_app_password

GUNICORN_WORKERS=2
GUNICORN_THREADS=4

BACKEND_PORT=8000
SOCKETIO_PORT=9000

NETWORK_NAME=frappe-net

VOLUME_SITES=frappe_v15_sites
VOLUME_LOGS=frappe_v15_logs
VOLUME_MARIADB=frappe_v15_mariadb
VOLUME_REDIS_CACHE=frappe_v15_redis_cache
VOLUME_REDIS_QUEUE=frappe_v15_redis_queue
```

> `DB_HOST`, `DB_PORT`, `DB_USER`, and `REDIS_*` do not need changing for a standard setup.

### Step 4 — Add your custom app (optional)

If you have a custom Frappe app, clone it into a `custom_apps/` directory:

```bash
mkdir -p custom_apps
cd custom_apps
git clone https://github.com/your-org/your_custom_app custom_app && cd ..
```

Then uncomment the relevant lines in **`Dockerfile`** (steps 13 and 14):

```dockerfile
# Step 13 — install the app
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench get-app file:///home/frappe/custom_apps/your_custom_app

# Step 14 — add --app your_custom_app to the bench build command
RUN bench build --app frappe --app erpnext --app your_custom_app --force
```

### Step 5 — Build the Docker image

```bash
docker compose build
```

> The first build takes 15–30 minutes. Subsequent builds are faster thanks to Docker layer caching.

### Step 6 — Start the stack

```bash
docker compose up -d
docker compose ps        # verify all containers are running/healthy
```

### Step 7 — Create the Frappe site

Run this once after all containers are healthy. Replace `your_strong_root_password` with the value you set in `.env`:

```bash
docker compose exec backend \
  bench new-site \
    --no-mariadb-socket \
    --admin-password=admin \
    --db-root-password=your_strong_root_password \
    --install-app erpnext \
    --set-default \
    erp.company.com
```

To also install a custom app at site creation time, append `--install-app your_custom_app`.

### Step 8 — Configure host Nginx

Copy the provided Nginx config to the host:

```bash
sudo cp frappe-nginx.conf /etc/nginx/sites-available/frappe-erp
```

Edit the `server_name` directive to match your domain:

```nginx
server_name erp.company.com;   # ← your domain here
```

Enable the site and reload Nginx:

```bash
sudo ln -s /etc/nginx/sites-available/frappe-erp /etc/nginx/sites-enabled/frappe-erp
sudo nginx -t
sudo systemctl reload nginx
```

### Step 9 — SSL with Let's Encrypt (recommended)

```bash
sudo certbot --nginx -d erp.company.com
```

Certbot will automatically modify your Nginx config and set up auto-renewal.

---

Your Frappe / ERPNext v15 instance should now be reachable at `https://erp.company.com`.

---

## Multi-Bench Setup

Multi-bench means running **two completely independent Frappe stacks** on the same server. Each bench is a **separate clone** of this repository with its own `.env`, Docker Compose project, containers, volumes, network, and Nginx config — fully isolated from each other.

> **Key rule:** Every bench must have unique values for `COMPOSE_PROJECT_NAME`, `BACKEND_PORT`, `SOCKETIO_PORT`, `NETWORK_NAME`, and all `VOLUME_*` names. Reusing any of these across benches will cause conflicts.

This guide sets up two benches:

| | Bench 1 | Bench 2 |
|--|---------|---------|
| Directory | `bench1` | `bench2` |
| Domain | `erp1.company.com` | `erp2.company.com` |
| Backend port | `8000` | `8001` |
| Socket.IO port | `9000` | `9001` |
| Nginx config | `frappe-erp-bench1` | `frappe-erp-bench2` |

---

### Bench 1 — erp1.company.com

#### Step 1 — Clone into bench1

```bash
git clone https://github.com/aashishvashisht6/FrappeForge bench1
cd bench1
cp env.example .env
```

#### Step 2 — Configure .env for bench1

```bash
nano .env
```

```dotenv
COMPOSE_PROJECT_NAME=frappe1

CUSTOM_IMAGE=frappe-erpnext-v15
IMAGE_TAG=latest

FRAPPE_SITE_NAME=erp1.company.com

DB_ROOT_PASSWORD=strong_root_password_bench1
DB_PASSWORD=strong_app_password_bench1

GUNICORN_WORKERS=2
GUNICORN_THREADS=4

BACKEND_PORT=8000
SOCKETIO_PORT=9000

NETWORK_NAME=frappe-net-1

VOLUME_SITES=frappe_v15_b1_sites
VOLUME_LOGS=frappe_v15_b1_logs
VOLUME_MARIADB=frappe_v15_b1_mariadb
VOLUME_REDIS_CACHE=frappe_v15_b1_redis_cache
VOLUME_REDIS_QUEUE=frappe_v15_b1_redis_queue
```

#### Step 3 — Build and start

```bash
docker compose build
docker compose up -d
docker compose ps
```

#### Step 4 — Create the Frappe site

```bash
docker compose exec backend \
  bench new-site \
    --no-mariadb-socket \
    --admin-password=admin \
    --db-root-password=strong_root_password_bench1 \
    --install-app erpnext \
    --set-default \
    erp1.company.com
```

#### Step 5 — Configure Nginx for bench1

Copy the config and open it for editing:

```bash
sudo cp frappe-nginx.conf /etc/nginx/sites-available/frappe-erp-bench1
sudo nano /etc/nginx/sites-available/frappe-erp-bench1
```

Make the following three changes in the file:

**1. Rename the upstream blocks** (avoids conflicts with bench2's upstreams):

```nginx
upstream bench1_backend {
    server 127.0.0.1:8000;
    keepalive 16;
}

upstream bench1_socketio {
    server 127.0.0.1:9000;
    keepalive 8;
}
```

**2. Set the server_name:**

```nginx
server_name erp1.company.com;
```

**3. Update proxy_pass references** to use the renamed upstreams:

```nginx
location /socket.io {
    proxy_pass http://bench1_socketio;
    # ... keep all other proxy_set_header lines unchanged
}

location / {
    proxy_pass http://bench1_backend;
    # ... keep all other proxy_set_header lines unchanged
}
```

Enable the site:

```bash
sudo ln -s /etc/nginx/sites-available/frappe-erp-bench1 /etc/nginx/sites-enabled/frappe-erp-bench1
sudo nginx -t
sudo systemctl reload nginx
```

---

### Bench 2 — erp2.company.com

#### Step 1 — Clone into bench2

Open a new terminal or navigate away from bench1 first:

```bash
cd ~   # or wherever you keep your projects
git clone https://github.com/aashishvashisht6/FrappeForge bench2
cd bench2
cp env.example .env
```

#### Step 2 — Configure .env for bench2

```bash
nano .env
```

```dotenv
COMPOSE_PROJECT_NAME=frappe2

CUSTOM_IMAGE=frappe-erpnext-v15
IMAGE_TAG=latest

FRAPPE_SITE_NAME=erp2.company.com

DB_ROOT_PASSWORD=strong_root_password_bench2
DB_PASSWORD=strong_app_password_bench2

GUNICORN_WORKERS=2
GUNICORN_THREADS=4

BACKEND_PORT=8001
SOCKETIO_PORT=9001

NETWORK_NAME=frappe-net-2

VOLUME_SITES=frappe_v15_b2_sites
VOLUME_LOGS=frappe_v15_b2_logs
VOLUME_MARIADB=frappe_v15_b2_mariadb
VOLUME_REDIS_CACHE=frappe_v15_b2_redis_cache
VOLUME_REDIS_QUEUE=frappe_v15_b2_redis_queue
```

> Every value that differs from bench1 is intentional — these prevent the two stacks from colliding.

#### Step 3 — Build and start

```bash
docker compose build
docker compose up -d
docker compose ps
```

#### Step 4 — Create the Frappe site

```bash
docker compose exec backend \
  bench new-site \
    --no-mariadb-socket \
    --admin-password=admin \
    --db-root-password=strong_root_password_bench2 \
    --install-app erpnext \
    --set-default \
    erp2.company.com
```

#### Step 5 — Configure Nginx for bench2

```bash
sudo cp frappe-nginx.conf /etc/nginx/sites-available/frappe-erp-bench2
sudo nano /etc/nginx/sites-available/frappe-erp-bench2
```

Make the following three changes:

**1. Rename the upstream blocks** to bench2 and point to ports 8001/9001:

```nginx
upstream bench2_backend {
    server 127.0.0.1:8001;
    keepalive 16;
}

upstream bench2_socketio {
    server 127.0.0.1:9001;
    keepalive 8;
}
```

**2. Set the server_name:**

```nginx
server_name erp2.company.com;
```

**3. Update proxy_pass references:**

```nginx
location /socket.io {
    proxy_pass http://bench2_socketio;
    # ... keep all other proxy_set_header lines unchanged
}

location / {
    proxy_pass http://bench2_backend;
    # ... keep all other proxy_set_header lines unchanged
}
```

Enable the site:

```bash
sudo ln -s /etc/nginx/sites-available/frappe-erp-bench2 /etc/nginx/sites-enabled/frappe-erp-bench2
sudo nginx -t
sudo systemctl reload nginx
```

---

### SSL for both benches

Run Certbot separately for each domain:

```bash
sudo certbot --nginx -d erp1.company.com
sudo certbot --nginx -d erp2.company.com
```

Certbot will update each site's Nginx config independently and set up auto-renewal for both.

---

Both Frappe instances are now reachable at their configured domains:
- `https://erp1.company.com`
- `https://erp2.company.com`
