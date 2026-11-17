#!/bin/bash
# ~/secure-server-setup/secure-server-setup.sh

set -euo pipefail

WORKDIR="$HOME/secure-server-setup"
LOGFILE="$WORKDIR/setup.log"
PHASE_MARKER="$WORKDIR/.phase"
SCREEN_NAME="secure-setup"

# Pinned releases, so a rebuild gets the same code. Bump deliberately.
MODSECURITY_VERSION="v3.0.17"
MODSECURITY_NGINX_VERSION="v1.0.4"
CRS_VERSION="v4.30.0"

mkdir -p "$WORKDIR"
touch "$LOGFILE"

log_step() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1: $2" | tee -a "$LOGFILE"
}

mark_done() {
  echo "$1" >> "$PHASE_MARKER"
}

already_done() {
  [[ -f "$PHASE_MARKER" ]] && grep -qx "$1" "$PHASE_MARKER"
}

# Resume this script after a reboot; removed again when setup finishes.
RESUME_CMD="@reboot $WORKDIR/secure-server-setup.sh"

enable_resume() {
  (crontab -l 2>/dev/null | grep -vxF "$RESUME_CMD" || true; echo "$RESUME_CMD") | crontab -
}

disable_resume() {
  (crontab -l 2>/dev/null | grep -vxF "$RESUME_CMD" || true) | crontab -
}

####################
# PHASE 0 - Screen #
####################

if ! screen -list | grep -q "$SCREEN_NAME"; then
  log_step "PHASE 0" "Starting screen session $SCREEN_NAME"
  screen -dmS "$SCREEN_NAME" bash -c "$WORKDIR/secure-server-setup.sh"
  exit 0
fi

##############################
# PHASE 1 - Initial Setup    #
##############################

if ! already_done "phase1"; then
  log_step "PHASE 1" "System update and timezone config"
  sudo apt update
  sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
  sudo timedatectl set-timezone Asia/Kolkata

  mark_done "phase1"
  enable_resume
  sudo reboot
  exit 0
fi

##############################################
# PHASE 2 - Install Security & Dev Packages  #
##############################################

if ! already_done "phase2"; then
  log_step "PHASE 2" "Installing base packages"
  # rkhunter and chkrootkit pull in postfix, which stops to ask about mail.
  # Answer "No configuration" up front and keep apt non-interactive.
  echo "postfix postfix/main_mailer_type select No configuration" | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive apt install -y nginx ufw fail2ban rkhunter chkrootkit clamav clamav-daemon logrotate unattended-upgrades git build-essential libssl-dev zlib1g-dev certbot python3-certbot-nginx gcc make autoconf automake libtool libcurl4-openssl-dev liblua5.3-dev libfuzzy-dev ssdeep gettext pkg-config libgeoip-dev libyajl-dev doxygen libpcre2-dev zlib1g wget libsystemd-dev libevent-dev curl

  mark_done "phase2"
fi

#####################################
# PHASE 3 - SSH / UFW / Fail2Ban    #
#####################################

if ! already_done "phase3"; then
  log_step "PHASE 3" "Configuring UFW & SSH & Fail2Ban"

  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow OpenSSH
  sudo ufw allow http
  sudo ufw allow https
  sudo ufw --force enable

  # Refuse to disable password login unless this user can log in with a key.
  if [[ ! -s "$HOME/.ssh/authorized_keys" ]]; then
    log_step "PHASE 3" "No SSH key in $HOME/.ssh/authorized_keys; add one before disabling password login"
    exit 1
  fi

  # A drop-in, because sshd uses the first value it reads and cloud images
  # often ship 50-cloud-init.conf with PasswordAuthentication yes.
  printf 'PermitRootLogin no\nPasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null
  sudo sshd -t
  sudo systemctl restart ssh

  cat <<EOF | sudo tee /etc/fail2ban/jail.local >/dev/null
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 5

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 5
EOF

  sudo systemctl restart fail2ban

  mark_done "phase3"
fi

##################################
# PHASE 4 - Rootkits & Scanners  #
##################################

if ! already_done "phase4"; then
  log_step "PHASE 4" "Enabling and scheduling ClamAV, RKHunter, Chkrootkit"

  sudo systemctl enable clamav-freshclam
  sudo systemctl start clamav-freshclam
  sudo systemctl enable clamav-daemon
  sudo systemctl start clamav-daemon

  echo -e "Version:2025052202\nmirror=https://rkhunter.sourceforge.io/1.4\nmirror=https://rkhunter.sourceforge.io/1.4" | sudo tee /var/lib/rkhunter/db/mirrors.dat >/dev/null
  sudo sed -i 's/^UPDATE_MIRRORS=.*/UPDATE_MIRRORS=1/' /etc/rkhunter.conf
  sudo sed -i 's/^MIRRORS_MODE=.*/MIRRORS_MODE=0/' /etc/rkhunter.conf
  sudo sed -i 's|^WEB_CMD=.*|WEB_CMD=/usr/bin/wget|' /etc/rkhunter.conf

  sudo rkhunter --propupd || true
  sudo chkrootkit || true

  sudo tee -a /etc/crontab >/dev/null <<'EOF'
