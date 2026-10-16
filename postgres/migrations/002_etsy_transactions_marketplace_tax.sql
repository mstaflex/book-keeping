-- =============================================================================
-- 002 · etsy_transactions.type um 'marketplace_tax' erweitern
--
-- Der Ledger-Sync (02) schreibt Steuern, die Etsy als Marktplatz einbehält,
-- als type = 'marketplace_tax'. Ohne diese Migration verletzt das den alten
-- CHECK-Constraint, und der komplette Ledger-Sync bricht bei jedem Lauf ab.
-- Idempotent: kann gefahrlos mehrfach ausgeführt werden. Kennt der Constraint
-- 'marketplace_tax' schon (auch in der erweiterten Fassung aus 004), bleibt
-- er unverändert – sonst würde ein erneuter Lauf die neueren Typen verbieten.
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conname = 'etsy_transactions_type_check'
                   AND pg_get_constraintdef(oid) LIKE '%marketplace_tax%') THEN
    ALTER TABLE etsy_transactions DROP CONSTRAINT IF EXISTS etsy_transactions_type_check;
    ALTER TABLE etsy_transactions ADD CONSTRAINT etsy_transactions_type_check CHECK (type IN (
        'sale', 'fee_transaction', 'fee_listing',
        'fee_ads', 'fee_processing', 'refund',
        'tax',              -- eigene Steuern (Rechnungen, manuell)
        'marketplace_tax',  -- von Etsy als 'deemed supplier' einbehalten/abgeführt
        'payout'
    ));
  END IF;
END $$;

COMMIT;
