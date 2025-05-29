#!/bin/bash
# ~/secure-server-setup/verify-setup.sh

set -euo pipefail
LOG="$HOME/secure-server-setup/verify.log"
echo "Security Setup Verification — $(date)" > "$LOG"

log() {
  echo -e "[✔] $1" | tee -a "$LOG"
}
warn() {
  echo -e "[!] $1" | tee -a "$LOG"
}
fail() {
  echo -e "[✘] $1" | tee -a "$LOG"
}

check_package() {
  if dpkg -s "$1" &>/dev/null; then log "Package '$1' is installed"; else fail "Package '$1' is missing"; fi
}

echo "=================== PHASE 1: BASE PACKAGES ====================" | tee -a "$LOG"
for pkg in nginx ufw fail2ban rkhunter chkrootkit clamav clamav-daemon logrotate unattended-upgrades; do
  check_package "$pkg"
done

echo "=================== PHASE 2: UFW & SSH ====================" | tee -a "$LOG"
sudo ufw status | grep -q "Status: active" && log "UFW is active" || fail "UFW is not active"
sudo grep -q "^PermitRootLogin no" /etc/ssh/sshd_config && log "SSH root login disabled" || fail "SSH root login still enabled"
sudo grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config && log "SSH password login disabled" || fail "SSH password login still enabled"

echo "=================== PHASE 3: FAIL2BAN ====================" | tee -a "$LOG"
sudo systemctl is-active --quiet fail2ban && log "Fail2Ban is running" || fail "Fail2Ban is not running"
sudo test -f /etc/fail2ban/jail.local && log "jail.local exists" || fail "jail.local not found"

echo "=================== PHASE 4: CLAMAV & ROOTKIT TOOLS ====================" | tee -a "$LOG"
for svc in clamav-daemon clamav-freshclam; do
  sudo systemctl is-active --quiet "$svc" && log "$svc is running" || fail "$svc is not running"
done
sudo test -f /etc/rkhunter.conf && log "rkhunter.conf found" || fail "rkhunter.conf missing"
sudo test -f /usr/sbin/chkrootkit && log "chkrootkit installed" || fail "chkrootkit missing"
sudo grep -q "clamscan" /etc/crontab && log "clamscan cronjob found" || fail "clamscan cronjob not found"
sudo grep -q "rkhunter" /etc/crontab && log "rkhunter cronjob found" || fail "rkhunter cronjob not found"
sudo grep -q "chkrootkit" /etc/crontab && log "chkrootkit cronjob found" || fail "chkrootkit cronjob not found"

echo "=================== PHASE 5: MODSECURITY ====================" | tee -a "$LOG"
if sudo nginx -V 2>&1 | grep -q "modsecurity"; then
  log "ModSecurity module is compiled"
else
  sudo test -f /etc/nginx/modules-enabled/ngx_http_modsecurity_module.so && log "ModSecurity module loaded dynamically" || fail "ModSecurity module not found"
fi
sudo grep -q "SecRuleEngine On" /etc/nginx/modsecurity.conf && log "ModSecurity config is active" || fail "SecRuleEngine is not set to On"

echo "=================== PHASE 6: OWASP CRS ====================" | tee -a "$LOG"
sudo test -d /etc/nginx/owasp-crs && log "OWASP CRS folder exists" || fail "OWASP CRS not installed"
sudo grep -q "owasp-crs/crs-setup.conf" /etc/nginx/modsecurity.conf && log "CRS config included in modsecurity.conf" || fail "CRS config missing"

echo "=================== PHASE 7: LOGROTATE & AUTO-UPGRADES ====================" | tee -a "$LOG"
sudo test -f /etc/logrotate.d/nginx && log "Logrotate config for Nginx exists" || fail "Missing nginx logrotate config"
sudo test -f /etc/apt/apt.conf.d/20auto-upgrades && log "Unattended-upgrades config found" || fail "Unattended-upgrades config missing"

echo "=================== FINAL CHECK ====================" | tee -a "$LOG"
sudo nginx -t &>/dev/null && log "Nginx config test passed" || fail "Nginx config test failed"

echo -e "\nVerification complete. Review the log at: $LOG"
