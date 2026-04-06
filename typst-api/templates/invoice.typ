// ============================================================
//  Rechnung · DIN A4
// ============================================================
#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

// ── Hilfsfunktionen ─────────────────────────────────────────
#let eur(n) = {
  let cents = calc.round(float(n) * 100)
  let e = int(cents / 100)
  let c = int(calc.rem(calc.abs(cents), 100))
  let cs = if c < 10 { "0" + str(c) } else { str(c) }
  str(e) + "," + cs + " €"
}

#let addr-line(v) = if v != none and v != "" { v + linebreak() }

// ── Seite ───────────────────────────────────────────────────
#set page(
  paper:  "a4",
  margin: (top: 2.7cm, bottom: 2.5cm, left: 2.5cm, right: 2cm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.55em)

// Akzentfarbe
#let accent = rgb("#2563eb")

// ── Kopfzeile ───────────────────────────────────────────────
#grid(
  columns: (1fr, auto),
  gutter: 1em,
  // Links: Firmenname groß
  align(left)[
    #text(size: 18pt, weight: "bold", fill: accent)[
      #if s.business_name != none { s.business_name } else { s.name }
    ]
  ],
  // Rechts: Absenderblock klein
  align(right, text(size: 8.5pt, fill: luma(80))[
    #s.name \
    #addr-line(s.street)#addr-line(s.zip + " " + s.city)#addr-line(s.country)
    #if s.email != none { s.email + linebreak() }
    #if s.phone != none { s.phone }
  ]),
)

#line(length: 100%, stroke: 0.5pt + accent)
#v(0.8em)

// ── Adressfenster (DIN 5008B – Empfänger) ───────────────────
#box(
  width:  85mm,
  height: 45mm,
  inset:  (x: 0pt, y: 4pt),
)[
  // Rücksendeadresse winzig
  #text(size: 7pt, fill: luma(120))[
    #if s.business_name != none { s.business_name } else { s.name } ·
    #s.street · #s.zip #s.city
  ]
  #v(0.4em)
  // Empfänger
  #text(size: 10pt)[
    *#b.name* \
    #addr-line(b.street)#addr-line(b.zip + " " + b.city)#addr-line(b.country)
  ]
]

// Rechts davon: Rechnungs-Metadaten
#place(
  top + right,
  dy: -40mm,
)[
  #align(right)[
    #text(size: 14pt, weight: "bold")[RECHNUNG]
    #v(0.4em)
    #grid(
      columns: (auto, auto),
      gutter: (0.6em, 0.3em),
      align(right, text(fill: luma(100))[Rechnungsnr.:]),
      align(left)[*#d.invoice_number*],
      align(right, text(fill: luma(100))[Datum:]),
      align(left)[#d.invoice_date],
      align(right, text(fill: luma(100))[Bestellung:]),
      align(left, text(fill: luma(80))[#if d.order_id != none { d.order_id } else { "–" }]),
    )
  ]
]

#v(4.5em)

// ── Artikeltabelle ──────────────────────────────────────────
#set table(
  stroke:      none,
  inset:       (x: 6pt, y: 5pt),
  fill:        (_, row) => if row == 0 { accent } else if calc.odd(row) { luma(248) } else { white },
)
#set table.header(repeat: true)

#table(
  columns: (2em, 1fr, 4em, 5em, 5em),
  table.header(
    table.cell(text(fill: white, weight: "bold")[Pos.]),
    table.cell(text(fill: white, weight: "bold")[Beschreibung]),
    table.cell(align: center, text(fill: white, weight: "bold")[Menge]),
    table.cell(align: right,  text(fill: white, weight: "bold")[Einzelpreis]),
    table.cell(align: right,  text(fill: white, weight: "bold")[Gesamt]),
  ),
  ..d.items.map(item => (
    table.cell(align: center)[#item.pos],
    table.cell[#item.description],
    table.cell(align: center)[#item.quantity],
    table.cell(align: right)[#eur(item.unit_price)],
    table.cell(align: right)[#eur(item.total)],
  )).flatten(),
)

#v(0.8em)

// ── Summenblock ─────────────────────────────────────────────
#align(right)[
  #box(width: 10cm)[
    #set text(size: 10pt)
    #grid(
      columns: (1fr, auto),
      gutter: (0pt, 5pt),
      text(fill: luma(80))[Zwischensumme:],  align(right)[#eur(d.subtotal)],
      text(fill: luma(80))[Versandkosten:],  align(right)[#eur(d.shipping_cost)],
    )
    #line(length: 100%, stroke: 0.5pt + luma(200))
    #v(2pt)
    #grid(
      columns: (1fr, auto),
      text(weight: "bold", size: 11pt)[Gesamtbetrag:],
      align(right, text(weight: "bold", size: 11pt)[#eur(d.total)]),
    )
  ]
]

#v(1.5em)

// ── Zahlungshinweis ─────────────────────────────────────────
#box(
  fill:    luma(245),
  inset:   10pt,
  radius:  4pt,
  width:   100%,
)[
  #text(fill: luma(80))[*Zahlungsstatus:*] #d.payment_note
  #if s.iban != none and d.payment_note.contains("bereits") == false [
    \ IBAN: *#s.iban*#if s.bank_name != none { " (" + s.bank_name + ")" }
  ]
]

// ── Steuerhinweis ───────────────────────────────────────────
#if s.kleinunternehmer [
  #v(1em)
  #text(size: 8.5pt, fill: luma(100))[
    Gemäß §19 UStG wird keine Umsatzsteuer berechnet.
    #if s.tax_id != none { " · Steuernummer: " + s.tax_id }
  ]
]

// ── Fußzeile ────────────────────────────────────────────────
#place(bottom + center)[
  #line(length: 100%, stroke: 0.5pt + luma(200))
  #v(4pt)
  #text(size: 8pt, fill: luma(120))[
    #if s.business_name != none { s.business_name + " · " }
    #s.name · #s.street · #s.zip #s.city
    #if s.email != none { " · " + s.email }
    #if s.website != none { " · " + s.website }
  ]
]
