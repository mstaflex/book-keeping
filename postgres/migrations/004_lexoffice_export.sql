-- =============================================================================
-- 004 · Etsy-Zahlungskonto → Lexoffice: Monats-CSV (Ersatz für PayJoe)
--
-- Aus etsy_transactions entsteht pro abgeschlossenem Monat eine kleine CSV
-- mit wenigen Summenzeilen für das Lexoffice-„Konto ohne Anbindung“
-- (Etsy-Zahlungskonto). Hintergrund und Buchungslogik:
-- docs/lexoffice-etsy-export.md
--
--   etsy_transactions          + Etsy-Rohdaten je Ledger-Eintrag (ledger_type,
--                                reference_*, balance, sequence_number);
--                                type erlaubt zusätzlich 'card_payment' und
--                                'unknown'
--   etsy_ledger_classified     View: jede Etsy-Buchung mit Zeilenart für den
--                                Export und Monat in deutscher Zeit
--   lexoffice_exports          erzeugte Dateien (Inhalt, Prüfsumme, enthaltene
--                                Buchungen, Bestätigung des Imports)
--   lexoffice_export_build()   Vorschau/Prüfung, schreibt nichts
--   lexoffice_export_create()  erzeugt die Datei eines Monats (idempotent)
--   lexoffice_export_confirm() Import in Lexoffice bestätigen
--
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden.
-- =============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- Etsy-Rohdaten je Ledger-Eintrag. Workflow 02 ergänzt sie für bestehende
-- Zeilen beim nächsten Lauf automatisch (einmaliger Backfill).
--   ledger_type     Etsys eigener Typ (z.B. PAYMENT_GROSS, DISBURSE2) –
--                   daraus leitet Workflow 02 die Spalte type ab
--   reference_*     Objekt, auf das sich die Buchung bezieht (receipt, payment …)
--   balance         Etsy-Guthaben direkt nach der Buchung (EUR) – damit prüft
--                   der Export, dass keine Buchung fehlt
--   sequence_number Etsys Reihenfolge der Buchungen
-- ---------------------------------------------------------------------------
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS ledger_type     TEXT;
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS reference_type  TEXT;
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS reference_id    TEXT;
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS balance         NUMERIC(12,2);
ALTER TABLE etsy_transactions ADD COLUMN IF NOT EXISTS sequence_number BIGINT;

-- 'card_payment': Etsy belastet die Karte des Verkäufers, um ein negatives
--                 Guthaben auszugleichen (billing_payment) – KEINE Gebühr.
-- 'unknown':      Etsy-Typ, den Workflow 02 nicht kennt. Wird gespeichert,
--                 damit der Sync weiterläuft; der Export bricht dann ab.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'etsy_transactions_type_check'
                   AND pg_get_constraintdef(oid) LIKE '%card_payment%') THEN
    ALTER TABLE etsy_transactions DROP CONSTRAINT IF EXISTS etsy_transactions_type_check;
    ALTER TABLE etsy_transactions ADD CONSTRAINT etsy_transactions_type_check CHECK (type IN (
        'sale', 'fee_transaction', 'fee_listing',
        'fee_ads', 'fee_processing', 'refund',
        'tax',              -- eigene Steuern (Rechnungen, manuell)
        'marketplace_tax',  -- von Etsy als 'deemed supplier' einbehalten/abgeführt
        'payout',
        'card_payment',     -- Kartenzahlung des Verkäufers an Etsy (billing_payment)
        'unknown'           -- von Workflow 02 nicht erkannter Etsy-Typ
    ));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_etsy_tx_date ON etsy_transactions (date);

-- ---------------------------------------------------------------------------
-- lexoffice_exports: eine Zeile je erzeugter Datei. Der Lexoffice-Import hat
-- keine Dublettenprüfung und lässt sich nicht rückgängig machen – deshalb
-- wird ein Monat nur auf ausdrücklichen Wunsch (regenerate) neu erzeugt und
-- nach bestätigtem Import nie mehr. Ersetzte Versionen bleiben erhalten.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lexoffice_exports (
    id               SERIAL PRIMARY KEY,
    month            TEXT NOT NULL,              -- 'YYYY-MM' (deutsche Zeit)
    version          INTEGER NOT NULL DEFAULT 1,
    file_name        TEXT NOT NULL,
    csv              TEXT NOT NULL,              -- Dateiinhalt, unverändert
    checksum         TEXT NOT NULL,              -- SHA-256 des Dateiinhalts
    line_count       INTEGER NOT NULL,
    total            NUMERIC(12,2) NOT NULL,     -- Summe aller Zeilen
    proforma_number  TEXT,                       -- Proformarechnung der Erlöszeile
    transaction_ids  TEXT[] NOT NULL,            -- enthaltene Etsy-Buchungen
    report           JSONB NOT NULL,             -- Prüfbericht beim Erzeugen
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    confirmed_at     TIMESTAMPTZ,                -- Import in Lexoffice bestätigt
    superseded_at    TIMESTAMPTZ,                -- durch neuere Version ersetzt
    UNIQUE (month, version)
);
-- Je Monat höchstens eine gültige (nicht ersetzte) Datei
CREATE UNIQUE INDEX IF NOT EXISTS idx_lexoffice_exports_current
    ON lexoffice_exports (month) WHERE superseded_at IS NULL;

-- ---------------------------------------------------------------------------
-- etsy_ledger_classified: Zeilenart je Etsy-Buchung
--   SALE          Verkauf, von Etsy einbehaltene VAT/Sales Tax, Erstattung
--   FEE           Etsy-Gebühren
--   PAYOUT        Auszahlung aufs Bankkonto
--   CARD_PAYMENT  Kartenzahlung des Verkäufers (gleicht negatives Guthaben aus)
--   UNKNOWN       alles andere → Export bricht ab
-- month_berlin/date_berlin: Monat und Tag in deutscher Zeit (nicht UTC und
-- nicht die Spalte month, die in Altdaten abweichen kann).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW etsy_ledger_classified AS
SELECT
  t.id, t.transaction_id, t.order_id, t.type, t.description,
  t.amount, t.currency, t.date, t.month, t.lexoffice_synced, t.created_at,
  t.ledger_type, t.reference_type, t.reference_id, t.balance, t.sequence_number,
  CASE
    WHEN t.type = 'payout' THEN 'PAYOUT'
    -- Ältere Versionen von Workflow 02 haben billing_payment als Gebühr geführt
    WHEN t.type = 'card_payment'
      OR (t.type = 'fee_transaction' AND lower(t.description) = 'billing_payment') THEN 'CARD_PAYMENT'
    WHEN t.type IN ('sale', 'marketplace_tax', 'refund') THEN 'SALE'
    WHEN t.type IN ('fee_transaction', 'fee_listing', 'fee_ads', 'fee_processing') THEN 'FEE'
    ELSE 'UNKNOWN'
  END AS line_class,
  CASE t.type
    WHEN 'fee_ads'         THEN 'Ads'
    WHEN 'fee_transaction' THEN 'Transaction'
    WHEN 'fee_processing'  THEN 'Processing'
    WHEN 'fee_listing'     THEN 'Listing'
  END AS fee_kind,
  to_char(t.date AT TIME ZONE 'Europe/Berlin', 'YYYY-MM') AS month_berlin,
  (t.date AT TIME ZONE 'Europe/Berlin')::date             AS date_berlin
