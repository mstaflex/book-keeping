"""
Typst PDF API
Endpoints: POST /invoice · POST /delivery-note · POST /shipping-label
Gibt jeweils application/pdf zurück – direkt in n8n als Binary nutzbar.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

TEMPLATES_DIR = Path(__file__).parent / "templates"
TYPST_BIN     = shutil.which("typst") or "typst"

app = FastAPI(title="Typst PDF API", version="1.0.0")


# ---------------------------------------------------------------------------
# Shared data models
# ---------------------------------------------------------------------------

class Address(BaseModel):
    name:    str
    street:  Optional[str] = None
    zip:     Optional[str] = None
    city:    Optional[str] = None
    country: Optional[str] = None


class Seller(Address):
    business_name: Optional[str] = None
    email:         Optional[str] = None
    phone:         Optional[str] = None
    website:       Optional[str] = None
    iban:          Optional[str] = None
    bank_name:     Optional[str] = None
    # Steuer
    tax_id:        Optional[str] = None          # USt-IdNr oder Steuernummer
    kleinunternehmer: bool = True                # §19 UStG → keine MwSt


class LineItem(BaseModel):
    pos:         int
    description: str
    quantity:    float
    unit_price:  float
    total:       float


# ---------------------------------------------------------------------------
# Request bodies
# ---------------------------------------------------------------------------

class InvoiceRequest(BaseModel):
    invoice_number: str
    invoice_date:   str                          # "06.04.2026"
    order_id:       Optional[str] = None
    seller:         Seller
    buyer:          Address
    items:          list[LineItem]
    subtotal:       float
    shipping_cost:  float
    total:          float
    currency:       str = "EUR"
    payment_note:   str = "Bereits bezahlt via Etsy Payments"


class DeliveryNoteRequest(BaseModel):
    delivery_number: str
    date:            str
    order_id:        Optional[str] = None
    seller:          Seller
    buyer:           Address
    items:           list[LineItem]
    tracking_number: Optional[str] = None
    carrier:         Optional[str] = None


class ShippingLabelRequest(BaseModel):
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
    return {"status": "ok", "typst": TYPST_BIN}


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
