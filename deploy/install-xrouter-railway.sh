#!/usr/bin/env bash
# ==============================================================================
# X Router — Railway installer
#
# Deploys https://github.com/yanndevgbut/xrouter-railway (fork of
# johsua092-ui/xrouter) to Railway with:
#   - service created from the GitHub repo (auto-deploy on push)
#   - persistent volume mounted at /app/data (SQLite + JWT secret)
#   - Railway domain on port 20128
#   - production environment variables
#
# The dashboard password is NOT generated here. Set INITIAL_PASSWORD in
# Railway -> Variables before the first login from a public address.
#
# Usage: bash deploy/install-xrouter-railway.sh [options]
# ==============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_REPO="yanndevgbut/xrouter-railway"
DEFAULT_BRANCH="main"
DEFAULT_PROJECT="xrouter"
DEFAULT_SERVICE="xrouter"
APP_PORT="20128"
APP_DATA_DIR="/app/data"
HEALTH_PATH="/api/health"
RAILWAY_APP_URL="https://github.com/apps/railway-app/installations/new"

REPO="$DEFAULT_REPO"
BRANCH="$DEFAULT_BRANCH"
PROJECT_NAME="$DEFAULT_PROJECT"
SERVICE_NAME="$DEFAULT_SERVICE"
WORKSPACE=""
CUSTOM_DOMAIN=""
USE_LOCAL=false
DO_UPDATE=false
NO_WAIT=false
ASSUME_YES=false
DRY_RUN=false

RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fi

info() { printf "${CYAN}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}OK${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}!!${NC}  %s\n" "$*" >&2; }
die()  { printf "${RED}XX${NC}  %s\n" "$*" >&2; exit 1; }

trap 'printf "${RED}XX${NC}  Gagal pada baris %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

usage() {
  cat <<EOF
X Router — Railway installer v${SCRIPT_VERSION}

Usage:
  bash deploy/install-xrouter-railway.sh [options]

Options:
  --repo <owner/repo>     Repo GitHub untuk deploy (default: ${DEFAULT_REPO})
  --branch <name>         Branch yang dipakai (default: ${DEFAULT_BRANCH})
  --project <name>        Nama project Railway (default: ${DEFAULT_PROJECT})
  --service <name>        Nama service Railway (default: ${DEFAULT_SERVICE})
  --workspace <id|name>   Workspace Railway (opsional, untuk akun multi-workspace)
  --domain <host>         Custom domain (default: domain *.up.railway.app)
  --local                 Deploy dari source lokal (railway up) alih-alih GitHub
  --update                Redeploy commit terbaru dari repo (railway redeploy --from-source)
  --no-wait               Jangan tunggu build/health check
  -y, --yes               Non-interaktif (tidak ada prompt)
  --dry-run               Cetak perintah tanpa mengubah apa pun
  -h, --help              Tampilkan bantuan ini

Environment:
  RAILWAY_TOKEN           Project token (untuk CI)
  RAILWAY_API_TOKEN       Account/workspace token (untuk CI)
  INITIAL_PASSWORD        Kalau di-set, ikut dikirim sebagai password dashboard.
                          Kalau tidak, isi manual di Railway -> Variables.

Contoh:
  bash deploy/install-xrouter-railway.sh
  bash deploy/install-xrouter-railway.sh --workspace "My Team" -y
  bash deploy/install-xrouter-railway.sh --domain router.example.com
  bash deploy/install-xrouter-railway.sh --update
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)        REPO="${2:?--repo butuh nilai}"; shift 2 ;;
      --branch)      BRANCH="${2:?--branch butuh nilai}"; shift 2 ;;
      --project)     PROJECT_NAME="${2:?--project butuh nilai}"; shift 2 ;;
      --service)     SERVICE_NAME="${2:?--service butuh nilai}"; shift 2 ;;
      --workspace)   WORKSPACE="${2:?--workspace butuh nilai}"; shift 2 ;;
      --domain)      CUSTOM_DOMAIN="${2:?--domain butuh nilai}"; shift 2 ;;
      --local)       USE_LOCAL=true; shift ;;
      --update)      DO_UPDATE=true; shift ;;
      --no-wait)     NO_WAIT=true; shift ;;
      -y|--yes)      ASSUME_YES=true; shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "Opsi tidak dikenal: $1 (lihat --help)" ;;
    esac
  done

  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "Format --repo harus owner/repo, contoh: yanndevgbut/xrouter-railway"
}

