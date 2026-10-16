# Lokal testen

`test/` enthält eine Testumgebung für den eigenen Rechner. Sie nutzt dieselben
Bausteine wie der Betrieb (bootstrap, Postgres-Schema, Config-Loader,
typst-api und die Workflows aus `n8n/workflows/`) und ersetzt nur die
Außenwelt:

| Im Betrieb | In der Testumgebung |
|---|---|
| Etsy-API | `test/etsy-mock`: beantwortet dieselben URLs mit Testbestellungen, Ledger-Einträgen und Zahlungen |
| Mailserver | Mailpit: fängt alle Mails ab und zeigt sie im Browser |
| Notion | nicht enthalten (Workflow 03 wird nicht importiert) |
| Lexoffice | nicht enthalten; Workflow 06 erzeugt die CSV, importiert wird sie nicht |
| Credentials von Hand anlegen | `test/n8n-setup`: legt Login, Credentials und Workflows automatisch an |
| Umgebungsvariablen im Hosting-Panel | `test/test.env` mit ausgedachten Werten |

Die Testumgebung ist ein eigenes Compose-Projekt (`bookkeeping-test`) mit
eigenen Volumes und eigenem Netz. Eine echte Installation auf demselben
Rechner wird nicht berührt.

## Voraussetzungen

Docker mit Compose. Beim ersten Start werden die Images geladen bzw. gebaut
(dafür braucht es einmal Internet, für typst-api z.B. den Typst-Download).
Danach läuft alles offline.

Belegt werden nur Ports auf `127.0.0.1`: 5678 (n8n), 8025 (Mailpit), 8081 (Adminer).

## Starten

Im Repository-Root:

```bash
docker compose -f test/docker-compose.yml up -d --build
docker compose -f test/docker-compose.yml logs -f n8n-setup     # bis "importiert und aktiviert"
```

| | Adresse | Zugang |
|---|---|---|
| n8n | http://localhost:5678 | `test@example.org` / `Testpass123` |
| Mails | http://localhost:8025 | – |
| Adminer | http://localhost:8081 | Server `orderdb`, Benutzer `worker`, Passwort `test-worker-pw`, Datenbank `orderdb` |

Importiert werden die Workflows 01, 02, 04, 05 und 06. Aktiv sind 04, 05 und
06, damit Formulare und Webhook erreichbar sind. 01 und 02 startest du von
Hand, damit du siehst, was passiert.

## Testdaten

Der Etsy-Mock erzeugt beim Start Bestellungen im Vormonat und im laufenden
Monat (Datei `test/etsy-mock/fixtures.py`). Alle Namen und Adressen sind
ausgedacht.

| Bestellung | Monat | Fall | Erwartung |
|---|---|---|---|
| 1001 | laufend | physisch, Apostroph im Namen, zweite Adresszeile | Rechnung + Lieferschein |
| 1002 | laufend | rein digital | Formular lehnt ab; nächsten Monat auf der Etsy-Rechnung |
| 1003 | laufend | gemischt, 3 € Gutschein (Poster 20 €, digital 10 €) | Rechnung über 18,00 € + Versand; 9,00 € auf der Etsy-Rechnung |
| 1004 | laufend | Titel HTML-kodiert von Etsy | Titel lesbar: Karte "Mother's Day" |
| 2001 | Vormonat | digital, 2 × 7,50 €, Frankreich | 15,00 € auf der Etsy-Rechnung |
| 2002 | Vormonat | digital, storniert und erstattet | nicht auf der Etsy-Rechnung |
| 2003 | Vormonat | physisch, versandt mit Sendungsnummer | Rechnung + Lieferschein mit Sendungsnummer |
| 2004 | Vormonat | digital, Österreich (20 % VAT) | 12,00 € auf der Etsy-Rechnung |

Dazu im Ledger, mit laufendem Kontostand wie bei Etsy: Gebühren je Bestellung,
Listing-Verlängerungen, eine Auszahlung, eine Kartenbelastung
(`billing_payment`) und ein unbekannter Typ (`shipping_labels`, laufender
Monat), der im Prüfbericht als „unbekannt“ auftauchen soll. Verkäufe und VAT
verweisen wie bei Etsy auf die Zahlung; Workflow 02 holt die Bestellnummer
über den Zahlungs-Abruf nach.

## Ablauf

1. **Bestellungen abrufen:** In n8n „01 · Etsy Orders Sync“ öffnen,
   **Execute workflow**. Danach stehen die 8 Bestellungen in `orders`
   (Adminer oder Prüfbericht).
2. **Ledger abrufen:** „02 · Etsy Transactions Sync“, **Execute workflow**.
   Danach haben alle Verkäufe eine Bestellnummer (`order_id`).
