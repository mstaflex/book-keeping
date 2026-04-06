# buschi-bookkeeping

Automatisierte Buchhaltung und Dokumentenerstellung für kleine Unternehmen, betrieben mit n8n und einer eigenen PDF-API.

## Komponenten

| Verzeichnis | Beschreibung |
|---|---|
| `typst-api/` | FastAPI-Service zur PDF-Generierung via [Typst](https://typst.app) |
| `n8n/` | n8n-Workflows und Konfiguration |
| `postgres/` | PostgreSQL-Daten |

## typst-api

REST-API zur Generierung von PDF-Dokumenten. Endpoints:

- `POST /invoice` – Rechnung (DIN A4)
- `POST /delivery-note` – Lieferschein (DIN A4)
- `POST /shipping-label` – Versandetikett (DIN A6)

Die Rechnungs- und Lieferschein-Templates basieren auf **[invoice-pro](https://github.com/leonieziechmann/invoice-pro)** von Leonie Ziechmann (MIT-Lizenz). Das Rechnungstemplate nutzt das Paket direkt (`@preview/invoice-pro:0.1.1`); der Lieferschein ist im gleichen visuellen Stil gehalten.

### Starten

```bash
docker compose up -d
```

Die API ist unter `http://localhost:8080` erreichbar. Swagger-Doku: `http://localhost:8080/docs`.
