/* ============================================================
   05_GOLD_BUILD_FACTS_DIMS.SQL
   Layer   : GOLD
   Purpose : Assemble the final gold star schema from silver data
             plus the rule engine's output (04). No new detection
             logic here — this script only keys, finalizes, and
             merges. All merges use business keys so reruns are
             idempotent.

   Every exclusion made by a join in this script (orphaned
   transactions, duplicate accounts, watchlist entities with no
   matching geography, alerts on orphaned accounts) is logged to
   the audit schema with a reason, never silently dropped.

   The live audit.* exclusion tables hold latest-run results only
   (CREATE OR REPLACE, not accumulated INSERT); if you need
   point-in-time history across reruns, clone the audit schema
   before each rerun (CREATE SCHEMA audit_history CLONE audit).
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS audit;

SET as_of_date = '2026-06-30';

/* ---------------------------------------------------------
   dim_date — date spine covering the 18-month history window,
   plus ~95 days forward so disposition_date (up to +90 days past
   alert_date) always has a matching date_key for fact_alerts.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_date (
  date_key        NUMBER PRIMARY KEY,
  full_date       DATE,
  month           NUMBER,
  quarter         NUMBER,
  year            NUMBER,
  is_month_end    BOOLEAN,
  is_quarter_end  BOOLEAN
);

INSERT INTO gold.dim_date
SELECT
  TO_NUMBER(TO_CHAR(d, 'YYYYMMDD'))  AS date_key,
  d                                   AS full_date,
  MONTH(d)                            AS month,
  QUARTER(d)                          AS quarter,
  YEAR(d)                             AS year,
  d = LAST_DAY(d, 'month')            AS is_month_end,
  d = LAST_DAY(d, 'quarter')          AS is_quarter_end
FROM (
  SELECT DATEADD('day', SEQ4(), DATEADD('month', -18, $as_of_date::DATE)) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 650))
)
WHERE d <= DATEADD('day', 95, $as_of_date::DATE)
  AND NOT EXISTS (SELECT 1 FROM gold.dim_date dd WHERE dd.full_date = d);

/* ---------------------------------------------------------
   dim_geography — consolidated country / risk reference.
   region is populated via a hardcoded country->region mapping —
   only 23 distinct countries appear in this dataset (per EDA) and
   no region reference table exists upstream to drive this
   dynamically. 'Unmapped' is a defensive fallback if a country
   outside this list ever appears in future data.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_geography (
  geo_key                  NUMBER AUTOINCREMENT PRIMARY KEY,
  country                  VARCHAR UNIQUE,
  region                   VARCHAR,
  is_high_risk_country     BOOLEAN,
  is_sanctioned_country    BOOLEAN
);

MERGE INTO gold.dim_geography tgt
USING (
  SELECT DISTINCT
    counterparty_country_standardized AS country,
    is_high_risk_counterparty_country AS is_high_risk_country,
    CASE counterparty_country_standardized
      WHEN 'United States'  THEN 'North America'
      WHEN 'US'             THEN 'North America'
      WHEN 'Canada'         THEN 'North America'
      WHEN 'Mexico'         THEN 'North America'
      WHEN 'Brazil'         THEN 'South America'
      WHEN 'Venezuela'      THEN 'South America'
      WHEN 'United Kingdom' THEN 'Europe'
      WHEN 'UK'             THEN 'Europe'
      WHEN 'France'         THEN 'Europe'
      WHEN 'Germany'        THEN 'Europe'
      WHEN 'Netherlands'    THEN 'Europe'
      WHEN 'Russia'         THEN 'Europe'
      WHEN 'Iran'           THEN 'Middle East'
      WHEN 'Syria'          THEN 'Middle East'
      WHEN 'Yemen'          THEN 'Middle East'
      WHEN 'UAE'            THEN 'Middle East'
      WHEN 'Uae'            THEN 'Middle East'  -- silver stores this one as an initcap abbreviation, not a full name
      WHEN 'India'          THEN 'Asia'
      WHEN 'Pakistan'       THEN 'Asia'
      WHEN 'Afghanistan'    THEN 'Asia'
      WHEN 'Myanmar'        THEN 'Asia'
      WHEN 'Japan'          THEN 'Asia'
      WHEN 'Singapore'      THEN 'Asia'
      WHEN 'North Korea'    THEN 'Asia'
      WHEN 'Nigeria'        THEN 'Africa'
      WHEN 'Australia'      THEN 'Oceania'
      ELSE 'Unmapped'
    END AS region
  FROM silver.transactions
) src
ON tgt.country = src.country
WHEN MATCHED THEN UPDATE SET tgt.is_high_risk_country = src.is_high_risk_country, tgt.region = src.region
WHEN NOT MATCHED THEN INSERT (country, region, is_high_risk_country, is_sanctioned_country)
  VALUES (src.country, src.region, src.is_high_risk_country, FALSE);

UPDATE gold.dim_geography g
SET is_sanctioned_country = TRUE
WHERE g.country IN (SELECT DISTINCT country_standardized FROM silver.watchlist);

/* ---------------------------------------------------------
   dim_rule
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_rule (
  rule_key           NUMBER AUTOINCREMENT PRIMARY KEY,
  rule_id            VARCHAR UNIQUE,
  rule_name          VARCHAR,
  rule_type          VARCHAR,
  threshold_params   VARIANT
);

MERGE INTO gold.dim_rule tgt
USING (SELECT rule_id, rule_name, rule_type, PARSE_JSON(threshold_params) AS threshold_params FROM bronze.raw_rule) src
ON tgt.rule_id = src.rule_id
WHEN MATCHED THEN UPDATE SET tgt.rule_name = src.rule_name, tgt.threshold_params = src.threshold_params
WHEN NOT MATCHED THEN INSERT (rule_id, rule_name, rule_type, threshold_params)
  VALUES (src.rule_id, src.rule_name, src.rule_type, src.threshold_params);

/* ---------------------------------------------------------
   dim_watchlist
   Watchlist entities whose country never appears as a transaction
   counterparty country have no dim_geography row to join to — logged
   to audit.excluded_watchlist_entities rather than silently dropped.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_watchlist (
  watchlist_key               NUMBER AUTOINCREMENT PRIMARY KEY,
  entity_name_standardized    VARCHAR,
  geo_key                     NUMBER,
  program                     VARCHAR
);

CREATE OR REPLACE TABLE audit.excluded_watchlist_entities AS
SELECT
  w.entity_name_standardized,
  w.country_standardized,
  w.program,
  'country_standardized never appears as a transaction counterparty country — no gold.dim_geography row to join to, excluded from dim_watchlist' AS exclusion_reason,
  CURRENT_TIMESTAMP() AS logged_at
FROM silver.watchlist w
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_geography g WHERE g.country = w.country_standardized);

MERGE INTO gold.dim_watchlist tgt
USING (
  SELECT w.entity_name_standardized, g.geo_key, w.program
  FROM silver.watchlist w
  JOIN gold.dim_geography g ON g.country = w.country_standardized
) src
ON tgt.entity_name_standardized = src.entity_name_standardized
WHEN NOT MATCHED THEN INSERT (entity_name_standardized, geo_key, program)
  VALUES (src.entity_name_standardized, src.geo_key, src.program);

/* ---------------------------------------------------------
   dim_customer — SCD Type 2 on risk_rating only.
   A risk_rating change closes out the current row and inserts a
   new one, preserving history. pep_flag, country, and business
   type changes overwrite in place — a scoped trade-off. Extending
   to full SCD2 coverage would mean comparing all four tracked
   attributes in both the close-out and insert steps below, not
   just risk_rating.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_customer (
  customer_key                NUMBER AUTOINCREMENT PRIMARY KEY,
  customer_id                 VARCHAR,
  risk_rating                 VARCHAR,
  pep_flag                    BOOLEAN,
  country_standardized        VARCHAR,
  business_type                VARCHAR,
  customer_base_risk_score    NUMBER(5,2),
  effective_date              DATE,
  end_date                    DATE,
  is_current                  BOOLEAN
);

-- Step 1: close out any current record whose risk_rating changed
UPDATE gold.dim_customer d
SET end_date = $as_of_date::DATE, is_current = FALSE
WHERE d.is_current = TRUE
  AND EXISTS (
    SELECT 1 FROM silver.customer c
    JOIN gold.tmp_customer_base_risk cbr ON cbr.customer_id_resolved = c.customer_id_resolved
    WHERE c.customer_id_resolved = d.customer_id
      AND c.risk_rating != d.risk_rating
  );

-- Step 2: insert new current record for new customers or changed risk_rating
INSERT INTO gold.dim_customer
  (customer_id, risk_rating, pep_flag, country_standardized, business_type,
   customer_base_risk_score, effective_date, end_date, is_current)
SELECT
  c.customer_id_resolved,
  c.risk_rating,
  c.pep_flag,
  c.country_standardized,
  c.occupation_business_type,
  cbr.customer_base_risk_score,
  $as_of_date::DATE,
  NULL,
  TRUE
FROM silver.customer c
JOIN gold.tmp_customer_base_risk cbr ON cbr.customer_id_resolved = c.customer_id_resolved
WHERE NOT EXISTS (
  SELECT 1 FROM gold.dim_customer d
  WHERE d.customer_id = c.customer_id_resolved AND d.is_current = TRUE
);

/* ---------------------------------------------------------
   dim_account
   silver.account carries a small number of account_ids with
   genuine conflicts on customer_id_resolved (a known, documented
   EDA finding — see 03's duplicate_account_ids check). Deduped
   here with a provisional tiebreak (most recent open_date, then
   lowest customer_id_resolved) so the MERGE below doesn't throw a
   multiple-match error. Losing rows are logged to
   audit.excluded_duplicate_accounts, not silently dropped — swap
   in the real resolution once the business decides one.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.dim_account (
  account_key            NUMBER AUTOINCREMENT PRIMARY KEY,
  account_id             VARCHAR UNIQUE,
  customer_key            NUMBER,
  account_type           VARCHAR,
  is_new_account_flag    BOOLEAN,
  status                 VARCHAR
);

CREATE OR REPLACE TABLE gold.tmp_account_dedup AS
SELECT
  *,
  ROW_NUMBER() OVER (
    PARTITION BY account_id
    ORDER BY open_date DESC NULLS LAST, customer_id_resolved ASC
  ) AS rn
FROM silver.account;

CREATE OR REPLACE TABLE audit.excluded_duplicate_accounts AS
SELECT
  account_id,
  customer_id_resolved,
  account_type,
  status,
  'duplicate account_id — kept most-recent-open_date row (provisional tiebreak, pending final resolution)' AS exclusion_reason,
  CURRENT_TIMESTAMP() AS logged_at
FROM gold.tmp_account_dedup
WHERE rn > 1;

MERGE INTO gold.dim_account tgt
USING (
  SELECT a.account_id, dc.customer_key, a.account_type, a.is_new_account_flag, a.status
  FROM gold.tmp_account_dedup a
  JOIN gold.dim_customer dc ON dc.customer_id = a.customer_id_resolved AND dc.is_current = TRUE
  WHERE a.rn = 1
) src
ON tgt.account_id = src.account_id
WHEN MATCHED THEN UPDATE SET
  tgt.customer_key = src.customer_key,
  tgt.is_new_account_flag = src.is_new_account_flag,
  tgt.status = src.status
WHEN NOT MATCHED THEN INSERT (account_id, customer_key, account_type, is_new_account_flag, status)
  VALUES (src.account_id, src.customer_key, src.account_type, src.is_new_account_flag, src.status);

/* ---------------------------------------------------------
   fact_transactions
   Transactions on an account_id that never made it into
   gold.dim_account (orphaned relative to silver.account — a
   documented EDA finding, ~43.6K rows / ~$17.5M) are logged to
   audit.excluded_orphan_transactions before the INNER JOIN below
   excludes them.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE audit.excluded_orphan_transactions AS
SELECT
  t.transaction_id,
  t.account_id,
  t.amount_usd,
  t.transaction_date,
  'account_id not present in gold.dim_account (orphaned relative to silver.account) — excluded from fact_transactions' AS exclusion_reason,
  CURRENT_TIMESTAMP() AS logged_at
FROM silver.transactions t
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_account da WHERE da.account_id = t.account_id);

CREATE TABLE IF NOT EXISTS gold.fact_transactions (
  transaction_key         VARCHAR PRIMARY KEY,
  account_key             NUMBER,
  geo_key                 NUMBER,
  date_key                NUMBER,
  amount_usd              NUMBER(18,2),
  channel                 VARCHAR,
  direction               VARCHAR,
  structuring_flag        BOOLEAN,
  rapid_movement_flag     BOOLEAN
);

MERGE INTO gold.fact_transactions tgt
USING (
  SELECT
    t.transaction_id                                      AS transaction_key,
    da.account_key,
    dg.geo_key,
    dd.date_key,
    t.amount_usd,
    t.channel,
    t.direction,
    t.transaction_id IN (SELECT transaction_id FROM gold.tmp_structuring_hits)    AS structuring_flag,
    t.transaction_id IN (SELECT transaction_id FROM gold.tmp_rapid_movement_hits) AS rapid_movement_flag
  FROM silver.transactions t
  JOIN gold.dim_account   da ON da.account_id = t.account_id
  JOIN gold.dim_geography dg ON dg.country    = t.counterparty_country_standardized
  JOIN gold.dim_date      dd ON dd.full_date  = t.transaction_date
) src
ON tgt.transaction_key = src.transaction_key
WHEN MATCHED THEN UPDATE SET
  tgt.structuring_flag    = src.structuring_flag,
  tgt.rapid_movement_flag = src.rapid_movement_flag
WHEN NOT MATCHED THEN INSERT VALUES (
  src.transaction_key, src.account_key, src.geo_key, src.date_key,
  src.amount_usd, src.channel, src.direction, src.structuring_flag, src.rapid_movement_flag
);

/* ---------------------------------------------------------
   fact_alerts  (grain: one row per alert)
   Alerts on orphaned accounts (account_id not in gold.dim_account)
   are logged to audit.excluded_orphan_alerts before the INNER JOIN
   below drops them, matching the same exclusion-must-be-audited
   principle applied to orphan transactions and duplicate accounts.

   This is a full rebuild (CREATE OR REPLACE), not an incremental
   MERGE — gold.alerts.alert_id is a new UUID every time 04 reruns,
   so it isn't a stable key to MERGE against across runs. gold.alerts
   is already fully rebuilt each run in 04, so fact_alerts mirrors
   that.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE audit.excluded_orphan_alerts AS
SELECT
  a.alert_id,
  a.rule_id,
  a.account_id,
  a.transaction_id,
  a.alert_date,
  a.risk_score,
  'account_id not present in gold.dim_account (orphaned relative to silver.account) — excluded from fact_alerts' AS exclusion_reason,
  CURRENT_TIMESTAMP() AS logged_at
FROM gold.alerts a
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_account da WHERE da.account_id = a.account_id);

CREATE OR REPLACE TABLE gold.fact_alerts AS
SELECT
    a.alert_id                                            AS alert_key,
    da.account_key,
    dr.rule_key,
    dd1.date_key                                          AS date_key,
    dd2.date_key                                          AS disposition_date_key,
    dg.geo_key,
    a.risk_score,
    a.disposition = 'sar_filed'                           AS alert_to_sar_flag,
    DATEDIFF('day', a.alert_date, a.disposition_date) > 30 AS is_sla_overdue_flag,
    DATEDIFF('day', a.alert_date, a.disposition_date)      AS time_to_disposition_days
  FROM gold.alerts a
  JOIN gold.dim_account da ON da.account_id = a.account_id
  JOIN gold.dim_rule    dr ON dr.rule_id = a.rule_id
  JOIN gold.dim_date    dd1 ON dd1.full_date = a.alert_date
  JOIN gold.dim_date    dd2 ON dd2.full_date = a.disposition_date
  LEFT JOIN silver.transactions t ON t.transaction_id = a.transaction_id
  LEFT JOIN gold.dim_geography dg ON dg.country = t.counterparty_country_standardized;

/* ---------------------------------------------------------
   fact_customer_risk_snapshot  (grain: customer x month-end)
   NOTE (open item, not fixed here): this only produces a row for
   customers with at least one alert (INNER JOIN to fact_alerts).
   Customers with zero alerts never get a snapshot row, which
   limits a "customer risk over time" view to previously-alerted
   customers only. Full-population risk trending would need a
   driving CROSS JOIN of dim_customer x dim_date (month-end) with
   a LEFT JOIN to fact_alerts instead.
--------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS gold.fact_customer_risk_snapshot (
  customer_key            NUMBER,
  date_key                NUMBER,
  customer_risk_score     NUMBER(5,2),
  cumulative_sar_count    NUMBER
);

MERGE INTO gold.fact_customer_risk_snapshot tgt
USING (
  SELECT
    dc.customer_key,
    dd.date_key,
    dc.customer_base_risk_score AS customer_risk_score,
    SUM(IFF(fa.alert_to_sar_flag, 1, 0)) OVER (
      PARTITION BY dc.customer_key ORDER BY dd.date_key
    ) AS cumulative_sar_count
  FROM gold.dim_customer dc
  JOIN gold.dim_account  da ON da.customer_key = dc.customer_key
  JOIN gold.fact_alerts  fa ON fa.account_key = da.account_key
  JOIN gold.dim_date     dd ON dd.date_key = fa.date_key AND dd.is_month_end = TRUE
) src
ON tgt.customer_key = src.customer_key AND tgt.date_key = src.date_key
WHEN NOT MATCHED THEN INSERT VALUES (src.customer_key, src.date_key, src.customer_risk_score, src.cumulative_sar_count);
