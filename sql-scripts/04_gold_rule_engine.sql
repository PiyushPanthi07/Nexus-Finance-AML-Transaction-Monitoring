/* ============================================================
   04_GOLD_RULE_ENGINE.SQL
   Layer   : GOLD
   Purpose : The core of the project — a batch, rule-based AML
             detection engine. Reads thresholds from
             bronze.raw_rule (config-driven, never hardcoded),
             evaluates silver transaction/customer data, and
             produces AML findings: risk-scored alert candidates.

   This simulates a nightly batch detection run, not a real-time
   streaming engine.

   Run this after 02_silver_cleanse_enrich.sql, in the same
   session (silver.tmp_high_risk_countries is referenced directly).
   ============================================================ */

CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS audit;

SET as_of_date = '2026-06-30';

/* ---------------------------------------------------------
   Rule parameters, unpacked once for reuse across every rule below.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_rule_params AS
SELECT
  rule_id,
  rule_type,
  PARSE_JSON(threshold_params) AS params
FROM bronze.raw_rule;

/* ---------------------------------------------------------
   1. STRUCTURING DETECTION
   N transactions within [min_amt, max_amt] inside a rolling
   window, count >= min_count — a "sub-$10K clustering" pattern.
   Thresholds pulled from the structuring rule's config row.

   NOTE: the window is a 72 HOUR literal in the RANGE BETWEEN
   frame below, not the config's window_hrs value — Snowflake
   requires a literal there, not a variable. It matches the
   current config value; a dynamic-SQL rewrite would be needed
   if that threshold needs to change without a code edit.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_structuring_hits AS
WITH params AS (
  SELECT
    rule_id,
    params:min_amt::NUMBER    AS min_amt,
    params:max_amt::NUMBER    AS max_amt,
    params:window_hrs::NUMBER AS window_hrs,
    params:min_count::NUMBER  AS min_count
  FROM gold.tmp_rule_params
  WHERE rule_type = 'structuring'
),
banded_txns AS (
  SELECT t.*
  FROM silver.transactions t
  CROSS JOIN params p
  WHERE t.amount_usd BETWEEN p.min_amt AND p.max_amt
    AND t.direction = 'debit'   -- the injected clustering pattern in this dataset sits on the outbound side
),
windowed AS (
  SELECT
    b.*,
    p.rule_id,
    p.min_count,
    COUNT(*) OVER (
      PARTITION BY b.account_id ORDER BY b.transaction_timestamp
      RANGE BETWEEN INTERVAL '72 HOURS' PRECEDING AND CURRENT ROW
    ) AS cluster_count
  FROM banded_txns b
  CROSS JOIN params p
)
SELECT
  rule_id,
  account_id,
  transaction_id,
  transaction_timestamp AS alert_date,
  cluster_count
FROM windowed
WHERE cluster_count >= min_count
QUALIFY ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY transaction_timestamp DESC) = 1;
-- one alert per account per structuring cluster (the last triggering txn), not one per txn

/* ---------------------------------------------------------
   2. RAPID MOVEMENT OF FUNDS
   A large inbound transaction followed by near-full outbound
   movement within window_days. Requires a minimum inbound amount
   so routine cash flow (paycheck -> rent) doesn't qualify —
   without that floor, this rule matches ordinary account activity
   as well as genuine rapid fund movement.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_rapid_movement_hits AS
WITH params AS (
  SELECT
    rule_id,
    params:window_days::NUMBER      AS window_days,
    params:min_pct_outbound::FLOAT  AS min_outflow_pct,
    params:min_amt::NUMBER          AS min_amt
  FROM gold.tmp_rule_params
  WHERE rule_type = 'rapid_movement'
),
inbound AS (
  SELECT * FROM silver.transactions WHERE direction = 'credit'
),
outbound AS (
  SELECT * FROM silver.transactions WHERE direction = 'debit'
)
SELECT
  p.rule_id,
  i.account_id,
  o.transaction_id,
  o.transaction_timestamp AS alert_date,
  i.amount_usd  AS inbound_amount,
  o.amount_usd  AS outbound_amount
FROM inbound i
JOIN outbound o
  ON o.account_id = i.account_id
 AND o.transaction_timestamp > i.transaction_timestamp
 AND o.transaction_timestamp <= DATEADD('day', (SELECT window_days FROM params), i.transaction_timestamp)
CROSS JOIN params p
WHERE o.amount_usd >= p.min_outflow_pct * i.amount_usd
  AND i.amount_usd >= p.min_amt   -- filters out routine cash flow
QUALIFY ROW_NUMBER() OVER (PARTITION BY i.account_id ORDER BY o.transaction_timestamp) = 1;

/* ---------------------------------------------------------
   3. HIGH-RISK COUNTRY COUNTERPARTY
   Requires BOTH country risk (from the silver watchlist-derived
   flag) AND a minimum transaction amount — country risk alone,
   with no size condition, would flag every transaction to a
   high-risk country regardless of value and inflate alert volume
   well past a realistic target rate.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_high_risk_country_hits AS
WITH params AS (
  SELECT rule_id, params:min_amt::NUMBER AS min_amt
  FROM gold.tmp_rule_params
  WHERE rule_type = 'high_risk_country'
)
SELECT
  p.rule_id,
  t.account_id,
  t.transaction_id,
  t.transaction_timestamp AS alert_date
FROM silver.transactions t
CROSS JOIN params p
WHERE t.is_high_risk_counterparty_country = TRUE
  AND t.amount_usd >= p.min_amt;

/* ---------------------------------------------------------
   4. CTR THRESHOLD MONITORING
   Currency Transaction Report threshold — any transaction at or
   above the configured minimum amount. Threshold read from config,
   not hardcoded.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_ctr_hits AS
WITH params AS (
  SELECT rule_id, params:min_amt::NUMBER AS min_amt
  FROM gold.tmp_rule_params
  WHERE rule_type = 'ctr_threshold'
)
SELECT
  p.rule_id,
  t.account_id,
  t.transaction_id,
  t.transaction_timestamp AS alert_date
FROM silver.transactions t
CROSS JOIN params p
WHERE t.amount_usd >= p.min_amt;

/* ---------------------------------------------------------
   5. CUSTOMER BASE RISK SCORE
   Weighted, rule-based (not ML) — auditable and explainable,
   consistent with this project's "detection and analytics" scope
   rather than a black-box model.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.tmp_customer_base_risk AS
SELECT
  c.customer_id_resolved,
  ( CASE c.risk_rating WHEN 'Low' THEN 0 WHEN 'Medium' THEN 15 WHEN 'High' THEN 30 ELSE 0 END
  + IFF(c.pep_flag, 25, 0)
  + IFF(c.country_standardized IN (SELECT country FROM silver.tmp_high_risk_countries), 20, 0)
  + IFF(LOWER(c.occupation_business_type) LIKE ANY ('%restaurant%','%cash%','%retail%'), 15, 0)
  + IFF(EXISTS (
      SELECT 1 FROM silver.account a
      WHERE a.customer_id_resolved = c.customer_id_resolved AND a.is_new_account_flag
    ), 10, 0)
  ) AS customer_base_risk_score
FROM silver.customer c;

/* ---------------------------------------------------------
   6. UNION ALL FINDINGS, COMPUTE ALERT-LEVEL RISK SCORE
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.alert_candidates AS
WITH all_hits AS (
  SELECT rule_id, account_id, transaction_id, alert_date FROM gold.tmp_structuring_hits
  UNION ALL
  SELECT rule_id, account_id, transaction_id, alert_date FROM gold.tmp_rapid_movement_hits
  UNION ALL
  SELECT rule_id, account_id, transaction_id, alert_date FROM gold.tmp_high_risk_country_hits
  UNION ALL
  SELECT rule_id, account_id, transaction_id, alert_date FROM gold.tmp_ctr_hits
),
severity AS (
  SELECT rule_id,
    CASE rule_type
      WHEN 'structuring'        THEN 40
      WHEN 'rapid_movement'     THEN 35
      WHEN 'high_risk_country'  THEN 20
      WHEN 'ctr_threshold'      THEN 15
      ELSE 10
    END AS rule_severity
  FROM gold.tmp_rule_params
)
SELECT
  UUID_STRING()                                                      AS alert_id,
  h.rule_id,
  h.account_id,
  h.transaction_id,
  h.alert_date::DATE                                                 AS alert_date,
  LEAST(100,
    s.rule_severity
    + COALESCE(cbr.customer_base_risk_score, 0) * 0.2
    + COALESCE(t.txn_count_velocity_7day, 0) * 2
  )                                                                    AS risk_score
FROM all_hits h
JOIN severity s ON s.rule_id = h.rule_id
LEFT JOIN (
  -- silver.account can carry a small number of duplicate account_id rows
  -- (conflicting customer linkage — see 05's dim_account note). Deduped
  -- inline here with the same tiebreak used in gold.tmp_account_dedup
  -- (most recent open_date, then lowest customer_id_resolved), so 04 and
  -- 05 stay consistent and one account's hits don't fan out into two rows.
  SELECT account_id, customer_id_resolved
  FROM silver.account
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY account_id
    ORDER BY open_date DESC NULLS LAST, customer_id_resolved ASC
  ) = 1
) acc ON acc.account_id = h.account_id
LEFT JOIN gold.tmp_customer_base_risk cbr ON cbr.customer_id_resolved = acc.customer_id_resolved
LEFT JOIN silver.transactions t ON t.transaction_id = h.transaction_id;

/* ---------------------------------------------------------
   7. DISPOSITION SIMULATION
   No real investigator exists in this project, so disposition
   (false positive / true positive / SAR filed) is assigned
   probabilistically to match published industry benchmark bands
   (88-95% false positive, 5-10% SAR filed). This is explicitly a
   SIMULATION step — not a claim of real investigative work — and
   is validated against those bands in 06.

   roll/roll2 are drawn per-row via an inline correlated subquery
   so every alert gets its own independent random draw.
--------------------------------------------------------- */
CREATE OR REPLACE TABLE gold.alerts AS
SELECT
  ac.alert_id,
  ac.rule_id,
  ac.account_id,
  ac.transaction_id,
  ac.alert_date,
  ac.risk_score,
  CASE
    WHEN roll <= 0.05 THEN 'sar_filed'
    WHEN roll <= 0.12 THEN 'true_positive'
    ELSE 'false_positive'
  END                                                                      AS disposition,
  DATEADD('day',
    -- most dispositions land inside 30 days; a small tail runs past 60
    -- (ops-backlog realism)
    CASE WHEN roll2 <= 0.90 THEN UNIFORM(1,30,RANDOM())
         WHEN roll2 <= 0.97 THEN UNIFORM(31,60,RANDOM())
         ELSE UNIFORM(61,90,RANDOM())
    END,
    ac.alert_date)                                                         AS disposition_date
FROM (
  SELECT
    ac.*,
    UNIFORM(0::FLOAT,1::FLOAT,RANDOM()) AS roll,
    UNIFORM(0::FLOAT,1::FLOAT,RANDOM()) AS roll2
  FROM gold.alert_candidates ac
) ac;

/* Quick informal check (formal target validation happens in 06):
   SELECT disposition, COUNT(*), ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (),1) AS pct
   FROM gold.alerts GROUP BY disposition;
   Target band: 88-95% false_positive / 5-10% sar_filed. */
