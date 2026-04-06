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
    created_at       TIMESTAMPTZ DEFAULT NOW(),
    updated_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_orders_status      ON orders (status);
CREATE INDEX idx_orders_source      ON orders (source);
CREATE INDEX idx_orders_order_date  ON orders (order_date DESC);

-- ---------------------------------------------------------------------------
-- etsy_transactions
-- ---------------------------------------------------------------------------
CREATE TABLE etsy_transactions (
    id               SERIAL PRIMARY KEY,
    transaction_id   TEXT UNIQUE NOT NULL,
    order_id         TEXT,
    type             TEXT NOT NULL CHECK (type IN (
                         'sale', 'fee_transaction', 'fee_listing',
                         'fee_ads', 'fee_processing', 'refund', 'tax', 'payout'
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
