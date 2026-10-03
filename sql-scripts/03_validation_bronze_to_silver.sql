/* ============================================================
   03_VALIDATION_BRONZE_TO_SILVER.SQL
   Layer   : AUDIT (gate 1 of 2)
   Purpose : Gate the bronze -> silver transform (02) before anything
             downstream is allowed to trust it. Two jobs:

     1. TABLE POPULATION SANITY (Section 0, runs first).
        Every check below this point uses COUNT() / NULLIF() ratios,
        which PASS VACUOUSLY on zero rows. An empty table looks
        "clean" unless something checks for emptiness explicitly —
        that is what Section 0 does, before anything else runs.

     2. ROW-COUNT RECONCILIATION (Section 1).
        For every bronze -> silver step, assert what the resulting
        row count SHOULD be — an exact match, or bronze count minus
        a named, counted reason for the drop — instead of eyeballing
        "n vs m". If the reconciliation doesn't balance, that's a
        real regression.

   Two FAIL results are EXPECTED and stable, by design:
   'transactions_orphaned_accounts' and 'duplicate_account_ids' are
   real EDA findings, handled explicitly downstream (05/06) with a
   full audit trail. They are supposed to show FAIL here so the
   audit trail stays honest — the thing to watch is the count
   changing run over run, not the FAIL itself. Every other FAIL
   means something broke that wasn't broken before.

   Run this after 01_bronze_load.sql and 02_silver_cleanse_enrich.sql
   in the same session/database context (NEXUS_FINANCE).
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.dq_results (
  check_id        VARCHAR,
  pipeline_stage  VARCHAR,
  check_name      VARCHAR,
  check_result    VARCHAR,
  expected_value  VARCHAR,
  actual_value    FLOAT,
  run_timestamp   TIMESTAMP_NTZ
);

-- One shared timestamp per run, so this run's results can be pulled
-- out with a single WHERE clause (see summary queries at the bottom).
SET run_ts = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;

/* ============================================================
   SECTION 0 — TABLE POPULATION SANITY
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'bronze_raw_customer_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM bronze.raw_customer;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'bronze_raw_account_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM bronze.raw_account;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'bronze_raw_transactions_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM bronze.raw_transactions;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'bronze_raw_watchlist_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM bronze.raw_watchlist;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'bronze_raw_rule_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM bronze.raw_rule;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_customer_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.customer;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_account_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.account;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_transactions_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.transactions;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_watchlist_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.watchlist;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_customer_entity_map_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.customer_entity_map;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'silver_tmp_high_risk_countries_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.tmp_high_risk_countries;

/* ============================================================
   SECTION 1 — ROW-COUNT RECONCILIATION, bronze -> silver
   ============================================================ */

-- transactions: 02 applies no filtering join, only typing -> exact match expected
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transaction_row_count_match',
  IFF((SELECT COUNT(*) FROM bronze.raw_transactions) = (SELECT COUNT(*) FROM silver.transactions), 'PASS', 'FAIL'),
  (SELECT COUNT(*) FROM bronze.raw_transactions)::VARCHAR,
  (SELECT COUNT(*) FROM silver.transactions),
  $run_ts;

-- watchlist: straight passthrough -> exact match expected
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'watchlist_row_count_match',
  IFF((SELECT COUNT(*) FROM bronze.raw_watchlist) = (SELECT COUNT(*) FROM silver.watchlist), 'PASS', 'FAIL'),
  (SELECT COUNT(*) FROM bronze.raw_watchlist)::VARCHAR,
  (SELECT COUNT(*) FROM silver.watchlist),
  $run_ts;

-- customer_entity_map: one row per raw customer, no filtering -> exact match expected
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_entity_map_row_count_match',
  IFF((SELECT COUNT(*) FROM bronze.raw_customer) = (SELECT COUNT(*) FROM silver.customer_entity_map), 'PASS', 'FAIL'),
  (SELECT COUNT(*) FROM bronze.raw_customer)::VARCHAR,
  (SELECT COUNT(*) FROM silver.customer_entity_map),
  $run_ts;

-- customer: entity resolution intentionally collapses duplicate people, so silver
-- count should be <= bronze count, AND should equal the distinct resolved-id count
-- in the entity map (internal consistency between the two silver objects)
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_dedup_delta',
  IFF(delta >= 0 AND silver_cnt = distinct_resolved_cnt, 'PASS', 'FAIL'),
  '>= 0 (silver.customer <= bronze.raw_customer after entity resolution), and silver.customer count must equal distinct customer_id_resolved in customer_entity_map',
  delta,
  $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM bronze.raw_customer) - (SELECT COUNT(*) FROM silver.customer) AS delta,
    (SELECT COUNT(*) FROM silver.customer)                                              AS silver_cnt,
    (SELECT COUNT(DISTINCT customer_id_resolved) FROM silver.customer_entity_map)       AS distinct_resolved_cnt
);

