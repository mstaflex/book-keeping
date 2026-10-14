# Daten und Konfiguration im Betrieb

Dieses Dokument beschreibt, wo der Stack seinen Zustand ablegt, wie die
Konfiguration in die Datenbank kommt und was in welcher Situation mit Daten
und Konfiguration passiert. Die Schritt-fuer-Schritt-Anleitung steht in der
README (Schritte 2 und 5, „Updates einspielen“, „Datensicherung“).

## Was sich geaendert hat

| | Vorher | Jetzt |
|---|---|---|
| **Volumes** | Von Compose automatisch angelegt, Name `<projektname>_postgres_data` bzw. `<projektname>_secrets_data`. Ein anderer Projektname (z.B. nach einem Repo-Wechsel im Hosting-Panel) erzeugte neue, leere Volumes; `docker compose down -v` oder das Loeschen des Projekts im Panel loeschte die Daten. | Externe Volumes mit festen Namen `bookkeeping_pgdata` und `bookkeeping_secrets`, einmalig von Hand angelegt. Compose legt sie nie an und loescht sie nie. |
| **Konfiguration** | Einmalig per SQL von Hand in `app_config` eingetragen. Existierte nur in der Datenbank und ging mit ihr verloren. | Umgebungsvariablen des Compose-Projekts sind die Quelle. Der Container `app-config` schreibt sie bei jedem Start nach `app_config`. |

## Wo welcher Zustand liegt

| Zustand | Ort | Lebensdauer |
|---|---|---|
| Bestellungen, Transaktionen, Rechnungen, Nummernkreis, `app_config` | PostgreSQL im Volume `bookkeeping_pgdata` | Bis `docker volume rm bookkeeping_pgdata` |
| DB-Name, Admin- und Worker-Zugang | Dateien im Volume `bookkeeping_secrets`, geschrieben von `bootstrap` beim ersten Start | Bis `docker volume rm bookkeeping_secrets` |
| Instanz-Konfiguration (Etsy-API-Key, IDs, Verkaeufer- und Mail-Daten, Empfaenger der Etsy-Rechnung) | Umgebungsvariablen des Compose-Projekts (Hosting-Panel oder `.env` neben der `docker-compose.yml`); Kopie in `app_config` | Quelle bleibt beim Projekt; die Kopie wird bei jedem Start erneuert |
| Logins fuer Etsy (OAuth2), Notion, SMTP, Postgres | Credential-Speicher von n8n | Unabhaengig von diesem Stack |

`app_config` ist damit ein Abbild der Umgebungsvariablen. Einzige Ausnahme ist
`etsy.receipts_cursor`, den Workflow 01 selbst pflegt.

`ETSY_SYNC_START` (`etsy.sync_start`) legt nur den Startpunkt fuer den ersten
Abruf fest: Workflow 01 nutzt ihn, solange `etsy.receipts_cursor` fehlt,
Workflow 02, solange `etsy_transactions` leer ist. Eine spaetere Aenderung
holt allein nichts nach; dafuer die Startpunkte zuruecksetzen (README:
„Etsy-Daten neu abrufen“).

## Ablauf beim Start

1. **`bootstrap`** schreibt fehlende Secret-Dateien. Ist das Volume schon
   befuellt, ueberspringt es alles und beendet sich. `DB_*`-Variablen wirken
   deshalb nur beim allerersten Start.
2. **`postgres`** (Container `orderdb`) startet. Bei leerem Volume legt das
   Image die Datenbank an und fuehrt `01_schema.sql` und `02_worker_user.sh`
   aus.
3. **`config`** (Container `app-config`):
   1. wartet, bis die Datenbank TCP-Verbindungen annimmt (`pg_isready`);
   2. prueft, dass die Tabelle `app_config` existiert, sonst Abbruch mit
      Hinweis auf die Migrationen;
   3. schreibt jede gesetzte, nicht leere Variable als Upsert. Geaendert wird
      nur, wenn sich der Wert wirklich unterscheidet. Datumswerte
      (`ETSY_SYNC_START`, `ETSY_RC_START_DATE`) muessen `YYYY-MM-DD` sein,
      sonst werden sie mit Fehlermeldung uebersprungen;
   4. loggt die geaenderten Schluessel und die noch fehlenden Pflichtwerte.
      Werte selbst werden nie geloggt;
   5. bleibt im Leerlauf. Wegen `restart: unless-stopped` startet Docker ihn
      nach einem Server-Neustart wieder, und er schreibt die Werte erneut.
4. **`typst-api`** startet unabhaengig davon.

## Verhalten in typischen Situationen

