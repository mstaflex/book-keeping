"""Testdaten für den Etsy-Mock: Bestellungen und Ledger, relativ zum aktuellen Monat.

Alle Namen, Adressen und Nummern sind ausgedacht. Die Daten werden beim Start
des Containers einmal berechnet; nach einem Monatswechsel liefert ein
Neustart Daten für den neuen Vor- und laufenden Monat (am besten mit frischer
Datenbank: docker compose -f test/docker-compose.yml down -v).

Sonderfälle, die die Workflows abdecken müssen:
  1001  physisch, Apostroph im Namen, zweite Adresszeile       → Workflow 04
  1002  rein digital                                          → 04 lehnt ab, 05 im Folgemonat
  1003  gemischt mit Gutschein (physisch 20 €, digital 10 €)   → 04 und 05 teilen den Rabatt
  1004  physisch, Titel HTML-kodiert ("Mother&#39;s Day")     → Titel lesbar auf der Rechnung
  2001  Vormonat, digital, 2 Stück                             → 05 Vormonat
  2002  Vormonat, digital, storniert und erstattet             → nie auf einer Etsy-Rechnung
  2003  Vormonat, physisch, versandt mit Sendungsnummer        → 04 mit Tracking
  2004  Vormonat, digital, Käuferin in Österreich (20 % VAT)   → 05 Vormonat
Dazu im Ledger: Auszahlung, Kartenbelastung, Verlängerungsgebühren und ein
unbekannter Typ (shipping_labels), der im Prüfbericht unter "unbekannt" auftaucht.
"""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo('Europe/Berlin')
NOW = datetime.now(BERLIN)
THIS_MONTH = NOW.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
LAST_MONTH = (THIS_MONTH - timedelta(days=1)).replace(day=1)


def this_month(fraction):
    """Zeitpunkt im laufenden Monat, sicher in der Vergangenheit."""
    return THIS_MONTH + (NOW - THIS_MONTH) * fraction


def last_month(day, hour=10):
    return LAST_MONTH.replace(day=day, hour=hour)


def cents(eur):
    return int(round(eur * 100))


def money(eur):
    return {'amount': cents(eur), 'divisor': 100, 'currency_code': 'EUR'}


# receipt_id, Zeitpunkt, Status, Käufer, Land, MwSt-Satz digital, Gutschein, Versand, Artikel, Sendung
# Artikel: (listing_id, Titel, Menge, Einzelpreis, digital)
CASES = [
    (1001, this_month(0.2), 'Paid', ("Anna O'Neil", 'Hauptstr. 5', 'Hinterhaus 3. OG', 'Berlin', '10115'), 'DE', 0.19, 0.00, 4.90,
     [(501, 'Postkarte Herbst', 2, 3.50, False), (502, 'Poster A4', 1, 12.00, False)], None),
    (1002, this_month(0.4), 'Completed', ('Max Mustermann', 'Musterweg 1', None, 'Hamburg', '20095'), 'DE', 0.19, 0.00, 0.00,
     [(601, 'Digitale Vorlage', 1, 8.00, True)], None),
    (1003, this_month(0.6), 'Paid', ('Erika Musterfrau', 'Beispielallee 7', None, 'Köln', '50667'), 'DE', 0.19, 3.00, 4.90,
     [(503, 'Poster A3', 1, 20.00, False), (601, 'Digitale Vorlage', 1, 10.00, True)], None),
    (1004, this_month(0.8), 'Paid', ('Vorname Nachname', 'Testgasse 2', None, 'München', '80331'), 'DE', 0.19, 0.00, 1.95,
     [(504, 'Karte &quot;Mother&#39;s Day&quot;', 3, 2.50, False)], None),
    (2001, last_month(5), 'Completed', ('Jean Dupont', '1 Rue Exemple', None, 'Paris', '75001'), 'FR', 0.20, 0.00, 0.00,
     [(602, 'Digitales Muster', 2, 7.50, True)], None),
    (2002, last_month(9), 'Canceled', ('Max Mustermann', 'Musterweg 1', None, 'Hamburg', '20095'), 'DE', 0.19, 0.00, 0.00,
     [(602, 'Digitales Muster', 1, 7.50, True)], None),
    (2003, last_month(14), 'Completed', ('Erika Musterfrau', 'Beispielallee 7', None, 'Köln', '50667'), 'DE', 0.19, 0.00, 1.95,
     [(501, 'Postkarte Herbst', 5, 3.00, False)], ('TESTTRACK2003', 'Deutsche Post')),
    (2004, last_month(21), 'Completed', ('Vorname Nachname', 'Teststraße 3', None, 'Wien', '1010'), 'AT', 0.20, 0.00, 0.00,
     [(603, 'Digitaler Kalender', 1, 12.00, True)], None),
]


