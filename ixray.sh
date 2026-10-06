#!/usr/bin/env bash
# iXRay panel: install and manage it on a server with one command.
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/sephrrr/iXRay-Install/main/ixray.sh)" @ install
#
# After the install the same script is available as `ixray`:
#   ixray key | status | logs | restart | update [version] | backup | restore <file>
#   ixray domain <name> | extra-domains [a b] | path [new-path] | login | uninstall [--purge]
#
# Nodes are added from the dashboard (Nodes -> Install node), which hands out a
# one-line command for the node server.
set -euo pipefail

IMAGE=ghcr.io/sephrrr/ixray-panel
SELF_URL=https://raw.githubusercontent.com/sephrrr/iXRay-Install/main/ixray.sh
DIR=/opt/ixray/panel
BACKUPS=/opt/ixray/backups
BIN=/usr/local/bin/ixray
CLI=/usr/local/bin/ixray-cli

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; off=$'\033[0m'
say() { printf '\n%s==>%s %s%s%s\n' "$green" "$off" "$bold" "$*" "$off"; }
note() { printf '    %s\n' "$*"; }
die() { printf '%serror:%s %s\n' "$red" "$off" "$*" >&2; exit 1; }
ask() { # ask <variable> <question> [default]
  local answer
  read -r -p "$2${3:+ [$3]}: " answer </dev/tty || true
  printf -v "$1" '%s' "${answer:-${3:-}}"
}
rand() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1" || true; }
need_root() { [[ $EUID -eq 0 ]] || die "run this as root (sudo)"; }
installed() { [[ -f $DIR/docker-compose.yml && -f $DIR/.env ]]; }
need_install() { installed || die "the panel is not installed here; run: ixray install"; }
compose() { (cd "$DIR" && docker compose "$@"); }
setting() { grep -E "^$1=" "$DIR/.env" | tail -1 | cut -d= -f2-; }
set_setting() { # set_setting KEY VALUE
  if grep -qE "^$1=" "$DIR/.env"; then sed -i "s|^$1=.*|$1=$2|" "$DIR/.env"; else echo "$1=$2" >>"$DIR/.env"; fi
}

write_stack() {
  cat >"$DIR/docker-compose.yml" <<'YAML'
# iXRay panel: PostgreSQL + panel + Caddy (automatic TLS). Written by `ixray`.
services:
  postgres:
    image: postgres:17
    restart: always
    environment:
      POSTGRES_DB: ixray
      POSTGRES_USER: ixray
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C.UTF-8"
    command: >
      postgres -c shared_buffers=512MB -c effective_cache_size=1536MB
               -c work_mem=8MB -c maintenance_work_mem=128MB
               -c max_connections=200 -c timezone=UTC
    volumes:
      - postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ixray -d ixray"]
      interval: 5s
      timeout: 5s
      retries: 20

  panel:
    image: ghcr.io/sephrrr/ixray-panel:${IXRAY_VERSION:-latest}
    restart: always
    env_file: .env
    environment:
      SQLALCHEMY_DATABASE_URL: postgresql+asyncpg://ixray:${POSTGRES_PASSWORD}@postgres:5432/ixray
      UVICORN_UDS: /run/ixray/panel.sock
      UVICORN_PROXY_HEADERS: "true"
      UVICORN_FORWARDED_ALLOW_IPS: "*"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - panel-data:/var/lib/ixray
      - panel-sock:/run/ixray
    healthcheck:
      test: ["CMD", "/code/healthcheck.sh"]
      interval: 30s
      timeout: 10s
      retries: 3

  caddy:
    image: caddy:2
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    environment:
      PANEL_DOMAIN: ${PANEL_DOMAIN:?set PANEL_DOMAIN in .env}
      PANEL_EXTRA_DOMAINS: ${PANEL_EXTRA_DOMAINS:-}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - panel-sock:/run/ixray
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - panel

volumes:
  postgres:
  panel-data:
  panel-sock:
  caddy-data:
  caddy-config:
YAML
  cat >"$DIR/Caddyfile" <<'CADDY'
# Every name here gets its own certificate; users' subscription links work on
# whichever of them they were made with.
{$PANEL_DOMAIN} {$PANEL_EXTRA_DOMAINS} {
	encode zstd gzip
	# The bare domain answers with nothing useful: it sends the browser to a name
	# that does not exist, so the panel is not advertised to whoever opens it.
	@root path /
	redir @root https://www.{host}/ 302
	reverse_proxy unix//run/ixray/panel.sock
}
CADDY
}

install_docker() {
  if ! command -v docker >/dev/null; then
    say "Installing Docker"
    curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "the Docker compose plugin is missing"
}

