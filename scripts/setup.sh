#!/usr/bin/env bash
# =============================================================================
# FrappeForge — automated setup
#
# Walks through the whole flow in docs/SETUP.md interactively:
#   1. Installs Docker Engine + Compose plugin, Nginx, and Certbot if missing
#      (distro-agnostic: Debian/Ubuntu, Fedora/RHEL/CentOS, Arch, openSUSE,
#      Alpine — Docker itself is installed via get.docker.com everywhere else)
#   2. Asks for the domain, compose project name, ports, and passwords, then
#      writes .env (with per-project volume/network names so multiple benches
#      never collide)
#   3. Asks whether to add custom apps — repeatedly, one git URL + branch at
#      a time — and wires them into the image build
#   4. Builds the image and brings the stack up
#   5. Creates the Frappe site, installing ERPNext and every custom app that
#      was actually fetched into the image (detected from the container, so
#      app-name guessing is never required)
#   6. Installs and enables the host Nginx config for the domain
#   7. Optionally requests a Let's Encrypt certificate
#
# Usage:
#   ./scripts/setup.sh                  # fully interactive
#   ./scripts/setup.sh --domain erp.mycompany.com --non-interactive
#   ./scripts/setup.sh --help
#
# Safe to re-run: an existing .env, an already-created site, and an already
# enabled Nginx config are all detected and skipped rather than clobbered.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Colors / logging
# ---------------------------------------------------------------------------
c_green="\033[0;32m"; c_yellow="\033[0;33m"; c_red="\033[0;31m"; c_blue="\033[0;34m"; c_bold="\033[1m"; c_reset="\033[0m"
log()  { echo -e "${c_blue}==>${c_reset} $*"; }
ok()   { echo -e "${c_green}✓${c_reset} $*"; }
warn() { echo -e "${c_yellow}!${c_reset} $*"; }
die()  { echo -e "${c_red}✗ $*${c_reset}" >&2; exit 1; }
step() { echo -e "\n${c_bold}$*${c_reset}"; }

# ---------------------------------------------------------------------------
# Defaults / flags
# ---------------------------------------------------------------------------
DOMAIN=""
PROJECT_NAME="frappe"
BACKEND_PORT=""    # left empty so ask_port can suggest the first free port (see collect_answers)
SOCKETIO_PORT=""
GUNICORN_WORKERS="$(nproc 2>/dev/null || echo 2)"
ADMIN_PASSWORD=""
DB_ROOT_PASSWORD=""
DB_PASSWORD=""
SITES_HOST_PATH="${REPO_ROOT}/volumes/sites"   # host dir the `sites` volume binds to (for Nginx /assets)
CUSTOM_APPS_STR=""     # "url|branch;url|branch;..." — sent straight to the Dockerfile build arg
GITHUB_TOKEN="${GITHUB_TOKEN:-}"   # for private github.com custom apps — never written to .env,
                                    # only passed to `docker compose build` as a BuildKit secret
FRAPPE_VERSION=""      # 14, 15, or 16 — resolved to FRAPPE_BRANCH/ERPNEXT_BRANCH/PYTHON_VERSION/NODE_VERSION below
FRAPPE_BRANCH=""
ERPNEXT_BRANCH=""
PYTHON_VERSION=""
NODE_VERSION=""
CUSTOM_IMAGE=""
SKIP_DEPS="false"
SKIP_NGINX="false"
SKIP_SSL="false"
NON_INTERACTIVE="false"
CERTBOT_EMAIL=""
NGINX_CONF_NAME=""

