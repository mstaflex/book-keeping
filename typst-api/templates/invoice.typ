// ============================================================
//  Rechnung · DIN A4 · DIN-5008-B
//  Basiert auf @preview/invoice-pro:0.1.1
//  https://github.com/leonieziechmann/invoice-pro
// ============================================================
#import "@preview/invoice-pro:0.1.1": invoice, item, invoice-line-items

#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

// ── Datum parsen "DD.MM.YYYY" ─────────────────────────────
#let dp = d.invoice_date.split(".")
#let inv-date = datetime(
  day:   int(dp.at(0)),
  month: int(dp.at(1)),
  year:  int(dp.at(2)),
)

// ── Absender-Zusatzinfo ───────────────────────────────────
#let sender-extra = {
  let extra = (:)
  if s.email   != none { extra.insert("E-Mail", [#s.email])   }
  if s.phone   != none { extra.insert("Tel",    [#s.phone])   }
  if s.website != none { extra.insert("Web",    [#s.website]) }
  extra
}

// ── Positionen inkl. optionale Versandkosten ─────────────
#let all-items = {
  let items = d.items.map(i => item(
    [#i.description],
    quantity: i.quantity,
    price:    i.unit_price,
    vat:      0.0,
  ))
  if d.shipping_cost > 0 {
    items + (item([Versandkosten], quantity: 1, price: d.shipping_cost, vat: 0.0),)
  } else {
    items
  }
}

// ── Dokument ──────────────────────────────────────────────
#set text(font: "Liberation Sans", lang: "de")

#show: invoice.with(
  format:               "DIN-5008-B",
  vat-exempt-small-biz: s.kleinunternehmer,
  sender: (
    name:    if s.business_name != none { s.business_name } else { s.name },
    address: if s.street        != none { s.street        } else { "" },
    city:    (if s.zip  != none { s.zip  } else { "" }) + " " +
             (if s.city != none { s.city } else { "" }),
    extra:   sender-extra,
  ),
  recipient: (
    name:    b.name,
    address: if b.street != none { b.street } else { "" },
    city:    (if b.zip  != none { b.zip  } else { "" }) + " " +
             (if b.city != none { b.city } else { "" }),
  ),
  invoice-nr: d.invoice_number,
  date:       inv-date,
  tax-nr:     s.tax_id,
)

#if d.order_id != none [
  Ihre Bestellung: *#d.order_id*
  #v(0.5em)
]

#invoice-line-items(..all-items)

#v(1em)
#block[#d.payment_note]

#if s.iban != none [
  #v(1.5em)
  #block(fill: luma(245), inset: 10pt, radius: 4pt, width: 100%)[
    #text(size: 9pt, fill: luma(80))[*Bankverbindung*] \
    #v(0.3em)
    #text(size: 9pt)[
      Kontoinhaber: #if s.business_name != none { s.business_name } else { s.name } \
      #if s.bank_name != none [Bank: #s.bank_name \ ]
      IBAN: #text(font: "Liberation Mono")[#s.iban]
    ]
  ]
]
