# Etsy-Zahlungskonto → Lexoffice: Monats-CSV

Dieses Dokument erklaert, wie Workflow 06 die Etsy-Buchungen eines Monats in
eine kleine CSV fuer Lexoffice verwandelt, warum die Zeilen so aussehen, welche
Kontrollen laufen und was (noch) nicht automatisch geht. Bedienung und
Einrichtung stehen kurz in der README („Etsy-Zahlungskonto → Lexoffice“).

Ersetzt wird damit PayJoe: das erzeugte pro Verkauf 5–6 Einzelpositionen
(inkl. der Etsy-VAT), die in Lexoffice einzeln zugeordnet werden mussten.
Jetzt sind es typischerweise etwa fuenf Zeilen pro Monat.

## Grundidee: das Etsy-Guthaben ist ein eigenes Konto

Etsy verhaelt sich wie ein PayPal-Konto: Verkaeufe und Gebuehren veraendern das
**Guthaben bei Etsy**. Die Auszahlung aufs Bankkonto ist nur ein Umbuchen von
einem eigenen Konto aufs andere, kein Umsatz. Auf dem Bankkonto kommen deshalb
nie einzelne Verkaeufe an, nur Auszahlungen.

In Lexoffice wird dafuer ein **Konto ohne Anbindung** (Offline-Bankkonto, z.B.
„Etsy-Zahlungskonto“) angelegt. Umsaetze kommen dort nur per CSV-Import hinein.
Jede Zeile der CSV wird in Lexoffice wie eine Kontobewegung einem Beleg
zugeordnet. Deshalb wenige Summenzeilen statt Dutzender Einzelbuchungen.

| Zeile | Anzahl/Monat | Datum | Betrag | Zuordnung in Lexoffice (laut Konzept, SKR03) |
|---|---|---|---|---|
| Digitale Verkaeufe, netto | 1 (Summe) | letzter Tag des Monats | + | Proformarechnung an Etsy Ireland UC (Workflow 05) |
| Etsy-Gebuehren | 1 (Summe) | letzter Tag des Monats | − | Gebuehrenrechnung von Etsy (Reverse Charge §13b, Konto 3123; die Steuerbuchung macht Lexoffice) |
| Auszahlung | 1 je Auszahlung | Tag der Auszahlung | − | Geldtransit (1360) mit dem Eingang auf dem Bankkonto |
| Kartenzahlung an Etsy | 1 je Zahlung | Tag der Zahlung | + | je nach Karte, siehe „Offene Punkte“ |
| Physischer Verkauf | 1 je Bestellung | Tag der Gutschrift bei Etsy | + (brutto) | Kundenrechnung aus Workflow 04 (Erloese mit USt) |

Beispiel (erfundene Zahlen):

```
Datum;Betrag;Verwendungszweck
01.03.2025;0,20;Etsy Kartenzahlung (billing_payment) Ausgleich Etsy-Gebuehren, ID 1000000002
25.03.2025;-5,23;Etsy Auszahlung DISBURSE2, ID 1000000012
31.03.2025;7,50;2025-0003 Etsy digitale Verkaeufe 03/2025 netto (2 Verkaeufe)
31.03.2025;-2,27;Etsy-Gebuehren 03/2025 (Ads 0,68 + Transaction 0,49 + Processing 0,75 + Listing 0,35)
```

Die Summe aller Zeilen ist genau die Veraenderung des Etsy-Guthabens im Monat.
Lexoffice zeigt fuer ein Konto ohne Anbindung keinen Kontostand an; diese
Kontrolle macht deshalb der Export selbst (siehe unten).

### Warum „netto“ und warum keine VAT-Zeile