run() {
  if $DRY_RUN; then
    printf '+ '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

mask() {
  local value="$1"
  if [[ ${#value} -gt 8 ]]; then
    printf '%s…%s' "${value:0:4}" "${value: -2}"
  else
    printf '***'
  fi
}

gen_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import secrets; print(secrets.token_hex(32))'
  elif command -v node >/dev/null 2>&1; then
    node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))'
  else
    die "Butuh openssl, python3, atau node untuk membuat secret."
  fi
}

preflight() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v git  >/dev/null 2>&1 || missing+=("git")
  if (( ${#missing[@]} > 0 )); then
    die "Perintah berikut belum tersedia: ${missing[*]}"
  fi

  export PATH="$HOME/.railway/bin:$HOME/.local/bin:$PATH"

  if ! command -v railway >/dev/null 2>&1; then
    if $DRY_RUN; then
      warn "Railway CLI belum terpasang (dry-run: tidak menginstall)."
      printf '+ bash <(curl -fsSL https://railway.com/install.sh)\n'
    else
      info "Railway CLI belum terpasang, menginstall..."
      bash <(curl -fsSL https://railway.com/install.sh) \
        || die "Instalasi Railway CLI gagal. Install manual: https://docs.railway.com/cli"
      export PATH="$HOME/.railway/bin:$HOME/.local/bin:$PATH"
      command -v railway >/dev/null 2>&1 \
        || die "Railway CLI terpasang tapi tidak ada di PATH (~/.railway/bin)."
    fi
  fi
  export RAILWAY_NO_TELEMETRY=1

  if $DRY_RUN; then
    ok "Preflight selesai (dry-run)."
    return
  fi

  if ! railway whoami >/dev/null 2>&1; then
    if [[ -n "${RAILWAY_TOKEN:-}" || -n "${RAILWAY_API_TOKEN:-}" ]]; then
      warn "Menggunakan token Railway dari environment (tanpa cek whoami)."
    elif $ASSUME_YES; then
      die "Belum login ke Railway. Jalankan 'railway login' lalu ulangi."
    else
      info "Login ke Railway..."
      if [[ -n "${SSH_CONNECTION:-}" || ! -t 0 ]]; then
        railway login --browserless || die "Login Railway gagal."
      else
        railway login || railway login --browserless || die "Login Railway gagal."
      fi
    fi
  fi

  ok "Railway CLI siap: $(railway --version 2>/dev/null | head -n1)"
}

repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$script_dir"
}

ensure_project() {
  cd "$(repo_root)"

  if ! $DRY_RUN && railway status --json >/dev/null 2>&1; then
    info "Project Railway sudah ter-link di direktori ini."
    return
  fi

  if $DRY_RUN; then
    if [[ -n "$WORKSPACE" ]]; then
      printf '+ railway init --name %q --workspace %q --json\n' "$PROJECT_NAME" "$WORKSPACE"
    else
      printf '+ railway init --name %q --json\n' "$PROJECT_NAME"
    fi
    return
  fi

  if [[ -n "$WORKSPACE" ]]; then
    railway init --name "$PROJECT_NAME" --workspace "$WORKSPACE" --json >/dev/null \
      || die "Gagal membuat project Railway."
  else
    railway init --name "$PROJECT_NAME" --json >/dev/null \
      || die "Gagal membuat project Railway (coba --workspace <id>)."
  fi
  ok "Project '$PROJECT_NAME' dibuat dan ter-link."
}

ensure_service() {
  local services=""
  if ! $DRY_RUN; then
    services="$(railway service list --json 2>/dev/null || true)"
  fi

  if printf '%s' "$services" | tr -d '[:space:]' | grep -q "\"name\":\"${SERVICE_NAME}\""; then
    info "Service '${SERVICE_NAME}' sudah ada, memastikan ter-link..."
    run railway service link "$SERVICE_NAME"
    ok "Service ter-link."
    return
  fi

  if $USE_LOCAL; then
    info "Membuat service kosong '${SERVICE_NAME}' (mode --local)..."
    run railway add --service "$SERVICE_NAME" --json
  else
    info "Membuat service '${SERVICE_NAME}' dari ${REPO}@${BRANCH}..."
    if ! $DRY_RUN; then
      if ! out="$(railway add --repo "$REPO" --branch "$BRANCH" --service "$SERVICE_NAME" --json 2>&1)"; then
        printf '%s\n' "$out" >&2
        warn "Gagal membuat service dari GitHub."
        warn "Pastikan Railway GitHub App sudah di-install dan punya akses ke ${REPO}:"
        warn "  ${RAILWAY_APP_URL}"
        warn "Atau jalankan ulang dengan --local dari dalam clone repo."
        die "Service GitHub belum bisa dibuat."
      fi
    fi
  fi
  ok "Service '${SERVICE_NAME}' siap."
}

ensure_volume() {
  local volumes="" compact=""
  if ! $DRY_RUN; then
    volumes="$(railway volume list --json 2>/dev/null || true)"
    compact="$(printf '%s' "$volumes" | tr -d '[:space:]')"
  fi

  if [[ -n "$compact" ]] && printf '%s' "$compact" | grep -q "\"mountPath\":\"${APP_DATA_DIR}\""; then
    ok "Volume ${APP_DATA_DIR} sudah terpasang."
    return
  fi

  if $DRY_RUN; then
    printf '+ railway volume add -m %q\n' "$APP_DATA_DIR"
    return
  fi

  info "Memasang volume persisten di ${APP_DATA_DIR}..."
  if ! out="$(railway volume add -m "$APP_DATA_DIR" 2>&1)"; then
    if printf '%s' "$out" | grep -qiE 'already|exists|duplicate'; then
      warn "Volume sudah terpasang (dilewati)."
    else
      printf '%s\n' "$out" >&2
      die "Gagal memasang volume. Pastikan service '${SERVICE_NAME}' ter-link."
    fi
  fi
  ok "Volume ${APP_DATA_DIR} siap."
}

detect_domain() {
  local list host
  list="$(railway domain list -s "$SERVICE_NAME" --json 2>/dev/null || true)"
  host="$(printf '%s' "$list" | grep -oE '[a-z0-9][a-z0-9.-]*\.up\.railway\.app' | head -n1 || true)"
  printf '%s' "$host"
}

ensure_domain() {
  HOST=""

  if [[ -n "$CUSTOM_DOMAIN" ]]; then
    HOST="$CUSTOM_DOMAIN"
    info "Menambahkan custom domain ${HOST}..."
    run railway domain "$HOST" --port "$APP_PORT" -s "$SERVICE_NAME" --json
    warn "Tambahkan record CNAME + TXT yang ditampilkan Railway di DNS Anda."
    return
  fi

  if $DRY_RUN; then
    HOST="<railway-domain>"
    printf '+ railway domain --port %q -s %q --json\n' "$APP_PORT" "$SERVICE_NAME"
    return
  fi

  HOST="$(detect_domain)"
  if [[ -n "$HOST" ]]; then
    ok "Domain sudah ada: https://${HOST}"
    return
  fi

  info "Membuat domain Railway (port ${APP_PORT})..."
  if ! out="$(railway domain --port "$APP_PORT" -s "$SERVICE_NAME" --json 2>&1)"; then
    printf '%s\n' "$out" >&2
    warn "Domain belum bisa dibuat sekarang; akan dicoba setelah deploy sukses."
    return
  fi
  HOST="$(printf '%s' "$out" | grep -oE '[a-z0-9][a-z0-9.-]*\.up\.railway\.app' | head -n1 || true)"
  if [[ -z "$HOST" ]]; then
    warn "Tidak bisa membaca domain dari output Railway."
    return
  fi
  ok "Domain: https://${HOST}"
}

existing_vars() {
  railway variable list --kv -s "$SERVICE_NAME" 2>/dev/null | tr -d '\r' || true
}

get_existing_var() {
  local vars="$1" key="$2"
  printf '%s\n' "$vars" | grep -E "^${key}=" | head -n1 | cut -d= -f2- || true
}

set_env_vars() {
  local vars jwt api_secret machine_salt initial_password node_options
  vars="$(existing_vars)"

  jwt="$(get_existing_var "$vars" JWT_SECRET)"
  api_secret="$(get_existing_var "$vars" API_KEY_SECRET)"
  machine_salt="$(get_existing_var "$vars" MACHINE_ID_SALT)"

  [[ -n "$jwt" ]] || jwt="$(gen_hex)"
  [[ -n "$api_secret" ]] || api_secret="$(gen_hex)"
  [[ -n "$machine_salt" ]] || machine_salt="$(gen_hex)"
  initial_password="${INITIAL_PASSWORD:-}"
  node_options="--expose-gc --max-old-space-size=256 --dns-result-order=ipv4first"

  local args=(
    "NODE_ENV=production"
    "PORT=${APP_PORT}"
    "DATA_DIR=${APP_DATA_DIR}"
    "JWT_SECRET=${jwt}"
    "API_KEY_SECRET=${api_secret}"
    "MACHINE_ID_SALT=${machine_salt}"
    "AUTH_COOKIE_SECURE=true"
    "NEXT_TELEMETRY_DISABLED=1"
    "NODE_OPTIONS=${node_options}"
    "ENABLE_REQUEST_LOGS=false"
    "OBSERVABILITY_ENABLED=true"
    "REQUIRE_API_KEY=false"
  )
  if [[ -n "$HOST" ]]; then
    args+=(
      "BASE_URL=https://${HOST}"
      "PUBLIC_BASE_URL=https://${HOST}"
      "NEXT_PUBLIC_BASE_URL=https://${HOST}"
    )
  fi
  if [[ -n "$initial_password" ]]; then
    args+=("INITIAL_PASSWORD=${initial_password}")
  fi

  if $DRY_RUN; then
    printf '+ railway variable set'
    local item key value
    for item in "${args[@]}"; do
      key="${item%%=*}"; value="${item#*=}"
      case "$key" in
        *SECRET*|*SALT*|INITIAL_PASSWORD) printf ' %s=%s' "$key" "$(mask "$value")" ;;
        *) printf ' %q' "$item" ;;
      esac
    done
    printf ' -s %q\n' "$SERVICE_NAME"
    return
  fi

  info "Menyetel environment variables (secret yang sudah ada tidak dirotasi)..."
  railway variable set "${args[@]}" -s "$SERVICE_NAME" >/dev/null
  ok "Environment variables siap."
}

deploy_local() {
  local root
  root="$(repo_root)"
  [[ -f "$root/Dockerfile" && -f "$root/package.json" ]] \
    || die "--local harus dijalankan dari dalam clone repo (Dockerfile + package.json tidak ditemukan)."
  info "Deploy dari source lokal (railway up)..."
  run railway up "$root" -s "$SERVICE_NAME" --ci
}

latest_status() {
  local json
  json="$(railway deployment list --json --limit 1 -s "$SERVICE_NAME" 2>/dev/null || true)"
  printf '%s' "$json" | tr -d '[:space:]' \
    | grep -oE '"status":"[A-Z_]+"' | head -n1 | cut -d'"' -f4 || true
}

wait_for_deploy() {
  local timeout="${1:-1800}"
  local deadline=$(( SECONDS + timeout )) status=""
  info "Menunggu deployment selesai (maks $((timeout / 60)) menit)..."
  while (( SECONDS < deadline )); do
    status="$(latest_status)"
    case "$status" in
      SUCCESS)
        ok "Deployment SUCCESS."
        return 0 ;;
      FAILED|CRASHED|REMOVED)
        warn "Deployment $status. 50 baris terakhir build log:"
        railway logs --build -s "$SERVICE_NAME" 2>/dev/null | tail -n 50 || true
        return 1 ;;
      "") : ;;
      *) info "status: $status" ;;
    esac
    sleep 10
  done
  warn "Timeout menunggu deployment."
  return 1
}

