# Haven Backup & Restore Guide

## Overview

Haven stores data in multiple locations:
- **Docker volumes**: Database (postgres), vector search (qdrant), file storage (minio)
- **State files**: `~/.haven/` contains collector progress tracking and configuration
- **Chat database backup**: `~/.haven/chat_backup/` contains snapshots of your iMessage database

## Quick Reference

### Create a Backup

```bash
# Using Makefile (recommended)
make backup                          # Auto-generated timestamp name
make backup NAME=my-good-state       # Custom name

# Or use script directly
./scripts/backup.sh                  # Auto-generated timestamp name
./scripts/backup.sh my-good-state    # Custom name
```

Backups are saved to `~/.haven-backups/<backup_name>/`

### List Backups

```bash
# Using Makefile
make list-backups

# Or use script directly
./scripts/list-backups.sh
```

### Restore a Backup

```bash
# Using Makefile (recommended)
make list-backups                    # List available backups first
make restore NAME=my-good-state      # Restore specific backup

# Or use script directly
./scripts/list-backups.sh            # List available backups
./scripts/restore.sh my-good-state   # Restore specific backup
```

**Warning**: Restore will:
1. Stop all Docker services
2. Delete current Docker volumes
3. Replace `~/.haven/` directory (backs up current to `~/.haven.pre-restore-*`)
4. Restore all data from backup

## Typical Workflow for Testing

### 1. Create a backup before testing

```bash
# Using Makefile (recommended)
make backup NAME=good-state-before-hostagent-test

# Or use script directly
./scripts/backup.sh good-state-before-hostagent-test

# Verify backup was created
make list-backups
```

### 2. Test new features (purge if needed)

```bash
# Option A: Full purge - delete everything and start fresh
docker compose down -v  # Remove volumes
rm -rf ~/.haven/*       # Clear state files

# Option B: Partial purge - just reset collectors
rm ~/.haven/imessage_collector_state.json
rm ~/.haven/imessage_versions.json
rm ~/.haven/imessage_image_cache.json
rm ~/.haven/localfs_collector_state.json
rm ~/.haven/contacts_collector_state.json

# Start services fresh
docker compose up --build
```

### 3. Restore good state when done

```bash
# Using Makefile (recommended)
make restore NAME=good-state-before-hostagent-test

# Or use script directly
./scripts/restore.sh good-state-before-hostagent-test

# Start services
docker compose up -d
# Or use Makefile
make start

# Verify restoration
docker compose exec postgres psql -U postgres -d haven -c "SELECT COUNT(*) FROM documents;"
```

## What Gets Backed Up

### Docker Volumes (`~/.haven-backups/<name>/volumes/`)
- `pg_data.tar.gz` - PostgreSQL database (documents, chunks, metadata)
- `qdrant_data.tar.gz` - Vector embeddings for semantic search
- `minio_data.tar.gz` - File attachments (images, documents)

### State Files (`~/.haven-backups/<name>/state/dot-haven/`)
- `imessage_collector_state.json` - iMessage collection progress
- `imessage_versions.json` - Message version tracking
- `imessage_image_cache.json` - Image enrichment cache
- `localfs_collector_state.json` - Filesystem watch progress
- `contacts_collector_state.json` - Contacts sync state
- `chat_backup/` - Chat database snapshots
- `hostagent.yaml` - Host agent configuration

### Configuration (`~/.haven-backups/<name>/config/`)
- `hostagent.yaml` - Host agent settings
- `compose-ps.json` - Docker service state snapshot

## Backup Storage

- Backups are stored in `~/.haven-backups/`
- Each backup is in its own directory with timestamp
- Typical backup size: 100MB - 2GB depending on data volume
- Backups are **local only** - consider copying to external storage for safety

## Tips

1. **Create backups before major changes**:
   - Before testing new collectors
   - Before schema migrations
   - Before Docker Compose updates

2. **Name backups descriptively**:
   ```bash
   # Using Makefile
   make backup NAME=before-hostagent-migration
   make backup NAME=good-2025-10-17
   make backup NAME=pre-schema-v3
   
   # Or use script directly
   ./scripts/backup.sh before-hostagent-migration
   ./scripts/backup.sh good-2025-10-17
   ./scripts/backup.sh pre-schema-v3
   ```

3. **Test restores periodically**:
   - Verify backups work before you need them
   - Restore to a test environment if possible

4. **Clean up old backups**:
   ```bash
   # Manual cleanup
   rm -rf ~/.haven-backups/old-backup-name
   
   # Or keep only recent backups
   ls -t ~/.haven-backups/ | tail -n +6 | xargs -I {} rm -rf ~/.haven-backups/{}
   ```

5. **Disk space considerations**:
   ```bash
   # Check backup sizes
   du -sh ~/.haven-backups/*
   
   # Check available space
   df -h ~
   ```

## Troubleshooting

### Backup fails with "volume not found"
- Volume hasn't been created yet (services haven't run)
- This is OK - script will skip missing volumes with a warning

### Restore fails with permission errors
- Run with proper permissions
- Ensure Docker daemon is running: `docker ps`

### Restore completes but data seems wrong
- Check service logs: `docker compose logs -f`
- Verify volumes were restored: `docker volume inspect haven_pg_data`
- Check database: `docker compose exec postgres psql -U postgres -d haven`

### After restore, embedding service shows errors
- Embeddings may need to be regenerated
- Check Ollama is running: `curl http://localhost:11434/api/tags`
- Restart embedding service: `docker compose restart embedding_service`
