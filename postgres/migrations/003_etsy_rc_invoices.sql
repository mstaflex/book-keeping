-- =============================================================================
-- 003 · Monatliche Reverse-Charge-Rechnungen an Etsy (Workflow 05)
--
-- etsy_rc_invoices:             eine Rechnung pro Monat, Positionen/Parteien
--                               als unveränderlicher Snapshot
-- orders.etsy_rc_invoice_number: markiert, welche Bestellung bereits auf einer
--                               Etsy-Rechnung steht (verhindert Doppelabrechnung)
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden.
-- =============================================================================
BEGIN;

ALTER TABLE orders ADD COLUMN IF NOT EXISTS etsy_rc_invoice_number TEXT;
CREATE INDEX IF NOT EXISTS idx_orders_etsy_rc ON orders (etsy_rc_invoice_number);

CREATE TABLE IF NOT EXISTS etsy_rc_invoices (
    id               SERIAL PRIMARY KEY,
    period           DATE NOT NULL UNIQUE,
    invoice_number   TEXT NOT NULL UNIQUE,
    invoice_date     DATE NOT NULL,
    service_from     DATE NOT NULL,
    service_to       DATE NOT NULL,
    order_count      INTEGER NOT NULL,
    net_total        NUMERIC(12,2) NOT NULL,
    gross_total      NUMERIC(12,2),
    marketplace_tax  NUMERIC(12,2),
    currency         TEXT NOT NULL DEFAULT 'EUR',
    lines_json       JSONB NOT NULL,
    seller_json      JSONB NOT NULL,
    recipient_json   JSONB NOT NULL,
    payment_note     TEXT,
    note             TEXT,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

COMMIT;
