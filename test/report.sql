-- =============================================================================
-- test/report.sql – Prüfbericht über Bestellungen, Rechnungen und Etsy-Ledger
-- Aufruf über test/report.sh (Test-DB) oder test/report.sh --prod (nur lesend).
-- =============================================================================
SET TIME ZONE 'Europe/Berlin';
\pset footer off

\echo
\echo '== Datenbank'
SELECT current_database() AS datenbank, NOW()::timestamp(0) AS stand,
       (SELECT to_timestamp(value::bigint)::timestamp(0) FROM app_config
         WHERE scope = 'etsy' AND key = 'receipts_cursor')       AS letzte_etsy_aenderung,
       (SELECT MAX(date)::timestamp(0) FROM etsy_transactions)    AS letzter_ledger_eintrag;

\echo
\echo '== Fehlende Konfiguration (leer = alles da)'
SELECT k AS fehlt
FROM unnest(ARRAY['etsy.api_key', 'etsy.shop_id', 'notion.database_id', 'mail.from', 'mail.to',
                  'seller.name', 'seller.street', 'seller.zip', 'seller.city', 'seller.vat_id',
                  'etsy_rc.recipient_name', 'etsy_rc.recipient_street', 'etsy_rc.recipient_city',
                  'etsy_rc.recipient_country', 'etsy_rc.recipient_vat_id', 'etsy_rc.start_date']) AS k
WHERE NOT EXISTS (SELECT 1 FROM app_config c WHERE c.scope || '.' || c.key = k);

-- Bestellungen der letzten drei Monate mit Art (physisch/digital/gemischt)
CREATE TEMP VIEW o AS
SELECT to_char(order_date, 'YYYY-MM') AS monat, o.*,
       EXISTS (SELECT 1 FROM jsonb_array_elements(o.items_json) i
               WHERE COALESCE((i->>'is_digital')::boolean, false))     AS hat_digital,
       EXISTS (SELECT 1 FROM jsonb_array_elements(o.items_json) i
               WHERE NOT COALESCE((i->>'is_digital')::boolean, false)) AS hat_physisch
FROM orders o
WHERE o.source = 'etsy'
  AND o.order_date >= date_trunc('month', NOW()) - INTERVAL '2 months';

-- Ab hier nur lesend (die temporäre View oben verändert nichts Bleibendes)
SET default_transaction_read_only = on;

\echo
\echo '== Bestellungen je Monat'
SELECT monat,
       count(*)                                                         AS gesamt,
       count(*) FILTER (WHERE hat_physisch AND NOT hat_digital)         AS physisch,
       count(*) FILTER (WHERE hat_digital AND NOT hat_physisch)         AS digital,
       count(*) FILTER (WHERE hat_digital AND hat_physisch)             AS gemischt,
       count(*) FILTER (WHERE status = 'cancelled')                     AS storniert,
       count(*) FILTER (WHERE invoice_number IS NOT NULL)               AS mit_kundenrechnung,
       count(*) FILTER (WHERE etsy_rc_invoice_number IS NOT NULL)       AS auf_etsy_rechnung,
       count(*) FILTER (WHERE notion_page_id IS NOT NULL)               AS in_notion,
       sum(total) FILTER (WHERE status <> 'cancelled')                  AS brutto
FROM o GROUP BY monat ORDER BY monat;

\echo
\echo '== Physische Bestellungen ohne Kundenrechnung (Workflow 04 noch nicht gelaufen)'
SELECT order_id, order_date::date AS datum, status, total
FROM o
WHERE hat_physisch AND status <> 'cancelled' AND invoice_number IS NULL
ORDER BY order_date;

\echo
\echo '== Digitale Verkäufe abgeschlossener Monate, die auf keiner Etsy-Rechnung stehen'
SELECT order_id, order_date::date AS datum, status, subtotal
FROM o
WHERE hat_digital AND status <> 'cancelled' AND etsy_rc_invoice_number IS NULL
  AND order_date < date_trunc('month', NOW())
  AND order_date::date >= COALESCE((SELECT value::date FROM app_config
                                    WHERE scope = 'etsy_rc' AND key = 'start_date'), 'infinity')
ORDER BY order_date;

\echo
\echo '== Stornierte Bestellungen auf einer Etsy-Rechnung (sollte leer sein)'
SELECT order_id, order_date::date AS datum, etsy_rc_invoice_number
FROM orders WHERE status = 'cancelled' AND etsy_rc_invoice_number IS NOT NULL;

\echo
\echo '== Reverse-Charge-Rechnungen an Etsy'
SELECT period AS monat, invoice_number AS nummer, invoice_date AS datum,
       service_from AS von, service_to AS bis, order_count AS verkaeufe,
       net_total AS netto, marketplace_tax AS etsy_vat, gross_total AS brutto
FROM etsy_rc_invoices ORDER BY period;

\echo
\echo '== Etsy-Ledger je Monat'
SELECT month AS monat,
       SUM(amount) FILTER (WHERE type = 'sale')                         AS verkauf_brutto,
       SUM(amount) FILTER (WHERE type = 'marketplace_tax')              AS etsy_steuer,
       SUM(amount) FILTER (WHERE type IN ('sale', 'marketplace_tax'))   AS umsatz_ohne_etsy_steuer,
       SUM(amount) FILTER (WHERE type LIKE 'fee%')                      AS gebuehren,
       SUM(amount) FILTER (WHERE type = 'refund')                       AS erstattungen,
       SUM(amount) FILTER (WHERE type IN ('payout', 'transfer'))        AS geldbewegungen,
       COUNT(*)    FILTER (WHERE type = 'other')                        AS unbekannt
FROM etsy_transactions
WHERE date >= date_trunc('month', NOW()) - INTERVAL '2 months'
GROUP BY month ORDER BY month;

\echo
\echo '== Unbekannte Ledger-Typen (in Workflow 02 ergänzen, sonst leer)'
SELECT ledger_type, count(*) AS anzahl, sum(amount) AS summe
FROM etsy_transactions WHERE type = 'other'
GROUP BY ledger_type ORDER BY anzahl DESC;

\echo
\echo '== Abgleich Ledger-Verkäufe mit Bestellungen'
\echo '   Abweichungen durch Stornos (Verkauf im Ledger, Erstattung separat) und Bestellungen am Monatswechsel sind normal.'
SELECT COALESCE(l.monat, b.monat) AS monat,
       l.verkauf_brutto  AS ledger_verkauf_brutto,
       b.bestellungen_brutto,
       COALESCE(l.verkauf_brutto, 0) - COALESCE(b.bestellungen_brutto, 0) AS differenz
FROM (SELECT month AS monat, SUM(amount) AS verkauf_brutto
      FROM etsy_transactions
      WHERE type = 'sale' AND date >= date_trunc('month', NOW()) - INTERVAL '2 months'
      GROUP BY month) l
FULL JOIN (SELECT monat, SUM(total) AS bestellungen_brutto
           FROM o WHERE status <> 'cancelled'
           GROUP BY monat) b ON b.monat = l.monat
ORDER BY 1;