0 2 * * * root clamscan -r -i --exclude-dir='^/(proc|sys|dev|run)' / >> /var/log/clamav/scan.log 2>&1
0 3 * * * root rkhunter --check --skip-keypress
0 4 * * * root chkrootkit
EOF

  mark_done "phase4"
fi

#################################
# PHASE 5 - ModSecurity Build   #
#################################

if ! already_done "phase5"; then
  # The dynamic module must be built against the installed nginx version.
  NGINX_VERSION=$(nginx -v 2>&1 | sed -E 's|.*nginx/([0-9.]+).*|\1|')
  log_step "PHASE 5" "Cloning and building ModSecurity and the connector for nginx $NGINX_VERSION"

  cd /opt
  sudo git clone --depth 1 --branch "$MODSECURITY_VERSION" https://github.com/owasp-modsecurity/ModSecurity.git
  cd ModSecurity
  # Recursive: Mbed TLS 4.x has nested submodules of its own.
  sudo git submodule update --init --recursive
  sudo ./build.sh
  # One command per line: set -e does not stop on a failure inside an && chain.
  sudo ./configure
  sudo make -j"$(nproc)"
  sudo make install

  cd /opt
  sudo git clone --depth 1 --branch "$MODSECURITY_NGINX_VERSION" https://github.com/owasp-modsecurity/ModSecurity-nginx.git
  sudo wget "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
  sudo tar -xzf "nginx-$NGINX_VERSION.tar.gz"
  cd "nginx-$NGINX_VERSION"
  sudo ./configure --with-compat --add-dynamic-module=/opt/ModSecurity-nginx
  sudo make -j"$(nproc)" modules
  # The modules directory only exists once a dynamic module is installed.
  MODULES_PATH=$(nginx -V 2>&1 | grep -oP -- '--modules-path=\K\S+')
  sudo mkdir -p "$MODULES_PATH"
  sudo cp objs/ngx_http_modsecurity_module.so "$MODULES_PATH/"
  echo "load_module $MODULES_PATH/ngx_http_modsecurity_module.so;" | sudo tee /etc/nginx/modules-enabled/50-mod-http-modsecurity.conf >/dev/null

  sudo cp /opt/ModSecurity/modsecurity.conf-recommended /etc/nginx/modsecurity.conf
  sudo cp /opt/ModSecurity/unicode.mapping /etc/nginx/unicode.mapping

  sudo sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' /etc/nginx/modsecurity.conf

  mark_done "phase5"
fi

######################################
# PHASE 6 - OWASP CRS Configuration  #
######################################

if ! already_done "phase6"; then
  log_step "PHASE 6" "Installing OWASP CRS and linking config"

  sudo git clone --depth 1 --branch "$CRS_VERSION" https://github.com/coreruleset/coreruleset.git /etc/nginx/owasp-crs
  sudo cp /etc/nginx/owasp-crs/crs-setup.conf.example /etc/nginx/owasp-crs/crs-setup.conf

  echo -e "\nInclude owasp-crs/crs-setup.conf\nInclude owasp-crs/rules/*.conf" | sudo tee -a /etc/nginx/modsecurity.conf

  # Turn ModSecurity on for every server block (http context).
  printf 'modsecurity on;\nmodsecurity_rules_file /etc/nginx/modsecurity.conf;\n' | sudo tee /etc/nginx/conf.d/modsecurity.conf >/dev/null

  sudo nginx -t
  sudo systemctl restart nginx

  mark_done "phase6"
fi

######################################
# PHASE 7 - Misc Configs & Rotation  #
######################################

if ! already_done "phase7"; then
  log_step "PHASE 7" "Configuring logrotate and unattended upgrades"

  # Keep Ubuntu's config (its postrotate makes nginx reopen logs); only keep 30 days.
  sudo sed -i 's/^\(\s*\)rotate [0-9]*/\1rotate 30/' /etc/logrotate.d/nginx

  sudo dpkg-reconfigure -f noninteractive unattended-upgrades

  mark_done "phase7"
fi

##########################
# PHASE 8 - Final Checks #
##########################

if ! already_done "phase8"; then
  disable_resume
  log_step "PHASE 8" "Secure server setup completed successfully"
  mark_done "phase8"
fi
