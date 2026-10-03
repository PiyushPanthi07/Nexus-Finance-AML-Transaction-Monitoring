/* ============================================================
   02_SILVER_CLEANSE_ENRICH.SQL
   Layer   : SILVER
   Purpose : Clean, standardize, and enrich bronze -> silver.
             No detection / business logic here — that lives entirely
             in the gold rule engine (04). This script only fixes
             data quality and derives generic fields any downstream
             consumer would need (typed columns, standardized
             categories, entity resolution, rolling velocity metrics).

   Every bronze column lands as TEXT, so every field is explicitly
   cast here with TRY_TO_* functions rather than relying on implicit
   conversion inside later aggregates or window functions. Each cast
   is paired with an "is_<field>_unparseable" flag so bad source data
   is visible instead of silently becoming NULL.
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS silver;

SET as_of_date = '2026-06-30';  -- fixed analysis anchor for this dataset

/* ---------------------------------------------------------
   Bronze customer, typed
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.tmp_customer_typed AS
SELECT
  customer_id,
  TRIM(full_name)                                            AS full_name,
  TRY_TO_DATE(dob)                                           AS dob,
  dob IS NOT NULL AND TRY_TO_DATE(dob) IS NULL                AS is_dob_unparseable,
  TRIM(ssn_id_number)                                        AS ssn_id_number,
  TRIM(country)                                              AS country_raw,
  TRIM(occupation_business_type)                             AS occupation_business_type,
  TRY_TO_BOOLEAN(pep_flag)                                   AS pep_flag,
  pep_flag IS NOT NULL AND TRY_TO_BOOLEAN(pep_flag) IS NULL   AS is_pep_flag_unparseable,
  TRIM(risk_rating)                                          AS risk_rating,
  TRY_TO_DATE(onboarding_date)                               AS onboarding_date,
  TRY_TO_DATE(kyc_review_date)                               AS kyc_review_date
FROM bronze.raw_customer;

/* ---------------------------------------------------------
   Entity resolution map
   Deterministic version: groups by normalized name + DOB. A
   production system would use a fuzzy-match library (e.g.
   Jaro-Winkler via a UDF) — this keeps the concept demonstrable
   in plain SQL for a portfolio project.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.customer_entity_map AS
SELECT
  customer_id,
  MIN(customer_id) OVER (
    PARTITION BY UPPER(REGEXP_REPLACE(full_name, '[^A-Za-z]', '')), dob
  ) AS customer_id_resolved
FROM silver.tmp_customer_typed;

/* ---------------------------------------------------------
   silver.customer
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.customer AS
SELECT
  m.customer_id_resolved,
  LISTAGG(DISTINCT c.customer_id, ';') WITHIN GROUP (ORDER BY c.customer_id) AS customer_id_raw_list,
  MIN(c.full_name)                                                            AS full_name_standardized,
  MIN(c.dob)                                                                  AS dob,
  BOOLOR_AGG(c.is_dob_unparseable)                                            AS is_dob_unparseable,
  DATEDIFF('year', MIN(c.dob), $as_of_date::DATE)                             AS age_years,
  MIN(c.ssn_id_number)                                                        AS ssn_id_number,
  MIN(c.ssn_id_number) IS NOT NULL
    AND MIN(c.ssn_id_number) RLIKE '^[0-9]{3}-[0-9]{2}-[0-9]{4}$'             AS is_id_format_valid,
  CASE
    WHEN UPPER(MIN(c.country_raw)) IN ('UK','ENGLAND','BRITAIN','UNITED KINGDOM') THEN 'UK'
    WHEN UPPER(MIN(c.country_raw)) IN ('US','USA','U.S.A.','UNITED STATES')       THEN 'US'
    ELSE INITCAP(MIN(c.country_raw))
  END                                                                          AS country_standardized,
  MIN(c.occupation_business_type)                                             AS occupation_business_type,
  MIN(c.occupation_business_type) IS NULL                                     AS is_business_type_missing,
  BOOLOR_AGG(c.pep_flag)                                                       AS pep_flag,
  BOOLOR_AGG(c.is_pep_flag_unparseable)                                       AS is_pep_flag_unparseable,
  MIN(c.risk_rating)                                                          AS risk_rating,
  MIN(c.onboarding_date)                                                      AS onboarding_date,
  MIN(c.kyc_review_date)                                                      AS kyc_review_date
FROM silver.tmp_customer_typed c
JOIN silver.customer_entity_map m ON m.customer_id = c.customer_id
GROUP BY m.customer_id_resolved;

/* ---------------------------------------------------------
   silver.account
   NOTE: raw_account.account_type contains a small number of
   'ach' / 'card' / 'wire' values alongside the expected
   'checking' / 'savings' — that overlap with CHANNEL values looks
   like injected dirty data rather than a real account-type
   taxonomy. It is left as-is here and asserted against an
   expected value set in 03_validation_bronze_to_silver.sql
   (flagged as a known, non-fatal WARN) rather than silently
   corrected, so the audit trail stays honest about what the
   source data actually contains.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.account AS
SELECT
  a.account_id,
  m.customer_id_resolved,
  LOWER(TRIM(a.account_type))                                            AS account_type,
  TRY_TO_DATE(a.open_date)                                                AS open_date,
  a.open_date IS NOT NULL AND TRY_TO_DATE(a.open_date) IS NULL            AS is_open_date_unparseable,
  DATEDIFF('day', TRY_TO_DATE(a.open_date), $as_of_date::DATE)            AS account_age_days,
  DATEDIFF('day', TRY_TO_DATE(a.open_date), $as_of_date::DATE) < 90       AS is_new_account_flag,
  LOWER(TRIM(a.status))                                                  AS status
FROM bronze.raw_account a
JOIN silver.customer_entity_map m ON m.customer_id = a.customer_id;

/* ---------------------------------------------------------
   silver.watchlist
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.watchlist AS
SELECT
  watchlist_id,
  UPPER(TRIM(entity_name))   AS entity_name_standardized,
  LOWER(TRIM(entity_type))   AS entity_type,
  CASE
    WHEN UPPER(TRIM(country)) IN ('UK','ENGLAND','BRITAIN','UNITED KINGDOM') THEN 'UK'
    WHEN UPPER(TRIM(country)) IN ('US','USA','U.S.A.','UNITED STATES')      THEN 'US'
    ELSE INITCAP(TRIM(country))
  END                        AS country_standardized,
  TRIM(program)              AS program,
  TRY_TO_DATE(list_date)     AS list_date
FROM bronze.raw_watchlist;

/* ---------------------------------------------------------
   Reference: high-risk country list, sourced from the watchlist
   (OFAC/SDN countries) — the realistic production source for
   "high risk or sanctioned" geography, and the source the gold
   rule engine (04) reads for its high-risk-country rule.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.tmp_high_risk_countries AS
SELECT DISTINCT country_standardized AS country
FROM silver.watchlist;

/* ---------------------------------------------------------
   silver.transactions
   All CTR / structuring / rapid-movement threshold logic is
   intentionally NOT here — those live solely in the gold rule
   engine (04), reading thresholds dynamically from
   bronze.raw_rule. This layer only types, standardizes, and
   derives generic account-level velocity metrics that any rule
   (or any other future consumer) could use.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE silver.tmp_transactions_typed AS
SELECT
  t.transaction_id,
  t.account_id,
  t.counterparty_id,
  TRIM(t.counterparty_name)                                                  AS counterparty_name,
  CASE
    WHEN UPPER(TRIM(t.counterparty_country)) IN ('UK','ENGLAND','BRITAIN','UNITED KINGDOM') THEN 'UK'
    WHEN UPPER(TRIM(t.counterparty_country)) IN ('US','USA','U.S.A.','UNITED STATES')       THEN 'US'
    ELSE INITCAP(TRIM(t.counterparty_country))
  END                                                                        AS counterparty_country_standardized,
  TRY_TO_DECIMAL(t.amount, 18, 2)                                            AS amount_usd,
  t.amount IS NOT NULL AND TRY_TO_DECIMAL(t.amount, 18, 2) IS NULL           AS is_amount_unparseable,
  UPPER(TRIM(t.channel))                                                     AS channel,   -- collapses ACH/ach etc.
  LOWER(TRIM(t.direction))                                                   AS direction,
  TRY_TO_TIMESTAMP_NTZ(t.transaction_timestamp)                              AS transaction_timestamp,
  t.transaction_timestamp IS NOT NULL
    AND TRY_TO_TIMESTAMP_NTZ(t.transaction_timestamp) IS NULL                AS is_txn_timestamp_unparseable
FROM bronze.raw_transactions t;

CREATE OR REPLACE TABLE silver.transactions AS
SELECT
  t.transaction_id,
  t.account_id,
  t.counterparty_id,
  t.counterparty_name,
  t.counterparty_country_standardized,
  t.amount_usd,                                    -- placeholder: join an FX table here if multi-currency
  t.is_amount_unparseable,
  t.channel,
  t.direction,
  t.transaction_timestamp,
  t.is_txn_timestamp_unparseable,
  t.transaction_timestamp::DATE                                                          AS transaction_date,
  SUM(t.amount_usd) OVER (
    PARTITION BY t.account_id ORDER BY t.transaction_timestamp
    RANGE BETWEEN INTERVAL '7 DAYS' PRECEDING AND CURRENT ROW
  )                                                                                        AS rolling_7day_txn_sum,
  COUNT(*) OVER (
    PARTITION BY t.account_id ORDER BY t.transaction_timestamp
    RANGE BETWEEN INTERVAL '7 DAYS' PRECEDING AND CURRENT ROW
  )                                                                                        AS txn_count_velocity_7day,
  DATEDIFF('day',
    LAG(t.transaction_timestamp) OVER (PARTITION BY t.account_id ORDER BY t.transaction_timestamp),
    t.transaction_timestamp)                                                              AS days_since_last_txn,
  hrc.country IS NOT NULL                                                                 AS is_high_risk_counterparty_country
FROM silver.tmp_transactions_typed t
LEFT JOIN silver.tmp_high_risk_countries hrc
  ON hrc.country = t.counterparty_country_standardized;

/* NOTE: silver.alerts does not exist. Alerts are generated by the rule
   engine (04_gold_rule_engine.sql), which reads FROM silver.transactions /
   silver.customer / silver.account — not the other way around. */