FROM etsy_transactions t;

-- ---------------------------------------------------------------------------
-- Betrag im Format der CSV: Dezimalkomma, ohne Tausenderpunkt, Minus davor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lexoffice_amount(p NUMERIC)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $fn$
  SELECT replace(to_char(p, 'FM999999990.00'), '.', ',')
$fn$;

-- ---------------------------------------------------------------------------
-- Prüfbericht als Text (für Mail und psql), aus dem Ergebnis von
-- lexoffice_export_build/_create/_confirm
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lexoffice_export_report_text(p JSONB)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  s   JSONB := COALESCE(p->'summary', '{}'::jsonb);
  e   JSONB := p->'existing_export';
  l   JSONB;
  x   TEXT;
  t   TEXT;
  eur CONSTANT TEXT := ' €';
BEGIN
  t := format('Etsy-Zahlungskonto → Lexoffice, Monat %s', COALESCE(p->>'label', p->>'month', '?')) || E'\n'
    || 'Status: ' || CASE p->>'status'
         WHEN 'preview'           THEN 'Vorschau – nichts gespeichert, Datei nicht importieren'
         WHEN 'created'           THEN format('Datei %s erzeugt', p->>'file_name')
         WHEN 'regenerated'       THEN format('Datei %s neu erzeugt (ersetzt Version %s)', p->>'file_name', p->>'replaced_version')
         WHEN 'existing'          THEN format('Datei %s wurde bereits am %s erzeugt', p->>'file_name',
                                              to_char((p->>'created_at')::timestamptz AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'))
         WHEN 'confirmed'         THEN format('Import von %s bestätigt, %s Etsy-Buchungen als übertragen markiert',
                                              p->>'file_name', p->>'transactions_marked')
         WHEN 'already_confirmed' THEN format('Import von %s war bereits am %s bestätigt', p->>'file_name',
                                              to_char((p->>'confirmed_at')::timestamptz AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY HH24:MI'))
         ELSE 'FEHLER – keine Datei erzeugt'
       END || E'\n';

  IF jsonb_array_length(COALESCE(p->'errors', '[]')) > 0 THEN
    t := t || E'\nFehler:\n';
    FOR x IN SELECT jsonb_array_elements_text(p->'errors') LOOP
      t := t || '  - ' || x || E'\n';
    END LOOP;
  END IF;

  IF jsonb_array_length(COALESCE(p->'lines', '[]')) > 0 THEN
    t := t || CASE WHEN (p->>'ok')::boolean THEN E'\nZeilen der Datei:\n'
                   ELSE E'\nZeilen, wie sie ohne die Fehler entstünden (nicht importieren):\n' END;
    FOR l IN SELECT jsonb_array_elements(p->'lines') LOOP
      t := t || format('  %s %10s  %s', l->>'date_de', l->>'amount_de', l->>'purpose') || E'\n';
    END LOOP;
    t := t || format('  %-10s %10s', 'Summe', lexoffice_amount((p->>'line_sum')::numeric)) || E'\n';
  END IF;

  IF s ? 'transaction_count' THEN
    t := t || E'\nKontrolle:\n'
      || format('  Etsy-Buchungen im Monat:      %s, Summe %s%s (Summe der Zeilen: %s%s)',
                s->>'transaction_count', lexoffice_amount((s->>'transaction_sum')::numeric), eur,
                lexoffice_amount((p->>'line_sum')::numeric), eur) || E'\n'
      || format('  Guthaben Monatsanfang:        %s%s%s', lexoffice_amount((s->>'opening_balance')::numeric), eur,
                CASE WHEN s->>'etsy_opening_balance' IS NOT NULL
                     THEN format(' (laut Etsy %s%s)', lexoffice_amount((s->>'etsy_opening_balance')::numeric), eur) ELSE '' END) || E'\n'
      || format('  Guthaben Monatsende:          %s%s%s', lexoffice_amount((s->>'closing_balance')::numeric), eur,
                CASE WHEN s->>'etsy_closing_balance' IS NOT NULL
                     THEN format(' (laut Etsy %s%s)', lexoffice_amount((s->>'etsy_closing_balance')::numeric), eur) ELSE '' END) || E'\n'
      || format('  Digitale Verkäufe netto:      %s%s (%s %s)%s', lexoffice_amount((s->>'digital_sales')::numeric), eur,
                s->>'digital_sales_count', CASE WHEN s->>'digital_sales_count' = '1' THEN 'Verkauf' ELSE 'Verkäufe' END,
                CASE WHEN s->>'proforma_number' IS NOT NULL
                     THEN format(' – Proformarechnung %s%s', s->>'proforma_number',
                                 CASE WHEN s->>'proforma_net_total' IS NOT NULL
                                      THEN format(' über %s%s', lexoffice_amount((s->>'proforma_net_total')::numeric), eur) ELSE '' END)
                     ELSE '' END) || E'\n'
      || format('  Physische Verkäufe brutto:    %s%s', lexoffice_amount((s->>'physical_sales')::numeric), eur) || E'\n'
      || format('  Etsy-Gebühren:                %s%s', lexoffice_amount((s->>'fees')::numeric), eur) || E'\n'
      || format('  Kartenzahlungen an Etsy:      %s%s', lexoffice_amount((s->>'card_payments')::numeric), eur) || E'\n'
      || format('  Auszahlungen:                 %s%s (%s) – mit den Eingängen auf dem Bankkonto abgleichen',
                lexoffice_amount((s->>'payouts')::numeric), eur, s->>'payout_count') || E'\n';
  END IF;

  IF jsonb_array_length(COALESCE(p->'warnings', '[]')) > 0 THEN
    t := t || E'\nHinweise:\n';
    FOR x IN SELECT jsonb_array_elements_text(p->'warnings') LOOP
      t := t || '  - ' || x || E'\n';
    END LOOP;
  END IF;

  IF p->>'status' = 'preview' AND jsonb_typeof(e) = 'object' THEN
    t := t || E'\n' || format('Für %s gibt es bereits die Datei %s vom %s%s.', p->>'label', e->>'file_name',
                to_char((e->>'created_at')::timestamptz AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
                CASE WHEN e->>'confirmed_at' IS NOT NULL THEN ', Import bestätigt' ELSE ', Import noch nicht bestätigt' END)
      || CASE WHEN (p->>'ok')::boolean AND p->>'checksum' = e->>'checksum' THEN ' Die Vorschau ist identisch.'
              WHEN (p->>'ok')::boolean THEN ' ACHTUNG: Die Vorschau weicht davon ab.'
              ELSE '' END || E'\n';
  END IF;

  t := t || E'\nNächste Schritte:\n' || CASE
    WHEN p->>'status' = 'preview' AND (p->>'ok')::boolean THEN
         '  Vorschau mit dem Etsy-Zahlungskonto-Auszug und der Proformarechnung vergleichen.' || E'\n'
      || format('  Datei erzeugen: {"month": "%s", "action": "create"}', p->>'month') || E'\n'
    WHEN p->>'status' IN ('created', 'regenerated')
      OR (p->>'status' = 'existing' AND p->>'confirmed_at' IS NULL) THEN
         '  1. Datei mit dem Etsy-Zahlungskonto-Auszug vergleichen.' || E'\n'
      || '  2. In Lexoffice beim Konto „Etsy-Zahlungskonto“ importieren und die Vorschau prüfen.' || E'\n'
      || '     Nur EINMAL importieren: Lexoffice erkennt keine Dubletten.' || E'\n'
      || format('  3. Import bestätigen: {"month": "%s", "action": "confirm"}', p->>'month') || E'\n'
    WHEN p->>'status' IN ('existing', 'confirmed', 'already_confirmed') THEN
         '  Keine – der Monat ist erledigt. Datei nicht erneut importieren.' || E'\n'
    ELSE '  Fehler beheben, dann erneut eine Vorschau erzeugen.' || E'\n'
  END;
  RETURN t;
END
$fn$;

-- ---------------------------------------------------------------------------
-- lexoffice_export_build(month, proforma_number)
--
-- Erzeugt Zeilen, CSV und Prüfbericht eines Monats und schreibt NICHTS in die
-- Datenbank (Vorschau / Dry-Run). Rückgabe als JSON; ok = false heißt: keine
-- Datei, Gründe in errors. Der Betrag ist vorzeichenbehaftet wie bei Etsy:
-- Zugang aufs Etsy-Guthaben positiv, Abgang negativ.
--
-- Zeilen je Monat:
--   Digitale Verkäufe netto  1 Summe, letzter Tag  → Proformarechnung an Etsy
--   Etsy-Gebühren            1 Summe, letzter Tag  → Etsy-Gebührenrechnung
--   Auszahlung               je Auszahlung         → Geldtransit zum Bankkonto
--   Kartenzahlung            je Zahlung            → Ausgleich negatives Guthaben
--   Physischer Verkauf       je Bestellung, brutto → Kundenrechnung (Workflow 04)
-- „Netto“ heißt: Verkauf minus der von Etsy einbehaltenen VAT. Die VAT schuldet
-- Etsy, nicht der Shop; sie taucht deshalb nie als eigene Zeile auf.
--
-- proforma_number: nur nötig, wenn die Proformarechnung des Monats nicht von
-- Workflow 05 stammt (z.B. vor etsy_rc.start_date von Hand geschrieben).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lexoffice_export_build(p_month TEXT, p_proforma_number TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_month       TEXT := btrim(COALESCE(p_month, ''));
  v_proforma_in TEXT := NULLIF(btrim(COALESCE(p_proforma_number, '')), '');
  v_now_month   TEXT := to_char(NOW() AT TIME ZONE 'Europe/Berlin', 'YYYY-MM');
  v_start       DATE;
  v_last_day    DATE;
  v_label       TEXT;
  v_cfg_start   TEXT;
  v_errors      TEXT[] := '{}';
  v_warnings    TEXT[] := '{}';
  v_lines       JSONB := '[]';
  v_tx_ids      TEXT[];
  v_tx_count    INTEGER;
  v_tx_sum      NUMERIC(12,2);
  v_digital     NUMERIC(12,2) := 0;
  v_digital_n   INTEGER := 0;
  v_digital_tx  TEXT[] := '{}';
  v_dig_orders  JSONB := '{}';          -- order_id → digitaler Betrag laut Etsy-Konto
  v_unassigned  INTEGER := 0;
  v_physical    NUMERIC(12,2) := 0;
  v_phys_part   NUMERIC(12,2);
  v_fees        NUMERIC(12,2);
  v_fee_tx      TEXT[];
  v_fee_detail  TEXT;
  v_payouts     NUMERIC(12,2) := 0;
  v_payout_n    INTEGER := 0;
  v_cards       NUMERIC(12,2) := 0;
  v_rc          etsy_rc_invoices%ROWTYPE;
  v_rc_found    BOOLEAN;
  v_proforma    TEXT;
  v_line_sum    NUMERIC(12,2);
  v_open_db     NUMERIC(12,2);
  v_open_etsy   NUMERIC(12,2);
  v_close_etsy  NUMERIC(12,2);
  v_no_balance  INTEGER;
  v_exp         lexoffice_exports%ROWTYPE;
  v_exp_found   BOOLEAN;
  v_ok          BOOLEAN;
  v_csv         TEXT;
  v_checksum    TEXT;
  v_n           INTEGER;
  v_ids         TEXT;
  v_txt         TEXT;
  v_result      JSONB;
  r             RECORD;
BEGIN
  IF v_month !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN
    v_result := jsonb_build_object('month', v_month, 'ok', false, 'status', 'error',
      'errors', jsonb_build_array(format('Ungültiger Monat „%s“ – erwartet wird YYYY-MM, z.B. 2026-09', v_month)),
      'warnings', '[]'::jsonb, 'lines', '[]'::jsonb);
    RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
  END IF;
  v_start    := to_date(v_month || '-01', 'YYYY-MM-DD');
  v_last_day := (v_start + INTERVAL '1 month')::date - 1;
  v_label    := to_char(v_start, 'MM/YYYY');

  -- 1. Rahmen: nur abgeschlossene Monate, nicht vor dem Umstiegs-Stichtag ----
  IF v_month >= v_now_month THEN
    v_errors := array_append(v_errors, format(
      '%s ist noch nicht abgeschlossen – exportiert werden nur vergangene Monate', v_label));
  END IF;
  SELECT value INTO v_cfg_start FROM app_config WHERE scope = 'lexoffice' AND key = 'start_month';
  IF v_cfg_start IS NULL THEN
    v_errors := array_append(v_errors,
      'lexoffice.start_month fehlt in app_config (Variable LEXOFFICE_START_MONTH, README Schritt 5): '
      || 'erster Monat, der über diese Datei (statt z.B. über PayJoe) nach Lexoffice kommt');
  ELSIF v_cfg_start !~ '^\d{4}-(0[1-9]|1[0-2])$' THEN
    v_errors := array_append(v_errors, format(
      'lexoffice.start_month „%s“ – erwartet wird YYYY-MM', v_cfg_start));
    v_cfg_start := NULL;
  ELSIF v_month < v_cfg_start THEN
    v_errors := array_append(v_errors, format(
      '%s liegt vor lexoffice.start_month (%s): dieser Zeitraum ist bereits anders gebucht (z.B. PayJoe) '
      || 'und darf nicht doppelt nach Lexoffice', v_label, v_cfg_start));
  END IF;

  -- 2. Buchungen des Monats -------------------------------------------------
  SELECT COUNT(*), COALESCE(SUM(amount), 0),
         COALESCE(array_agg(transaction_id ORDER BY date, transaction_id), '{}')
    INTO v_tx_count, v_tx_sum, v_tx_ids
    FROM etsy_ledger_classified WHERE month_berlin = v_month;
  IF v_tx_count = 0 THEN
    v_errors := array_append(v_errors, format('Keine Etsy-Buchungen in %s – keine Datei nötig', v_label));
  END IF;

  SELECT COUNT(*), string_agg(transaction_id, ', ' ORDER BY date) INTO v_n, v_ids
    FROM etsy_ledger_classified WHERE month_berlin = v_month AND ledger_type IS NULL;
  IF v_n > 0 THEN
    v_errors := array_append(v_errors, format(
      '%s Etsy-Buchung(en) ohne Etsy-Rohdaten (ledger_type, Kontostand): Workflow 02 in der aktuellen '
      || 'Version importieren und einmal laufen lassen, er ergänzt sie automatisch (IDs %s)', v_n, v_ids));
  END IF;

  FOR r IN SELECT * FROM etsy_ledger_classified
           WHERE month_berlin = v_month AND line_class = 'UNKNOWN' ORDER BY date LOOP
    v_errors := array_append(v_errors, format(
      'Unbekannte Etsy-Buchung %s vom %s: type=%s, ledger_type=%s, description=%s, Betrag %s € – '
      || 'erst Zuordnung klären (Workflow 02 und View etsy_ledger_classified), dann exportieren',
      r.transaction_id, to_char(r.date_berlin, 'DD.MM.YYYY'), r.type, COALESCE(r.ledger_type, '–'),
      COALESCE(r.description, '–'), lexoffice_amount(r.amount)));
  END LOOP;

  SELECT string_agg(transaction_id || ' (' || COALESCE(currency, '?') || ')', ', ') INTO v_ids
    FROM etsy_ledger_classified WHERE month_berlin = v_month AND currency IS DISTINCT FROM 'EUR';
  IF v_ids IS NOT NULL THEN
    v_errors := array_append(v_errors, 'Buchungen in Fremdwährung, nur EUR wird unterstützt: ' || v_ids);
  END IF;

  SELECT string_agg(c.transaction_id || ' (' || e.month || ')', ', ') INTO v_ids
    FROM etsy_ledger_classified c
    JOIN lexoffice_exports e ON e.superseded_at IS NULL AND e.month <> v_month
                            AND c.transaction_id = ANY (e.transaction_ids)
   WHERE c.month_berlin = v_month;
  IF v_ids IS NOT NULL THEN
    v_errors := array_append(v_errors, 'Buchungen stehen bereits in der Datei eines anderen Monats: ' || v_ids);
  END IF;

  SELECT string_agg(transaction_id || ' (month=' || COALESCE(month, '–') || ', Datum '
                    || to_char(date_berlin, 'DD.MM.YYYY') || ')', ', ') INTO v_ids
    FROM etsy_ledger_classified
   WHERE (month_berlin = v_month OR month = v_month) AND month IS DISTINCT FROM month_berlin;
  IF v_ids IS NOT NULL THEN
    v_warnings := array_append(v_warnings,
      'Spalte month passt nicht zum Buchungsdatum, maßgeblich ist das Datum in deutscher Zeit: ' || v_ids);
  END IF;

  -- 3. Verkäufe: digital (Summe) oder physisch (einzeln, brutto) ------------
  -- Etsy bucht Verkauf, VAT und Erstattungen je Bestellung. Digital/physisch
  -- steht nur in orders.items_json; ohne Bestellnummer gilt eine Buchung als
  -- digital (Warnung). Die Summe wird unten gegen die Proformarechnung
  -- geprüft, ein falsch zugeordneter physischer Verkauf fällt dort auf.
  FOR r IN
    WITH s AS (
      SELECT c.order_id, c.transaction_id, c.type, c.amount, c.date, c.date_berlin,
             o.order_id IS NOT NULL AS order_found, o.invoice_number,
             o.items_json, o.subtotal, o.shipping_cost
        FROM etsy_ledger_classified c
        LEFT JOIN orders o ON o.order_id = c.order_id
       WHERE c.month_berlin = v_month AND c.line_class = 'SALE'
    ), g AS (
      SELECT s.order_id,
             bool_or(s.order_found)                                        AS order_found,
             MAX(s.invoice_number)                                         AS invoice_number,
             (array_agg(s.items_json))[1]                                  AS items_json,
             MAX(s.subtotal)                                               AS subtotal,
             MAX(s.shipping_cost)                                          AS shipping_cost,
             SUM(s.amount)                                                 AS amount,
             COUNT(*) FILTER (WHERE s.type = 'sale' AND s.amount > 0)      AS sale_count,
             COUNT(*) FILTER (WHERE s.type = 'refund')                     AS refund_count,
             COALESCE(MIN(s.date_berlin) FILTER (WHERE s.type = 'sale'),
                      MIN(s.date_berlin))                                  AS sale_date,
             MIN(s.date)                                                   AS first_ts,
             array_agg(s.transaction_id ORDER BY s.date, s.transaction_id) AS tx_ids
        FROM s GROUP BY s.order_id
    )
    SELECT g.*,
           CASE WHEN g.order_id IS NULL     THEN 'unassigned'
                WHEN NOT g.order_found      THEN 'order_missing'
                WHEN COALESCE(x.n_phys, 0) = 0 THEN 'digital'
                WHEN x.n_dig = 0            THEN 'physical'
                ELSE 'mixed' END AS kind,
           -- Rechnungsbetrag der physischen Artikel wie in Workflow 04:
           -- Artikel nach (anteiligem) Gutschein plus Versand
           ROUND(x.phys_sum * COALESCE(g.subtotal, x.all_sum) / NULLIF(x.all_sum, 0), 2)
             + COALESCE(g.shipping_cost, 0) AS phys_invoice_total
      FROM g
      LEFT JOIN LATERAL (
        SELECT COUNT(*) FILTER (WHERE NOT COALESCE((i->>'is_digital')::boolean, false)) AS n_phys,
               COUNT(*) FILTER (WHERE COALESCE((i->>'is_digital')::boolean, false))     AS n_dig,
               SUM(ROUND((i->>'price')::numeric * (i->>'quantity')::numeric, 2))
                 FILTER (WHERE NOT COALESCE((i->>'is_digital')::boolean, false))        AS phys_sum,
               SUM(ROUND((i->>'price')::numeric * (i->>'quantity')::numeric, 2))        AS all_sum
          FROM jsonb_array_elements(COALESCE(g.items_json, '[]'::jsonb)) i
      ) x ON TRUE
     ORDER BY g.first_ts
  LOOP
    IF r.refund_count > 0 THEN
      v_warnings := array_append(v_warnings, format(
        'Erstattung bei Bestellung %s – ist der Verkauf schon auf einer früheren Rechnung, '
        || 'braucht es eine Gutschrift/Storno dazu', COALESCE(r.order_id, '(ohne Nummer)')));
    END IF;

    IF r.kind IN ('physical', 'mixed') THEN
      IF r.kind = 'mixed' AND r.sale_count = 0 THEN
        v_errors := array_append(v_errors, format(
          'Gemischte Bestellung %s: Etsy-Buchungen ohne den Verkauf selbst im Monat – bitte von Hand aufteilen',
          r.order_id));
        CONTINUE;
      END IF;
      -- Gemischte Bestellung: physischer Anteil wie auf der Kundenrechnung,
      -- der Rest gehört zu den digitalen Verkäufen
      v_phys_part := CASE WHEN r.kind = 'mixed' THEN COALESCE(r.phys_invoice_total, 0) ELSE r.amount END;
      IF r.invoice_number IS NULL THEN
        v_warnings := array_append(v_warnings, format(
          'Physische Bestellung %s hat noch keine Rechnung (Workflow 04) – in Lexoffice braucht die Zeile '
          || 'eine Ausgangsrechnung mit USt', r.order_id));
      END IF;
      IF r.kind = 'physical' AND r.sale_count > 0 AND r.phys_invoice_total IS DISTINCT FROM r.amount THEN
        v_warnings := array_append(v_warnings, format(
          'Physische Bestellung %s: Etsy-Konto %s €, Rechnungsbetrag %s € – Abweichung prüfen',
          r.order_id, lexoffice_amount(r.amount), lexoffice_amount(r.phys_invoice_total)));
      END IF;
      IF v_phys_part <> 0 THEN
        v_lines := v_lines || jsonb_build_object(
          'kind', 'PHYSICAL_SALE', 'date', r.sale_date, 'sort_group', 0, 'sort_ts', r.first_ts,
          'amount', v_phys_part, 'order_id', r.order_id, 'transaction_ids', to_jsonb(r.tx_ids),
          'purpose', format('Etsy Verkauf physisch, Bestellung %s, Rechnung %s, %s',
                            r.order_id, COALESCE(r.invoice_number, 'fehlt'),
                            CASE WHEN r.kind = 'mixed' THEN 'physischer Anteil brutto' ELSE 'brutto' END));
      END IF;
      v_physical := v_physical + v_phys_part;
      IF r.kind = 'mixed' THEN
        v_digital    := v_digital + (r.amount - v_phys_part);
        v_digital_tx := v_digital_tx || r.tx_ids;
        IF r.amount - v_phys_part <> 0 THEN
          v_digital_n  := v_digital_n + r.sale_count;
          v_dig_orders := v_dig_orders || jsonb_build_object(r.order_id, r.amount - v_phys_part);
        END IF;
      END IF;
    ELSE
      v_digital    := v_digital + r.amount;
      v_digital_tx := v_digital_tx || r.tx_ids;
      IF r.kind = 'unassigned' THEN
        v_digital_n  := v_digital_n + r.sale_count;
        v_unassigned := cardinality(r.tx_ids);
        v_warnings := array_append(v_warnings, format(
          '%s Verkaufsbuchung(en) ohne Bestellnummer als digitaler Verkauf gezählt (IDs %s) – '
          || 'Workflow 02 trägt die Bestellnummer nach', v_unassigned, array_to_string(r.tx_ids, ', ')));
      ELSE
        -- Im selben Monat voll erstattete Bestellungen (Saldo 0) zählen nicht
        IF r.amount <> 0 THEN
          v_digital_n  := v_digital_n + r.sale_count;
          v_dig_orders := v_dig_orders || jsonb_build_object(r.order_id, r.amount);
        END IF;
        IF r.kind = 'order_missing' THEN
          v_warnings := array_append(v_warnings, format(
            'Bestellung %s fehlt in orders – als digitaler Verkauf gezählt', r.order_id));
        END IF;
      END IF;
    END IF;
  END LOOP;

  -- Physische Bestellungen, die keinem Etsy-Verkauf zugeordnet sind, während
  -- Verkäufe ohne Bestellnummer als digital zählen → könnte falsch sein
  IF v_unassigned > 0 THEN
    SELECT string_agg(o.order_id || ' vom ' || to_char(o.order_date AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'),
                      ', ' ORDER BY o.order_date) INTO v_ids
      FROM orders o
     WHERE o.source = 'etsy' AND o.status <> 'cancelled'
       AND (o.order_date AT TIME ZONE 'Europe/Berlin')::date BETWEEN v_start - 60 AND v_last_day
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(o.items_json) i
                   WHERE NOT COALESCE((i->>'is_digital')::boolean, false))
       AND NOT EXISTS (SELECT 1 FROM etsy_transactions t WHERE t.order_id = o.order_id AND t.type = 'sale');
    IF v_ids IS NOT NULL THEN
      v_warnings := array_append(v_warnings,
        'Physische Bestellung(en) ohne zugeordneten Etsy-Verkauf: ' || v_ids || '. Ist einer der Verkäufe '
        || 'ohne Bestellnummer physisch, stimmt die Erlöszeile nicht (er gehört einzeln und brutto in die Datei)');
    END IF;
  END IF;

  -- Abgleich mit der Proformarechnung (Workflow 05): der Erlösbetrag der
  -- Zeile muss genau dem Rechnungsbetrag entsprechen
  SELECT * INTO v_rc FROM etsy_rc_invoices WHERE period = v_start;
  v_rc_found := FOUND;
  IF v_digital < 0 THEN
    v_errors := array_append(v_errors, format(
      'Digitale Verkäufe %s im Saldo negativ (%s €, Erstattungen?) – dafür braucht es eine Gutschrift bzw. '
      || 'ein Storno zur Proformarechnung, bitte von Hand klären', v_label, lexoffice_amount(v_digital)));
  ELSIF v_digital > 0 AND v_rc_found THEN
    v_proforma := v_rc.invoice_number;
    IF v_proforma_in IS NOT NULL AND v_proforma_in <> v_rc.invoice_number THEN
      v_errors := array_append(v_errors, format(
        'proforma_number %s passt nicht zur Proformarechnung %s aus Workflow 05', v_proforma_in, v_rc.invoice_number));
    END IF;
    IF v_rc.net_total <> v_digital THEN
      v_txt := format('Digitale Verkäufe laut Etsy-Konto %s €, Proformarechnung %s über %s € (Differenz %s €)',
                      lexoffice_amount(v_digital), v_rc.invoice_number, lexoffice_amount(v_rc.net_total),
                      lexoffice_amount(v_digital - v_rc.net_total));
      SELECT string_agg(l->>'order_id' || ' (' || lexoffice_amount((l->>'net')::numeric) || ' €)', ', ') INTO v_ids
        FROM jsonb_array_elements(v_rc.lines_json) l WHERE NOT v_dig_orders ? (l->>'order_id');
      IF v_ids IS NOT NULL THEN
        v_txt := v_txt || '. Auf der Rechnung, aber nicht im Etsy-Konto des Monats: ' || v_ids;
      END IF;
      SELECT string_agg(k || ' (' || lexoffice_amount(v::numeric) || ' €)', ', ') INTO v_ids
        FROM jsonb_each_text(v_dig_orders) AS d(k, v)
       WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rc.lines_json) l WHERE l->>'order_id' = k);
      IF v_ids IS NOT NULL THEN
        v_txt := v_txt || '. Im Etsy-Konto, aber nicht auf der Rechnung: ' || v_ids;
      END IF;
      IF v_unassigned > 0 THEN
        v_txt := v_txt || format('. %s Verkaufsbuchung(en) ohne Bestellnummer', v_unassigned);
      END IF;
      v_errors := array_append(v_errors, v_txt);
    END IF;
  ELSIF v_digital > 0 AND v_proforma_in IS NOT NULL THEN
    v_proforma := v_proforma_in;
    v_warnings := array_append(v_warnings, format(
      'Proformarechnung %s stammt nicht aus Workflow 05 und wurde nicht automatisch geprüft: sie muss über '
      || 'genau %s € lauten', v_proforma_in, lexoffice_amount(v_digital)));
  ELSIF v_digital > 0 THEN
    v_errors := array_append(v_errors, format(
      'Keine Proformarechnung für %s in etsy_rc_invoices: zuerst Workflow 05 für den Monat ausführen. '
      || 'Wurde sie außerhalb geschrieben (vor etsy_rc.start_date), ihre Nummer als proforma_number angeben',
      v_label));
  ELSIF v_rc_found THEN
    v_errors := array_append(v_errors, format(
      'Proformarechnung %s über %s €, aber keine digitalen Verkäufe im Etsy-Konto %s',
      v_rc.invoice_number, lexoffice_amount(v_rc.net_total), v_label));
  END IF;

  IF v_digital <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'kind', 'DIGITAL_SALES', 'date', v_last_day, 'sort_group', 1, 'sort_ts', v_last_day,
      'amount', v_digital, 'transaction_ids', to_jsonb(v_digital_tx),
      'purpose', format('%s Etsy digitale Verkaeufe %s netto (%s %s)',
                        COALESCE(v_proforma, '<Proformarechnung fehlt>'), v_label, v_digital_n,
                        CASE WHEN v_digital_n = 1 THEN 'Verkauf' ELSE 'Verkaeufe' END));
  END IF;

  -- 4. Gebühren: eine Summe, Aufschlüsselung im Verwendungszweck -------------
  SELECT COALESCE(SUM(amount), 0), COALESCE(array_agg(transaction_id ORDER BY date, transaction_id), '{}')
    INTO v_fees, v_fee_tx
    FROM etsy_ledger_classified WHERE month_berlin = v_month AND line_class = 'FEE';
  -- Trenner ' + ' statt ';': das Semikolon ist der Spaltentrenner der CSV
  SELECT string_agg(fee_kind || ' ' || lexoffice_amount(-s), ' + ' ORDER BY ord) INTO v_fee_detail
    FROM (SELECT fee_kind, SUM(amount) AS s,
                 MIN(CASE fee_kind WHEN 'Ads' THEN 1 WHEN 'Transaction' THEN 2
                                   WHEN 'Processing' THEN 3 ELSE 4 END) AS ord
            FROM etsy_ledger_classified
           WHERE month_berlin = v_month AND line_class = 'FEE'
           GROUP BY fee_kind HAVING SUM(amount) <> 0) f;
  IF v_fees <> 0 THEN
    v_lines := v_lines || jsonb_build_object(
      'kind', 'FEES', 'date', v_last_day, 'sort_group', 2, 'sort_ts', v_last_day,
      'amount', v_fees, 'transaction_ids', to_jsonb(v_fee_tx),
      'purpose', format('Etsy-Gebuehren %s (%s)', v_label, v_fee_detail));
  END IF;

  -- 5. Auszahlungen und Kartenzahlungen: je Buchung eine Zeile ----------------
  FOR r IN SELECT * FROM etsy_ledger_classified
           WHERE month_berlin = v_month AND line_class IN ('PAYOUT', 'CARD_PAYMENT')
           ORDER BY date, transaction_id LOOP
    IF r.line_class = 'PAYOUT' THEN
      v_payouts := v_payouts + r.amount;
      v_payout_n := v_payout_n + 1;
    ELSE
      v_cards := v_cards + r.amount;
    END IF;
    v_lines := v_lines || jsonb_build_object(
      'kind', r.line_class, 'date', r.date_berlin, 'sort_group', 0, 'sort_ts', r.date,
      'amount', r.amount, 'transaction_ids', jsonb_build_array(r.transaction_id),
      'purpose', CASE r.line_class
        WHEN 'PAYOUT' THEN format('Etsy Auszahlung %s, ID %s', COALESCE(r.description, r.ledger_type), r.transaction_id)
        ELSE format('Etsy Kartenzahlung (%s) Ausgleich Etsy-Gebuehren, ID %s',
                    COALESCE(r.description, r.ledger_type), r.transaction_id) END);
  END LOOP;

  -- Zeilen sortieren und für die CSV formatieren. Verwendungszweck: ohne
  -- Semikolon/Zeilenumbruch (Spaltentrenner), nie leer, max. 255 Zeichen.
  SELECT COALESCE(jsonb_agg(
           (l - 'sort_group' - 'sort_ts' - 'purpose') || jsonb_build_object(
             'purpose', btrim(regexp_replace(l->>'purpose', '[;"\r\n]+', ' ', 'g')),
             'date_de', to_char((l->>'date')::date, 'DD.MM.YYYY'),
             'amount_de', lexoffice_amount((l->>'amount')::numeric))
           ORDER BY l->>'date', (l->>'sort_group')::int, (l->>'sort_ts')::timestamptz, l->>'purpose'), '[]')
    INTO v_lines FROM jsonb_array_elements(v_lines) l;
  SELECT COALESCE(SUM((l->>'amount')::numeric), 0) INTO v_line_sum FROM jsonb_array_elements(v_lines) l;
  FOR r IN SELECT l->>'purpose' AS purpose FROM jsonb_array_elements(v_lines) l
           WHERE length(l->>'purpose') NOT BETWEEN 1 AND 255 LOOP
    v_errors := array_append(v_errors, format('Verwendungszweck leer oder länger als 255 Zeichen: „%s“', r.purpose));
  END LOOP;

  -- 6. Kontrollsummen ---------------------------------------------------------
  -- a) Summe der Zeilen = Summe aller Etsy-Buchungen des Monats
  IF v_line_sum <> v_tx_sum THEN
    v_errors := array_append(v_errors, format(
      'Kontrollsumme: Zeilen ergeben %s €, die Etsy-Buchungen des Monats %s € (Differenz %s €)',
      lexoffice_amount(v_line_sum), lexoffice_amount(v_tx_sum), lexoffice_amount(v_line_sum - v_tx_sum)));
  END IF;

  -- b) Guthaben: Anfang + Summe = Ende, und gegen Etsys eigenen Kontostand.
  --    Jede Buchung muss den Etsy-Kontostand der vorigen um genau ihren
  --    Betrag verändern, sonst fehlt dazwischen eine Buchung in der Datenbank.
  SELECT COALESCE(SUM(amount), 0) INTO v_open_db FROM etsy_ledger_classified WHERE month_berlin < v_month;
  FOR r IN
    SELECT * FROM (
      SELECT c.transaction_id, c.month_berlin, c.amount, c.balance, c.date_berlin,
             LAG(c.balance)        OVER w AS prev_balance,
             LAG(c.transaction_id) OVER w AS prev_id
        FROM etsy_ledger_classified c
       WHERE c.balance IS NOT NULL AND c.sequence_number IS NOT NULL AND c.month_berlin <= v_month
      WINDOW w AS (ORDER BY c.sequence_number, c.transaction_id)
    ) x
    WHERE x.month_berlin = v_month AND x.prev_balance + x.amount <> x.balance
  LOOP
    v_errors := array_append(v_errors, format(
      'Lücke in den Etsy-Buchungen vor %s vom %s: Kontostand nach %s %s €, plus %s € ergäbe %s €, Etsy meldet '
      || '%s € – es fehlen Buchungen über %s € (Workflow 02 prüfen)',
      r.transaction_id, to_char(r.date_berlin, 'DD.MM.YYYY'), r.prev_id, lexoffice_amount(r.prev_balance),
      lexoffice_amount(r.amount), lexoffice_amount(r.prev_balance + r.amount), lexoffice_amount(r.balance),
      lexoffice_amount(r.balance - r.prev_balance - r.amount)));
  END LOOP;
  SELECT COUNT(*) FILTER (WHERE balance IS NULL OR sequence_number IS NULL) INTO v_no_balance
    FROM etsy_ledger_classified WHERE month_berlin = v_month;
  SELECT balance - amount INTO v_open_etsy FROM etsy_ledger_classified
   WHERE month_berlin = v_month AND balance IS NOT NULL AND sequence_number IS NOT NULL
   ORDER BY sequence_number, transaction_id LIMIT 1;
  SELECT balance INTO v_close_etsy FROM etsy_ledger_classified
   WHERE month_berlin = v_month AND balance IS NOT NULL AND sequence_number IS NOT NULL
   ORDER BY sequence_number DESC, transaction_id DESC LIMIT 1;
  IF v_no_balance > 0 AND v_tx_count > 0 THEN
    v_warnings := array_append(v_warnings, format(
      '%s Buchung(en) ohne Etsy-Kontostand – Vollständigkeit nur teilweise gegen Etsy geprüft', v_no_balance));
  ELSIF v_tx_count > 0 THEN
    IF v_close_etsy - v_open_etsy <> v_tx_sum THEN
      v_errors := array_append(v_errors, format(
        'Etsy-Kontostand %s € → %s €, die Buchungen des Monats ergeben aber %s € – es fehlen Buchungen',
        lexoffice_amount(v_open_etsy), lexoffice_amount(v_close_etsy), lexoffice_amount(v_tx_sum)));
    END IF;
    IF v_open_etsy <> v_open_db THEN
      v_warnings := array_append(v_warnings, format(
        'Guthaben Monatsanfang laut Datenbank %s €, laut Etsy %s €: die Datenbank enthält nicht die ganze '
        || 'Etsy-Historie. Für die Datei unerheblich, in Lexoffice zählt der Anfangsbestand des Kontos',
        lexoffice_amount(v_open_db), lexoffice_amount(v_open_etsy)));
    END IF;
  END IF;

  -- c) Nachzügler: Buchungen aus bereits exportierten Monaten, die in deren
  --    Datei fehlen (z.B. verspätet synchronisiert)
  IF v_cfg_start IS NOT NULL THEN
    FOR r IN
      SELECT c.month_berlin, (e.id IS NOT NULL) AS exported, e.confirmed_at,
             COUNT(*) AS n, string_agg(c.transaction_id, ', ' ORDER BY c.date) AS ids
        FROM etsy_ledger_classified c
        LEFT JOIN lexoffice_exports e ON e.month = c.month_berlin AND e.superseded_at IS NULL
       WHERE c.month_berlin >= v_cfg_start AND c.month_berlin < v_month
         AND NOT EXISTS (SELECT 1 FROM lexoffice_exports x
                          WHERE x.superseded_at IS NULL AND c.transaction_id = ANY (x.transaction_ids))
       GROUP BY c.month_berlin, e.id, e.confirmed_at
       ORDER BY c.month_berlin
    LOOP
      IF r.exported THEN
        v_errors := array_append(v_errors, format(
          'Etsy-Buchung(en) %s aus %s fehlen in der bereits erzeugten Datei dieses Monats (nachträglich '
          || 'synchronisiert). %s', r.ids, r.month_berlin,
          CASE WHEN r.confirmed_at IS NULL
               THEN 'Ist sie noch nicht importiert: den Monat mit regenerate neu erzeugen.'
               ELSE 'Sie ist schon importiert: die Buchungen müssen per eigener CSV nachgetragen werden.' END));
      ELSE
        v_warnings := array_append(v_warnings, format(
          '%s ist noch nicht exportiert (%s Etsy-Buchungen)', r.month_berlin, r.n));
      END IF;
    END LOOP;
  END IF;

  -- 7. Ergebnis ---------------------------------------------------------------
  v_ok := cardinality(v_errors) = 0;
  IF v_ok THEN
    SELECT 'Datum;Betrag;Verwendungszweck' || E'\r\n'
           || string_agg((l->>'date_de') || ';' || (l->>'amount_de') || ';' || (l->>'purpose'), E'\r\n' ORDER BY n)
           || E'\r\n'
      INTO v_csv FROM jsonb_array_elements(v_lines) WITH ORDINALITY AS a(l, n);
    v_checksum := encode(sha256(convert_to(v_csv, 'UTF8')), 'hex');
  END IF;

  SELECT * INTO v_exp FROM lexoffice_exports WHERE month = v_month AND superseded_at IS NULL;
  v_exp_found := FOUND;

  v_result := jsonb_build_object(
    'month', v_month, 'label', v_label, 'ok', v_ok,
    'status', CASE WHEN v_ok THEN 'preview' ELSE 'error' END,
    'errors', to_jsonb(v_errors), 'warnings', to_jsonb(v_warnings),
    'file_name', CASE WHEN v_ok THEN 'etsy_lexoffice_' || v_month || '.csv' END,
    'csv', v_csv, 'checksum', v_checksum,
    'lines', v_lines, 'line_count', jsonb_array_length(v_lines), 'line_sum', v_line_sum,
    'transaction_ids', to_jsonb(v_tx_ids),
    'summary', jsonb_build_object(
      'transaction_count',    v_tx_count,
      'transaction_sum',      v_tx_sum,
      'opening_balance',      v_open_db,
      'closing_balance',      v_open_db + v_tx_sum,
      'etsy_opening_balance', v_open_etsy,
      'etsy_closing_balance', v_close_etsy,
      'digital_sales',        v_digital,
      'digital_sales_count',  v_digital_n,
      'proforma_number',      v_proforma,
      'proforma_net_total',   CASE WHEN v_rc_found THEN v_rc.net_total END,
      'physical_sales',       v_physical,
      'fees',                 v_fees,
      'card_payments',        v_cards,
      'payouts',              v_payouts,
      'payout_count',         v_payout_n),
    'existing_export', CASE WHEN v_exp_found THEN jsonb_build_object(
      'version', v_exp.version, 'file_name', v_exp.file_name, 'checksum', v_exp.checksum,
      'created_at', v_exp.created_at, 'confirmed_at', v_exp.confirmed_at) END);
  RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