wait_for_health() {
  local host="$1" url="https://${1}${HEALTH_PATH}"
  local deadline=$(( SECONDS + 300 ))
  info "Menunggu ${url} sehat..."
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 10 "$url" 2>/dev/null | grep -q '"ok"'; then
      ok "Health check lolos: ${url}"
      return 0
    fi
    sleep 5
  done
  warn "Health check belum lolos. Cek: railway logs -s ${SERVICE_NAME}"
  return 1
}

prompt_password() {
  local vars
  vars="$(existing_vars)"
  if [[ -n "$(get_existing_var "$vars" INITIAL_PASSWORD)" ]]; then
    ok "INITIAL_PASSWORD sudah ada di Railway Variables."
    return
  fi

  if $ASSUME_YES; then
    warn "INITIAL_PASSWORD belum di-set. Login dari domain publik akan ditolak"
    warn "sampai Anda mengisinya di Railway -> Variables (service ${SERVICE_NAME})."
    return
  fi

  cat <<EOF

${BOLD}Langkah manual: password dashboard${NC}
  Buka Railway -> project ${PROJECT_NAME} -> service ${SERVICE_NAME} -> Variables,
  tambahkan:
      INITIAL_PASSWORD=<password pilihan Anda>

  Tanpa ini, login dari domain publik sengaja ditolak (anti default-password).
  Railway akan redeploy otomatis setelah variabel ditambahkan.

EOF
  read -r -p "Tekan Enter setelah INITIAL_PASSWORD diisi (atau Enter untuk lewati)... " _ || true
}

