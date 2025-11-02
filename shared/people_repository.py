from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence
from uuid import UUID, uuid4

try:  # pragma: no cover - Python < 3.12 fallback
    from uuid import uuid7  # type: ignore[attr-defined]
except ImportError:  # pragma: no cover
    def uuid7() -> UUID:  # type: ignore[misc]
        return uuid4()

try:  # pragma: no cover - optional dependency during tests
    from psycopg import Connection
    from psycopg.rows import dict_row
except ImportError:  # pragma: no cover - fallback when psycopg unavailable
    Connection = Any  # type: ignore[assignment]

    def dict_row(*_args, **_kwargs):  # type: ignore[misc]
        raise RuntimeError("psycopg is required for database access; install haven-platform[common]")

try:  # pragma: no cover - optional dependency during tests
    from psycopg.types.json import Json
except ImportError:  # pragma: no cover - fallback when psycopg unavailable
    def Json(obj):  # type: ignore[misc]
        raise RuntimeError("psycopg is required for database access; install haven-platform[common]")

from shared.logging import get_logger
from shared.people_normalization import IdentifierKind, NormalizedIdentifier, normalize_identifier

logger = get_logger("people.repository")


@dataclass(slots=True)
class ContactValue:
    value: str
    value_raw: str | None = None
    label: str | None = None
    priority: int = 100
    verified: bool = True


@dataclass(slots=True)
class ContactAddress:
    label: str | None = None
    street: str | None = None
    city: str | None = None
    region: str | None = None
    postal_code: str | None = None
    country: str | None = None


@dataclass(slots=True)
class ContactUrl:
    label: str | None = None
    url: str | None = None


@dataclass(slots=True)
class PersonIngestRecord:
    external_id: str
    display_name: str
    given_name: str | None = None
    family_name: str | None = None
    organization: str | None = None
    nicknames: Sequence[str] = field(default_factory=tuple)
    notes: str | None = None
    photo_hash: str | None = None
    emails: Sequence[ContactValue] = field(default_factory=tuple)
    phones: Sequence[ContactValue] = field(default_factory=tuple)
    addresses: Sequence[ContactAddress] = field(default_factory=tuple)
    urls: Sequence[ContactUrl] = field(default_factory=tuple)
    change_token: str | None = None
    version: int = 1
    deleted: bool = False


@dataclass(slots=True)
class UpsertStats:
    accepted: int = 0
    upserts: int = 0
    deletes: int = 0
    conflicts: int = 0
    skipped: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "accepted": self.accepted,
            "upserts": self.upserts,
            "deletes": self.deletes,
            "conflicts": self.conflicts,
            "skipped": self.skipped,
        }