usage() {
  cat <<'EOF'
FrappeForge automated setup

Usage: ./scripts/setup.sh [options]

With no options, the script asks for everything it needs interactively.
Flags let you pre-fill answers or run fully unattended with --non-interactive.

  --domain DOMAIN            Site domain — becomes FRAPPE_SITE_NAME and DB name
  --frappe-version {14,15,16}  Frappe/ERPNext major version to build (default: 15).
                              Sets FRAPPE_BRANCH/ERPNEXT_BRANCH to version-<N> and
                              picks the matching Python/Node toolchain for the build:
                              v14->Python 3.10/Node 20, v15->Python 3.12/Node 22,
                              v16->Python 3.14/Node 24.
  --project-name NAME        COMPOSE_PROJECT_NAME (default: frappe)
  --backend-port PORT        Host port for the backend container (default: first free
                              port at/after 8000 — auto-detected so multiple benches
                              on one host never collide)
  --socketio-port PORT       Host port for the socketio container (default: first free
                              port at/after 9000, distinct from --backend-port)
  --gunicorn-workers N       Gunicorn worker count (default: number of CPU cores)
  --admin-password PASS      Frappe Administrator password (default: random)
  --db-root-password PASS    MariaDB root password (default: random)
  --db-password PASS         Frappe app DB user password (default: random)
  --custom-app URL[|BRANCH]  Add a custom app fetched from this git URL, optionally
                              pinned to BRANCH. Repeat this flag for multiple apps.
  --github-token TOKEN       GitHub personal access token, for private github.com
                              custom apps. Passed to the build as a BuildKit secret —
                              never written to .env or any compose file. Also read
                              from the GITHUB_TOKEN env var if already exported.
  --sites-path PATH          Absolute host directory the `sites` volume binds to,
                              used by Nginx to serve /assets (default: ./volumes/sites)
  --nginx-conf-name NAME     Nginx sites-available file name (default: frappe-erp,
                              or frappe-erp-<project-name> for multi-bench setups)
  --certbot-email EMAIL      Email for Let's Encrypt registration
  --skip-deps                 Don't install Docker/Nginx/Certbot even if missing
  --skip-nginx                Don't touch host Nginx configuration
  --skip-ssl                  Don't run Certbot
  --non-interactive            Never prompt; use flag values / defaults instead
  -h, --help                   Show this help

Examples:
  ./scripts/setup.sh
  ./scripts/setup.sh --domain erp.mycompany.com --non-interactive
  ./scripts/setup.sh --domain erp2.company.com --project-name frappe2 \
      --backend-port 8001 --socketio-port 9001 --skip-ssl --non-interactive
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --frappe-version) FRAPPE_VERSION="$2"; shift 2 ;;
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --backend-port) BACKEND_PORT="$2"; shift 2 ;;
    --socketio-port) SOCKETIO_PORT="$2"; shift 2 ;;
    --gunicorn-workers) GUNICORN_WORKERS="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --db-root-password) DB_ROOT_PASSWORD="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    --custom-app) CUSTOM_APPS_STR="${CUSTOM_APPS_STR}${CUSTOM_APPS_STR:+;}${2}"; shift 2 ;;
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    --sites-path) SITES_HOST_PATH="$2"; shift 2 ;;
    --nginx-conf-name) NGINX_CONF_NAME="$2"; shift 2 ;;
    --certbot-email) CERTBOT_EMAIL="$2"; shift 2 ;;
    --skip-deps) SKIP_DEPS="true"; shift ;;
    --skip-nginx) SKIP_NGINX="true"; shift ;;
    --skip-ssl) SKIP_SSL="true"; shift ;;
    --non-interactive) NON_INTERACTIVE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Prompt helper — "ask VAR_NAME 'Question' 'default'"
# In --non-interactive mode, returns the default (or the value already set
# via flags) without prompting; dies if a value is required but missing.
# ---------------------------------------------------------------------------
ask() {
  local __var="$1" __question="$2" __default="${3:-}" __required="${4:-false}" __reply
  local __current="${!__var}"

  if [[ -n "$__current" ]]; then
    return # already set via a flag
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ -z "$__default" && "$__required" == "true" ]]; then
      die "$__var is required (pass it as a flag when using --non-interactive)"
    fi
    printf -v "$__var" '%s' "$__default"
    return
  fi

  if [[ -n "$__default" ]]; then
    read -rp "$__question [$__default]: " __reply
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    read -rp "$__question: " __reply
    if [[ -z "$__reply" && "$__required" == "true" ]]; then
      die "A value is required"
    fi
    printf -v "$__var" '%s' "$__reply"
  fi
}

confirm() {
  [[ "$NON_INTERACTIVE" == "true" ]] && return 1
  local reply
  read -rp "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

rand_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20; }

