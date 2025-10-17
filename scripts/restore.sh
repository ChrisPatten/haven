#!/usr/bin/env bash
#
# restore.sh - Restore Haven application state from backup
#
# This script restores:
# - Docker volumes (postgres, qdrant, minio)
# - Collector state files to ~/.haven
# - Configuration files
#
# Usage: ./scripts/restore.sh <backup_name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -eq 0 ]; then
    echo "ERROR: Backup name required"
    echo ""
    echo "Usage: $0 <backup_name>"
    echo ""
    echo "Available backups:"
    ls -1 "$HOME/.haven-backups/" 2>/dev/null || echo "  (none found)"
    exit 1
fi

BACKUP_NAME="$1"
BACKUP_DIR="$HOME/.haven-backups/$BACKUP_NAME"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup not found: $BACKUP_DIR"
    echo ""
    echo "Available backups:"
    ls -1 "$HOME/.haven-backups/" 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo "==> Restoring backup: $BACKUP_NAME"
echo "==> From: $BACKUP_DIR"
echo ""

# Show manifest if available
if [ -f "$BACKUP_DIR/MANIFEST.txt" ]; then
    echo "==> Backup manifest:"
    cat "$BACKUP_DIR/MANIFEST.txt"
    echo ""
fi

# Confirm with user
read -p "This will REPLACE current data. Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# Stop services first
echo ""
echo "==> Stopping Docker Compose services..."
cd "$PROJECT_ROOT"
docker compose down
echo "    ✓ Services stopped"

# 1. Restore Docker volumes
echo ""
echo "==> Restoring Docker volumes..."

if [ -f "$BACKUP_DIR/volumes/pg_data.tar.gz" ]; then
    echo "  - Restoring postgres volume..."
    # Remove old volume if it exists
    docker volume rm haven_pg_data 2>/dev/null || true
    # Create new volume
    docker volume create haven_pg_data
    # Restore data
    docker run --rm \
        -v haven_pg_data:/data \
        -v "$BACKUP_DIR/volumes":/backup:ro \
        alpine tar xzf /backup/pg_data.tar.gz -C /data
    echo "    ✓ Restored pg_data"
else
    echo "WARNING: pg_data.tar.gz not found in backup. Skipping..."
fi

if [ -f "$BACKUP_DIR/volumes/qdrant_data.tar.gz" ]; then
    echo "  - Restoring qdrant volume..."
    docker volume rm haven_qdrant_data 2>/dev/null || true
    docker volume create haven_qdrant_data
    docker run --rm \
        -v haven_qdrant_data:/data \
        -v "$BACKUP_DIR/volumes":/backup:ro \
        alpine tar xzf /backup/qdrant_data.tar.gz -C /data
    echo "    ✓ Restored qdrant_data"
else
    echo "WARNING: qdrant_data.tar.gz not found in backup. Skipping..."
fi

if [ -f "$BACKUP_DIR/volumes/minio_data.tar.gz" ]; then
    echo "  - Restoring minio volume..."
    docker volume rm haven_minio_data 2>/dev/null || true
    docker volume create haven_minio_data
    docker run --rm \
        -v haven_minio_data:/data \
        -v "$BACKUP_DIR/volumes":/backup:ro \
        alpine tar xzf /backup/minio_data.tar.gz -C /data
    echo "    ✓ Restored minio_data"
else
    echo "WARNING: minio_data.tar.gz not found in backup. Skipping..."
fi

# 2. Restore ~/.haven state files
echo ""
echo "==> Restoring state files to ~/.haven..."
if [ -d "$BACKUP_DIR/state/dot-haven" ]; then
    # Backup current state if it exists
    if [ -d "$HOME/.haven" ]; then
        echo "  - Backing up current ~/.haven to ~/.haven.pre-restore..."
        mv "$HOME/.haven" "$HOME/.haven.pre-restore-$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Restore from backup
    cp -r "$BACKUP_DIR/state/dot-haven" "$HOME/.haven"
    echo "    ✓ Restored ~/.haven"
    
    # List what was restored
    echo "    Files restored:"
    find "$HOME/.haven" -type f -exec basename {} \; | sed 's/^/      - /'
else
    echo "WARNING: No state backup found (dot-haven directory missing)"
fi

# 3. Restore configuration files
echo ""
echo "==> Restoring configuration files..."
if [ -f "$BACKUP_DIR/config/hostagent.yaml" ]; then
    cp "$BACKUP_DIR/config/hostagent.yaml" "$HOME/.haven/"
    echo "    ✓ Restored hostagent.yaml"
fi

# 4. Summary
echo ""
echo "==> Restore complete!"
echo ""
echo "Next steps:"
echo "  1. Start services:    docker compose up -d"
echo "  2. Check logs:        docker compose logs -f"
echo "  3. Verify data:       docker compose exec postgres psql -U postgres -d haven -c 'SELECT COUNT(*) FROM documents;'"
echo ""
echo "If you need to revert this restore, your previous ~/.haven is at:"
echo "  ~/.haven.pre-restore-*"
