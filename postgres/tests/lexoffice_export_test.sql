-- =============================================================================
-- Tests für den Lexoffice-Export (Migration 004). Nur gegen eine WEGWERF-
-- Datenbank mit Schema und Migrationen ausführen: postgres/tests/run.sh
-- Alle Daten sind erfunden (IDs, Beträge, Bestellungen).
-- =============================================================================
\set ON_ERROR_STOP 1
\o /dev/null
SET client_min_messages = notice;

CREATE FUNCTION pg_temp.check(ok BOOLEAN, label TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS NOT TRUE THEN RAISE EXCEPTION 'FEHLGESCHLAGEN: %', label; END IF;
  RAISE NOTICE 'ok  %', label;
END $$;

-- Hilfsfunktion: eine Etsy-Buchung wie von Workflow 02 (aktuelle Version)
CREATE FUNCTION pg_temp.tx(seq INT, ts TIMESTAMPTZ, typ TEXT, ltype TEXT, amt NUMERIC, bal NUMERIC,
                           ord TEXT DEFAULT NULL, mon TEXT DEFAULT NULL, descr TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO etsy_transactions (transaction_id, order_id, type, description, amount, net_amount, currency,
                                 date, month, ledger_type, balance, sequence_number)
  VALUES ((1000000000 + seq)::text, ord, typ, COALESCE(descr, ltype), amt, amt, 'EUR', ts,
          COALESCE(mon, to_char(ts AT TIME ZONE 'Europe/Berlin', 'YYYY-MM')), ltype, bal, seq)
$$;

CREATE FUNCTION pg_temp.ord(id TEXT, d DATE, items JSONB, sub NUMERIC, ship NUMERIC, tot NUMERIC,
                            inv TEXT DEFAULT NULL, st TEXT DEFAULT 'completed')
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO orders (order_id, source, order_date, items_json, subtotal, shipping_cost, total, status, invoice_number,
                      is_digital)
  VALUES (id, 'etsy', d + TIME '12:00', items, sub, ship, tot, st, inv,
          NOT EXISTS (SELECT 1 FROM jsonb_array_elements(items) i WHERE NOT (i->>'is_digital')::boolean))
$$;

CREATE FUNCTION pg_temp.rc(period DATE, nr TEXT, net NUMERIC, lines JSONB) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO etsy_rc_invoices (period, invoice_number, invoice_date, service_from, service_to, order_count,
                                net_total, lines_json, seller_json, recipient_json)
  VALUES (period, nr, (period + INTERVAL '1 month')::date, period, (period + INTERVAL '1 month')::date - 1,
          jsonb_array_length(lines), net, lines, '{}', '{}')
$$;

INSERT INTO app_config VALUES ('lexoffice', 'start_month', '2025-03');

-- Februar 2025: vor dem Stichtag (PayJoe), Guthaben danach -0,20
SELECT pg_temp.tx(1, '2025-02-20 10:00+00', 'fee_listing', 'renew_expired', -0.20, -0.20);

-- März 2025: wie der Stand heute – Verkäufe noch ohne Bestellnummer,
-- Kartenzahlung noch im Altformat (fee_transaction + billing_payment)
SELECT pg_temp.tx( 2, '2025-03-01 07:00+00', 'fee_transaction', 'billing_payment', 0.20, 0.00);
SELECT pg_temp.tx( 3, '2025-03-04 09:00+00', 'sale',            'PAYMENT_GROSS',          4.50, 4.50);
SELECT pg_temp.tx( 4, '2025-03-04 09:00+00', 'fee_transaction', 'transaction',           -0.29, 4.21);
SELECT pg_temp.tx( 5, '2025-03-04 09:00+00', 'fee_processing',  'PAYMENT_PROCESSING_FEE',-0.42, 3.79);
SELECT pg_temp.tx( 6, '2025-03-04 09:01+00', 'fee_ads',         'offsite_ads_fee',       -0.68, 3.11, '1001');
SELECT pg_temp.tx( 7, '2025-03-04 09:01+00', 'fee_listing',     'renew_sold_auto',       -0.18, 2.93);
SELECT pg_temp.tx( 8, '2025-03-18 15:00+00', 'sale',            'PAYMENT_GROSS',          3.00, 5.93);
SELECT pg_temp.tx( 9, '2025-03-18 15:00+00', 'fee_transaction', 'transaction',           -0.20, 5.73);
SELECT pg_temp.tx(10, '2025-03-18 15:00+00', 'fee_processing',  'PAYMENT_PROCESSING_FEE',-0.33, 5.40);
SELECT pg_temp.tx(11, '2025-03-18 15:01+00', 'fee_listing',     'renew_sold_auto',       -0.17, 5.23);
SELECT pg_temp.tx(12, '2025-03-25 05:00+00', 'payout',          'DISBURSE2',             -5.23, 0.00);
-- 31.03. 22:30 UTC = 01.04. 00:30 deutscher Zeit → gehört in den April;
-- month wie aus einer alten Workflow-Version (UTC)
SELECT pg_temp.tx(13, '2025-03-31 22:30+00', 'fee_listing',     'renew_sold_auto',       -0.18, -0.18, NULL, '2025-03');
SELECT pg_temp.rc('2025-03-01', '2025-0003', 7.50, '[{"order_id":"1001","net":4.50},{"order_id":"1002","net":3.00}]');
-- physische Bestellung ohne Etsy-Verkauf im Ledger (noch nicht versendet)
SELECT pg_temp.ord('1003', '2025-03-10', '[{"title":"Poster","price":10,"quantity":1,"is_digital":false}]', 10, 4, 14);

-- April 2025: Bestellnummern bekannt; digital mit VAT, physisch, gemischt
-- (Gutschein), im selben Monat erstattet
SELECT pg_temp.ord('2001', '2025-04-03', '[{"title":"Datei A","price":5,"quantity":1,"is_digital":true}]', 5, 0, 5.95);
SELECT pg_temp.ord('2002', '2025-04-05', '[{"title":"Poster","price":12,"quantity":1,"is_digital":false}]', 12, 4, 16, '2025-0004');
SELECT pg_temp.ord('2003', '2025-04-10', '[{"title":"Datei B","price":3,"quantity":1,"is_digital":true},'
                                         '{"title":"Druck","price":7,"quantity":1,"is_digital":false}]', 9, 2, 11.51, '2025-0005');
SELECT pg_temp.ord('2004', '2025-04-20', '[{"title":"Datei C","price":2,"quantity":1,"is_digital":true}]', 2, 0, 2, NULL, 'cancelled');
SELECT pg_temp.tx(14, '2025-04-03 10:00+00', 'sale',            'PAYMENT_GROSS',           5.95,  5.77, '2001');
SELECT pg_temp.tx(15, '2025-04-03 10:00+00', 'marketplace_tax', 'vat_tax_ep',             -0.95,  4.82, '2001');
SELECT pg_temp.tx(16, '2025-04-03 10:00+00', 'fee_transaction', 'transaction',            -0.33,  4.49);
SELECT pg_temp.tx(17, '2025-04-03 10:00+00', 'fee_processing',  'PAYMENT_PROCESSING_FEE', -0.48,  4.01);
SELECT pg_temp.tx(18, '2025-04-08 08:00+00', 'sale',            'PAYMENT_GROSS',          16.00, 20.01, '2002');
SELECT pg_temp.tx(19, '2025-04-08 08:00+00', 'fee_transaction', 'transaction',            -1.04, 18.97);
SELECT pg_temp.tx(20, '2025-04-08 08:00+00', 'fee_processing',  'PAYMENT_PROCESSING_FEE', -0.73, 18.24);
SELECT pg_temp.tx(21, '2025-04-10 11:00+00', 'sale',            'PAYMENT_GROSS',          11.51, 29.75, '2003');
SELECT pg_temp.tx(22, '2025-04-10 11:00+00', 'marketplace_tax', 'vat_tax_ep',             -0.51, 29.24, '2003');
SELECT pg_temp.tx(23, '2025-04-10 11:00+00', 'fee_transaction', 'transaction',            -0.72, 28.52);
SELECT pg_temp.tx(24, '2025-04-20 16:00+00', 'sale',            'PAYMENT_GROSS',           2.00, 30.52, '2004');
SELECT pg_temp.tx(25, '2025-04-21 09:00+00', 'refund',          'REFUND',                 -2.00, 28.52, '2004');
SELECT pg_temp.tx(26, '2025-04-28 05:00+00', 'payout',          'DISBURSE2',             -28.52,  0.00);
SELECT pg_temp.rc('2025-04-01', '2025-0006', 7.70, '[{"order_id":"2001","net":5.00},{"order_id":"2003","net":2.70}]');

-- Mai 2025: unbekannter Etsy-Typ und Proformarechnung passt nicht
SELECT pg_temp.ord('3001', '2025-05-06', '[{"title":"Datei D","price":4,"quantity":1,"is_digital":true}]', 4, 0, 4);
SELECT pg_temp.tx(27, '2025-05-06 10:00+00', 'sale',    'PAYMENT_GROSS',        4.00, 4.00, '3001');
SELECT pg_temp.tx(28, '2025-05-06 10:00+00', 'unknown', 'vat_seller_services', -0.10, 3.90);
SELECT pg_temp.tx(29, '2025-05-20 05:00+00', 'payout',  'DISBURSE2',           -3.90, 0.00);
SELECT pg_temp.rc('2025-05-01', '2025-0007', 3.50, '[{"order_id":"3001","net":3.50}]');

-- Juni 2025: keine Proformarechnung aus Workflow 05
SELECT pg_temp.tx(30, '2025-06-06 10:00+00', 'sale',   'PAYMENT_GROSS',  2.00, 2.00);
SELECT pg_temp.tx(31, '2025-06-20 05:00+00', 'payout', 'DISBURSE2',     -2.00, 0.00);

-- Juli 2025: Lücke – zwischen 32 und 34 fehlt eine Buchung über -0,20
SELECT pg_temp.tx(32, '2025-07-06 10:00+00', 'sale',            'PAYMENT_GROSS', 3.00, 3.00);
SELECT pg_temp.tx(34, '2025-07-06 10:00+00', 'fee_transaction', 'transaction',  -0.20, 2.60);
SELECT pg_temp.rc('2025-07-01', '2025-0008', 3.00, '[{"order_id":"4001","net":3.00}]');

-- August 2025: Buchung aus alter Workflow-Version ohne Etsy-Rohdaten
INSERT INTO etsy_transactions (transaction_id, type, description, amount, net_amount, currency, date, month)
VALUES ('1000000035', 'fee_listing', 'renew_sold_auto', -0.18, -0.18, 'EUR', '2025-08-04 10:00+00', '2025-08');

-- ---------------------------------------------------------------------------
-- Klassifizierung
-- ---------------------------------------------------------------------------
SELECT pg_temp.check((SELECT line_class FROM etsy_ledger_classified WHERE transaction_id = '1000000002') = 'CARD_PAYMENT',
                     'billing_payment im Altformat ist Kartenzahlung, keine Gebühr');
SELECT pg_temp.check((SELECT month_berlin FROM etsy_ledger_classified WHERE transaction_id = '1000000013') = '2025-04',
                     'Monat nach deutscher Zeit, nicht UTC');
SELECT pg_temp.check((SELECT line_class FROM etsy_ledger_classified WHERE transaction_id = '1000000028') = 'UNKNOWN',
                     'unbekannter Typ → UNKNOWN');

-- ---------------------------------------------------------------------------
-- Testfall März: wie Briefing-Testfall 1
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE r AS SELECT '2025-03' AS m, lexoffice_export_build('2025-03') AS j;
INSERT INTO r SELECT '2025-04', lexoffice_export_build('2025-04');

SELECT pg_temp.check((j->>'ok')::boolean, 'März: exportierbar ' || (j->>'errors')) FROM r WHERE m = '2025-03';
SELECT pg_temp.check(j->>'csv' =
     E'Datum;Betrag;Verwendungszweck\r\n'
  || E'01.03.2025;0,20;Etsy Kartenzahlung (billing_payment) Ausgleich Etsy-Gebuehren, ID 1000000002\r\n'
  || E'25.03.2025;-5,23;Etsy Auszahlung DISBURSE2, ID 1000000012\r\n'
  || E'31.03.2025;7,50;2025-0003 Etsy digitale Verkaeufe 03/2025 netto (2 Verkaeufe)\r\n'
  || E'31.03.2025;-2,27;Etsy-Gebuehren 03/2025 (Ads 0,68 + Transaction 0,49 + Processing 0,75 + Listing 0,35)\r\n',
  'März: CSV exakt wie erwartet') FROM r WHERE m = '2025-03';
SELECT pg_temp.check((j->>'line_sum')::numeric = 0.20 AND (j->'summary'->>'transaction_sum')::numeric = 0.20,
                     'März: Summe der Zeilen = Summe der Buchungen = +0,20') FROM r WHERE m = '2025-03';
SELECT pg_temp.check((j->'summary'->>'opening_balance')::numeric = -0.20 AND (j->'summary'->>'closing_balance')::numeric = 0
                     AND (j->'summary'->>'etsy_closing_balance')::numeric = 0,
                     'März: Guthaben -0,20 → 0,00, Etsy-Kontostand bestätigt') FROM r WHERE m = '2025-03';
SELECT pg_temp.check((j->'summary'->>'fees')::numeric = -2.27 AND (j->'summary'->>'card_payments')::numeric = 0.20,
                     'März: Kartenzahlung nicht in der Gebührensumme') FROM r WHERE m = '2025-03';
SELECT pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements_text(j->'warnings') w WHERE w LIKE '%ohne Bestellnummer%')
                 AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(j->'warnings') w WHERE w LIKE '%Physische Bestellung(en) ohne zugeordneten Etsy-Verkauf: 1003%')
                 AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(j->'warnings') w WHERE w LIKE '%Spalte month%1000000013%'),
                     'März: Warnungen zu fehlender Bestellnummer, physischer Bestellung und Spalte month') FROM r WHERE m = '2025-03';

