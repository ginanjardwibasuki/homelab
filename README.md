# 🏠 Homelab Stack Installer — Enterprise Edition

<div align="center">

![Version](https://img.shields.io/badge/version-2.1.1--enterprise-blue?style=for-the-badge)
![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-red?style=for-the-badge&logo=debian)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?style=for-the-badge&logo=gnu-bash)
![License](https://img.shields.io/badge/license-MIT-green?style=for-the-badge)

**One-shot installer untuk self-hosted homelab stack:**
**Nextcloud + Immich + Jellyfin**

*Idempotent • Split-storage • Smart backup • Telegram-integrated*

</div>

---

## 📖 Tentang

**Homelab Stack Installer** adalah script Bash yang mengotomasi deployment **Nextcloud**, **Immich**, dan **Jellyfin** dalam satu perintah. Dirancang untuk **LXC container** (Proxmox), **VPS**, atau **bare-metal** dengan arsitektur **split-storage**: user data di SSD eksternal, app/DB di local disk.

Cukup jalankan satu baris, dan seluruh stack siap pakai dalam ~10 menit.

---

## ⚡ Instalasi Cepat (One-Liner)

Jalankan sebagai **root** di server Debian 12/13 atau Ubuntu 22.04+:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)"
```

> 💡 **Best practice**: review dulu sebelum eksekusi.
> ```bash
> curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh | less
> ```

### Opsi CLI

```bash
# Install / re-run idempotent
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)"

# Pre-flight check saja (tidak install)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --check

# Wipe semua data & install dari nol
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --reset

# Bantuan
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --help
```

> **Catatan**: `-s --` dipakai untuk passing argumen CLI ke script saat dipanggil via `bash -c "$(curl ...)"`.

---

## 🎯 Fitur Utama

### 🚀 One-Shot Deployment
- Instalasi otomatis **Nextcloud + Immich + Jellyfin** dengan Docker Compose
- **Idempotent** — aman dijalankan ulang tanpa kehilangan data
- Mode `--reset` untuk wipe & install dari nol
- Mode `--check` untuk pre-flight validation tanpa install

### 💾 Split-Storage Architecture

```
/mnt/external_ssd/homelab_data/   ← User data (SSD, besar)
    ├── nextcloud/data/           → File Nextcloud
    ├── immich/library/           → Foto & video Immich
    └── jellyfin/media/           → Media Jellyfin

/root/homelab/                    ← App/DB/Config (local disk, cepat)
    ├── nextcloud/{app,db}/
    ├── immich/postgres/
    ├── jellyfin/{config,cache}/
    └── docker-compose.yml
```

**Kenapa?** SSD cepat untuk I/O user, local disk untuk random-write database (memperpanjang umur SSD).

### 🛡️ System Hardening
- Konfigurasi SSH (`PermitRootLogin`, `PasswordAuthentication`)
- **fail2ban** otomatis dengan jail SSH (ban 24 jam, max 10 retry)
- Timezone `Asia/Jakarta`
- Docker log rotation (10MB × 3 file)
- `live-restore` untuk zero-downtime Docker daemon restart

### 🔐 Secure Credential Management
- Password prompt inline (tidak tersimpan di shell history)
- Config disimpan di `/root/config/homelab.conf` (chmod 600)
- YAML-safe escaping untuk password dengan karakter spesial (`$`, `"`, `\`)
- Validasi password minimal 8 karakter + konfirmasi

### 📦 Smart Backup (`autobackup`)

Bukan backup full — hanya yang penting:

| Disertakan ✅ | Di-skip ❌ (auto-rebuild) |
|--------------|---------------------------|
| SQL dump MariaDB (Nextcloud) | Nextcloud codebase (~400MB) |
| SQL dump PostgreSQL (Immich) | Raw MariaDB files |
| `config.php` + `custom_apps/` | Raw PostgreSQL files |
| Jellyfin config (tanpa metadata) | Jellyfin cache/transcode |
| `docker-compose.yml` + `homelab.conf` | — |