# ---------------------------------------------------------------------------
# Load an existing .env into the current shell WITHOUT executing it as a
# script. `source`/`.` runs each line as a bash command, and values like
# CUSTOM_APPS (which legitimately contains "|") get parsed as shell syntax —
# e.g. "CUSTOM_APPS=https://host/org/repo|main" is a pipe into a command
# called "main", which bash resolves to this script's own main() function
# and calls it recursively. Plain textual KEY=VALUE parsing avoids that
# entirely (and also avoids `source` mangling FRAPPE_SITE_NAME_HEADER's
# literal "$$host" into the shell's PID).
# ---------------------------------------------------------------------------
load_env_file() {
  local file="$1" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    export "${key}=${value}"
  done < "$file"
}

# ---------------------------------------------------------------------------
# Custom app URL validation — `bench get-app` parses git URLs as
# protocol://host/org/repo and dies with a cryptic "not enough values to
# unpack" deep inside the image build if a host segment is missing (e.g.
# "https://myorg/myrepo" instead of "https://github.com/myorg/myrepo").
# Catch that here instead, before minutes of build time are spent on it.
# ---------------------------------------------------------------------------
validate_git_url() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/[^/]+/[^/]+ ]]
}

validate_custom_apps_str() {
  local str="$1" entry url
  [[ -z "$str" ]] && return
  local IFS=';'
  for entry in $str; do
    url="${entry%%|*}"
    validate_git_url "$url" || die "Invalid custom app git URL: '$url' — bench needs a full protocol://host/org/repo URL (e.g. https://github.com/org/repo). Fix the --custom-app flag and retry."
  done
}

# ---------------------------------------------------------------------------
# Port helpers — matter most in multi-bench setups, where each additional
# FrappeForge stack on the same host needs its own free BACKEND_PORT/
# SOCKETIO_PORT. Pure-bash /dev/tcp probe, so no ss/netstat dependency.
# ---------------------------------------------------------------------------
port_in_use() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  return 1
}

next_free_port() {
  local port="$1" avoid="${2:-}"
  while port_in_use "$port" || [[ -n "$avoid" && "$port" == "$avoid" ]]; do
    port=$((port + 1))
  done
  echo "$port"
}

# ask_port VAR "Question" default_start [avoid_port]
# Suggests the first free port at/after default_start, skips avoid_port (used
# so SOCKETIO_PORT never collides with whatever BACKEND_PORT was just picked),
# and re-validates whatever is finally chosen — via flag, prompt, or default.
ask_port() {
  local __var="$1" __question="$2" __start="$3" __avoid="${4:-}"
  local __suggested; __suggested="$(next_free_port "$__start" "$__avoid")"

  if [[ -n "${!__var}" ]]; then
    if port_in_use "${!__var}"; then
      local __flag; __flag="--$(tr '_' '-' <<<"${__var,,}")"
      die "${__var}=${!__var} is already in use on this host — pass a free port (e.g. $__suggested) via $__flag"
    fi
    return
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    printf -v "$__var" '%s' "$__suggested"
    return
  fi

  local __reply
  while true; do
    read -rp "$__question [$__suggested]: " __reply
    __reply="${__reply:-$__suggested}"
    if [[ -n "$__avoid" && "$__reply" == "$__avoid" ]]; then
      warn "Port $__reply is already used by this stack's other service — pick a different one"
      continue
    fi
    if port_in_use "$__reply"; then
      warn "Port $__reply is already in use on this host (likely another bench) — pick a different one, e.g. $__suggested"
      continue
    fi
    printf -v "$__var" '%s' "$__reply"
    break
  done
}

