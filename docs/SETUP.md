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

## Setup Steps

### Step 1 — Clone the repository

```bash
git clone https://github.com/aashishvashisht6/FrappeForge bench1
```

### Step 2 — Create your environment file

```bash
cd bench1 && cp env.example .env
```

### Step 3 — Configure environment variables

Open `.env` in your editor and configure all the variables:

```bash
nano .env
```

Set values such as `CUSTOM_IMAGE`, `IMAGE_TAG`, `FRAPPE_SITE_NAME`, `DB_ROOT_PASSWORD`, `DB_PASSWORD`, `GUNICORN_WORKERS`, `GUNICORN_THREADS`, `BACKEND_PORT`, and `SOCKETIO_PORT` according to your deployment.

### Step 4 — Add your custom app (optional)

If you have a custom Frappe app, clone it into a `custom_apps/` directory:

```bash
mkdir -p custom_apps
cd custom_apps
git clone https://github.com/your-org/your_custom_app custom_app && cd ..
```

### Step 5 — Enable the custom app in the Dockerfile

Uncomment the relevant lines in **`Dockerfile`** (steps 13 and 14):

```dockerfile
# Step 13 — install the app
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench get-app file:///home/frappe/custom_apps/your_custom_app --resolve-deps

# Step 14 — add --app your_custom_app to the bench build command
RUN bench build --app frappe --app erpnext --app your_custom_app --force
```

Then build the image:

```bash
docker compose build
```

And start the stack:

```bash
docker compose up -d
```

### Step 6 — Create the Frappe site

Run this once after the containers are up:

```bash
docker compose exec backend \
  bench new-site \
    --no-mariadb-socket \
    --admin-password=admin \
    --db-root-password="${DB_ROOT_PASSWORD}" \
    --install-app erpnext \
    --install-app your_custom_app \
    --set-default \
    site_name
```

### Step 7 — Configure host Nginx

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

### Step 8 — SSL with Let's Encrypt (recommended)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d erp.mycompany.com
```

Certbot will automatically modify your Nginx config and set up auto-renewal.

---

Your Frappe / ERPNext v15 instance should now be reachable at your configured domain.
