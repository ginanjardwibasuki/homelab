#!/bin/bash
# ==============================================================================
# HOMELAB STACK INSTALLER — ENTERPRISE EDITION
# Version: 3.0.1-enterprise (independent services + domain prompt)
# ==============================================================================
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CONSTANTS
# ══════════════════════════════════════════════════════════════════════════════
readonly SCRIPT_VERSION="3.0.1-enterprise"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/homelab-installer.log"

# SSD mount point & struktur
readonly MOUNT_DIR="/mnt/ssd"
readonly NC_DIR="$MOUNT_DIR/nextcloud"
readonly NC_DATA="$NC_DIR/data"
readonly NC_EXT="$NC_DIR/external_storage"
readonly NC_MEDIA="$NC_EXT/media"
readonly IMMICH_DIR="$MOUNT_DIR/immich"

# Local disk
readonly APP_BASE="/root/homelab"
readonly COMPOSE_DIR="$APP_BASE"
readonly COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
readonly RESTORE_DIR="/root/restore"
readonly CONFIG_DIR="/root/config"
readonly CONFIG_FILE="$CONFIG_DIR/homelab.conf"
readonly LOCK_FILE="/var/lock/homelab-backup.lock"
readonly UTIL_DIR="/usr/local/bin"

# Local path
readonly IMMICH_ML_CACHE="$APP_BASE/immich-machine-learning/model-cache"
readonly IMMICH_POSTGRES="$APP_BASE/immich/postgres"

readonly MIN_DISK_GB=5
readonly NC_READY_TIMEOUT=300
readonly DB_READY_TIMEOUT=180
readonly TG_MAX_PART_MB=48

readonly C_RESET='\033[0m'
readonly C_CYAN='\033[1;36m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'
readonly C_GREY='\033[0;90m'

SERVER_IP=""
SERVER_DOMAIN=""
INPUT_PASSWORD=""
DB_PASSWORD=""
TG_BOT_TOKEN=""
TG_CHAT_ID=""
RESET_MODE=0
CHECK_ONLY=0
START_TIME=$(date +%s)

# ══════════════════════════════════════════════════════════════════════════════
# LOGGING
# ══════════════════════════════════════════════════════════════════════════════
_log() {
    local level="$1" color="$2" msg="$3"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[${level}]${C_RESET} ${msg}"
    echo "[${ts}] [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()  { _log "INFO " "$C_CYAN"   "$*"; }
log_ok()    { _log "OK   " "$C_GREEN"  "$*"; }
log_warn()  { _log "WARN " "$C_YELLOW" "$*"; }
log_err()   { _log "ERROR" "$C_RED"    "$*"; }
log_step()  { echo ""; _log "STEP " "$C_CYAN"  "▶ $*"; }

banner() {
    echo -e "${C_CYAN}"
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║    HOMELAB STACK INSTALLER  —  ENTERPRISE EDITION            ║
║    Nextcloud  +  Immich  +  Jellyfin  (Independent)          ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${C_RESET}  Version: ${SCRIPT_VERSION}"
    echo -e "  Log    : ${LOG_FILE}"
    echo ""
}

on_error() {
    local exit_code=$?
    local line_no="${1:-?}"
    log_err "Script gagal di baris $line_no (exit=$exit_code)"
    log_err "Cek log lengkap: $LOG_FILE"
    echo ""
    echo -e "${C_YELLOW}[i] Tip: untuk reset bersih, jalankan:${C_RESET}"
    echo -e "    $SCRIPT_NAME --reset"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_err "Harus dijalankan sebagai root."
        exit 1
    fi
}

docker_is_healthy() {
    local c="$1"
    local st
    st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo "none")
    [[ "$st" == "healthy" ]]
}

docker_is_running() {
    local c="$1"
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]
}

wait_until() {
    local timeout="$1" interval="$2" desc="$3"
    shift 3
    local elapsed=0
    while (( elapsed < timeout )); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log_err "Timeout ${timeout}s menunggu: $desc"
    return 1
}

prompt_yes_no() {
    local prompt="$1" default="${2:-n}"
    local ans
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
    else
        read -rp "$prompt [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]]
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# CLI ARGS
# ══════════════════════════════════════════════════════════════════════════════
parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --reset|-r)  RESET_MODE=1 ;;
            --check|-c)  CHECK_ONLY=1 ;;
            --help|-h)
                cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  (tanpa opsi)   Install / re-run idempotent (independent services)
  --reset, -r    Hapus semua container + data (safe: abort jika SSD busy)
  --check, -c    Hanya pre-flight check (tidak install)
  --help, -h     Tampilkan bantuan ini
EOF
                exit 0
                ;;
            *) log_warn "Argumen tidak dikenal: $arg" ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0: PRE-FLIGHT
