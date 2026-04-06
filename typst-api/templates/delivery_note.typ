// ============================================================
//  Lieferschein · DIN A4
// ============================================================
#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

#let addr-line(v) = if v != none and v != "" { v + linebreak() }

#set page(
  paper:  "a4",
  margin: (top: 2.7cm, bottom: 2.5cm, left: 2.5cm, right: 2cm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.55em)

#let accent = rgb("#16a34a")

// ── Kopfzeile ───────────────────────────────────────────────
#grid(
  columns: (1fr, auto),
  gutter: 1em,
  align(left)[
    #text(size: 18pt, weight: "bold", fill: accent)[
      #if s.business_name != none { s.business_name } else { s.name }
    ]
  ],
  align(right, text(size: 8.5pt, fill: luma(80))[
    #s.name \
    #addr-line(s.street)#addr-line(s.zip + " " + s.city)#addr-line(s.country)
    #if s.email != none { s.email }
  ]),
)

#line(length: 100%, stroke: 0.5pt + accent)
#v(0.8em)

// ── Adressfenster ───────────────────────────────────────────
#box(width: 85mm, height: 45mm, inset: (x: 0pt, y: 4pt))[
  #text(size: 7pt, fill: luma(120))[
    #if s.business_name != none { s.business_name } else { s.name } ·
    #s.street · #s.zip #s.city
  ]
  #v(0.4em)
  #text(size: 10pt)[
    *#b.name* \
    #addr-line(b.street)#addr-line(b.zip + " " + b.city)#addr-line(b.country)
  ]
]

#place(top + right, dy: -40mm)[
  #align(right)[
    #text(size: 14pt, weight: "bold")[LIEFERSCHEIN]
    #v(0.4em)
    #grid(
      columns: (auto, auto),
      gutter: (0.6em, 0.3em),
      align(right, text(fill: luma(100))[Lieferschein-Nr.:]), align(left)[*#d.delivery_number*],
      align(right, text(fill: luma(100))[Datum:]),            align(left)[#d.date],
      align(right, text(fill: luma(100))[Bestellung:]),
      align(left, text(fill: luma(80))[#if d.order_id != none { d.order_id } else { "–" }]),
    )
  ]
]

#v(4.5em)

// ── Artikeltabelle (ohne Preise) ─────────────────────────────
#set table(
  stroke:  none,
  inset:   (x: 6pt, y: 5pt),
  fill:    (_, row) => if row == 0 { accent } else if calc.odd(row) { luma(248) } else { white },
)

#table(
  columns: (2em, 1fr, 5em),
  table.header(
    table.cell(text(fill: white, weight: "bold")[Pos.]),
    table.cell(text(fill: white, weight: "bold")[Artikel]),
    table.cell(align: center, text(fill: white, weight: "bold")[Menge]),
  ),
  ..d.items.map(item => (
    table.cell(align: center)[#item.pos],
    table.cell[#item.description],
    table.cell(align: center)[#item.quantity],
  )).flatten(),
)

// ── Versandinfo ─────────────────────────────────────────────
#if d.tracking_number != none or d.carrier != none [
  #v(1.5em)
  #box(fill: luma(245), inset: 10pt, radius: 4pt, width: 100%)[
    #grid(
      columns: (auto, 1fr),
      gutter: (0.8em, 0.4em),
      ..{
        let rows = ()
        if d.carrier != none {
          rows = rows + (text(fill: luma(80))[*Versanddienstleister:*], [#d.carrier])
        }
        if d.tracking_number != none {
          rows = rows + (text(fill: luma(80))[*Sendungsnummer:*], text(font: "Liberation Mono")[#d.tracking_number])
        }
        rows
      }
    )
  ]
]

#v(2em)

// ── Unterschriftszeile ───────────────────────────────────────
#grid(
  columns: (1fr, 1fr),
  gutter: 2em,
  [
    #line(length: 80%, stroke: 0.5pt)
    #text(size: 8pt, fill: luma(120))[Datum / Unterschrift Absender]
  ],
  [
    #line(length: 80%, stroke: 0.5pt)
    #text(size: 8pt, fill: luma(120))[Datum / Unterschrift Empfänger (optional)]
  ],
)

// ── Fußzeile ────────────────────────────────────────────────
#place(bottom + center)[
  #line(length: 100%, stroke: 0.5pt + luma(200))
  #v(4pt)
  #text(size: 8pt, fill: luma(120))[
    #if s.business_name != none { s.business_name + " · " }
    #s.name · #s.street · #s.zip #s.city
    #if s.email != none { " · " + s.email }
  ]
]