3. **Rechnung und Lieferschein:** http://localhost:5678/form/rechnung öffnen
   und nacheinander 1001, 1003, 1004, 2003 eintragen. Jede Seite bietet beide
   PDFs zum Download an, Mailpit zeigt je eine Mail mit zwei Anhängen.
   - 1001 ein zweites Mal: dieselbe Rechnungsnummer, keine neue Rechnung.
   - 1002: „Nicht möglich … enthält nur digitale Artikel“.
   - eine Fantasienummer: „… nicht in der Datenbank gefunden“.
4. **Monatsrechnung an Etsy:** http://localhost:5678/form/etsy-rechnung, Feld
   leer lassen (= Vormonat). Erwartet: eine neue Rechnung über 27,00 € mit
   2 Verkäufen (2001 und 2004). Ein zweites Mal: „Bereits angelegt, erneut
   versendet“ mit derselben Nummer. Der laufende Monat wird abgelehnt.
   Alternativ in n8n „05 · …“ öffnen und **Execute workflow** am Zeitplan-
   Trigger: das ist genau der Lauf vom 1. des Monats.
5. **Lexoffice-Export für den Vormonat** (Workflow 06, nach Schritt 3 und 4).
   Vorschau, Erzeugen und Bestätigen per Webhook, `<monat>` = Vormonat:

   ```bash
   e() { curl -s -X POST http://localhost:5678/webhook/etsy-lexoffice-export \
           -H 'content-type: application/json' -d "$1"; echo; }
   e '{"month": "<monat>"}'                          # Vorschau, schreibt nichts
   e '{"month": "<monat>", "action": "create"}'      # Datei erzeugen
   e '{"month": "<monat>", "action": "confirm"}'     # Import bestätigen
   ```

   Erwartet: 4 Zeilen – physischer Verkauf 2003 mit 16,95 € brutto, die
   Auszahlung −40,00 €, digitale Verkäufe netto 27,00 € mit der Nummer der
   Etsy-Rechnung aus Schritt 4 und die Etsy-Gebühren als eine Summe. Hinweis
   zur Erstattung bei 2002, keine Fehler. Ein zweites `create` liefert dieselbe
   Datei. Ohne Etsy-Rechnung aus Schritt 4 bricht der Export ab, weil die
   Erlöszeile nicht zur Rechnung passt. Mails mit CSV in Mailpit.
6. **Prüfbericht:**

   ```bash
   test/report.sh
   ```

   Erwartet: keine physischen Bestellungen ohne Rechnung (nachdem Schritt 3
   alle vier erzeugt hat), keine digitalen Verkäufe des Vormonats ohne
   Etsy-Rechnung, keine stornierte Bestellung auf einer Etsy-Rechnung, ein
   unbekannter Ledger-Typ `shipping_labels`. Im Abgleich weicht der Vormonat
   um den Betrag der stornierten Bestellung ab (Verkauf und Erstattung stehen
   im Ledger getrennt).

Die PDFs selbst prüfen: Rechnung 1003 zeigt Poster 20,00 €, Rabatt −2,00 €,
Versand 4,90 €. Die Etsy-Rechnung enthält beide USt-IdNr. und den Hinweis auf
die Steuerschuldnerschaft des Leistungsempfängers.

## Nach Änderungen

| Geändert | Befehl |
|---|---|
| Workflow-JSON in `n8n/workflows/` | `docker compose -f test/docker-compose.yml run --rm n8n-setup` (ersetzt die Workflows) |
| typst-Templates, `typst-api/` | `docker compose -f test/docker-compose.yml up -d --build typst-api` |
| `config-loader/`, `test/test.env` | `docker compose -f test/docker-compose.yml up -d --build config` |
| Schema, Testdaten, neuer Monat | alles neu: `docker compose -f test/docker-compose.yml down -v`, dann wieder `up -d --build` |

`down -v` löscht nur die Volumes der Testumgebung (Namen beginnen mit
`bookkeeping-test_`). Die echten Volumes `bookkeeping_pgdata` und
`bookkeeping_secrets` sind `external` und gehören nicht zu diesem Projekt.

Beenden ohne Daten zu löschen: `docker compose -f test/docker-compose.yml down`.

## Prüfbericht im Betrieb

`test/report.sql` funktioniert auch mit der echten Datenbank und ändert dort
nichts (nur lesend). Auf dem Server im Repository-Root:

```bash
test/report.sh --prod
```

## Grenzen

- Der Etsy-Mock bildet nur die Felder nach, die die Workflows lesen. Ändert
  Etsy das Format seiner API, fällt das hier nicht auf.
- Die n8n-Version ist in `test/docker-compose.yml` festgelegt. Läuft im
  Betrieb eine andere Version, dort ebenfalls eintragen, damit der Test
  aussagekräftig ist. `test/n8n-setup/setup.mjs` nutzt die interne REST-API
  von n8n; bei einem großen Versionssprung kann sie sich ändern.
- Notion (Workflow 03) und die echte Etsy-Anmeldung (OAuth) sind nicht Teil
  des Tests, der Import in Lexoffice selbst ebenfalls nicht.
- Die Datenbanklogik des Lexoffice-Exports hat zusätzlich eigene Tests:
  `postgres/tests/run.sh`.
