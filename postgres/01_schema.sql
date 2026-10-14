-- =============================================================================
-- Schema: Bestellmanagement für Etsy + eBay
-- Wird nur ausgeführt, wenn das Daten-Volume noch leer ist.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Hilfsfunktion: updated_at automatisch setzen
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
    id               SERIAL PRIMARY KEY,
    order_id         TEXT UNIQUE NOT NULL,
    source           TEXT NOT NULL CHECK (source IN ('etsy', 'ebay')),
    order_date       TIMESTAMPTZ NOT NULL,
    buyer_name       TEXT,
    buyer_email      TEXT,
    buyer_street     TEXT,
    buyer_city       TEXT,
    buyer_zip        TEXT,
    buyer_country    TEXT,
    items_json       JSONB,
    subtotal         NUMERIC(10,2),
    shipping_cost    NUMERIC(10,2),
    total            NUMERIC(10,2),
    currency         TEXT DEFAULT 'EUR',
    status           TEXT DEFAULT 'paid' CHECK (status IN ('paid', 'shipped', 'completed', 'cancelled')),
    tracking_number  TEXT,
    carrier          TEXT,
    invoice_number   TEXT,
    invoice_path     TEXT,
    is_digital       BOOLEAN DEFAULT FALSE,
    lexoffice_id     TEXT,
    notion_page_id   TEXT,
    etsy_rc_invoice_number TEXT,    -- Reverse-Charge-Rechnung an Etsy, die die digitalen Artikel enthält
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_orders_status      ON orders (status);
CREATE INDEX idx_orders_source      ON orders (source);
CREATE INDEX idx_orders_order_date  ON orders (order_date DESC);
CREATE INDEX idx_orders_etsy_rc     ON orders (etsy_rc_invoice_number);

-- ---------------------------------------------------------------------------
-- etsy_transactions
-- ---------------------------------------------------------------------------
CREATE TABLE etsy_transactions (
    id               SERIAL PRIMARY KEY,
    transaction_id   TEXT UNIQUE NOT NULL,
    order_id         TEXT,
    type             TEXT NOT NULL CHECK (type IN (
                         'sale', 'fee_transaction', 'fee_listing',
                         'fee_ads', 'fee_processing', 'refund',
                         'tax',              -- eigene Steuern (Rechnungen, manuell)
                         'marketplace_tax',  -- von Etsy als 'deemed supplier' einbehalten/abgeführt
                         'payout'
                     )),
    description      TEXT,
    amount           NUMERIC(10,2),
    fee_amount       NUMERIC(10,2),
    net_amount       NUMERIC(10,2),
    currency         TEXT DEFAULT 'EUR',
    date             TIMESTAMPTZ NOT NULL,
    month            TEXT,          -- Format: '2026-04' für Gruppierung
    lexoffice_synced BOOLEAN DEFAULT FALSE,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_etsy_tx_month           ON etsy_transactions (month);
CREATE INDEX idx_etsy_tx_synced          ON etsy_transactions (lexoffice_synced);
CREATE INDEX idx_etsy_tx_order_id        ON etsy_transactions (order_id);

-- ---------------------------------------------------------------------------
-- app_config  (Key-Value-Store für API-Credentials und Konfiguration,
--              gruppiert nach scope: 'etsy', 'notion', 'lexoffice', ...)
-- ---------------------------------------------------------------------------
CREATE TABLE app_config (
    scope  TEXT NOT NULL,
    key    TEXT NOT NULL,
    value  TEXT NOT NULL,
    PRIMARY KEY (scope, key)
);

-- ---------------------------------------------------------------------------
-- etsy_rc_invoices  (monatliche Reverse-Charge-Rechnungen an Etsy über die
--                    digitalen Verkäufe; Etsy ist dort Plattform/Leistungs-
--                    empfänger und führt die VAT selbst ab)
-- Positionen, Verkäufer und Empfänger werden beim Anlegen eingefroren:
-- ein erneuter PDF-Druck liefert exakt dieselbe Rechnung (GoBD).
-- ---------------------------------------------------------------------------
CREATE TABLE etsy_rc_invoices (
    id               SERIAL PRIMARY KEY,
    period           DATE NOT NULL UNIQUE,      -- erster Tag des abgerechneten Monats
    invoice_number   TEXT NOT NULL UNIQUE,      -- aus invoice_counter (gemeinsamer Nummernkreis)
    invoice_date     DATE NOT NULL,
    service_from     DATE NOT NULL,             -- Leistungszeitraum
    service_to       DATE NOT NULL,
    order_count      INTEGER NOT NULL,
    net_total        NUMERIC(12,2) NOT NULL,    -- Rechnungsbetrag (ohne VAT)
    gross_total      NUMERIC(12,2),             -- nur Abgleich: von Käufern gezahlt inkl. VAT
    marketplace_tax  NUMERIC(12,2),             -- nur Abgleich: von Etsy einbehaltene VAT/Steuer
    currency         TEXT NOT NULL DEFAULT 'EUR',
    lines_json       JSONB NOT NULL,
    seller_json      JSONB NOT NULL,
    recipient_json   JSONB NOT NULL,
    payment_note     TEXT,
    note             TEXT,                      -- Erläuterung auf der Rechnung
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- invoice_counter
-- ---------------------------------------------------------------------------
CREATE TABLE invoice_counter (
    year    INTEGER PRIMARY KEY,
    last_nr INTEGER DEFAULT 0
);

-- Startwert für das aktuelle Jahr einfügen
INSERT INTO invoice_counter (year, last_nr)
VALUES (EXTRACT(YEAR FROM NOW())::INTEGER, 0)
ON CONFLICT (year) DO NOTHING;