class PeopleRepository:
    def __init__(self, conn: Connection, *, default_region: str | None = None) -> None:
        self.conn = conn
        self.default_region = default_region

    def upsert_batch(self, source: str, batch: Sequence[PersonIngestRecord]) -> UpsertStats:
        stats = UpsertStats()
        if not batch:
            return stats

        with self.conn.cursor() as cur:
            # Use a SAVEPOINT per person so a failure processing one record
            # doesn't abort the entire outer transaction. On error we rollback
            # to the savepoint, log the failure, and continue with the next
            # person.
            for person in batch:
                stats.accepted += 1
                # create a savepoint for this person's work
                try:
                    cur.execute("SAVEPOINT person_sp")
                except Exception:
                    # If creating a savepoint fails for any reason, log and
                    # fall back to treating this person as skipped.
                    logger.exception(
                        "savepoint_create_failed",
                        source=source,
                        external_id=person.external_id,
                    )
                    stats.skipped += 1
                    continue

                try:
                    person_id = self._resolve_person_id(cur, source, person.external_id, person)

                    applied = self._upsert_person(cur, source, person_id, person)
                    # Ensure the people_source_map points to the persisted
                    # people row only after the upsert of people succeeded.
                    if applied:
                        try:
                            self._ensure_source_map(cur, source, person.external_id, person_id)
                        except Exception:
                            # If ensuring the source map fails for FK reasons,
                            # raise to trigger rollback to savepoint for this
                            # person.
                            raise

                    if applied and person.deleted:
                        self._delete_children(cur, person_id)
                        stats.deletes += 1
                        # finished successfully for this person
                        cur.execute("RELEASE SAVEPOINT person_sp")
                        continue

                    # Always refresh identifiers, addresses, and urls even if the person record
                    # wasn't updated (applied=False). This handles the case where we found the
                    # person via source_map but have new identifiers to add.
                    self._refresh_children(cur, person_id, person, source, stats)
                    
                    if not applied:
                        stats.skipped += 1
                        cur.execute("RELEASE SAVEPOINT person_sp")
                        continue

                    stats.upserts += 1

                    # succeed and release the savepoint
                    cur.execute("RELEASE SAVEPOINT person_sp")
                except Exception as exc:  # pragma: no cover - defensive
                    # rollback to the per-person savepoint to clear any
                    # partial work and un-abort the transaction, then skip
                    # this person and continue.
                    try:
                        cur.execute("ROLLBACK TO SAVEPOINT person_sp")
                    except Exception:
                        # If rollback to savepoint fails, there's not much we
                        # can do here other than log and let the outer caller
                        # handle the full transaction rollback.
                        logger.exception(
                            "savepoint_rollback_failed",
                            source=source,
                            external_id=person.external_id,
                            error=str(exc),
                        )
                        stats.skipped += 1
                        continue

                    logger.exception(
                        "person_upsert_failed",
                        source=source,
                        external_id=person.external_id,
                        error=str(exc),
                    )
                    stats.skipped += 1
                    # continue processing remaining records
                    continue

        return stats

    def _resolve_person_id(self, cur, source: str, external_id: str, person: PersonIngestRecord | None = None) -> UUID:
        """
        Resolve person_id by checking multiple sources in priority order:
        1. people_source_map (primary path, backward compatible)
        2. identifier_owner (secondary path, finds existing person by identifiers)
        3. Generate new UUID (fallback if no matches found)
        
        This preserves all existing behavior while adding identifier-based resolution.
        
        Args:
            cur: Database cursor
            source: Source system name
            external_id: External ID from source system
            person: Optional PersonIngestRecord to extract identifiers from
            
        Returns:
            UUID of the resolved or newly-generated person_id
        """
        # Step 1: Check people_source_map (primary path, backward compatible)
        # Only look up an existing mapping. If one doesn't exist, we'll check
        # identifiers before generating a new person_id.
        cur.execute(
            "SELECT person_id FROM people_source_map WHERE source = %s AND external_id = %s",
            (source, external_id),
        )
        row = cur.fetchone()
        if row:
            return row[0]

        # Step 2: If person record provided, try to find existing person by identifiers
        if person is not None:
            identifiers = self._collect_identifiers(person)
            if identifiers:
                existing_person_id = self._resolve_person_by_identifiers(cur, identifiers)
                if existing_person_id:
                    return existing_person_id

        # Step 3: No mapping or identifier match found, generate new person_id
        # We do not insert the source map yet. We must create the people row first
        # (in _upsert_person) to satisfy the foreign key constraint on people_source_map.
        # The caller should call _ensure_source_map after the people row exists.
        return uuid7()

    def _ensure_source_map(self, cur, source: str, external_id: str, person_id: UUID) -> UUID:
        """Insert or update the people_source_map entry. This must be called
        after ensuring the people row with person_id exists so the foreign
        key constraint is satisfied."""
        cur.execute(
            """
            INSERT INTO people_source_map (source, external_id, person_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (source, external_id) DO UPDATE SET person_id = EXCLUDED.person_id
            RETURNING person_id
            """,
            (source, external_id, person_id),
        )
        assigned = cur.fetchone()
        return assigned[0]

    def _upsert_person(self, cur, source: str, person_id: UUID, person: PersonIngestRecord) -> bool:
        cur.execute(
            """
            INSERT INTO people (
                person_id, display_name, given_name, family_name, organization, nicknames,
                notes, photo_hash, source, version, deleted
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (person_id) DO UPDATE
            SET display_name = EXCLUDED.display_name,
                given_name = EXCLUDED.given_name,
                family_name = EXCLUDED.family_name,
                organization = EXCLUDED.organization,
                nicknames = EXCLUDED.nicknames,
                notes = EXCLUDED.notes,
                photo_hash = EXCLUDED.photo_hash,
                version = EXCLUDED.version,
                deleted = EXCLUDED.deleted
            WHERE people.version <= EXCLUDED.version
            RETURNING version
            """,
            (
                person_id,
                person.display_name,
                person.given_name,
                person.family_name,
                person.organization,
                list(person.nicknames),
                person.notes,
                person.photo_hash,
                source,
                person.version,
                person.deleted,
            ),
        )
        row = cur.fetchone()
        return bool(row)

    def _delete_children(self, cur, person_id: UUID) -> None:
        cur.execute("DELETE FROM person_identifiers WHERE person_id = %s", (person_id,))
        cur.execute("DELETE FROM person_addresses WHERE person_id = %s", (person_id,))
        cur.execute("DELETE FROM person_urls WHERE person_id = %s", (person_id,))

    def _refresh_children(
        self,
        cur,
        person_id: UUID,
        person: PersonIngestRecord,
        source: str,
        stats: UpsertStats,
    ) -> None:
        # NOTE: We do NOT delete existing children here. When multiple source contacts
        # merge to the same person_id (via identifier-based resolution), we want to
        # accumulate all identifiers from all sources, not replace them.
        # The only time we delete children is when person.deleted=True (handled separately).
        
        identifiers = self._collect_identifiers(person)

        for ident in identifiers:
            existing_owner = self._lookup_identifier_owner(cur, ident)
            if existing_owner and existing_owner != person_id:
                # Identifier is owned by a different person
                # Instead of just recording conflict, append to existing owner
                append_stats = self._append_identifiers_to_person(
                    cur,
                    target_person_id=existing_owner,
                    identifiers=[ident],
                    source=source,
                    external_id=person.external_id,
                    incoming_person_id=person_id,
                )
                stats.conflicts += 1
                # Log the append action but don't add identifier to incoming person
                continue
            
            # Add identifier to person_identifiers (or update if exists)
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (person_id, kind, value_canonical) DO UPDATE
                SET value_raw = EXCLUDED.value_raw,
                    label = EXCLUDED.label,
                    priority = EXCLUDED.priority,
                    verified = EXCLUDED.verified
                """,
                (
                    person_id,
                    ident.kind.value,
                    ident.value_raw,
                    ident.value_canonical,
                    ident.label,
                    ident.priority,
                    ident.verified,
                ),
            )
            
            # Claim ownership in identifier_owner for this identifier
            self._claim_identifier_ownership(cur, ident, person_id)

        for address in person.addresses:
            cur.execute(
                """
                INSERT INTO person_addresses (
                    person_id, label, street, city, region, postal_code, country
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (person_id, label) DO UPDATE
                SET street = EXCLUDED.street,
                    city = EXCLUDED.city,
                    region = EXCLUDED.region,
                    postal_code = EXCLUDED.postal_code,
                    country = EXCLUDED.country
                """,
                (
                    person_id,
                    (address.label or "other").lower(),
                    address.street,
                    address.city,
                    address.region,
                    address.postal_code,
                    address.country,
                ),
            )

        for link in person.urls:
            if not link.url:
                continue
            cur.execute(
                """
                INSERT INTO person_urls (person_id, label, url)
                VALUES (%s, %s, %s)
                ON CONFLICT (person_id, label) DO UPDATE
                SET url = EXCLUDED.url
                """,
                (
                    person_id,
                    (link.label or "other").lower(),
                    link.url,
                ),
            )

    def _collect_identifiers(self, person: PersonIngestRecord) -> List[NormalizedIdentifier]:
        identifiers: List[NormalizedIdentifier] = []
        for item in person.phones:
            try:
                raw_value = item.value_raw or item.value
                identifiers.append(
                    normalize_identifier(
                        IdentifierKind.PHONE,
                        raw_value,
                        default_region=self.default_region,
                        label=(item.label or "other").lower(),
                        priority=item.priority,
                        verified=item.verified,
                        value_raw=item.value_raw or item.value,
                    )
                )
            except Exception as exc:
                logger.info(
                    "normalize_phone_failed",
                    value=item.value,
                    error=str(exc),
                )
        for item in person.emails:
            try:
                raw_value = item.value_raw or item.value
                identifiers.append(
                    normalize_identifier(
                        IdentifierKind.EMAIL,
                        raw_value,
                        label=(item.label or "other").lower(),
                        priority=item.priority,
                        verified=item.verified,
                        value_raw=item.value_raw or item.value,
                    )
                )
            except Exception as exc:
                logger.info(
                    "normalize_email_failed",
                    value=item.value,
                    error=str(exc),
                )
        return identifiers

    def _lookup_identifier_owner(self, cur, identifier: NormalizedIdentifier) -> UUID | None:
        cur.execute(
            """
            SELECT owner_person_id
            FROM identifier_owner
            WHERE kind = %s AND value_canonical = %s
            """,
            (identifier.kind.value, identifier.value_canonical),
        )
        row = cur.fetchone()
        return row[0] if row else None

    def _claim_identifier_ownership(
        self, cur, identifier: NormalizedIdentifier, candidate_person_id: UUID
    ) -> tuple[UUID | None, bool]:
        """
        Atomically claim ownership of an identifier.
        
        Attempts to insert or update the identifier_owner table to claim ownership.
        Uses INSERT ... ON CONFLICT DO UPDATE to handle concurrent claims atomically.
        
        Args:
            cur: Database cursor
            identifier: NormalizedIdentifier to claim
            candidate_person_id: UUID of person attempting to claim the identifier
            
        Returns:
            Tuple of (owner_person_id, was_claimed):
            - owner_person_id: UUID of the current owner (may be candidate or existing owner)
            - was_claimed: True if this call successfully claimed it, False if already owned
        """
        cur.execute(
            """
            INSERT INTO identifier_owner (kind, value_canonical, owner_person_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (kind, value_canonical) DO UPDATE
            SET owner_person_id = CASE 
                WHEN identifier_owner.owner_person_id IS NULL THEN EXCLUDED.owner_person_id
                ELSE identifier_owner.owner_person_id
            END
            RETURNING owner_person_id
            """,
            (identifier.kind.value, identifier.value_canonical, candidate_person_id),
        )
        row = cur.fetchone()
        if not row or not row[0]:
            return None, False
        
        owner_person_id = row[0]
        was_claimed = owner_person_id == candidate_person_id
        
        # If identifier was already owned by a different person, return existing owner
        return owner_person_id, was_claimed

    def _resolve_person_by_identifiers(
        self, cur, identifiers: Sequence[NormalizedIdentifier]
    ) -> UUID | None:
        """
        Resolve person_id by checking person_identifiers table for multiple identifiers.
        
        For each identifier, checks person_identifiers table for existing owner.
        Returns the most common owner person_id if multiple identifiers point to same person.
        Returns None if no existing owner found for any identifier.
        
        Args:
            cur: Database cursor
            identifiers: Sequence of NormalizedIdentifier objects to look up
            
        Returns:
            UUID of the person that matches the most identifiers, or None if no matches
        """
        if not identifiers:
            return None
        
        # Build VALUES clause for IN query
        values = [(ident.kind.value, ident.value_canonical) for ident in identifiers]
        placeholders = ", ".join(["(%s, %s)"] * len(values))
        args: list[Any] = []
        for kind, canonical in values:
            args.extend([kind, canonical])
        
        cur.execute(
            f"""
            SELECT person_id, COUNT(*) as match_count
            FROM person_identifiers
            WHERE (kind, value_canonical) IN ({placeholders})
            GROUP BY person_id
            ORDER BY match_count DESC, person_id
            LIMIT 1
            """,
            args,
        )
        row = cur.fetchone()
        return row[0] if row else None

    def _append_identifiers_to_person(
        self,
        cur,
        target_person_id: UUID,
        identifiers: Sequence[NormalizedIdentifier],
        source: str,
        external_id: str,
        incoming_person_id: UUID,
    ) -> dict[str, int]:
        """
        Append identifiers from incoming person to an existing target person.
        
        This method:
        1. Adds identifiers to person_identifiers for target person (skip duplicates)
        2. Updates people_source_map to map external_id → target_person_id
        3. Claims ownership in identifier_owner for all appended identifiers
        4. Records append action in append_audit table
        
        Args:
            cur: Database cursor
            target_person_id: UUID of the person to append to
            identifiers: Sequence of NormalizedIdentifier objects to append
            source: Source system name
            external_id: External ID from source system
            incoming_person_id: UUID of the incoming person being appended
            
        Returns:
            Dict with statistics: {
                "identifiers_appended": int,
                "ownership_claimed": int,
                "source_map_updated": int
            }
        """
        stats = {
            "identifiers_appended": 0,
            "ownership_claimed": 0,
            "source_map_updated": 0,
        }
        
        # Track which identifiers were actually appended
        appended_identifiers: list[dict[str, str]] = []
        
        # Step 1: Add identifiers to person_identifiers for target person
        for ident in identifiers:
            cur.execute(
                """
                INSERT INTO person_identifiers (
                    person_id, kind, value_raw, value_canonical, label, priority, verified
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (person_id, kind, value_canonical) DO NOTHING
                """,
                (
                    target_person_id,
                    ident.kind.value,
                    ident.value_raw,
                    ident.value_canonical,
                    ident.label,
                    ident.priority,
                    ident.verified,
                ),
            )
            if cur.rowcount > 0:
                stats["identifiers_appended"] += 1
                appended_identifiers.append({
                    "kind": ident.kind.value,
                    "value_canonical": ident.value_canonical,
                })
        
        # Step 2: Update people_source_map to point incoming external_id to target person
        cur.execute(
            """
            INSERT INTO people_source_map (source, external_id, person_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (source, external_id) DO UPDATE
            SET person_id = EXCLUDED.person_id
            """,
            (source, external_id, target_person_id),
        )
        if cur.rowcount > 0:
            stats["source_map_updated"] += 1
        
        # Step 3: Claim ownership in identifier_owner for all identifiers
        for ident in identifiers:
            owner_id, was_claimed = self._claim_identifier_ownership(cur, ident, target_person_id)
            if owner_id == target_person_id:
                stats["ownership_claimed"] += 1
        
        # Step 4: Record append action in append_audit table
        cur.execute(
            """
            INSERT INTO append_audit (
                source, external_id, target_person_id, incoming_person_id,
                identifiers_appended, justification
            )
            VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (
                source,
                external_id,
                target_person_id,
                incoming_person_id,
                Json(appended_identifiers),
                f"Appended {len(appended_identifiers)} identifiers from incoming person",
            ),
        )
        
        return stats

    def _record_conflict(
        self,
        cur,
        source: str,
        person: PersonIngestRecord,
        incoming_person_id: UUID,
        existing_person_id: UUID,
        identifier: NormalizedIdentifier,
    ) -> None:
        cur.execute(
            """
            INSERT INTO people_conflict_log (
                source, external_id, kind, value_canonical, existing_person_id, incoming_person_id, notes
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            """,
            (
                source,
                person.external_id,
                identifier.kind.value,
                identifier.value_canonical,
                existing_person_id,
                incoming_person_id,
                f"Conflict on identifier {identifier.value_raw}",
            ),
        )

    def merge_people(
        self,
        target_id: UUID,
        source_ids: Sequence[UUID],
        strategy: str = "prefer_target",
        actor: str = "system",
        metadata: dict | None = None,
    ) -> dict:
        """
        Merge multiple source contacts into a single target contact.
        
        This operation:
        1. Updates all FK references from source_ids to target_id
        2. Merges attributes per strategy
        3. Soft-deletes source records (sets merged_into = target_id)
        4. Records the merge in contacts_merge_audit
        
        Args:
            target_id: UUID of the surviving contact
            source_ids: Sequence of UUIDs to merge into target
            strategy: "prefer_target", "prefer_source", or "merge_non_null"
            actor: Who is performing the merge (user, script name, etc.)
            metadata: Optional additional context
        
        Returns:
            Dict with merge statistics
        
        Raises:
            ValueError: If target or sources don't exist, or invalid strategy
            RuntimeError: On transaction failure
        """
        if not source_ids:
            raise ValueError("source_ids cannot be empty")
        
        if strategy not in ("prefer_target", "prefer_source", "merge_non_null"):
            raise ValueError(f"Invalid strategy: {strategy}")
        
        source_ids_list = list(source_ids)
        if target_id in source_ids_list:
            raise ValueError("target_id cannot be in source_ids")
        
        merge_id = uuid4()
        
        try:
            with self.conn.cursor() as cur:
                # Verify target exists and is not merged
                cur.execute(
                    "SELECT person_id, display_name, given_name, family_name, organization, nicknames, notes, photo_hash FROM people WHERE person_id = %s AND merged_into IS NULL AND deleted = FALSE",
                    (target_id,)
                )
                target_row = cur.fetchone()
                if not target_row:
                    raise ValueError(f"Target person {target_id} not found or already merged")
                
                # Verify all sources exist and are not already merged
                for source_id in source_ids_list:
                    cur.execute(
                        "SELECT person_id FROM people WHERE person_id = %s AND merged_into IS NULL AND deleted = FALSE",
                        (source_id,)
                    )
                    if not cur.fetchone():
                        raise ValueError(f"Source person {source_id} not found or already merged")
                
                # Merge person_identifiers
                cur.execute(
                    """
                    UPDATE person_identifiers
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                identifier_count = cur.rowcount
                
                # Merge people_source_map
                cur.execute(
                    """
                    UPDATE people_source_map
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                source_map_count = cur.rowcount
                
                # Merge person_addresses
                cur.execute(
                    """
                    UPDATE person_addresses
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                address_count = cur.rowcount
                
                # Merge person_urls
                cur.execute(
                    """
                    UPDATE person_urls
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                url_count = cur.rowcount
                
                # Merge document_people
                cur.execute(
                    """
                    UPDATE document_people
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                doc_people_count = cur.rowcount
                
                # Merge crm_relationships (handle both directions)
                # Update self_person_id references
                cur.execute(
                    """
                    UPDATE crm_relationships
                    SET self_person_id = %s
                    WHERE self_person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                crm_self_count = cur.rowcount
                
                # Update person_id references (contacts of the source)
                cur.execute(
                    """
                    UPDATE crm_relationships
                    SET person_id = %s
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                crm_person_count = cur.rowcount
                
                # Merge target attributes per strategy
                target_display_name = target_row[1]
                target_given_name = target_row[2]
                target_family_name = target_row[3]
                target_organization = target_row[4]
                target_nicknames = target_row[5] or []
                target_notes = target_row[6]
                target_photo_hash = target_row[7]
                
                if strategy in ("prefer_source", "merge_non_null"):
                    # Get source attributes (use first source's non-null values)
                    for source_id in source_ids_list:
                        cur.execute(
                            "SELECT display_name, given_name, family_name, organization, nicknames, notes, photo_hash FROM people WHERE person_id = %s",
                            (source_id,)
                        )
                        source_row = cur.fetchone()
                        if source_row:
                            if strategy == "prefer_source":
                                # Use source's values, fall back to target if source is null
                                target_display_name = source_row[0] or target_display_name
                                target_given_name = source_row[1] or target_given_name
                                target_family_name = source_row[2] or target_family_name
                                target_organization = source_row[3] or target_organization
                                target_notes = source_row[5] or target_notes
                                target_photo_hash = source_row[6] or target_photo_hash
                                source_nicknames = source_row[4] or []
                                target_nicknames = list(set(list(target_nicknames) + source_nicknames))
                            else:  # merge_non_null
                                # Combine non-null values, prefer target on conflicts
                                target_display_name = target_display_name or source_row[0]
                                target_given_name = target_given_name or source_row[1]
                                target_family_name = target_family_name or source_row[2]
                                target_organization = target_organization or source_row[3]
                                source_nicknames = source_row[4] or []
                                target_nicknames = list(set(list(target_nicknames) + source_nicknames))
                                target_notes = target_notes or source_row[5]
                                target_photo_hash = target_photo_hash or source_row[6]
                
                # Update target with merged attributes
                cur.execute(
                    """
                    UPDATE people
                    SET display_name = %s, given_name = %s, family_name = %s,
                        organization = %s, nicknames = %s, notes = %s, photo_hash = %s,
                        updated_at = NOW()
                    WHERE person_id = %s
                    """,
                    (
                        target_display_name,
                        target_given_name,
                        target_family_name,
                        target_organization,
                        target_nicknames,
                        target_notes,
                        target_photo_hash,
                        target_id,
                    ),
                )
                
                # Soft-delete source records
                cur.execute(
                    """
                    UPDATE people
                    SET merged_into = %s, updated_at = NOW()
                    WHERE person_id = ANY(%s)
                    """,
                    (target_id, source_ids_list)
                )
                
                # Record merge in audit table
                merge_metadata = metadata or {}
                cur.execute(
                    """
                    INSERT INTO contacts_merge_audit (
                        merge_id, target_person_id, source_person_ids, actor, strategy, merge_metadata
                    )
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (
                        merge_id,
                        target_id,
                        source_ids_list,
                        actor,
                        strategy,
                        merge_metadata,
                    ),
                )
                
                self.conn.commit()
                
                return {
                    "merge_id": str(merge_id),
                    "target_id": str(target_id),
                    "source_ids": [str(s) for s in source_ids_list],
                    "strategy": strategy,
                    "actor": actor,
                    "updated_identifiers": identifier_count,
                    "updated_source_maps": source_map_count,
                    "updated_addresses": address_count,
                    "updated_urls": url_count,
                    "updated_document_people": doc_people_count,
                    "updated_crm_relationships": crm_self_count + crm_person_count,
                }
        
        except Exception as e:
            logger.exception(
                "merge_people_failed",
                target_id=str(target_id),
                source_ids=[str(s) for s in source_ids_list],
                error=str(e),
            )
            try:
                self.conn.rollback()
            except Exception:
                pass
            raise RuntimeError(f"Failed to merge contacts: {str(e)}") from e

    def _should_merge_on_ingest(
        self,
        cur,
        target_person_id: UUID,
        incoming_person_id: UUID,
        identifiers: Sequence[NormalizedIdentifier],
        policy: str = "never",
    ) -> bool:
        """
        Evaluate merge policy to determine if two persons should be merged during ingestion.
        
        Merge policies:
        - "never": Always append (default, safest)
        - "strict": Merge only if both persons have >=N matching identifiers (default N=2)
        - "same_namespace": Merge if external_ids share same namespace/prefix
        
        Args:
            cur: Database cursor
            target_person_id: UUID of existing person
            incoming_person_id: UUID of incoming person
            identifiers: Sequence of identifiers from incoming person
            policy: Policy name ("never", "strict", "same_namespace")
            
        Returns:
            True if merge should happen, False for append
        """
        if policy == "never":
            # Default: always append, never merge
            return False
        
        if policy == "strict":
            # Merge if both persons have >= 2 matching identifiers
            match_count = self._count_matching_identifiers(
                cur, target_person_id, incoming_person_id
            )
            return match_count >= 2
        
        if policy == "same_namespace":
            # Check if external_ids share namespace
            return self._check_namespace_match(cur, target_person_id, incoming_person_id)
        
        # Unknown policy: default to never merge
        return False

    def _count_matching_identifiers(
        self, cur, person_id_1: UUID, person_id_2: UUID
    ) -> int:
        """
        Count matching identifiers between two persons.
        
        Args:
            cur: Database cursor
            person_id_1: UUID of first person
            person_id_2: UUID of second person
            
        Returns:
            Count of matching (kind, value_canonical) pairs
        """
        cur.execute(
            """
            SELECT COUNT(*)
            FROM person_identifiers pi1
            WHERE pi1.person_id = %s
            AND EXISTS (
                SELECT 1 FROM person_identifiers pi2
                WHERE pi2.person_id = %s
                AND pi1.kind = pi2.kind
                AND pi1.value_canonical = pi2.value_canonical
            )
            """,
            (person_id_1, person_id_2),
        )
        row = cur.fetchone()
        return row[0] if row else 0

    def _check_namespace_match(self, cur, person_id_1: UUID, person_id_2: UUID) -> bool:
        """
        Check if external_ids for two persons share the same namespace/prefix.
        
        Example: "contacts:UUID-123" and "contacts:UUID-456" share namespace "contacts"
        
        Args:
            cur: Database cursor
            person_id_1: UUID of first person
            person_id_2: UUID of second person
            
        Returns:
            True if any external_id pair shares namespace, False otherwise
        """
        cur.execute(
            """
            SELECT psm1.source
            FROM people_source_map psm1
            WHERE psm1.person_id = %s
            AND EXISTS (
                SELECT 1 FROM people_source_map psm2
                WHERE psm2.person_id = %s
                AND psm1.source = psm2.source
            )
            LIMIT 1
            """,
            (person_id_1, person_id_2),
        )
        row = cur.fetchone()
        return bool(row)


class PeopleResolver:
    def __init__(self, conn: Connection, *, default_region: str | None = None) -> None:
        self.conn = conn
        self.default_region = default_region

    def resolve(self, kind: IdentifierKind, value: str) -> Optional[Dict[str, str]]:
        identifier = normalize_identifier(kind, value, default_region=self.default_region)
        query = """
            SELECT p.person_id, p.display_name
            FROM person_identifiers pi
            JOIN people p ON p.person_id = pi.person_id
            WHERE pi.kind = %s
              AND pi.value_canonical = %s
              AND p.deleted = FALSE
        """
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(query, (identifier.kind.value, identifier.value_canonical))
            row = cur.fetchone()
            if not row:
                return None
            return {
                "person_id": str(row["person_id"]),
                "display_name": row["display_name"],
            }

    def resolve_many(self, items: Sequence[tuple[IdentifierKind, str]]) -> Dict[str, Dict[str, str]]:
        results: Dict[str, Dict[str, str]] = {}
        if not items:
            return results

        normalized: List[tuple[str, str]] = []
        for kind, value in items:
            ident = normalize_identifier(kind, value, default_region=self.default_region)
            normalized.append((ident.kind.value, ident.value_canonical))

        placeholders = ", ".join(["(%s, %s)"] * len(normalized))
        args: List[str] = []
        for kind_value, canonical in normalized:
            args.extend([kind_value, canonical])

        query = f"""
            SELECT pi.kind, pi.value_canonical, p.person_id, p.display_name
            FROM person_identifiers pi
            JOIN people p ON p.person_id = pi.person_id
            WHERE (pi.kind, pi.value_canonical) IN ({placeholders})
              AND p.deleted = FALSE
        """

        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(query, args)
            for row in cur.fetchall():
                key = f"{row['kind']}:{row['value_canonical']}"
                results[key] = {
                    "person_id": str(row["person_id"]),
                    "display_name": row["display_name"],
                }
        return results


def get_self_person_id_from_settings(conn: Connection) -> Optional[UUID]:
    """
    Retrieve the self_person_id from system_settings.
    
    Args:
        conn: Database connection
        
    Returns:
        UUID of the self person, or None if not set
    """
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT value->>'self_person_id' AS self_person_id
            FROM system_settings
            WHERE key = 'self_person_id'
            """,
        )
        row = cur.fetchone()
        if row and row.get("self_person_id"):
            return UUID(row["self_person_id"])
    return None


def store_self_person_id_if_needed(
    conn: Connection, 
    person_id: UUID, 
    *,
    source: str,
    detected_at: str,
) -> bool:
    """
    Store self_person_id in system_settings using atomic UPSERT.
    
    Only writes if self_person_id is not already set. Uses INSERT ... ON CONFLICT
    to ensure atomicity when multiple processes attempt to set simultaneously.
    
    Args:
        conn: Database connection
        person_id: UUID of the self person
        source: Source of detection (e.g., "imessage")
        detected_at: ISO8601 timestamp when detection occurred
        
    Returns:
        True if self_person_id was written (was unset before), False if already set
    """
    import json
    from datetime import datetime
    
    # Normalize detected_at to ISO8601 if it's a datetime object
    if isinstance(detected_at, datetime):
        detected_at = detected_at.isoformat()
    
    setting_value = {
        "self_person_id": str(person_id),
        "source": source,
        "detected_at": detected_at,
    }
    
    with conn.cursor() as cur:
        # Check if already set
        cur.execute(
            """
            SELECT value->>'self_person_id' AS self_person_id
            FROM system_settings
            WHERE key = 'self_person_id'
            """,
        )
        existing = cur.fetchone()
        
        if existing and existing[0]:
            # Already set, no update needed
            return False
        
        # Write using UPSERT with condition: only update if currently NULL/unset
        cur.execute(
            """
            INSERT INTO system_settings (key, value)
            VALUES ('self_person_id', %s)
            ON CONFLICT (key) DO UPDATE
            SET value = EXCLUDED.value
            WHERE system_settings.value->>'self_person_id' IS NULL
            """,
            (Json(setting_value),),
        )
        conn.commit()
        return True
