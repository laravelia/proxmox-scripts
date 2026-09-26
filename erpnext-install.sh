#!/usr/bin/env bash
set -e

# 1. Update OS & Install Dependencies
apt-get update && apt-get install -y git python3-dev python3-pip python3-venv mariadb-server mariadb-client redis-server curl nodejs npm

# Install Bench CLI
pip3 install frappe-bench --break-system-packages

# 2. Inisialisasi Bench & ERPNext + HRMS
cd /home
bench init --frappe-branch version-15 frappe-bench
cd frappe-bench

# Download App ERPNext & HRMS
bench get-app --branch version-15 erpnext
bench get-app --branch version-15 hrms

# Create Site & Install Apps
bench new-site site1.local --admin-password "admin" --mariadb-root-password "root"
bench --site site1.local install-app erpnext
bench --site site1.local install-app hrms

# Production Setup (Nginx & Supervisor)
bench setup production frappe

# 3. Buat Script Automatic Upgrade ("upgrade")
cat << 'EOF' > /usr/local/bin/upgrade
#!/usr/bin/env bash
echo "==> Memulai Upgrade ERPNext & HRMS..."
cd /home/frappe-bench
bench update --pull --apps erpnext,hrms --patch
echo "==> Upgrade Selesai!"
EOF

chmod +x /usr/local/bin/upgrade
