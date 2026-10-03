/* ============================================================
   06_VALIDATION_SILVER_TO_GOLD.SQL
   Layer   : AUDIT (gate 2 of 2)
   Purpose : Gate the silver -> gold build (04 rule engine + 05 star
             schema). Same two jobs as 03, applied to the gold layer:

     1. TABLE POPULATION SANITY (Section 0, runs first) — every
        gold object, for the same reason as 03: checks below this
        point can pass vacuously on an empty table.

     2. ROW-COUNT RECONCILIATION (Sections 1-8) — every MERGE/JOIN
        step in 05 that can drop rows is explicitly reconciled here,
        beyond the two documented exclusions (orphan transactions,
        duplicate accounts):
          - fact_transactions can also lose rows to the INNER JOIN
            on dim_date (transaction_date outside the spine) or
            dim_geography (checked defensively, though geography is
            built FROM these countries so this should not fire).
          - dim_watchlist is built by joining silver.watchlist to
            dim_geography; a watchlist country that never appears as
            a counterparty country has nothing to join to.
          - dim_account: duplicate rows are logged, but only if they
            differ from the surviving row's natural key — an EXACT
            duplicate row would neither survive nor get logged.
            Section 6's audit-trail-complete check catches that gap.
          - fact_alerts drops any alert whose account_id was never
            loaded into dim_account, via its INNER JOIN — Section 8
            surfaces that.

   Run this after 01-05 have run in the same session/database
   context (NEXUS_FINANCE).
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

SET run_ts = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ;
SET as_of_date = '2026-06-30';  -- keep in sync with 04/05's anchor

/* ============================================================
   SECTION 0 — TABLE POPULATION SANITY
   ============================================================ */

-- upstream dependency checks — if these are empty, everything below is moot
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'silver_transactions_source_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.transactions;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'silver_account_source_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.account;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'silver_customer_source_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.customer;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'silver_watchlist_source_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM silver.watchlist;

-- gold dims/facts
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_date_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_date;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_geography_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_geography;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_rule_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_rule;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_watchlist_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_watchlist;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_customer_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_customer;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_dim_account_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.dim_account;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_fact_transactions_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.fact_transactions;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_fact_alerts_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.fact_alerts;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_fact_customer_risk_snapshot_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.fact_customer_risk_snapshot;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_alert_candidates_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.alert_candidates;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_alerts_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.alerts;

-- rule-engine hit tables: an always-empty tmp_*_hits table with no error raised
-- is exactly the failure mode a naive "did it run without erroring" check misses
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_tmp_structuring_hits_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.tmp_structuring_hits;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_tmp_rapid_movement_hits_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.tmp_rapid_movement_hits;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_tmp_high_risk_country_hits_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.tmp_high_risk_country_hits;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'gold_tmp_ctr_hits_not_empty', IFF(COUNT(*) > 0, 'PASS', 'FAIL'), '> 0', COUNT(*), $run_ts FROM gold.tmp_ctr_hits;

