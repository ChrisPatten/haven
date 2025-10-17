#!/usr/bin/env bash
#
# backup.sh - Back up Haven application state
#
# This script backs up:
# - Docker volumes (postgres, qdrant, minio)
# - Collector state files from ~/.haven
# - Configuration files
#
# Usage: ./scripts/backup.sh [backup_name]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default backup name includes timestamp
BACKUP_NAME="${1:-haven-backup-$(date +%Y%m%d-%H%M%S)}"
BACKUP_DIR="$HOME/.haven-backups/$BACKUP_NAME"

echo "==> Creating backup: $BACKUP_NAME"
echo "==> Backup directory: $BACKUP_DIR"

# Create backup directory
mkdir -p "$BACKUP_DIR"/{volumes,state,config}

# 1. Back up Docker volumes
echo ""
echo "==> Backing up Docker volumes..."

# Check if volumes exist
if ! docker volume ls | grep -q "haven_pg_data"; then
    echo "WARNING: Docker volume 'haven_pg_data' not found. Skipping..."
else
    echo "  - Backing up postgres volume..."
    docker run --rm \
        -v haven_pg_data:/data:ro \
        -v "$BACKUP_DIR/volumes":/backup \
        alpine tar czf /backup/pg_data.tar.gz -C /data .
    echo "    ✓ Saved to pg_data.tar.gz ($(du -h "$BACKUP_DIR/volumes/pg_data.tar.gz" | cut -f1))"
fi

if ! docker volume ls | grep -q "haven_qdrant_data"; then
    echo "WARNING: Docker volume 'haven_qdrant_data' not found. Skipping..."
else
    echo "  - Backing up qdrant volume..."
    docker run --rm \
        -v haven_qdrant_data:/data:ro \
        -v "$BACKUP_DIR/volumes":/backup \
        alpine tar czf /backup/qdrant_data.tar.gz -C /data .
    echo "    ✓ Saved to qdrant_data.tar.gz ($(du -h "$BACKUP_DIR/volumes/qdrant_data.tar.gz" | cut -f1))"
fi

if ! docker volume ls | grep -q "haven_minio_data"; then
    echo "WARNING: Docker volume 'haven_minio_data' not found. Skipping..."
else
    echo "  - Backing up minio volume..."
    docker run --rm \
        -v haven_minio_data:/data:ro \
        -v "$BACKUP_DIR/volumes":/backup \
        alpine tar czf /backup/minio_data.tar.gz -C /data .
    echo "    ✓ Saved to minio_data.tar.gz ($(du -h "$BACKUP_DIR/volumes/minio_data.tar.gz" | cut -f1))"
fi

# 2. Back up ~/.haven state files
echo ""
echo "==> Backing up state files from ~/.haven..."
if [ -d "$HOME/.haven" ]; then
    cp -r "$HOME/.haven" "$BACKUP_DIR/state/dot-haven"
    echo "    ✓ Copied ~/.haven ($(du -sh "$BACKUP_DIR/state/dot-haven" | cut -f1))"
    
    # List what was backed up
    echo "    Files backed up:"
    find "$BACKUP_DIR/state/dot-haven" -type f -exec basename {} \; | sed 's/^/      - /'
else
    echo "WARNING: ~/.haven directory not found. Creating empty marker..."
    touch "$BACKUP_DIR/state/no-haven-dir"
fi

# 3. Back up configuration files
echo ""
echo "==> Backing up configuration files..."
if [ -f "$HOME/.haven/hostagent.yaml" ]; then
    cp "$HOME/.haven/hostagent.yaml" "$BACKUP_DIR/config/"
    echo "    ✓ Backed up hostagent.yaml"
fi

# 4. Save Docker Compose state
echo ""
echo "==> Saving Docker Compose information..."
cd "$PROJECT_ROOT"
docker compose ps --format json > "$BACKUP_DIR/config/compose-ps.json" 2>/dev/null || echo "[]" > "$BACKUP_DIR/config/compose-ps.json"
echo "    ✓ Saved container state"

# 5. Create manifest
echo ""
echo "==> Creating backup manifest..."
cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
Haven Backup: $BACKUP_NAME
Created: $(date)
Hostname: $(hostname)
User: $(whoami)

Contents:
$(tree -L 2 "$BACKUP_DIR" 2>/dev/null || find "$BACKUP_DIR" -maxdepth 2 -type f -o -type d | sort)

Sizes:
$(du -sh "$BACKUP_DIR"/volumes/* 2>/dev/null || echo "No volume backups")
$(du -sh "$BACKUP_DIR"/state/* 2>/dev/null || echo "No state backups")

To restore this backup, run:
  ./scripts/restore.sh $BACKUP_NAME
EOF

# 6. Summary
echo ""
echo "==> Backup complete!"
echo ""
echo "Backup location: $BACKUP_DIR"
echo "Total size: $(du -sh "$BACKUP_DIR" | cut -f1)"
echo ""
echo "To restore this backup later:"
echo "  ./scripts/restore.sh $BACKUP_NAME"
echo ""
echo "To list all backups:"
echo "  ls -lh ~/.haven-backups/"
