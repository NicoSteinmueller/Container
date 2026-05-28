# SFTPGo Container

SFTPGo is a fully-featured SFTP server with optional FTP/DAV support and web UI for file management and user administration.

## Migration to Default Template (v2.0)

This service has been refactored to use the modern three-file Docker Compose template structure:

- **compose.yml** - Base configuration with best practices (init, restart policy, healthchecks, resource limits, security settings)
- **compose.override.yml** - Local development settings (user 1000:1000, published ports)
- **compose.prod.yml** - Production settings (user 99:100, bind mounts, Traefik integration, network configuration)

### Configuration

1. Copy `example.env` to `.env` and set strong passwords:
   ```bash
   cp example.env .env
   ```

2. Create required directories on the host:
   ```bash
   mkdir -p /mnt/user/appdata/sftpgo/postgres
   mkdir -p /mnt/user/data/sftpgo/data
   mkdir -p /mnt/user/data/sftpgo/backups
   ```

### Running

**Development (with local ports):**
```bash
docker compose up -d
# Web UI: http://localhost:8080
# SFTP: localhost:2022
# FTP: localhost:21
```

**Production (with Traefik):**
```bash
docker compose -f compose.yml -f compose.prod.yml up -d
# Access via: https://sftpgo.nico-steinmueller.de
```

### Key Environment Variables

- `SFTPGO_COMMON__IDLE_TIMEOUT` - Idle connection timeout in minutes
- `SFTPGO_COMMON__UPLOAD_MODE` - 0=normal, 1=tempfile, 2=atomic (recommended)
- `SFTPGO_COMMON__DEFENDER__ENABLED` - Brute-force protection
- `SFTPGO_DATA_PROVIDER__PASSWORD` - Database password (set in .env)

For complete documentation, see the [SFTPGo documentation](https://sftpgo.com/).

### Initial Setup

After first startup, access the web interface and:
1. Login with default credentials (check SFTPGo docs)
2. Configure your first user with appropriate home directories
3. Set up API key for automated management (optional)

### Backup & Restore

Data is persisted in:
- `/mnt/user/appdata/sftpgo/postgres` - PostgreSQL database
- `/mnt/user/data/sftpgo/data` - User data and files
- `/mnt/user/data/sftpgo/backups` - Manual backups

Backup the database:
```bash
docker compose exec database pg_dump -U sftpgo sftpgo > backup.sql
```
