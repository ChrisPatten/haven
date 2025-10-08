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
                    person_id = self._resolve_person_id(cur, source, person.external_id)

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

                    if not applied:
                        stats.skipped += 1
                        cur.execute("RELEASE SAVEPOINT person_sp")
                        continue

                    self._refresh_children(cur, person_id, person, source, stats)
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

    def _resolve_person_id(self, cur, source: str, external_id: str) -> UUID:
        # Only look up an existing mapping. If one doesn't exist, generate
        # a new person_id but do not insert the source map yet. We must
        # create the people row first (in _upsert_person) to satisfy the
        # foreign key constraint on people_source_map. The caller should
        # call _ensure_source_map after the people row exists.
        cur.execute(
            "SELECT person_id FROM people_source_map WHERE source = %s AND external_id = %s",
            (source, external_id),
        )
        row = cur.fetchone()
        if row:
            return row[0]

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
        self._delete_children(cur, person_id)
        identifiers = self._collect_identifiers(person)

        for ident in identifiers:
            existing_owner = self._lookup_identifier_owner(cur, ident)
            if existing_owner and existing_owner != person_id:
                self._record_conflict(cur, source, person, person_id, existing_owner, ident)
                stats.conflicts += 1
                continue
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
            SELECT person_id
            FROM person_identifiers
            WHERE kind = %s AND value_canonical = %s
            """,
            (identifier.kind.value, identifier.value_canonical),
        )
        row = cur.fetchone()
        return row[0] if row else None

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
