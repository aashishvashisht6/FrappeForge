# syntax = docker/dockerfile:experimental
FROM ubuntu:20.04

ENV LANG C.UTF-8
ENV DEBIAN_FRONTEND noninteractive

ENV OPENBLAS_NUM_THREADS 1
ENV MKL_NUM_THREADS 1

# Install essential packages
RUN --mount=type=cache,target=/var/cache/apt apt-get update \
  && apt-get install --yes --no-install-suggests --no-install-recommends \
  # Essentials
  build-essential \
  git \
  mariadb-client \
  libmariadb-dev \
  pv \
  ntp \
  wget \
  curl \
  supervisor \
  nginx \
  file \
  gettext \
  # Dependencies for SSH access
  openssh-server \
  nano \
  vim \
  less \
  htop \
  iputils-ping \
  telnet \
  # Dependencies for adding Python PPA
  software-properties-common \
  gnupg \
  # weasyprint dependencies
  libpango-1.0-0 \
  libharfbuzz0b \
  libpangoft2-1.0-0 \
  libpangocairo-1.0-0 \
  # wkhtmltopdf dependencies
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
  # pycups dependencies
  gcc \
  libcups2-dev \
  # s3-attachment dependencies
  libmagic1 \
  && rm -rf /var/lib/apt/lists/* \
  # Fixes for non-root nginx and logs to stdout
  && rm -fr /etc/nginx/sites-enabled/default \
  && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
  && ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log \
  && touch /run/nginx.pid \
  `#stage-pre-essentials`

COPY --chown=root:root resources/supervisord.conf /etc/supervisor/supervisord.conf

# Install Redis from PPA
RUN --mount=type=cache,target=/var/cache/apt curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb focal main" | tee /etc/apt/sources.list.d/redis.list \
  && apt-get update \
  && apt-get install --yes --no-install-suggests --no-install-recommends \
  redis-server \
  && rm -rf /var/lib/apt/lists/* `#stage-pre-redis`

# Install Python from DeadSnakes PPA

RUN --mount=type=cache,target=/var/cache/apt add-apt-repository ppa:deadsnakes/ppa \
  && apt-get update \
  && apt-get install --yes --no-install-suggests --no-install-recommends \
  python3.10 \
  python3.10-dev \
  python3.10-venv \
  python3.10-distutils \
  && rm -rf /var/lib/apt/lists/* \
  `#stage-pre-python`

RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb \
  && dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb \
  && rm wkhtmltox_0.12.6-1.focal_amd64.deb \
  `#stage-pre-wkhtmltopdf`

# Install Fonts
RUN git clone --progress --depth 1 https://github.com/frappe/fonts.git /tmp/fonts \
  && rm -rf /etc/fonts && mv /tmp/fonts/etc_fonts /etc/fonts \
  && rm -rf /usr/share/fonts && mv /tmp/fonts/usr_share_fonts /usr/share/fonts \
  && rm -rf /tmp/fonts \
  && fc-cache -fv \
  `#stage-pre-fonts`

# Set max_allowed_packet to 512 MB for mysqldump
RUN echo "[mysqldump]\nmax_allowed_packet              = 512M" > /etc/mysql/conf.d/mysqldump.cnf

# Add frappe user
RUN useradd -ms /bin/bash frappe

# Fix permissions for Nginx
RUN chown -R frappe:frappe /etc/nginx/conf.d \
  && chown -R frappe:frappe /etc/nginx/nginx.conf \
  && chown -R frappe:frappe /var/log/nginx \
  && chown -R frappe:frappe /var/lib/nginx \
  && chown -R frappe:frappe /run/nginx.pid 


# Switch to frappe
USER frappe
WORKDIR /home/frappe

COPY resources/nginx-template.conf /home/frappe/templates/nginx/frappe.conf.template
COPY resources/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh


ENV NVM_DIR /home/frappe/.nvm

RUN wget https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh \
  && bash install.sh \
  && . "/home/frappe/.nvm/nvm.sh" \
  && nvm install v20.14.0 \
  && nvm use v20.14.0 \
  && nvm alias default v20.14.0 \
  && rm install.sh \
  && nvm cache clear \
  `#stage-pre-node`

ENV PATH "$PATH:/home/frappe/.nvm/versions/node/v20.14.0/bin"


# Install Yarn
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 npm install -g yarn `#stage-pre-yarn`


# Install Bench
ENV PATH "$PATH:/home/frappe/.local/bin"

RUN wget https://bootstrap.pypa.io/get-pip.py && python3.10 get-pip.py `#stage-pre-pip`

RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 python3.10 -m pip install --upgrade frappe-bench==5.22.3 `#stage-bench-bench`

RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 python3.10 -m pip install Jinja2~=3.0.3
RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 python3.10 -m pip install --upgrade setuptools

RUN git config --global advice.detachedHead false

ENV PYTHONUNBUFFERED 1

# For the sake of completing the step
RUN `#stage-bench-env`

# Install Frappe app
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 bench init --python /usr/bin/python3.10 --no-backups --frappe-branch version-15 frappe-bench `#stage-apps-frappe`
WORKDIR /home/frappe/frappe-bench

RUN --mount=type=cache,target=/home/frappe/.cache,uid=1000,gid=1000 /home/frappe/frappe-bench/env/bin/pip install pycups==2.0.1

#Install ERPNext App
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 bench get-app --branch version-15 --resolve-deps erpnext `#stage-apps-erpnext`

#COPY Custom Apps
COPY --chown=frappe:frappe custom_apps /home/frappe/custom_apps/

# Install Custom Apps
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 bench get-app file:///home/frappe/custom_apps/property_tax  `#stage-apps-property_tax`
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 bench get-app file:///home/frappe/custom_apps/water_tax  `#stage-apps-water_tax`
RUN --mount=type=cache,sharing=locked,target=/home/frappe/.cache,uid=1000,gid=1000 bench build --force  `#stage-build`


# Setup Supervisor
COPY --chown=frappe:frappe resources/supervisor.conf /home/frappe/frappe-bench/config/supervisor.conf

VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
  "/home/frappe/frappe-bench/sites/assets" \
]

CMD ["supervisord"]