**Hasil:** backup kecil (~50–200MB vs 5GB+ full backup), cepat, tetap lengkap.

### ☁️ Telegram Integration
- Auto-split arsip >48MB (batas Telegram Bot API)
- Upload multi-part dengan caption
- Retry 3× untuk reliability
- Notifikasi progress (start, split, selesai)
- Validasi token + chat ID sebelum disimpan

### 🔄 Auto-Restore (`autorestore`)
- Deteksi otomatis tipe backup (`smart` vs `full`)
- Auto-merge split parts
- Drop & recreate database sebelum import
- Restore config, custom_apps, compose, dan DB dalam satu perintah
- Trap-based cleanup — service selalu kembali running meski gagal

### ⚙️ Runtime Utilities

| Command | Fungsi |
|---------|--------|
| `autobackup` | Stop → dump DB → arsip → Telegram → start |
| `autorestore` | Stop → restore → start |
| `config` | Ubah password & Telegram token |

### 🩺 Built-in Diagnostics
- Health check semua container di akhir instalasi
- Error pattern detection di log Nextcloud (`Access denied`, `SQLSTATE`, dll)
- Auto-cleanup `config.php` stale jika DB kosong
- Deteksi volume DB rusak (`ibdata1` hilang → auto reset)
- Lock file (`flock`) mencegah backup/restore konkuren

### 🔁 Auto-Start on Boot
- `docker.service` di-enable dengan `RequiresMountsFor=/mnt/external_ssd`
- `homelab-stack.service` (systemd oneshot) untuk `docker compose up -d`
- Cron Nextcloud background job (`*/5 * * * *`)
- Cron autobackup harian (`0 2 * * *`)

### 🎨 Custom MOTD
Login banner dengan endpoint URL, status service, dan hint utility — plus disable MOTD Ubuntu default.

---

## 🖼️ Setelah Instalasi

Akses service melalui browser:

| Service | URL | Login |
|---------|-----|-------|
| 📁 **Nextcloud** | `http://<IP-SERVER>:8080` | `admin` / password Anda |
| 📸 **Immich** | `http://<IP-SERVER>:2283` | `admin@example.com` / password Anda |
| 🎬 **Jellyfin** | `http://<IP-SERVER>:8096` | Setup wizard |

Cek IP server:
```bash
hostname -I | awk '{print $1}'
```

---

## 🛠️ Utility Pasca-Install

Tiga command tersedia di `/usr/local/bin/`:

```bash
# Backup manual (stop → dump DB → arsip → Telegram → start)
sudo autobackup

# Restore dari backup terbaru di /root/restore/
sudo autorestore

# Ubah password & Telegram token
sudo config
```

Backup otomatis berjalan tiap **hari pukul 02:00** via cron.

---

## 📋 Persyaratan

| Item | Minimum | Rekomendasi |
|------|---------|-------------|
| OS | Debian 12 / Ubuntu 22.04 | Debian 13 / Ubuntu 24.04 |
| RAM | 4 GB | 8 GB (Immich ML) |
| CPU | 2 vCPU | 4 vCPU |
| Disk SSD (`/mnt/external_ssd`) | 5 GB | 100 GB+ |
| Disk Root (`/root`) | 5 GB | 20 GB+ |
| Akses | Root / sudo | — |

> 💡 Cocok untuk **LXC container** (Proxmox), **VPS**, atau **bare-metal**.

---

## 🏗️ Arsitektur Stack

