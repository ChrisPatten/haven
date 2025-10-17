#!/usr/bin/env bash
#
# list-backups.sh - List all Haven backups with details
#
set -euo pipefail

BACKUP_ROOT="$HOME/.haven-backups"

if [ ! -d "$BACKUP_ROOT" ]; then
    echo "No backups found. Backup directory does not exist: $BACKUP_ROOT"
    exit 0
fi

echo "Haven Backups (in $BACKUP_ROOT)"
echo "========================================"
echo ""

# Count backups
BACKUP_COUNT=$(ls -1 "$BACKUP_ROOT" | wc -l | tr -d ' ')

if [ "$BACKUP_COUNT" -eq 0 ]; then
    echo "No backups found."
    exit 0
fi

# List backups with details
for backup_dir in "$BACKUP_ROOT"/*; do
    if [ -d "$backup_dir" ]; then
        backup_name=$(basename "$backup_dir")
        backup_size=$(du -sh "$backup_dir" | cut -f1)
        backup_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_dir" 2>/dev/null || stat -c "%y" "$backup_dir" 2>/dev/null | cut -d. -f1)
        
        echo "📦 $backup_name"
        echo "   Date:    $backup_date"
        echo "   Size:    $backup_size"
        
        # Show volumes if available
        if [ -d "$backup_dir/volumes" ]; then
            echo "   Volumes:"
            for vol in "$backup_dir/volumes"/*.tar.gz; do
                if [ -f "$vol" ]; then
                    vol_name=$(basename "$vol" .tar.gz)
                    vol_size=$(du -sh "$vol" | cut -f1)
                    echo "     - $vol_name ($vol_size)"
                fi
            done
        fi
        
        # Show state files if available
        if [ -d "$backup_dir/state/dot-haven" ]; then
            file_count=$(find "$backup_dir/state/dot-haven" -type f | wc -l | tr -d ' ')
            echo "   State:   $file_count files in ~/.haven"
        fi
        
        echo ""
    fi
done

echo "Total backups: $BACKUP_COUNT"
echo ""
echo "To restore a backup:"
echo "  ./scripts/restore.sh <backup_name>"
