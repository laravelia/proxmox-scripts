#!/usr/bin/env bash
# Header & konfigurasi standar
source <(curl -s https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
APP="ERPNext-HRMS"
NSAPP="erpnext-hrms"
var_cpu="2"
var_ram="4096"
var_disk="20"
var_os="ubuntu"
var_version="24.04"

header_info "$APP"
variables
build_container

# POINT PENTING: Arahkan installer ke script install milik Anda di github
description="ERPNext + HRMS"
msg_info "Installing $APP"
lxc-attach -n $CTID -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/laravelia/proxmox-scripts/refs/heads/install/erpnext-install.sh?token=GHSAT0AAAAAAEKKA47SD65VAXWFYZO37DU22VX5PBA)"
msg_ok "Installed $APP"
