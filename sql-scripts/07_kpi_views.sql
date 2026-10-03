/* ============================================================
   07_KPI_VIEWS.SQL
   Layer   : GOLD / BI
   Purpose : Pure aggregation layer answering the core business
             questions. Tableau connects to these views directly.
             No new business logic here — every field already
             exists in gold.

   Design notes that explain a few non-obvious choices below:
     - Fact tables are pre-aggregated in their own CTE before being
       joined to a shared dimension (dim_date, dim_geography). Joining
       two fact tables directly to the same dimension key in one query
       causes row fan-out before COUNT(DISTINCT) can collapse it,
       which both inflates intermediate row counts and hurts runtime.
     - alert_count can exceed transaction_count where multiple rules
       fire on one transaction, so rate columns are named
       "alerts_per_100_x" rather than "alert_rate_pct" — a value that
       can exceed 100 is a misleading label on what reads as a 0-100%
       axis.
   ============================================================ */

/* =========== DASHBOARD 1 — Compliance Executive Overview =========== */

CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_alert_funnel AS
WITH txn_agg AS (
  SELECT date_key,
         COUNT(DISTINCT transaction_key) AS transaction_count
  FROM NEXUS_FINANCE.GOLD.fact_transactions
  GROUP BY date_key
),
alert_agg AS (
  SELECT date_key,
         COUNT(DISTINCT alert_key)        AS alert_count,
         SUM(IFF(alert_to_sar_flag,1,0))  AS sar_count
  FROM NEXUS_FINANCE.GOLD.fact_alerts
  GROUP BY date_key
)
SELECT
  dd.year, dd.month,
  SUM(COALESCE(ta.transaction_count,0))                                                     AS transaction_count,
  SUM(COALESCE(aa.alert_count,0))                                                            AS alert_count,
  SUM(COALESCE(aa.sar_count,0))                                                              AS sar_count,
  ROUND(100.0 * SUM(COALESCE(aa.sar_count,0)) / NULLIF(SUM(COALESCE(aa.alert_count,0)),0), 2) AS alert_to_sar_conversion_pct,
  ROUND(SUM(COALESCE(ta.transaction_count,0)) / NULLIF(SUM(COALESCE(aa.alert_count,0)),0), 0)  AS transaction_to_alert_ratio
FROM NEXUS_FINANCE.GOLD.dim_date dd
LEFT JOIN txn_agg   ta ON ta.date_key = dd.date_key
LEFT JOIN alert_agg aa ON aa.date_key = dd.date_key
GROUP BY dd.year, dd.month
ORDER BY dd.year, dd.month;

-- Filters to disposed alerts whose disposition_date has already happened as of
-- query time. Every alert has a pre-assigned disposition_date (disposition can
-- land up to 90 days after alert_date), so without this filter, months that
-- haven't happened yet show up with tiny, unrepresentative sample sizes and an
-- artificially low compliance %. Uses CURRENT_DATE() so the cutoff always
-- reflects whenever the view is queried, not a hardcoded date.
CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_sla_compliance AS
SELECT
  dd.year, dd.month,
  COUNT(*)                                                              AS disposed_alert_count,
  SUM(IFF(fa.is_sla_overdue_flag, 1, 0))                                AS overdue_count,
  ROUND(100.0 * SUM(IFF(NOT fa.is_sla_overdue_flag,1,0)) / COUNT(*), 2) AS sla_compliance_pct,
  ROUND(AVG(fa.time_to_disposition_days), 1)                            AS avg_days_to_disposition
FROM NEXUS_FINANCE.GOLD.fact_alerts fa
JOIN NEXUS_FINANCE.GOLD.dim_date dd ON dd.date_key = fa.disposition_date_key
WHERE fa.disposition_date_key <= TO_NUMBER(TO_VARCHAR(CURRENT_DATE(), 'YYYYMMDD'))
GROUP BY dd.year, dd.month
ORDER BY dd.year, dd.month;

CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_disposition_breakdown AS
SELECT
  dr.rule_name,
  COUNT(*)                              AS alert_count,
  SUM(IFF(fa.alert_to_sar_flag, 1, 0))  AS sar_count
FROM NEXUS_FINANCE.GOLD.fact_alerts fa
JOIN NEXUS_FINANCE.GOLD.dim_rule dr ON dr.rule_key = fa.rule_key
GROUP BY dr.rule_name;

/* =========== DASHBOARD 2 — Rule Performance & Tuning =========== */

CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_rule_performance AS
SELECT
  dr.rule_id,
  dr.rule_name,
  dr.rule_type,
  COUNT(*)                                                                          AS alert_count,
  ROUND(100.0 * SUM(IFF(fa.alert_to_sar_flag = FALSE AND NOT EXISTS (
        SELECT 1 FROM NEXUS_FINANCE.GOLD.alerts sa
        WHERE sa.alert_id = fa.alert_key AND sa.disposition = 'true_positive'
      ),1,0)) / COUNT(*), 2)                                                        AS false_positive_rate_pct,
  ROUND(100.0 * SUM(IFF(fa.alert_to_sar_flag,1,0)) / COUNT(*), 2)                    AS sar_conversion_rate_pct,
  ROUND(AVG(fa.risk_score), 1)                                                       AS avg_risk_score,
  ROUND(AVG(fa.time_to_disposition_days), 1)                                        AS avg_time_to_disposition_days
