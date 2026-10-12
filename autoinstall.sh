#!/bin/bash
# ==============================================================================
# HOMELAB STACK INSTALLER — ENTERPRISE EDITION
# Version: 2.4.0-enterprise
# ==============================================================================
set -euo pipefail

# ── CONSTANTS ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.4.0-enterprise"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/homelab-installer.log"

readonly MOUNT_DIR="/mnt/external_ssd"
readonly DATA_BASE="$MOUNT_DIR/homelab_data"
readonly APP_BASE="/root/homelab"
readonly COMPOSE_DIR="$APP_BASE"
readonly COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
readonly OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
readonly RESTORE_DIR="/root/restore"
readonly CONFIG_DIR="/root/config"
readonly CONFIG_FILE="$CONFIG_DIR/homelab.conf"
readonly MOUNTS_FILE="$CONFIG_DIR/homelab-mounts.conf"
readonly LOCK_FILE="/var/lock/homelab-backup.lock"
readonly UTIL_DIR="/usr/local/bin"

readonly MIN_DISK_GB=5
readonly NC_READY_TIMEOUT=90
readonly DB_READY_TIMEOUT=180
readonly TG_MAX_PART_MB=48

readonly C_RESET='\033[0m'
readonly C_CYAN='\033[1;36m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'
readonly C_GREY='\033[0;90m'

SERVER_IP=""
INPUT_PASSWORD=""
DB_PASSWORD=""
TG_BOT_TOKEN=""
TG_CHAT_ID=""
RESET_MODE=0
CHECK_ONLY=0
TUNING_MODE=0
START_TIME=$(date +%s)

# ── LOGGING ───────────────────────────────────────────────────────────────────
_log() {
    local level="$1" color="$2" msg="$3"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
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
║   HOMELAB STACK INSTALLER  —  ENTERPRISE EDITION             ║
║   Nextcloud  +  Immich  +  Jellyfin                          ║
╚══════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${C_RESET}  Version: ${SCRIPT_VERSION}"
    echo -e "  Log    : ${LOG_FILE}"
    echo ""
}

on_error() {
    local exit_code=$? line_no="${1:-?}"
    log_err "Script gagal di baris $line_no (exit=$exit_code)"
    log_err "Cek log: $LOG_FILE"
    echo ""
    echo -e "${C_YELLOW}[i] Tip reset: $SCRIPT_NAME --reset${C_RESET}"
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ── HELPERS ───────────────────────────────────────────────────────────────────
require_root() {
    [[ "$(id -u)" -eq 0 ]] || { log_err "Harus root."; exit 1; }
}

docker_is_healthy() {
    [[ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo none)" == "healthy" ]]
}

docker_is_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

wait_until() {
    local timeout="$1" interval="$2" desc="$3"; shift 3
    local elapsed=0
    while (( elapsed < timeout )); do
        "$@" >/dev/null 2>&1 && return 0
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log_err "Timeout ${timeout}s: $desc"
    return 1
}

prompt_yes_no() {
    local prompt="$1" default="${2:-n}" ans
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
    else
        read -rp "$prompt [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]]
    fi
}

# ── MOUNT MANAGER ─────────────────────────────────────────────────────────────

mount_list() {
    echo ""
    echo -e "${C_CYAN}═══ MOUNT TERDAFTAR — ${MOUNTS_FILE} ═══${C_RESET}"
    echo ""

    if [[ ! -f "$MOUNTS_FILE" ]] || [[ ! -s "$MOUNTS_FILE" ]]; then
        echo "  (belum ada mount terdaftar)"
        echo ""
        echo -e "  Tambah: ${C_GREEN}sudo $SCRIPT_NAME --mount add${C_RESET}"
        echo ""
        return 0
    fi

    printf "  ${C_YELLOW}%-20s %-14s %-42s %-24s %s${C_RESET}\n" \
        "NAME" "SERVICE" "HOST PATH" "CONTAINER PATH" "MODE"
    printf "  %-20s %-14s %-42s %-24s %s\n" \
        "────────────────────" "──────────────" \
        "──────────────────────────────────────────" \
        "────────────────────────" "────"

    local count=0
    while IFS='|' read -r name service host_path container_path mode; do
        [[ -z "$name" || "$name" =~ ^# ]] && continue
        printf "  %-20s %-14s %-42s %-24s %s\n" \
            "$name" "$service" "$host_path" "$container_path" "$mode"
        count=$((count + 1))
    done < "$MOUNTS_FILE"

    echo ""
    echo -e "  Total: ${C_GREEN}${count}${C_RESET} mount(s)"
    echo ""
    echo -e "  ${C_GREEN}sudo $SCRIPT_NAME --mount add${C_RESET}                # tambah"
    echo -e "  ${C_GREEN}sudo $SCRIPT_NAME --mount delete <name>${C_RESET}      # hapus"
    echo -e "  ${C_GREEN}sudo $SCRIPT_NAME --mount fix-perms [name|all]${C_RESET}  # fix permission"
    echo ""
}

mount_apply_perms() {
    local name="$1" service="$2" host_path="$3" mode="$4" perm_mode="${5:-auto}"

    [[ ! -d "$host_path" ]] && { log_warn "  Folder tidak ada: $host_path"; return 1; }

    local uid gid
    case "$service" in
        nextcloud)     uid=33;   gid=33 ;;
        immich-server) uid=1000; gid=1000 ;;
        jellyfin)      uid=1000; gid=1000 ;;
        *) log_warn "  Service '$service' unknown"; return 1 ;;
    esac

    local perm setgid=0
    if [[ "$perm_mode" == "auto" ]]; then
        if [[ "$mode" == "ro" ]]; then
            perm="755"
        else
            perm="775"; setgid=1
        fi
    else
        perm="$perm_mode"
        [[ "$perm" =~ ^2 ]] && setgid=1
    fi

    log_info "  chown -R ${uid}:${gid} $host_path"
    chown -R "${uid}:${gid}" "$host_path" 2>/dev/null || true

    log_info "  chmod -R $perm $host_path"
    chmod -R "$perm" "$host_path" 2>/dev/null || true

    if (( setgid )); then
        find "$host_path" -type d -exec chmod g+s {} \; 2>/dev/null || true
        log_info "  setgid: ON"
    fi

    local actual
    actual=$(stat -c '%a %U:%G' "$host_path" 2>/dev/null || echo "?")
    log_ok "  Final: $actual"
}

mount_fix_perms() {
    local target="${1:-all}"

    if [[ ! -f "$MOUNTS_FILE" ]] || [[ ! -s "$MOUNTS_FILE" ]]; then
        log_err "Tidak ada mount terdaftar."
        exit 1
    fi

    echo ""
    echo -e "${C_CYAN}═══ FIX PERMISSIONS — target: $target ═══${C_RESET}"
    echo ""

    if [[ "$target" == "all" ]]; then
        local count=0
        while IFS='|' read -r name service host_path container_path mode; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            echo ""
            log_info "▸ [$name] service=$service mode=$mode"
            mount_apply_perms "$name" "$service" "$host_path" "$mode" "auto"
            count=$((count + 1))
        done < "$MOUNTS_FILE"
        echo ""
        log_ok "Total $count mount difix."
    else
        local line
        line=$(grep "^${target}|" "$MOUNTS_FILE" | head -1)
        if [[ -z "$line" ]]; then
            log_err "Mount '$target' tidak ditemukan."
            mount_list
            exit 1
        fi
        IFS='|' read -r name service host_path container_path mode <<< "$line"
        log_info "▸ [$name] service=$service mode=$mode"
        mount_apply_perms "$name" "$service" "$host_path" "$mode" "auto"
        echo ""
        log_ok "Mount '$target' difix."
    fi
}

