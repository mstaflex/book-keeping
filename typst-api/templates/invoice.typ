// ============================================================
//  Rechnung · DIN A4 · DIN-5008-B
//  Inspiriert von @preview/invoice-pro
//  https://github.com/leonieziechmann/invoice-pro
// ============================================================
#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

// ── Hilfsfunktionen ──────────────────────────────────────
#let eur(n) = {
  let cents = int(calc.round(float(n) * 100))
  let neg   = cents < 0
  let abs-c = if neg { -cents } else { cents }
  let c     = calc.rem(abs-c, 100)
  let e     = int(abs-c / 100)
  let cs    = if c < 10 { "0" + str(c) } else { str(c) }
  (if neg { "−" } else { "" }) + str(e) + "," + cs + "\u{202f}€"
}
#let pct(r) = str(int(calc.round(r * 100))) + "\u{202f}%"

// ── Seite ────────────────────────────────────────────────
#set page(
  paper:  "a4",
  margin: (top: 20mm, bottom: 22mm, left: 25mm, right: 20mm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.55em)

// ── Kopfzeile: feste Höhe, Logo per place() positioniert ──
// Das Logo wird absolut platziert und verschiebt keinen Inhalt.
#block(width: 100%, height: 30mm)[
  #place(top + left)[
    #text(size: 17pt, weight: "bold")[
      #if s.business_name != none { s.business_name } else { s.name }
    ]
    #if s.tagline != none [
      \ #text(size: 8.5pt, fill: luma(120))[#s.tagline]
    ]
  ]
  #place(top + right)[
    #text(size: 8pt, fill: luma(80))[
      *#(if s.business_name != none { s.business_name } else { s.name })* \
      #if s.street  != none { s.street  + linebreak() }
      #if s.zip     != none { s.zip + " " }#if s.city != none { s.city + linebreak() }
      #if s.email   != none { s.email   + linebreak() }
      #if s.phone   != none { s.phone   + linebreak() }
      #if s.website != none { s.website }
    ]
  ]
  #if d.logo != none {
    place(top + center, dy: -15pt, image(d.logo, height: 40mm))
  }
]

#v(2mm)
// #line(length: 100%, stroke: 0.4pt + luma(180))
#v(5mm)

// ── Miniabsender + Adressfenster (DIN-5008-B) ────────────
#text(size: 7pt, fill: luma(150))[
  #(if s.business_name != none { s.business_name } else { s.name }) ·
  #if s.street != none { s.street } ·
  #if s.zip    != none { s.zip }#if s.city != none { " " + s.city }
]
#v(1mm)
#text(size: 10pt)[
  *#b.name* \
  #if b.street  != none { b.street  + linebreak() }
  #if b.zip     != none { b.zip + " " }#if b.city    != none { b.city    + linebreak() }
  #if b.country != none { b.country }
]

// ── Betreff + Datum ───────────────────────────────────────
#v(8mm)
#grid(
  columns: (1fr, auto),
  align(left)[
    #text(size: 13pt, weight: "bold")[Rechnung #d.invoice_number]
    #if d.order_id != none [
      #v(1pt)
      #text(size: 9pt, fill: luma(110))[Bestellung: #d.order_id]
    ]
  ],
  align(right + bottom, text(size: 9pt, fill: luma(90))[
    #if s.city != none { s.city + ", " }#d.invoice_date
    #if s.tax_id != none [ \ USt-IdNr. #s.tax_id ]
  ]),
)
#v(4mm)

// ── Tabelle ───────────────────────────────────────────────
#let show-vat = (not s.kleinunternehmer) and d.items.any(i => i.vat_rate > 0)
#let ship-vat = if s.kleinunternehmer { 0.0 } else { 0.19 }
#let cols = if show-vat { (2.5em, 1fr, 4.5em, 5em, 3em, 5em) } else { (2em, 1fr, 3.5em, 5em, 5em) }

