# 🦆 DuckDB 2.0 Triggers

<p align="center">
  <b>BEFORE / AFTER</b> &nbsp;•&nbsp; <b>INSERT / UPDATE / DELETE</b> &nbsp;•&nbsp; <b>ROW / STATEMENT</b> &nbsp;•&nbsp; <b>VARIANT audit logs</b>
</p>

---

## 📑 Table of Contents

0.  [When to Use Triggers (and When Not To)](#When to Use Triggers (and When Not To))
1.  [What 2.0 triggers can do](#-what-20-triggers-can-do)
2.  [The demo design](#-the-demo-design)
3.  [Demo script](#-demo-script)
    - [0. Setup](#0-setup)
    - [1. AFTER INSERT, statement-level](#1-after-insert-statement-level--new-table)
    - [2. AFTER UPDATE with OLD/NEW tables](#2-after-update--oldnew-tables-audit-stored-as-variant)
    - [3. BEFORE and AFTER DELETE](#3-before--after-delete-statement-level)
    - [4. RETURNING](#4-returning-works-with-statement-level-triggers)
    - [5. Row-level triggers](#5-row-level-triggers-on-zscore_rows-new--old)
    - [6. Inspect, replace, drop](#6-inspect-replace-drop)
4.  [Gotchas: things that fail on purpose](#-gotchas-things-that-fail-on-purpose)
5.  [Notes](#-notes-before-running the code)
6.  [Sources](#-sources)

---

## ✅ When to Use Triggers (and When Not To)

- Triggers let the database react automatically to `INSERT`, `UPDATE` and `DELETE`, which makes them a good fit for work that must happen _every time_, no matter which tool or script changed the data. Typical wins are audit trails (who changed what, and when), archiving deleted rows, keeping a small summary or counter table in step with a base table, and flagging suspicious rows, such as filings with missing revenue, into a quarantine table.

- Because the rule lives in the database, it can't be forgotten by a forgetful script or a second application.

- The danger is the flip side of the same strength: triggers are _invisible_. Someone running a simple `UPDATE` has no hint that extra writes are happening, and a chain of triggers can make behavior hard to trace and debug. They add work to every write, which matters in DuckDB, where tables are usually loaded in large batches. A row-level trigger that fires once per inserted row can turn a fast bulk load into a slow one, which is why statement-level triggers (once per statement, with access to the changed rows as a whole) are usually the better fit.

- A badly written trigger can also fail or misbehave inside the transaction of the statement that fired it, and DuckDB 2.0 triggers come with restrictions of their own, such as no row-level `BEFORE` triggers and limits on combining them with some statements like `MERGE INTO`.

- **Use triggers for small, simple, high-value side effects like auditing and archiving.**

- **Don't use them for heavy transformations, business logic that belongs in your pipeline, or anything where a visible, explicit step (a scheduled job, a view, or a data-modifying CTE) would be easier to understand and test.**

| Good fit                          | Poor fit                                    |
| --------------------------------- | ------------------------------------------- |
| Audit log of changes              | Complex multi-step business logic           |
| Archive rows on delete            | Heavy calculations on every row             |
| Small counters or summary tables  | Large bulk loads with row-level triggers    |
| Flagging or quarantining bad rows | Anything that must be easy to see and debug |

## ✅ What 2.0 triggers can do

| Capability            | What the docs say                                                                                                                                                                                                               |
| :-------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Timing**            | `BEFORE` and `AFTER` only. There is **no** `INSTEAD OF` ( intercepts INSERT, UPDATE, or DELETE statements on a view or table and executes replacement code instead of the original DML operation) and **no** triggers on views. |
| **Events**            | `INSERT`, `UPDATE` and `DELETE`. Use `UPDATE OF col` to limit an update trigger to specific columns.                                                                                                                            |
| **Row-level**         | `FOR EACH ROW` exposes `NEW` or `OLD`. Works for `INSERT` and `DELETE` only.                                                                                                                                                    |
| **Statement-level**   | `FOR EACH STATEMENT` fires once per statement and can use transition tables: `REFERENCING OLD TABLE AS o NEW TABLE AS n`.                                                                                                       |
| **Multiple triggers** | Several triggers on one event fire in **creation order**.                                                                                                                                                                       |
| **Body**              | A **single SQL statement**. The docs don't mention a `WHEN` clause.                                                                                                                                                             |

> **IMPORTANT**  
> Row-level and statement-level triggers **can't be mixed** on the same event of a table. So this demo uses two tables:
>
> | Table         | Trigger style            |
> | :------------ | :----------------------- |
> | `zscore_live` | statement-level triggers |
> | `zscore_rows` | row-level triggers       |

> **NOTE**  
> Run the script in a database that uses the **2.0 storage format**.

---

### 0. Setup

Create an the zscore_live table

```sql
CREATE OR REPLACE TABLE zscore_live (
    ticker            VARCHAR,
    period_end        DATE,
    ebit              DOUBLE,
    revenue           DOUBLE,
    retained_earnings DOUBLE,
    total_liabilities DOUBLE,
    ebit_margin       DOUBLE
);

INSERT INTO zscore_live
SELECT ticker, period_end, ebit, revenue, retained_earnings, total_liabilities,
       ebit / revenue AS ebit_margin
FROM read_json('c:/tmp/zscore_inputs.json');

FROM zscore_live LIMIT 10;

-- Row-level demos get an empty copy of the same shape
CREATE OR REPLACE TABLE zscore_rows AS FROM zscore_live LIMIT 0;

-- Audit destinations. `details` is a VARIANT, so any shape fits
CREATE OR REPLACE TABLE change_log (
    ts         TIMESTAMP,
    table_name VARCHAR,
    event      VARCHAR,
    details    VARIANT
);

CREATE OR REPLACE TABLE insert_counter (ts TIMESTAMP, total_rows BIGINT);
CREATE OR REPLACE TABLE zscore_archive AS FROM zscore_live LIMIT 0;
CREATE OR REPLACE TABLE row_log        (ts TIMESTAMP, event VARCHAR, ticker VARCHAR, period_end DATE);
CREATE OR REPLACE TABLE quarantine     (ts TIMESTAMP, ticker VARCHAR, period_end DATE, reason VARCHAR);
```

---

### 1. AFTER INSERT, statement-level + NEW TABLE

A batch summary: one audit row per `INSERT` statement, no matter how many rows it inserts.

```sql
CREATE TRIGGER trg_ins_summary
AFTER INSERT ON zscore_live
REFERENCING NEW TABLE AS n
FOR EACH STATEMENT
  INSERT INTO change_log
  SELECT now(), 'zscore_live', 'INSERT',
         {'rows': count(*), 'tickers': list(DISTINCT ticker)}::VARIANT
  FROM n;
```

**1b. A second trigger on the same event** fires _after_ the first, in creation order:

```sql
CREATE TRIGGER trg_ins_counter
AFTER INSERT ON zscore_live
FOR EACH STATEMENT
  INSERT INTO insert_counter SELECT now(), count(*) FROM zscore_live;
```

**Test it:**

```sql
INSERT INTO zscore_live (ticker, period_end, total_liabilities, retained_earnings, ebit, revenue)
VALUES ('HSY', '2025-12-31',  8.5e9, 6.0e9, 3.0e9, 11.5e9),
       ('KHC', '2025-12-27', 38.0e9, 2.4e9, 1.9e9, NULL);

SELECT * FROM change_log;       -- {'rows': 2, 'tickers': [HSY, KHC]}
SELECT * FROM insert_counter;   -- one row per statement, not per inserted row
```

---

### 2. AFTER UPDATE + OLD/NEW TABLE, audit stored as VARIANT

The join key is `ticker + period_end`, since the table has no primary key.

```sql
CREATE TRIGGER trg_upd_audit
AFTER UPDATE ON zscore_live
REFERENCING OLD TABLE AS o NEW TABLE AS n
FOR EACH STATEMENT
  INSERT INTO change_log
  SELECT now(), 'zscore_live', 'UPDATE',
         {'ticker': n.ticker, 'period_end': n.period_end::VARCHAR,
          'old': {'ebit': o.ebit, 'revenue': o.revenue},
          'new': {'ebit': n.ebit, 'revenue': n.revenue}}::VARIANT
  FROM o JOIN n ON o.ticker = n.ticker AND o.period_end = n.period_end;
```

**2b. Column-restricted trigger.** It fires only when `ebit` is in the `SET` list. No `REFERENCING` is allowed here, so it can't see old/new rows, only that it ran.

```sql
CREATE OR REPLACE TABLE ebit_changes (
    ts            TIMESTAMP,
    event         VARCHAR,
    rows_in_table BIGINT,
    total_ebit    DOUBLE
);

CREATE OR REPLACE TRIGGER trg_ebit_only
AFTER UPDATE OF ebit ON zscore_live
FOR EACH STATEMENT
  INSERT INTO ebit_changes
  SELECT now(), 'ebit column updated', count(*), sum(ebit) FROM zscore_live;
```

**Test it.** The first update doesn't touch `ebit`, the second does:

```sql
-- trg_upd_audit fires, trg_ebit_only does NOT
UPDATE zscore_live SET revenue = revenue * 1.01 WHERE ticker = 'HSY';
SELECT count(*) AS should_be_0 FROM ebit_changes;

-- both fire
UPDATE zscore_live SET ebit = ebit * 1.10 WHERE ticker = 'GIS';
SELECT * FROM ebit_changes;          -- 1 row: a post-update snapshot
SELECT count(*) FROM ebit_changes;
```

**Query the VARIANT audit trail:**

```sql
SELECT ts,
       details.ticker                                     AS ticker,
       (details.old.ebit)::DOUBLE                         AS old_ebit,
       (details.new.ebit)::DOUBLE                         AS new_ebit,
       (details.new.ebit)::DOUBLE - (details.old.ebit)::DOUBLE AS delta
FROM change_log
WHERE event = 'UPDATE' AND variant_exists(details, 'old')
ORDER BY ts;
```

---

### 3. BEFORE + AFTER DELETE, statement-level

A snapshot before the delete, and an archive after it.

```sql
CREATE TRIGGER trg_before_delete
BEFORE DELETE ON zscore_live
FOR EACH STATEMENT
  INSERT INTO change_log
  SELECT now(), 'zscore_live', 'BEFORE DELETE', {'rows_before': count(*)}::VARIANT
  FROM zscore_live;

CREATE TRIGGER trg_archive
AFTER DELETE ON zscore_live
REFERENCING OLD TABLE AS o
FOR EACH STATEMENT
  INSERT INTO zscore_archive SELECT * FROM o;
```

**Test it:**

```sql
DELETE FROM zscore_live WHERE revenue IS NULL;

SELECT count(*) AS archived FROM zscore_archive;
SELECT * FROM change_log WHERE event = 'BEFORE DELETE';
```

---

### 4. RETURNING works with statement-level triggers

`RETURNING` is allowed here because `zscore_live` has only statement-level triggers.

```sql
INSERT INTO zscore_live (ticker, period_end, ebit, revenue)
VALUES ('GIS', '2026-11-30', 1.0e9, 19.0e9)
RETURNING ticker, period_end;
```

---

### 5. Row-level triggers on `zscore_rows` (NEW / OLD)

```sql
CREATE TRIGGER trg_row_ins
AFTER INSERT ON zscore_rows
FOR EACH ROW
  INSERT INTO row_log VALUES (now(), 'INSERT', NEW.ticker, NEW.period_end);
```

**5b. A conditional trigger.** The docs show no `WHEN` clause, so put a `WHERE` inside the body instead:

```sql
CREATE TRIGGER trg_row_quarantine
AFTER INSERT ON zscore_rows
FOR EACH ROW
  INSERT INTO quarantine
  SELECT now(), NEW.ticker, NEW.period_end, 'missing revenue'
  WHERE NEW.revenue IS NULL;

CREATE TRIGGER trg_row_del
AFTER DELETE ON zscore_rows
FOR EACH ROW
  INSERT INTO row_log VALUES (now(), 'DELETE', OLD.ticker, OLD.period_end);
```

**Test it:**

```sql
INSERT INTO zscore_rows (ticker, period_end, ebit, revenue)
VALUES ('GIS', '2026-05-31',  885.8e6, 18424.6e6),
       ('KHC', '2024-12-28', 1683e6,   NULL),
       ('HSY', '2024-12-31', 2898.2e6, 11202.3e6);

SELECT * FROM row_log;      -- 3 INSERT rows, one per row
SELECT * FROM quarantine;   -- only the KHC row

DELETE FROM zscore_rows WHERE ticker = 'HSY';
SELECT * FROM row_log WHERE event = 'DELETE';
```

---

### 6. Inspect, replace, drop

```sql
-- See every trigger
SELECT trigger_name, table_name, action_timing, event_manipulation, for_each
FROM duckdb_triggers()
ORDER BY table_name, trigger_name;

-- Redefine in place
CREATE OR REPLACE TRIGGER trg_ins_counter
AFTER INSERT ON zscore_live
FOR EACH STATEMENT
  INSERT INTO insert_counter SELECT now(), count(DISTINCT ticker) FROM zscore_live;

-- Silently does nothing, because the trigger already exists
CREATE TRIGGER IF NOT EXISTS trg_ins_counter
AFTER INSERT ON zscore_live
FOR EACH STATEMENT
  INSERT INTO insert_counter VALUES (now(), -1);

-- Drop
DROP TRIGGER trg_ebit_only ON zscore_live;
DROP TRIGGER IF EXISTS trg_nope ON zscore_live;
```

---

## ⚠️ Gotchas: things that fail on purpose

These are the 2.0 limitations from the docs. **Each statement should fail**, so run them one at a time.

|  #  | Statement                                                                                   | Why it fails                                                    |
| :-: | :------------------------------------------------------------------------------------------ | :-------------------------------------------------------------- |
|  1  | `BEFORE INSERT ... FOR EACH ROW`                                                            | `BEFORE ... FOR EACH ROW` is not supported                      |
|  2  | `AFTER UPDATE ... FOR EACH ROW`                                                             | `UPDATE ... FOR EACH ROW` is not supported                      |
|  3  | `FOR EACH ROW` on a table that already has statement-level `INSERT` triggers                | Can't mix `ROW` and `STATEMENT` for the same event on one table |
|  4  | `INSTEAD OF INSERT` on a view                                                               | `INSTEAD OF` and triggers on views are not supported            |
|  5  | `INSERT OR REPLACE`, `ON CONFLICT`, `MERGE INTO` on a table with `UPDATE`/`DELETE` triggers | Upsert variants and `MERGE` are not supported there             |
|  6  | `RETURNING` on a table with row-level triggers                                              | `RETURNING` is not allowed there                                |

<details>
<summary><b>Show the SQL for each gotcha</b></summary>

```sql
-- 1. BEFORE ... FOR EACH ROW is not supported
CREATE TRIGGER bad1 BEFORE INSERT ON zscore_rows FOR EACH ROW
  INSERT INTO row_log VALUES (now(), 'x', NEW.ticker, NEW.period_end);

-- 2. UPDATE ... FOR EACH ROW is not supported
CREATE TRIGGER bad2 AFTER UPDATE ON zscore_rows FOR EACH ROW
  INSERT INTO row_log VALUES (now(), 'x', NEW.ticker, NEW.period_end);

-- 3. Can't mix ROW and STATEMENT for the same event on one table
CREATE TRIGGER bad3 AFTER INSERT ON zscore_live FOR EACH ROW
  INSERT INTO row_log VALUES (now(), 'x', NEW.ticker, NEW.period_end);

-- 4. INSTEAD OF / triggers on views are not supported
CREATE VIEW v AS FROM zscore_live;
CREATE TRIGGER bad4 INSTEAD OF INSERT ON v FOR EACH ROW
  INSERT INTO zscore_live SELECT NEW.*;

-- 5. MERGE INTO and upsert variants fail on tables with UPDATE/DELETE triggers
INSERT OR REPLACE INTO zscore_live SELECT * FROM zscore_live LIMIT 1;
INSERT INTO zscore_live SELECT * FROM zscore_live LIMIT 1 ON CONFLICT DO NOTHING;

-- 6. RETURNING is not allowed on tables with row-level triggers
INSERT INTO zscore_rows (ticker, period_end) VALUES ('X', '2026-01-01') RETURNING ticker;
```

</details>

---

## 🔎 Notes

- **Storage version.** If `CREATE TRIGGER` complains about the database's storage version, attach the database with `ATTACH ... (STORAGE_VERSION 'latest')`.
- **Duplicate keys.** The demo table has no primary key. If two rows share `ticker` and `period_end`, the join in trigger 2 will produce duplicate audit rows. Real filings should be unique per period.
- **Cleanup.** `DROP TABLE` the demo tables when you're done running the code. Dropping a table also drops its triggers.

---

## 📚 Sources

- CREATE TRIGGER (DuckDB 2.0)
- A Preview of DuckDB v2.0
- Announcing DuckDB 2.0.0 LTS "Cinnamon Teal"
