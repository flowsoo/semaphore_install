#!/bin/bash

set -e

# Variables
ANSIBLE_USER="ansible"
ANSIBLE_PASSWORD="AnsiblePass123!"
SEMAPHORE_DB="semaphore"
SEMAPHORE_DB_USER="semaphore"
SEMAPHORE_DB_PASSWORD="SemaphoreDBPass123!"
MYSQL_ROOT_PASSWORD="MySQLRootPass123!"
SEMAPHORE_DIR="/opt/semaphore"
SEMAPHORE_CONFIG="/etc/semaphore/config.json"

# i) Create an Ansible user with password
echo "### i) Creating Ansible user"
useradd -m -s /bin/bash $ANSIBLE_USER
echo "$ANSIBLE_USER:$ANSIBLE_PASSWORD" | chpasswd

# ii) Install Ansible
echo "### ii) Installing Ansible"
apt update
apt install -y software-properties-common
add-apt-repository --yes --update ppa:ansible/ansible
apt install -y ansible

# iii) Install all required packages (use mariadb for the database)
echo "### iii) Installing required packages"
apt update
apt install -y curl git mariadb-server mariadb-client expect jq

# iv) Install mysql (MariaDB already covers this step)
echo "### iv) Ensuring MariaDB is installed (mysql alternative)"
# Already handled in step iii

# v) Secure mysql, filling out all fields automatically
echo "### v) Securing MariaDB"

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

# vi) Create the required database and user for semaphore
echo "### vi) Creating Semaphore database and user"
mysql -u root -p$MYSQL_ROOT_PASSWORD <<MYSQL_SCRIPT
CREATE DATABASE $SEMAPHORE_DB;
CREATE USER '$SEMAPHORE_DB_USER'@'localhost' IDENTIFIED BY '$SEMAPHORE_DB_PASSWORD';
GRANT ALL PRIVILEGES ON $SEMAPHORE_DB.* TO '$SEMAPHORE_DB_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# vii) Download and extract the latest stable release of semaphore that ends in _linux_amd64.tar.gz
echo "### vii) Downloading and extracting Semaphore release (ending in _linux_amd64.tar.gz)"

DOWNLOAD_URL=$(curl -s https://api.github.com/repos/semaphoreui/semaphore/releases | jq -r '
    .[] 
    | .assets[] 
    | select(.name | endswith("_linux_amd64.tar.gz")) 
    | .browser_download_url' | head -n1)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ERROR: Could not find suitable Semaphore release."
    exit 1
fi

echo "Found release: $DOWNLOAD_URL"

mkdir -p $SEMAPHORE_DIR
cd /tmp
curl -sL "$DOWNLOAD_URL" -o semaphore_linux_amd64.tar.gz

echo "Extracting to $SEMAPHORE_DIR"
tar -xzf semaphore_linux_amd64.tar.gz -C $SEMAPHORE_DIR
rm semaphore_linux_amd64.tar.gz
chmod +x $SEMAPHORE_DIR/semaphore

# viii) Run the setup script, and fill out the interactive fields as required
echo "### viii) Running Semaphore setup"
cat <<EOF | $SEMAPHORE_DIR/semaphore setup
$SEMAPHORE_DB_USER
$SEMAPHORE_DB_PASSWORD
localhost
3306
$SEMAPHORE_DB
admin
admin
admin@example.com
admin123
EOF

# ix) Start Semaphore
echo "### ix) Starting Semaphore"
$SEMAPHORE_DIR/semaphore -config $SEMAPHORE_CONFIG &

# x) Create the systemd service file to run semaphore
echo "### x) Creating systemd service"
cat <<EOF > /etc/systemd/system/semaphore.service
[Unit]
Description=Semaphore Ansible UI
After=network.target mariadb.service

[Service]
ExecStart=$SEMAPHORE_DIR/semaphore -config $SEMAPHORE_CONFIG
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

echo "Semaphore installation complete."
echo "Access the web UI at http://<your-server-ip>:3000"
echo "Login with: admin / admin123"
