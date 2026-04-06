// ============================================================
//  Lieferschein · DIN A4 · DIN-5008-B
//  Angelehnt an @preview/invoice-pro
//  https://github.com/leonieziechmann/invoice-pro
// ============================================================
#let d = json("data.json")
#let s = d.seller
#let b = d.buyer

#set page(
  paper:  "a4",
  margin: (top: 20mm, bottom: 20mm, left: 25mm, right: 20mm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.55em)

#let accent = rgb("#16a34a")

// ── Kopfzeile ────────────────────────────────────────────
#grid(
  columns: (1fr, auto),
  gutter: 1em,
  align(left + top)[
    #text(size: 18pt, weight: "bold", fill: accent)[
      #if s.business_name != none { s.business_name } else { s.name }
    ]
  ],
  align(right, text(size: 8.5pt, fill: luma(80))[
    #s.name \
    #if s.street != none { s.street + linebreak() }
    #if s.zip != none { s.zip } #if s.city != none { " " + s.city }
    #if s.email != none { linebreak() + s.email }
    #if s.phone != none { linebreak() + s.phone }
  ]),
)
#v(2mm)
#line(length: 100%, stroke: 0.5pt + accent)
#v(8mm)

// ── Adressfenster DIN-5008-B + Info-Box rechts ───────────
#grid(
  columns: (85mm, 1fr),
  gutter: 1em,
  [
    #text(size: 7pt, fill: luma(120))[
      #if s.business_name != none { s.business_name } else { s.name } ·
      #if s.street != none { s.street } ·
      #if s.zip != none { s.zip } #if s.city != none { s.city }
    ]
    #v(2mm)
    #text(size: 10pt)[
      *#b.name* \
      #if b.street  != none { b.street  + linebreak() }
      #if b.zip     != none { b.zip }
      #if b.city    != none { " " + b.city + linebreak() }
      #if b.country != none { b.country }
    ]
  ],
  align(right)[
    #text(size: 14pt, weight: "bold")[LIEFERSCHEIN]
    #v(0.4em)
    #set text(size: 9pt)
    #grid(
      columns: (auto, auto),
      gutter: (0.6em, 0.3em),
      align(right, text(fill: luma(100))[Lieferschein-Nr.:]),
      align(left)[*#d.delivery_number*],
      align(right, text(fill: luma(100))[Datum:]),
      align(left)[#d.date],
      ..if d.order_id != none {(
        align(right, text(fill: luma(100))[Bestellung:]),
        align(left, text(fill: luma(80))[#d.order_id]),
      )} else { () },
    )
  ],
)

#v(10mm)

// ── Artikeltabelle ───────────────────────────────────────
#set table(
  stroke: none,
  inset:  (x: 6pt, y: 5pt),
  fill:   (_, row) => if row == 0 { accent } else if calc.odd(row) { luma(248) } else { white },
)
#set table.header(repeat: true)

#table(
  columns: (2em, 1fr, 5em),
  table.header(
    table.cell(text(fill: white, weight: "bold")[Pos.]),
    table.cell(text(fill: white, weight: "bold")[Artikel]),
    table.cell(align: center, text(fill: white, weight: "bold")[Menge]),
  ),
  ..d.items.map(i => (
    table.cell(align: center)[#i.pos],
    table.cell[#i.description],
    table.cell(align: center)[#i.quantity],
  )).flatten(),
)

// ── Versandinfo ──────────────────────────────────────────
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

// ── Unterschrift ─────────────────────────────────────────
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

// ── Fußzeile ─────────────────────────────────────────────
#place(bottom + center)[
  #line(length: 100%, stroke: 0.5pt + luma(200))
  #v(4pt)
  #text(size: 8pt, fill: luma(120))[
    #if s.business_name != none { s.business_name + " · " }
    #s.name
    #if s.street != none { " · " + s.street }
    #if s.zip != none { " · " + s.zip }
    #if s.city != none { " " + s.city }
    #if s.email != none { " · " + s.email }
  ]
]
