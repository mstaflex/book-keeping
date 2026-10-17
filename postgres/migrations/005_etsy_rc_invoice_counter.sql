-- =============================================================================
-- 005 · Eigener Nummernkreis für die Reverse-Charge-Rechnungen an Etsy
--
-- Die Etsy-Rechnungen (Workflow 05) zählen unabhängig von den Kunden-
-- rechnungen (invoice_counter, Workflow 04): je Jahr ab 1, Format
-- etsy_rc.number_format (Standard RE-E-{YYYY}-{NN}). Der Zähler steigt nur,
-- wenn eine Rechnung entsteht; Monate ohne digitale Verkäufe verbrauchen
-- keine Nummer.
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden.
-- =============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS etsy_rc_invoice_counter (
    year    INTEGER PRIMARY KEY,
    last_nr INTEGER NOT NULL DEFAULT 0
);

COMMIT;