```
┌─────────────────────────────────────────────────────────────┐
│                  Docker Network: homelab-net                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐     │
│  │  nextcloud   │   │ immich-server│   │   jellyfin   │     │
│  │   :8080      │   │   :2283      │   │   :8096      │     │
│  └──────┬───────┘   └──────┬───────┘   └──────────────┘     │
│         │                  │                                │
│  ┌──────▼───────┐   ┌──────▼───────┐                        │
│  │nextcloud-db  │   │immich-postgres│                       │
│  │  MariaDB     │   │  pgvector/pg15│                       │
│  └──────────────┘   └───────────────┘                       │
│  ┌──────────────┐   ┌───────────────┐                       │
│  │nextcloud-redis│  │ immich-redis  │                       │
│  │  Redis        │  │  Valkey 8     │                       │
│  └──────────────┘   └───────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

---

## 📁 Struktur Repository

```
homelab/
├── autoinstall.sh          # Installer utama
├── README.md               # Dokumentasi ini
├── LICENSE                 # MIT
└── docs/
    ├── TROUBLESHOOTING.md  # Solusi error umum
    ├── RESTORE.md          # Panduan restore detail
    └── SECURITY.md         # Catatan hardening
```

---

## 🔧 Troubleshooting Cepat

**Script gagal di tengah jalan?**
```bash
tail -f /var/log/homelab-installer.log
```

**SSD tidak terdeteksi?**
```bash
lsblk
mount | grep external_ssd
```
Pastikan SSD di-mount ke `/mnt/external_ssd`.

**Nextcloud tidak bisa diakses?**
```bash
docker logs nextcloud --tail 50
docker compose -f /root/homelab/docker-compose.yml ps
```

**Cek status semua container:**
```bash
docker ps --filter name=nextcloud --filter name=immich --filter name=jellyfin
```

**Ingin reset bersih?**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --reset
```

**Docker tidak auto-start setelah reboot?**
```bash
systemctl status docker --no-pager
systemctl is-enabled docker
```

---

## ⚠️ Peringatan Keamanan

Script ini melakukan perubahan sistem:

- ✏️ Mengubah `/etc/ssh/sshd_config` (permit root login)
- 🔥 Install & enable **fail2ban**
- 🐳 Install **Docker** dari repo resmi
- ⏰ Menambah **cron jobs** (Nextcloud bg job + autobackup)
- 🎨 Mengganti **MOTD** login

**Selalu review script** sebelum menjalankan di production. Pastikan Anda punya akses konsol/IPMI sebagai fallback jika SSH terputus.

Backup tersimpan di `/root/restore/` — tapi **jangan pernah mengandalkan satu lokasi**. Upload otomatis ke Telegram sangat disarankan untuk off-site backup.

---

## 🧪 Testing Matrix

| Environment | Status |
|-------------|--------|
| Debian 12 (LXC) | ✅ Tested |
| Debian 13 (trixie) | ✅ Tested |
| Ubuntu 22.04 | ✅ Tested |
| Ubuntu 24.04 | ⚠️ Partial |
| Proxmox LXC | ✅ Tested |

---

## 📋 Cheat Sheet Perintah

```bash
# ── Install ──
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)"

# ── Pre-flight check ──
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --check

# ── Reset bersih ──
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh)" -s -- --reset

# ── Download & review manual ──
curl -fsSL https://raw.githubusercontent.com/ginanjardwibasuki/homelab/main/autoinstall.sh -o /root/autoinstall.sh
chmod +x /root/autoinstall.sh
sudo /root/autoinstall.sh

# ── Operasional harian ──
sudo autobackup      # backup manual
sudo autorestore     # restore dari backup terbaru
sudo config          # ubah kredensial

# ── Monitoring ──
docker ps                                           # status container
tail -f /var/log/homelab-installer.log              # log installer
docker logs nextcloud --tail 50                     # log Nextcloud
```

---

## 🤝 Kontribusi

Pull request sangat diterima! Untuk perubahan besar:

1. Fork repo
2. Buat branch fitur (`git checkout -b feat/AmazingFeature`)
3. Commit (`git commit -m 'Add: AmazingFeature'`)
4. Push (`git push origin feat/AmazingFeature`)
5. Buka Pull Request

---

## 📜 Lisensi

MIT License — bebas digunakan, dimodifikasi, dan didistribusikan. Lihat [LICENSE](LICENSE).

---

<div align="center">

**⭐ Kalau repo ini membantu, jangan lupa kasih bintang! ⭐**

Made with ❤️ for the self-hosting community

</div>