# ---------------------------------------------------------------------------
# 0. Collect answers
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Resolve FRAPPE_VERSION (14/15/16) to a branch name + matching Python/Node
# toolchain. Both frappe and erpnext use identical "version-N" branch naming,
# and the `payments` app fetch in the Dockerfile already reuses ERPNEXT_BRANCH,
# so setting these is all that's needed to build a different major version:
#   version-14  ->  Python 3.10, Node 20
#   version-15  ->  Python 3.12, Node 22
#   version-16  ->  Python 3.14, Node 24
# The Node 22 default is pinned to 22.14.0, not 22.x's floor — several
# frontend packages (e.g. @vitejs/plugin-react 5.x, pulled in by some custom
# apps) declare an engines requirement of ">=22.12.0", and anything below
# that fails `yarn install` deep inside the image build. Don't drop this
# below 22.12.0.
# ---------------------------------------------------------------------------
select_version() {
  if [[ -z "$FRAPPE_VERSION" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      FRAPPE_VERSION="15"
    else
      local choice
      while true; do
        read -rp "Frappe/ERPNext version [14/15/16] (default: 15): " choice
        choice="${choice:-15}"
        case "$choice" in
          14|15|16) FRAPPE_VERSION="$choice"; break ;;
          *) warn "Enter 14, 15, or 16" ;;
        esac
      done
    fi
  fi

  case "$FRAPPE_VERSION" in
    14) FRAPPE_BRANCH="version-14"; ERPNEXT_BRANCH="version-14"
        PYTHON_VERSION="${PYTHON_VERSION:-3.10}"; NODE_VERSION="${NODE_VERSION:-20.19.1}" ;;
    15) FRAPPE_BRANCH="version-15"; ERPNEXT_BRANCH="version-15"
        PYTHON_VERSION="${PYTHON_VERSION:-3.12}"; NODE_VERSION="${NODE_VERSION:-22.14.0}" ;;
    16) FRAPPE_BRANCH="version-16"; ERPNEXT_BRANCH="version-16"
        PYTHON_VERSION="${PYTHON_VERSION:-3.14}"; NODE_VERSION="${NODE_VERSION:-24.4.0}" ;;
    *) die "Unsupported --frappe-version '$FRAPPE_VERSION' (must be 14, 15, or 16)" ;;
  esac
  CUSTOM_IMAGE="frappe-erpnext-v${FRAPPE_VERSION}"
  ok "Building Frappe/ERPNext ${FRAPPE_BRANCH} (Python ${PYTHON_VERSION}, Node ${NODE_VERSION})"
}

collect_answers() {
  step "1. Basic configuration"
  ask DOMAIN "Domain for this site (e.g. erp.mycompany.com)" "" true
  ask PROJECT_NAME "Docker Compose project name" "$PROJECT_NAME"
  ask_port BACKEND_PORT "Host port for the backend (pick a free one per bench if running more than one)" 8000
  ask_port SOCKETIO_PORT "Host port for Socket.IO" 9000 "$BACKEND_PORT"
  ask GUNICORN_WORKERS "Gunicorn workers" "$GUNICORN_WORKERS"

  [[ -n "$ADMIN_PASSWORD" ]]   || ADMIN_PASSWORD="$(rand_pass)"
  [[ -n "$DB_ROOT_PASSWORD" ]] || DB_ROOT_PASSWORD="$(rand_pass)"
  [[ -n "$DB_PASSWORD" ]]      || DB_PASSWORD="$(rand_pass)"

  [[ -n "$NGINX_CONF_NAME" ]] || {
    if [[ "$PROJECT_NAME" == "frappe" ]]; then NGINX_CONF_NAME="frappe-erp"
    else NGINX_CONF_NAME="frappe-erp-${PROJECT_NAME}"; fi
  }

  step "2. Frappe / ERPNext version"
  select_version

  step "3. Custom apps"
  validate_custom_apps_str "$CUSTOM_APPS_STR"   # catch bad --custom-app flags before anything else runs

  if [[ -z "$CUSTOM_APPS_STR" ]] && confirm "Add a custom app from a git repo?"; then
    while true; do
      local url branch
      while true; do
        read -rp "  Git URL (e.g. https://github.com/org/repo): " url
        [[ -z "$url" ]] && { warn "Empty URL, skipping"; break; }
        if validate_git_url "$url"; then break; fi
        warn "'$url' doesn't look like a full git URL — bench needs protocol://host/org/repo (e.g. https://github.com/org/repo). Try again."
      done
      [[ -n "$url" ]] || break
      read -rp "  Branch (blank = repo default): " branch
      CUSTOM_APPS_STR="${CUSTOM_APPS_STR}${CUSTOM_APPS_STR:+;}${url}|${branch}"
      ok "Added: $url${branch:+ (branch: $branch)}"
      confirm "Add another custom app?" || break
    done
  fi

  if [[ -n "$CUSTOM_APPS_STR" && -z "$GITHUB_TOKEN" && "$NON_INTERACTIVE" != "true" ]] \
     && confirm "Does any custom app above need a private github.com repo?"; then
    read -rsp "  GitHub personal access token (input hidden): " GITHUB_TOKEN
    echo
    [[ -n "$GITHUB_TOKEN" ]] && ok "Token captured — kept in memory only, never written to .env"
  fi
}