/* ============================================================
   SECTION 1 — DIM_DATE COVERAGE
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_date_covers_as_of_date',
  IFF(cnt = 1, 'PASS', 'FAIL'), '1', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.dim_date WHERE full_date = $as_of_date::DATE);

-- disposition_date can run up to 90 days past alert_date; if the spine doesn't
-- reach that far, fact_alerts' INNER JOIN to dim_date silently drops those rows
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_date_covers_disposition_tail',
  IFF(cnt = 0, 'PASS', 'FAIL'),
  '0 (count of gold.alerts.disposition_date values beyond the max date in gold.dim_date)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.alerts a WHERE a.disposition_date > (SELECT MAX(full_date) FROM gold.dim_date));

/* ============================================================
   SECTION 2 — DIM_RULE RECONCILIATION
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_rule_row_count_match',
  IFF((SELECT COUNT(*) FROM bronze.raw_rule) = (SELECT COUNT(*) FROM gold.dim_rule), 'PASS', 'FAIL'),
  (SELECT COUNT(*) FROM bronze.raw_rule)::VARCHAR,
  (SELECT COUNT(*) FROM gold.dim_rule),
  $run_ts;

/* ============================================================
   SECTION 3 — DIM_GEOGRAPHY RECONCILIATION
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_geography_row_count_match',
  IFF(txn_countries = geo_cnt, 'PASS', 'FAIL'),
  txn_countries || ' (distinct counterparty_country_standardized in silver.transactions)',
  geo_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(DISTINCT counterparty_country_standardized) FROM silver.transactions) AS txn_countries,
    (SELECT COUNT(*) FROM gold.dim_geography) AS geo_cnt
);

-- confirms every dim_geography row has a real region assigned — not NULL, and
-- not the defensive 'Unmapped' fallback for a country outside the hardcoded map
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_geography_region_populated',
  IFF(cnt = 0, 'PASS', 'FAIL'),
  '0 (count of gold.dim_geography rows with NULL or Unmapped region)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.dim_geography WHERE region IS NULL OR region = 'Unmapped');

/* ============================================================
   SECTION 4 — DIM_WATCHLIST RECONCILIATION
   dim_watchlist is built by joining silver.watchlist to
   dim_geography — a watchlist country that never appears as a
   counterparty country in silver.transactions has no dim_geography
   row to join to, and would otherwise vanish from dim_watchlist
   with no trace.
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_watchlist_row_count_match',
  IFF(silver_cnt = gold_cnt, 'PASS', 'FAIL'),
  silver_cnt || ' (silver.watchlist row count)',
  gold_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM silver.watchlist) AS silver_cnt,
    (SELECT COUNT(*) FROM gold.dim_watchlist) AS gold_cnt
);

-- diagnostic that directly explains any gap in the check above
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'watchlist_entities_missing_geography',
  IFF(cnt = 0, 'PASS', 'WARN'),
  '0 ideal (watchlist countries that never appear as a transaction counterparty country and so have no gold.dim_geography row to join to)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM silver.watchlist w
        WHERE NOT EXISTS (SELECT 1 FROM gold.dim_geography g WHERE g.country = w.country_standardized));

-- confirms every entity counted above is actually captured in
-- audit.excluded_watchlist_entities, not just counted with no record of which
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'watchlist_audit_trail_complete',
  IFF(missing_cnt = logged_cnt, 'PASS', 'FAIL'),
  missing_cnt || ' (watchlist entities with no matching dim_geography row)',
  logged_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM silver.watchlist w
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_geography g WHERE g.country = w.country_standardized)) AS missing_cnt,
    (SELECT COUNT(*) FROM audit.excluded_watchlist_entities) AS logged_cnt
);

/* ============================================================
   SECTION 5 — DIM_CUSTOMER RECONCILIATION
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_customer_current_row_count_match',
  IFF(silver_cnt = current_cnt, 'PASS', 'FAIL'),
  silver_cnt || ' (silver.customer row count)',
  current_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM silver.customer) AS silver_cnt,
    (SELECT COUNT(*) FROM gold.dim_customer WHERE is_current = TRUE) AS current_cnt
);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_customer_duplicate_current_flag',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (no customer_id should have more than one is_current = TRUE row)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM (
  SELECT customer_id FROM gold.dim_customer WHERE is_current = TRUE GROUP BY customer_id HAVING COUNT(*) > 1
));

/* ============================================================
   SECTION 6 — DIM_ACCOUNT RECONCILIATION
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_account_row_count_match',
  IFF(distinct_cnt = gold_cnt, 'PASS', 'FAIL'),
  distinct_cnt || ' (distinct account_id in silver.account)',
  gold_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(DISTINCT account_id) FROM silver.account) AS distinct_cnt,
    (SELECT COUNT(*) FROM gold.dim_account) AS gold_cnt
);

-- catches an edge case the 05 exclusion log can miss: an EXACT duplicate row
-- (same account_id, customer_id_resolved, AND open_date) is invisible to a
-- natural-key anti-join, so it could vanish with no audit trail even though
-- only one copy survives the dedup. If duplicate row count != logged count,
-- some duplicates went unlogged.
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'duplicate_account_audit_trail_complete',
  IFF(duplicate_row_cnt = logged_cnt, 'PASS', 'FAIL'),
  duplicate_row_cnt || ' (silver.account total rows minus distinct account_id count)',
  logged_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM silver.account) - (SELECT COUNT(DISTINCT account_id) FROM silver.account) AS duplicate_row_cnt,
    (SELECT COUNT(*) FROM audit.excluded_duplicate_accounts) AS logged_cnt
);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'dim_account_unique_account_id',
  IFF(total_cnt = distinct_cnt, 'PASS', 'FAIL'), total_cnt::VARCHAR, distinct_cnt, $run_ts
FROM (SELECT COUNT(*) AS total_cnt, COUNT(DISTINCT account_id) AS distinct_cnt FROM gold.dim_account);

/* ============================================================
   SECTION 7 — FACT_TRANSACTIONS RECONCILIATION
   ============================================================ */