mount_add() {
    echo ""
    echo -e "${C_CYAN}═══ TAMBAH MOUNT BARU ═══${C_RESET}"
    echo ""

    local name
    read -rp "  Nama mount (unik, no spasi): " name
    [[ -z "$name" ]] && { log_err "Nama kosong."; exit 1; }
    [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]] && { log_err "Nama: huruf/angka/_/-"; exit 1; }
    if [[ -f "$MOUNTS_FILE" ]] && grep -q "^${name}|" "$MOUNTS_FILE"; then
        log_err "Nama '$name' sudah dipakai."; exit 1
    fi

    local service svc_choice
    echo ""
    echo "  Service:"
    echo "    1) nextcloud"
    echo "    2) immich-server"
    echo "    3) jellyfin"
    echo ""
    read -rp "  Pilih [1/2/3]: " svc_choice
    case "$svc_choice" in
        1) service="nextcloud" ;;
        2) service="immich-server" ;;
        3) service="jellyfin" ;;
        *) log_err "Pilihan invalid."; exit 1 ;;
    esac

    local host_path
    echo ""
    read -rp "  Host path: " host_path
    [[ -z "$host_path" ]] && { log_err "Kosong."; exit 1; }
    [[ ! "$host_path" =~ ^/ ]] && { log_err "Harus absolute."; exit 1; }

    echo ""
    echo "  Container path — rekomendasi:"
    case "$service" in
        nextcloud)     echo "    /mnt/shared  atau /mnt/shared/family" ;;
        immich-server) echo "    /mnt/nc-photos  /mnt/family-photos" ;;
        jellyfin)      echo "    /media/movies  /media/music" ;;
    esac
    echo ""
    local container_path
    read -rp "  Container path: " container_path
    [[ -z "$container_path" ]] && { log_err "Kosong."; exit 1; }

    if [[ "$service" == "nextcloud" ]] && {
       [[ "$container_path" == "/var/www/html/data" ]] || \
       [[ "$container_path" =~ ^/var/www/html/data/ ]] || \
       [[ "$container_path" == "/var/www/html" ]]; }; then
        log_err "❌ DILARANG /var/www/html/data* — BLOCKER NC install"
        log_err "   Pakai /mnt/shared → enable External Storage di UI"
        exit 1
    fi

    local mode
    echo ""
    read -rp "  Mode [ro/rw] (default ro): " mode
    mode="${mode:-ro}"
    [[ ! "$mode" =~ ^(ro|rw)$ ]] && { log_err "Mode: ro/rw"; exit 1; }

    echo ""
    echo "  Permission mode:"
    echo "    1) Auto (ro→755, rw→2775) [default]"
    echo "    2) 755   3) 775   4) 2775   5) 700   6) Custom"
    echo ""
    read -rp "  Pilih [1-6]: " perm_choice
    perm_choice="${perm_choice:-1}"

    local perm_mode
    case "$perm_choice" in
        1) perm_mode="auto" ;;
        2) perm_mode="755" ;;
        3) perm_mode="775" ;;
        4) perm_mode="2775" ;;
        5) perm_mode="700" ;;
        6) read -rp "  Custom perm (mis. 750): " perm_mode
           [[ ! "$perm_mode" =~ ^[0-7]{3,4}$ ]] && { log_err "Invalid."; exit 1; } ;;
        *) perm_mode="auto" ;;
    esac

    echo ""
    log_info "Membuat folder: $host_path"
    mkdir -p "$host_path"
    mount_apply_perms "$name" "$service" "$host_path" "$mode" "$perm_mode"

    mkdir -p "$CONFIG_DIR"
    echo "${name}|${service}|${host_path}|${container_path}|${mode}" >> "$MOUNTS_FILE"
    log_ok "Mount '$name' disimpan."

    mount_apply "$service"
}

mount_delete() {
    local name="$1"
    [[ -z "$name" ]] && { echo "Usage: --mount delete <name>"; exit 1; }

    if [[ ! -f "$MOUNTS_FILE" ]] || ! grep -q "^${name}|" "$MOUNTS_FILE"; then
        log_err "Mount '$name' tidak ditemukan."
        mount_list
        exit 1
    fi

    local service
    service=$(grep "^${name}|" "$MOUNTS_FILE" | head -1 | cut -d'|' -f2)

    echo ""
    echo -e "${C_YELLOW}Hapus mount '${name}':${C_RESET}"
    grep "^${name}|" "$MOUNTS_FILE" | while IFS='|' read -r n s h c m; do
        echo "  Service: $s | Host: $h | Container: $c | Mode: $m"
    done
    echo ""
    echo -e "${C_YELLOW}⚠  Data di host TIDAK dihapus.${C_RESET}"
    echo ""
    read -rp "  Lanjut? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Dibatalkan."; exit 0; }

    local tmp="${MOUNTS_FILE}.tmp.$$"
    grep -v "^${name}|" "$MOUNTS_FILE" > "$tmp" || true
    mv "$tmp" "$MOUNTS_FILE"
    [[ ! -s "$MOUNTS_FILE" ]] && rm -f "$MOUNTS_FILE"

    log_ok "Mount '$name' dihapus."
    mount_apply "$service"
}

mount_apply() {
    local service="$1"
    mount_regenerate_override

    [[ ! -f "$COMPOSE_FILE" ]] && { log_warn "compose belum ada — skip recreate."; return 0; }
    docker ps --format '{{.Names}}' | grep -q . || { log_warn "Tidak ada container running."; return 0; }

    log_info "Recreate: $service"
    cd "$COMPOSE_DIR"
    docker compose up -d --force-recreate "$service" 2>/dev/null || {
        log_err "Gagal recreate '$service'."; return 1
    }
    log_ok "Service '$service' di-recreate."
}

mount_regenerate_override() {
    if [[ ! -f "$MOUNTS_FILE" ]] || [[ ! -s "$MOUNTS_FILE" ]]; then
        [[ -f "$OVERRIDE_FILE" ]] && { rm -f "$OVERRIDE_FILE"; log_info "Override dihapus."; }
        return 0
    fi

    local out
    out="# Auto-generated by $SCRIPT_NAME — JANGAN edit manual
# Pakai: $SCRIPT_NAME --mount add|delete|list|fix-perms

services:"

    local svc
    for svc in "nextcloud" "immich-server" "jellyfin"; do
        local svc_mounts
        svc_mounts=$(grep "|${svc}|" "$MOUNTS_FILE" 2>/dev/null || true)
        [[ -z "$svc_mounts" ]] && continue

        out+=$'\n'"  ${svc}:"$'\n'"    volumes:"
        while IFS='|' read -r name s host_path container_path mode; do
            [[ "$s" != "$svc" ]] && continue
            out+=$'\n'"      - ${host_path}:${container_path}:${mode}"
        done <<< "$svc_mounts"
    done

    echo "$out" > "$OVERRIDE_FILE"
    log_ok "Override: $OVERRIDE_FILE"
}