summary() {
  local host="$1"
  printf '\n%sX Router siap%s\n\n' "$BOLD" "$NC"
  printf '  Dashboard   : https://%s/login\n' "$host"
  printf '  API OpenAI  : https://%s/v1\n' "$host"
  printf '  API Claude  : https://%s\n' "$host"
  printf '  Health      : https://%s%s\n' "$host" "$HEALTH_PATH"
  printf '\n  Project     : %s\n' "$PROJECT_NAME"
  printf '  Service     : %s\n' "$SERVICE_NAME"
  printf '  Volume      : %s\n' "$APP_DATA_DIR"
  printf '\n  Logs        : railway logs -s %s\n' "$SERVICE_NAME"
  printf '  Redeploy    : bash deploy/install-xrouter-railway.sh --update\n'
  printf '  Backup data : railway volume files download / ./xrouter-data-backup\n'
  if [[ -z "${INITIAL_PASSWORD:-}" ]]; then
    printf '\n  %sPassword belum di-set.%s Isi INITIAL_PASSWORD di Railway -> Variables.\n' "$YELLOW" "$NC"
  fi
  printf '\n'
}

do_update() {
  preflight
  cd "$(repo_root)"
  railway status --json >/dev/null 2>&1 \
    || die "Direktori ini belum ter-link ke project Railway. Jalankan tanpa --update dulu."
  info "Redeploy commit terbaru dari ${REPO}@${BRANCH}..."
  railway redeploy --from-source -s "$SERVICE_NAME" -y >/dev/null
  if $NO_WAIT; then
    ok "Redeploy dijadwalkan (--no-wait)."
    return
  fi
  wait_for_deploy 1800 || exit 1
  HOST="$(detect_domain)"
  if [[ -n "$HOST" ]]; then
    wait_for_health "$HOST" || true
  fi
  summary "${HOST:-<domain>}"
}