Digitale Artikel verkauft Etsy als Marktplatz im eigenen Namen an den Kaeufer
und fuehrt die VAT selbst ab. Der Shop verkauft seine Leistung an Etsy Ireland
UC (Reverse Charge, §3a Abs. 2 UStG, ohne deutsche USt) und stellt dafuer
monatlich eine Proformarechnung (Workflow 05). Etsy bucht aufs Guthaben den
Bruttobetrag des Kaeufers und zieht die VAT gleich wieder ab. Beides zusammen
ist genau der Rechnungsbetrag an Etsy. Wuerden Brutto und VAT einzeln nach
Lexoffice gehen, stuende die VAT als Erloes bzw. Kosten in den Buechern, obwohl
sie den Shop nichts angeht. Deshalb werden sie vorher verrechnet.

### Physische Verkaeufe

Sie werden nicht an Etsy, sondern direkt an den Kunden abgerechnet (Workflow 04,
mit USt) und stehen deshalb nicht auf der Proformarechnung. Das Geld laeuft aber
trotzdem ueber das Etsy-Guthaben, also gehoeren sie in die CSV: einzeln und
brutto, damit Lexoffice die Zeile der Kundenrechnung zuordnen kann. Etsy
schreibt physische Verkaeufe erst beim Versand gut; die Zeile traegt deshalb das
Datum der Gutschrift, nicht das Bestelldatum. Bei gemischten Bestellungen geht
der physische Anteil (Artikel nach anteiligem Gutschein plus Versand, genau wie
auf der Kundenrechnung) einzeln in die Datei, der Rest zu den digitalen
Verkaeufen. Die Gebuehren auf physische Verkaeufe stecken in der normalen
Gebuehrensumme, Etsy stellt sie auf derselben Gebuehrenrechnung.

### Kartenzahlung (billing_payment)

Reicht das Guthaben nicht fuer die Gebuehren, belastet Etsy die hinterlegte
Karte. Das ist **keine Gebuehr**, sondern Geld, das aufs Etsy-Konto kommt. Es
erscheint deshalb als eigene positive Zeile und nie in der Gebuehrensumme.

## Woher die Zahlen kommen

Workflow 02 holt alle 6 Stunden das Etsy-Ledger (die Liste aller Buchungen des
Zahlungskontos) nach `etsy_transactions`. Die View `etsy_ledger_classified`
ordnet jede Buchung einer Zeilenart zu:

| `type` in `etsy_transactions` | Etsy (`ledger_type`) | Zeilenart |
|---|---|---|
| `sale` | PAYMENT_GROSS | Verkauf |
| `marketplace_tax` | vat_tax_ep, sales_tax | Verkauf (mindert ihn auf netto) |
| `refund` | REFUND | Verkauf (Erstattung, mindert ihn) |
| `fee_ads`, `fee_transaction`, `fee_processing`, `fee_listing` | offsite_ads_fee, transaction, PAYMENT_PROCESSING_FEE, listing, renew_sold_auto, renew_auto, auto_renew_expired | Gebuehr |
| `payout` | DISBURSE, DISBURSE2 | Auszahlung |
| `card_payment` | billing_payment | Kartenzahlung |
| `unknown` (und alles andere) | jeder andere Typ | unbekannt → **Export bricht ab** |

Wichtig dabei:

- **Unbekannte Etsy-Typen werden nicht geraten.** Fruehere Versionen von
  Workflow 02 haben sie als Transaktionsgebuehr (oder als Marktplatzsteuer, wenn
  „tax“ im Namen stand) gespeichert; so landete z.B. die Kartenzahlung in den
  Gebuehren. Jetzt speichert Workflow 02 sie als `unknown`, der Sync laeuft
  weiter, und der Export meldet die Buchung mit Etsy-Typ, Text und Betrag. Dann
  die Zuordnung in Workflow 02 (und bei Bedarf in der View) ergaenzen.
- **Monat in deutscher Zeit.** Der Monat einer Buchung wird aus dem Datum in
  Europe/Berlin bestimmt, nicht aus UTC und nicht aus der Spalte `month` (die in
  Altdaten abweichen konnte; der Export weist darauf hin).