# ---------------------------------------------------------------------------
# 1. Install dependencies — distro-agnostic
# ---------------------------------------------------------------------------
detect_pkg_manager() {
  for pm in apt-get dnf yum pacman zypper apk; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
  echo "unknown"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Compose plugin already installed ($(docker --version))"
    return
  fi
  log "Installing Docker Engine + Compose plugin via get.docker.com (works across most distros)..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
  ok "Docker installed. You may need to log out/in for docker-group membership to take effect."
}

install_nginx_certbot() {
  local pm; pm="$(detect_pkg_manager)"
  local want_nginx="true" want_certbot="true"
  [[ "$SKIP_NGINX" == "true" ]] && want_nginx="false" && want_certbot="false"
  [[ "$SKIP_SSL" == "true" ]] && want_certbot="false"

  command -v nginx  >/dev/null 2>&1 && want_nginx="false"
  command -v certbot >/dev/null 2>&1 && want_certbot="false"
  [[ "$want_nginx" == "false" && "$want_certbot" == "false" ]] && { ok "Nginx/Certbot already present or not needed"; return; }

  log "Installing $( [[ $want_nginx == true ]] && echo -n nginx )$( [[ $want_nginx == true && $want_certbot == true ]] && echo -n ' + ' )$( [[ $want_certbot == true ]] && echo -n certbot ) via $pm..."
  case "$pm" in
    apt-get)
      sudo apt-get update -y
      [[ "$want_nginx" == "true" ]] && sudo apt-get install -y nginx
      [[ "$want_certbot" == "true" ]] && sudo apt-get install -y certbot python3-certbot-nginx
      ;;
    dnf)
      [[ "$want_nginx" == "true" ]] && sudo dnf install -y nginx
      [[ "$want_certbot" == "true" ]] && sudo dnf install -y certbot python3-certbot-nginx
      ;;
    yum)
      sudo yum install -y epel-release || true
      [[ "$want_nginx" == "true" ]] && sudo yum install -y nginx
      [[ "$want_certbot" == "true" ]] && sudo yum install -y certbot python3-certbot-nginx
      ;;
    pacman)
      [[ "$want_nginx" == "true" ]] && sudo pacman -Sy --noconfirm nginx
      [[ "$want_certbot" == "true" ]] && sudo pacman -Sy --noconfirm certbot certbot-nginx
      ;;
    zypper)
      [[ "$want_nginx" == "true" ]] && sudo zypper install -y nginx
      [[ "$want_certbot" == "true" ]] && sudo zypper install -y certbot python3-certbot-nginx
      ;;
    apk)
      [[ "$want_nginx" == "true" ]] && sudo apk add nginx
      [[ "$want_certbot" == "true" ]] && sudo apk add certbot certbot-nginx
      ;;
    *)
      warn "Unrecognized package manager — install nginx/certbot manually, then re-run with --skip-deps."
      return
      ;;
  esac
  command -v nginx >/dev/null 2>&1 && sudo systemctl enable --now nginx 2>/dev/null || true
  ok "Nginx/Certbot install step complete"
}

install_deps() {
  step "0. Dependencies"
  if [[ "$SKIP_DEPS" == "true" ]]; then
    log "Skipping dependency installation (--skip-deps)"
    return
  fi
  install_docker
  install_nginx_certbot
}

