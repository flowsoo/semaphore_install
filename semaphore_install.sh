#!/bin/bash

set -e

# === VARIABLES ===
ANSIBLE_USER="ansible"
ANSIBLE_PASSWORD="AnsiblePass123!"

SEMAPHORE_DB="semaphore"
SEMAPHORE_DB_USER="semaphore"
SEMAPHORE_DB_PASSWORD="SemaphoreDBPass123!"
MYSQL_ROOT_PASSWORD="MySQLRootPass123!"

SEMAPHORE_DIR="/opt/semaphore"
SEMAPHORE_BIN="$SEMAPHORE_DIR/semaphore"
SEMAPHORE_CONFIG="/etc/semaphore/config.json"
SEMAPHORE_PORT="3000"

ADMIN_USER="admin"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="admin123"

# === i) Create Ansible user ===
echo "### i) Creating Ansible user"
useradd -m -s /bin/bash $ANSIBLE_USER || true
echo "$ANSIBLE_USER:$ANSIBLE_PASSWORD" | chpasswd

# === ii) Install Ansible ===
echo "### ii) Installing Ansible (from official apt repo)"
apt update
apt install -y ansible

# === iii) Install required packages ===
echo "### iii) Installing required packages"
apt install -y curl git mariadb-server mariadb-client expect jq ufw

# Open Port 3000
ufw allow 3000
ufw allow 3306

# === iv) Secure MariaDB ===
echo "### iv) Securing MariaDB"
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation

expect \"Enter current password for root (enter for none):\"
send \"\r\"

expect \"Set root password?\"
send \"Y\r\"

expect \"New password:\"
send \"$MYSQL_ROOT_PASSWORD\r\"

expect \"Re-enter new password:\"
send \"$MYSQL_ROOT_PASSWORD\r\"

expect \"Remove anonymous users?\"
send \"Y\r\"

expect \"Disallow root login remotely?\"
send \"Y\r\"

expect \"Remove test database and access to it?\"
send \"Y\r\"

expect \"Reload privilege tables now?\"
send \"Y\r\"

expect eof
")

echo "$SECURE_MYSQL"

# === v) Create Semaphore DB and user ===
echo "### v) Creating Semaphore DB and user"
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS $SEMAPHORE_DB;
CREATE USER IF NOT EXISTS '$SEMAPHORE_DB_USER'@'localhost' IDENTIFIED BY '$SEMAPHORE_DB_PASSWORD';
GRANT ALL PRIVILEGES ON $SEMAPHORE_DB.* TO '$SEMAPHORE_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# === vi) Download Semaphore ===
echo "### vi) Downloading Semaphore latest release"
DOWNLOAD_URL=$(curl -s https://api.github.com/repos/semaphoreui/semaphore/releases/latest | jq -r '.assets[] | select(.name | endswith("_linux_amd64.tar.gz")) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ERROR: Semaphore download URL not found."
    exit 1
fi

mkdir -p $SEMAPHORE_DIR
cd /tmp
curl -sL "$DOWNLOAD_URL" -o semaphore.tar.gz
tar -xzf semaphore.tar.gz -C $SEMAPHORE_DIR
chmod +x $SEMAPHORE_BIN
rm semaphore.tar.gz

# === vii) Create config.json manually ===
echo "### vii) Creating Semaphore config.json"
mkdir -p "$(dirname "$SEMAPHORE_CONFIG")"

cat <<EOF > "$SEMAPHORE_CONFIG"
{
  "mysql": {
    "host": "127.0.0.1:3306",
    "user": "$SEMAPHORE_DB_USER",
    "pass": "$SEMAPHORE_DB_PASSWORD",
    "name": "$SEMAPHORE_DB",
    "options": {
      "interpolateParams": "true"
    }
  },
  "dialect": "mysql",
  "port": ":$SEMAPHORE_PORT",
  "tmp_path": "/tmp/semaphore",
  "cookie_hash": "$(head -c 16 /dev/urandom | base64)",
  "cookie_encryption": "$(head -c 16 /dev/urandom | base64)",
  "email_alert": false,
  "telegram_alert": false,
  "slack_alert": false,
  "ldap_enable": false,
  "web_host": "",
  "playbook_path": "/tmp/semaphore"
}
EOF

# === viii) Run DB migration ===
echo "### viii) Migrating DB"
/opt/semaphore/semaphore migrate --config "$SEMAPHORE_CONFIG"

# === ix) Create admin user ===
echo "### ix) Creating Semaphore admin user"
/opt/semaphore/semaphore user add --config "$SEMAPHORE_CONFIG" \
  --admin --login "$ADMIN_USER" --name "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$ADMIN_PASS"

# === x) Create systemd service ===
echo "### x) Creating systemd service for Semaphore"
cat <<EOF > /etc/systemd/system/semaphore.service
[Unit]
Description=Semaphore Ansible UI
After=network.target mariadb.service

[Service]
ExecStart=$SEMAPHORE_BIN server --config $SEMAPHORE_CONFIG
Restart=always
User=root
Environment=SEMAPHORE_CONFIG=$SEMAPHORE_CONFIG

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable semaphore
systemctl start semaphore

echo
echo "Semaphore installation complete."
echo "Access the web UI at: http://<your-server-ip>:3000"
echo "Login with: $ADMIN_USER / $ADMIN_PASS"