FROM NEXUS_FINANCE.GOLD.fact_alerts fa
JOIN NEXUS_FINANCE.GOLD.dim_rule dr ON dr.rule_key = fa.rule_key
GROUP BY dr.rule_id, dr.rule_name, dr.rule_type
ORDER BY false_positive_rate_pct DESC;

-- total_active_accounts = every account with any transaction (the active
-- account base). accounts_with_structuring_pattern / total_active_accounts
-- is the structuring prevalence rate the dashboard actually plots.
CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_structuring_detection_hit_rate AS
SELECT
  COUNT(DISTINCT ft.account_key)                                    AS total_active_accounts,
  COUNT(DISTINCT IFF(ft.structuring_flag, ft.account_key, NULL))    AS accounts_with_structuring_pattern
FROM NEXUS_FINANCE.GOLD.fact_transactions ft;

/* =========== DASHBOARD 3 — Geographic & Risk Segmentation =========== */

CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_geo_risk_summary AS
WITH txn_agg AS (
  SELECT geo_key,
         COUNT(DISTINCT transaction_key) AS transaction_count
  FROM NEXUS_FINANCE.GOLD.fact_transactions
  GROUP BY geo_key
),
alert_agg AS (
  SELECT geo_key,
         COUNT(DISTINCT alert_key) AS alert_count
  FROM NEXUS_FINANCE.GOLD.fact_alerts
  GROUP BY geo_key
)
SELECT
  dg.country,
  dg.region,
  dg.is_high_risk_country,
  dg.is_sanctioned_country,
  COALESCE(ta.transaction_count,0) AS transaction_count,
  COALESCE(aa.alert_count,0)       AS alert_count,
  ROUND(100.0 * COALESCE(aa.alert_count,0) / NULLIF(COALESCE(ta.transaction_count,0),0), 2) AS alerts_per_100_txn
FROM NEXUS_FINANCE.GOLD.dim_geography dg
LEFT JOIN txn_agg   ta ON ta.geo_key = dg.geo_key
LEFT JOIN alert_agg aa ON aa.geo_key = dg.geo_key
ORDER BY alerts_per_100_txn DESC NULLS LAST;

-- region-level rollup, for a dashboard view that starts at region and drills
-- into country rather than listing all 23 countries flat
CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_geo_region_summary AS
WITH txn_agg AS (
  SELECT geo_key,
         COUNT(DISTINCT transaction_key) AS transaction_count
  FROM NEXUS_FINANCE.GOLD.fact_transactions
  GROUP BY geo_key
),
alert_agg AS (
  SELECT geo_key,
         COUNT(DISTINCT alert_key) AS alert_count
  FROM NEXUS_FINANCE.GOLD.fact_alerts
  GROUP BY geo_key
)
SELECT
  dg.region,
  COUNT(DISTINCT dg.geo_key)                                                                 AS country_count,
  SUM(IFF(dg.is_high_risk_country, 1, 0))                                                     AS high_risk_country_count,
  SUM(COALESCE(ta.transaction_count,0))                                                        AS transaction_count,
  SUM(COALESCE(aa.alert_count,0))                                                              AS alert_count,
  ROUND(100.0 * SUM(COALESCE(aa.alert_count,0)) / NULLIF(SUM(COALESCE(ta.transaction_count,0)),0), 2) AS alerts_per_100_txn
FROM NEXUS_FINANCE.GOLD.dim_geography dg
LEFT JOIN txn_agg   ta ON ta.geo_key = dg.geo_key
LEFT JOIN alert_agg aa ON aa.geo_key = dg.geo_key
GROUP BY dg.region
ORDER BY alerts_per_100_txn DESC NULLS LAST;

-- LEFT JOIN dim_account (not INNER) so customers with zero accounts are still
-- counted in the denominator — an inner join here understates total customers.
CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_segment_concentration AS
WITH customer_base AS (
  SELECT COUNT(*) AS total_customers FROM NEXUS_FINANCE.GOLD.dim_customer WHERE is_current = TRUE
),
alert_base AS (
  SELECT COUNT(*) AS total_alerts FROM NEXUS_FINANCE.GOLD.fact_alerts
)
SELECT
  dc.risk_rating,
  dc.pep_flag,
  COUNT(DISTINCT dc.customer_key)                                                                  AS customer_count,
  ROUND(100.0 * COUNT(DISTINCT dc.customer_key) / (SELECT total_customers FROM customer_base), 2)   AS pct_of_customers,
  COUNT(fa.alert_key)                                                                               AS alert_count,
  ROUND(100.0 * COUNT(fa.alert_key) / (SELECT total_alerts FROM alert_base), 2)                     AS pct_of_alerts