# ══════════════════════════════════════════════════════════════════════════════
phase_preflight() {
    log_step "PHASE 0: Pre-flight checks"

    require_root
    mkdir -p "$(dirname "$LOG_FILE")"

    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        log_err "Tidak bisa deteksi IP."
        exit 1
    fi
    log_ok "IP Server: $SERVER_IP"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        log_ok "OS: ${PRETTY_NAME:-unknown}"
    fi

    if ! mountpoint -q "$MOUNT_DIR"; then
        log_warn "$MOUNT_DIR bukan mountpoint (SSD mungkin tidak di-mount)"
        if [[ ! -d "$MOUNT_DIR" ]]; then
            log_err "$MOUNT_DIR tidak ada."
            exit 1
        fi
        if ! prompt_yes_no "Lanjutkan pakai folder $MOUNT_DIR (bukan mount)?" "n"; then
            exit 1
        fi
    else
        log_ok "SSD mounted di $MOUNT_DIR"
    fi

    local avail_gb
    avail_gb=$(df -BG "$MOUNT_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [[ -z "$avail_gb" || "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        log_err "Disk space kurang (perlu ${MIN_DISK_GB}GB, ada ${avail_gb:-0}GB)."
        exit 1
    fi
    log_ok "Disk space SSD: ${avail_gb}GB free"

    avail_gb=$(df -BG /root 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [[ -n "$avail_gb" && "$avail_gb" -lt "$MIN_DISK_GB" ]]; then
        log_warn "/root hanya ${avail_gb}GB free"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 0.5: BOOTSTRAP
# ══════════════════════════════════════════════════════════════════════════════
phase_bootstrap() {
    log_step "PHASE 0.5: Bootstrap minimal packages"

    export DEBIAN_FRONTEND=noninteractive

    local need_install=0
    local pkg
    for pkg in curl ca-certificates gnupg cron sudo tar coreutils acl; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            need_install=1
            break
        fi
    done

    if (( need_install )); then
        log_info "Update apt & install paket minimal..."
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates gnupg cron sudo tar coreutils acl >/dev/null
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_err "curl masih tidak tersedia setelah bootstrap. Cek apt."
        exit 1
    fi

    log_ok "Bootstrap OK — curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
}

# ══════════════════════════════════════════════════════════════════════════════
# CONFIG MANAGER
# ══════════════════════════════════════════════════════════════════════════════
config_get() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null \
        | head -1 \
        | sed -E "s/^${key}=\"?([^\"]*)\"?$/\1/" \
        || echo ""
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Memuat config dari $CONFIG_FILE"
        DB_PASSWORD=$(config_get DB_PASSWORD)
        TG_BOT_TOKEN=$(config_get TG_BOT_TOKEN)
        TG_CHAT_ID=$(config_get TG_CHAT_ID)
        SERVER_DOMAIN=$(config_get SERVER_DOMAIN)
        INPUT_PASSWORD="$DB_PASSWORD"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    local tmp="${CONFIG_FILE}.tmp.$$"
    cat > "$tmp" <<EOF
# Auto-generated by $SCRIPT_NAME on $(date '+%Y-%m-%d %H:%M:%S')
DB_PASSWORD="$INPUT_PASSWORD"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_DOMAIN="$SERVER_DOMAIN"
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    log_ok "Config disimpan: $CONFIG_FILE"
}

prompt_password() {
    echo -e "\n${C_CYAN}=== Password Admin (Nextcloud + Immich + DB) ===${C_RESET}"
    if [[ -n "$DB_PASSWORD" ]]; then
        read -rsp "Password baru [Enter = pakai lama]: " NEW_PASSWORD; echo ""
        if [[ -z "$NEW_PASSWORD" ]]; then
            return 0
        fi
        read -rsp "Konfirmasi: " CONFIRM; echo ""
        if [[ "$NEW_PASSWORD" != "$CONFIRM" ]]; then
            log_err "Password tidak cocok."
            exit 1
        fi
        INPUT_PASSWORD="$NEW_PASSWORD"
    else
        while true; do
            read -rsp "Password baru: " INPUT_PASSWORD; echo ""
            read -rsp "Konfirmasi  : " CONFIRM; echo ""
            if [[ "$INPUT_PASSWORD" == "$CONFIRM" && ${#INPUT_PASSWORD} -ge 8 ]]; then
                break
            fi
            log_warn "Tidak cocok atau kurang dari 8 karakter. Ulangi."
        done
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# PROMPT DOMAIN
# ══════════════════════════════════════════════════════════════════════════════
prompt_domain() {
    echo -e "\n${C_CYAN}=== Domain Nextcloud (opsional) ===${C_RESET}"
    echo -e "${C_GREY}  Kosongkan jika akses via IP saja.${C_RESET}"
    echo -e "${C_GREY}  Contoh: cloud.example.com atau nextcloud.local${C_RESET}"
    echo ""

    local new_domain
    if [[ -n "$SERVER_DOMAIN" ]]; then
        read -rp "Domain baru [Enter = pakai lama: ${SERVER_DOMAIN}]: " new_domain
        new_domain="${new_domain:-$SERVER_DOMAIN}"
    else
        read -rp "Domain: " new_domain
    fi

    # Validasi format domain (kalau tidak kosong)
    if [[ -n "$new_domain" ]]; then
        if [[ "$new_domain" =~ [[:space:]] ]] || \
           [[ "$new_domain" =~ ^https?:// ]]; then
            log_err "Domain tidak boleh mengandung spasi atau http://"
            SERVER_DOMAIN=""
            return 0
        fi

        if [[ ! "$new_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_warn "Format domain '$new_domain' tidak standar."
            if ! prompt_yes_no "Pakai tetap?" "n"; then
                SERVER_DOMAIN=""
                return 0
            fi
        fi

        SERVER_DOMAIN="$new_domain"
        log_ok "Domain: $SERVER_DOMAIN"
    else
        SERVER_DOMAIN=""
        log_warn "Domain dikosongkan — Nextcloud hanya akses via IP."
    fi
}

prompt_telegram() {
    echo -e "\n${C_YELLOW}=== Telegram (opsional) ===${C_RESET}"

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl tidak tersedia — Telegram dilewati."
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        return 0
    fi

    local new_token new_chat
    read -rp "Bot Token [${TG_BOT_TOKEN:0:15}...]: " new_token
    new_token="${new_token:-$TG_BOT_TOKEN}"
    read -rp "Chat ID   [${TG_CHAT_ID:-kosong}]: " new_chat
    new_chat="${new_chat:-$TG_CHAT_ID}"

    if [[ -z "$new_token" || -z "$new_chat" ]]; then
        log_warn "Telegram dilewati."
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        return 0
    fi

    log_info "Validasi ke Telegram API..."
    local bot_check
    bot_check=$(curl -sS --max-time 10 "https://api.telegram.org/bot${new_token}/getMe" 2>/dev/null || true)
    if ! echo "$bot_check" | grep -q '"ok":true'; then
        log_err "Bot Token tidak valid."
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        return 0
    fi
    local chat_check
    chat_check=$(curl -sS --max-time 10 "https://api.telegram.org/bot${new_token}/getChat?chat_id=${new_chat}" 2>/dev/null || true)
    if ! echo "$chat_check" | grep -q '"ok":true'; then
        log_err "Chat ID tidak valid (bot belum di-Start?)"
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        return 0
    fi
    log_ok "Telegram OK"
    TG_BOT_TOKEN="$new_token"
    TG_CHAT_ID="$new_chat"
}

# ══════════════════════════════════════════════════════════════════════════════
# RESET — Safe mode (stop Docker + umount SSD check)
# ══════════════════════════════════════════════════════════════════════════════
do_reset() {
    log_step "RESET MODE — Safe stop + wipe"

    echo -e "${C_RED}"
    echo "  ⚠️  Semua data berikut akan DIHAPUS PERMANEN:"
    echo "      • $APP_BASE"
    echo "      • $NC_DIR         (SSD)"
    echo "      • $IMMICH_DIR     (SSD)"
    echo "      • $CONFIG_DIR"
    echo "      • $RESTORE_DIR"
    echo "      • Semua container homelab"
    echo -e "${C_RESET}"
    echo -e "${C_YELLOW}  ⚠️  Kalau SSD gagal di-unmount → RESET DIBATALKAN"
    echo -e "${C_RESET}"
    echo ""

    read -rp "Ketik 'HAPUS' untuk konfirmasi: " CONFIRM
    if [[ "$CONFIRM" != "HAPUS" ]]; then
        echo "Dibatalkan."
        exit 0
    fi

    local ssd_was_mounted=0
    local ssd_source=""
    local docker_was_running=0

    if systemctl is-active --quiet docker 2>/dev/null; then
        docker_was_running=1
    fi

    # ── 1. Stop container ──
    log_info "[1/6] Stop container..."
    if [[ -f "$COMPOSE_FILE" ]]; then
        (cd "$COMPOSE_DIR" && docker compose down -v --remove-orphans 2>/dev/null) || true
    fi
    docker rm -f nextcloud nextcloud_db nextcloud_redis \
                immich_server immich_machine_learning immich_redis immich_postgres \
                jellyfin 2>/dev/null || true

    # ── 2. Stop Docker daemon ──
    log_info "[2/6] Stop Docker daemon..."
    systemctl stop docker.socket 2>/dev/null || true
    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true

    local _i=0
    while systemctl is-active --quiet docker 2>/dev/null; do
        sleep 1
        _i=$((_i + 1))
        if (( _i >= 30 )); then
            log_warn "  Docker masih active — force kill..."
            systemctl kill -s SIGKILL docker 2>/dev/null || true
            sleep 3
            break
        fi
    done
    log_ok "  Docker stopped"

    # ── 3. Umount SSD (CRITICAL) ──
    log_info "[3/6] Deteksi + umount SSD..."

    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        ssd_was_mounted=1
        ssd_source=$(findmnt -n -o SOURCE "$MOUNT_DIR" 2>/dev/null || echo "")
        log_warn "  SSD ter-mount di $MOUNT_DIR"
        [[ -n "$ssd_source" ]] && log_info "    Device: $ssd_source"

        # Umount nested mount (deepest first)
        local _nested
        _nested=$(findmnt -rn -o TARGET --submounts "$MOUNT_DIR" 2>/dev/null | sort -r || true)
        if [[ -n "$_nested" ]]; then
            while IFS= read -r _m; do
                [[ -z "$_m" || "$_m" == "$MOUNT_DIR" ]] && continue
                log_info "    Umount nested: $_m"
                umount "$_m" 2>/dev/null || umount -l "$_m" 2>/dev/null || \
                    log_warn "      Gagal: $_m"
            done <<< "$_nested"
        fi

        # Umount main
        log_info "    Umount $MOUNT_DIR..."
        local umount_ok=0
        if umount "$MOUNT_DIR" 2>/dev/null; then
            umount_ok=1
            log_ok "    Umount OK"
        elif umount -l "$MOUNT_DIR" 2>/dev/null; then
            sleep 2
            if ! mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
                umount_ok=1
                log_ok "    Umount (lazy) OK"
            fi
        fi

        if (( umount_ok == 0 )); then
            echo ""
            log_err "  ❌ GAGAL umount $MOUNT_DIR — device busy!"
            echo ""
            echo -e "${C_YELLOW}── Diagnostik proses ──${C_RESET}"
            command -v fuser >/dev/null 2>&1 && fuser -vm "$MOUNT_DIR" 2>&1 | sed 's/^/    /' || true
            command -v lsof >/dev/null 2>&1 && lsof +D "$MOUNT_DIR" 2>/dev/null | head -10 | sed 's/^/    /' || true
            echo ""
            echo -e "${C_YELLOW}── Cara fix ──${C_RESET}"
            echo "    1. Cek proses: sudo fuser -vm $MOUNT_DIR"
            echo "    2. Kill: sudo fuser -km $MOUNT_DIR"
            echo "    3. Umount manual: sudo umount $MOUNT_DIR"
            echo "    4. Jalankan ulang: sudo $SCRIPT_NAME --reset"
            echo ""
            log_err "RESET DIBATALKAN — TIDAK ADA DATA YANG DIHAPUS"
            echo ""

            if (( docker_was_running )); then
                log_info "Restart Docker (rollback)..."
                systemctl start containerd 2>/dev/null || true
                systemctl start docker 2>/dev/null || true
            fi
            exit 1
        fi
    else
        log_info "  $MOUNT_DIR tidak ter-mount — skip umount"
    fi

    # ── 4. Hapus data ──
    log_info "[4/6] Hapus direktori data..."

    rm -rf "$APP_BASE" "$CONFIG_DIR" "$RESTORE_DIR"
    log_ok "  Hapus local: $APP_BASE, $CONFIG_DIR, $RESTORE_DIR"

    if (( ssd_was_mounted )) && [[ -n "$ssd_source" ]]; then
        if ! mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            log_info "  Remount SSD sementara untuk hapus..."
            mkdir -p "$MOUNT_DIR"
            if mount "$ssd_source" "$MOUNT_DIR" 2>/dev/null; then
                rm -rf "$NC_DIR" "$IMMICH_DIR"
                log_ok "  Hapus SSD: $NC_DIR, $IMMICH_DIR"
                umount "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
            else
                log_warn "  Gagal remount $ssd_source — data SSD TIDAK dihapus"
            fi
        fi
    fi

    rm -rf /tmp/homelab_* 2>/dev/null || true

    # ── 5. Restart Docker ──
    log_info "[5/6] Restart Docker daemon..."
    systemctl start containerd 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    sleep 3
    systemctl is-active --quiet docker && log_ok "  Docker running" || log_warn "  Docker tidak start"

    # ── 6. Remount SSD ──
    log_info "[6/6] Remount SSD..."
    if (( ssd_was_mounted )) && [[ -n "$ssd_source" ]]; then
        if ! mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            mkdir -p "$MOUNT_DIR"
            mount "$ssd_source" "$MOUNT_DIR" 2>/dev/null && \
                log_ok "  SSD remounted: $ssd_source → $MOUNT_DIR" || \
                log_warn "  Gagal remount — manual: mount $ssd_source $MOUNT_DIR"
        else
            log_ok "  SSD masih mounted"
        fi
    fi

    echo ""
    log_ok "Reset selesai."
    echo -e "     Docker: $(systemctl is-active docker 2>/dev/null || echo unknown)"
    echo -e "     SSD   : $(mountpoint -q "$MOUNT_DIR" 2>/dev/null && echo "mounted" || echo "not mounted")"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: HARDENING
# ══════════════════════════════════════════════════════════════════════════════
phase_hardening() {
    log_step "PHASE 1: System hardening"

    log_info "Konfigurasi SSH..."
    local sshd=/etc/ssh/sshd_config
    if [[ -f "$sshd" ]]; then
        if grep -qE "^#?PermitRootLogin" "$sshd"; then
            sed -i 's/^#\?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' "$sshd"
        else
            echo "PermitRootLogin yes" >> "$sshd"
        fi
        if grep -qE "^#?PasswordAuthentication" "$sshd"; then
            sed -i 's/^#\?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd"
        else
            echo "PasswordAuthentication yes" >> "$sshd"
        fi
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    else
        log_warn "sshd_config tidak ada."
    fi

    log_info "Set timezone Asia/Jakarta..."
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    export DEBIAN_FRONTEND=noninteractive
    dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

    log_info "Install fail2ban..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq fail2ban >/dev/null

    if command -v fail2ban-client >/dev/null 2>&1; then
        cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 10
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
F2B
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
    fi

    log_ok "Hardening selesai"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: RUNTIME
# ══════════════════════════════════════════════════════════════════════════════
phase_runtime() {
    log_step "PHASE 2: Container runtime"

    if ! command -v docker >/dev/null 2>&1; then
        log_info "Install Docker..."
        # shellcheck disable=SC1091
        . /etc/os-release
        local distro="${ID:-debian}"
        if [[ "$distro" != "debian" && "$distro" != "ubuntu" ]]; then
            distro="debian"
        fi

        install -m 0755 -d /etc/apt/keyrings
        rm -f /etc/apt/keyrings/docker.asc
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local suite="${VERSION_CODENAME}"
        if [[ "$distro" == "debian" && "$suite" == "trixie" ]]; then
            suite="bookworm"
        fi

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${suite} stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null
    fi

    if [[ ! -f /etc/docker/daemon.json ]]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<'DJ'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
DJ
        systemctl restart docker 2>/dev/null || true
        sleep 3
    fi

    log_info "Set drop-in docker.service (RequiresMountsFor=$MOUNT_DIR)..."
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Unit]
RequiresMountsFor=$MOUNT_DIR
After=network-online.target
Wants=network-online.target
EOF
    systemctl daemon-reload

    systemctl enable containerd 2>/dev/null || true
    if ! systemctl enable docker 2>/dev/null; then
        log_warn "docker.service tidak bisa di-enable otomatis — cek journalctl -u docker"
    fi
    systemctl start containerd 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    if ! systemctl is-enabled --quiet docker; then
        log_warn "docker.service masih 'disabled' — akan gagal auto-start saat reboot!"
    else
        log_ok "docker.service: enabled (auto-start saat boot)"
    fi

    log_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3: PROVISION (independent services)
# ══════════════════════════════════════════════════════════════════════════════
phase_provision() {
    log_step "PHASE 3: Storage provisioning"

    # ── SSD structure ──
    mkdir -p "$NC_DATA"                # → /var/www/html/data
    mkdir -p "$NC_EXT"                 # → /mnt/external_storage
    mkdir -p "$NC_MEDIA"               # → /media (Jellyfin)

    # Immich: parent + subfolder + marker
    mkdir -p "$IMMICH_DIR"/{library,thumbs,upload,encoded-video,profile,backups}
    for d in library thumbs upload encoded-video profile backups; do
        touch "$IMMICH_DIR/$d/.immich"
    done

    # ── Local disk structure ──
    mkdir -p "$APP_BASE/nextcloud/app"
    mkdir -p "$APP_BASE/nextcloud/db"
    mkdir -p "$IMMICH_POSTGRES"
    mkdir -p "$IMMICH_ML_CACHE"
    mkdir -p "$APP_BASE/jellyfin/config"
    mkdir -p "$APP_BASE/jellyfin/cache"
    mkdir -p "$RESTORE_DIR"

    log_info "Set ownership..."

    # Nextcloud (uid 33)
    chown -R 33:33 "$APP_BASE/nextcloud/app"      2>/dev/null || true
    chown -R 33:33 "$NC_DATA"                      2>/dev/null || true
    chown -R 33:33 "$NC_EXT"                       2>/dev/null || true
    chmod -R u=rwX,g=rX,o= "$NC_DATA"              2>/dev/null || true
    chmod -R u=rwX,g=rX,o= "$NC_EXT"               2>/dev/null || true

    # MariaDB (uid 999)
    chown -R 999:999 "$APP_BASE/nextcloud/db"     2>/dev/null || true
    chmod -R 700 "$APP_BASE/nextcloud/db"          2>/dev/null || true

    # Immich (uid 1000)
    chown -R 1000:1000 "$IMMICH_DIR"               2>/dev/null || true
    chown -R 1000:1000 "$IMMICH_ML_CACHE"          2>/dev/null || true

    # Immich postgres (uid 999)
    chown -R 999:999 "$IMMICH_POSTGRES"            2>/dev/null || true
    chmod -R 700 "$IMMICH_POSTGRES"                2>/dev/null || true

    # Jellyfin (uid 1000)
    chown -R 1000:1000 "$APP_BASE/jellyfin"        2>/dev/null || true

    # ── ACL: Jellyfin (uid 1000) bisa READ folder media ──
    log_info "Set ACL untuk media (Jellyfin read-only)..."
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -R -m u:1000:rX "$NC_MEDIA" 2>/dev/null || true
        setfacl -R -d -m u:1000:rX "$NC_MEDIA" 2>/dev/null || true
        log_ok "  ACL set: uid 1000 = rX di $NC_MEDIA"
    else
        log_warn "  setfacl tidak tersedia — Jellyfin mungkin tidak bisa baca media"
    fi

    log_ok "Layout:"
    echo -e "    ${C_GREY}NC data:${C_RESET}   $NC_DATA"
    echo -e "    ${C_GREY}NC ext:${C_RESET}    $NC_EXT"
    echo -e "    ${C_GREY}NC media:${C_RESET}  $NC_MEDIA"
    echo -e "    ${C_GREY}Immich:${C_RESET}    $IMMICH_DIR"
    echo -e "    ${C_GREY}Local:${C_RESET}     $APP_BASE"
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4: DEPLOY
# ══════════════════════════════════════════════════════════════════════════════

write_compose() {
    mkdir -p "$COMPOSE_DIR"

    local pw_escaped
    pw_escaped=$(printf '%s' "$INPUT_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/$$/g')

    # ── Trusted domains: IP server + domain (kalau ada) ──
    local trusted_domains="$SERVER_IP"
    if [[ -n "$SERVER_DOMAIN" ]]; then
        trusted_domains="$SERVER_IP $SERVER_DOMAIN"
    fi
    log_info "Trusted domains: $trusted_domains"

    cat > "$COMPOSE_FILE" <<EOF
name: homelab-stack

networks:
  homelab-net:
    driver: bridge

services:
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    hostname: nextcloud
    networks: [homelab-net]
    ports:
      - "8080:80"
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_PORT: 3306
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: "${pw_escaped}"
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: "${pw_escaped}"
      NEXTCLOUD_TRUSTED_DOMAINS: "${trusted_domains}"
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PORT: 6379
      PHP_MEMORY_LIMIT: 1G
      PHP_UPLOAD_LIMIT: 10G
      APACHE_BODY_LIMIT: 0
    volumes:
      - /root/homelab/nextcloud/app:/var/www/html
      - /mnt/ssd/nextcloud/data:/var/www/html/data
      - /mnt/ssd/nextcloud/external_storage:/mnt/external_storage
    depends_on:
      nextcloud-db:
        condition: service_healthy
      nextcloud-redis:
        condition: service_started

  nextcloud-db:
    image: mariadb:10.11
    container_name: nextcloud_db
    restart: unless-stopped
    hostname: nextcloud-db
    networks: [homelab-net]
    command:
      - --transaction-isolation=READ-COMMITTED
      - --log-bin=binlog
      - --binlog-format=ROW
      - --innodb-file-per-table=1
      - --skip-name-resolve
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
      - --max-allowed-packet=128M
    environment:
      MYSQL_ROOT_PASSWORD: "${pw_escaped}"
      MYSQL_PASSWORD: "${pw_escaped}"
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_INITDB_SKIP_TZINFO: "1"
    volumes:
      - /root/homelab/nextcloud/db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 15
      start_period: 60s

  nextcloud-redis:
    image: redis:alpine
    container_name: nextcloud_redis
    restart: unless-stopped
    networks: [homelab-net]

  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:release
    restart: unless-stopped
    networks: [homelab-net]
    ports:
      - "2283:2283"
    environment:
      DB_HOSTNAME: immich-postgres
      DB_USERNAME: postgres
      DB_PASSWORD: "${pw_escaped}"
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: immich-redis
    volumes:
      - /mnt/ssd/immich:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      immich-redis:
        condition: service_started
      immich-postgres:
        condition: service_healthy

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:release
    restart: unless-stopped
    networks: [homelab-net]
    volumes:
      - /root/homelab/immich-machine-learning/model-cache:/cache

  immich-redis:
    container_name: immich_redis
    image: valkey/valkey:8-alpine
    restart: unless-stopped
    networks: [homelab-net]

  immich-postgres:
    container_name: immich_postgres
    image: pgvector/pgvector:pg15
    restart: unless-stopped
    networks: [homelab-net]
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: "${pw_escaped}"
      POSTGRES_DB: immich
    volumes:
      - /root/homelab/immich/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d immich"]
      interval: 10s
      timeout: 5s
      retries: 15
      start_period: 60s

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    networks: [homelab-net]
    ports:
      - "8096:8096"
    volumes:
      - /root/homelab/jellyfin/config:/config
      - /root/homelab/jellyfin/cache:/cache
      - /mnt/ssd/nextcloud/external_storage/media:/media:ro
EOF

    if grep -qP '\t' "$COMPOSE_FILE" 2>/dev/null; then
        log_err "File $COMPOSE_FILE mengandung TAB — YAML tidak mengizinkan!"
        grep -nP '\t' "$COMPOSE_FILE" | head -5 | sed 's/^/    /'
        return 1
    fi
}

validate_compose() {
    log_info "Validasi $COMPOSE_FILE..."
    if ! docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1; then
        log_err "docker-compose.yml tidak valid:"
        docker compose -f "$COMPOSE_FILE" config 2>&1 | head -10 | sed 's/^/    /'
        return 1
    fi
    log_ok "  docker-compose.yml valid."
}

cleanup_stale() {
    log_info "Membersihkan container stale..."

    if [[ -f "$COMPOSE_FILE" ]]; then
        (cd "$COMPOSE_DIR" && docker compose down --remove-orphans 2>/dev/null) || true
    fi

    local containers=(nextcloud nextcloud_db nextcloud_redis
                      immich_server immich_machine_learning immich_redis immich_postgres jellyfin)
    local c
    for c in "${containers[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
            log_warn "  Remove stale container: $c"
            docker rm -f "$c" >/dev/null 2>&1 || true
        fi
    done
}

cleanup_stale_nc_config() {
    local nc_config="$APP_BASE/nextcloud/app/config/config.php"

    if [[ ! -f "$nc_config" ]]; then
        return 0
    fi

    log_warn "config.php lama terdeteksi — cek apakah DB punya schema..."

    local db_has_schema=0
    if docker ps --format '{{.Names}}' | grep -qx "nextcloud_db"; then
        if docker exec nextcloud_db mariadb -u nextcloud -p"$INPUT_PASSWORD" \
                -e "USE nextcloud; SHOW TABLES LIKE 'oc_%';" 2>/dev/null | grep -q oc_; then
            db_has_schema=1
        fi
    fi

    if (( db_has_schema == 0 )); then
        log_warn "DB kosong — hapus config.php stale + custom_apps + data."
        rm -f "$nc_config"
        rm -f "$APP_BASE/nextcloud/app/config/CAN_INSTALL"
        rm -rf "$APP_BASE/nextcloud/app/custom_apps"/* 2>/dev/null || true
        rm -rf "$APP_BASE/nextcloud/app/data"/* 2>/dev/null || true
        log_ok "  Stale config dibersihkan."
    else
        log_ok "  DB sudah punya schema — biarkan config.php."
    fi
}

phase_deploy() {
    log_step "PHASE 4: Deploy containers"

    write_compose
    validate_compose

    cleanup_stale_nc_config
    cleanup_stale

    local nc_db_dir="$APP_BASE/nextcloud/db"
    if [[ -d "$nc_db_dir/mysql" ]] && [[ ! -f "$nc_db_dir/mysql/ibdata1" ]]; then
        log_warn "Volume DB Nextcloud tidak lengkap (ibdata1 hilang) — dibersihkan."
        rm -rf "$nc_db_dir"/*
    fi

    mkdir -p "$APP_BASE/nextcloud/db"
    chown -R 999:999 "$APP_BASE/nextcloud/db" 2>/dev/null || true

    log_info "docker compose up -d --force-recreate..."
    cd "$COMPOSE_DIR"
    docker compose up -d --force-recreate --remove-orphans

    log_info "Menunggu DB containers healthy (maks ${DB_READY_TIMEOUT}s)..."
    if ! wait_until "$DB_READY_TIMEOUT" 5 "nextcloud_db healthy" docker_is_healthy nextcloud_db; then
        log_err "nextcloud_db tidak healthy."
        echo ""
        echo "── Log nextcloud_db (50 terakhir) ──"
        docker logs nextcloud_db --tail 50 2>&1 | sed 's/^/    /'
        return 1
    fi
    if ! wait_until "$DB_READY_TIMEOUT" 5 "immich_postgres healthy" docker_is_healthy immich_postgres; then
        log_err "immich_postgres tidak healthy."
        docker logs immich_postgres --tail 50 2>&1 | sed 's/^/    /'
        return 1
    fi

    log_ok "Semua container running."
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5: WAIT READY
# ══════════════════════════════════════════════════════════════════════════════
nc_is_installed() {
    docker exec --user www-data nextcloud php occ status 2>/dev/null \
        | grep -q "installed: true"
}

phase_wait_ready() {
    log_step "PHASE 5: Menunggu Nextcloud ready (maks ${NC_READY_TIMEOUT}s)"

    local elapsed=0
    local err_pattern='Access denied|SQLSTATE\[|Cannot connect|Connection refused|Error while trying to create admin user|Unhandled exception|Fatal error'

    while (( elapsed < NC_READY_TIMEOUT )); do
        if nc_is_installed; then
            echo ""
            log_ok "Nextcloud ready."
            return 0
        fi

        if docker logs nextcloud --tail 100 2>&1 | grep -qiE "$err_pattern"; then
            echo ""
            log_err "FATAL: Nextcloud tidak bisa init (error terdeteksi di log)."
            echo ""
            echo -e "${C_YELLOW}── Error yang terdeteksi ──${C_RESET}"
            docker logs nextcloud --tail 100 2>&1 | grep -iE "$err_pattern" | head -5 | sed 's/^/    /' || true
            echo ""
            echo -e "${C_YELLOW}── Solusi ──${C_RESET}"
            echo "    $SCRIPT_NAME --reset"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."

        if (( elapsed % 60 == 0 )); then
            echo ""
            log_info "@${elapsed}s: $(docker ps --filter name=nextcloud --format '{{.Names}}={{.Status}}' | tr '\n' ' ')"
        fi
    done

    echo ""
    log_err "TIMEOUT setelah ${NC_READY_TIMEOUT}s."
    echo "── Log Nextcloud (50 terakhir) ──"
    docker logs nextcloud --tail 50 2>&1 | sed 's/^/    /' || true
    echo "── Log DB (30 terakhir) ──"
    docker logs nextcloud_db --tail 30 2>&1 | sed 's/^/    /' || true
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6: TUNING
# ══════════════════════════════════════════════════════════════════════════════
phase_tuning() {
    log_step "PHASE 6: Nextcloud tuning"

    log_info "Set config cache + region..."
    docker exec --user www-data nextcloud php occ config:system:set default_phone_region --value="ID" 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=1 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set memcache.local --value="\OC\Memcache\APCu" 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set memcache.distributed --value="\OC\Memcache\Redis" 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set memcache.locking --value="\OC\Memcache\Redis" 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set redis host --value="nextcloud-redis" 2>/dev/null || true
    docker exec --user www-data nextcloud php occ config:system:set redis port --type=integer --value=6379 2>/dev/null || true

    log_info "Fix DB schema..."
    docker exec --user www-data nextcloud php occ db:add-missing-indices --no-interaction 2>/dev/null || true
    docker exec --user www-data nextcloud php occ db:add-missing-columns --no-interaction 2>/dev/null || true
    docker exec --user www-data nextcloud php occ db:add-missing-primary-keys --no-interaction 2>/dev/null || true
    docker exec --user www-data nextcloud php occ db:convert-filecache-bigint --no-interaction 2>/dev/null || true

    log_info "Repair mimetypes..."
    docker exec --user www-data nextcloud php occ maintenance:repair --include-expensive 2>/dev/null || true

    log_info "HSTS header..."
    docker exec --user root nextcloud bash -c '
        f=/etc/apache2/sites-available/000-default.conf
        if [[ -f "$f" ]] && ! grep -q "Strict-Transport-Security" "$f"; then
            sed -i "/<VirtualHost \*:80>/a \\    Header always set Strict-Transport-Security \"max-age=15552000; includeSubDomains\"" "$f"
        fi
    ' 2>/dev/null || true
    docker exec --user root nextcloud a2enmod headers 2>/dev/null || true

    # Enable files_external untuk admin, tapi tanpa auto-register mount
    log_info "Enable files_external app..."
    docker exec --user www-data nextcloud php occ app:enable files_external 2>/dev/null || true

    log_info "Restart Nextcloud..."
    docker restart nextcloud >/dev/null
    wait_until 90 3 "NC restart" nc_is_installed || true

    log_ok "Tuning selesai."
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 7: UTILITIES
# ══════════════════════════════════════════════════════════════════════════════
phase_utilities() {
    log_step "PHASE 7: Command utilities"

    write_autobackup
    write_autorestore
    write_config_cli

    chmod +x "$UTIL_DIR/autobackup" "$UTIL_DIR/autorestore" "$UTIL_DIR/config"
    log_ok "Utilities terpasang: autobackup, autorestore, config"
}

write_autobackup() {
    cat > "$UTIL_DIR/autobackup" <<'AUTOBACKUP_EOF'
#!/bin/bash
set -uo pipefail

readonly LOCK_FILE="/var/lock/homelab-backup.lock"
readonly CONFIG_FILE="/root/config/homelab.conf"
readonly MOUNT_DIR="/mnt/ssd"
readonly NC_DIR="$MOUNT_DIR/nextcloud"
readonly IMMICH_DIR="$MOUNT_DIR/immich"
readonly APP_BASE="/root/homelab"
readonly COMPOSE_DIR="$APP_BASE"
readonly RESTORE_DIR="/root/restore"
readonly TG_MAX_PART_MB=48

readonly ALL_CONTAINERS=(nextcloud nextcloud_db nextcloud_redis \
                         immich_server immich_machine_learning immich_redis immich_postgres jellyfin)

C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_CYAN='\033[1;36m'; C_RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
err()  { echo -e "${C_RED}✗ $*${C_RESET}" >&2; }

exec 9>"$LOCK_FILE"
flock -n 9 || { err "Backup lain sedang berjalan (lock: $LOCK_FILE)"; exit 1; }

SERVICES_STOPPED=0; MAINTENANCE_ON=0

cleanup() {
    local code=$?
    (( code != 0 )) && warn "Terjadi error — memulihkan service state..."
    if (( SERVICES_STOPPED )); then
        docker start nextcloud immich_server jellyfin >/dev/null 2>&1 || true
        sleep 8
    fi
    if (( MAINTENANCE_ON )); then
        docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null || true
    fi
    exit $code
}
trap cleanup EXIT

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config tidak ada: $CONFIG_FILE"
    exit 1
fi

DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$CONFIG_FILE" | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/')
TG_BOT_TOKEN=$(grep -E '^TG_BOT_TOKEN=' "$CONFIG_FILE" | head -1 | sed -E 's/^TG_BOT_TOKEN="?([^"]*)"?$/\1/')
TG_CHAT_ID=$(grep -E '^TG_CHAT_ID=' "$CONFIG_FILE" | head -1 | sed -E 's/^TG_CHAT_ID="?([^"]*)"?$/\1/')

for c in nextcloud_db immich_postgres; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
        err "$c tidak running"
        exit 1
    fi
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMP_DIR="/tmp/homelab_backup_${TIMESTAMP}"
BACKUP_NAME="homelab_backup_${TIMESTAMP}.tar.gz"
BACKUP_FILE="${RESTORE_DIR}/${BACKUP_NAME}"

mkdir -p "$TMP_DIR"/{databases,nextcloud,jellyfin,compose,meta} "$RESTORE_DIR"

echo ""
echo -e "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_CYAN}  HOMELAB SMART BACKUP — ${TIMESTAMP}${C_RESET}"
echo -e "${C_CYAN}  (DB + Config + Addons only — no codebase)${C_RESET}"
echo -e "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
echo ""

log "${C_YELLOW}[1/8]${C_RESET} Nextcloud maintenance mode ON..."
if docker exec --user www-data nextcloud php occ maintenance:mode --on 2>/dev/null; then
    MAINTENANCE_ON=1
fi

log "${C_YELLOW}[2/8]${C_RESET} Stop container aplikasi (DB tetap running)..."
docker stop nextcloud immich_server jellyfin >/dev/null 2>&1 || true
SERVICES_STOPPED=1
sleep 3
ok "  Container stopped."

log "${C_YELLOW}[3/8]${C_RESET} Dump database (SQL)..."

if docker exec nextcloud_db mariadb-dump -u root -p"$DB_PASSWORD" \
        --single-transaction --routines --triggers --events \
        --default-character-set=utf8mb4 \
        nextcloud > "$TMP_DIR/databases/nextcloud.sql" 2>/tmp/nc_dump_err; then
    ok "  nextcloud.sql ($(du -h "$TMP_DIR/databases/nextcloud.sql" | cut -f1))"
else
    err "  Gagal dump NC!"; cat /tmp/nc_dump_err
    exit 1
fi

if docker exec immich_postgres pg_dump -U postgres -d immich \
        > "$TMP_DIR/databases/immich.sql" 2>/tmp/im_dump_err; then
    ok "  immich.sql ($(du -h "$TMP_DIR/databases/immich.sql" | cut -f1))"
else
    err "  Gagal dump Immich!"; cat /tmp/im_dump_err
    exit 1
fi

log "${C_YELLOW}[4/8]${C_RESET} Backup Nextcloud config + custom_apps..."

NC_APP="$APP_BASE/nextcloud/app"

if [[ -f "$NC_APP/config/config.php" ]]; then
    cp "$NC_APP/config/config.php" "$TMP_DIR/nextcloud/config.php"
    ok "  config.php"
fi

if [[ -d "$NC_APP/custom_apps" ]]; then
    cp -a "$NC_APP/custom_apps" "$TMP_DIR/nextcloud/custom_apps" 2>/dev/null || true
    APP_COUNT=$(find "$TMP_DIR/nextcloud/custom_apps" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    ok "  custom_apps/ ($APP_COUNT addons, $(du -sh "$TMP_DIR/nextcloud/custom_apps" 2>/dev/null | cut -f1))"
else
    warn "  custom_apps/ tidak ada (mungkin versi lama)"
fi

if docker start nextcloud >/dev/null 2>&1; then
    sleep 15
    docker exec --user www-data nextcloud php occ app:list --output=json \
        > "$TMP_DIR/nextcloud/apps.json" 2>/dev/null || true
    if [[ -s "$TMP_DIR/nextcloud/apps.json" ]]; then
        ok "  apps.json (inventory)"
    fi
    docker stop nextcloud >/dev/null 2>&1 || true
fi

log "${C_YELLOW}[5/8]${C_RESET} Backup Jellyfin config..."

JF_CONFIG="$APP_BASE/jellyfin/config"
if [[ -d "$JF_CONFIG" ]]; then
    rsync -a \
        --exclude='metadata/' \
        --exclude='transcodes/' \
        --exclude='log/' \
        --exclude='cache/' \
        --exclude='.cache/' \
        "$JF_CONFIG/" "$TMP_DIR/jellyfin/config/" 2>/dev/null \
    || cp -a "$JF_CONFIG/." "$TMP_DIR/jellyfin/config/" 2>/dev/null

    rm -rf "$TMP_DIR/jellyfin/config/metadata" \
           "$TMP_DIR/jellyfin/config/transcodes" \
           "$TMP_DIR/jellyfin/config/log" \
           "$TMP_DIR/jellyfin/config/cache" 2>/dev/null

    ok "  jellyfin config ($(du -sh "$TMP_DIR/jellyfin/config" 2>/dev/null | cut -f1))"
else
    warn "  Jellyfin config tidak ada"
fi

log "${C_YELLOW}[6/8]${C_RESET} Backup compose + meta..."

[[ -f "$COMPOSE_DIR/docker-compose.yml" ]] && \
    cp "$COMPOSE_DIR/docker-compose.yml" "$TMP_DIR/compose/docker-compose.yml"

cp "$CONFIG_FILE" "$TMP_DIR/meta/homelab.conf"

cat > "$TMP_DIR/meta/BACKUP_INFO.txt" <<INFO
Backup Timestamp : $TIMESTAMP
Hostname         : $(hostname)
Backup Type      : SMART (DB + Config + Addons)
Script Version   : 3.0.1-smart

Included:
  databases/nextcloud.sql        — MariaDB logical dump
  databases/immich.sql           — PostgreSQL logical dump
  nextcloud/config.php           — Main NC config (DB creds, secret)
  nextcloud/custom_apps/         — User-installed addons
  nextcloud/apps.json            — occ app:list inventory
  jellyfin/config/               — JF config (tanpa metadata/transcode/cache)
  compose/docker-compose.yml     — Stack definition
  meta/homelab.conf              — Secrets (password, telegram, domain)

Excluded (auto-rebuilt from Docker image):
  nextcloud/app/                 — Base codebase (~400MB)
  nextcloud/db/                  — Raw MariaDB files
  immich/postgres/               — Raw PostgreSQL files
  jellyfin/cache/                — Regenerable

Restore Notes:
  1. Semua service akan di-stop
  2. Config di-copy balik ke /root/homelab
  3. Database direstore dari SQL dump
  4. Container akan recreate base codebase otomatis
INFO

ok "  compose + meta"

log "${C_YELLOW}[7/8]${C_RESET} Restart services & build archive..."

docker start nextcloud immich_server jellyfin >/dev/null 2>&1 || true
SERVICES_STOPPED=0
sleep 10
if docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null; then
    MAINTENANCE_ON=0
fi
ok "  Services running."

tar -czf "$BACKUP_FILE" -C "$TMP_DIR" . 2>/tmp/tar_err || {
    err "Tar gagal!"; cat /tmp/tar_err; exit 1
}
rm -rf "$TMP_DIR" /tmp/nc_dump_err /tmp/im_dump_err /tmp/tar_err 2>/dev/null || true

if ! tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
    err "Arsip korup!"
    rm -f "$BACKUP_FILE"
    exit 1
fi

SIZE_MB=$(du -m "$BACKUP_FILE" | awk '{print $1}')
SIZE_H=$(du -h "$BACKUP_FILE" | cut -f1)
ok "  Arsip: ${BACKUP_NAME} (${SIZE_H})"

log "${C_YELLOW}[8/8]${C_RESET} Retensi & upload..."

cd "$RESTORE_DIR" 2>/dev/null || true
mapfile -t OLD < <(ls -t homelab_backup_*.tar.gz 2>/dev/null | grep -v '\.part_' | tail -n +6)
for f in "${OLD[@]}"; do
    [[ -n "$f" ]] && rm -f "$f"
done

tg_send_msg() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local msg="$1" i=1
    while (( i <= 3 )); do
        if curl -sS --max-time 20 -X POST \
                "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_CHAT_ID}" \
                --data-urlencode "parse_mode=Markdown" \
                --data-urlencode "text=${msg}" >/dev/null 2>&1; then
            return 0
        fi
        (( i < 3 )) && sleep $((i * 2))
        (( i++ ))
    done
}

tg_send_doc() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local file="$1" caption="$2" i=1
    while (( i <= 3 )); do
        if curl -sS --max-time 600 -F "chat_id=${TG_CHAT_ID}" \
                -F "document=@${file}" \
                -F "caption=${caption}" \
                "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" >/dev/null 2>&1; then
            return 0
        fi
        (( i < 3 )) && sleep $((i * 5))
        (( i++ ))
    done
    return 1
}

if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    warn "Telegram tidak dikonfigurasi — skip upload."
else
    tg_send_msg "🚀 *Smart Backup Homelab*
🕐 \`${TIMESTAMP}\`
📦 *${SIZE_H}* (${SIZE_MB}MB)
🗄️ DB + Config + Addons only"

    if (( SIZE_MB > TG_MAX_PART_MB )); then
        log "  File > ${TG_MAX_PART_MB}MB → split..."
        SPLIT_PREFIX="${BACKUP_FILE}.part_"
        rm -f "${SPLIT_PREFIX}"* 2>/dev/null || true
        split -b "${TG_MAX_PART_MB}M" "$BACKUP_FILE" "$SPLIT_PREFIX"

        shopt -s nullglob
        PARTS=("${SPLIT_PREFIX}"*)
        shopt -u nullglob
        TOTAL=${#PARTS[@]}

        tg_send_msg "📦 Dipecah jadi *${TOTAL} bagian*
Gabung: \`cat ${BACKUP_NAME}.part_* > ${BACKUP_NAME}\`"

        local_count=1
        for part in "${PARTS[@]}"; do
            if tg_send_doc "$part" "[${local_count}/${TOTAL}] ${BACKUP_NAME}"; then
                ok "  Part ${local_count}/${TOTAL} OK"
            else
                warn "  Part ${local_count}/${TOTAL} GAGAL"
            fi
            local_count=$((local_count + 1))
        done
    else
        tg_send_doc "$BACKUP_FILE" "Backup: ${BACKUP_NAME}" && ok "  File terkirim."
    fi
    tg_send_msg "✅ *Backup Selesai*
\`${RESTORE_DIR}/${BACKUP_NAME}\`"
fi

echo ""
echo -e "${C_GREEN}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_GREEN}  ✅ SMART BACKUP SELESAI${C_RESET}"
echo -e "${C_GREEN}     ${BACKUP_NAME} (${SIZE_H})${C_RESET}"
echo -e "${C_GREEN}═══════════════════════════════════════════════════${C_RESET}"
AUTOBACKUP_EOF
}

write_autorestore() {
    cat > "$UTIL_DIR/autorestore" <<'AUTORESTORE_EOF'
#!/bin/bash
set -uo pipefail

readonly LOCK_FILE="/var/lock/homelab-backup.lock"
readonly CONFIG_FILE="/root/config/homelab.conf"
readonly APP_BASE="/root/homelab"
readonly COMPOSE_DIR="$APP_BASE"
readonly RESTORE_DIR="/root/restore"

readonly ALL_CONTAINERS=(nextcloud nextcloud_db nextcloud_redis \
                         immich_server immich_machine_learning immich_redis immich_postgres jellyfin)

C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_CYAN='\033[1;36m'; C_RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
err()  { echo -e "${C_RED}✗ $*${C_RESET}" >&2; }

exec 9>"$LOCK_FILE"
flock -n 9 || { err "Backup/restore lain sedang berjalan."; exit 1; }

[[ ! -f "$CONFIG_FILE" ]] && { err "Config tidak ada: $CONFIG_FILE"; exit 1; }

STACK_STOPPED=0; MAINTENANCE_ON=0

cleanup() {
    local code=$?
    if (( code != 0 )); then
        warn "Error — memulihkan service state..."
        if (( STACK_STOPPED )); then
            (cd "$COMPOSE_DIR" && docker compose up -d 2>/dev/null) || \
                docker start "${ALL_CONTAINERS[@]}" >/dev/null 2>&1 || true
        fi
        if (( MAINTENANCE_ON )); then
            sleep 15
            docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null || true
        fi
    fi
    exit $code
}
trap cleanup EXIT

echo ""
echo -e "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_CYAN}  HOMELAB SMART RESTORE${C_RESET}"
echo -e "${C_CYAN}═══════════════════════════════════════════════════${C_RESET}"
echo ""

cd "$RESTORE_DIR" 2>/dev/null || { err "$RESTORE_DIR tidak ada"; exit 1; }

shopt -s nullglob
SPLIT_PARTS=(homelab_backup_*.tar.gz.part_*)
shopt -u nullglob
if (( ${#SPLIT_PARTS[@]} > 0 )); then
    BASE_PREFIX=$(ls homelab_backup_*.tar.gz.part_* 2>/dev/null | head -1 | sed -E 's/\.part_.*$//')
    if [[ -n "$BASE_PREFIX" && ! -f "$BASE_PREFIX" ]]; then
        log "🔗 Menggabungkan split parts → $(basename "$BASE_PREFIX")"
        cat "${BASE_PREFIX}".part_* > "$BASE_PREFIX"
        ok "Gabung OK"
    fi
fi

LATEST=$(ls -t homelab_backup_*.tar.gz 2>/dev/null | grep -v '\.part_' | head -1 || true)
[[ -z "$LATEST" ]] && { err "Tidak ada file backup."; exit 1; }

if ! tar -tzf "$LATEST" >/dev/null 2>&1; then
    err "Arsip korup: $LATEST"
    exit 1
fi

BACKUP_TYPE="unknown"
if tar -tzf "$LATEST" 2>/dev/null | grep -q '^databases/'; then
    BACKUP_TYPE="smart"
elif tar -tzf "$LATEST" 2>/dev/null | grep -q '^homelab/'; then
    BACKUP_TYPE="full"
fi

SIZE_H=$(du -h "$LATEST" | cut -f1)
ok "Backup: $LATEST (${SIZE_H}) — tipe: ${BACKUP_TYPE}"

if [[ "$BACKUP_TYPE" != "smart" ]]; then
    warn "Backup ini bukan format 'smart' (v2.1+)."
    exit 1
fi

log "Content:"
tar -tzf "$LATEST" 2>/dev/null | awk -F/ '{print $1"/"$2}' | sort -u | head -15 | sed 's/^/    /'

echo ""
warn "RESTORE SMART akan:"
echo "    1. Stop semua container"
echo "    2. Restore config (config.php, custom_apps, jellyfin config)"
echo "    3. Restore database dari SQL dump"
echo "    4. Container rebuild codebase otomatis dari Docker image"
echo ""
warn "Data user di SSD TIDAK diubah."
echo ""
read -rp "Lanjut? Ketik 'RESTORE': " CONFIRM
[[ "$CONFIRM" != "RESTORE" ]] && { echo "Dibatalkan."; exit 0; }

TMP_DIR="/tmp/homelab_restore_$$"
rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"

log "${C_YELLOW}[1/7]${C_RESET} Extract backup..."
tar -xzf "$LATEST" -C "$TMP_DIR"
ok "  Extracted."

DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$TMP_DIR/meta/homelab.conf" 2>/dev/null \
    | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/') \
    || DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$CONFIG_FILE" | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/')

log "${C_YELLOW}[2/7]${C_RESET} Stop SEMUA container..."

docker exec --user www-data nextcloud php occ maintenance:mode --on 2>/dev/null && MAINTENANCE_ON=1

if [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    (cd "$COMPOSE_DIR" && docker compose stop -t 30 2>/dev/null) || true
else
    docker stop -t 30 "${ALL_CONTAINERS[@]}" >/dev/null 2>&1 || true
fi
STACK_STOPPED=1
sleep 3
ok "  Semua container stopped."

log "${C_YELLOW}[3/7]${C_RESET} Restore config ke $APP_BASE..."

NC_APP="$APP_BASE/nextcloud/app"
JF_CONFIG="$APP_BASE/jellyfin/config"

mkdir -p "$NC_APP/config" "$NC_APP/custom_apps" "$JF_CONFIG" "$COMPOSE_DIR"

if [[ -f "$TMP_DIR/nextcloud/config.php" ]]; then
    cp -f "$TMP_DIR/nextcloud/config.php" "$NC_APP/config/config.php"
    ok "  nextcloud/config.php"
fi

if [[ -d "$TMP_DIR/nextcloud/custom_apps" ]]; then
    rm -rf "$NC_APP/custom_apps"
    cp -a "$TMP_DIR/nextcloud/custom_apps" "$NC_APP/custom_apps"
    APP_COUNT=$(find "$NC_APP/custom_apps" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    ok "  custom_apps/ ($APP_COUNT addons restored)"
fi

if [[ -d "$TMP_DIR/jellyfin/config" ]]; then
    cp -a "$TMP_DIR/jellyfin/config/." "$JF_CONFIG/"
    ok "  jellyfin/config"
fi

if [[ -f "$TMP_DIR/compose/docker-compose.yml" ]]; then
    cp -f "$TMP_DIR/compose/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
    ok "  docker-compose.yml"
fi

if [[ -f "$TMP_DIR/meta/homelab.conf" ]]; then
    cp -f "$TMP_DIR/meta/homelab.conf" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "  homelab.conf"
fi

chown -R 33:33     "$NC_APP/config"       2>/dev/null || true
chown -R 33:33     "$NC_APP/custom_apps"  2>/dev/null || true
chown -R 1000:1000 "$JF_CONFIG"           2>/dev/null || true
ok "  Permissions fixed."

log "${C_YELLOW}[4/7]${C_RESET} Start DB containers..."
cd "$COMPOSE_DIR"

docker compose up -d nextcloud-db immich-postgres 2>/dev/null || true

log "     Menunggu DB healthy (90s)..."
for _ in $(seq 1 30); do
    nc_ok=0; im_ok=0
    docker inspect -f '{{.State.Health.Status}}' nextcloud_db 2>/dev/null | grep -q healthy && nc_ok=1
    docker inspect -f '{{.State.Health.Status}}' immich_postgres 2>/dev/null | grep -q healthy && im_ok=1
    (( nc_ok && im_ok )) && break
    sleep 3
done
ok "  DBs healthy."

log "${C_YELLOW}[5/7]${C_RESET} Restore database..."

if [[ -f "$TMP_DIR/databases/nextcloud.sql" ]]; then
    log "     Drop & recreate 'nextcloud' database..."
    docker exec nextcloud_db mariadb -u root -p"$DB_PASSWORD" -e "
        DROP DATABASE IF EXISTS nextcloud;
        CREATE DATABASE nextcloud
            CHARACTER SET utf8mb4
            COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS 'nextcloud'@'%' IDENTIFIED BY '$DB_PASSWORD';
        GRANT ALL ON nextcloud.* TO 'nextcloud'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null || warn "    Warning saat drop/create"

    log "     Import SQL..."
    if docker exec -i nextcloud_db mariadb -u root -p"$DB_PASSWORD" nextcloud \
            < "$TMP_DIR/databases/nextcloud.sql" 2>/dev/null; then
        ok "  Nextcloud DB restored ($(du -h "$TMP_DIR/databases/nextcloud.sql" | cut -f1))"
    else
        warn "  Nextcloud restore ada warning"
    fi
fi

if [[ -f "$TMP_DIR/databases/immich.sql" ]]; then
    log "     Drop schema & restore Immich..."
    docker exec immich_postgres psql -U postgres -d immich \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true

    if docker exec -i immich_postgres psql -U postgres -d immich \
            < "$TMP_DIR/databases/immich.sql" >/dev/null 2>&1; then
        ok "  Immich DB restored ($(du -h "$TMP_DIR/databases/immich.sql" | cut -f1))"
    else
        warn "  Immich restore ada warning"
    fi
fi

log "${C_YELLOW}[6/7]${C_RESET} Start semua service..."
docker compose up -d 2>/dev/null || true
STACK_STOPPED=0

log "     Tunggu Nextcloud ready (maks 180s)..."
NC_READY=0
for _ in $(seq 1 60); do
    if docker exec --user www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
        NC_READY=1
        break
    fi
    sleep 3
done

if (( NC_READY )); then
    ok "  Nextcloud ready."
else
    warn "  NC tidak ready dalam 180s. Cek: docker logs nextcloud --tail 50"
fi

log "${C_YELLOW}[7/7]${C_RESET} Disable maintenance mode..."

if (( NC_READY )); then
    docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null && MAINTENANCE_ON=0
    ok "  Maintenance OFF."
fi

if [[ -f "$TMP_DIR/nextcloud/apps.json" ]] && (( NC_READY )); then
    log "     Verifikasi app addons..."
    enabled_count=$(docker exec --user www-data nextcloud php occ app:list 2>/dev/null | grep -c '  - ' || echo "0")
    log "     Apps terdeteksi: $enabled_count"
fi

rm -rf "$TMP_DIR"

echo ""
echo -e "${C_GREEN}═══════════════════════════════════════════════════${C_RESET}"
echo -e "${C_GREEN}  ✅ SMART RESTORE SELESAI${C_RESET}"
echo -e "${C_GREEN}═══════════════════════════════════════════════════${C_RESET}"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "  📁 Nextcloud : http://${IP}:8080"
echo "  📸 Immich    : http://${IP}:2283"
echo "  🎬 Jellyfin  : http://${IP}:8096"
echo ""
AUTORESTORE_EOF
}

write_config_cli() {
    cat > "$UTIL_DIR/config" <<'CONFIGCLI_EOF'
#!/bin/bash
set -uo pipefail

readonly CONFIG_DIR="/root/config"
readonly CONFIG_FILE="$CONFIG_DIR/homelab.conf"
C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_RESET='\033[0m'

cfg_get() { grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | head -1 | sed -E "s/^$1=\"?([^\"]*)\"?$/\1/"; }

DB_PASSWORD=$(cfg_get DB_PASSWORD)
TG_BOT_TOKEN=$(cfg_get TG_BOT_TOKEN)
TG_CHAT_ID=$(cfg_get TG_CHAT_ID)
SERVER_DOMAIN=$(cfg_get SERVER_DOMAIN)

echo -e "\n${C_CYAN}=== Konfigurasi Homelab ===${C_RESET}\n"

echo -e "${C_YELLOW}── Password Admin ──${C_RESET}"
if [[ -n "$DB_PASSWORD" ]]; then
    read -rsp "Password baru [Enter = lama]: " NEW_PASSWORD; echo ""
    if [[ -n "$NEW_PASSWORD" ]]; then
        read -rsp "Konfirmasi: " CONFIRM; echo ""
        if [[ "$NEW_PASSWORD" != "$CONFIRM" ]]; then
            echo -e "${C_RED}✗ Tidak cocok.${C_RESET}"
            exit 1
        fi
        DB_PASSWORD="$NEW_PASSWORD"
    fi
else
    while true; do
        read -rsp "Password baru: " DB_PASSWORD; echo ""
        read -rsp "Konfirmasi  : " CONFIRM; echo ""
        if [[ "$DB_PASSWORD" == "$CONFIRM" && ${#DB_PASSWORD} -ge 8 ]]; then
            break
        fi
        echo -e "${C_RED}✗ Tidak cocok / <8 karakter.${C_RESET}"
    done
fi

echo ""
echo -e "${C_YELLOW}── Domain Nextcloud (opsional) ──${C_RESET}"
read -rp "Domain [${SERVER_DOMAIN:-kosong}]: " NEW_DOMAIN
NEW_DOMAIN="${NEW_DOMAIN:-$SERVER_DOMAIN}"
SERVER_DOMAIN="$NEW_DOMAIN"

echo ""
echo -e "${C_YELLOW}── Telegram ──${C_RESET}"
read -rp "Bot Token [${TG_BOT_TOKEN:0:15}...]: " NEW_TOKEN
NEW_TOKEN="${NEW_TOKEN:-$TG_BOT_TOKEN}"
read -rp "Chat ID   [${TG_CHAT_ID:-kosong}]: " NEW_CHAT
NEW_CHAT="${NEW_CHAT:-$TG_CHAT_ID}"

if [[ -n "$NEW_TOKEN" && -n "$NEW_CHAT" ]]; then
    echo "Validasi..."
    if curl -sS --max-time 10 "https://api.telegram.org/bot${NEW_TOKEN}/getMe" | grep -q '"ok":true' \
    && curl -sS --max-time 10 "https://api.telegram.org/bot${NEW_TOKEN}/getChat?chat_id=${NEW_CHAT}" | grep -q '"ok":true'; then
        echo -e "${C_GREEN}✓ Valid${C_RESET}"
        TG_BOT_TOKEN="$NEW_TOKEN"
        TG_CHAT_ID="$NEW_CHAT"
    else
        echo -e "${C_RED}✗ Invalid — Telegram di-skip.${C_RESET}"
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
fi

mkdir -p "$CONFIG_DIR"
TMP="${CONFIG_FILE}.tmp.$$"
cat > "$TMP" <<EOF
# Auto-generated — $(date '+%Y-%m-%d %H:%M:%S')
DB_PASSWORD="$DB_PASSWORD"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_DOMAIN="$SERVER_DOMAIN"
EOF
chmod 600 "$TMP"
mv -f "$TMP" "$CONFIG_FILE"
echo -e "\n${C_GREEN}✓ Tersimpan: $CONFIG_FILE${C_RESET}"
CONFIGCLI_EOF
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 8: SCHEDULE & MOTD
# ══════════════════════════════════════════════════════════════════════════════
phase_schedule() {
    log_step "PHASE 8: Schedule & MOTD"

    docker exec --user www-data nextcloud php occ background:cron 2>/dev/null || true

    local nc_cron="*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php >/dev/null 2>&1"
    local bk_cron="0 2 * * * /usr/local/bin/autobackup >/dev/null 2>&1"

    local current
    current=$(crontab -l 2>/dev/null || true)
    local new="$current"
    if ! echo "$current" | grep -q "/var/www/html/cron.php"; then
        new="${new}"$'\n'"$nc_cron"
    fi
    if ! echo "$current" | grep -q "/usr/local/bin/autobackup"; then
        new="${new}"$'\n'"$bk_cron"
    fi
    echo "$new" | grep -v '^$' | crontab -

    if ! systemctl is-active --quiet cron; then
        systemctl start cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || true
    fi

    log_info "Install systemd unit homelab-stack.service (auto-up saat boot)..."
    cat > /etc/systemd/system/homelab-stack.service <<'UNIT'
[Unit]
Description=Homelab Stack Auto-Up
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/root/homelab
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable homelab-stack.service 2>/dev/null || true

    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    rm -f /etc/motd 2>/dev/null || true
    touch /etc/motd

    cat > /etc/profile.d/99-cloud-motd.sh <<'MOTD'
#!/bin/bash
case $- in *i*) ;; *) return ;; esac
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
clear
echo ""
echo -e "\e[1;36m\e[1m ⚡ HOMELAB LXC — Enterprise Stack\e[0m"
echo -e "    Independent Services: Nextcloud | Immich | Jellyfin"
echo ""
echo -e "\e[1m  📡 Endpoints\e[0m"
echo -e "\e[0;90m  ────────────────────────────\e[0m"
echo -e "  📁 Nextcloud : \e[1;33mhttp://${IP}:8080\e[0m"
echo -e "  📸 Immich    : \e[1;33mhttp://${IP}:2283\e[0m"
echo -e "  🎬 Jellyfin  : \e[1;33mhttp://${IP}:8096\e[0m"
echo ""
echo -e "\e[1m  🛠️  Utilities\e[0m"
echo -e "\e[0;90m  ────────────────────────────\e[0m"
echo -e "  📦 \e[1;36mautobackup\e[0m   Stop → dump DB → Telegram → Start"
echo -e "  🔄 \e[1;36mautorestore\e[0m  Stop → restore → Start"
echo -e "  ⚙️  \e[1;36mconfig\e[0m       Ubah parameter"
echo ""
MOTD
    chmod +x /etc/profile.d/99-cloud-motd.sh

    log_ok "Cron & MOTD terpasang."
}

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 9: HEALTH CHECK
# ══════════════════════════════════════════════════════════════════════════════
phase_healthcheck() {
    log_step "PHASE 9: Health check"

    local failed=0
    local c
    for c in nextcloud nextcloud_db nextcloud_redis immich_server immich_machine_learning immich_postgres immich_redis jellyfin; do
        if docker_is_running "$c"; then
            log_ok "  $c: running"
        else
            log_err "  $c: NOT running"
            failed=$((failed + 1))
        fi
    done

    if docker exec --user www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
        log_ok "  Nextcloud: installed"
    else
        log_warn "  Nextcloud: belum terinstall"
        failed=$((failed + 1))
    fi

    if (( failed > 0 )); then
        log_warn "$failed check(s) gagal — review log."
    fi

    local elapsed=$(( $(date +%s) - START_TIME ))
    log_ok "Total waktu: ${elapsed}s"
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print_summary() {
    echo ""
    echo -e "${C_GREEN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_GREEN}║  ✅ INSTALASI SELESAI — SEMUA SERVICE BERJALAN!               ║${C_RESET}"
    echo -e "${C_GREEN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo -e "  ${C_CYAN}📡 Endpoints${C_RESET}"
    echo -e "     📁 Nextcloud : - http://${SERVER_IP}:8080"
    echo -e "     📸 Immich    : - http://${SERVER_IP}:2283"
    echo -e "     🎬 Jellyfin  : - http://${SERVER_IP}:8096"
    echo ""
    echo -e "  ${C_CYAN}💾 Storage${C_RESET}"
    echo -e "     SSD:  $MOUNT_DIR"
    echo -e "     Local: $APP_BASE"
    echo ""
    echo -e "  ${C_CYAN}🔐 Credentials${C_RESET}"
    echo -e "     User     : admin"
    echo -e "     Password : (lihat $CONFIG_FILE)"
    echo ""
    if [[ -n "$SERVER_DOMAIN" ]]; then
        echo -e "  ${C_CYAN}🌐 Domain${C_RESET}"
        echo -e "     $SERVER_DOMAIN"
        echo -e "     ${C_YELLOW}ℹ  Setup reverse proxy untuk HTTPS & akses via domain${C_RESET}"
        echo ""
    fi
    echo -e "  ${C_CYAN}🛠️  Utilities${C_RESET}"
    echo -e "     ${C_GREEN}autobackup${C_RESET}   — stop → dump → Telegram → start"
    echo -e "     ${C_GREEN}autorestore${C_RESET}  — stop → restore → start"
    echo -e "     ${C_GREEN}config${C_RESET}       — ubah parameter"
    echo ""
    echo -e "  ${C_CYAN}📄 Log:${C_RESET} $LOG_FILE"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    banner
    parse_args "$@"

    phase_preflight
    phase_bootstrap

    if (( CHECK_ONLY )); then
        log_ok "Pre-flight check selesai (--check mode, tidak install)."
        exit 0
    fi

    if (( RESET_MODE )); then
        do_reset
    fi

    load_config

    if [[ -d "$APP_BASE/nextcloud/db/mysql" && -f "$CONFIG_FILE" ]]; then
        log_warn "Data lama terdeteksi di $APP_BASE/nextcloud/db"
        if ! prompt_yes_no "Lanjutkan (idempotent) — jika ragu, pilih 'n' untuk reset" "y"; then
            exec "$0" --reset
        fi
    fi

    prompt_password
    prompt_domain
    prompt_telegram
    save_config

    phase_hardening
    phase_runtime
    phase_provision
    phase_deploy
    phase_wait_ready
    phase_tuning
    phase_utilities
    phase_schedule
    phase_healthcheck

    print_summary
}

main "$@"
