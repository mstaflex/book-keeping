-- =============================================================================
-- 004 · etsy_transactions: neue Typen, Original-Angaben von Etsy, Umbuchung
--
-- - type 'transfer': Geldbewegung ohne Ertrag/Aufwand (z.B. billing_payment:
--   Etsy belastet die Karte, um einen negativen Saldo auszugleichen).
-- - type 'other': Ledger-Typ, den Workflow 02 nicht kennt. Vorher landeten
--   solche Einträge stillschweigend bei 'fee_transaction'.
-- - ledger_type / reference_type / reference_id: Original-Angaben von Etsy,
--   damit sich Einträge später neu einordnen und Bestellungen zuordnen lassen.
-- - Bestehende Zeilen werden umgebucht. Etsy liefert den Ledger-Typ auch im
--   Feld description; daran richtet sich die Umbuchung.
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden.
-- =============================================================================
BEGIN;

ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS ledger_type    TEXT;
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS reference_type TEXT;
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS reference_id   TEXT;

ALTER TABLE etsy_transactions DROP CONSTRAINT IF EXISTS etsy_transactions_type_check;
ALTER TABLE etsy_transactions ADD CONSTRAINT etsy_transactions_type_check CHECK (type IN (
    'sale',
    'fee_transaction', 'fee_listing',
    'fee_ads', 'fee_processing', 'refund',
    'tax',
    'marketplace_tax',
    'payout',
    'transfer',
    'other'
));

-- Listing-Verlängerungen, die bisher als Transaktionsgebühr galten
UPDATE etsy_transactions
SET type = 'fee_listing'
WHERE type = 'fee_transaction'
  AND lower(description) IN ('auto_renew_expired', 'renew_expired', 'renew_sold');

-- Kartenbelastung zum Ausgleich eines negativen Saldos: kein Gebühren-Ertrag
UPDATE etsy_transactions
SET type = 'transfer'
WHERE type <> 'transfer'
  AND lower(description) = 'billing_payment';

COMMIT;