FROM NEXUS_FINANCE.GOLD.dim_customer dc
LEFT JOIN NEXUS_FINANCE.GOLD.dim_account da ON da.customer_key = dc.customer_key
LEFT JOIN NEXUS_FINANCE.GOLD.fact_alerts fa ON fa.account_key = da.account_key
WHERE dc.is_current = TRUE
GROUP BY dc.risk_rating, dc.pep_flag
ORDER BY pct_of_alerts DESC;

CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.vw_new_account_alert_rate AS
SELECT
  da.is_new_account_flag,
  COUNT(DISTINCT da.account_key)                                                             AS account_count,
  COUNT(DISTINCT fa.alert_key)                                                                AS alert_count,
  ROUND(100.0 * COUNT(DISTINCT fa.alert_key) / NULLIF(COUNT(DISTINCT da.account_key),0), 2)   AS alerts_per_100_accounts
FROM NEXUS_FINANCE.GOLD.dim_account da
LEFT JOIN NEXUS_FINANCE.GOLD.fact_alerts fa ON fa.account_key = da.account_key
GROUP BY da.is_new_account_flag;

/* =========== Supporting views (used by ad-hoc analysis / drill-downs) =========== */

-- one row per account: did any of its transactions ever trip the structuring flag
CREATE OR REPLACE VIEW GOLD.VW_ACCOUNT_STRUCTURING_FLAG AS
SELECT
    d.ACCOUNT_KEY,
    MAX(t.STRUCTURING_FLAG) AS STRUCTURING_FLAG
FROM GOLD.DIM_ACCOUNT d
JOIN GOLD.FACT_TRANSACTIONS t
    ON t.ACCOUNT_KEY = d.ACCOUNT_KEY
GROUP BY d.ACCOUNT_KEY;

-- alert-level PEP exposure, for a Tableau filter/segment without repeating the
-- account -> customer join in every workbook that needs it
CREATE OR REPLACE VIEW GOLD.VW_ALERT_PEP_FLAG AS
SELECT
    fa.ALERT_KEY,
    dc.PEP_FLAG
FROM GOLD.FACT_ALERTS fa
JOIN GOLD.DIM_ACCOUNT da
    ON fa.ACCOUNT_KEY = da.ACCOUNT_KEY
JOIN GOLD.DIM_CUSTOMER dc
    ON da.CUSTOMER_KEY = dc.CUSTOMER_KEY
    AND dc.IS_CURRENT = TRUE;

-- alert rate split by new-vs-established account, pre-aggregated per side
-- before joining, to avoid fan-out between the two independent aggregations
CREATE OR REPLACE VIEW NEXUS_FINANCE.GOLD.VW_ACCOUNT_ALERT_RATE AS
WITH account_totals AS (
    SELECT
        IS_NEW_ACCOUNT_FLAG,
        COUNT(DISTINCT ACCOUNT_KEY) AS TOTAL_ACCOUNTS
    FROM NEXUS_FINANCE.GOLD.DIM_ACCOUNT
    GROUP BY IS_NEW_ACCOUNT_FLAG
),
alerted_accounts AS (
    SELECT DISTINCT ACCOUNT_KEY
    FROM NEXUS_FINANCE.GOLD.FACT_ALERTS
),
alert_totals AS (
    SELECT
        da.IS_NEW_ACCOUNT_FLAG,
        COUNT(DISTINCT aa.ACCOUNT_KEY) AS ALERTED_ACCOUNTS
    FROM alerted_accounts aa
    INNER JOIN NEXUS_FINANCE.GOLD.DIM_ACCOUNT da
        ON aa.ACCOUNT_KEY = da.ACCOUNT_KEY
    GROUP BY da.IS_NEW_ACCOUNT_FLAG
)
SELECT
    t.IS_NEW_ACCOUNT_FLAG,
    t.TOTAL_ACCOUNTS,
    COALESCE(a.ALERTED_ACCOUNTS, 0)                              AS ALERTED_ACCOUNTS,
    ROUND(COALESCE(a.ALERTED_ACCOUNTS, 0) / t.TOTAL_ACCOUNTS, 4) AS NEW_ACCOUNT_ALERT_RATE
FROM account_totals t
LEFT JOIN alert_totals a
    ON t.IS_NEW_ACCOUNT_FLAG = a.IS_NEW_ACCOUNT_FLAG;

/* =========== One-shot check: quick numbers for every KPI view =========== */

SELECT * FROM NEXUS_FINANCE.GOLD.vw_alert_funnel ORDER BY year DESC, month DESC;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_sla_compliance ORDER BY year DESC, month DESC;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_disposition_breakdown;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_rule_performance;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_structuring_detection_hit_rate;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_geo_risk_summary;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_geo_region_summary ORDER BY alerts_per_100_txn DESC NULLS LAST;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_segment_concentration;
SELECT * FROM NEXUS_FINANCE.GOLD.vw_new_account_alert_rate;
SELECT * FROM NEXUS_FINANCE.GOLD.VW_ACCOUNT_STRUCTURING_FLAG;
SELECT * FROM NEXUS_FINANCE.GOLD.VW_ALERT_PEP_FLAG;
SELECT * FROM NEXUS_FINANCE.GOLD.VW_ACCOUNT_ALERT_RATE;
