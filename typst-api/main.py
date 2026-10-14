"""
Typst PDF API
Endpoints: POST /invoice · POST /delivery-note · POST /shipping-label
Gibt jeweils application/pdf zurück – direkt in n8n als Binary nutzbar.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, ConfigDict, model_validator

TEMPLATES_DIR = Path(__file__).parent / "templates"
ASSETS_DIR    = Path(__file__).parent / "assets"
TYPST_BIN     = shutil.which("typst") or "typst"

# Fähigkeiten, die Workflows vor dem Rendern prüfen können (z.B. Workflow 05)
FEATURES = ["discount", "reverse_charge"]

# Fingerabdruck der eingebauten Templates. Templates werden ins Image kopiert –
# nach Änderungen muss neu gebaut werden (docker compose up -d --build typst-api).
# Über GET /health lässt sich so prüfen, welcher Stand tatsächlich läuft.
TEMPLATES_SHA = hashlib.sha256(
    b"".join(p.name.encode() + p.read_bytes() for p in sorted(TEMPLATES_DIR.glob("*.typ")))
).hexdigest()[:12]

app = FastAPI(title="Typst PDF API", version="1.0.0")


# ---------------------------------------------------------------------------
# Shared data models
# ---------------------------------------------------------------------------

class Model(BaseModel):
    # Unbekannte Felder ablehnen statt still zu verwerfen: schickt ein neuerer
    # Workflow Felder an ein veraltetes Image, gibt es einen 422 statt eines
    # PDFs, dem z.B. der Rabatt oder der Reverse-Charge-Vermerk fehlt.
    model_config = ConfigDict(extra="forbid")


class Address(Model):
    name:    str
    street:  Optional[str] = None
    zip:     Optional[str] = None
    city:    Optional[str] = None
    country: Optional[str] = None
    vat_id:  Optional[str] = None                # USt-IdNr (z.B. "DE123456789"), falls vorhanden


class Seller(Address):
    business_name: Optional[str] = None
    tagline:       Optional[str] = None          # z.B. "Schöne Dinge aus Berlin"
    email:         Optional[str] = None
    phone:         Optional[str] = None
    website:       Optional[str] = None
    iban:          Optional[str] = None
    bank_name:     Optional[str] = None
    # Steuer
    tax_id:        Optional[str] = None          # Steuernummer (z.B. "123/456/78901")
    kleinunternehmer: bool = True                # §19 UStG → keine MwSt


class LineItem(Model):
    pos:         int
    description: str
    quantity:    float
    unit_price:  float
    total:       float
    vat_rate:    float = 0.0                     # z.B. 0.19 für 19% MwSt


# ---------------------------------------------------------------------------
# Request bodies
# ---------------------------------------------------------------------------

class InvoiceRequest(Model):
    invoice_number: str
    invoice_date:   str                          # "06.04.2026"
    order_id:       Optional[str] = None
    seller:         Seller
    buyer:          Address
    items:          list[LineItem]
    subtotal:       float                        # Warenwert nach Rabatt, ohne Versand
    shipping_cost:  float
    discount:       float = 0.0                  # Rabatt (Gutschein), positiv angeben
    total:          float
    currency:       str = "EUR"
    payment_note:   Optional[str] = "Bereits bezahlt via Etsy Payments"
    note:           Optional[str] = None         # persönlicher Gruß / Hinweis
    # B2B-Leistung ins EU-Ausland (z.B. an Etsy Ireland): keine USt,
    # Steuerschuldnerschaft des Leistungsempfängers
    reverse_charge: bool = False
    service_period: Optional[str] = None         # "01.09.2026 – 30.09.2026"

    @model_validator(mode="after")
    def _reverse_charge_needs_vat_ids(self):
        # §14a Abs. 1 UStG: USt-IdNr. von Leistendem und Empfänger sind Pflicht
        if self.reverse_charge and not (self.seller.vat_id and self.buyer.vat_id):
            raise ValueError("reverse_charge erfordert seller.vat_id und buyer.vat_id")
        return self


class DeliveryNoteRequest(Model):
    delivery_number: str
    date:            str
    order_id:        Optional[str] = None
    seller:          Seller
    buyer:           Address
    items:           list[LineItem]
    tracking_number: Optional[str] = None
    carrier:         Optional[str] = None
    note:            Optional[str] = None        # persönlicher Gruß / Hinweis


class ShippingLabelRequest(Model):
    sender:          Address
    recipient:       Address
    tracking_number: Optional[str] = None
    carrier:         Optional[str] = None
    weight:          Optional[str] = None
    service:         Optional[str] = None        # z.B. "Päckchen M"


# ---------------------------------------------------------------------------
# Typst compile helper
# ---------------------------------------------------------------------------

def compile_pdf(template_name: str, data: dict) -> bytes:
    """
    Schreibt data.json in ein tmpdir, kopiert das Template dorthin,
    kompiliert mit Typst und gibt die rohen PDF-Bytes zurück.
    """
    template_src = TEMPLATES_DIR / f"{template_name}.typ"
    if not template_src.exists():
        raise HTTPException(500, detail=f"Template '{template_name}.typ' nicht gefunden")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        # Logo kopieren falls vorhanden, Pfad in data eintragen
        logo_src = next(ASSETS_DIR.glob("logo.*"), None) if ASSETS_DIR.exists() else None
        if logo_src:
            shutil.copy(logo_src, tmp / logo_src.name)
            data = {**data, "logo": logo_src.name}
        else:
            data = {**data, "logo": None}

        # Daten als JSON schreiben
        (tmp / "data.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

        # Template kopieren (+ alle .typ-Hilfsdateien)
        for typ_file in TEMPLATES_DIR.glob("*.typ"):
            shutil.copy(typ_file, tmp / typ_file.name)

        out_pdf = tmp / "output.pdf"

        result = subprocess.run(
            [
                TYPST_BIN, "compile",
                "--font-path", "/usr/share/fonts",
                str(tmp / f"{template_name}.typ"),
                str(out_pdf),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            raise HTTPException(
                500,
                detail=f"Typst Fehler:\n{result.stderr}",
            )

        return out_pdf.read_bytes()


def pdf_response(pdf_bytes: bytes, filename: str) -> Response:
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
def health():
    return {"status": "ok", "typst": TYPST_BIN, "templates_sha": TEMPLATES_SHA, "features": FEATURES}


@app.post("/invoice", summary="Rechnung als PDF")
def generate_invoice(req: InvoiceRequest):
    pdf = compile_pdf("invoice", req.model_dump())
    filename = f"Rechnung_{req.invoice_number.replace('/', '-')}.pdf"
    return pdf_response(pdf, filename)


@app.post("/delivery-note", summary="Lieferschein als PDF")
def generate_delivery_note(req: DeliveryNoteRequest):
    pdf = compile_pdf("delivery_note", req.model_dump())
    filename = f"Lieferschein_{req.delivery_number.replace('/', '-')}.pdf"
    return pdf_response(pdf, filename)


@app.post("/shipping-label", summary="Versandetikett als PDF")
def generate_shipping_label(req: ShippingLabelRequest):
    pdf = compile_pdf("shipping_label", req.model_dump())
    tracking = req.tracking_number or "label"
    return pdf_response(pdf, f"Versandetikett_{tracking}.pdf")
