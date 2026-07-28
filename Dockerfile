# syntax=docker/dockerfile:experimental
# =============================================================================
# Frappe / ERPNext — Production Dockerfile
#
# OS      : Ubuntu 22.04 LTS (Jammy) — supported until April 2027
# Python / Node are tied to the Frappe major version being built:
#   version-14  ->  Python 3.10, Node 20
#   version-15  ->  Python 3.12, Node 22
#   version-16  ->  Python 3.14, Node 24
# scripts/setup.sh sets PYTHON_VERSION/NODE_VERSION correctly for whichever
# --frappe-version you pick; set them by hand to match if building manually.
# Keep NODE_VERSION >= 22.12.0 on the Node-22 line — some custom apps' JS
# deps (e.g. @vitejs/plugin-react 5.x) enforce that via package.json engines
# and fail `yarn install` deep in this build on anything lower.
# Bench   : latest 5.x
#
# Overridable at build time:
#   --build-arg FRAPPE_BRANCH=version-15
#   --build-arg ERPNEXT_BRANCH=version-15
#   --build-arg PYTHON_VERSION=3.12
#   --build-arg NODE_VERSION=22.14.0
# =============================================================================

FROM ubuntu:22.04

# ---------------------------------------------------------------------------
# Build arguments
# ---------------------------------------------------------------------------
ARG FRAPPE_BRANCH=version-15
ARG ERPNEXT_BRANCH=version-15
ARG PYTHON_VERSION=3.12
ARG NODE_VERSION=22.14.0
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=jammy

# Custom apps to fetch directly from git during the build — semicolon-separated
# list of "git_url|branch" pairs (branch may be empty to use the repo default),
# e.g. "https://github.com/org/app_one|version-15;https://github.com/org/app_two|"
# Populated automatically by scripts/setup.sh; set manually via
# `docker compose build --build-arg CUSTOM_APPS=...` otherwise.
ARG CUSTOM_APPS=""

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    PYTHONUNBUFFERED=1 \
    NVM_DIR=/home/frappe/.nvm \
    PATH="/home/frappe/.nvm/versions/node/v${NODE_VERSION}/bin:/home/frappe/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install --yes --no-install-suggests --no-install-recommends \
    # Core build tools
    build-essential \
    gcc \
    git \
    curl \
    wget \
    vim \
    nano \
    less \
    htop \
    file \
    gettext \
    pv \
    ntp \
    cron \
    # MariaDB client + dev headers
    mariadb-client \
    libmariadb-dev \
    # Python build prerequisites
    software-properties-common \
    gnupg \
    # WeasyPrint rendering deps
    libpango-1.0-0 \
    libharfbuzz0b \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    # wkhtmltopdf runtime deps
    ca-certificates \
    fontconfig \
    libfreetype6 \
    libjpeg-turbo8 \
    libpng16-16 \
    libx11-6 \
    libxcb1 \
    libxext6 \
    libxrender1 \
    xfonts-75dpi \
    xfonts-base \
    # pycups (printing support)
    libcups2-dev \
    # python-magic / s3 attachments
    libmagic1 \
    # Extra build libs
    libffi-dev \
    libbz2-dev \
    libldap2-dev \
    libsasl2-dev \
    pkg-config \
    # Network utils
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Python (from DeadSnakes PPA) — version tied to FRAPPE_BRANCH, see the
#    version/toolchain table at the top of this file.
#    `distutils` was removed from the stdlib in Python 3.12+ and DeadSnakes
#    doesn't package a compat wheel for every version, so it's installed
#    best-effort and never fails the build on newer Python versions.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt \
    add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install --yes --no-install-suggests --no-install-recommends \
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-dev \
    python${PYTHON_VERSION}-venv \
    && (apt-get install --yes --no-install-suggests --no-install-recommends python${PYTHON_VERSION}-distutils || true) \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --set python3 /usr/bin/python${PYTHON_VERSION}


