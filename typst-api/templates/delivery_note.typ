// ============================================================
//  Lieferschein · DIN A4 · DIN-5008-B
//  Gleicher Stil wie invoice.typ
// ============================================================
#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

// ── Seite ────────────────────────────────────────────────
#set page(
  paper:  "a4",
  margin: (top: 20mm, bottom: 22mm, left: 25mm, right: 20mm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.55em)

// ── Kopfzeile: feste Höhe, Logo per place() positioniert ──
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
    place(top + center, dy - 15pt, image(d.logo, height: 40mm))
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
    #text(size: 13pt, weight: "bold")[Lieferschein #d.delivery_number]
    #if d.order_id != none [
      #v(1pt)
      #text(size: 9pt, fill: luma(110))[Bestellung: #d.order_id]
    ]
  ],
  align(right + bottom, text(size: 9pt, fill: luma(90))[
    #if s.city != none { s.city + ", " }#d.date
  ]),
)
#v(4mm)

// ── Tabelle (1-basierte Positionsnummern) ─────────────────
#set table(stroke: none, inset: (x: 5pt, y: 3pt))

#table(
  columns: (2em, 1fr, 5em),
  table.hline(stroke: 0.5pt + luma(100)),
  table.cell(align: center, text(weight: "bold", size: 9pt)[Pos.]),
  table.cell(               text(weight: "bold", size: 9pt)[Artikel]),
  table.cell(align: center, text(weight: "bold", size: 9pt)[Menge]),
  table.hline(stroke: 0.5pt + luma(100)),
  ..d.items.enumerate().map(((idx, i)) => (
    table.cell(align: center)[#(idx + 1)],
    table.cell[#i.description],
    table.cell(align: center)[#i.quantity],
    table.hline(stroke: 0.3pt + luma(215)),
  )).flatten(),
)

// ── Versandinfo ──────────────────────────────────────────
#if d.tracking_number != none or d.carrier != none [
  #v(1em)
  #block(fill: luma(247), inset: (x: 10pt, y: 8pt), radius: 3pt, width: 100%)[
    #set text(size: 9pt)
    #if d.carrier != none [*Versanddienstleister:* #d.carrier \ ]
    #if d.tracking_number != none [
      *Sendungsnummer:* #text(font: "Liberation Mono")[#d.tracking_number]
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

#v(2em)

// ── Unterschrift ─────────────────────────────────────────
// #grid(
//   columns: (1fr, 1fr),
//   gutter: 2em,
//   [
//     #line(length: 80%, stroke: 0.4pt + luma(160))
//     #v(2pt)
//     #text(size: 8pt, fill: luma(140))[Datum / Unterschrift Absender]
//   ],
//   [
//     #line(length: 80%, stroke: 0.4pt + luma(160))
//     #v(2pt)
//     #text(size: 8pt, fill: luma(140))[Datum / Unterschrift Empfänger (optional)]
//   ],
// )

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