-- ---------------------------------------------------------------------------
-- Testfall April: VAT-Verrechnung, physisch, gemischt, Erstattung
-- ---------------------------------------------------------------------------
SELECT pg_temp.check((j->>'ok')::boolean, 'April: exportierbar ' || (j->>'errors')) FROM r WHERE m = '2025-04';
SELECT pg_temp.check(j->>'csv' =
     E'Datum;Betrag;Verwendungszweck\r\n'
  || E'08.04.2025;16,00;Etsy Verkauf physisch, Bestellung 2002, Rechnung 2025-0004, brutto\r\n'
  || E'10.04.2025;8,30;Etsy Verkauf physisch, Bestellung 2003, Rechnung 2025-0005, physischer Anteil brutto\r\n'
  || E'28.04.2025;-28,52;Etsy Auszahlung DISBURSE2, ID 1000000026\r\n'
  || E'30.04.2025;7,70;2025-0006 Etsy digitale Verkaeufe 04/2025 netto (2 Verkaeufe)\r\n'
  || E'30.04.2025;-3,48;Etsy-Gebuehren 04/2025 (Transaction 2,09 + Processing 1,21 + Listing 0,18)\r\n',
  'April: CSV exakt wie erwartet (VAT verrechnet, Gutschein anteilig, Erstattung saldiert)') FROM r WHERE m = '2025-04';
