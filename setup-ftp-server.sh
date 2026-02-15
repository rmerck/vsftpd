#!/usr/bin/env bash
# =============================================================================
# FTP Log Collection Server — Setup Script
# Deploys a vsftpd-based FTP server via Docker Compose (host network mode)
# on Debian Trixie with Docker and Docker Compose.
#
# Features:
#   - Host network mode (no NAT/iptables conflicts with NetBird)
#   - Virtual users with PAM authentication (pam_pwdfile)
#   - Chrooted per-site directories
#   - Passive FTP with configurable address and port range
#   - Dynamic user management via users.txt + helper script
#   - Secrets isolated in .env (never in compose file)
#   - Persistent data and log volumes
#   - Log rotation sidecar (120-day default retention)
#
# Usage: sudo bash setup-ftp-server.sh
# =============================================================================

set -euo pipefail

# --- Configuration ---
FTP_BASE="/opt/ftp-server"
FTP_DATA="${FTP_BASE}/data"
FTP_CONFIG="${FTP_BASE}/config"
FTP_LOGS="${FTP_BASE}/logs"

echo "============================================="
echo " FTP Log Collection Server — Setup"
echo " Base: ${FTP_BASE}"
echo "============================================="

# --- Preflight ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script with sudo."
    exit 1
fi

for cmd in docker; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: ${cmd} is not installed."
        exit 1
    fi
done

if ! docker compose version &>/dev/null; then
    echo "ERROR: Docker Compose plugin is not installed."
    exit 1
fi

# --- Directory structure ---
echo "[1/9] Creating directories..."
mkdir -p "${FTP_DATA}"
mkdir -p "${FTP_CONFIG}"
mkdir -p "${FTP_LOGS}"

# --- .env ---
echo "[2/9] Creating .env..."
if [[ -f "${FTP_BASE}/.env" ]]; then
    echo "  .env exists — skipping. Delete to regenerate."
else
    cat > "${FTP_BASE}/.env" <<'EOF'
# =============================================================================
# FTP Server — Environment Variables
# This file contains secrets. Do not commit or share it.
# =============================================================================

# The IP address vsftpd advertises to clients for passive data connections.
# Set this to your NetBird tunnel IP (run: netbird status | grep IP).
# REQUIRED — passive mode will not work without this.
FTP_PASV_ADDRESS=CHANGE_ME

# Passive data port range. Clients connect to a port in this range for
# directory listings and file transfers. 11 ports = 11 concurrent transfers.
FTP_PASV_MIN_PORT=21100
FTP_PASV_MAX_PORT=21110

# Delete uploaded log files and vsftpd logs older than this many days.
LOG_RETENTION_DAYS=120
EOF
    chmod 600 "${FTP_BASE}/.env"
    echo "  Created. >>> Set FTP_PASV_ADDRESS to your NetBird IP <<<"
fi

# --- users.txt ---
echo "[3/9] Creating users.txt..."
if [[ -f "${FTP_CONFIG}/users.txt" ]]; then
    echo "  users.txt exists — skipping."
else
    cat > "${FTP_CONFIG}/users.txt" <<'EOF'
# =============================================================================
# FTP Virtual Users
#
# Format:  username|password|subfolder
#
#   username   — Login name (letters, numbers, underscores only)
#   password   — Plain text here; hashed automatically at container start
#   subfolder  — Directory under /opt/ftp-server/data/ for this user's uploads
#
# Examples:
#   site_mainlobby|Xk!9mQ#pW2v|mainlobby
#   site_parking|Yt$4rW!nK8v|parking_garage
#
# After editing, restart the FTP container:
#   cd /opt/ftp-server && sudo docker compose restart ftp-server
# =============================================================================
EOF
    chmod 600 "${FTP_CONFIG}/users.txt"
    echo "  Created. Add your site users before starting."
fi

# --- vsftpd.conf ---
echo "[4/9] Writing vsftpd.conf..."
cat > "${FTP_CONFIG}/vsftpd.conf" <<'EOF'
# =============================================================================
# vsftpd — security-hardened configuration for log collection
# =============================================================================

