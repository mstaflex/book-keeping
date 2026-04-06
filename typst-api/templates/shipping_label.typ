// ============================================================
//  Versandetikett · DIN A6 (148 × 105 mm)
//  Druckfertig: 2 Labels passen auf ein DIN A4-Blatt
// ============================================================
#let d    = json("data.json")
#let from = d.sender
#let to   = d.recipient

#let addr-line(v) = if v != none and v != "" { v + linebreak() }

#set page(
  width:  148mm,
  height: 105mm,
  margin: (top: 5mm, bottom: 5mm, left: 6mm, right: 6mm),
)
#set text(font: "Liberation Sans", size: 10pt, lang: "de")
#set par(leading: 0.5em)

#let accent = rgb("#1e40af")

// ── Absender (oben links, klein) ─────────────────────────────
#box(
  stroke:  0.4pt + luma(180),
  inset:   (x: 4pt, y: 3pt),
  radius:  2pt,
)[
  #text(size: 7pt, fill: luma(80))[
    VON: #from.name · #from.street · #from.zip #from.city · #from.country
  ]
]

#v(2mm)
#line(length: 100%, stroke: 0.4pt + luma(200))
#v(3mm)

// ── Empfänger (groß) ─────────────────────────────────────────
#text(size: 7.5pt, fill: luma(100))[AN:]
#v(1mm)
#text(size: 13pt, weight: "bold")[#to.name]
#v(0.5mm)
#text(size: 11pt)[
  #addr-line(to.street)#text(weight: "bold")[#to.zip] #to.city \
  #to.country
]

#v(auto)

// ── Unterer Bereich: Carrier + Tracking ─────────────────────
#line(length: 100%, stroke: 0.4pt + luma(200))
#v(2mm)

#grid(
  columns: (1fr, auto),
  gutter: 4mm,
  align(left)[
    #if d.carrier != none [
      #box(
        fill:   accent,
        inset:  (x: 6pt, y: 4pt),
        radius: 3pt,
      )[#text(fill: white, weight: "bold", size: 11pt)[#d.carrier]]
      #h(4pt)
    ]
    #if d.service != none [
      #text(size: 8.5pt, fill: luma(80))[#d.service]
    ]
  ],
  align(right)[
    #if d.weight != none [
      #text(size: 8pt, fill: luma(80))[#d.weight]
    ]
  ],
)

#if d.tracking_number != none [
  #v(1.5mm)
  #text(size: 8pt, fill: luma(100))[Sendungsnr.: ]
  #text(font: "Liberation Mono", size: 9pt, weight: "bold")[#d.tracking_number]
]