SELECT pg_temp.check((j->>'line_sum')::numeric = 0 AND (j->'summary'->>'physical_sales')::numeric = 24.30,
                     'April: Summe 0,00, physisch 24,30 brutto') FROM r WHERE m = '2025-04';
SELECT pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements_text(j->'warnings') w WHERE w LIKE 'Erstattung bei Bestellung 2004%'),
                     'April: Hinweis auf Erstattung') FROM r WHERE m = '2025-04';

SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM r, jsonb_array_elements(r.j->'lines') l
                                  WHERE length(l->>'purpose') NOT BETWEEN 1 AND 255 OR l->>'purpose' ~ '[;\r\n]'),
                     'Verwendungszwecke nicht leer, max. 255 Zeichen, ohne Spaltentrenner');

-- ---------------------------------------------------------------------------
-- Fehlerfälle: keine Datei
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.has_error(m TEXT, pattern TEXT, pf TEXT DEFAULT NULL) RETURNS BOOLEAN LANGUAGE sql AS $$
  SELECT NOT (j->>'ok')::boolean AND j->>'csv' IS NULL
     AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(j->'errors') e WHERE e LIKE pattern)
  FROM (SELECT lexoffice_export_build(m, pf) AS j) x
$$;
SELECT pg_temp.check(pg_temp.has_error('2025-05', 'Unbekannte Etsy-Buchung 1000000028%vat_seller_services%'),
                     'Mai: unbekannter Typ bricht ab');