# ---------------------------------------------------------------------------
# 2. Generate .env
# ---------------------------------------------------------------------------
write_env() {
  step "4. Writing .env"
  if [[ -f .env ]] && ! confirm ".env already exists — overwrite it with new values?"; then
    log "Keeping existing .env as-is."
    load_env_file .env
    return
  fi

  cp env.example .env
  local -A subs=(
    [FRAPPE_SITE_NAME]="$DOMAIN"
    [COMPOSE_PROJECT_NAME]="$PROJECT_NAME"
    [DB_ROOT_PASSWORD]="$DB_ROOT_PASSWORD"
    [DB_PASSWORD]="$DB_PASSWORD"
    [GUNICORN_WORKERS]="$GUNICORN_WORKERS"
    [BACKEND_PORT]="$BACKEND_PORT"
    [SOCKETIO_PORT]="$SOCKETIO_PORT"
    [CUSTOM_APPS]="$CUSTOM_APPS_STR"
    [SITES_HOST_PATH]="$SITES_HOST_PATH"
    [FRAPPE_BRANCH]="$FRAPPE_BRANCH"
    [ERPNEXT_BRANCH]="$ERPNEXT_BRANCH"
    [PYTHON_VERSION]="$PYTHON_VERSION"
    [NODE_VERSION]="$NODE_VERSION"
    [CUSTOM_IMAGE]="$CUSTOM_IMAGE"
    [NETWORK_NAME]="${PROJECT_NAME}-net"
    [VOLUME_SITES]="${PROJECT_NAME}_sites"
    [VOLUME_LOGS]="${PROJECT_NAME}_logs"
    [VOLUME_MARIADB]="${PROJECT_NAME}_mariadb"
    [VOLUME_REDIS_CACHE]="${PROJECT_NAME}_redis_cache"
    [VOLUME_REDIS_QUEUE]="${PROJECT_NAME}_redis_queue"
  )
  for key in "${!subs[@]}"; do
    # CUSTOM_APPS' value contains '|' and ';' but not '#', safe as a sed replacement with '#' delimiter
    sed -i "s#^${key}=.*#${key}=${subs[$key]}#" .env
  done
  ok ".env written"
}

# ---------------------------------------------------------------------------
# 3. Build + start the stack
# ---------------------------------------------------------------------------
build_and_start() {
  step "5. Building the image"
  [[ -n "$CUSTOM_APPS_STR" ]] && log "Custom apps to fetch: $CUSTOM_APPS_STR"
  if [[ -n "$GITHUB_TOKEN" ]]; then
    log "Building with a GitHub token available for private custom apps (not persisted anywhere)"
    GITHUB_TOKEN="$GITHUB_TOKEN" docker compose build
  else
    docker compose build
  fi

  step "6. Starting the stack"
  log "Preparing bind-mount host directory for the sites volume: $SITES_HOST_PATH"
  mkdir -p "$SITES_HOST_PATH"
  docker compose up -d

  log "Waiting for MariaDB and Redis to become healthy..."
  local tries=0
  while (( tries < 60 )); do
    local unhealthy
    unhealthy=$(docker compose ps --format '{{.Service}} {{.Health}}' 2>/dev/null \
      | awk '$1 ~ /^(mariadb|redis_cache|redis_queue)$/ && $2 != "healthy" {print $1}')
    [[ -z "$unhealthy" ]] && break
    sleep 5
    ((tries++))
  done
  (( tries < 60 )) || die "Timed out waiting for mariadb/redis to become healthy. Check: docker compose ps"

  log "Waiting for the configurator to finish..."
  docker compose wait configurator >/dev/null 2>&1 || true
  ok "Stack is up"
}

# ---------------------------------------------------------------------------
# 4. Create the site — installs every app actually present in the image
# (frappe is always there; erpnext + any custom apps were fetched at build
# time, so we read the real app directory names instead of guessing them).
# ---------------------------------------------------------------------------
create_site() {
  step "7. Creating the site"
  if docker compose exec -T backend test -d "sites/$DOMAIN" 2>/dev/null; then
    ok "Site '$DOMAIN' already exists — skipping creation"
    return
  fi

  local apps_to_install=()
  while IFS= read -r app; do
    [[ -z "$app" || "$app" == "frappe" ]] && continue
    apps_to_install+=(--install-app "$app")
  done < <(docker compose exec -T backend bash -c "ls apps" | tr -d '\r')

  log "Installing apps: ${apps_to_install[*]:-erpnext}"
  docker compose exec -T backend \
    bench new-site \
      --no-mariadb-socket \
      --admin-password="$ADMIN_PASSWORD" \
      --db-root-password="$DB_ROOT_PASSWORD" \
      "${apps_to_install[@]}" \
      --set-default \
      "$DOMAIN"
  ok "Site created"
}