# Listener — binds on all interfaces; NetBird ACLs control access.
listen=YES
listen_ipv6=NO
listen_port=21

# Access control
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022

# Virtual users mapped to a single system account
guest_enable=YES
guest_username=ftpuser
virtual_use_local_privs=YES
user_sub_token=$USER
local_root=/home/ftpdata/$USER
pam_service_name=vsftpd_virtual

# Chroot — jail each user to their own directory
chroot_local_user=YES
allow_writeable_chroot=YES
hide_ids=YES
secure_chroot_dir=/var/run/vsftpd/empty

# Passive mode — address and ports are injected by entrypoint from .env
pasv_enable=YES
pasv_addr_resolve=NO
# Placeholders replaced at container start:
pasv_min_port=21100
pasv_max_port=21110

# Security hardening
chmod_enable=NO
ascii_upload_enable=NO
ascii_download_enable=NO
async_abor_enable=NO
ls_recurse_enable=NO
connect_from_port_20=NO

# Connection limits
max_clients=20
max_per_ip=5
idle_session_timeout=300
data_connection_timeout=120

# Logging
xferlog_enable=YES
xferlog_std_format=NO
log_ftp_protocol=YES
dual_log_enable=YES
vsftpd_log_file=/var/log/vsftpd/vsftpd.log
xferlog_file=/var/log/vsftpd/xferlog.log

# Banner
ftpd_banner=Authorized access only. All sessions are logged.

# Container compatibility
seccomp_sandbox=NO
EOF
echo "  Created."

# --- Dockerfile ---
echo "[5/9] Writing Dockerfile..."
cat > "${FTP_BASE}/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        vsftpd \
        libpam-pwdfile \
        openssl \
    && rm -rf /var/lib/apt/lists/*

# System user that all virtual FTP users map to
RUN useradd -m -d /home/ftpdata -s /usr/sbin/nologin ftpuser

# Directories vsftpd expects
RUN mkdir -p /var/log/vsftpd && chown ftpuser:ftpuser /var/log/vsftpd
RUN mkdir -p /var/run/vsftpd/empty

# PAM config for virtual user authentication
RUN printf '%s\n' \
    'auth required pam_pwdfile.so pwdfile /etc/vsftpd/passwd' \
    'account required pam_permit.so' \
    > /etc/pam.d/vsftpd_virtual

COPY config/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE
echo "  Created."

# --- entrypoint.sh ---
echo "[6/9] Writing entrypoint.sh..."
cat > "${FTP_CONFIG}/entrypoint.sh" <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

USERS_FILE="/etc/vsftpd/users.txt"
PASSWD_FILE="/etc/vsftpd/passwd"
VSFTPD_CONF_SRC="/etc/vsftpd/vsftpd.conf"
VSFTPD_CONF="/tmp/vsftpd.conf"
DATA_DIR="/home/ftpdata"

echo "=== FTP Server Starting ==="

# ---- Provision virtual users ----
echo "Provisioning users..."
: > "${PASSWD_FILE}"

user_count=0