SELECT pg_temp.check(pg_temp.has_error('2025-05', 'Digitale Verkäufe laut Etsy-Konto 4,00 €, Proformarechnung 2025-0007 über 3,50 €%'),
                     'Mai: Abweichung zur Proformarechnung bricht ab');
SELECT pg_temp.check(pg_temp.has_error('2025-06', 'Keine Proformarechnung für 06/2025%'),
                     'Juni: fehlende Proformarechnung bricht ab');
SELECT pg_temp.check((lexoffice_export_build('2025-06', 'PF-2025-06')->>'csv') LIKE '%;2,00;PF-2025-06 Etsy digitale Verkaeufe 06/2025 netto (1 Verkauf)%',
                     'Juni: Proformanummer von Hand angegeben');
SELECT pg_temp.check(pg_temp.has_error('2025-07', 'Lücke in den Etsy-Buchungen vor 1000000034%fehlen Buchungen über -0,20 €%'),
                     'Juli: Lücke im Etsy-Kontostand bricht ab');
SELECT pg_temp.check(pg_temp.has_error('2025-08', '1 Etsy-Buchung(en) ohne Etsy-Rohdaten%'),
                     'August: Altdaten ohne Etsy-Rohdaten brechen ab');
SELECT pg_temp.check(pg_temp.has_error('2025-02', '%liegt vor lexoffice.start_month%'),
                     'Februar: vor dem Stichtag wird nicht exportiert');
