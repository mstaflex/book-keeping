-- =============================================================================
-- 001 · app_config-Tabelle (eingeführt mit "moving secrets and vars into the db")
--
-- 01_schema.sql läuft nur beim allerersten Start (leeres Daten-Volume).
-- Bestehende Datenbanken bekommen Schemaänderungen nur über diese Migrationen.
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden.
-- =============================================================================
CREATE TABLE IF NOT EXISTS app_config (
    scope  TEXT NOT NULL,
    key    TEXT NOT NULL,
    value  TEXT NOT NULL,
    PRIMARY KEY (scope, key)
);