# ── CLI ARGS ──────────────────────────────────────────────────────────────────
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --reset|-r)   RESET_MODE=1; shift ;;
            --check|-c)   CHECK_ONLY=1; shift ;;
            --tuning|-t)  TUNING_MODE=1; shift ;;
            --mount)
                shift
                local subcmd="${1:-list}"
                shift || true
                case "$subcmd" in
                    list) mount_list ;;
                    add) mount_add ;;
                    delete|rm|remove) mount_delete "${1:-}" ;;
                    fix-perms|fix) mount_fix_perms "${1:-all}" ;;
                    *) echo "Usage: --mount {list|add|delete <name>|fix-perms [name|all]}"; exit 1 ;;
                esac
                exit 0 ;;
            --help|-h)
                cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

  (tanpa opsi)                Install / re-run (tanpa tuning)
  --reset, -r                 Hapus semua data + install dari nol
  --check, -c                 Pre-flight check saja
  --tuning, -t                Wait ready + tuning Nextcloud

  --mount list                List mount terdaftar
  --mount add                 Tambah mount (auto chmod+chown)
  --mount delete <name>       Hapus mount
  --mount fix-perms [name]    Fix permission mount

  --help, -h                  Bantuan
EOF
                exit 0 ;;
            *) log_warn "Argumen unknown: $1"; shift ;;
        esac
    done
}