SELECT pg_temp.check(pg_temp.has_error(to_char(NOW() AT TIME ZONE 'Europe/Berlin', 'YYYY-MM'), '%noch nicht abgeschlossen%'),
                     'laufender Monat wird nicht exportiert');
SELECT pg_temp.check(pg_temp.has_error('2025-13', 'Ungültiger Monat%'), 'ungültiger Monat');
SELECT pg_temp.check((lexoffice_export_create('2025-05')->>'status') = 'error'
                     AND NOT EXISTS (SELECT 1 FROM lexoffice_exports WHERE month = '2025-05'),
                     'create bei Fehlern speichert nichts');

-- ---------------------------------------------------------------------------
-- Idempotenz und Bestätigung
-- ---------------------------------------------------------------------------
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM lexoffice_exports), 'build schreibt nichts (Dry-Run)');
SELECT pg_temp.check((lexoffice_export_create('2025-03')->>'status') = 'created', 'März: Datei erzeugt');
SELECT pg_temp.check((SELECT j->>'csv' FROM r WHERE m = '2025-03') = (SELECT csv FROM lexoffice_exports WHERE month = '2025-03'),
                     'gespeicherte Datei = Vorschau');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM etsy_transactions WHERE lexoffice_synced),
                     'lexoffice_synced bleibt beim Erzeugen unverändert');
SELECT pg_temp.check((SELECT x->>'status' = 'existing' AND x->>'csv' = (SELECT csv FROM lexoffice_exports WHERE month = '2025-03')
                      FROM lexoffice_export_create('2025-03') x),
                     'erneutes create liefert dieselbe Datei');
