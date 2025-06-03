#!/bin/bash
set -e

# -------------------------------
# Configurable Variables
# -------------------------------
SONAR_DB_PASSWORD="P@ltech@123$"
DISK_DEVICE="/dev/nvme1n1"
DISK_MOUNT_PATH="/mnt/sonar-db-disk"
PGSQL_DATA_PATH="$DISK_MOUNT_PATH/sonar-db"

# -------------------------------
# Update system packages
# -------------------------------
echo "[+] Updating system packages..."
sudo yum update -y

# -------------------------------
# Install dependencies
# -------------------------------
echo "[+] Installing required packages..."
sudo yum install -y java-17-amazon-corretto-devel wget unzip curl rsync postgresql-server postgresql-contrib

# -------------------------------
# Mount secondary disk
# -------------------------------
echo "[+] Mounting secondary disk..."
if ! mount | grep "$DISK_MOUNT_PATH" > /dev/null; then
    sudo mkdir -p "$DISK_MOUNT_PATH"
    sudo mount "$DISK_DEVICE" "$DISK_MOUNT_PATH"
    echo "[+] Disk mounted at $DISK_MOUNT_PATH"
else
    echo "[+] Disk already mounted."
fi

# -------------------------------
# Prepare PostgreSQL data directory
# -------------------------------
echo "[+] Resetting PostgreSQL data directory on secondary disk..."
sudo systemctl stop postgresql || true
sudo rm -rf "$PGSQL_DATA_PATH"
sudo mkdir -p "$PGSQL_DATA_PATH"
sudo chown postgres:postgres "$PGSQL_DATA_PATH"
sudo chmod 700 "$PGSQL_DATA_PATH"

# -------------------------------
# Initialize PostgreSQL database
# -------------------------------
echo "[+] Initializing PostgreSQL..."
sudo -u postgres /usr/bin/initdb -D "$PGSQL_DATA_PATH"

# -------------------------------
# Symlink PostgreSQL data directory
# -------------------------------
echo "[+] Creating symlink to PostgreSQL data directory..."
sudo rm -rf /var/lib/pgsql/data
sudo ln -s "$PGSQL_DATA_PATH" /var/lib/pgsql/data

# -------------------------------
# Start PostgreSQL
# -------------------------------
echo "[+] Starting PostgreSQL..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

# -------------------------------
# Configure PostgreSQL for SonarQube
# -------------------------------
echo "[+] Creating sonar user and database..."
sudo -u postgres psql <<EOF
CREATE USER sonar WITH ENCRYPTED PASSWORD '${SONAR_DB_PASSWORD}';
CREATE DATABASE sonarqube OWNER sonar;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# -------------------------------
# Install SonarQube
# -------------------------------
echo "[+] Installing SonarQube..."
cd /tmp
SONAR_VERSION="25.5.0.107428"
SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

# Download with fallback
if ! curl --head --silent --fail "$SONAR_URL" > /dev/null; then
    echo "[!] Unable to download SonarQube from $SONAR_URL"
    exit 1
fi

wget "$SONAR_URL"
unzip "$SONAR_ZIP"
sudo mv "sonarqube-${SONAR_VERSION}" /opt/sonarqube
sudo useradd -r -s /bin/false sonar || true
sudo chown -R sonar:sonar /opt/sonarqube

# -------------------------------
# Configure SonarQube
# -------------------------------
echo "[+] Configuring SonarQube..."
sudo tee -a /opt/sonarqube/conf/sonar.properties > /dev/null <<EOF
sonar.jdbc.username=sonar
sonar.jdbc.password=${SONAR_DB_PASSWORD}
sonar.jdbc.url=jdbc:postgresql://localhost:5432/sonarqube
EOF

# -------------------------------
# Create systemd service
# -------------------------------
echo "[+] Creating systemd service for SonarQube..."
sudo tee /etc/systemd/system/sonar.service > /dev/null <<EOF
[Unit]
Description=SonarQube service
After=syslog.target network.target postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable sonar
sudo systemctl start sonar

# -------------------------------
# Tuning system settings
# -------------------------------
echo "[+] Applying system limits for SonarQube..."
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=65536" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo "ulimit -n 65536" | sudo tee -a /etc/security/limits.conf
echo "ulimit -u 4096" | sudo tee -a /etc/security/limits.conf

# -------------------------------
# Done
# -------------------------------
echo "[✓] SonarQube installed successfully."
echo "→ Access via http://<your-ip>:9000 (admin/admin)"

