# FTP Log Collection Server

## Overview

Docker-based vsftpd server for receiving logs from legacy access control systems over FTP. Each site connects with its own credentials and is jailed (chrooted) to its own directory. All traffic is tunneled securely through NetBird — FTP itself is unencrypted and must never be exposed to the public internet.

The server runs in Docker host network mode to avoid NAT/iptables conflicts with NetBird's firewall rules.

---

## Directory Structure

```
~/vsftpd/
├── docker-compose.yml          # Container orchestration (you:644)
├── Dockerfile                  # FTP server image definition (you:644)
├── .env                        # Secrets and environment config (root:600)
├── add-user.sh                 # Helper to add FTP users (root:700)
├── README.md                   # This file
├── config/
│   ├── vsftpd.conf             # vsftpd configuration (root:644)
│   ├── users.txt               # Virtual user definitions (root:600)
│   └── entrypoint.sh           # Container startup script (root:755)
├── data/                       # Persistent FTP uploads (ftpuser:755)
│   ├── site_example1/
│   └── site_example2/
└── logs/                       # vsftpd transfer and protocol logs (ftpuser:755)
```

---

## Initial Setup

```bash
cd ~
sudo -E bash setup-ftp-server.sh
sudo nano ~/vsftpd/.env                 # Set FTP_PASV_ADDRESS
sudo nano ~/vsftpd/config/users.txt     # Add site users
cd ~/vsftpd && sudo docker compose up -d --build
```

The `-E` flag preserves your working directory when running under sudo.

---

## Managing Users

### Adding a User

**Option A — Helper script (recommended):**

```bash
sudo ~/vsftpd/add-user.sh <username> '<password>' <subfolder>
```

Example:

```bash
sudo ~/vsftpd/add-user.sh site_mainlobby 'Gk#9xQ!mP2w' mainlobby
```

This appends the user to `users.txt` and restarts the FTP container automatically.

**Option B — Manual edit:**

```bash
sudo nano ~/vsftpd/config/users.txt
```

Add a line in the format:

```
username|password|subfolder
```

Example:

```
site_mainlobby|Gk#9xQ!mP2w|mainlobby
site_parking|Yt$4rW!nK8v|parking_garage
```

Then restart the container:

```bash
cd ~/vsftpd && sudo docker compose restart ftp-server
```

### Removing a User

1. Remove the user's line from `users.txt`:

   ```bash
   sudo nano ~/vsftpd/config/users.txt
   ```

2. Restart the container:

   ```bash
   cd ~/vsftpd && sudo docker compose restart ftp-server
   ```

3. Optionally remove their data:

   ```bash
   sudo rm -rf ~/vsftpd/data/<subfolder>
   ```

### Changing a Password

Edit the user's line in `users.txt` with the new password, then restart. Passwords are hashed at container startup — plaintext exists only in `users.txt` (root:600).

---

## User Naming Convention

Recommended format: `site_<location>` with a matching subfolder.

| Username | Password | Subfolder | Description |
|---|---|---|---|
| site_145front | (secure password) | site_145front | 145 Front St access panel |
| site_mainlobby | (secure password) | mainlobby | Main lobby controllers |
| site_parking | (secure password) | parking_garage | Parking garage readers |

---

## Common Operations

### Start

```bash
cd ~/vsftpd && sudo docker compose up -d
```

### Stop

```bash
cd ~/vsftpd && sudo docker compose down
```

### Rebuild (after Dockerfile or entrypoint changes)

```bash
cd ~/vsftpd && sudo docker compose down && sudo docker compose up -d --build
```

### Restart FTP only (after user changes)

```bash
cd ~/vsftpd && sudo docker compose restart ftp-server
```

### View live container logs

```bash
cd ~/vsftpd && sudo docker compose logs -f
```

### View FTP transfer logs

```bash
sudo cat ~/vsftpd/logs/xferlog.log
```

### Check disk usage per site

```bash
sudo du -sh ~/vsftpd/data/*/
```

---

## Log Rotation

A sidecar container runs every 24 hours and deletes files older than the configured retention period from both the upload data and vsftpd's own logs.

**File types cleaned from `data/`:** `.log`, `.csv`, `.txt`

**Retention period** is set in `.env`:

```
LOG_RETENTION_DAYS=120
```

Changes take effect on the next rotation cycle or immediately on container restart.

---

## Network and Connectivity

| Setting | Value |
|---|---|
| FTP control port | 21 |
| Passive port range | 21100–21110 |
| Network mode | Docker host (no NAT) |
| Tunnel | NetBird |

### Passive Address

`FTP_PASV_ADDRESS` in `.env` must be set to this server's NetBird IP. Find it with:

```bash
netbird status | grep IP
```

### Client Connection Settings

Provide these to whoever configures the access control systems:

| Setting | Value |
|---|---|
| Protocol | FTP (plain) |
| Host | Server's NetBird IP |
| Port | 21 |
| Mode | Passive |
| Username | (per-site, from users.txt) |
| Password | (per-site, from users.txt) |

---

## Security Notes

- **No anonymous access** — all connections require authentication.
- **Chroot enforced** — each user is jailed to their own directory.
- **Secrets protected** — `.env` and `users.txt` are chmod 600 root-only.
- **Config mounted read-only** — the container cannot modify its own configuration files.
- **Host network mode** — vsftpd binds directly to the host stack, avoiding Docker NAT conflicts with NetBird's iptables rules.
- **Connection limits** — 20 max clients, 5 per IP, 5-minute idle timeout.
- **FTP is unencrypted** — acceptable only because all traffic is tunneled through NetBird. Never expose ports 21 or 21100–21110 to the public internet.
- **nf_conntrack_ftp** — kernel module loaded for passive mode compatibility through firewalls. Persisted via `/etc/modules-load.d/ftp-conntrack.conf`.

---

## Permissions Reference

| Path | Owner | Mode | Why |
|---|---|---|---|
| `~/vsftpd/` | you | 755 | User can browse |
| `.env` | root | 600 | Contains passive address, retention config |
| `config/users.txt` | root | 600 | Contains FTP credentials |
| `config/vsftpd.conf` | root | 644 | Server config, readable but not user-writable |
| `config/entrypoint.sh` | root | 755 | Startup script, executable |
| `add-user.sh` | root | 700 | Writes to users.txt, restarts Docker |
| `docker-compose.yml` | you | 644 | User can read |
| `Dockerfile` | you | 644 | User can read |
| `data/` | UID 1000 | 755 | ftpuser writes uploads here |
| `logs/` | UID 1000 | 755 | ftpuser writes vsftpd logs here |

---

## Troubleshooting

### Container crash loops

Check the actual error by running interactively:

```bash
cd ~/vsftpd && sudo docker compose down
sudo docker compose run --rm --entrypoint /bin/bash ftp-server
/entrypoint.sh
```

### Exit code 139 (segfault)

Usually PAM-related. Rebuild the image:

```bash
cd ~/vsftpd && sudo docker compose down && sudo docker compose up -d --build
```

### Exit code 1 (silent exit after provisioning)

Likely the bash arithmetic bug with `set -e`. Ensure the entrypoint uses `user_count=$((user_count + 1))` and not `((user_count++))`.

### "secure_chroot_dir not found"

The Dockerfile is missing `mkdir -p /var/run/vsftpd/empty`. Rebuild after verifying the Dockerfile contains that line.

### Login fails (530 error)

Check `users.txt` formatting — must be `username|password|subfolder` with no trailing spaces or Windows line endings:

```bash
sudo cat -A ~/vsftpd/config/users.txt
```

Lines ending in `^M$` have Windows line endings. Fix with:

```bash
sudo sed -i 's/\r$//' ~/vsftpd/config/users.txt
```

### Passive mode hangs from remote clients

1. Verify `FTP_PASV_ADDRESS` in `.env` matches `netbird status | grep IP`.
2. Confirm NetBird policies allow ports 21 and 21100–21110.
3. Verify the `nf_conntrack_ftp` module is loaded: `lsmod | grep nf_conntrack_ftp`.

### Cannot connect over NetBird

Check NetBird peer status:

```bash
netbird status -d
```

Ensure the client peer shows **Connected** and the correct NetBird groups/policies are applied.

### Disk full

```bash
sudo du -sh ~/vsftpd/data/*/
```

Consider lowering `LOG_RETENTION_DAYS` in `.env` or manually removing old data.