- **Etsy-Rohdaten.** Workflow 02 speichert zusaetzlich Etsys Originaltyp
  (`ledger_type`), den Bezug (`reference_type`, `reference_id`), den Etsy-
  Kontostand nach jeder Buchung (`balance`) und Etsys Reihenfolge
  (`sequence_number`). Fuer Buchungen aus aelteren Versionen holt er sie beim
  ersten Lauf einmalig nach; dabei werden auch `type` und `month` neu aus den
  Etsy-Daten abgeleitet. Bis das passiert ist, verweigert der Export den Monat.

### Digital oder physisch?

Ob eine Bestellung digital ist, steht nur in `orders.items_json`. Etsy verweist
bei Verkaeufen (PAYMENT_GROSS) aber nicht auf die Bestellung, sondern auf die
Zahlung; nur VAT- und Ads-Buchungen tragen die Bestellnummer direkt. Workflow 02
fragt deshalb fuer jeden Verkauf ohne Bestellnummer die Zahlung bei Etsy ab
(`GET /v3/application/shops/{shop_id}/payment-account/ledger-entries/payments`)
und traegt deren `receipt_id` als `order_id` nach.

Solange das fuer eine Buchung nicht geklappt hat, zaehlt sie als digitaler
Verkauf, und der Pruefbericht warnt, zusaetzlich mit Hinweis auf physische
Bestellungen, denen kein Etsy-Verkauf zugeordnet ist. Ein faelschlich als
digital gezaehlter physischer Verkauf faellt ausserdem beim Abgleich mit der
Proformarechnung auf, die nur digitale Artikel enthaelt.

## Kontrollen – wann keine Datei entsteht

Eine Datei entsteht nur, wenn alles stimmt. Sonst nennt der Pruefbericht die
Gruende und zeigt die Zeilen, wie sie ohne die Fehler aussaehen.

- Der Monat ist abgeschlossen (deutsche Zeit) und liegt nicht vor
  `lexoffice.start_month`.
- Keine unbekannten Etsy-Typen, keine Fremdwaehrung, alle Buchungen mit
  Etsy-Rohdaten.
- **Erloeszeile = Proformarechnung:** Die digitalen Verkaeufe laut Etsy-Konto
  muessen genau dem Betrag der Proformarechnung des Monats aus Workflow 05
  entsprechen; deren Nummer steht im Verwendungszweck. Bei Abweichung listet der
  Bericht die Bestellungen, die nur auf einer Seite stehen.
- **Kontrollsumme:** Summe der Zeilen = Summe aller Etsy-Buchungen des Monats.
- **Vollstaendigkeit gegen Etsy:** Jede Buchung muss Etsys Kontostand der
  vorigen um genau ihren Betrag veraendern, und Kontostand Monatsende minus
  Monatsanfang muss der Monatssumme entsprechen. Sonst fehlt in der Datenbank
  eine Buchung. Weicht nur das Anfangsguthaben laut Datenbank von Etsys
  Kontostand ab (die Datenbank beginnt spaeter als das Etsy-Konto), ist das ein
  Hinweis, kein Fehler: in Lexoffice zaehlt der Anfangsbestand des Kontos.
- **Nachzuegler:** Taucht nachtraeglich eine Buchung fuer einen schon
  exportierten Monat auf, bricht der naechste Export ab.
- Jeder Verwendungszweck ist nicht leer, hoechstens 255 Zeichen lang und
  enthaelt weder Semikolon (Spaltentrenner) noch Zeilenumbruch. Die
  Gebuehrenaufschluesselung ist deshalb mit „+“ statt „;“ getrennt.

Hinweise (keine Fehler) gibt es z.B. fuer Verkaeufe ohne Bestellnummer,
Erstattungen, physische Bestellungen ohne Kundenrechnung oder mit abweichendem
Betrag und fuer noch nicht exportierte Vormonate.

## Einmal erzeugen, einmal importieren

Der Lexoffice-Import hat **keine Dublettenpruefung** und laesst sich **nicht
rueckgaengig machen**. Deshalb:

- `preview` (Standard beim Webhook) erzeugt nur Pruefbericht und Vorschau-Datei
  `…_VORSCHAU.csv` und schreibt nichts in die Datenbank.
- `create` speichert die Datei in `lexoffice_exports` (Inhalt, SHA-256,
  enthaltene Buchungen, Pruefbericht). Ein zweiter Aufruf liefert genau dieselbe
  Datei; haben sich die Daten inzwischen geaendert, steht das als Hinweis dabei.
- Neu erzeugt wird nur mit `"regenerate": true`, nur wenn sich wirklich etwas
  geaendert hat, und nur solange der Import nicht bestaetigt ist. Die neue Datei
  heisst `…_v2.csv`, die alte bleibt als ersetzt gespeichert.
- `confirm` nach dem Import: markiert die Datei als importiert und setzt
  `lexoffice_synced` fuer genau die enthaltenen Etsy-Buchungen. Danach wird der
  Monat nie mehr neu erzeugt; Korrekturen dann in Lexoffice per Berichtigung
  bzw. Storno.

## Format der Datei

UTF-8, Semikolon als Trenner, Kopfzeile `Datum;Betrag;Verwendungszweck`, Datum
`TT.MM.JJJJ`, Betrag mit Dezimalkomma ohne Tausenderpunkt, Abgaenge negativ,
Zeilenende CRLF, Verwendungszweck ohne Umlaute. Beim ersten Import legt man in
Lexoffice die Spaltenzuordnung einmal fest. Die Lexoffice-Vorschau dabei genau
pruefen: Zeilen ohne Verwendungszweck ignoriert Lexoffice, und einmal
festgeschriebene Buchungen lassen sich nur per Berichtigung aendern.

## Nicht automatisiert

- **Erstattungen ueber den Monat hinaus:** Wird ein schon abgerechneter
  digitaler Verkauf spaeter erstattet, passt die Erloeszeile nicht mehr zur
  Proformarechnung und der Export bricht ab. Dann braucht es eine Gutschrift
  bzw. ein Storno zur Proformarechnung (von Hand). Im selben Monat voll
  erstattete Bestellungen gleichen sich dagegen aus. Erstattet Etsy dabei auch
  Gebuehren, erscheint das zunaechst als unbekannter Typ.
- **Abgleich mit der Etsy-Gebuehrenrechnung:** Gebucht wird in Lexoffice der
  Rechnungsbetrag. Cent-Abweichungen zur Gebuehrensumme sind moeglich (z.B.
  Einstellgebuehren in USD, umgerechnet). Der Bericht zeigt die Summe; den
  Vergleich mit der Rechnung macht man von Hand.
- **Fremdwaehrungen:** nur EUR.

## Offene Punkte zum Klaeren (mit Steuerberater)

1. **Zuflusszeitpunkt:** Das Konzept nimmt an, dass bei der EUeR die Gutschrift
   aufs Etsy-Guthaben zaehlt, nicht erst die Auszahlung.
2. **Kartenzahlung an Etsy:** Ist die Karte in Lexoffice gefuehrt (dann
   Geldtransit) oder privat (dann Privateinlage, SKR03 1890)?
3. **Umstiegs-Stichtag (`LEXOFFICE_START_MONTH`):** Nur Monate exportieren, die
   PayJoe noch nicht nach Lexoffice gebracht hat, sonst entstehen
   Doppelbuchungen.
4. **Eine Proformarechnung je Monat** (statt je Verkauf), ihre Meldung in der
   UStVA und ggf. der Zusammenfassenden Meldung abstimmen. Dabei auch das
   Erloeskonto klaeren: Das Konzept nennt 8200; fuer sonstige Leistungen an
   Unternehmer im EU-Ausland, fuer die der Empfaenger die Steuer schuldet, gibt
   es in SKR03 ein eigenes Konto (8338), ueber das Lexoffice auch die Meldung
   steuert.