# ---------------------------------------------------------------------------
# 5. Host Nginx
# ---------------------------------------------------------------------------
setup_nginx() {
  step "8. Host Nginx"
  if [[ "$SKIP_NGINX" == "true" ]]; then
    log "Skipping Nginx configuration (--skip-nginx)"
    return
  fi
  command -v nginx >/dev/null 2>&1 || { warn "nginx not found on host — skipping Nginx configuration"; return; }

  local conf="/etc/nginx/sites-available/$NGINX_CONF_NAME"
  local enabled_dir="/etc/nginx/sites-enabled"
  if [[ ! -d "$enabled_dir" ]]; then
    # RHEL/Fedora/Arch nginx packages don't ship sites-available/sites-enabled by default
    conf="/etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
  fi

  sudo cp frappe-nginx.conf "$conf"
  sudo sed -i "s|server_name erp.mycompany.com;|server_name $DOMAIN;|" "$conf"
  sudo sed -i "s|127.0.0.1:8000|127.0.0.1:${BACKEND_PORT}|g" "$conf"
  sudo sed -i "s|127.0.0.1:9000|127.0.0.1:${SOCKETIO_PORT}|g" "$conf"
  sudo sed -i "s|/path/to/FrappeForge/volumes/sites/assets|${SITES_HOST_PATH}/assets|g" "$conf"

  if [[ -d "$enabled_dir" ]]; then
    sudo ln -sf "$conf" "$enabled_dir/$NGINX_CONF_NAME"
  fi
  sudo nginx -t
  sudo systemctl reload nginx
  ok "Nginx configured and reloaded for $DOMAIN ($conf)"
}

# ---------------------------------------------------------------------------
# 6. SSL
# ---------------------------------------------------------------------------
setup_ssl() {
  step "9. SSL"
  if [[ "$SKIP_SSL" == "true" || "$SKIP_NGINX" == "true" ]]; then
    log "Skipping SSL setup"
    return
  fi
  command -v certbot >/dev/null 2>&1 || { warn "certbot not found — skipping SSL setup"; return; }

  if [[ -z "$CERTBOT_EMAIL" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      warn "No --certbot-email given in non-interactive mode — skipping SSL setup"
      return
    fi
    read -rp "Email for Let's Encrypt registration (blank to skip SSL): " CERTBOT_EMAIL
  fi
  [[ -n "$CERTBOT_EMAIL" ]] || { warn "No email provided — skipping SSL setup"; return; }

  log "Requesting Let's Encrypt certificate for $DOMAIN..."
  sudo certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos --no-eff-email --redirect
  ok "SSL configured for https://$DOMAIN"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo -e "${c_bold}FrappeForge — automated setup${c_reset}"
  collect_answers
  install_deps
  write_env
  build_and_start
  create_site
  setup_nginx
  setup_ssl

  step "Done"
  cat <<SUMMARY
  Site:               https://${DOMAIN}  (http:// if SSL was skipped)
  Frappe user:         Administrator
  Admin password:      ${ADMIN_PASSWORD}
  MariaDB root pass:   ${DB_ROOT_PASSWORD}
  MariaDB app pass:    ${DB_PASSWORD}
  Compose project:     ${PROJECT_NAME}
  Backend port:        ${BACKEND_PORT}
  Socket.IO port:      ${SOCKETIO_PORT}

  Volumes:
    sites        ${PROJECT_NAME}_sites  (bind-mounted at ${SITES_HOST_PATH})
    logs         ${PROJECT_NAME}_logs
    mariadb      ${PROJECT_NAME}_mariadb
    redis_cache  ${PROJECT_NAME}_redis_cache
    redis_queue  ${PROJECT_NAME}_redis_queue

  Nginx serves /assets directly from ${SITES_HOST_PATH}/assets — if you see
  403s on JS/CSS after this, check that nginx's user can traverse that path:
    sudo -u www-data test -r ${SITES_HOST_PATH}/assets && echo OK

  These values are also saved in .env — keep it out of version control.

  Useful commands:
    docker compose ps
    docker compose logs -f backend
    docker compose exec backend bash
SUMMARY
}

main