if [[ -f "${USERS_FILE}" ]]; then
    while IFS='|' read -r username password subfolder; do
        # Skip comments and blanks
        [[ -z "${username}" || "${username}" =~ ^[[:space:]]*# ]] && continue

        username=$(echo "${username}" | xargs)
        password=$(echo "${password}" | xargs)
        subfolder=$(echo "${subfolder}" | xargs)

        if [[ -z "${username}" || -z "${password}" || -z "${subfolder}" ]]; then
            echo "  WARNING: Skipping malformed line for '${username}'"
            continue
        fi

        # Hash password and write to passwd file
        hash=$(openssl passwd -1 "${password}")
        echo "${username}:${hash}" >> "${PASSWD_FILE}"

        # Create and own user directory
        user_dir="${DATA_DIR}/${subfolder}"
        mkdir -p "${user_dir}"
        chown ftpuser:ftpuser "${user_dir}"
        chmod 755 "${user_dir}"

        # If username differs from subfolder, symlink for vsftpd $USER token
        if [[ "${username}" != "${subfolder}" ]]; then
            ln -sfn "${subfolder}" "${DATA_DIR}/${username}"
        fi

        echo "  User: ${username} -> ${subfolder}/"
        ((user_count++))

    done < "${USERS_FILE}"
else
    echo "  WARNING: ${USERS_FILE} not found."
fi

chmod 600 "${PASSWD_FILE}"
echo "  ${user_count} user(s) provisioned."

# ---- Build runtime vsftpd config ----
# Copy the read-only mounted config to a writable location, then inject
# environment variables for passive mode.
cp "${VSFTPD_CONF_SRC}" "${VSFTPD_CONF}"

if [[ -n "${FTP_PASV_ADDRESS:-}" && "${FTP_PASV_ADDRESS}" != "CHANGE_ME" ]]; then
    sed -i '/^pasv_address=/d' "${VSFTPD_CONF}"
    echo "pasv_address=${FTP_PASV_ADDRESS}" >> "${VSFTPD_CONF}"
    echo "Passive address: ${FTP_PASV_ADDRESS}"
else
    echo "WARNING: FTP_PASV_ADDRESS is not set. Passive mode may not work for remote clients."
fi

if [[ -n "${FTP_PASV_MIN_PORT:-}" ]]; then
    sed -i "s/^pasv_min_port=.*/pasv_min_port=${FTP_PASV_MIN_PORT}/" "${VSFTPD_CONF}"
fi
if [[ -n "${FTP_PASV_MAX_PORT:-}" ]]; then
    sed -i "s/^pasv_max_port=.*/pasv_max_port=${FTP_PASV_MAX_PORT}/" "${VSFTPD_CONF}"
fi

echo "Passive ports: ${FTP_PASV_MIN_PORT:-21100}-${FTP_PASV_MAX_PORT:-21110}"

echo "=== Starting vsftpd ==="
exec /usr/sbin/vsftpd "${VSFTPD_CONF}"
ENTRYPOINT
chmod +x "${FTP_CONFIG}/entrypoint.sh"
echo "  Created."

# --- docker-compose.yml ---
echo "[7/9] Writing docker-compose.yml..."
cat > "${FTP_BASE}/docker-compose.yml" <<COMPOSE
services:
  ftp-server:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ftp-server
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    volumes:
      - ${FTP_DATA}:/home/ftpdata:rw
      - ${FTP_CONFIG}/vsftpd.conf:/etc/vsftpd/vsftpd.conf:ro
      - ${FTP_CONFIG}/users.txt:/etc/vsftpd/users.txt:ro
      - ${FTP_CONFIG}/entrypoint.sh:/entrypoint.sh:ro
      - ${FTP_LOGS}:/var/log/vsftpd:rw
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  log-rotation:
    image: debian:bookworm-slim
    container_name: ftp-log-rotation
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ${FTP_DATA}:/data:rw
      - ${FTP_LOGS}:/logs:rw
    entrypoint: >
      /bin/bash -c '
        echo "Log rotation started (retention: \${LOG_RETENTION_DAYS:-120} days)";
        while true; do
          echo "[rotation] Cleanup at \$\$(date -u +%Y-%m-%dT%H:%M:%SZ)";
          find /data -type f \( -name "*.log" -o -name "*.csv" -o -name "*.txt" \) -mtime +\$${LOG_RETENTION_DAYS:-120} -print -delete 2>/dev/null || true;
          find /logs -type f -name "*.log" -mtime +\$${LOG_RETENTION_DAYS:-120} -print -delete 2>/dev/null || true;
          echo "[rotation] Next run in 24h";
          sleep 86400;
        done
      '
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"
COMPOSE
echo "  Created."

# --- add-user.sh ---
echo "[8/9] Writing add-user.sh..."
cat > "${FTP_BASE}/add-user.sh" <<'ADDUSER'
#!/usr/bin/env bash
# =============================================================================
# Add an FTP user and restart the server to apply.
# Usage: sudo ./add-user.sh <username> <password> <subfolder>
# =============================================================================
set -euo pipefail

USERS_FILE="/opt/ftp-server/config/users.txt"
COMPOSE_DIR="/opt/ftp-server"

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <username> <password> <subfolder>"
    echo ""
    echo "  username   Letters, numbers, underscores only."
    echo "  password   Wrap in single quotes if it contains special characters."
    echo "  subfolder  Directory name under /opt/ftp-server/data/."
    echo ""
    echo "Example:"
    echo "  sudo $0 site_lobby 'Xk!9mQ#pW2v' lobby"
    exit 1
fi

USERNAME="$1"
PASSWORD="$2"
SUBFOLDER="$3"

if [[ ! "${USERNAME}" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: Username must contain only letters, numbers, and underscores."
    exit 1
fi

if grep -q "^${USERNAME}|" "${USERS_FILE}" 2>/dev/null; then
    echo "ERROR: User '${USERNAME}' already exists."
    exit 1
fi

echo "${USERNAME}|${PASSWORD}|${SUBFOLDER}" >> "${USERS_FILE}"
echo "Added: ${USERNAME} -> ${SUBFOLDER}/"

echo "Restarting FTP server..."
cd "${COMPOSE_DIR}" && sudo docker compose restart ftp-server

echo "Done. '${USERNAME}' is now active."
ADDUSER
chmod 700 "${FTP_BASE}/add-user.sh"
echo "  Created."

# --- Permissions ---
echo "[9/9] Setting permissions..."

# Base directory owned by root
chown -R root:root "${FTP_BASE}"

# Data directory owned by UID 1000 (ftpuser in the container)
chown -R 1000:1000 "${FTP_DATA}"
chmod 755 "${FTP_DATA}"

# Logs writable by ftpuser
chown -R 1000:1000 "${FTP_LOGS}"
chmod 755 "${FTP_LOGS}"

# Config directory
chmod 750 "${FTP_CONFIG}"
chmod 600 "${FTP_CONFIG}/users.txt"
chmod 644 "${FTP_CONFIG}/vsftpd.conf"
chmod 755 "${FTP_CONFIG}/entrypoint.sh"

# Secrets
chmod 600 "${FTP_BASE}/.env"

# Compose and Dockerfile
chmod 644 "${FTP_BASE}/docker-compose.yml"
chmod 644 "${FTP_BASE}/Dockerfile"

# Helper script
chmod 700 "${FTP_BASE}/add-user.sh"

# Load FTP connection tracking module (passive mode through firewalls)
if ! lsmod | grep -q nf_conntrack_ftp; then
    modprobe nf_conntrack_ftp 2>/dev/null || true
fi
echo "nf_conntrack_ftp" > /etc/modules-load.d/ftp-conntrack.conf 2>/dev/null || true

echo ""
echo "============================================="
echo " Setup Complete"
echo "============================================="
echo ""
echo " ${FTP_BASE}/"
echo " ├── docker-compose.yml"
echo " ├── Dockerfile"
echo " ├── .env                  ← SET FTP_PASV_ADDRESS"
echo " ├── add-user.sh           ← Add users: sudo ./add-user.sh"
echo " ├── config/"
echo " │   ├── vsftpd.conf"
echo " │   ├── users.txt         ← ADD YOUR SITE USERS"
echo " │   └── entrypoint.sh"
echo " ├── data/                 ← FTP uploads (persistent)"
echo " └── logs/                 ← vsftpd logs (persistent)"
echo ""
echo " Next steps:"
echo ""
echo "   1. Set your NetBird IP:"
echo "      sudo nano ${FTP_BASE}/.env"
echo ""
echo "   2. Add site users:"
echo "      sudo nano ${FTP_CONFIG}/users.txt"
echo "      Format: username|password|subfolder"
echo ""
echo "   3. Build and start:"
echo "      cd ${FTP_BASE} && sudo docker compose up -d --build"
echo ""
echo "   4. Verify:"
echo "      sudo docker compose logs -f"
echo "      ftp localhost"
echo ""
echo "   5. Add more users later:"
echo "      sudo ${FTP_BASE}/add-user.sh site_name 'password' folder_name"
echo ""
echo " Log rotation runs daily, removing files older than 120 days."
echo "============================================="
