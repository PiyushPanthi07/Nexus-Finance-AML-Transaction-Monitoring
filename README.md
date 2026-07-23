# Nexus Finance — AML Transaction Monitoring Pipeline

A synthetic, end-to-end Anti-Money Laundering (AML) transaction monitoring system built on Snowflake, modeling how a real compliance data platform detects, investigates, and reports suspicious activity — from raw core-banking data through regulatory KPI reporting.

> **Disclaimer:** All data in this project is synthetically generated. This is a portfolio engineering project, not a production compliance system, and is not affiliated with any financial institution.

---

## Why this project exists

Anti-money laundering monitoring sits at the intersection of data engineering, regulatory logic, and messy real-world data — a combination that's hard to demonstrate with a toy dataset. This project builds a realistic version of that pipeline end-to-end: ingesting raw transaction data, applying config-driven detection rules against multiple money-laundering typologies, and producing the KPIs a compliance team would actually track (alert volume, false-positive rate, SAR conversion, SLA compliance).

The goal wasn't just to produce a working pipeline — it was to build it the way a real one gets built: break, diagnose, fix, validate, document, repeat.

---

## Architecture

**Medallion architecture, four layers, all in Snowflake:**

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   BRONZE    │────▶│   SILVER    │────▶│    GOLD     │────▶│   AUDIT     │
│  Raw loads  │     │  Cleansed/  │     │  Rule engine│     │  Validation │
│  (as-is)    │     │  enriched   │     │  + star     │     │  + exclusion│
│             │     │             │     │  schema     │     │  logs       │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
```

| Layer | Responsibility |
|---|---|
| **Bronze** | Raw ingestion via `COPY INTO`, idempotent file tracking. No transformation. |
| **Silver** | Type casting (every bronze column is `TEXT`), entity resolution, country standardization, velocity/rolling-window features. No detection logic. |
| **Gold** | Config-driven rule engine (thresholds read from a rules table, not hardcoded) evaluates four AML typologies; star schema (facts + SCD Type 2 dimensions) built via idempotent `MERGE`. |
| **Audit** | Data-quality validation results (`dq_results`) and exclusion logs for every record dropped from the pipeline, with a documented reason — nothing disappears silently. |

**Pipeline execution (sequential, one script per stage):**

```
01_bronze_load.sql              → raw ingestion
02_silver_cleanse_enrich.sql    → cleanse, type, enrich
03_validation_bronze_to_silver.sql
04_gold_rule_engine.sql         → AML typology detection
05_gold_build_facts_dims.sql    → star schema (MERGE, SCD2)
06_validation_silver_to_gold.sql
07_kpi_report.sql               → reporting views for BI
```

Each script is designed to be rerun safely — loads are idempotent, dimension merges use business keys, and full re-runs never duplicate or corrupt state.

---

## Detection logic: four AML typologies

Thresholds and parameters are stored in a config table (`bronze.raw_rule`) and read dynamically by the rule engine — not hardcoded into SQL — so tuning a threshold doesn't require a code change.

| Typology | Pattern detected |
|---|---|
| **Structuring** | Multiple transactions kept just under a reporting threshold to avoid detection |
| **Rapid fund movement** | Funds moved through an account in a short window (in → out velocity) |
| **High-risk country counterparty** | Counterparty located in a jurisdiction flagged as high-risk/sanctioned |
| **CTR threshold breach** | Single transaction breaching the Currency Transaction Report threshold |

Regulatory grounding: Bank Secrecy Act, USA PATRIOT Act, FinCEN CTR/SAR filing requirements, OFAC/SDN screening, PEP (Politically Exposed Person) checks.

---

## Scale

- **~2.7 million** synthetic transactions
- **~23,000** accounts
- **18 months** of transaction history (Jan 2025 – Jun 2026)

---

## Data quality & engineering decisions

This section covers real problems found and fixed during development — the kind of debugging a production data engineer actually does, not a curated success story.

### 1. A detection rule was silently dead on arrival
The high-risk-country rule read its country list from `bronze.raw_rule.threshold_params`, but the actual parameter shape for that rule was `{"applies_to": "high_risk_or_sanctioned"}` — no country array. The `FLATTEN` against a non-existent key always returned zero rows, so the flag was `FALSE` for every transaction, silently, with no error. **Root cause found via a targeted "is the flag ever TRUE" assertion** — a null/empty check alone would never have caught it. Fixed by re-sourcing the high-risk country list from the watchlist table (the actual OFAC/SDN-derived source), which is also the more realistic production pattern.

### 2. An unstable primary key caused silent row duplication across reruns
`gold.alerts.alert_id` is a UUID regenerated fresh every time the rule engine reruns — not a stable business key. Downstream, `fact_alerts` was built with a `MERGE ... WHEN NOT MATCHED THEN INSERT`, keyed on that UUID. Since no rerun's UUIDs ever matched the prior run's, **every rerun inserted an entire extra copy of the table** (1.99M rows after 4 reruns, vs. an expected ~506K). Fixed by rebuilding `fact_alerts` as a full `CREATE OR REPLACE` each run, matching how `gold.alerts` itself is already rebuilt upstream.

### 3. Referential integrity gaps in source data — handled, not hidden
Diagnostics surfaced two upstream data-quality defects baked into the raw account data: 166 `account_id`s assigned to two genuinely different customer records, and ~43,584 transactions (~$17.47M) referencing account IDs that never existed in the source account table at all. Rather than silently dropping these records — the kind of gap that fails an audit — every excluded record is deterministically resolved (e.g., duplicate accounts keep the most-recent-`open_date` row) and logged to a dedicated audit table (`audit.excluded_duplicate_accounts`, `audit.excluded_orphan_transactions`) with a machine-readable exclusion reason. A downstream knock-on effect — alerts referencing those same orphaned accounts — was caught the same way before it could quietly undercount every dashboard reading from `fact_alerts`.

### 4. Fan-out and fail-open validation traps
- A geography dimension column (`region`) was populated in the table DDL but never actually written by any `UPDATE`/`MERGE` — despite being referenced in KPI `GROUP BY` clauses, silently returning `NULL` region for every row. A "column exists" check wouldn't have caught this; a **"column is actually populated"** validation check was added.
- A one-off SLA filter patch (`disposition_date_key <= CURRENT_DATE()`) had been applied directly against a view and was silently reverted every time the view got rebuilt — a common trap with `CREATE OR REPLACE VIEW` pipelines. Fixed by embedding the filter permanently in the generating script instead of patching the output.

*Full issue history — all fixes, root-cause diagnostics, and before/after validation output — is in [`docs/issue_tracker.md`](docs/issue_tracker.md).*

---

## Validation & data quality framework

Every pipeline stage writes structured results to `audit.dq_results` — pass/fail/warn checks with expected vs. actual values, not just a boolean. Examples of what's checked:

- Row-count reconciliation between layers
- Referential integrity (orphaned accounts, orphaned transactions)
- Duplicate detection (transaction IDs, account IDs)
- "Flag actually fires" assertions (not just "flag is non-null")
- Audit-trail completeness (every excluded record is traceable, not just excluded)
- Dimension population checks (a column existing isn't the same as a column being populated)

**Latest validated run:** 0 FAIL, all WARNs documented and explained (see `known_limitations.md`), 43 PASS checks.

---

## Key metrics & targets

| Metric | Target | Status |
|---|---|---|
| False positive rate | 88–95% | Within target band |
| Alert-to-SAR conversion | 5–10% | Within target band |
| SLA compliance (alert disposition) | ≥ 90% | ~88–91%, borderline — see [known limitations](docs/known_limitations.md) |

---

## Reporting layer

Seven gold-layer KPI views feed three Tableau dashboards:

1. **Compliance Executive Overview** — alert volume, SAR conversion, disposition trends
2. **Rule Performance & Tuning** — false-positive rate by rule, threshold sensitivity
3. **Geographic Risk Segmentation** — risk concentration by country/region

*(Dashboard screenshots and links in [`dashboards/`](dashboards/) once published.)*

---

## Repository structure

```
nexus-finance-aml-pipeline/
├── README.md
├── docs/
│   ├── architecture.md
│   ├── issue_tracker.md
│   ├── data_dictionary.md
│   └── known_limitations.md
├── sql/
│   ├── 01_bronze_load.sql
│   ├── 02_silver_cleanse_enrich.sql
│   ├── 03_validation_bronze_to_silver.sql
│   ├── 04_gold_rule_engine.sql
│   ├── 05_gold_build_facts_dims.sql
│   ├── 06_validation_silver_to_gold.sql
│   └── 07_kpi_report.sql
├── validation/
│   └── sample_validation_output.csv
├── sample_data/
└── dashboards/
    └── screenshots/
