# syntax=docker/dockerfile:experimental
# =============================================================================
# Frappe / ERPNext v15 — Production Dockerfile
#
# OS      : Ubuntu 22.04 LTS (Jammy) — supported until April 2027
# Python  : 3.11  — safest for v15; avoids `imp` removal breakage in 3.12
# Node    : 20 LTS — battle-tested on v15 (minimum required is 18+)
# Bench   : latest 5.x
#
# Overridable at build time:
#   --build-arg FRAPPE_BRANCH=version-15
#   --build-arg ERPNEXT_BRANCH=version-15
#   --build-arg NODE_VERSION=20.19.1
# =============================================================================

FROM ubuntu:22.04

# ---------------------------------------------------------------------------
# Build arguments
# ---------------------------------------------------------------------------
ARG FRAPPE_BRANCH=version-15
ARG ERPNEXT_BRANCH=version-15
ARG NODE_VERSION=20.19.1
ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=jammy

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
# 2. Python 3.11 from DeadSnakes PPA
#    Ubuntu 22.04 ships 3.10 by default; 3.11 is recommended for v15 and
#    avoids the `imp` module removal that breaks some deps in 3.12.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt \
    add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install --yes --no-install-suggests --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3.11-venv \
    python3.11-distutils \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --set python3 /usr/bin/python3.11


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
    && python3.11 get-pip.py \
    && rm get-pip.py

RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 \
    python3.11 -m pip install --upgrade frappe-bench setuptools

RUN git config --global advice.detachedHead false

# ---------------------------------------------------------------------------
# 10. bench init — installs Frappe framework into frappe-bench/
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench init \
        --python /usr/bin/python3.11 \
        --frappe-branch ${FRAPPE_BRANCH} \
        --no-backups \
        --skip-redis-config-generation \
        --verbose \
        frappe-bench

WORKDIR /home/frappe/frappe-bench

# ---------------------------------------------------------------------------
# 11. Install ERPNext
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench get-app \
        --branch ${ERPNEXT_BRANCH} \
        --resolve-deps \
        erpnext \
        https://github.com/frappe/erpnext

# ---------------------------------------------------------------------------
# 12. Optional: pycups for printing — remove if not needed
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 \
    /home/frappe/frappe-bench/env/bin/pip install pycups==2.0.1

# ---------------------------------------------------------------------------
# 13. Custom apps
# ---------------------------------------------------------------------------
COPY --chown=frappe:frappe custom_apps /home/frappe/custom_apps/

# Uncomment and duplicate for each custom app:
# RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
#     bench get-app file:///home/frappe/custom_apps/easy_pos

# ---------------------------------------------------------------------------
# 14. Build frontend assets (add --app flag for each custom app with assets)
# ---------------------------------------------------------------------------
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 \
    bench build \
        --app frappe \
        --app erpnext \
        # --app easy_pos \
        --force --hard-link && chmod -R 755 /home/frappe/frappe-bench/sites/assets
# Add: --app your_app_name  for any custom app with JS/CSS assets

# ---------------------------------------------------------------------------
# 15. Seed empty common_site_config — required before any bench command runs
# ---------------------------------------------------------------------------
RUN echo "{}" > /home/frappe/frappe-bench/sites/common_site_config.json

# ---------------------------------------------------------------------------
# Volumes
# ---------------------------------------------------------------------------
VOLUME [ \
    "/home/frappe/frappe-bench/sites", \
    "/home/frappe/frappe-bench/sites/assets", \
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
