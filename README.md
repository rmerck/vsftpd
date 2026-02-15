# vsftpd Docker FTP Server

A Docker-based vsftpd server designed for collecting logs from legacy systems that only support plain FTP. Each client authenticates with unique credentials and is chrooted to its own directory. Intended for use behind a secure tunnel (e.g., WireGuard, NetBird, Tailscale) — FTP traffic is unencrypted and should never be exposed to the public internet.

## Features

- **Host network mode** — avoids Docker NAT/iptables conflicts with overlay network tunnels
- **Virtual users** — PAM authentication via `pam_pwdfile`, no system accounts per client
- **Chrooted directories** — each user is jailed to their own upload folder
- **Passive FTP** — configurable passive address and port range
- **Dynamic user management** — add/remove users via a text file or helper script, no rebuild required
- **Secrets isolation** — credentials and config kept in `.env` and `users.txt`, never in the compose file
- **Persistent storage** — upload data and logs survive container restarts
- **Log rotation** — sidecar container removes old files on a configurable retention schedule

## Requirements

- Debian 12+ (tested on Debian Trixie)
- Docker Engine with Compose plugin
- A secure network tunnel if accessing remotely (FTP is unencrypted)

## Quick Start

```bash
cd ~
sudo -E bash setup-ftp-server.sh
```

The `-E` flag preserves your working directory under sudo. The script creates `~/vsftpd/` with all necessary files.

```bash
sudo nano ~/vsftpd/.env                 # Set FTP_PASV_ADDRESS
sudo nano ~/vsftpd/config/users.txt     # Add users
cd ~/vsftpd && sudo docker compose up -d --build
```

## Directory Structure

```
~/vsftpd/
├── docker-compose.yml          # Container orchestration
├── Dockerfile                  # vsftpd image definition
├── .env                        # Environment variables and secrets
├── add-user.sh                 # Helper script to add users
├── config/
│   ├── vsftpd.conf             # vsftpd configuration
│   ├── users.txt               # Virtual user definitions
│   └── entrypoint.sh           # Container startup / user provisioning
├── data/                       # Persistent uploads (one subfolder per user)
└── logs/                       # vsftpd transfer and protocol logs
```

## Configuration

### Environment Variables (`.env`)

| Variable | Description | Default |
|---|---|---|
| `FTP_PASV_ADDRESS` | IP address advertised to clients for passive data connections | `CHANGE_ME` |
| `FTP_PASV_MIN_PORT` | Start of passive port range | `21100` |
| `FTP_PASV_MAX_PORT` | End of passive port range | `21110` |
| `LOG_RETENTION_DAYS` | Delete uploaded files older than this many days | `120` |

`FTP_PASV_ADDRESS` must be set to the IP your clients will reach the server on (e.g., your tunnel IP). Find it with your tunnel client's status command.

### Users (`config/users.txt`)

One user per line in the format:

```
username|password|subfolder
```

- `username` — alphanumeric and underscores only
- `password` — plaintext here, hashed automatically at container startup
- `subfolder` — directory created under `data/` for this user's uploads

Example:

```
location_a|S3cur3P@ss!|location_a
location_b|An0th3rP@ss|location_b
```

Passwords are hashed with `openssl passwd -1` at container start. The `users.txt` file should be protected (the setup script sets it to `root:600`).

## User Management

### Add a user (helper script)

```bash
sudo ~/vsftpd/add-user.sh <username> '<password>' <subfolder>
```

Appends to `users.txt` and restarts the FTP container automatically.

### Add a user (manual)

Edit `users.txt` and restart:

```bash
sudo nano ~/vsftpd/config/users.txt
cd ~/vsftpd && sudo docker compose restart ftp-server
```

### Remove a user

Delete the line from `users.txt`, restart, and optionally remove the data:

```bash
sudo nano ~/vsftpd/config/users.txt
cd ~/vsftpd && sudo docker compose restart ftp-server
sudo rm -rf ~/vsftpd/data/<subfolder>   # optional
```

### Change a password

Edit the password in `users.txt` and restart.

## Operations

| Action | Command |
|---|---|
| Start | `cd ~/vsftpd && sudo docker compose up -d` |
| Stop | `cd ~/vsftpd && sudo docker compose down` |
| Rebuild | `cd ~/vsftpd && sudo docker compose down && sudo docker compose up -d --build` |
| Restart FTP only | `cd ~/vsftpd && sudo docker compose restart ftp-server` |
| View logs | `cd ~/vsftpd && sudo docker compose logs -f` |
| Transfer logs | `sudo cat ~/vsftpd/logs/xferlog.log` |
| Disk usage | `sudo du -sh ~/vsftpd/data/*/` |

## Log Rotation

A sidecar container runs every 24 hours and deletes files matching `*.log`, `*.csv`, and `*.txt` older than `LOG_RETENTION_DAYS` from both `data/` and `logs/`.

Adjust retention in `.env` and restart the rotation container to apply immediately.

## Security

- Anonymous access is disabled.
- Each user is chrooted to their own directory and cannot see other users' data.
- `.env` and `users.txt` are `chmod 600 root:root`.
- Config files are mounted read-only into the container.
- Unnecessary FTP commands (CHMOD, ASCII, recursive listing) are disabled.
- Connection limits: 20 max clients, 5 per IP, 5-minute idle timeout, 2-minute data timeout.
- `nf_conntrack_ftp` kernel module is loaded for passive mode compatibility.
- **FTP is unencrypted.** This setup assumes all traffic is routed through a secure tunnel. Do not expose the FTP or passive ports to untrusted networks.

## Permissions

The setup script assigns ownership as follows:

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `~/vsftpd/` | invoking user | 755 | Browsable by the admin user |
| `.env` | root | 600 | Contains environment secrets |
| `config/users.txt` | root | 600 | Contains FTP credentials |
| `config/vsftpd.conf` | root | 644 | Server config, not user-writable |
| `config/entrypoint.sh` | root | 755 | Startup script |
| `add-user.sh` | root | 700 | Modifies users.txt, restarts Docker |
| `docker-compose.yml` | invoking user | 644 | Readable by admin |
| `Dockerfile` | invoking user | 644 | Readable by admin |
| `data/` | UID 1000 | 755 | Container ftpuser writes here |
| `logs/` | UID 1000 | 755 | Container ftpuser writes here |

## Troubleshooting

### Container crash loops

Run interactively to see the actual error:

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

### Exit code 1 (silent exit after user provisioning)

Bash arithmetic with `set -e`: `((var++))` returns exit code 1 when the variable is 0. The entrypoint uses `var=$((var + 1))` to avoid this. Verify with:

```bash
grep 'user_count' ~/vsftpd/config/entrypoint.sh
```

### "secure_chroot_dir not found"

Ensure the Dockerfile contains `mkdir -p /var/run/vsftpd/empty` and rebuild.

### Login fails (530 error)

Check `users.txt` formatting and line endings:

```bash
sudo cat -A ~/vsftpd/config/users.txt
```

Lines ending in `^M$` have Windows line endings. Fix:

```bash
sudo sed -i 's/\r$//' ~/vsftpd/config/users.txt
```

### Passive mode hangs

1. Verify `FTP_PASV_ADDRESS` in `.env` matches the server's tunnel IP.
2. Ensure firewall/tunnel policies allow the passive port range.
3. Check the conntrack module: `lsmod | grep nf_conntrack_ftp`.

### Cannot connect remotely

Verify both the client and server are connected to the tunnel and that the correct access policies are applied.

## License

MIT