-- core reconciliation identity: silver.transactions = fact_transactions + excluded_orphan_transactions
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_transactions_row_count_reconciliation',
  IFF(silver_cnt = fact_cnt + excluded_cnt, 'PASS', 'FAIL'),
  silver_cnt || ' (silver.transactions count; fact_transactions + audit.excluded_orphan_transactions should sum to this)',
  fact_cnt + excluded_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM silver.transactions) AS silver_cnt,
    (SELECT COUNT(*) FROM gold.fact_transactions) AS fact_cnt,
    (SELECT COUNT(*) FROM audit.excluded_orphan_transactions) AS excluded_cnt
);

-- informational record of the exclusion's dollar value, so it's traceable run-over-run
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'excluded_orphan_transactions_value',
  'PASS', 'informational — matches EDA-documented ~$17.47M exclusion; watch for material drift run-over-run',
  ROUND(SUM(amount_usd), 2), $run_ts
FROM audit.excluded_orphan_transactions;

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_transactions_unique_transaction_key',
  IFF(total_cnt = distinct_cnt, 'PASS', 'FAIL'), total_cnt::VARCHAR, distinct_cnt, $run_ts
FROM (SELECT COUNT(*) AS total_cnt, COUNT(DISTINCT transaction_key) AS distinct_cnt FROM gold.fact_transactions);

/* ============================================================
   SECTION 8 — ALERT PIPELINE RECONCILIATION (candidates -> alerts -> fact_alerts)
   ============================================================ */

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'alert_candidates_hit_union_match',
  IFF(hit_sum = candidate_cnt, 'PASS', 'FAIL'),
  hit_sum || ' (sum of tmp_structuring_hits + tmp_rapid_movement_hits + tmp_high_risk_country_hits + tmp_ctr_hits)',
  candidate_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM gold.tmp_structuring_hits) + (SELECT COUNT(*) FROM gold.tmp_rapid_movement_hits)
      + (SELECT COUNT(*) FROM gold.tmp_high_risk_country_hits) + (SELECT COUNT(*) FROM gold.tmp_ctr_hits) AS hit_sum,
    (SELECT COUNT(*) FROM gold.alert_candidates) AS candidate_cnt
);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'alerts_row_count_match',
  IFF(candidate_cnt = alert_cnt, 'PASS', 'FAIL'),
  candidate_cnt || ' (gold.alert_candidates count; disposition simulation should not add/drop rows)',
  alert_cnt, $run_ts
FROM (
  SELECT (SELECT COUNT(*) FROM gold.alert_candidates) AS candidate_cnt, (SELECT COUNT(*) FROM gold.alerts) AS alert_cnt
);

