# buschi-bookkeeping

Automatisierte Buchhaltung und Dokumentenerstellung für kleine Unternehmen, betrieben mit n8n und einer eigenen PDF-API.

## Komponenten

| Verzeichnis | Beschreibung |
|---|---|
| `bootstrap/` | Initialisiert Secrets (DB-Credentials) beim ersten Start |
| `postgres/` | PostgreSQL mit Schema für Bestellungen, Transaktionen, Rechnungen |
| `typst-api/` | FastAPI-Service zur PDF-Generierung via [Typst](https://typst.app) |
| `n8n/workflows/` | n8n-Workflow-JSONs (Etsy-Sync, Notion-Sync, Rechnungserstellung) |

## Installation

### Voraussetzungen

- Docker + Docker Compose
- Eine laufende n8n-Instanz im selben Docker-Netzwerk (`n8n-backend`)
- Eine Etsy-App (erstellt unter [etsy.com/developers](https://www.etsy.com/developers))

### 1. Docker-Netzwerk erstellen (falls noch nicht vorhanden)

```bash
docker network create n8n-backend
```

### 2. Infrastruktur starten

```bash
docker compose up -d
```

Beim ersten Start erzeugt der `bootstrap`-Container automatisch DB-Credentials und gibt sie einmalig in den Docker-Logs aus:

```bash
docker compose logs bootstrap
```

Die Ausgabe enthält DB-Name, Admin- und Worker-User mit Passwort sowie einen fertigen PostgreSQL Connection-String fuer n8n.

### 3. PostgreSQL-Credential in n8n anlegen

In n8n unter **Settings > Credentials > Add Credential > Postgres**:

- **Host:** `orderdb` (Container-Name im Docker-Netzwerk)
- **Port:** `5432`
- **Database:** `orderdb` (oder der Wert aus den Bootstrap-Logs)
- **User / Password:** Worker-Credentials aus den Bootstrap-Logs

Die Credential-ID (sichtbar in der URL, z.B. `/credentials/1`) muss in den Workflow-JSONs als Ersatz fuer `POSTGRES_CREDENTIAL_ID` eingetragen werden — oder die Credentials werden nach dem Import ueber die n8n-UI zugewiesen.

### 4. Etsy OAuth2-Credential in n8n anlegen

Etsy verlangt PKCE fuer OAuth2. In n8n unter **Settings > Credentials > Add Credential > OAuth2 API**:

| Feld | Wert |
|---|---|
| **Grant Type** | Authorization Code |
| **Authorization URL** | `https://www.etsy.com/oauth/connect` |
| **Access Token URL** | `https://api.etsy.com/v3/public/oauth/token` |
| **Client ID** | `keystring:shared_secret` (beides aus der Etsy-App, mit Doppelpunkt getrennt) |
| **Client Secret** | `shared_secret` |
| **Scope** | `transactions_r listings_r email_r` |
| **Authentication** | Body |
| **PKCE** | S256 |

Dann auf **Connect** klicken und bei Etsy autorisieren. Die Redirect-URI in der Etsy-App muss mit der in n8n angezeigten OAuth Redirect URL uebereinstimmen.

Die Credential-ID analog zu Postgres in den Workflow-JSONs als `ETSY_OAUTH2_CREDENTIAL_ID` eintragen, oder nach Import ueber die UI zuweisen.

### 5. App-Konfiguration in die Datenbank schreiben

Alle API-Keys und externen IDs liegen in der zentralen `app_config`-Tabelle (`scope`, `key`, `value`), nicht in `.env`:

```sql
INSERT INTO app_config (scope, key, value) VALUES
  ('etsy',   'api_key',     'deinKeystring:deinSharedSecret'),
  ('etsy',   'shop_id',     'deineShopId'),
  ('notion', 'database_id', 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')
ON CONFLICT (scope, key) DO UPDATE SET value = EXCLUDED.value;
```

Der Etsy `api_key` muss im Format `keystring:shared_secret` vorliegen (Etsy-Anforderung seit Februar 2026). Die Shop-ID findest du im Etsy Shop Manager in der URL (`shop_id=...`) oder ueber die API unter `GET /v3/application/users/me`. Die Notion `database_id` steht in der Notion-URL: `notion.so/<workspace>/<DATABASE_ID>?v=...`.

### 6. Workflows importieren

Die JSON-Dateien aus `n8n/workflows/` in n8n importieren:

| Workflow | Beschreibung |
|---|---|
| `01_etsy_orders_sync.json` | Synchronisiert Etsy-Bestellungen alle 15 Minuten |
| `02_etsy_transactions_sync.json` | Synchronisiert Etsy-Transaktionen (Gebuehren, Auszahlungen) alle 6 Stunden |
| `03_notion_sync.json` | Synchronisiert Bestellungen nach Notion |
| `04_generate_invoice_pdf.json` | Erzeugt Rechnungen und Lieferscheine als PDF |

Nach dem Import die Postgres- und OAuth2-Credentials in jedem Workflow zuweisen und die Workflows aktivieren.

## typst-api

REST-API zur Generierung von PDF-Dokumenten. Endpoints:

- `POST /invoice` – Rechnung (DIN A4)
- `POST /delivery-note` – Lieferschein (DIN A4)
- `POST /shipping-label` – Versandetikett (DIN A6)

Die Rechnungs- und Lieferschein-Templates basieren auf **[invoice-pro](https://github.com/leonieziechmann/invoice-pro)** von Leonie Ziechmann (MIT-Lizenz). Das Rechnungstemplate nutzt das Paket direkt (`@preview/invoice-pro:0.1.1`); der Lieferschein ist im gleichen visuellen Stil gehalten.

Die API ist intern unter `http://typst-api:8080` erreichbar. Swagger-Doku: `http://typst-api:8080/docs`.
