# buschi-bookkeeping

Automatisierte Buchhaltung und Dokumentenerstellung für kleine Unternehmen, betrieben mit n8n und einer eigenen PDF-API.

## Komponenten

| Verzeichnis | Beschreibung |
|---|---|
| `bootstrap/` | Initialisiert Secrets (DB-Credentials) beim ersten Start |
| `postgres/` | PostgreSQL mit Schema für Bestellungen, Transaktionen, Rechnungen |
| `config-loader/` | Schreibt die Konfiguration aus Umgebungsvariablen bei jedem Start nach `app_config` |
| `typst-api/` | FastAPI-Service zur PDF-Generierung via [Typst](https://typst.app) |
| `n8n/workflows/` | n8n-Workflow-JSONs (Etsy-Sync, Notion-Sync, Rechnungserstellung, Lexoffice-Export) |

## Installation

### Voraussetzungen

- Docker + Docker Compose
- Eine laufende n8n-Instanz im selben Docker-Netzwerk (`n8n-backend`)
- Eine Etsy-App (erstellt unter [etsy.com/developers](https://www.etsy.com/developers))

### 1. Docker-Netzwerk erstellen (falls noch nicht vorhanden)

```bash
docker network create n8n-backend
```

### 2. Volumes anlegen und Infrastruktur starten

Datenbank und DB-Passwoerter liegen in zwei Docker-Volumes mit festen Namen. Sie werden **einmalig von Hand** angelegt (z.B. per SSH auf dem Server). Compose legt sie bewusst nicht selbst an und loescht sie nie: weder `docker compose down -v` noch das Loeschen des Projekts im Hosting-Panel noch ein anderer Projektname beruehren die Daten.

```bash
docker volume create bookkeeping_pgdata
docker volume create bookkeeping_secrets
docker compose up -d
```

Fehlt ein Volume, bricht der Start mit `external volume "bookkeeping_..." not found` ab, statt still mit einer leeren Datenbank zu starten. Absichtlich loeschen laesst sich die Datenbank nur mit `docker volume rm bookkeeping_pgdata`. Hintergrund und Verhalten in allen Situationen: [docs/daten-und-konfiguration.md](docs/daten-und-konfiguration.md).

Beim ersten Start erzeugt der `bootstrap`-Container automatisch DB-Credentials und gibt sie einmalig in den Docker-Logs aus:

```bash
docker compose logs bootstrap
```

Die Ausgabe enthält DB-Name, Admin- und Worker-User mit Passwort sowie einen fertigen PostgreSQL Connection-String fuer n8n.

### 3. Credentials in n8n anlegen

Alle Credentials unter **Credentials > Add Credential**. Die Namen sind frei waehlbar; nach dem Import der Workflows (Schritt 6) wird in jeder Node das passende Credential ausgewaehlt.

| Credential | Typ in n8n | Benutzt von |
|---|---|---|
| Postgres | *Postgres* | allen Workflows |
| Etsy | *OAuth2 API* | 01, 02 (HTTP-Request-Nodes zu Etsy) |
| Notion | *Notion API* | 03 |
| E-Mail | *SMTP* | 04, 05 |

#### 3.1 Postgres

| Feld | Wert |
|---|---|
| **Host** | `orderdb` (Container-Name im Docker-Netzwerk) |
| **Port** | `5432` |
| **Database** | DB-Name aus den Bootstrap-Logs (Standard `orderdb`) |
| **User / Password** | **Worker**-User aus den Bootstrap-Logs, nicht der Admin |
| **Maximum Number of Connections** | `5` |
| **Ignore SSL Issues** | aus |
| **SSL** | Disable (die DB ist nur im internen Docker-Netzwerk erreichbar) |

#### 3.2 Etsy (OAuth2 API)

Typ **OAuth2 API** (generisch, es gibt kein eigenes Etsy-Credential):

| Feld | Wert |
|---|---|
| **Grant Type** | PKCE |
| **Authorization URL** | `https://www.etsy.com/oauth/connect` |
| **Access Token URL** | `https://api.etsy.com/v3/public/oauth/token` |
| **Client ID** | Keystring der Etsy-App (nur der Keystring, **ohne** `:shared_secret`) |
| **Client Secret** | Shared Secret der Etsy-App |
| **Scope** | `transactions_r listings_r email_r shops_r` |
| **Auth URI Query Parameters** | leer lassen |
| **Authentication** | Body |
| **Ignore SSL Issues** | aus |
| **Token Expired Status Code** | `401` |
| **Encrypted Tokens (JWE)** | aus |
| **Allowed HTTP Request Domains** | All (optional enger: nur `openapi.etsy.com`) |

n8n zeigt oben die **OAuth Redirect URL** an, nach dem Muster `https://<deine-n8n-domain>/rest/oauth2-credential/callback`. Genau diese URL in der Etsy-App unter [etsy.com/developers](https://www.etsy.com/developers) als Callback-URL eintragen, dann in n8n auf **Connect** klicken und bei Etsy autorisieren. Danach steht dort „Account connected“; Access- und Refresh-Token erneuert n8n selbst.

Nicht verwechseln: Fuer den Header `x-api-key` erwartet Etsy das Format `keystring:shared_secret`. Dieser Wert gehoert nicht ins Credential, sondern nach `app_config` (Schritt 5).

#### 3.3 Notion (Notion API)

| Feld | Wert |
|---|---|
| **Internal Integration Secret** | Secret einer *internen* Integration (Notion: Einstellungen > Integrationen / Connections) |
| **Allowed HTTP Request Domains** | All |

Die Integration sieht nur Seiten, mit denen sie verbunden ist: In der Ziel-Datenbank ueber **••• > Connections** die Integration hinzufuegen (siehe Schritt 4).

#### 3.4 E-Mail (SMTP)

Host, Port, User und Passwort deines Mail-Anbieters. **SSL/TLS** an bei Port 465; bei Port 587 (STARTTLS) aus lassen. Absender- und Empfaengeradresse der Rechnungs-Mails stehen nicht im Workflow, sondern in `app_config` (Scope `mail`, Schritt 5).

### 4. Notion-Datenbank vorbereiten

Workflow 03 schreibt in eine Notion-Datenbank mit genau diesen Properties (Name und Typ muessen passen):

| Property | Typ | | Property | Typ |
|---|---|---|---|---|
| `OrderID` | Title | | `Versand` | Number |
| `Quelle` | Select | | `Gesamt` | Number |
| `Status` | Select | | `Currency` | Text |
| `Bestelldatum` | Date | | `Artikel` | Text |
| `Pseudonym` | Text | | `Digital` | Checkbox |
| `Stadt` | Text | | `Rechnungsnr.` | Text |
| `PLZ` | Text | | `Tracking` | Text |
| `Land` | Text | | `Versanddienstl.` | Text |

Die Integration aus 3.3 mit der Datenbank verbinden (**••• > Connections**). Die Datenbank-ID kommt nach `app_config` (Schritt 5).

### 5. App-Konfiguration hinterlegen

Die Workflows lesen alle instanzspezifischen Werte (Etsy-API-Key, IDs, Verkaeuferdaten, Mail-Adressen, Empfaenger der Etsy-Rechnung) aus der Tabelle `app_config`. Gepflegt werden sie als **Umgebungsvariablen des Compose-Projekts**: im Hosting-Panel oder in einer `.env` neben der `docker-compose.yml` (Vorlage: `.env.example`, die `.env` selbst nie committen). Der Container `app-config` schreibt sie bei jedem Start in die Datenbank.

- Die Variablen koennen auch erst nach dem ersten Start eingetragen werden. Leere oder fehlende Variablen werden uebersprungen, der Wert in der Datenbank bleibt dann unveraendert.
- **Nach jeder Aenderung `docker compose up -d` ausfuehren** (im Panel: „Redeploy“/„Update“). Erst dabei wird der Container mit den neuen Werten neu erstellt. Ein `docker compose restart` uebernimmt geaenderte Variablen **nicht**; das ist Docker-Verhalten, kein Fehler.
- Bei jedem Start, auch nach einem Server-Neustart, werden die Werte erneut geschrieben. Was als Variable gesetzt ist, gewinnt also gegen Aenderungen von Hand in der Datenbank.
- Kontrolle: `docker logs app-config` zeigt, welche Schluessel uebernommen bzw. geaendert wurden und welche Pflichtwerte noch fehlen. Die Werte selbst werden nie geloggt.
- Ablauf, Namensschema und Verhalten bei Neustart, Redeploy oder geleerten Variablen im Detail: [docs/daten-und-konfiguration.md](docs/daten-und-konfiguration.md).

| Variable | `app_config` | Hinweis |
|---|---|---|
| `ETSY_API_KEY` | `etsy.api_key` | Format `keystring:shared_secret` |
| `ETSY_SHOP_ID` | `etsy.shop_id` | |
| `ETSY_SYNC_START` | `etsy.sync_start` | optional: ab welchem Tag (`YYYY-MM-DD`, deutsche Zeit) der erste Abruf von Bestellungen und Ledger beginnt (Workflows 01, 02); ohne: die letzten 90 Tage |
| `NOTION_DATABASE_ID` | `notion.database_id` | |
| `MAIL_FROM`, `MAIL_TO` | `mail.from`, `mail.to` | Absender/Empfaenger der PDF-Mails (Workflows 04, 05) |
| `SELLER_NAME`, `SELLER_STREET`, `SELLER_ZIP`, `SELLER_CITY` | `seller.*` | Pflicht fuer Rechnungen |
| `SELLER_BUSINESS_NAME`, `SELLER_TAGLINE`, `SELLER_COUNTRY`, `SELLER_EMAIL`, `SELLER_PHONE`, `SELLER_WEBSITE`, `SELLER_IBAN`, `SELLER_BANK_NAME` | `seller.*` | optional |
| `SELLER_TAX_ID` | `seller.tax_id` | Steuernummer |
| `SELLER_VAT_ID` | `seller.vat_id` | USt-IdNr., wird nur gedruckt, wenn gesetzt; Pflicht fuer Workflow 05 |
| `SELLER_KLEINUNTERNEHMER` | `seller.kleinunternehmer` | `true` (Standard, §19 UStG) oder `false` |
| `ETSY_RC_RECIPIENT_NAME`, `_STREET`, `_ZIP`, `_CITY`, `_COUNTRY`, `_VAT_ID` | `etsy_rc.recipient_*` | Empfaenger der Reverse-Charge-Rechnung (Workflow 05), `_ZIP` optional |
| `ETSY_RC_START_DATE` | `etsy_rc.start_date` | erster Tag, ab dem Workflow 05 abrechnet (`YYYY-MM-DD`) |
| `ETSY_RC_NUMBER_FORMAT` | `etsy_rc.number_format` | optional: Muster der Rechnungsnummer, `{YYYY}` und `{MM}` = abgerechneter Monat; Standard `RE-E-{YYYY}-{MM}` (z.B. `RE-E-2026-09`) |
| `ETSY_RC_PAYMENT_NOTE`, `ETSY_RC_NOTE` | `etsy_rc.payment_note`, `etsy_rc.note` | optionale Texte auf der Etsy-Rechnung |
| `LEXOFFICE_START_MONTH` | `lexoffice.start_month` | erster Monat, den Workflow 06 nach Lexoffice exportiert (`YYYY-MM`) |

Zu den Werten:

- Der Etsy `api_key` muss im Format `keystring:shared_secret` vorliegen (Etsy-Anforderung seit Februar 2026). Die Shop-ID findest du im Etsy Shop Manager in der URL (`shop_id=...`) oder ueber die API unter `GET /v3/application/users/me`. Die Notion `database_id` steht in der Notion-URL: `notion.so/<workspace>/<DATABASE_ID>?v=...`.
- Fehlen Pflichtwerte, brechen die Workflows mit einer klaren Fehlermeldung ab, statt Rechnungen mit Platzhaltern zu erzeugen.
- Empfaenger der Etsy-Rechnung, z.B. `ETSY_RC_RECIPIENT_NAME=Etsy Ireland UC`, `ETSY_RC_RECIPIENT_STREET=One Le Pole Square, Ship Street Great`, `ETSY_RC_RECIPIENT_CITY=Dublin 8`, `ETSY_RC_RECIPIENT_COUNTRY=Irland`, `ETSY_RC_RECIPIENT_VAT_ID=IE9777587C`. Anschrift und USt-IdNr. bitte mit deinen bisherigen Rechnungen an Etsy bzw. einer Etsy-Gebuehrenrechnung abgleichen.
- `ETSY_RC_START_DATE`: alles davor hast du bereits selbst an Etsy fakturiert; es darf nicht doppelt auf eine Rechnung.
- `ETSY_SYNC_START` wirkt nur, solange noch kein Abruf gelaufen ist (kein `etsy.receipts_cursor`, leere Tabelle `etsy_transactions`). Danach setzen beide Workflows dort fort, wo sie aufgehoert haben; eine spaetere Aenderung allein holt also nichts nach (siehe [Etsy-Daten neu abrufen](#etsy-daten-neu-abrufen)). Fuer die Reverse-Charge-Rechnung muessen die Bestellungen ab `ETSY_RC_START_DATE` vorliegen, `ETSY_SYNC_START` also spaetestens an diesem Tag beginnen.
- `LEXOFFICE_START_MONTH`: alle Monate davor sind schon anders in Lexoffice gebucht (z.B. ueber PayJoe) und werden nie exportiert, sonst entstehen Doppelbuchungen.

Werte lassen sich weiterhin auch per SQL oder Adminer in `app_config` eintragen. Sie werden nur dann ueberschrieben, wenn dieselbe Variable gesetzt ist. Den Schluessel `etsy.receipts_cursor` pflegt Workflow 01 selbst (Zeitstempel der zuletzt verarbeiteten Etsy-Aenderung); er ist bewusst keine Variable.

### 6. Workflows importieren

Die JSON-Dateien aus `n8n/workflows/` in n8n importieren:

| Workflow | Version | Beschreibung |
|---|---|---|
| `01_etsy_orders_sync.json` | v1 | Synchronisiert Etsy-Bestellungen alle 15 Minuten |
| `02_etsy_transactions_sync.json` | v1 | Synchronisiert Etsy-Transaktionen (Gebuehren, Auszahlungen) alle 6 Stunden |
| `03_notion_sync.json` | v1 | Synchronisiert Bestellungen nach Notion |
| `04_generate_invoice_pdf.json` | v1 | Erzeugt Rechnungen und Lieferscheine als PDF (nur physische Artikel), per Formular |
| `05_etsy_reverse_charge_invoice.json` | v2 | Monatliche Reverse-Charge-Rechnung an Etsy ueber die digitalen Verkaeufe |
| `06_etsy_lexoffice_export.json` | v1 | Monats-CSV des Etsy-Zahlungskontos fuer Lexoffice (ersetzt PayJoe) |

Nach dem Import in jeder Node das passende Credential aus Schritt 3 auswaehlen (die JSONs enthalten nur Platzhalter wie `POSTGRES_CREDENTIAL_ID`) und die Workflows aktivieren.

**Versionen:** Die Version steht im Namen des Workflows (`01 · Etsy Orders Sync · v1`) und wird mit jeder Aenderung an der JSON-Datei erhoeht. n8n uebernimmt den Namen beim Import. Ein Blick in die Workflow-Liste zeigt so, welcher Stand laeuft; Sollstand ist die Spalte *Version* oben. Workflows ganz ohne Versionsnummer stammen von vor dieser Regel und sind veraltet.

**Aktualisieren:** Den neuen Stand als **neuen** Workflow importieren. Ein Import in einen bestehenden Workflow fuegt die Nodes zusaetzlich ein, statt sie zu ersetzen. Dann Credentials zuweisen, den alten Workflow deaktivieren, den neuen aktivieren (bei 04 und 05 in dieser Reihenfolge, sonst meldet n8n einen Konflikt beim Webhook-Pfad) und den alten loeschen.

### 7. Rechnung und Lieferschein erzeugen (Workflow 04)

Workflow 04 hat ein n8n-Formular: im Browser `<n8n-adresse>/form/rechnung` oeffnen, die Etsy-Bestellnummer eintragen, **Erzeugen**. Danach stehen Rechnung und Lieferschein auf der Seite zum Download bereit (zum Ausdrucken beim Packen) und gehen zusaetzlich per Mail an `mail.to`.

- Derselbe Aufruf fuer dieselbe Bestellung liefert dieselbe Rechnungsnummer, es entsteht keine zweite Rechnung.
- Bestellungen nur mit digitalen Artikeln, unbekannte Bestellnummern oder fehlende Verkaeuferdaten lehnt das Formular mit einer Meldung ab, ohne eine Nummer zu vergeben.
- Fuer Skripte gibt es weiterhin den Webhook `POST /webhook/generate-docs` mit Body `{"order_id": "..."}`; er antwortet mit `{"status": "ok", "order_id": "...", "invoice_number": "..."}`.

> **Sicherheit:** Formular und Webhooks haben keine Anmeldung. Wer die Adresse erreicht, kann Rechnungsnummern fuer beliebige Bestellungen vergeben lassen. Ist n8n nur ueber VPN erreichbar, ist das in Ordnung. Ist n8n aus dem Internet erreichbar: im Formular-Trigger unter **Authentication** *Basic Auth* setzen (neuere n8n-Versionen bieten auch *n8n User Auth*, also das n8n-Login) und bei den Webhooks *Header Auth*. Das gilt auch fuer die Webhooks von Workflow 05 (`etsy-rc-invoice`) und 06 (`etsy-lexoffice-export`): Letzterer liefert in der Antwort die Etsy-Buchungen des Monats und kann einen Monat als importiert markieren.

## Lokal testen

`test/` enthaelt eine vollstaendige Testumgebung, die auf dem eigenen Rechner offline laeuft: n8n mit fertig eingerichteten Credentials und Workflows, ein nachgebautes Etsy mit Testbestellungen fuer Vormonat und laufenden Monat, Mailpit statt echtem Mailversand, dazu dieselbe Datenbank, derselbe Config-Loader und dieselbe typst-api wie im Betrieb.

```bash
docker compose -f test/docker-compose.yml up -d --build
```

Danach n8n unter `http://localhost:5678` (Login `test@example.org` / `Testpass123`), Mails unter `http://localhost:8025`. Ablauf, erwartete Ergebnisse und Pruefbericht: [docs/testen.md](docs/testen.md).

## Digitale Verkaeufe: Reverse-Charge-Rechnung an Etsy (Workflow 05)

Bei digitalen Artikeln gilt Etsy gegenueber dem Kaeufer als Verkaeufer (Art. 9a MwSt-DVO), erhebt die VAT und fuehrt sie selbst ab. Der Shop verkauft die Leistung an Etsy Ireland und stellt dafuer eine Reverse-Charge-Rechnung ohne USt. Workflow 05 erzeugt diese Rechnung einmal im Monat:

- **Wann:** am 1. jedes Monats um 6 Uhr (Europe/Berlin) fuer den Vormonat. Manuell ueber das Formular `<n8n-adresse>/form/etsy-rechnung` (Feld *Monat* im Format `YYYY-MM`, leer = Vormonat; das PDF steht danach zum Download bereit) oder per `POST /webhook/etsy-rc-invoice` mit Body `{"month": "2026-09"}`, ohne `month` gilt der Vormonat. Laufende oder kuenftige Monate werden abgelehnt.
- **Welche Bestellungen:** alle nicht stornierten Etsy-Bestellungen mit mindestens einem digitalen Artikel, die noch auf keiner Etsy-Rechnung stehen, Bestelldatum (deutsche Zeit) ab `start_date` bis Monatsende. Verspaetet synchronisierte Bestellungen aus Vormonaten landen dadurch automatisch auf der naechsten Rechnung; der Leistungszeitraum beginnt dann beim aeltesten Verkauf.
- **Betrag je Bestellung:** der Verkaufspreis ohne die von Etsy erhobene VAT. Etsys `subtotal` (Artikel nach Gutschein, ohne VAT und Versand) entspricht genau Brutto minus VAT. Bei gemischten Bestellungen zaehlt nur der digitale Anteil, der Gutschein wird anteilig verteilt. Die physischen Artikel derselben Bestellung rechnet Workflow 04 identisch ab, zusammen ergibt das wieder den `subtotal`.
- **Ergebnis:** Rechnung mit eigener Nummer je Monat nach `ETSY_RC_NUMBER_FORMAT` (Standard `RE-E-2026-09` fuer September 2026; der Zaehler der Kundenrechnungen bleibt unberuehrt). Monate ohne digitale Verkaeufe haben keine Rechnung und damit auch keine Nummer. Gespeichert in `etsy_rc_invoices` mit eingefrorenen Positionen, Verkaeufer- und Empfaengerdaten. Die Bestellungen werden in `orders.etsy_rc_invoice_number` markiert. Das PDF geht per E-Mail raus, mit Abgleichwerten fuer das Etsy-Zahlungskonto (gezahlt inkl. VAT, davon VAT).
- **Erneut ausfuehren** (z.B. nach einem Mail- oder PDF-Fehler) erzeugt keine neue Rechnung: Der Monat liefert dieselbe Rechnung mit derselben Nummer und demselben Inhalt aus dem Snapshot. Monate ohne digitale Verkaeufe erzeugen keine Rechnung und verbrauchen keine Nummer.

Rein digitale Bestellungen bekommen deshalb keine Kundenrechnung mehr (Workflow 04 lehnt sie ab, ohne eine Nummer zu vergeben), gemischte nur ueber die physischen Artikel.

Nicht automatisiert: Wird ein digitaler Verkauf **nach** Rechnungsstellung erstattet, ist eine Korrektur der Etsy-Rechnung (Gutschrift/Storno) manuell noetig. Teilerstattungen mindern den abgerechneten Betrag nicht.

## Etsy-Zahlungskonto (Workflow 02)

Workflow 02 speichert jeden Eintrag des Etsy-Zahlungskontos (Ledger) als Zeile in `etsy_transactions`, Betrag in EUR mit Vorzeichen. `ledger_type`, `reference_type`, `reference_id`, `balance` (Etsy-Guthaben nach der Buchung) und `sequence_number` sind die Originalangaben von Etsy, `type` ist die Einordnung:

| `type` | Etsy-`ledger_type` | Bedeutung |
|---|---|---|
| `sale` | `PAYMENT_GROSS` | Zahlung des Kaeufers, **brutto** inkl. der von Etsy erhobenen VAT/Sales Tax |
| `marketplace_tax` | `VAT_TAX_EP`, `SALES_TAX` | die von Etsy als Plattform erhobene Steuer als Minus-Zeile; Etsy fuehrt sie selbst ab |
| `fee_transaction` | `TRANSACTION` | Transaktionsgebuehr |
| `fee_listing` | `LISTING`, `RENEW_SOLD`, `RENEW_SOLD_AUTO`, `RENEW_AUTO`, `RENEW_EXPIRED`, `AUTO_RENEW_EXPIRED` | Einstell- und Verlaengerungsgebuehren |
| `fee_processing` | `PAYMENT_PROCESSING_FEE` | Zahlungsgebuehr |
| `fee_ads` | `OFFSITE_ADS_FEE` | Offsite Ads |
| `refund` | `REFUND` | Erstattung |
| `payout` | `DISBURSE`, `DISBURSE2` | Auszahlung aufs Bankkonto |
| `card_payment` | `BILLING_PAYMENT` | Etsy belastet die hinterlegte Karte, um einen negativen Saldo auszugleichen |
| `unknown` | alle anderen | unbekannter Typ: in Workflow 02 (`ENTRY_TYPE_MAP`) ergaenzen; bis dahin bricht der Lexoffice-Export (Workflow 06) ab |

Fuer die Auswertung:

- **Umsatz ohne die von Etsy erhobene Steuer = Summe aus `sale` und `marketplace_tax`.** Die `marketplace_tax`-Zeilen also nicht herausfiltern, sonst enthaelt der Umsatz die VAT. Bei rein digitalen Bestellungen ergibt das den Betrag, den Workflow 05 an Etsy fakturiert (am Monatsende koennen Ledger-Datum und Bestelldatum in verschiedene Monate fallen).
- Gebuehren sind alle `fee_*`. `payout` und `card_payment` sind Geldbewegungen zwischen Etsy-Konto und Bank bzw. Karte, weder Ertrag noch Aufwand.
- `order_id` setzt Workflow 02 bei Verkaeufen und Erstattungen, notfalls ueber die zugehoerige Zahlung. Gebuehren verweisen auf andere Objekte (`reference_type`/`reference_id`).
- Fuer Lexoffice fasst Workflow 06 das zu wenigen Monatszeilen zusammen (naechster Abschnitt).

Monatsuebersicht, z.B. in Adminer:

```sql
SELECT month,
       SUM(amount) FILTER (WHERE type IN ('sale', 'marketplace_tax')) AS umsatz_ohne_etsy_steuer,
       SUM(amount) FILTER (WHERE type = 'marketplace_tax')            AS etsy_steuer,
       SUM(amount) FILTER (WHERE type LIKE 'fee%')                    AS gebuehren,
       SUM(amount) FILTER (WHERE type = 'refund')                     AS erstattungen,
       SUM(amount) FILTER (WHERE type IN ('payout', 'card_payment'))      AS geldbewegungen,
       COUNT(*)    FILTER (WHERE type = 'unknown')                      AS unbekannt
FROM etsy_transactions
GROUP BY month
ORDER BY month;
```

### Etsy-Daten neu abrufen

Workflow 01 merkt sich die zuletzt verarbeitete Aenderung (`etsy.receipts_cursor`), Workflow 02 setzt beim juengsten gespeicherten Ledger-Eintrag fort. Aeltere Zeilen ohne Etsy-Rohdaten (aus frueheren Versionen von Workflow 02, bis 400 Tage zurueck) und Zeilen mit Typ `unknown` holt Workflow 02 von selbst erneut ab und ordnet sie neu ein.

Bestellungen vor dem ersten Abruf nachladen:

1. `ETSY_SYNC_START` auf den ersten gewuenschten Tag setzen und `docker compose up -d` ausfuehren.
2. Den Cursor loeschen (Adminer oder psql), dann beginnt Workflow 01 beim naechsten Lauf bei `ETSY_SYNC_START`:

   ```sql
   DELETE FROM app_config WHERE scope = 'etsy' AND key = 'receipts_cursor';
   ```

Bestellungen werden dabei nur aktualisiert, nicht dupliziert; Rechnungsnummern und die Markierung fuer die Etsy-Rechnung bleiben unberuehrt. Fuer das Ledger wirkt `ETSY_SYNC_START` nur bei leerer Tabelle `etsy_transactions`. Die Tabelle nicht leeren, sobald Lexoffice-Exporte (Workflow 06) existieren: Export und Bestaetigung beziehen sich auf die gespeicherten Buchungen.

## Etsy-Zahlungskonto → Lexoffice (Workflow 06)

Ersetzt PayJoe. Aus `etsy_transactions` entsteht pro abgeschlossenem Monat eine kleine CSV fuer ein Lexoffice-Konto ohne Anbindung („Etsy-Zahlungskonto“), mit wenigen Summenzeilen statt einer Zeile je Etsy-Buchung:

| Zeile | Anzahl | Betrag | In Lexoffice zuordnen zu |
|---|---|---|---|
| Digitale Verkaeufe netto (Verkauf minus Etsy-VAT) | 1, Monatsletzter | + | Proformarechnung an Etsy (Workflow 05); ihre Nummer steht im Verwendungszweck |
| Etsy-Gebuehren | 1, Monatsletzter | − | Etsy-Gebuehrenrechnung |
| Auszahlung | je Auszahlung | − | Geldtransit mit dem Eingang auf dem Bankkonto |
| Kartenzahlung an Etsy (billing_payment) | je Zahlung | + | je nach Karte |
| Physischer Verkauf | je Bestellung | + brutto | Kundenrechnung (Workflow 04) |

Buchungslogik, Kontrollen und offene Punkte im Detail: [docs/lexoffice-etsy-export.md](docs/lexoffice-etsy-export.md).

**Ablauf je Monat** (Webhook `POST /webhook/etsy-lexoffice-export`):

1. **Vorschau** (schreibt nichts): Body `{"month": "2026-09"}`. Per Mail kommen Pruefbericht und `etsy_lexoffice_2026-09_VORSCHAU.csv`; mit dem Etsy-Zahlungskonto-Auszug und der Proformarechnung vergleichen.
2. **Erzeugen**: `{"month": "2026-09", "action": "create"}`. Laeuft automatisch am 2. jedes Monats um 7 Uhr fuer den Vormonat (nach Workflow 05 am 1.). Per Mail kommt `etsy_lexoffice_2026-09.csv`. Erneutes Ausfuehren liefert dieselbe Datei; neu erzeugt wird sie nur mit `"regenerate": true` und nur, solange der Import nicht bestaetigt ist.
3. In Lexoffice beim Etsy-Zahlungskonto **einmal** importieren (Lexoffice erkennt keine Dubletten, ein Import laesst sich nicht rueckgaengig machen).
4. **Bestaetigen**: `{"month": "2026-09", "action": "confirm"}`. Erst jetzt wird `lexoffice_synced` fuer die enthaltenen Etsy-Buchungen gesetzt.

Eine Datei entsteht nur, wenn alle Kontrollen bestehen: Monat abgeschlossen und nicht vor `LEXOFFICE_START_MONTH`, keine unbekannten Etsy-Buchungstypen, Erloeszeile gleich Betrag der Proformarechnung, Summe der Zeilen gleich Summe der Etsy-Buchungen, keine Luecke gegenueber Etsys eigenem Kontostand. Sonst nennt die Mail die Gruende. Stammt die Proformarechnung eines Monats nicht aus Workflow 05 (z.B. vor `ETSY_RC_START_DATE` von Hand geschrieben), deren Nummer als `"proforma_number"` mitgeben.

Dasselbe geht im Terminal (Worker-User, wie n8n):

```bash
q() { docker exec -i orderdb sh -c 'psql -X -At -U "$(cat /run/secrets/db_worker_user.txt)" -d "$(cat /run/secrets/db_name.txt)"' <<< "$1"; }
q "SELECT lexoffice_export_build('2026-09')->>'report_text'"     # Vorschau mit Pruefbericht, schreibt nichts
q "SELECT lexoffice_export_create('2026-09')->>'report_text'"    # Datei erzeugen
# Datei byte-genau holen (psql haengt sonst einen Zeilenumbruch an)
q "SELECT encode(convert_to(csv, 'UTF8'), 'base64') FROM lexoffice_exports
   WHERE month = '2026-09' AND superseded_at IS NULL" | base64 -d > etsy_lexoffice_2026-09.csv
q "SELECT lexoffice_export_confirm('2026-09')->>'report_text'"   # nach dem Import bestaetigen
```

**Einrichtung:**

1. Migration `004_lexoffice_export.sql` einspielen („Updates einspielen“, Schritt 3).
2. Workflow 02 neu importieren. Er speichert jetzt Etsys Originaldaten je Buchung (Typ, Kontostand) und traegt bei Verkaeufen die Bestellnummer nach, damit digitale und physische Verkaeufe getrennt werden koennen. Beim ersten Lauf ergaenzt er das automatisch fuer die vorhandenen Buchungen.
3. `LEXOFFICE_START_MONTH` setzen (Schritt 5): der erste Monat, den PayJoe noch nicht nach Lexoffice gebracht hat.
4. In Lexoffice ein Konto ohne Anbindung fuer das Etsy-Guthaben anlegen.
5. Workflow 06 importieren, Credentials zuweisen, eine Vorschau fuer den ersten Monat erzeugen und pruefen. Beim ersten Import in Lexoffice die Spalten Datum, Betrag und Verwendungszweck zuordnen und die Vorschau dort genau ansehen. Danach Workflow 06 aktivieren.

## Datenbank im Browser ansehen (Adminer)

[Adminer](https://www.adminer.org) ist eine schlanke Web-Oberflaeche fuer die Datenbank (aehnlich phpMyAdmin): Tabellen durchsehen, filtern, einzelne Werte korrigieren, SQL ausfuehren. Der Container ist optional und startet nicht mit dem normalen `docker compose up -d`:

```bash
docker compose --profile tools up -d adminer     # starten
docker compose --profile tools stop adminer      # danach wieder stoppen
```

Adminer lauscht nur auf `127.0.0.1:8081` des Servers, also nicht im Internet. Zugriff vom eigenen Rechner per SSH-Tunnel:

```bash
ssh -L 8081:127.0.0.1:8081 <user>@<dein-server>
```

Dann im Browser `http://localhost:8081/?pgsql=orderdb` oeffnen (waehlt PostgreSQL vor) und anmelden. Steht *System* auf MySQL, meldet Adminer "Connection refused":

| Feld | Wert |
|---|---|
| **System** | PostgreSQL |
| **Server** | `orderdb` (vorausgefuellt) |
| **Benutzer / Passwort** | Worker-User aus den Bootstrap-Logs; den Admin-User nur fuer Schemaaenderungen |
| **Datenbank** | DB-Name aus den Bootstrap-Logs (Standard `orderdb`) |

Vorsicht bei Aenderungen von Hand: `invoice_counter` und `orders.invoice_number` bilden den lueckenlosen Nummernkreis der Kundenrechnungen, `etsy_rc_invoices` und `orders.etsy_rc_invoice_number` die Etsy-Rechnungen und die unveraenderlichen Rechnungs-Snapshots. Dort nichts loeschen oder umnummerieren. Lesen ist unproblematisch; Konfigurationswerte besser ueber die Umgebungsvariablen pflegen (Schritt 5), sonst ueberschreibt der naechste Start sie wieder.

Lauscht nach dem Start nichts auf `127.0.0.1:8081`: `docker ps -a --filter name=adminer` zeigt, ob der Container laeuft und ob die Freigabe steht (`127.0.0.1:8081->8080/tcp`), `docker logs adminer` den Grund. Steht dort nur `8080/tcp`, haengt der Container an keinem nicht-internen Netz (ein mit `--internal` angelegtes `n8n-backend` gibt keine Ports frei); dafuer ist das zusaetzliche Netz `adminer-access` da, also den Container mit der aktuellen `docker-compose.yml` neu anlegen (`--force-recreate`). Den Befehl im selben Verzeichnis bzw. mit demselben Projektnamen ausfuehren wie den Stack (`docker compose ls` zeigt beides; sonst `-p <projektname>`), sonst legt Compose ein zweites Projekt an und scheitert am schon vergebenen Containernamen `orderdb`.

Den Port nie auf `0.0.0.0` umstellen oder ueber einen oeffentlichen Reverse-Proxy freigeben: Das waere eine Anmeldeseite zur Buchhaltungs-DB direkt im Internet. Unterstuetzt ein Deploy-Werkzeug keine Compose-Profile, startet Adminer mit dem Stack, bleibt aber auf `127.0.0.1` begrenzt; dann bei Nichtgebrauch stoppen.

## Updates einspielen

Nach einem `git pull` auf dem Server:

1. **Einmalig fuer Installationen von vor den festen Volumes:** Die alten Volumes heissen `<projektname>_postgres_data` und `<projektname>_secrets_data` (`docker volume ls`). Vor dem ersten Start mit der neuen `docker-compose.yml` die Daten in die festen Volumes kopieren, sonst startet die neue Version mit leerer Datenbank:

   ```bash
   docker compose down
   docker volume create bookkeeping_pgdata
   docker volume create bookkeeping_secrets
   docker run --rm -v <projektname>_postgres_data:/from:ro -v bookkeeping_pgdata:/to  alpine cp -a /from/. /to/
   docker run --rm -v <projektname>_secrets_data:/from:ro  -v bookkeeping_secrets:/to alpine cp -a /from/. /to/
   ```

2. **typst-api neu bauen** – die Templates werden ins Image kopiert, ein reines `docker compose up -d` laeuft weiter mit dem alten Stand:

   ```bash
   docker compose up -d --build typst-api
   docker exec typst-api curl -s localhost:8080/health   # templates_sha zeigt den laufenden Template-Stand
   ```

3. **Datenbank-Migrationen anwenden** – `postgres/01_schema.sql` laeuft nur beim allerersten Start mit leerem Volume (zusammen mit allen Migrationen). Schemaaenderungen fuer bestehende Datenbanken liegen in `postgres/migrations/` und sind idempotent (mehrfaches Ausfuehren schadet nicht):

   ```bash
   for f in postgres/migrations/*.sql; do
     docker exec -i orderdb sh -c 'psql -v ON_ERROR_STOP=1 -U "$(cat /run/secrets/db_admin_user.txt)" -d "$(cat /run/secrets/db_name.txt)"' < "$f"
   done
   ```

   Bestehende Ledger-Zeilen ergaenzt und ordnet Workflow 02 danach bei seinem naechsten Lauf selbst neu ein (Etsy-Rohdaten, Listing-Verlaengerungen, Kartenbelastungen).

4. **Alles neu starten:** `docker compose up -d --build`. Das baut die Images neu und schreibt die Konfiguration erneut.

5. **Workflows neu importieren**, deren Version sich geaendert hat, und Credentials wieder zuweisen (Schritt 6, *Aktualisieren*).

Die Datenbanklogik (z.B. der Lexoffice-Export) hat Tests. Sie laufen in einem Wegwerf-Container, nie gegen die echte Datenbank: `postgres/tests/run.sh`.

## Datensicherung

Die festen Volumes schuetzen vor versehentlichem Loeschen, nicht vor einem Plattendefekt oder dem Verlust des Servers. `backup.sh` legt einen komprimierten Dump in `backups/` ab und entfernt Dumps, die aelter als 30 Tage sind. Als taeglicher Cronjob auf dem Server:

```bash
0 3 * * * /pfad/zum/repo/backup.sh >> /pfad/zum/repo/backups/backup.log 2>&1
```

Die Dumps zusaetzlich regelmaessig vom Server wegkopieren (z.B. mit `rsync` oder `rclone` auf einen anderen Rechner oder Speicher). Rechnungen und Buchungsbelege muessen mehrere Jahre aufbewahrt werden.

Wiederherstellen (ersetzt die komplette Datenbank, vorher alle Workflows deaktivieren):

```bash
docker exec orderdb sh -c 'U=$(cat /run/secrets/db_admin_user.txt); D=$(cat /run/secrets/db_name.txt); dropdb -U "$U" --force "$D" && createdb -U "$U" "$D"'
gunzip -c backups/<datei>.sql.gz | docker exec -i orderdb sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$(cat /run/secrets/db_admin_user.txt)" -d "$(cat /run/secrets/db_name.txt)"'
```

## typst-api

REST-API zur Generierung von PDF-Dokumenten. Endpoints:

- `POST /invoice` – Rechnung (DIN A4)
- `POST /delivery-note` – Lieferschein (DIN A4)
- `POST /shipping-label` – Versandetikett (DIN A6)

Die Rechnungs- und Lieferschein-Templates sind von **[invoice-pro](https://github.com/leonieziechmann/invoice-pro)** von Leonie Ziechmann (MIT-Lizenz) inspiriert und im gleichen visuellen Stil gehalten; sie importieren das Paket nicht, sondern sind eigenstaendige Typst-Dateien.

Die API ist intern unter `http://typst-api:8080` erreichbar. Swagger-Doku: `http://typst-api:8080/docs`.
