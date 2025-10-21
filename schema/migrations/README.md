# Database Migrations

This directory contains SQL migration files for the Haven database schema.

## Migration Naming Convention

Migrations are named using the pattern: `v2_XXX_description.sql`

- `v2`: Schema version
- `XXX`: Sequential migration number (e.g., 001, 002, 003)
- `description`: Brief description of what the migration does (use underscores)

## Applying Migrations

### To an existing database:

```bash
# Apply a single migration
docker compose exec -T postgres psql -U postgres -d haven < schema/migrations/v2_001_email_collector.sql

# Apply all migrations in order
for migration in schema/migrations/v2_*.sql; do
  echo "Applying $migration..."
  docker compose exec -T postgres psql -U postgres -d haven < "$migration"
done
```

### For new databases:

Migrations are automatically applied when initializing a new database via `schema/init.sql`.
When adding a new migration:
1. Create the migration file in this directory
2. Update `schema/init.sql` to include the same changes for new installations

## Migration Files

### v2_001_email_collector.sql
- **Date**: 2025-10-20
- **Bead**: haven-27
- **Description**: Add email_local source type and intent/relevance fields for email collector
- **Changes**:
  - Added `email_local` to `documents.source_type` CHECK constraint
  - Added `intent` JSONB column to documents table
  - Added `relevance_score` FLOAT column to documents table
  - Created GIN index on `intent` for JSONB queries
  - Created partial index on `relevance_score`
  - Created composite index for `email_local` queries

## Testing Migrations

Before applying a migration to production:

1. **Test on a copy of the database**:
   ```bash
   # Create a backup
   ./scripts/backup.sh
   
   # Apply migration
   docker compose exec -T postgres psql -U postgres -d haven < schema/migrations/v2_XXX_description.sql
   
   # Verify changes
   docker compose exec postgres psql -U postgres -d haven -c "\\d+ documents"
   ```

2. **Verify backwards compatibility**:
   - Ensure existing queries still work
   - Verify default values are appropriate
   - Test that NULL values are handled correctly

3. **Check performance**:
   - Verify indexes are created as expected
   - Test query performance with sample data
   - Monitor index usage with `EXPLAIN ANALYZE`

## Rollback Strategy

If a migration needs to be rolled back:

1. Restore from the most recent backup:
   ```bash
   ./scripts/restore.sh <backup-name>
   ```

2. Or manually reverse the changes by creating a rollback script

## Best Practices

1. **Always test migrations** on a copy of the database first
2. **Create backups** before applying migrations to production
3. **Keep migrations small and focused** - one logical change per migration
4. **Include verification queries** in migration comments
5. **Update init.sql** to keep it in sync with migrations
6. **Document breaking changes** clearly in the migration file
7. **Use `IF NOT EXISTS` / `IF EXISTS`** to make migrations idempotent where possible