-- fact_alerts drops any alert whose account_id was never loaded into dim_account
-- (i.e. it references an orphaned transaction's account) via the INNER JOIN. This
-- surfaces both the total gap and how much of it is explained by that known cause.
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_alerts_row_count_reconciliation',
  IFF(alert_cnt = fact_cnt, 'PASS', IFF(alert_cnt - fact_cnt = orphan_account_alerts, 'WARN', 'FAIL')),
  alert_cnt || ' (gold.alerts count; gap explained by orphan-account alerts = ' || orphan_account_alerts || ')',
  fact_cnt, $run_ts
FROM (
  SELECT
    (SELECT COUNT(*) FROM gold.alerts) AS alert_cnt,
    (SELECT COUNT(*) FROM gold.fact_alerts) AS fact_cnt,
    (SELECT COUNT(*) FROM gold.alerts a
       WHERE NOT EXISTS (SELECT 1 FROM gold.dim_account da WHERE da.account_id = a.account_id)) AS orphan_account_alerts
);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_alerts_unique_alert_key',
  IFF(total_cnt = distinct_cnt, 'PASS', 'FAIL'), total_cnt::VARCHAR, distinct_cnt, $run_ts
FROM (SELECT COUNT(*) AS total_cnt, COUNT(DISTINCT alert_key) AS distinct_cnt FROM gold.fact_alerts);

/* ============================================================
   SECTION 9 — BUSINESS LOGIC / KPI BENCHMARK SANITY CHECKS
   ============================================================ */

-- target band from 04's disposition simulation: 88-95% FP / 5-10% SAR
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'disposition_mix_false_positive_pct',
  CASE WHEN pct BETWEEN 88 AND 95 THEN 'PASS' ELSE 'WARN' END,
  '88-95% (industry benchmark band)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(disposition = 'false_positive') / NULLIF(COUNT(*), 0), 2) AS pct FROM gold.alerts);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'disposition_mix_sar_filed_pct',
  CASE WHEN pct BETWEEN 5 AND 10 THEN 'PASS' ELSE 'WARN' END,
  '5-10% (industry benchmark band)', pct, $run_ts
FROM (SELECT ROUND(100.0 * COUNT_IF(disposition = 'sar_filed') / NULLIF(COUNT(*), 0), 2) AS pct FROM gold.alerts);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'risk_score_out_of_bounds',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.alerts WHERE risk_score < 0 OR risk_score > 100);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'disposition_date_before_alert_date',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.alerts WHERE disposition_date < alert_date);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'time_to_disposition_days_out_of_bounds',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (expected range 0-90 days)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.fact_alerts WHERE time_to_disposition_days < 0 OR time_to_disposition_days > 90);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'sla_overdue_flag_consistency',
  IFF(cnt = 0, 'PASS', 'FAIL'), '0 (is_sla_overdue_flag must equal time_to_disposition_days > 30)', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.fact_alerts WHERE is_sla_overdue_flag != (time_to_disposition_days > 30));

-- fact-layer belt-and-suspenders for the two rules most sensitive to a silent
-- zero-hits regression (a wrong param key or filter direction produces this
-- exact failure mode with no error raised)
INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_transactions_structuring_flag_fires',
  IFF(cnt > 0, 'PASS', 'FAIL'), '> 0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.fact_transactions WHERE structuring_flag = TRUE);

INSERT INTO audit.dq_results (check_id, pipeline_stage, check_name, check_result, expected_value, actual_value, run_timestamp)
SELECT UUID_STRING(), 'silver_to_gold', 'fact_transactions_rapid_movement_flag_fires',
  IFF(cnt > 0, 'PASS', 'FAIL'), '> 0', cnt, $run_ts
FROM (SELECT COUNT(*) AS cnt FROM gold.fact_transactions WHERE rapid_movement_flag = TRUE);

/* =========== Quick summary of this run =========== */
-- SELECT check_result, COUNT(*) FROM audit.dq_results WHERE run_timestamp = $run_ts GROUP BY check_result ORDER BY check_result;
-- SELECT check_name, check_result, expected_value, actual_value FROM audit.dq_results WHERE run_timestamp = $run_ts AND check_result != 'PASS' ORDER BY check_result, check_name;