main() {
  parse_args "$@"

  if $DO_UPDATE; then
    do_update
    return
  fi

  printf '%sX Router — Railway installer v%s%s\n' "$BOLD" "$SCRIPT_VERSION" "$NC"
  $DRY_RUN && warn "Mode dry-run: tidak ada perubahan yang dilakukan."

  preflight
  ensure_project
  ensure_service
  ensure_volume
  ensure_domain
  set_env_vars

  if $USE_LOCAL; then
    deploy_local
  fi

  if $DRY_RUN; then
    printf '\n+ tunggu deployment + health check https://%s%s\n' "$HOST" "$HEALTH_PATH"
    summary "${HOST:-<railway-domain>}"
    return
  fi

  if $NO_WAIT; then
    warn "Deploy berjalan di background (--no-wait)."
    summary "${HOST:-<railway-domain>}"
    return
  fi

  prompt_password

  wait_for_deploy 1800 || exit 1

  if [[ -z "$HOST" ]]; then
    HOST="$(detect_domain)"
    if [[ -n "$HOST" ]]; then
      set_env_vars
      wait_for_deploy 900 || true
    fi
  fi

  [[ -n "$HOST" ]] || die "Domain belum tersedia. Buat manual di Railway -> Settings -> Networking."
  wait_for_health "$HOST" || true
  summary "$HOST"
}

main "$@"
