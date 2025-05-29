#!/bin/bash
# ~/secure-server-setup/secure-server-setup.sh

set -euo pipefail

WORKDIR="$HOME/secure-server-setup"
LOGFILE="$WORKDIR/setup.log"
PHASE_MARKER="$WORKDIR/.phase"
SCREEN_NAME="secure-setup"

mkdir -p "$WORKDIR"
touch "$LOGFILE"

log_step() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1: $2" | tee -a "$LOGFILE"
}

mark_done() {
  echo "$1" > "$PHASE_MARKER"
}

already_done() {
  [[ -f "$PHASE_MARKER" && $(cat "$PHASE_MARKER") == "$1" ]]
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
  sudo apt update && sudo apt upgrade -y
  sudo timedatectl set-timezone Asia/Kolkata

  mark_done "phase1"
  sudo reboot
fi

##############################################
# PHASE 2 - Install Security & Dev Packages  #
##############################################

if ! already_done "phase2"; then
  log_step "PHASE 2" "Installing base packages"
  sudo apt install -y nginx ufw fail2ban rkhunter chkrootkit clamav clamav-daemon logrotate unattended-upgrades git build-essential libpcre3 libpcre3-dev libssl-dev zlib1g-dev certbot python3-certbot-nginx gcc make autoconf automake libtool libcurl4-openssl-dev liblua5.3-dev libfuzzy-dev ssdeep gettext pkg-config libgeoip-dev libyajl-dev doxygen libpcre2-dev zlib1g wget libsystemd-dev libevent-dev curl

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

  sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sudo sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

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

  sudo bash -c 'cat <<EOF >> /etc/crontab
0 2 * * * root clamscan -r / --bell -i >> /var/log/clamav/scan.log
0 3 * * * root rkhunter --check --skip-keypress
0 4 * * * root chkrootkit
EOF'

  mark_done "phase4"
fi

#################################
# PHASE 5 - ModSecurity Build   #
#################################

if ! already_done "phase5"; then
  log_step "PHASE 5" "Cloning and building ModSecurity and Nginx 1.24.0"

  cd /opt
  sudo git clone https://github.com/owasp-modsecurity/ModSecurity.git
  cd ModSecurity && sudo git submodule init && sudo git submodule update
  sudo ./build.sh
  sudo ./configure && sudo make && sudo make install

  cd /opt
  sudo git clone https://github.com/owasp-modsecurity/ModSecurity-nginx.git
  sudo wget https://nginx.org/download/nginx-1.24.0.tar.gz
  sudo tar -xzf nginx-1.24.0.tar.gz
  cd nginx-1.24.0
  sudo ./configure --with-compat --add-dynamic-module=/opt/ModSecurity-nginx
  sudo make && sudo make modules
  sudo cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules-enabled/

  sudo cp /opt/ModSecurity/modsecurity.conf-recommended /etc/nginx/modsecurity.conf
  sudo cp /opt/ModSecurity/unicode.mapping /etc/nginx/unicode.mapping

  sudo sed -i '6iload_module /etc/nginx/modules-enabled/ngx_http_modsecurity_module.so;' /etc/nginx/nginx.conf
  sudo sed -i 's/^SecRuleEngine .*/SecRuleEngine On/' /etc/nginx/modsecurity.conf

  mark_done "phase5"
fi

######################################
# PHASE 6 - OWASP CRS Configuration  #
######################################

if ! already_done "phase6"; then
  log_step "PHASE 6" "Installing OWASP CRS and linking config"

  sudo git clone https://github.com/coreruleset/coreruleset.git /etc/nginx/owasp-crs
  sudo cp /etc/nginx/owasp-crs/crs-setup.conf.example /etc/nginx/owasp-crs/crs-setup.conf

  echo -e "\nInclude owasp-crs/crs-setup.conf\nInclude owasp-crs/rules/*.conf" | sudo tee -a /etc/nginx/modsecurity.conf

  sudo nginx -t
  sudo systemctl restart nginx

  mark_done "phase6"
fi

######################################
# PHASE 7 - Misc Configs & Rotation  #
######################################

if ! already_done "phase7"; then
  log_step "PHASE 7" "Configuring logrotate and unattended upgrades"

  echo -e "/var/log/nginx/*.log {\n  rotate 30\n  daily\n  missingok\n  notifempty\n  compress\n}" | sudo tee /etc/logrotate.d/nginx

  sudo dpkg-reconfigure -f noninteractive unattended-upgrades

  mark_done "phase7"
fi

##########################
# PHASE 8 - Final Checks #
##########################

if ! already_done "phase8"; then
  log_step "PHASE 8" "Secure server setup completed successfully"
  mark_done "phase8"
fi