def _build():
    receipts, ledger = [], []
    seq = [0]

    def entry(ts, ledger_type, amount_eur, ref_type, ref_id, description=None):
        seq[0] += 1
        ledger.append({
            'entry_id': 800000 + seq[0], 'ledger_id': 1, 'sequence_number': seq[0],
            'amount': cents(amount_eur), 'currency': 'EUR', 'balance': 0,
            'description': description or ledger_type.lower(),
            'create_date': int(ts.timestamp()), 'ledger_type': ledger_type,
            'reference_type': ref_type, 'reference_id': str(ref_id),
        })

    for rid, ts, status, buyer, country, vat_rate, coupon, shipping, items, shipment in CASES:
        name, line1, line2, city, zip_ = buyer
        items_sum = sum(q * p for _, _, q, p, _ in items)
        digital_sum = sum(q * p for _, _, q, p, d in items if d)
        subtotal = round(items_sum - coupon, 2)
        # Etsy erhebt die VAT nur auf digitale Artikel (als Plattform); Gutschein anteilig
        digital_net = digital_sum * subtotal / items_sum if items_sum else 0
        vat = round(digital_net * vat_rate, 2)
        grand = round(subtotal + shipping + vat, 2)
        created = int(ts.timestamp())
        updated = created + (3 * 86400 if shipment else 3600)
        receipts.append({
            'receipt_id': rid, 'status': status, 'is_shipped': bool(shipment),
            'name': name, 'buyer_email': f'kunde{rid}@example.org',
            'first_line': line1, 'second_line': line2, 'city': city, 'zip': zip_, 'country_iso': country,
            'created_timestamp': created, 'updated_timestamp': updated,
            'subtotal': money(subtotal), 'total_shipping_cost': money(shipping),
            'total_vat_cost': money(vat), 'grandtotal': money(grand),
            'transactions': [{'transaction_id': rid * 10 + i, 'listing_id': lid, 'title': title, 'quantity': q,
                              'price': money(p), 'is_digital': d}
                             for i, (lid, title, q, p, d) in enumerate(items)],
            'shipments': [{'tracking_code': shipment[0], 'carrier_name': shipment[1]}] if shipment else [],
        })
        pay = ts + timedelta(minutes=1)
        entry(pay, 'PAYMENT_GROSS', grand, 'receipt', rid)
        if vat:
            entry(pay, 'VAT_TAX_EP', -vat, 'payment', rid + 50000)
        for i, (lid, _, q, p, _) in enumerate(items):
            entry(pay, 'transaction', -round(q * p * 0.065, 2), 'transaction', rid * 10 + i)
            entry(pay, 'renew_sold', -0.18 * q, 'listing', lid)
        entry(pay, 'PAYMENT_PROCESSING_FEE', -round(grand * 0.04 + 0.30, 2), 'payment', rid + 50000)
        if status == 'Canceled':
            entry(ts + timedelta(days=1), 'REFUND', -grand, 'receipt', rid)

    entry(last_month(2), 'auto_renew_expired', -0.18, 'listing', 701)
    entry(last_month(3), 'renew_expired', -0.18, 'listing', 702)
    entry(last_month(26), 'DISBURSE2', -40.00, 'disbursement', 900001)
    entry(this_month(0.1), 'billing_payment', 5.00, 'shop_payment', 900002)
    entry(this_month(0.5), 'shipping_labels', -3.99, 'etsy', 900003)
    return receipts, ledger


_RECEIPTS, _LEDGER = _build()


def receipts():
    return [dict(r) for r in _RECEIPTS]


def ledger():
    return [dict(e) for e in _LEDGER]


if __name__ == '__main__':
    import json
    print(json.dumps({'receipts': _RECEIPTS, 'ledger': _LEDGER}, indent=1, ensure_ascii=False)[:3000])