registry_login() {
  say "Access to the panel image"
  note "The image is private. Use a GitHub token that may read packages"
  note "(github.com -> Settings -> Developer settings -> Tokens (classic) -> read:packages)."
  local user token
  ask user "GitHub username" sephrrr
  read -r -s -p "GitHub token: " token </dev/tty; echo
  [[ -n $token ]] || die "a token is needed to download the image"
  printf '%s' "$token" | docker login ghcr.io -u "$user" --password-stdin >/dev/null || die "the registry refused this token"
  note "signed in to ghcr.io"
}

wait_healthy() {
  say "Waiting for the panel to start"
  local id state
  for _ in $(seq 1 90); do
    id="$(compose ps -q panel 2>/dev/null || true)"
    state="$([[ -n $id ]] && docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || true)"
    [[ $state == healthy ]] && { note "panel is up"; return 0; }
    sleep 2
  done
  compose logs --tail 40 panel || true
  die "the panel did not become healthy; see: ixray logs"
}

show_address() {
  local domain path
  domain="$(setting PANEL_DOMAIN)"; path="$(setting DASHBOARD_PATH)"
  printf '\n%sDashboard%s  https://%s%s\n' "$bold" "$off" "$domain" "$path"
}

cmd_install() {
  need_root
  installed && die "the panel is already installed in $DIR (ixray update, or ixray uninstall first)"
  local domain version="${1:-latest}"
  say "iXRay panel"
  note "The domain must already point at this server (ports 80 and 443 open)."
  ask domain "Panel domain (e.g. panel.example.com)"
  [[ $domain =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "that is not a domain name"

  install_docker
  registry_login

  say "Writing the configuration to $DIR"
  install -d -m 0750 "$DIR" "$BACKUPS"
  write_stack
  local path="/$(rand 20)/"
  umask 077
  cat >"$DIR/.env" <<ENV
# iXRay panel settings. After a change: ixray restart
PANEL_DOMAIN=$domain
POSTGRES_PASSWORD=$(rand 40)
IXRAY_VERSION=${version#v}
# Secret address of the dashboard (keep the slashes).
DASHBOARD_PATH=$path
UVICORN_WORKERS=1
NATS_ENABLED=0
DOCS=0
# Nothing is deleted on its own: 0 keeps every usage row.
USAGE_RAW_RETENTION_DAYS=0
OUTBOUND_PROBE_RETENTION_DAYS=0
ENV
  umask 022

  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null; ufw allow 443 >/dev/null
  fi

  say "Downloading and starting"
  compose pull -q
  compose up -d --remove-orphans
  wait_healthy
  install_self

  show_address
  note ""
  note "Open it and create the owner account with this one-time key"
  note "(valid for five minutes; a new one: ixray key):"
  cmd_key || note "could not create a key now; run: ixray key"
  note "Keep this address: the dashboard answers nowhere else."
  note "Manage the panel with: ixray status | logs | update | backup"
}

install_self() {
  if curl -fsSL "$SELF_URL" -o "$BIN.new" 2>/dev/null && bash -n "$BIN.new"; then
    install -m 0755 "$BIN.new" "$BIN"
  fi
  rm -f "$BIN.new"
  # The panel's own CLI lives in the container; this makes it a host command,
  # as the dashboard's setup page words it (ixray-cli generate-temp-key).
  cat >"$CLI" <<CLI
#!/usr/bin/env bash
cd $DIR && exec docker compose exec -T panel ixray-cli "\$@"
CLI
  chmod 0755 "$CLI"
}

cmd_key() {
  need_root; need_install
  compose exec -T panel ixray-cli generate-temp-key
}

cmd_update() {
  need_root; need_install
  install_self
  [[ -n ${1:-} ]] && set_setting IXRAY_VERSION "${1#v}"
  say "Updating to $(setting IXRAY_VERSION)"
  note "A database backup is taken first."
  cmd_backup
  write_stack
  compose pull -q panel || die "could not download the image (ixray login to sign in again)"
  compose up -d --remove-orphans
  wait_healthy
  docker image prune -f >/dev/null
}

cmd_backup() {
  need_root; need_install
  install -d -m 0750 "$BACKUPS"
  local file="$BACKUPS/ixray-$(date -u +%Y%m%d-%H%M%S).sql.gz"
  compose exec -T postgres pg_dump -U ixray -d ixray --clean --if-exists | gzip >"$file" || { rm -f "$file"; die "backup failed"; }
  [[ -s $file ]] || { rm -f "$file"; die "backup came out empty"; }
  chmod 600 "$file"
  note "backup: $file ($(du -h "$file" | cut -f1))"
}

cmd_restore() {
  need_root; need_install
  local file="${1:-}" answer
  [[ -f $file ]] || die "usage: ixray restore <backup>   (.dump from the panel or Telegram, or .sql.gz from ixray backup)"
  printf '%sThis replaces the current database with %s.%s\n' "$red" "$file" "$off"
  ask answer "Type 'restore' to continue"
  [[ $answer == restore ]] || die "cancelled"
  cmd_backup
  compose stop panel
  if [[ $(head -c 5 "$file") == PGDMP ]]; then
    # A dump the panel made itself (the Backups page, or the file it sends to Telegram).
    # Emptied first: a table added by a newer version and missing from an older
    # dump would otherwise stay behind and trip the migrations on start.
    compose exec -T postgres psql -q -U ixray -d ixray -c "drop schema public cascade" -c "create schema public" >/dev/null \
      && compose exec -T postgres pg_restore -U ixray -d ixray --no-owner --no-privileges <"$file" \
      || die "the backup could not be loaded; the database from before is in $BACKUPS"
  else
    gunzip -c "$file" | compose exec -T postgres psql -q -U ixray -d ixray >/dev/null
  fi
  compose up -d
  wait_healthy
}

cmd_domain() {
  need_root; need_install
  [[ ${1:-} =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "usage: ixray domain <name>"
  set_setting PANEL_DOMAIN "$1"
  compose up -d
  show_address
}

cmd_extra_domains() {
  need_root; need_install
  local names=""
  for n in "$@"; do
    [[ $n =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "not a domain name: $n"
    names="${names:+$names }$n"
  done
  set_setting PANEL_EXTRA_DOMAINS "$names"
  write_stack
  compose up -d caddy
  if [[ -n $names ]]; then note "also answering on: $names"; else note "extra domains cleared"; fi
  note "each name must point at this server; its certificate is issued on the first visit"
}

cmd_path() {
  need_root; need_install
  local path="${1:-$(rand 20)}"
  path="/${path#/}"; path="${path%/}/"
  [[ $path =~ ^/[A-Za-z0-9_.-]+/$ ]] || die "the path may only hold letters, digits, - _ and ."
  set_setting DASHBOARD_PATH "$path"
  compose up -d panel
  wait_healthy
  show_address
}

cmd_uninstall() {
  need_root; need_install
  local answer purge="${1:-}"
  if [[ $purge == --purge ]]; then
    printf '%sThis removes the panel AND its database, users and certificates.%s\n' "$red" "$off"
    ask answer "Type the panel domain to confirm"
    [[ $answer == "$(setting PANEL_DOMAIN)" ]] || die "cancelled"
    compose down -v
    rm -rf "$DIR"
    note "removed with all data (backups in $BACKUPS were kept)"
  else
    ask answer "Stop and remove the panel containers? Data is kept. (y/N)"
    [[ $answer == y || $answer == Y ]] || die "cancelled"
    compose down
    note "stopped; data volumes and $DIR kept (ixray uninstall --purge deletes them)"
  fi
}

usage() {
  cat <<TXT
${bold}ixray${off}: manage the iXRay panel on this server

  install [version]    set the panel up (asks for the domain and a registry token)
  key                  one-time key to create the owner account or reset its password
  status               containers and the dashboard address
  logs [-f]            panel log
  restart              restart the panel (after editing $DIR/.env)
  update [version]     back up, download the new version and start it
  backup               dump the database to $BACKUPS
  restore <file>       load a backup: a .dump from the panel or Telegram, or a .sql.gz (asks first)
  domain <name>        move the panel to another domain
  extra-domains [a b]  more domains the panel also answers on (none = clear)
  path [new-path]      change the secret dashboard address (random if omitted)
  login                sign in to the image registry again
  uninstall [--purge]  remove the containers (--purge also deletes all data)
TXT
}

[[ ${1:-} == @ ]] && shift
cmd="${1:-help}"; shift || true
case "$cmd" in
  install) cmd_install "$@" ;;
  update) cmd_update "$@" ;;
  key) cmd_key ;;
  self-update) need_root; install_self; note "ixray command updated" ;;
  status) need_install; compose ps; show_address ;;
  logs) need_install; compose logs --tail 200 "$@" panel ;;
  restart) need_root; need_install; compose up -d; compose restart panel; wait_healthy ;;
  backup) cmd_backup ;;
  restore) cmd_restore "$@" ;;
  domain) cmd_domain "$@" ;;
  extra-domains) cmd_extra_domains "$@" ;;
  path) cmd_path "$@" ;;
  login) need_root; registry_login ;;
  uninstall) cmd_uninstall "$@" ;;
  help | -h | --help) usage ;;
  *) usage; exit 1 ;;
esac