# ── PHASE 0: PRE-FLIGHT ───────────────────────────────────────────────────────
phase_preflight() {
    log_step "PHASE 0: Pre-flight"

    require_root
    mkdir -p "$(dirname "$LOG_FILE")"

    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$SERVER_IP" ]] && { log_err "IP tidak terdeteksi."; exit 1; }
    log_ok "IP: $SERVER_IP"

    [[ -f /etc/os-release ]] && { . /etc/os-release; log_ok "OS: ${PRETTY_NAME:-unknown}"; }

    if ! mountpoint -q "$MOUNT_DIR"; then
        log_warn "$MOUNT_DIR bukan mountpoint"
        [[ ! -d "$MOUNT_DIR" ]] && { log_err "$MOUNT_DIR tidak ada."; exit 1; }
        prompt_yes_no "Lanjut pakai $MOUNT_DIR?" "n" || exit 1
    else
        log_ok "SSD mounted: $MOUNT_DIR"
    fi

    local avail
    avail=$(df -BG "$MOUNT_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
    [[ -z "$avail" || "$avail" -lt "$MIN_DISK_GB" ]] && {
        log_err "Disk kurang (butuh ${MIN_DISK_GB}GB, ada ${avail:-0}GB)."
        exit 1
    }
    log_ok "SSD free: ${avail}GB"
}

# ── PHASE 0.5: BOOTSTRAP ──────────────────────────────────────────────────────
phase_bootstrap() {
    log_step "PHASE 0.5: Bootstrap"
    export DEBIAN_FRONTEND=noninteractive

    local need=0 pkg
    for pkg in curl ca-certificates gnupg cron sudo tar coreutils; do
        dpkg -s "$pkg" >/dev/null 2>&1 || { need=1; break; }
    done

    if (( need )); then
        log_info "Install paket minimal..."
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates gnupg cron sudo tar coreutils >/dev/null
    fi

    command -v curl >/dev/null 2>&1 || { log_err "curl tidak ada."; exit 1; }
    log_ok "Bootstrap OK"
}

# ── CONFIG MANAGER ────────────────────────────────────────────────────────────
config_get() {
    local key="$1"
    grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 \
        | sed -E "s/^${key}=\"?([^\"]*)\"?$/\1/" || echo ""
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Load config: $CONFIG_FILE"
        DB_PASSWORD=$(config_get DB_PASSWORD)
        TG_BOT_TOKEN=$(config_get TG_BOT_TOKEN)
        TG_CHAT_ID=$(config_get TG_CHAT_ID)
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
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
    log_ok "Config: $CONFIG_FILE"
}

prompt_password() {
    echo -e "\n${C_CYAN}=== Password Admin (NC + Immich + DB) ===${C_RESET}"
    if [[ -n "$DB_PASSWORD" ]]; then
        read -rsp "Password baru [Enter = lama]: " NEW_PASSWORD; echo ""
        [[ -z "$NEW_PASSWORD" ]] && return 0
        read -rsp "Konfirmasi: " CONFIRM; echo ""
        [[ "$NEW_PASSWORD" != "$CONFIRM" ]] && { log_err "Tidak cocok."; exit 1; }
        INPUT_PASSWORD="$NEW_PASSWORD"
    else
        while true; do
            read -rsp "Password baru: " INPUT_PASSWORD; echo ""
            read -rsp "Konfirmasi  : " CONFIRM; echo ""
            if [[ "$INPUT_PASSWORD" == "$CONFIRM" && ${#INPUT_PASSWORD} -ge 8 ]]; then
                break
            fi
            log_warn "Tidak cocok / <8 char."
        done
    fi
}

prompt_telegram() {
    echo -e "\n${C_YELLOW}=== Telegram (opsional) ===${C_RESET}"
    command -v curl >/dev/null 2>&1 || { log_warn "curl tidak ada."; TG_BOT_TOKEN=""; TG_CHAT_ID=""; return; }

    local nt nc
    read -rp "Bot Token [${TG_BOT_TOKEN:0:15}...]: " nt
    nt="${nt:-$TG_BOT_TOKEN}"
    read -rp "Chat ID   [${TG_CHAT_ID:-kosong}]: " nc
    nc="${nc:-$TG_CHAT_ID}"

    if [[ -z "$nt" || -z "$nc" ]]; then
        log_warn "Telegram dilewati."
        TG_BOT_TOKEN=""; TG_CHAT_ID=""
        return
    fi

    log_info "Validasi Telegram..."
    curl -sS --max-time 10 "https://api.telegram.org/bot${nt}/getMe" 2>/dev/null \
        | grep -q '"ok":true' || { log_err "Bot Token invalid."; TG_BOT_TOKEN=""; TG_CHAT_ID=""; return; }
    curl -sS --max-time 10 "https://api.telegram.org/bot${nt}/getChat?chat_id=${nc}" 2>/dev/null \
        | grep -q '"ok":true' || { log_err "Chat ID invalid."; TG_BOT_TOKEN=""; TG_CHAT_ID=""; return; }

    log_ok "Telegram OK"
    TG_BOT_TOKEN="$nt"; TG_CHAT_ID="$nc"
}

# ── RESET ─────────────────────────────────────────────────────────────────────
do_reset() {
    log_step "RESET MODE"
    echo -e "${C_RED}"
    echo "  ⚠️  Semua data akan DIHAPUS:"
    echo "      • $APP_BASE"
    echo "      • $DATA_BASE"
    echo "      • $CONFIG_DIR"
    echo "      • $RESTORE_DIR"
    echo -e "${C_RESET}"

    read -rp "Ketik 'HAPUS' untuk konfirmasi: " CONFIRM
    [[ "$CONFIRM" != "HAPUS" ]] && { echo "Dibatalkan."; exit 0; }

    log_info "Stop container..."
    [[ -f "$COMPOSE_FILE" ]] && (cd "$COMPOSE_DIR" && docker compose down -v --remove-orphans 2>/dev/null) || true
    docker rm -f nextcloud nextcloud_db nextcloud_redis \
                immich_server immich_redis immich_postgres jellyfin 2>/dev/null || true

    log_info "Hapus direktori..."
    rm -rf "$APP_BASE" "$DATA_BASE" "$CONFIG_DIR" "$RESTORE_DIR"
    rm -rf /tmp/homelab_* 2>/dev/null || true
    log_ok "Reset selesai."
}

# ── PHASE 1: HARDENING ────────────────────────────────────────────────────────
phase_hardening() {
    log_step "PHASE 1: Hardening"

    log_info "SSH config..."
    local sshd=/etc/ssh/sshd_config
    if [[ -f "$sshd" ]]; then
        grep -qE "^#?PermitRootLogin" "$sshd" \
            && sed -i 's/^#\?[[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' "$sshd" \
            || echo "PermitRootLogin yes" >> "$sshd"
        grep -qE "^#?PasswordAuthentication" "$sshd" \
            && sed -i 's/^#\?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd" \
            || echo "PasswordAuthentication yes" >> "$sshd"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi

    log_info "Timezone Asia/Jakarta..."
    ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
    export DEBIAN_FRONTEND=noninteractive
    dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

    log_info "Install fail2ban..."
    apt-get install -y -qq fail2ban >/dev/null
    if command -v fail2ban-client >/dev/null 2>&1; then
        cat > /etc/fail2ban/jail.local <<'F2B'
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 10
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
F2B
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
    fi

    log_ok "Hardening selesai"
}

# ── PHASE 2: RUNTIME ──────────────────────────────────────────────────────────
phase_runtime() {
    log_step "PHASE 2: Docker runtime"

    if ! command -v docker >/dev/null 2>&1; then
        log_info "Install Docker..."
        . /etc/os-release
        local distro="${ID:-debian}"
        [[ "$distro" != "debian" && "$distro" != "ubuntu" ]] && distro="debian"

        install -m 0755 -d /etc/apt/keyrings
        rm -f /etc/apt/keyrings/docker.asc
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local suite="${VERSION_CODENAME}"
        [[ "$distro" == "debian" && "$suite" == "trixie" ]] && suite="bookworm"

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

    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/override.conf <<EOF
[Unit]
RequiresMountsFor=$MOUNT_DIR
After=network-online.target
Wants=network-online.target
EOF
    systemctl daemon-reload

    systemctl enable containerd 2>/dev/null || true
    systemctl enable docker 2>/dev/null || true
    systemctl start containerd 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    log_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
}

# ── PHASE 3: PROVISION ────────────────────────────────────────────────────────
phase_provision() {
    log_step "PHASE 3: Storage provisioning"

    # Layout SSD (user data)
    mkdir -p "$DATA_BASE/nextcloud/data"
    mkdir -p "$DATA_BASE/nextcloud/storage"     # shared folder untuk mount
    mkdir -p "$DATA_BASE/immich/library"
    mkdir -p "$DATA_BASE/jellyfin/media"

    # Layout Local (app/db/config)
    mkdir -p "$APP_BASE/nextcloud/app"
    mkdir -p "$APP_BASE/nextcloud/db"
    mkdir -p "$APP_BASE/immich/postgres"
    mkdir -p "$APP_BASE/jellyfin/config"
    mkdir -p "$APP_BASE/jellyfin/cache"
    mkdir -p "$RESTORE_DIR"

    # Ownership
    chown -R 33:33     "$APP_BASE/nextcloud/app"     2>/dev/null || true
    chown -R 33:33     "$DATA_BASE/nextcloud/data"   2>/dev/null || true
    chown -R 33:33     "$DATA_BASE/nextcloud/storage" 2>/dev/null || true
    chown -R 999:999   "$APP_BASE/nextcloud/db"      2>/dev/null || true
    chown -R 1000:1000 "$DATA_BASE/immich/library"   2>/dev/null || true
    chown -R 1000:1000 "$DATA_BASE/jellyfin/media"   2>/dev/null || true
    chown -R 999:999   "$APP_BASE/immich/postgres"   2>/dev/null || true
    chmod -R 700       "$APP_BASE/immich/postgres"   2>/dev/null || true

    log_ok "Layout:"
    echo -e "    ${C_GREY}SSD:${C_RESET}   $DATA_BASE"
    echo -e "    ${C_GREY}Local:${C_RESET} $APP_BASE"
}

# ── PHASE 4: DEPLOY ───────────────────────────────────────────────────────────
write_compose() {
    mkdir -p "$COMPOSE_DIR"

    local pw_escaped
    pw_escaped=$(printf '%s' "$INPUT_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/$$/g')

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
      NEXTCLOUD_TRUSTED_DOMAINS: "localhost nextcloud 40.40.40.1 192.168.1.0/24"
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PORT: 6379
      PHP_MEMORY_LIMIT: 1G
      PHP_UPLOAD_LIMIT: 10G
      APACHE_BODY_LIMIT: 0
    volumes:
      - /root/homelab/nextcloud/app:/var/www/html
      - /mnt/external_ssd/homelab_data/nextcloud/data:/var/www/html/data
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
      - /mnt/external_ssd/homelab_data/immich/library:/usr/src/app/upload/library
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      immich-redis:
        condition: service_started
      immich-postgres:
        condition: service_healthy

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
      - /mnt/external_ssd/homelab_data/jellyfin/media:/media
EOF

    if grep -qP '\t' "$COMPOSE_FILE" 2>/dev/null; then
        log_err "File $COMPOSE_FILE mengandung TAB!"
        grep -nP '\t' "$COMPOSE_FILE" | head -5
        return 1
    fi
}

validate_compose() {
    log_info "Validasi compose..."
    docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1 || {
        log_err "Compose tidak valid:"
        docker compose -f "$COMPOSE_FILE" config 2>&1 | head -10
        return 1
    }
    log_ok "  Compose valid."
}

cleanup_stale() {
    log_info "Cleanup stale container..."
    [[ -f "$COMPOSE_FILE" ]] && (cd "$COMPOSE_DIR" && docker compose down --remove-orphans 2>/dev/null) || true

    local containers=(nextcloud nextcloud_db nextcloud_redis immich_server immich_redis immich_postgres jellyfin)
    local c
    for c in "${containers[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
            log_warn "  Remove: $c"
            docker rm -f "$c" >/dev/null 2>&1 || true
        fi
    done
}

cleanup_stale_nc_config() {
    local nc_config="$APP_BASE/nextcloud/app/config/config.php"
    [[ ! -f "$nc_config" ]] && return 0

    log_warn "config.php lama terdeteksi — cek DB schema..."

    local db_has_schema=0
    if docker ps --format '{{.Names}}' | grep -qx "nextcloud_db"; then
        docker exec nextcloud_db mariadb -u nextcloud -p"$INPUT_PASSWORD" \
            -e "USE nextcloud; SHOW TABLES LIKE 'oc_%';" 2>/dev/null | grep -q oc_ && db_has_schema=1
    fi

    if (( db_has_schema == 0 )); then
        log_warn "DB kosong — hapus config.php stale"
        rm -f "$nc_config"
        rm -f "$APP_BASE/nextcloud/app/config/CAN_INSTALL"
        rm -rf "$APP_BASE/nextcloud/app/custom_apps"/* 2>/dev/null || true
        rm -rf "$APP_BASE/nextcloud/app/data"/* 2>/dev/null || true
        log_ok "  Dibersihkan."
    else
        log_ok "  DB punya schema — biarkan."
    fi
}

phase_deploy() {
    log_step "PHASE 4: Deploy"

    write_compose
    validate_compose
    cleanup_stale_nc_config
    cleanup_stale

    local nc_db_dir="$APP_BASE/nextcloud/db"
    if [[ -d "$nc_db_dir/mysql" ]] && [[ ! -f "$nc_db_dir/mysql/ibdata1" ]]; then
        log_warn "Volume DB NC rusak — dibersihkan."
        rm -rf "$nc_db_dir"/*
    fi

    mkdir -p "$APP_BASE/nextcloud/db"
    chown -R 999:999 "$APP_BASE/nextcloud/db" 2>/dev/null || true

    log_info "docker compose up -d --force-recreate..."
    cd "$COMPOSE_DIR"
    docker compose up -d --force-recreate --remove-orphans

    log_info "Tunggu DB healthy (maks ${DB_READY_TIMEOUT}s)..."
    wait_until "$DB_READY_TIMEOUT" 5 "nextcloud_db" docker_is_healthy nextcloud_db || return 1
    wait_until "$DB_READY_TIMEOUT" 5 "immich_postgres" docker_is_healthy immich_postgres || return 1

    log_ok "Semua container running."
}

# ── PHASE 5: WAIT READY (hanya --tuning) ──────────────────────────────────────
nc_is_installed() {
    docker exec --user www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true"
}

phase_wait_ready() {
    log_step "PHASE 5: Wait Nextcloud ready (maks ${NC_READY_TIMEOUT}s)"

    local elapsed=0
    local err_pattern='Access denied|SQLSTATE\[|Cannot connect|Connection refused|Error while trying to create admin user|Unhandled exception|Fatal error'

    while (( elapsed < NC_READY_TIMEOUT )); do
        if nc_is_installed; then
            echo ""
            log_ok "Nextcloud ready. (@${elapsed}s)"
            return 0
        fi

        if docker logs nextcloud --tail 100 2>&1 | grep -qiE "$err_pattern"; then
            echo ""
            log_err "FATAL: NC tidak bisa init."
            docker logs nextcloud --tail 100 2>&1 | grep -iE "$err_pattern" | head -5
            log_err "Solusi: $SCRIPT_NAME --reset"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."

        (( elapsed % 30 == 0 )) && { echo ""; log_info "@${elapsed}s"; }
    done

    echo ""
    log_err "TIMEOUT setelah ${NC_READY_TIMEOUT}s."
    docker logs nextcloud --tail 30 2>&1
    return 1
}

# ── PHASE 6: TUNING (hanya --tuning) ──────────────────────────────────────────
phase_tuning() {
    log_step "PHASE 6: Nextcloud tuning"

    log_info "Config cache + region..."
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

    log_info "HSTS..."
    docker exec --user root nextcloud bash -c '
        f=/etc/apache2/sites-available/000-default.conf
        if [[ -f "$f" ]] && ! grep -q "Strict-Transport-Security" "$f"; then
            sed -i "/<VirtualHost \*:80>/a \\    Header always set Strict-Transport-Security \"max-age=15552000; includeSubDomains\"" "$f"
        fi
    ' 2>/dev/null || true
    docker exec --user root nextcloud a2enmod headers 2>/dev/null || true

    log_info "Enable external storage app..."
    docker exec --user www-data nextcloud php occ app:enable files_external 2>/dev/null || true

    log_info "Restart Nextcloud..."
    docker restart nextcloud >/dev/null
    wait_until 90 3 "NC restart" nc_is_installed || true

    log_ok "Tuning selesai."
}

# ── PHASE 7: UTILITIES ────────────────────────────────────────────────────────
phase_utilities() {
    log_step "PHASE 7: Utilities"
    write_autobackup
    write_autorestore
    write_config_cli
    chmod +x "$UTIL_DIR/autobackup" "$UTIL_DIR/autorestore" "$UTIL_DIR/config"
    log_ok "Terpasang: autobackup, autorestore, config"
}

write_autobackup() {
    cat > "$UTIL_DIR/autobackup" <<'AUTOBACKUP_EOF'
#!/bin/bash
set -uo pipefail

readonly LOCK_FILE="/var/lock/homelab-backup.lock"
readonly CONFIG_FILE="/root/config/homelab.conf"
readonly MOUNT_DIR="/mnt/external_ssd"
readonly DATA_BASE="$MOUNT_DIR/homelab_data"
readonly APP_BASE="/root/homelab"
readonly COMPOSE_DIR="$APP_BASE"
readonly RESTORE_DIR="/root/restore"
readonly TG_MAX_PART_MB=48

readonly ALL_CONTAINERS=(nextcloud nextcloud_db nextcloud_redis \
                         immich_server immich_redis immich_postgres jellyfin)

C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_CYAN='\033[1;36m'; C_RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
err()  { echo -e "${C_RED}✗ $*${C_RESET}" >&2; }

exec 9>"$LOCK_FILE"
flock -n 9 || { err "Backup lain berjalan."; exit 1; }

SERVICES_STOPPED=0; MAINTENANCE_ON=0

cleanup() {
    local code=$?
    (( code != 0 )) && warn "Error — memulihkan service..."
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

[[ ! -f "$CONFIG_FILE" ]] && { err "Config tidak ada."; exit 1; }

DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$CONFIG_FILE" | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/')
TG_BOT_TOKEN=$(grep -E '^TG_BOT_TOKEN=' "$CONFIG_FILE" | head -1 | sed -E 's/^TG_BOT_TOKEN="?([^"]*)"?$/\1/')
TG_CHAT_ID=$(grep -E '^TG_CHAT_ID=' "$CONFIG_FILE" | head -1 | sed -E 's/^TG_CHAT_ID="?([^"]*)"?$/\1/')

for c in nextcloud_db immich_postgres; do
    docker ps --format '{{.Names}}' | grep -qx "$c" || { err "$c tidak running."; exit 1; }
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TMP_DIR="/tmp/homelab_backup_${TIMESTAMP}"
BACKUP_NAME="homelab_backup_${TIMESTAMP}.tar.gz"
BACKUP_FILE="${RESTORE_DIR}/${BACKUP_NAME}"

mkdir -p "$TMP_DIR"/{databases,nextcloud,jellyfin,compose,meta} "$RESTORE_DIR"

echo ""
echo -e "${C_CYAN}═══ HOMELAB SMART BACKUP — ${TIMESTAMP} ═══${C_RESET}"
echo ""

log "${C_YELLOW}[1/8]${C_RESET} NC maintenance ON..."
docker exec --user www-data nextcloud php occ maintenance:mode --on 2>/dev/null && MAINTENANCE_ON=1

log "${C_YELLOW}[2/8]${C_RESET} Stop app containers..."
docker stop nextcloud immich_server jellyfin >/dev/null 2>&1 || true
SERVICES_STOPPED=1
sleep 3
ok "  Stopped."

log "${C_YELLOW}[3/8]${C_RESET} Dump DB..."

docker exec nextcloud_db mariadb-dump -u root -p"$DB_PASSWORD" \
    --single-transaction --routines --triggers --events \
    --default-character-set=utf8mb4 \
    nextcloud > "$TMP_DIR/databases/nextcloud.sql" 2>/tmp/nc_dump_err && \
    ok "  nextcloud.sql ($(du -h "$TMP_DIR/databases/nextcloud.sql" | cut -f1))" || {
    err "  Gagal dump NC!"; cat /tmp/nc_dump_err; exit 1; }

docker exec immich_postgres pg_dump -U postgres -d immich \
    > "$TMP_DIR/databases/immich.sql" 2>/tmp/im_dump_err && \
    ok "  immich.sql ($(du -h "$TMP_DIR/databases/immich.sql" | cut -f1))" || {
    err "  Gagal dump Immich!"; cat /tmp/im_dump_err; exit 1; }

log "${C_YELLOW}[4/8]${C_RESET} Backup NC config + custom_apps..."
NC_APP="$APP_BASE/nextcloud/app"

[[ -f "$NC_APP/config/config.php" ]] && {
    cp "$NC_APP/config/config.php" "$TMP_DIR/nextcloud/config.php"
    ok "  config.php"
}

[[ -d "$NC_APP/custom_apps" ]] && {
    cp -a "$NC_APP/custom_apps" "$TMP_DIR/nextcloud/custom_apps" 2>/dev/null || true
    APP_COUNT=$(find "$TMP_DIR/nextcloud/custom_apps" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    ok "  custom_apps/ ($APP_COUNT)"
} || warn "  custom_apps/ tidak ada"

if docker start nextcloud >/dev/null 2>&1; then
    sleep 15
    docker exec --user www-data nextcloud php occ app:list --output=json \
        > "$TMP_DIR/nextcloud/apps.json" 2>/dev/null || true
    docker stop nextcloud >/dev/null 2>&1 || true
fi

log "${C_YELLOW}[5/8]${C_RESET} Backup Jellyfin config..."
JF_CONFIG="$APP_BASE/jellyfin/config"
if [[ -d "$JF_CONFIG" ]]; then
    rsync -a --exclude='metadata/' --exclude='transcodes/' --exclude='log/' \
        --exclude='cache/' --exclude='.cache/' \
        "$JF_CONFIG/" "$TMP_DIR/jellyfin/config/" 2>/dev/null \
    || cp -a "$JF_CONFIG/." "$TMP_DIR/jellyfin/config/" 2>/dev/null
    rm -rf "$TMP_DIR/jellyfin/config/"{metadata,transcodes,log,cache} 2>/dev/null || true
    ok "  jellyfin config"
else
    warn "  Jellyfin config tidak ada"
fi

log "${C_YELLOW}[6/8]${C_RESET} Backup compose + meta..."

[[ -f "$COMPOSE_DIR/docker-compose.yml" ]] && \
    cp "$COMPOSE_DIR/docker-compose.yml" "$TMP_DIR/compose/docker-compose.yml"
[[ -f "$COMPOSE_DIR/docker-compose.override.yml" ]] && \
    cp "$COMPOSE_DIR/docker-compose.override.yml" "$TMP_DIR/compose/docker-compose.override.yml"

cp "$CONFIG_FILE" "$TMP_DIR/meta/homelab.conf"
[[ -f "$CONFIG_DIR/homelab-mounts.conf" ]] && \
    cp "$CONFIG_DIR/homelab-mounts.conf" "$TMP_DIR/meta/homelab-mounts.conf"

cat > "$TMP_DIR/meta/BACKUP_INFO.txt" <<INFO
Backup: $TIMESTAMP
Host: $(hostname)
Type: SMART (DB + Config + Addons)
Script: 2.4.0-smart
INFO
ok "  Meta tersimpan"

log "${C_YELLOW}[7/8]${C_RESET} Restart services & build archive..."
docker start nextcloud immich_server jellyfin >/dev/null 2>&1 || true
SERVICES_STOPPED=0
sleep 10
docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null && MAINTENANCE_ON=0
ok "  Services running"

tar -czf "$BACKUP_FILE" -C "$TMP_DIR" . 2>/tmp/tar_err || {
    err "Tar gagal!"; cat /tmp/tar_err; exit 1; }
rm -rf "$TMP_DIR" /tmp/nc_dump_err /tmp/im_dump_err /tmp/tar_err 2>/dev/null || true

tar -tzf "$BACKUP_FILE" >/dev/null 2>&1 || {
    err "Arsip korup!"; rm -f "$BACKUP_FILE"; exit 1; }

SIZE_MB=$(du -m "$BACKUP_FILE" | awk '{print $1}')
SIZE_H=$(du -h "$BACKUP_FILE" | cut -f1)
ok "  Arsip: ${BACKUP_NAME} (${SIZE_H})"

log "${C_YELLOW}[8/8]${C_RESET} Retensi & Telegram..."

cd "$RESTORE_DIR" 2>/dev/null || true
mapfile -t OLD < <(ls -t homelab_backup_*.tar.gz 2>/dev/null | grep -v '\.part_' | tail -n +6)
for f in "${OLD[@]}"; do [[ -n "$f" ]] && rm -f "$f"; done

tg_send_msg() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local msg="$1" i=1
    while (( i <= 3 )); do
        curl -sS --max-time 20 -X POST \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "parse_mode=Markdown" \
            --data-urlencode "text=${msg}" >/dev/null 2>&1 && return 0
        (( i < 3 )) && sleep $((i * 2))
        (( i++ ))
    done
}

tg_send_doc() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local file="$1" caption="$2" i=1
    while (( i <= 3 )); do
        curl -sS --max-time 600 -F "chat_id=${TG_CHAT_ID}" \
            -F "document=@${file}" -F "caption=${caption}" \
            "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" >/dev/null 2>&1 && return 0
        (( i < 3 )) && sleep $((i * 5))
        (( i++ ))
    done
    return 1
}

if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    warn "Telegram tidak dikonfigurasi."
else
    tg_send_msg "🚀 Backup Homelab
🕐 \`${TIMESTAMP}\`
📦 *${SIZE_H}* (${SIZE_MB}MB)"

    if (( SIZE_MB > TG_MAX_PART_MB )); then
        SPLIT_PREFIX="${BACKUP_FILE}.part_"
        rm -f "${SPLIT_PREFIX}"* 2>/dev/null || true
        split -b "${TG_MAX_PART_MB}M" "$BACKUP_FILE" "$SPLIT_PREFIX"

        shopt -s nullglob
        PARTS=("${SPLIT_PREFIX}"*)
        shopt -u nullglob
        TOTAL=${#PARTS[@]}

        tg_send_msg "📦 Split jadi *${TOTAL} bagian*"
        local_count=1
        for part in "${PARTS[@]}"; do
            tg_send_doc "$part" "[${local_count}/${TOTAL}] ${BACKUP_NAME}" \
                && ok "  Part ${local_count}/${TOTAL} OK" \
                || warn "  Part ${local_count}/${TOTAL} GAGAL"
            local_count=$((local_count + 1))
        done
    else
        tg_send_doc "$BACKUP_FILE" "Backup: ${BACKUP_NAME}" && ok "  Terkirim"
    fi
    tg_send_msg "✅ Selesai"
fi

echo ""
echo -e "${C_GREEN}═══ SMART BACKUP SELESAI ═══${C_RESET}"
echo -e "${C_GREEN}  ${BACKUP_NAME} (${SIZE_H})${C_RESET}"
echo ""
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
readonly CONFIG_DIR="/root/config"

readonly ALL_CONTAINERS=(nextcloud nextcloud_db nextcloud_redis \
                         immich_server immich_redis immich_postgres jellyfin)

C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_CYAN='\033[1;36m'; C_RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
err()  { echo -e "${C_RED}✗ $*${C_RESET}" >&2; }

exec 9>"$LOCK_FILE"
flock -n 9 || { err "Backup/restore lain berjalan."; exit 1; }

[[ ! -f "$CONFIG_FILE" ]] && { err "Config tidak ada."; exit 1; }

STACK_STOPPED=0; MAINTENANCE_ON=0

cleanup() {
    local code=$?
    if (( code != 0 )); then
        warn "Error — memulihkan service..."
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
echo -e "${C_CYAN}═══ HOMELAB SMART RESTORE ═══${C_RESET}"
echo ""

cd "$RESTORE_DIR" 2>/dev/null || { err "$RESTORE_DIR tidak ada."; exit 1; }

shopt -s nullglob
SPLIT_PARTS=(homelab_backup_*.tar.gz.part_*)
shopt -u nullglob
if (( ${#SPLIT_PARTS[@]} > 0 )); then
    BASE_PREFIX=$(ls homelab_backup_*.tar.gz.part_* 2>/dev/null | head -1 | sed -E 's/\.part_.*$//')
    if [[ -n "$BASE_PREFIX" && ! -f "$BASE_PREFIX" ]]; then
        log "🔗 Gabung split parts..."
        cat "${BASE_PREFIX}".part_* > "$BASE_PREFIX"
        ok "OK"
    fi
fi

LATEST=$(ls -t homelab_backup_*.tar.gz 2>/dev/null | grep -v '\.part_' | head -1 || true)
[[ -z "$LATEST" ]] && { err "Tidak ada backup."; exit 1; }

tar -tzf "$LATEST" >/dev/null 2>&1 || { err "Arsip korup."; exit 1; }

BACKUP_TYPE="unknown"
tar -tzf "$LATEST" 2>/dev/null | grep -q '^databases/' && BACKUP_TYPE="smart"
tar -tzf "$LATEST" 2>/dev/null | grep -q '^homelab/' && BACKUP_TYPE="full"

SIZE_H=$(du -h "$LATEST" | cut -f1)
ok "Backup: $LATEST (${SIZE_H}) — tipe: ${BACKUP_TYPE}"

[[ "$BACKUP_TYPE" != "smart" ]] && { err "Bukan format 'smart'."; exit 1; }

echo ""
warn "Restore akan:"
echo "    1. Stop container"
echo "    2. Restore config"
echo "    3. Restore DB dari SQL dump"
echo "    4. Rebuild codebase dari image"
echo ""
warn "User data di \$DATA_BASE TIDAK diubah."
echo ""
read -rp "Lanjut? Ketik 'RESTORE': " CONFIRM
[[ "$CONFIRM" != "RESTORE" ]] && { echo "Dibatalkan."; exit 0; }

TMP_DIR="/tmp/homelab_restore_$$"
rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"

log "${C_YELLOW}[1/7]${C_RESET} Extract..."
tar -xzf "$LATEST" -C "$TMP_DIR"
ok "  OK"

DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$TMP_DIR/meta/homelab.conf" 2>/dev/null \
    | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/') \
    || DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$CONFIG_FILE" | head -1 | sed -E 's/^DB_PASSWORD="?([^"]*)"?$/\1/')

log "${C_YELLOW}[2/7]${C_RESET} Stop containers..."
docker exec --user www-data nextcloud php occ maintenance:mode --on 2>/dev/null && MAINTENANCE_ON=1
if [[ -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    (cd "$COMPOSE_DIR" && docker compose stop -t 30 2>/dev/null) || true
else
    docker stop -t 30 "${ALL_CONTAINERS[@]}" >/dev/null 2>&1 || true
fi
STACK_STOPPED=1
sleep 3
ok "  Stopped"

log "${C_YELLOW}[3/7]${C_RESET} Restore config..."
NC_APP="$APP_BASE/nextcloud/app"
JF_CONFIG="$APP_BASE/jellyfin/config"

mkdir -p "$NC_APP/config" "$NC_APP/custom_apps" "$JF_CONFIG" "$COMPOSE_DIR" "$CONFIG_DIR"

[[ -f "$TMP_DIR/nextcloud/config.php" ]] && {
    cp -f "$TMP_DIR/nextcloud/config.php" "$NC_APP/config/config.php"
    ok "  config.php"
}

[[ -d "$TMP_DIR/nextcloud/custom_apps" ]] && {
    rm -rf "$NC_APP/custom_apps"
    cp -a "$TMP_DIR/nextcloud/custom_apps" "$NC_APP/custom_apps"
    ok "  custom_apps"
}

[[ -d "$TMP_DIR/jellyfin/config" ]] && {
    cp -a "$TMP_DIR/jellyfin/config/." "$JF_CONFIG/"
    ok "  jellyfin config"
}

[[ -f "$TMP_DIR/compose/docker-compose.yml" ]] && {
    cp -f "$TMP_DIR/compose/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
    ok "  docker-compose.yml"
}

[[ -f "$TMP_DIR/compose/docker-compose.override.yml" ]] && {
    cp -f "$TMP_DIR/compose/docker-compose.override.yml" "$COMPOSE_DIR/docker-compose.override.yml"
    ok "  override"
}

[[ -f "$TMP_DIR/meta/homelab.conf" ]] && {
    cp -f "$TMP_DIR/meta/homelab.conf" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "  homelab.conf"
}

[[ -f "$TMP_DIR/meta/homelab-mounts.conf" ]] && {
    cp -f "$TMP_DIR/meta/homelab-mounts.conf" "$CONFIG_DIR/homelab-mounts.conf"
    ok "  homelab-mounts.conf"
}

chown -R 33:33 "$NC_APP/config" 2>/dev/null || true
chown -R 33:33 "$NC_APP/custom_apps" 2>/dev/null || true
chown -R 1000:1000 "$JF_CONFIG" 2>/dev/null || true

log "${C_YELLOW}[4/7]${C_RESET} Start DB..."
cd "$COMPOSE_DIR"
docker compose up -d nextcloud-db immich-postgres 2>/dev/null || true

for _ in $(seq 1 30); do
    nc_ok=0; im_ok=0
    docker inspect -f '{{.State.Health.Status}}' nextcloud_db 2>/dev/null | grep -q healthy && nc_ok=1
    docker inspect -f '{{.State.Health.Status}}' immich_postgres 2>/dev/null | grep -q healthy && im_ok=1
    (( nc_ok && im_ok )) && break
    sleep 3
done
ok "  DBs healthy"

log "${C_YELLOW}[5/7]${C_RESET} Restore DB..."

if [[ -f "$TMP_DIR/databases/nextcloud.sql" ]]; then
    docker exec nextcloud_db mariadb -u root -p"$DB_PASSWORD" -e "
        DROP DATABASE IF EXISTS nextcloud;
        CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
        CREATE USER IF NOT EXISTS 'nextcloud'@'%' IDENTIFIED BY '$DB_PASSWORD';
        GRANT ALL ON nextcloud.* TO 'nextcloud'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null || warn "  Warning drop/create"

    docker exec -i nextcloud_db mariadb -u root -p"$DB_PASSWORD" nextcloud \
        < "$TMP_DIR/databases/nextcloud.sql" 2>/dev/null \
        && ok "  NC DB restored" || warn "  NC restore warning"
fi

if [[ -f "$TMP_DIR/databases/immich.sql" ]]; then
    docker exec immich_postgres psql -U postgres -d immich \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 || true
    docker exec -i immich_postgres psql -U postgres -d immich \
        < "$TMP_DIR/databases/immich.sql" >/dev/null 2>&1 \
        && ok "  Immich DB restored" || warn "  Immich restore warning"
fi

log "${C_YELLOW}[6/7]${C_RESET} Start all..."
docker compose up -d 2>/dev/null || true
STACK_STOPPED=0

NC_READY=0
for _ in $(seq 1 60); do
    docker exec --user www-data nextcloud php occ status 2>/dev/null | grep -q "installed: true" && {
        NC_READY=1; break; }
    sleep 3
done

(( NC_READY )) && ok "  NC ready" || warn "  NC tidak ready 180s"

log "${C_YELLOW}[7/7]${C_RESET} Disable maintenance..."
(( NC_READY )) && {
    docker exec --user www-data nextcloud php occ maintenance:mode --off 2>/dev/null && MAINTENANCE_ON=0
    ok "  OFF"
}

rm -rf "$TMP_DIR"

echo ""
echo -e "${C_GREEN}═══ SMART RESTORE SELESAI ═══${C_RESET}"
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

echo -e "\n${C_CYAN}=== Konfigurasi Homelab ===${C_RESET}\n"

echo -e "${C_YELLOW}── Password Admin ──${C_RESET}"
if [[ -n "$DB_PASSWORD" ]]; then
    read -rsp "Password baru [Enter = lama]: " NEW_PASSWORD; echo ""
    if [[ -n "$NEW_PASSWORD" ]]; then
        read -rsp "Konfirmasi: " CONFIRM; echo ""
        [[ "$NEW_PASSWORD" != "$CONFIRM" ]] && { echo -e "${C_RED}✗ Tidak cocok.${C_RESET}"; exit 1; }
        DB_PASSWORD="$NEW_PASSWORD"
    fi
else
    while true; do
        read -rsp "Password baru: " DB_PASSWORD; echo ""
        read -rsp "Konfirmasi  : " CONFIRM; echo ""
        [[ "$DB_PASSWORD" == "$CONFIRM" && ${#DB_PASSWORD} -ge 8 ]] && break
        echo -e "${C_RED}✗ Tidak cocok / <8.${C_RESET}"
    done
fi

echo ""
echo -e "${C_YELLOW}── Telegram ──${C_RESET}"
read -rp "Bot Token [${TG_BOT_TOKEN:0:15}...]: " NEW_TOKEN
NEW_TOKEN="${NEW_TOKEN:-$TG_BOT_TOKEN}"
read -rp "Chat ID   [${TG_CHAT_ID:-kosong}]: " NEW_CHAT
NEW_CHAT="${NEW_CHAT:-$TG_CHAT_ID}"

if [[ -n "$NEW_TOKEN" && -n "$NEW_CHAT" ]]; then
    if curl -sS --max-time 10 "https://api.telegram.org/bot${NEW_TOKEN}/getMe" | grep -q '"ok":true' \
    && curl -sS --max-time 10 "https://api.telegram.org/bot${NEW_TOKEN}/getChat?chat_id=${NEW_CHAT}" | grep -q '"ok":true'; then
        echo -e "${C_GREEN}✓ Valid${C_RESET}"
        TG_BOT_TOKEN="$NEW_TOKEN"; TG_CHAT_ID="$NEW_CHAT"
    else
        echo -e "${C_RED}✗ Invalid — di-skip.${C_RESET}"
        TG_BOT_TOKEN=""; TG_CHAT_ID=""
    fi
else
    TG_BOT_TOKEN=""; TG_CHAT_ID=""
fi

mkdir -p "$CONFIG_DIR"
TMP="${CONFIG_FILE}.tmp.$$"
cat > "$TMP" <<EOF
# Auto-generated — $(date '+%Y-%m-%d %H:%M:%S')
DB_PASSWORD="$DB_PASSWORD"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
chmod 600 "$TMP"
mv -f "$TMP" "$CONFIG_FILE"
echo -e "\n${C_GREEN}✓ Tersimpan: $CONFIG_FILE${C_RESET}"
CONFIGCLI_EOF
}

# ── PHASE 8: SCHEDULE & MOTD ──────────────────────────────────────────────────
phase_schedule() {
    log_step "PHASE 8: Schedule & MOTD"

    docker exec --user www-data nextcloud php occ background:cron 2>/dev/null || true

    local nc_cron="*/5 * * * * docker exec -u www-data nextcloud php -f /var/www/html/cron.php >/dev/null 2>&1"
    local bk_cron="0 2 * * * /usr/local/bin/autobackup >/dev/null 2>&1"

    local current new
    current=$(crontab -l 2>/dev/null || true)
    new="$current"
    echo "$current" | grep -q "/var/www/html/cron.php" || new="${new}"$'\n'"$nc_cron"
    echo "$current" | grep -q "/usr/local/bin/autobackup" || new="${new}"$'\n'"$bk_cron"
    echo "$new" | grep -v '^$' | crontab -

    systemctl is-active --quiet cron || {
        systemctl start cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || true
    }

    log_info "Install homelab-stack.service..."
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
echo -e "    Split Storage: User Data @ SSD | App/DB @ /root/homelab"
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

    log_ok "Cron & MOTD OK"
}

# ── PHASE 9: HEALTH CHECK ─────────────────────────────────────────────────────
phase_healthcheck() {
    log_step "PHASE 9: Health check"

    local failed=0 c
    for c in nextcloud nextcloud_db nextcloud_redis immich_server immich_postgres immich_redis jellyfin; do
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
        log_warn "  Nextcloud: belum installed"
        failed=$((failed + 1))
    fi

    (( failed > 0 )) && log_warn "$failed check(s) gagal."

    local elapsed=$(( $(date +%s) - START_TIME ))
    log_ok "Total waktu: ${elapsed}s"
}

# ── SUMMARY ───────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${C_GREEN}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_GREEN}║  ✅ INSTALASI SELESAI                                        ║${C_RESET}"
    echo -e "${C_GREEN}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo -e "  ${C_CYAN}📡 Endpoints${C_RESET}"
    echo -e "     📁 Nextcloud : http://${SERVER_IP}:8080"
    echo -e "     📸 Immich    : http://${SERVER_IP}:2283"
    echo -e "     🎬 Jellyfin  : http://${SERVER_IP}:8096"
    echo ""
    echo -e "  ${C_CYAN}💾 Storage${C_RESET}"
    echo -e "     User Data  → $DATA_BASE"
    echo -e "     App/DB/Cfg → $APP_BASE"
    echo ""
    echo -e "  ${C_CYAN}🔐 Credentials${C_RESET}"
    echo -e "     User     : admin"
    echo -e "     Password : (lihat $CONFIG_FILE)"
    echo ""
    echo -e "  ${C_CYAN}🛠️  Utilities${C_RESET}"
    echo -e "     ${C_GREEN}autobackup${C_RESET}    — backup + Telegram"
    echo -e "     ${C_GREEN}autorestore${C_RESET}   — restore dari backup"
    echo -e "     ${C_GREEN}config${C_RESET}        — ubah parameter"
    echo ""
    echo -e "  ${C_CYAN}📄 Log:${C_RESET} $LOG_FILE"
    echo ""
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    banner
    parse_args "$@"

    # TUNING MODE
    if (( TUNING_MODE )); then
        require_root
        load_config

        log_step "TUNING MODE"
        docker ps --format '{{.Names}}' | grep -qx "nextcloud" || {
            log_err "Container nextcloud tidak running."
            exit 1
        }

        phase_wait_ready || {
            log_err "NC belum installed — tuning dibatalkan."
            exit 1
        }
        phase_tuning
        phase_healthcheck

        echo ""
        log_ok "Tuning selesai."
        exit 0
    fi

    # NORMAL MODE
    phase_preflight
    phase_bootstrap

    (( CHECK_ONLY )) && { log_ok "Pre-flight OK (--check)."; exit 0; }

    (( RESET_MODE )) && do_reset

    load_config

    if [[ -d "$APP_BASE/nextcloud/db/mysql" && -f "$CONFIG_FILE" ]]; then
        log_warn "Data lama terdeteksi di $APP_BASE/nextcloud/db"
        if ! prompt_yes_no "Lanjutkan (idempotent)?" "y"; then
            exec "$0" --reset
        fi
    fi

    prompt_password
    prompt_telegram
    save_config

    phase_hardening
    phase_runtime
    phase_provision
    phase_deploy
    mount_regenerate_override
    phase_utilities
    phase_schedule
    phase_healthcheck

    print_summary

    echo ""
    echo -e "${C_YELLOW}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_YELLOW}  ⚠️  Nextcloud sedang initialisasi di background${C_RESET}"
    echo -e "${C_YELLOW}═══════════════════════════════════════════════════════════════${C_RESET}"
    echo ""
    echo -e "  Tunggu ~1-2 menit, lalu jalankan:"
    echo -e "     ${C_GREEN}sudo $SCRIPT_NAME --tuning${C_RESET}"
    echo ""
    echo -e "  Lalu konfigurasi user & folder:"
    echo -e "     ${C_GREEN}sudo ./auto-config.sh${C_RESET}"
    echo ""
}

main "$@"