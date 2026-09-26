#!/bin/bash

# ==============================================================================
# ERPNext + HRMS Automated Setup, Update, and Rollback Script (Production Mode)
# Compatible with Ubuntu 22.04 LTS / Debian 12 (One-Liner & LXC Safe)
# ==============================================================================

set -e

# !!! GANTI URL INI DENGAN URL RAW GITHUB ANDA !!!
GITHUB_RAW_URL="https://raw.githubusercontent.com/USERNAME/REPO/main/install_erpnext.sh"

# Variable Configuration
BENCH_DIR="$HOME/frappe-bench"
BENCH_VERSION="version-15"
LOG_DIR="$HOME/frappe_backups_log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# AUTO-HANDLE ROOT / LXC USER CREATION (PIPE & ONE-LINER SAFE)
# ------------------------------------------------------------------------------
check_and_switch_root() {
    if [ "$EUID" -eq 0 ]; then
        log_warn "Terdeteksi menjalankan skrip sebagai root (LXC Container/Proxmox)."
        log_info "Membuat user non-root khusus 'frappe' untuk Frappe Bench..."

        # Update repositori & pastikan dependency dasar terpasang
        apt update && apt install -y sudo curl git

        # Buat user frappe jika belum ada
        if ! id "frappe" &>/dev/null; then
            useradd -m -s /bin/bash frappe
            echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe
            chmod 0440 /etc/sudoers.d/frappe
            log_info "User 'frappe' berhasil dibuat dan diberi akses sudo."
        fi

        TARGET_PATH="/home/frappe/install_erpnext.sh"

        # Jika dijalankan dari file lokal -> copy file. Jika dari pipe -> download dari GitHub RAW URL
        if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "-bash" ]; then
            cp "$(readlink -f "$0")" "$TARGET_PATH"
        else
            log_info "Mengunduh salinan skrip fisik ke $TARGET_PATH..."
            curl -fsSL "$GITHUB_RAW_URL" -o "$TARGET_PATH" || {
                log_error "Gagal mengunduh skrip dari $GITHUB_RAW_URL."
                log_error "Pastikan variabel GITHUB_RAW_URL di dalam skrip sudah diisi dengan URL GitHub Anda!"
                exit 1
            }
        fi

        chown frappe:frappe "$TARGET_PATH"
        chmod +x "$TARGET_PATH"

        log_info "Beralih eksekusi ke user 'frappe'..."
        exec su - frappe -c "$TARGET_PATH $1"
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 1. INSTALLATION FUNCTION (PRODUCTION MODE)
# ------------------------------------------------------------------------------
install_erpnext() {
    log_info "Memulai proses instalasi ERPNext + HRMS (Production Mode)..."

    # Menghubungkan kembali keyboard/terminal untuk input interaktif saat dijalankan dari pipe curl
    if [ ! -t 0 ]; then
        exec < /dev/tty 2>/dev/null || true
    fi

    read -p "Masukkan nama site (misal: erp.local): " SITE_NAME
    read -sp "Masukkan Password Root MariaDB: " MYSQL_ROOT_PASS
    echo ""
    read -sp "Masukkan Password Administrator ERPNext: " ADMIN_PASS
    echo ""

    log_info "1/6. Menginstal dependencies sistem, Nginx, dan Supervisor..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y python3-dev python3-pip python3-venv git mariadb-server mariadb-client \
        redis-server curl xvfb libfontconfig wkhtmltopdf build-essential cron nginx supervisor fail2ban

    # Node.js Installation
    if ! command -v node &> /dev/null; then
        log_info "Menginstal Node.js & NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        nvm install 18
        nvm use 18
        npm install -g yarn
    fi

    # Frappe Bench Installation
    log_info "2/6. Menginstal Frappe Bench CLI..."
    sudo pip3 install frappe-bench --break-system-packages 2>/dev/null || pip3 install frappe-bench

    # Setup MariaDB Configuration
    log_info "3/6. Mengonfigurasi MariaDB..."
    sudo mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS'; FLUSH PRIVILEGES;"
    
    MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
    if [ -f "$MYSQL_CONF" ]; then
        sudo bash -c "cat <<EOF >> $MYSQL_CONF

[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF"
        sudo systemctl restart mariadb
    fi

    # Initialize Bench
    log_info "4/6. Membuat Bench Directory ($BENCH_VERSION)..."
    bench init --frappe-branch $BENCH_VERSION $BENCH_DIR
    cd $BENCH_DIR

    # Jalankan Redis temporary daemon untuk tahap pembuatan site & app
    log_info "Menjalankan instance Redis sementara untuk proses instalasi..."
    redis-server config/redis_queue.conf --daemonize yes || true
    redis-server config/redis_cache.conf --daemonize yes || true
    redis-server config/redis_socketio.conf --daemonize yes || true

    # Create Site & Install Apps
    log_info "5/6. Mengunduh dan memasang ERPNext + HRMS..."
    bench new-site $SITE_NAME --mariadb-root-password $MYSQL_ROOT_PASS --admin-password $ADMIN_PASS
    
    bench get-app --branch $BENCH_VERSION erpnext
    bench get-app --branch $BENCH_VERSION hrms

    bench --site $SITE_NAME install-app erpnext
    bench --site $SITE_NAME install-app hrms

    # Setup Production Mode (Nginx + Supervisor)
    log_info "6/6. Mengonfigurasi mode Production (Nginx & Supervisor)..."
    
    # Hentikan Redis temporary agar diambil alih oleh Supervisor
    pkill -f redis || true

    # Enable and start background services
    sudo systemctl enable supervisor nginx
    sudo systemctl start supervisor nginx

    # Konfigurasi Production otomatis via Bench
    sudo $(which bench) setup production frappe --yes

    # Reload services
    sudo supervisorctl reread
    sudo supervisorctl update
    sudo supervisorctl restart all
    sudo systemctl restart nginx

    # Create shortcut commands for update and rollback
    setup_shortcuts

    log_info "================================================================="
    log_info "Instalasi Production Selesai!"
    log_info "ERPNext & HRMS sudah berjalan di background via Nginx & Supervisor."
    log_info "Akses web Anda di IP server atau domain: http://$SITE_NAME"
    log_info "================================================================="
}

# ------------------------------------------------------------------------------
# 2. UPDATE FUNCTION
# ------------------------------------------------------------------------------
update_erpnext() {
    log_info "Memulai pembaruan ERPNext + HRMS..."

    if [ ! -d "$BENCH_DIR" ]; then
        log_error "Direktori bench tidak ditemukan di $BENCH_DIR"
        exit 1
    fi

    cd $BENCH_DIR
    
    # Auto Backup before updating
    log_warn "Membuat snapshot/backup otomatis sebelum pembaruan..."
    mkdir -p $LOG_DIR
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    
    bench backup --with-files
    
    # Save the current git commit hashes for rollback
    echo "# Rollback Snapshot - $TIMESTAMP" > "$LOG_DIR/rollback_$TIMESTAMP.txt"
    for app in frappe erpnext hrms; do
        if [ -d "apps/$app" ]; then
            COMMIT=$(cd apps/$app && git rev-parse HEAD)
            echo "$app:$COMMIT" >> "$LOG_DIR/rollback_$TIMESTAMP.txt"
        fi
    done

    # Execute Update
    log_info "Menjalankan pembaruan bench..."
    bench update

    log_info "Pembaruan Berhasil! Catatan snapshot tersimpan di $LOG_DIR/rollback_$TIMESTAMP.txt"
}

# ------------------------------------------------------------------------------
# 3. ROLLBACK FUNCTION
# ------------------------------------------------------------------------------
rollback_erpnext() {
    log_warn "Memulai proses Rollback..."

    if [ ! -d "$BENCH_DIR" ]; then
        log_error "Direktori bench tidak ditemukan di $BENCH_DIR"
        exit 1
    fi

    mkdir -p $LOG_DIR
    LATEST_SNAPSHOT=$(ls -t $LOG_DIR/rollback_*.txt 2>/dev/null | head -n 1)

    if [ -z "$LATEST_SNAPSHOT" ]; then
        log_error "Tidak ditemukan catatan snapshot rollback sebelumnya!"
        exit 1
    fi

    log_info "Menggunakan file snapshot: $LATEST_SNAPSHOT"
    cd $BENCH_DIR

    # Revert Git Commits
    while IFS=':' read -r app commit; do
        # Ignore comments
        [[ "$app" =~ ^#.* ]] && continue
        if [ -d "apps/$app" ]; then
            log_info "Mengembalikan $app ke commit: $commit"
            (cd "apps/$app" && git checkout $commit)
        fi
    done < "$LATEST_SNAPSHOT"

    # Migrate Database Back
    log_info "Menjalankan migrasi database setelah rollback..."
    bench migrate

    log_info "Proses Rollback selesai! Sistem telah dikembalikan ke kondisi snapshot sebelumnya."
}

# ------------------------------------------------------------------------------
# SHORTCUT SETUP
# ------------------------------------------------------------------------------
setup_shortcuts() {
    SCRIPT_PATH="/home/frappe/install_erpnext.sh"
    
    # Add alias to user's bashrc if not present
    if ! grep -q "erpnext-update" "$HOME/.bashrc"; then
        echo "alias erpnext-update='$SCRIPT_PATH --update'" >> "$HOME/.bashrc"
        echo "alias erpnext-rollback='$SCRIPT_PATH --rollback'" >> "$HOME/.bashrc"
        log_info "Perintah shortcut telah ditambahkan ke ~/.bashrc"
        log_info "Gunakan 'erpnext-update' atau 'erpnext-rollback' setelah membuka terminal baru."
    fi
}

# ------------------------------------------------------------------------------
# CLI ROUTER
# ------------------------------------------------------------------------------
check_and_switch_root "$1"

case "$1" in
    --update)
        update_erpnext
        ;;
    --rollback)
        rollback_erpnext
        ;;
    *)
        install_erpnext
        ;;
esac