```

---

## How to run

1. Create a Snowflake database (`NEXUS_FINANCE`) with `bronze`, `silver`, `gold`, and `audit` schemas.
2. Load source files per `sql/01_bronze_load.sql`.
3. Run scripts **in strict numeric order** — each stage depends on the previous one, and partial/out-of-order runs will produce an inconsistent state:
   ```
   01 → 02 → 03 → 04 → 05 → 06 → 07
   ```
4. Check `audit.dq_results` after each validation script (03, 06) before proceeding.
5. Connect Tableau to the `gold` KPI views for dashboard consumption.

---

## Known limitations

- SCD Type 2 on `dim_customer` currently versions only on `risk_rating` changes — PEP flag, country, and business-type changes don't trigger a new historical row.
- SLA compliance sits at ~88–91% against a ≥90% target; not yet fully resolved.
- Customer risk snapshot currently only produces rows for customers with at least one alert; a full-population risk-trending view would need a driving join against all customers, not just alerted ones.
- Full detail in [`docs/known_limitations.md`](docs/known_limitations.md).

---

## Tech stack

- **Snowflake** — warehouse, transformation (SQL), config-driven rule engine
- **SQL** — all transformation logic, no external orchestration framework (by design, to keep the project inspectable end-to-end)
- **Tableau** — dashboard/reporting layer

---

## Author's note

This project was built iteratively and debugged the way real pipelines get debugged: reproduce the discrepancy, isolate the layer, pull the DDL, confirm root cause with a diagnostic query before touching anything, fix at the earliest broken point, rerun the full sequence, and validate with actual output — not assumption. The issue tracker linked above is the unfiltered record of that process.
