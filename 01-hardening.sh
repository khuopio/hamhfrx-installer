#!/bin/bash
# Phase 1 — OS hardening. Idempotent: safe to re-run.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
[ -f "$SCRIPT_DIR/hamhfrx.conf" ] || die "Run ./00-configure.sh first."
source "$SCRIPT_DIR/hamhfrx.conf"

[ "$EUID" -eq 0 ] && die "Run as your normal user with sudo rights, not as root directly."

step "Hostname"
CURRENT_HOSTNAME="$(hostnamectl --static)"
if [ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]; then
    sudo hostnamectl set-hostname "$HOSTNAME"
    sudo sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
    ok "hostname set to $HOSTNAME (reboot recommended before continuing)"
else
    skip "hostname already $HOSTNAME"
fi

step "System update"
sudo apt-get update -qq
sudo apt-get -y -qq upgrade
ok "packages up to date"

step "SSH key-based auth"
if [ -n "$SSH_PUBKEY_PATH" ] && [ -f "$SSH_PUBKEY_PATH" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    if ! grep -qf "$SSH_PUBKEY_PATH" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
        cat "$SSH_PUBKEY_PATH" >> "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        ok "public key installed for $USER"
    else
        skip "public key already present"
    fi
else
    warn "no SSH_PUBKEY_PATH given — make sure a key is authorized BEFORE the next step disables passwords, or you will lock yourself out"
    confirm "Continue anyway?" || die "Aborted — add a key and re-run."
fi

run_once "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config" \
    sudo bash -c "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
                  grep -q '^AllowUsers' /etc/ssh/sshd_config || echo 'AllowUsers $ADMIN_USER' >> /etc/ssh/sshd_config
                  systemctl restart ssh"

step "Firewall (ufw)"
run_once "dpkg -l ufw 2>/dev/null | grep -q ^ii" sudo apt-get -y -qq install ufw
sudo ufw --force default deny incoming
sudo ufw --force default allow outgoing
sudo ufw allow OpenSSH
run_once "sudo ufw status | grep -q 'Status: active'" sudo ufw --force enable

step "fail2ban (journald backend — this OS has no rsyslog by default)"
run_once "dpkg -l fail2ban 2>/dev/null | grep -q ^ii" sudo apt-get -y -qq install fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 4
bantime = 3600
findtime = 600
EOF
sudo systemctl enable --now fail2ban >/dev/null 2>&1
sudo systemctl restart fail2ban
ok "fail2ban configured and running"

step "Unattended security-only upgrades"
run_once "dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii" \
    sudo apt-get -y -qq install unattended-upgrades apt-listchanges
UU_FILE=/etc/apt/apt.conf.d/50unattended-upgrades
if [ -f "$UU_FILE" ]; then
    sudo sed -i 's#^\(\s*"origin=Debian,codename=${distro_codename},label=Debian";\)#//\1#' "$UU_FILE"
    sudo sed -i 's#^Unattended-Upgrade::Automatic-Reboot .*#Unattended-Upgrade::Automatic-Reboot "false";#' "$UU_FILE"
    ok "restricted to security-labeled origin only; automatic reboot disabled"
fi

step "Timezone and disabled radios"
sudo timedatectl set-timezone "$TIMEZONE"
sudo timedatectl set-ntp true
ok "timezone set to $TIMEZONE, NTP enabled"
sudo rfkill block bluetooth 2>/dev/null || true
ok "bluetooth radio blocked (leave wifi enabled unless you confirm Ethernet is in use)"

step "Reduce SD card wear"
if systemctl is-enabled dphys-swapfile &>/dev/null; then
    sudo systemctl disable --now dphys-swapfile
    sudo apt-get -y -qq purge dphys-swapfile
    ok "swap disabled and removed"
else
    skip "swap already disabled"
fi
run_once "grep -q noatime /etc/fstab" \
    sudo sed -i 's/\(\s\)\(defaults\)\(\s\+[0-9]\+\s\+[0-9]\+\)/\1\2,noatime\3/' /etc/fstab

step "Hardware watchdog"
run_once "dpkg -l watchdog 2>/dev/null | grep -q ^ii" sudo apt-get -y -qq install watchdog
run_once "grep -q '^watchdog-device' /etc/watchdog.conf" \
    sudo bash -c "echo 'watchdog-device = /dev/watchdog' >> /etc/watchdog.conf"
run_once "grep -q 'dtparam=watchdog=on' /boot/firmware/config.txt" \
    sudo bash -c "echo 'dtparam=watchdog=on' >> /boot/firmware/config.txt"
sudo systemctl enable --now watchdog >/dev/null 2>&1 || warn "watchdog service could not start — /dev/watchdog may need a reboot to appear (config.txt was just edited)"

echo
echo "=== Phase 1 complete ==="
echo "If the hostname, watchdog, or noatime lines just changed, reboot now:"
echo "    sudo reboot"
echo "Then continue with: ./02-service-account.sh"