// Tabellenzeilen aufbauen (1-basierte Positionsnummern)
#let shipping-row = if d.shipping_cost > 0 {(
  table.cell(align: center)[–],
  table.cell[Versandkosten],
  table.cell(align: center)[1],
  table.cell(align: right)[#eur(d.shipping_cost)],
  ..if show-vat { (table.cell(align: center, text(size: 9pt, fill: luma(110))[#pct(ship-vat)]),) } else { () },
  table.cell(align: right)[#eur(d.shipping_cost)],
)} else { () }

#set table(stroke: none, inset: (x: 5pt, y: 3pt))

#table(
  columns: cols,
  // Header
  table.hline(stroke: 0.5pt + luma(100)),
  table.cell(align: center,  text(weight: "bold", size: 9pt)[Pos.]),
  table.cell(                text(weight: "bold", size: 9pt)[Beschreibung]),
  table.cell(align: center,  text(weight: "bold", size: 9pt)[Menge]),
  table.cell(align: right,   text(weight: "bold", size: 9pt)[Einzelpreis]),
  ..if show-vat { (table.cell(align: center, text(weight: "bold", size: 9pt)[MwSt.]),) } else { () },
  table.cell(align: right,   text(weight: "bold", size: 9pt)[Gesamt]),
  table.hline(stroke: 0.5pt + luma(100)),
  // Datenzeilen
  ..d.items.enumerate().map(((idx, i)) => (
    table.cell(align: center)[#(idx + 1)],
    table.cell[#i.description],
    table.cell(align: center)[#i.quantity],
    table.cell(align: right)[#eur(i.unit_price)],
    ..if show-vat { (table.cell(align: center, text(size: 9pt, fill: luma(110))[#pct(i.vat_rate)]),) } else { () },
    table.cell(align: right)[#eur(i.total)],
    table.hline(stroke: 0.3pt + luma(215)),
  )).flatten(),
  ..shipping-row,
  ..if d.shipping_cost > 0 { (table.hline(stroke: 0.3pt + luma(215)),) } else { () },
)

// ── MwSt-Gruppen & Gesamtbetrag ──────────────────────────
#let vat-groups = {
  let g = (:)
  if not s.kleinunternehmer {
    for i in d.items {
      if i.vat_rate > 0 {
        let k = pct(i.vat_rate)
        g.insert(k, g.at(k, default: 0.0) + i.total * i.vat_rate)
      }
    }
    if d.shipping_cost > 0 and ship-vat > 0 {
      let k = pct(ship-vat)
      g.insert(k, g.at(k, default: 0.0) + d.shipping_cost * ship-vat)
    }
  }
  g
}
#let total-vat   = vat-groups.values().fold(0.0, (a, b) => a + b)
#let gross-total = d.subtotal + d.shipping_cost + total-vat

// ── Summenblock ───────────────────────────────────────────
#v(2mm)
#align(right)[
  #box(width: 8.5cm)[
    #set text(size: 9.5pt)
    #let sum-row(label, amount) = grid(
      columns: (1fr, 5.5em), column-gutter: 6mm,
      text(fill: luma(90))[#label], align(right)[#amount],
    )
    #sum-row([Nettosumme:], eur(d.subtotal))
    #if d.shipping_cost > 0 { v(2pt); sum-row([Versandkosten:], eur(d.shipping_cost)) }
    #for p in vat-groups.pairs() { v(2pt); sum-row([#p.at(0) Mehrwertsteuer:], eur(p.at(1))) }
    #v(4pt)
    #line(length: 100%, stroke: 0.5pt + luma(130))
    #v(3pt)
    #grid(
      columns: (1fr, 5.5em), column-gutter: 6mm,
      text(weight: "bold", size: 10.5pt)[Gesamtbetrag:],
      align(right, text(weight: "bold", size: 10.5pt)[#eur(gross-total)]),
    )
  ]
]

#v(1.2em)

// ── Zahlungshinweis ───────────────────────────────────────
#text(fill: luma(90))[*Zahlungsstatus:*] #d.payment_note

// ── §19-Hinweis ───────────────────────────────────────────
#if s.kleinunternehmer [
  #v(0.6em)
  #text(size: 8.5pt, fill: luma(130))[
    Gemäß §19 UStG wird keine Umsatzsteuer berechnet.#if s.tax_id != none { " · Steuernummer: " + s.tax_id }
  ]
]

// ── Bankverbindung ────────────────────────────────────────
#if s.iban != none [
  #v(1em)
  #block(fill: luma(247), inset: (x: 10pt, y: 8pt), radius: 3pt, width: 100%)[
    #text(size: 8.5pt, fill: luma(90))[*Bankverbindung*] \
    #v(2pt)
    #text(size: 9pt)[
      Kontoinhaber: #(if s.business_name != none { s.business_name } else { s.name }) \
      #if s.bank_name != none [Bank: #s.bank_name \ ]
      IBAN: #text(font: "Liberation Mono")[#s.iban]
    ]
  ]
]

// ── Persönlicher Gruß ─────────────────────────────────────
#if d.note != none [
  #v(1em)
  #block(stroke: 0.4pt + luma(200), inset: (x: 10pt, y: 8pt), radius: 3pt, width: 100%)[
    #text(size: 9.5pt)[#d.note]
  ]
]

// ── Fußzeile ─────────────────────────────────────────────
#place(bottom + center)[
  #line(length: 100%, stroke: 0.4pt + luma(190))
  #v(3pt)
  #text(size: 7.5pt, fill: luma(150))[
    #(if s.business_name != none { s.business_name + " · " } else { "" }
    )#s.name#if s.street != none { " · " + s.street
    }#if s.zip != none { " · " + s.zip }#if s.city != none { " " + s.city
    }#if s.email != none { " · " + s.email }#if s.website != none { " · " + s.website }
  ]
]