SELECT pg_temp.check((lexoffice_export_create('2025-03', NULL, TRUE)->>'status') = 'existing'
                     AND (SELECT COUNT(*) FROM lexoffice_exports WHERE month = '2025-03') = 1,
                     'regenerate ohne Änderung erzeugt keine neue Version');
SELECT pg_temp.check((SELECT bool_and(t.transaction_id = ANY (e.transaction_ids))
                        FROM etsy_ledger_classified t, lexoffice_exports e
                       WHERE e.month = '2025-03' AND t.month_berlin = '2025-03')
                     AND (SELECT cardinality(transaction_ids) FROM lexoffice_exports WHERE month = '2025-03') = 11,
                     'Datei enthält genau die 11 März-Buchungen');

-- Nachzügler für den exportierten März
SELECT pg_temp.tx(36, '2025-03-26 10:00+00', 'fee_ads', 'offsite_ads_fee', -0.05, -0.05);
SELECT pg_temp.check(pg_temp.has_error('2025-04', 'Etsy-Buchung(en) 1000000036 aus 2025-03 fehlen in der bereits erzeugten Datei%'),
                     'Nachzügler in exportiertem Monat bricht den nächsten Export ab');
SELECT pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements_text(lexoffice_export_create('2025-03')->'warnings') w
                             WHERE w LIKE 'Die Etsy-Daten haben sich seit dem Erzeugen geändert%'),
                     'bestehende Datei meldet geänderte Daten');
DELETE FROM etsy_transactions WHERE transaction_id = '1000000036';

SELECT pg_temp.check((lexoffice_export_confirm('2025-04')->>'status') = 'error', 'Bestätigen ohne Datei geht nicht');
SELECT pg_temp.check((lexoffice_export_confirm('2025-03')->>'transactions_marked')::int = 11, 'März bestätigt, 11 Buchungen markiert');
SELECT pg_temp.check((SELECT COUNT(*) FROM etsy_transactions WHERE lexoffice_synced) = 11
                     AND NOT EXISTS (SELECT 1 FROM etsy_ledger_classified WHERE lexoffice_synced AND month_berlin <> '2025-03'),
                     'lexoffice_synced genau für die Buchungen der Datei');
SELECT pg_temp.check((lexoffice_export_confirm('2025-03')->>'status') = 'already_confirmed', 'zweites Bestätigen ändert nichts');
SELECT pg_temp.check(EXISTS (SELECT 1 FROM jsonb_array_elements_text(lexoffice_export_create('2025-03', NULL, TRUE)->'errors') e
                             WHERE e LIKE '%bestätigt – der Monat wird nicht neu erzeugt%'),
                     'nach bestätigtem Import kein regenerate');

-- Neu erzeugen vor der Bestätigung, wenn sich Daten geändert haben
SELECT pg_temp.check((lexoffice_export_create('2025-04')->>'status') = 'created', 'April: Datei erzeugt');
UPDATE etsy_rc_invoices SET invoice_number = '2025-0006a' WHERE period = '2025-04-01';
SELECT pg_temp.check((SELECT x->>'status' = 'regenerated' AND x->>'file_name' = 'etsy_lexoffice_2025-04_v2.csv'
                      FROM lexoffice_export_create('2025-04', NULL, TRUE) x),
                     'April: regenerate erzeugt Version 2');
SELECT pg_temp.check((SELECT COUNT(*) FROM lexoffice_exports WHERE month = '2025-04') = 2
                     AND (SELECT COUNT(*) FROM lexoffice_exports WHERE month = '2025-04' AND superseded_at IS NULL) = 1,
                     'alte Version bleibt als ersetzt erhalten');
SELECT pg_temp.check(lexoffice_export_build('2025-04')->>'report_text' LIKE '%Vorschau ist identisch%',
                     'Vorschau erkennt bestehende identische Datei');

\echo 'Alle Tests bestanden.'