| Situation | Daten | Konfiguration |
|---|---|---|
| Erster Start, Volumes nicht angelegt | Start bricht ab: `external volume "bookkeeping_..." not found` | – |
| Erster Start ohne Konfigurations-Variablen | Neue Datenbank, Passwoerter werden erzeugt | Nichts geschrieben; das Log nennt die fehlenden Werte |
| Variablen nachgetragen oder geaendert, dann `docker compose up -d` (Panel: Redeploy/Update) | Unveraendert | Container wird neu erstellt, neue Werte werden geschrieben |
| `docker compose restart` | Unveraendert | Bisherige Werte werden erneut geschrieben; **geaenderte Variablen kommen nicht an** (Docker liest die Umgebung nur beim Erstellen eines Containers) |
| Server-Neustart | Unveraendert | `app-config` wartet auf die Datenbank und schreibt die Werte erneut |
| `docker compose down` oder `down -v` | Bleiben erhalten | – |
| Projekt im Panel geloescht, anderer Projektname | Bleiben erhalten; ein neuer Stack findet dieselben Daten und Passwoerter | – |
| Variable geleert oder entfernt | – | Wert in der Datenbank bleibt unveraendert (loeschen nur per SQL oder Adminer) |
| Wert per SQL oder Adminer geaendert | – | Wird beim naechsten Start ueberschrieben, wenn die Variable gesetzt ist |
| `ETSY_SYNC_START` nach dem ersten Abruf geaendert | Nichts wird nachgeladen | Wert wird geschrieben, wirkt aber erst nach Zuruecksetzen der Startpunkte (README: „Etsy-Daten neu abrufen“) |
| Tabelle `app_config` fehlt (alte Datenbank ohne Migrationen) | – | Fehlermeldung im Log; Docker startet den Container mit wachsendem Abstand neu, bis die Migrationen gelaufen sind |
| `docker volume rm bookkeeping_pgdata` | **Endgueltig geloescht** | Wird nach Neuanlage beim naechsten Start wieder geschrieben |

## Namensschema der Variablen

`<SCOPE>_<KEY>` wird zu `(scope, key)` in Kleinbuchstaben:

| Praefix | Scope | Beispiel |
|---|---|---|
| `ETSY_RC_` | `etsy_rc` | `ETSY_RC_START_DATE` → `etsy_rc.start_date` |
| `ETSY_` | `etsy` | `ETSY_API_KEY` → `etsy.api_key` |
| `NOTION_` | `notion` | `NOTION_DATABASE_ID` → `notion.database_id` |
| `MAIL_` | `mail` | `MAIL_FROM` → `mail.from` |
| `SELLER_` | `seller` | `SELLER_VAT_ID` → `seller.vat_id` |

Im Container kommen nur Variablen an, die in `docker-compose.yml` beim Service
`config` aufgefuehrt sind. Eine Variable, die nur im Panel oder in der `.env`
steht, aber dort fehlt, wird ignoriert. Die vollstaendige Liste steht in der
README (Schritt 5) und in `.env.example`.

## Eine neue Variable einfuehren

1. In `docker-compose.yml` beim Service `config` unter `environment` ergaenzen,
   z.B. `SELLER_FAX: ${SELLER_FAX:-}`. Ein neuer Scope braucht zusaetzlich ein
   neues Praefix in `config-loader/apply-config.sh` (Filter und `case`).
2. In der README-Tabelle (Schritt 5) und in `.env.example` dokumentieren, dort
   nur mit Platzhalterwert.
3. Im Workflow aus `app_config` lesen und mit klarer Fehlermeldung abbrechen,
   wenn der Wert fehlt.
4. Ist der Wert Pflicht, die Pruefliste am Ende von `apply-config.sh`
   ergaenzen, damit das Log ihn als fehlend meldet.

## Sicherheit

- Der Loader verbindet sich mit dem Worker-User (nur Tabellenrechte), nicht
  mit dem Admin.
- Werte werden ueber psql-Variablen uebergeben und dadurch sicher gequotet;
  Apostrophe, Backslashes und Zeilenumbrueche sind unkritisch.
- Werte erscheinen nie im Log. Umgebungsvariablen sind aber fuer jeden mit
  Docker-Zugriff auf dem Server sichtbar (`docker inspect`), wie die
  Datenbank selbst.
- Die `.env` mit echten Werten gehoert nie ins Repository.

## Grenzen

- Die festen Volumes schuetzen vor versehentlichem Loeschen durch Compose oder
  das Panel, nicht vor einem Plattendefekt oder dem Verlust des Servers.
  Dagegen helfen nur Backups ausserhalb des Servers (README:
  „Datensicherung“).
- Datenbank-Dumps enthalten auch `app_config`, also den Etsy-API-Key.
  Backups entsprechend geschuetzt aufbewahren.

## Umstieg bestehender Installationen

Installationen von vor dieser Aenderung haben ihre Daten in
`<projektname>_postgres_data` und `<projektname>_secrets_data`. Vor dem ersten
Start mit der neuen `docker-compose.yml` die Daten in die festen Volumes
kopieren (README: „Updates einspielen“, Schritt 1), sonst startet der Stack mit
einer leeren Datenbank. Die bisher per SQL eingetragenen Werte bleiben dabei
erhalten; sie werden nur ueberschrieben, wenn die passende Variable gesetzt
ist.