# ---------------------------------------------------------------------------
# 3. wkhtmltopdf with patched Qt — arch-aware (amd64 / arm64)
# ---------------------------------------------------------------------------
RUN if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; \
    elif [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb" \
    && apt-get install -y ./wkhtmltox_*.deb \
    && rm -f wkhtmltox_*.deb \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 4. Frappe fonts
# ---------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/frappe/fonts.git /tmp/frappe-fonts \
    && rm -rf /etc/fonts && mv /tmp/frappe-fonts/etc_fonts /etc/fonts \
    && rm -rf /usr/share/fonts && mv /tmp/frappe-fonts/usr_share_fonts /usr/share/fonts \
    && rm -rf /tmp/frappe-fonts \
    && fc-cache -fv

# ---------------------------------------------------------------------------
# 5. mysqldump tuning — 512 MB packet size for large DB backups
# ---------------------------------------------------------------------------
RUN printf "[mysqldump]\nmax_allowed_packet = 512M\n" > /etc/mysql/conf.d/mysqldump.cnf

# ---------------------------------------------------------------------------
# 6. frappe user
# ---------------------------------------------------------------------------
RUN useradd -ms /bin/bash frappe

# ---------------------------------------------------------------------------
# From here on, run everything as the frappe user
# ---------------------------------------------------------------------------
USER frappe
WORKDIR /home/frappe


# ---------------------------------------------------------------------------
# 7. Node.js via NVM
# ---------------------------------------------------------------------------
RUN wget -q https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh \
    && bash install.sh \
    && . "${NVM_DIR}/nvm.sh" \
    && nvm install v${NODE_VERSION} \
    && nvm use v${NODE_VERSION} \
    && nvm alias default v${NODE_VERSION} \
    && rm install.sh \
    && nvm cache clear \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >> /home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /home/frappe/.bashrc

# ---------------------------------------------------------------------------
# 8. Yarn (global npm package)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 \
    npm install -g yarn

# ---------------------------------------------------------------------------
# 9. pip + frappe-bench
# ---------------------------------------------------------------------------
ENV PATH="$PATH:/home/frappe/.local/bin"

RUN wget -q https://bootstrap.pypa.io/get-pip.py \
    && python${PYTHON_VERSION} get-pip.py \
    && rm get-pip.py

RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 \
    python${PYTHON_VERSION} -m pip install --upgrade frappe-bench setuptools

RUN git config --global advice.detachedHead false

# ---------------------------------------------------------------------------
# 10. bench init — installs Frappe framework into frappe-bench/
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench init \
        --python /usr/bin/python${PYTHON_VERSION} \
        --frappe-branch ${FRAPPE_BRANCH} \
        --no-backups \
        --skip-redis-config-generation \
        --verbose \
        frappe-bench

WORKDIR /home/frappe/frappe-bench

# ---------------------------------------------------------------------------
# 11. Install ERPNext
#
# ERPNext v15 declares `payments` as a required app (hooks.py required_apps)
# for its payment-gateway integrations. `--resolve-deps` only resolves pip
# dependencies, not this Frappe-level app requirement, so `payments` must be
# fetched explicitly here or `bench new-site --install-app erpnext` fails
# with "ModuleNotFoundError: No module named 'payments'".
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench get-app \
        --branch ${ERPNEXT_BRANCH} \
        --resolve-deps \
        erpnext \
        https://github.com/frappe/erpnext \
    && bench get-app \
        --branch ${ERPNEXT_BRANCH} \
        --resolve-deps \
        payments \
        https://github.com/frappe/payments

# ---------------------------------------------------------------------------
# 12. Optional: pycups for printing — remove if not needed
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 \
    /home/frappe/frappe-bench/env/bin/pip install pycups==2.0.1

# ---------------------------------------------------------------------------
# 13. Custom apps — fetched straight from git, same as ERPNext above.
# CUSTOM_APPS is "git_url|branch;git_url|branch;..." (branch optional per app).
# scripts/setup.sh builds this string interactively; set it by hand with
# `docker compose build --build-arg CUSTOM_APPS="..."` if you're not using the script.
#
# For a private github.com repo, pass a token via BuildKit secret rather than
# embedding it in CUSTOM_APPS — a plain ARG value gets baked into `docker
# history` and the build cache forever, leaking the credential. The token
# here only ever lives in this RUN's process environment (via git's
# GIT_CONFIG_* env-var mechanism, no ~/.gitconfig file written) and is gone
# once the RUN exits:
#   GITHUB_TOKEN=ghp_xxx docker compose build
# (docker-compose.yml declares the `github_token` secret from that env var;
# scripts/setup.sh prompts for it when you say a custom app is private.)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    --mount=type=secret,id=github_token,uid=1000,gid=1000 \
    if [ -s /run/secrets/github_token ]; then \
        export GIT_CONFIG_COUNT=1; \
        export GIT_CONFIG_KEY_0="url.https://x-access-token:$(cat /run/secrets/github_token)@github.com/.insteadOf"; \
        export GIT_CONFIG_VALUE_0="https://github.com/"; \
    fi; \
    if [ -n "$CUSTOM_APPS" ]; then \
        echo "$CUSTOM_APPS" | tr ';' '\n' | while IFS='|' read -r app_url app_branch; do \
            [ -z "$app_url" ] && continue; \
            if [ -n "$app_branch" ]; then \
                bench get-app --branch "$app_branch" --resolve-deps "$app_url"; \
            else \
                bench get-app --resolve-deps "$app_url"; \
            fi; \
        done; \
    fi

# ---------------------------------------------------------------------------
# 14. Build frontend assets for every installed app (frappe, erpnext, and any
# custom apps fetched above) — no need to list them by name.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench build --force --hard-link && \
    chmod -R 755 /home/frappe/frappe-bench/sites/assets

# ---------------------------------------------------------------------------
# 15. Seed empty common_site_config — required before any bench command runs
# ---------------------------------------------------------------------------
RUN echo "{}" > /home/frappe/frappe-bench/sites/common_site_config.json

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------
VOLUME [ \
    "/home/frappe/frappe-bench/sites", \
    "/home/frappe/frappe-bench/logs" \
]

# Default CMD — each service in docker-compose overrides this
CMD [ \
  "/home/frappe/frappe-bench/env/bin/gunicorn", \
  "--chdir=/home/frappe/frappe-bench/sites", \
  "--bind=0.0.0.0:8000", \
  "--threads=4", \
  "--workers=2", \
  "--worker-class=gthread", \
  "--worker-tmp-dir=/dev/shm", \
  "--timeout=120", \
  "--preload", \
  "frappe.app:application" \
]