-- account: silver.account INNER JOINs to customer_entity_map on customer_id, so any
-- raw_account row whose customer_id isn't in raw_customer is silently dropped.
-- Reconciliation identity: silver.account rows + orphaned-customer accounts = bronze.raw_account rows.
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'account_row_count_reconciliation',
  IFF(silver_cnt + orphan_cnt = bronze_cnt, 'PASS', 'FAIL'),
  bronze_cnt || ' (silver.account count + accounts_orphaned_customers count should sum to bronze.raw_account count)',
  silver_cnt + orphan_cnt,
  $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM bronze.raw_account) AS bronze_cnt,
    (SELECT COUNT(*) FROM silver.account)     AS silver_cnt,
    (SELECT COUNT(*) FROM bronze.raw_account a
       WHERE NOT EXISTS (SELECT 1 FROM bronze.raw_customer c WHERE c.customer_id = a.customer_id)) AS orphan_cnt
);

/* ============================================================
   SECTION 2 — REFERENTIAL INTEGRITY / ORPHAN DETECTION
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'accounts_orphaned_customers',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM bronze.raw_account a
        WHERE NOT EXISTS (SELECT 1 FROM bronze.raw_customer c WHERE c.customer_id = a.customer_id));

-- known EDA finding (~371 account_ids / ~43,584 txns) — resolved via documented
-- exclusion + audit trail in 05/06, not a script bug. Kept as FAIL so the audit
-- trail stays honest; watch for the count CHANGING, not for it being nonzero.
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transactions_orphaned_accounts',
  IFF(cnt = 0, 'PASS', 'FAIL'),
  '0 (known EDA gap, ~43584 expected — excluded downstream in 05/06 with audit trail; flag if this count changes)',
  cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions t
        WHERE NOT EXISTS (SELECT 1 FROM silver.account a WHERE a.account_id = t.account_id));

/* ============================================================
   SECTION 3 — DUPLICATE / UNIQUENESS CHECKS
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'duplicate_transaction_ids',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM (SELECT transaction_id FROM silver.transactions GROUP BY transaction_id HAVING COUNT(*) > 1));

-- known EDA finding (~166 account_ids, genuine customer_id_resolved conflicts) —
-- resolved via provisional tiebreak + audit.excluded_duplicate_accounts in 05.
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'duplicate_account_ids',
  IFF(cnt = 0, 'PASS', 'FAIL'),
  '0 (known EDA gap, ~166 expected — deduped downstream in 05 with audit trail; flag if this count changes)',
  cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM (SELECT account_id FROM silver.account GROUP BY account_id HAVING COUNT(*) > 1));

/* ============================================================
   SECTION 4 — PARSING / DATA-QUALITY PERCENTAGE CHECKS
   PASS/WARN/FAIL bands tolerate some injected dirty data (by
   dataset design) but still catch a genuinely broken cast.
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transactions_amount_unparseable_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 5 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 5% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_amount_unparseable) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.transactions);

-- any NULL amount_usd should be explained by is_amount_unparseable = TRUE (malformed
-- non-null source text); a NULL with the flag FALSE means bronze had a genuinely
-- blank amount, which is a different (and unexpected) problem
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transactions_amount_null_after_cast',
  IFF(cnt = 0, 'PASS', 'FAIL'),
  '0 (any null amount_usd should be explained by is_amount_unparseable = TRUE)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE amount_usd IS NULL AND NOT is_amount_unparseable);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transactions_timestamp_unparseable_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 5 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 5% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_txn_timestamp_unparseable) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.transactions);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_dob_unparseable_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 5 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 5% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_dob_unparseable) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.customer);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_pep_flag_unparseable_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 5 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 5% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_pep_flag_unparseable) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.customer);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'account_open_date_unparseable_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 5 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 5% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_open_date_unparseable) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.account);

-- known, intentional injected sparsity (by dataset design) — never FAIL, only WARN
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_missing_business_type_pct',
  CASE WHEN pct <= 10 THEN 'PASS' ELSE 'WARN' END,
  '<= 10% PASS ideal (target 2-5%); intentional injected sparsity, never FAIL', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_business_type_missing) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.customer);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_ssn_id_format_invalid_pct',
  CASE WHEN pct <= 1 THEN 'PASS' WHEN pct <= 10 THEN 'WARN' ELSE 'FAIL' END,
  '<= 1% PASS, <= 10% WARN (tolerance for injected dirty data)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(NOT is_id_format_valid) / NULLIF(COUNT(*), 0), 2) AS pct FROM silver.customer);

/* ============================================================
   SECTION 5 — DOMAIN / CATEGORICAL VALUE CHECKS
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'channel_unexpected_values',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (expected: ACH, CARD, CASH, WIRE)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE channel NOT IN ('ACH','CARD','CASH','WIRE'));

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'direction_unexpected_values',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (expected: credit, debit)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE direction NOT IN ('credit','debit'));

-- known, intentional injected dirty data (CHANNEL values bleeding into ACCOUNT_TYPE) — WARN not FAIL
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'account_type_unexpected_values',
  IFF(cnt = 0, 'PASS', 'WARN'),
  '0 ideal (expected: checking, savings); known dirty overlap with channel values (ach/card/cash/wire) is intentional, never FAIL', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.account WHERE account_type NOT IN ('checking','savings'));

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'counterparty_country_standardization_leftover_variants',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (no un-consolidated US/UK naming variants should survive standardization)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions
        WHERE (counterparty_country_standardized ILIKE '%united states%' OR counterparty_country_standardized ILIKE '%u.s.a%'
               OR counterparty_country_standardized ILIKE '%britain%' OR counterparty_country_standardized ILIKE '%england%'
               OR counterparty_country_standardized ILIKE '%united kingdom%')
          AND counterparty_country_standardized NOT IN ('US','UK'));

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'customer_country_standardization_leftover_variants',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (no un-consolidated US/UK naming variants should survive standardization)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.customer
        WHERE (country_standardized ILIKE '%united states%' OR country_standardized ILIKE '%u.s.a%'
               OR country_standardized ILIKE '%britain%' OR country_standardized ILIKE '%england%'
               OR country_standardized ILIKE '%united kingdom%')
          AND country_standardized NOT IN ('US','UK'));

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'watchlist_country_standardization_leftover_variants',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (no un-consolidated US/UK naming variants should survive standardization)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.watchlist
        WHERE (country_standardized ILIKE '%united states%' OR country_standardized ILIKE '%u.s.a%'
               OR country_standardized ILIKE '%britain%' OR country_standardized ILIKE '%england%'
               OR country_standardized ILIKE '%united kingdom%')
          AND country_standardized NOT IN ('US','UK'));

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'transactions_negative_amounts',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE amount_usd < 0);

/* ============================================================
   SECTION 6 — DERIVED / VELOCITY FIELD CHECKS
   These fields are pre-computed in silver; this section validates
   them, it does not recompute them.
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'rolling_7day_txn_sum_unexpected_nulls',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE rolling_7day_txn_sum IS NULL);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'txn_count_velocity_7day_unexpected_nulls',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE txn_count_velocity_7day IS NULL);

-- computed self-referentially against distinct account_id in silver.transactions
-- itself (not silver.account), so it stays correct regardless of the orphan gap
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'days_since_last_txn_null_count_matches_distinct_accounts',
  IFF(null_cnt = distinct_accts, 'PASS', 'FAIL'),
  distinct_accts || ' (one first-transaction null expected per distinct account_id in silver.transactions)',
  null_cnt, $run_ts
FROM (SELECT COUNT_IF(days_since_last_txn IS NULL) AS null_cnt, COUNT(DISTINCT account_id) AS distinct_accts FROM silver.transactions);

/* ============================================================
   SECTION 7 — HIGH-RISK COUNTRY FLAG VERIFICATION
   Must verify the flag actually FIRES, not just that it's non-null
   — a flag that is always FALSE would still pass a simple not-null
   check while silently flagging zero transactions.
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'high_risk_counterparty_country_flag_fires',
  IFF(cnt > 0, 'PASS', 'FAIL'), '> 0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.transactions WHERE is_high_risk_counterparty_country = TRUE);

-- sanity upper bound: if this is suspiciously close to 100%, the join is likely
-- backwards (e.g. matching NOT IN instead of IN the high-risk list)
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'bronze_to_silver', 'high_risk_counterparty_country_flag_not_universally_true',
  CASE WHEN pct_true > 0 AND pct_true < 95 THEN 'PASS' WHEN pct_true = 0 THEN 'FAIL' ELSE 'WARN' END,
  '0% < x < 95%', pct_true, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(is_high_risk_counterparty_country) / NULLIF(COUNT(*), 0), 2) AS pct_true FROM silver.transactions);

/* =========== Quick summary of this run =========== */
-- SELECT check_result, COUNT(*) FROM audit.dq_results WHERE run_timestamp = $run_ts GROUP BY check_result ORDER BY check_result;
-- SELECT check_name, check_result, expected_value, actual_value FROM audit.dq_results WHERE run_timestamp = $run_ts AND check_result != 'PASS' ORDER BY check_result, check_name;