END
$fn$;

-- ---------------------------------------------------------------------------
-- lexoffice_export_create(month, proforma_number, regenerate)
--
-- Speichert die Datei eines Monats in lexoffice_exports, wenn alle Prüfungen
-- bestehen. Gibt es schon eine, kommt genau diese zurück (status 'existing');
-- neu erzeugt wird nur mit regenerate = true und nur, solange der Import
-- nicht bestätigt ist. lexoffice_synced bleibt hier unverändert.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lexoffice_export_create(
  p_month TEXT, p_proforma_number TEXT DEFAULT NULL, p_regenerate BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql AS $fn$
DECLARE
  v_month  TEXT := btrim(COALESCE(p_month, ''));
  v_old    lexoffice_exports%ROWTYPE;
  v_found  BOOLEAN;
  v_new    lexoffice_exports%ROWTYPE;
  v_build  JSONB;
  v_result JSONB;
  v_file   TEXT;
BEGIN
  -- Laufen Schedule und Webhook gleichzeitig, wartet der zweite Aufruf
  PERFORM pg_advisory_xact_lock(hashtext('lexoffice_exports'));
  SELECT * INTO v_old FROM lexoffice_exports WHERE month = v_month AND superseded_at IS NULL;
  v_found := FOUND;

  IF v_found AND v_old.confirmed_at IS NOT NULL AND COALESCE(p_regenerate, false) THEN
    v_result := jsonb_build_object('month', v_month, 'label', v_old.report->>'label', 'ok', false, 'status', 'error',
      'errors', jsonb_build_array(format(
        'Der Import von %s wurde am %s bestätigt – der Monat wird nicht neu erzeugt, sonst entstehen '
        || 'Doppelbuchungen. Korrekturen in Lexoffice per Berichtigung/Storno', v_old.file_name,
        to_char(v_old.confirmed_at AT TIME ZONE 'Europe/Berlin', 'DD.MM.YYYY'))),
      'warnings', '[]'::jsonb, 'lines', '[]'::jsonb);
    RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
  END IF;

  -- Eine früher von Hand angegebene Proformanummer gilt weiter, solange es für
  -- den Monat keine Rechnung aus Workflow 05 gibt
  v_build := lexoffice_export_build(v_month, COALESCE(p_proforma_number,
    CASE WHEN v_found AND NOT EXISTS (SELECT 1 FROM etsy_rc_invoices
                                       WHERE to_char(period, 'YYYY-MM') = v_month)
         THEN v_old.proforma_number END));

  -- Bestehende Datei unverändert zurückgeben (auch bei regenerate, wenn sich
  -- nichts geändert hat). Haben sich die Daten geändert, nur darauf hinweisen.
  IF v_found AND (NOT COALESCE(p_regenerate, false) OR v_build->>'checksum' = v_old.checksum) THEN
    v_result := (v_old.report - 'report_text') || jsonb_build_object(
      'status', 'existing', 'ok', true, 'file_name', v_old.file_name, 'csv', v_old.csv,
      'checksum', v_old.checksum, 'version', v_old.version,
      'created_at', v_old.created_at, 'confirmed_at', v_old.confirmed_at, 'existing_export', NULL);
    IF v_build->>'checksum' IS DISTINCT FROM v_old.checksum THEN
      v_result := jsonb_set(v_result, '{warnings}', COALESCE(v_result->'warnings', '[]') || jsonb_build_array(
        CASE WHEN (v_build->>'ok')::boolean
             THEN 'Die Etsy-Daten haben sich seit dem Erzeugen geändert, eine neue Datei sähe anders aus.'
                  || CASE WHEN v_old.confirmed_at IS NULL
                          THEN ' Noch nicht importiert: mit regenerate neu erzeugen.' ELSE '' END
             ELSE 'Mit den heutigen Daten bestünde die Datei die Prüfungen nicht mehr: '
                  || (SELECT string_agg(x, '; ') FROM jsonb_array_elements_text(v_build->'errors') x) END));
    END IF;
    RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
  END IF;

  IF NOT (v_build->>'ok')::boolean THEN
    RETURN v_build;
  END IF;

  v_file := CASE WHEN v_found THEN format('etsy_lexoffice_%s_v%s.csv', v_month, v_old.version + 1)
                 ELSE v_build->>'file_name' END;
  IF v_found THEN
    UPDATE lexoffice_exports SET superseded_at = NOW() WHERE id = v_old.id;
  END IF;
  INSERT INTO lexoffice_exports (month, version, file_name, csv, checksum, line_count, total,
                                 proforma_number, transaction_ids, report)
  VALUES (v_month, CASE WHEN v_found THEN v_old.version + 1 ELSE 1 END, v_file,
          v_build->>'csv', v_build->>'checksum', (v_build->>'line_count')::int, (v_build->>'line_sum')::numeric,
          v_build->'summary'->>'proforma_number',
          ARRAY(SELECT jsonb_array_elements_text(v_build->'transaction_ids')),
          v_build - 'csv' - 'report_text' - 'existing_export')
  RETURNING * INTO v_new;

  v_result := (v_build - 'report_text') || jsonb_build_object(
    'status', CASE WHEN v_found THEN 'regenerated' ELSE 'created' END,
    'file_name', v_new.file_name, 'version', v_new.version, 'created_at', v_new.created_at,
    'replaced_version', CASE WHEN v_found THEN v_old.version END, 'existing_export', NULL);
  IF v_found THEN
    v_result := jsonb_set(v_result, '{warnings}', COALESCE(v_result->'warnings', '[]') || jsonb_build_array(format(
      'Ersetzt %s – die alte Datei nicht mehr importieren. Wurde sie schon importiert, diese hier NICHT '
      || 'importieren und den Monat stattdessen in Lexoffice von Hand korrigieren', v_old.file_name)));
  END IF;
  RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
END
$fn$;

-- ---------------------------------------------------------------------------
-- lexoffice_export_confirm(month)
--
-- Nach dem Import in Lexoffice aufrufen: markiert die Datei als importiert
-- und setzt lexoffice_synced für genau die enthaltenen Etsy-Buchungen.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lexoffice_export_confirm(p_month TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $fn$
DECLARE
  v_month  TEXT := btrim(COALESCE(p_month, ''));
  v_exp    lexoffice_exports%ROWTYPE;
  v_n      INTEGER;
  v_result JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('lexoffice_exports'));
  SELECT * INTO v_exp FROM lexoffice_exports WHERE month = v_month AND superseded_at IS NULL;
  IF NOT FOUND THEN
    v_result := jsonb_build_object('month', v_month, 'ok', false, 'status', 'error',
      'errors', jsonb_build_array(format('Für %s gibt es keine erzeugte Datei – erst action "create"', v_month)),
      'warnings', '[]'::jsonb, 'lines', '[]'::jsonb);
    RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
  END IF;

  IF v_exp.confirmed_at IS NOT NULL THEN
    v_result := jsonb_build_object('month', v_month, 'label', v_exp.report->>'label', 'ok', true,
      'status', 'already_confirmed', 'file_name', v_exp.file_name, 'version', v_exp.version,
      'confirmed_at', v_exp.confirmed_at, 'errors', '[]'::jsonb, 'warnings', '[]'::jsonb, 'lines', '[]'::jsonb);
    RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
  END IF;

  UPDATE lexoffice_exports SET confirmed_at = NOW() WHERE id = v_exp.id RETURNING * INTO v_exp;
  UPDATE etsy_transactions SET lexoffice_synced = TRUE
   WHERE transaction_id = ANY (v_exp.transaction_ids) AND NOT lexoffice_synced;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  v_result := jsonb_build_object('month', v_month, 'label', v_exp.report->>'label', 'ok', true,
    'status', 'confirmed', 'file_name', v_exp.file_name, 'version', v_exp.version,
    'confirmed_at', v_exp.confirmed_at, 'transactions_marked', v_n,
    'errors', '[]'::jsonb, 'warnings', '[]'::jsonb, 'lines', '[]'::jsonb);
  RETURN v_result || jsonb_build_object('report_text', lexoffice_export_report_text(v_result));
END
$fn$;

COMMIT;
