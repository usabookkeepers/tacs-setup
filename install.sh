#!/bin/bash
# TACS server setup - paste this whole file into Amazon Lightsail "Launch script" when creating the server
# (Ubuntu 24.04). It installs everything; the program itself is added afterwards with:  sudo tacs-finish
set -euxo pipefail
exec > >(tee -a /var/log/tacs-install.log) 2>&1
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
timedatectl set-timezone America/Chicago
apt-get update
apt-get -y upgrade
apt-get -y install python3-venv python3-pip git sqlite3 curl unzip tesseract-ocr ufw fail2ban unattended-upgrades \
                   debian-keyring debian-archive-keyring apt-transport-https gnupg
# Caddy web server (automatic HTTPS)
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get -y install caddy
snap install aws-cli --classic || true
# security basics
ufw default deny incoming; ufw default allow outgoing
ufw allow OpenSSH; ufw allow 80/tcp; ufw allow 443/tcp
ufw --force enable
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl reload ssh || true
# program user and folders
id tacs || useradd --system --create-home --home-dir /home/tacs --shell /bin/bash tacs
mkdir -p /srv/tacs /var/lib/tacs /var/backups/tacs /etc/tacs
chown tacs:tacs /srv/tacs /var/lib/tacs; chmod 700 /var/lib/tacs /var/backups/tacs /etc/tacs
[ -f /etc/tacs/backup.pass ] || (openssl rand -base64 36 > /etc/tacs/backup.pass && chmod 600 /etc/tacs/backup.pass)
# read-only key the server uses to download the program from GitHub
sudo -u tacs mkdir -p /home/tacs/.ssh
[ -f /home/tacs/.ssh/id_ed25519 ] || sudo -u tacs ssh-keygen -t ed25519 -N '' -C 'tacs-server-deploy' -f /home/tacs/.ssh/id_ed25519
sudo -u tacs bash -c 'ssh-keyscan github.com >> /home/tacs/.ssh/known_hosts 2>/dev/null'
python3 -m venv /srv/tacs/venv && chown -R tacs:tacs /srv/tacs/venv
# second step, run after the GitHub key is added:  sudo tacs-finish git@github.com:OWNER/REPO.git
cat > /usr/local/bin/tacs-finish <<'FIN'
#!/bin/bash
set -euo pipefail
REPO="${1:?usage: sudo tacs-finish git@github.com:OWNER/REPO.git}"
[ -d /srv/tacs/app/.git ] || sudo -u tacs git clone --quiet "$REPO" /srv/tacs/app
cd /srv/tacs/app
/srv/tacs/venv/bin/pip install --quiet -r deploy/requirements.txt
install -m 644 deploy/tacs.service /etc/systemd/system/tacs.service
install -m 644 deploy/Caddyfile /etc/caddy/Caddyfile
mkdir -p /var/log/caddy && chown caddy:caddy /var/log/caddy
systemctl daemon-reload && systemctl enable --now tacs
systemctl reload caddy || systemctl restart caddy
cat > /etc/cron.d/tacs <<'CRON'
30 1 * * * root /srv/tacs/app/deploy/backup.sh >> /var/log/tacs-backup.log 2>&1
30 2 * * * root /srv/tacs/app/deploy/update.sh >> /var/log/tacs-update.log 2>&1
CRON
sleep 3; curl -fsS http://127.0.0.1:8000/healthz && echo "  <- TACS is running"
echo "BACKUP PASSWORD (save it somewhere safe, it is needed to open backups):"; cat /etc/tacs/backup.pass
FIN
chmod 755 /usr/local/bin/tacs-finish
echo "SETUP DONE $(date -Is)" > /root/TACS_SETUP_DONE
