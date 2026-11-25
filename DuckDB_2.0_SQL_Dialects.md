# 🦆 DuckDB 2.0: What's New in the SQL Dialect

> A guided tour of the new SQL syntax in DuckDB 2.0, with runnable examples on real financial data (Altman Z-score inputs).

<p align="center">
  <b>$variables</b> &nbsp;•&nbsp; <b>FETCH FIRST</b> &nbsp;•&nbsp; <b>Python-style lambdas</b> &nbsp;•&nbsp; <b>GROUP BY UNNEST</b> &nbsp;•&nbsp; <b>JOIN BY (TYPE …)</b> &nbsp;•&nbsp; <b>NEAREST joins</b> &nbsp;•&nbsp; <b>MERGE</b> &nbsp;•&nbsp; <b>and more</b>
</p>

---

## 📑 Table of Contents

|  #  | Section                                                         |  #  | Section                                                      |
| :-: | :-------------------------------------------------------------- | :-: | :----------------------------------------------------------- |
|  0  | [Setup](#0-setup)                                               |  8  | [MERGE INTO](#8-merge-into-defined-duplicate-semantics)      |
|  1  | [`$variable` shorthand](#1-variable-shorthand)                  |  9  | [`WITH RECURSIVE … USING KEY`](#9-with-recursive--using-key) |
|  2  | [`FETCH FIRST / NEXT`](#2-sql-standard-fetch-first--fetch-next) | 10  | [Nested schemas](#10-nested-schemas)                         |
|  3  | [Python-style lambdas](#3-python-style-lambdas)                 | 11  | [JSON mutation functions](#11-json-mutation-functions)       |
|  4  | [`GROUP BY UNNEST`](#4-group-by-unnest)                         | 12  | [`SECURE VIEW`](#12-secure-view)                             |
|  5  | [`JOIN BY (TYPE …)`](#5-explicit-join-types-join-by-type-)      | 13  | [`SHOW` changes](#13-show-changes)                           |
|  6  | [`NEAREST` joins](#6-nearest-joins-top-k-as-a-join-clause)      | 14  | [`setval()`](#14-setval-set-a-sequence-value)                |
|  7  | [Data-modifying CTEs](#7-data-modifying-ctes)                   | 15  | [`regexp_extract` options](#15-regexp_extract-with-options)  |

**Bonus:** [⚡ Breaking changes at a glance](#-breaking-changes-at-a-glance) · [🔎 Notes before you run it](#-notes-before-you-run-it) · [📚 Sources](#-sources)

---

## 0. Setup

Derived objects used by the demos below.

```sql
.open 'SQL_Dialects.db';

-- NEW CLI dot command in 2.0: signatures + examples
.manual list_transform

CREATE OR REPLACE TABLE watchlist (ticker VARCHAR);
INSERT INTO watchlist VALUES ('GIS'), ('HSY'), ('ZZZ');   -- ZZZ doesn't exist in the data

CREATE OR REPLACE TABLE zscore_inputs (
    ticker            VARCHAR,
    period_end        DATE,
    ebit              DOUBLE,
    revenue           DOUBLE,
    retained_earnings DOUBLE,
    total_liabilities DOUBLE,
    ebit_margin       DOUBLE
);

INSERT INTO zscore_inputs
SELECT ticker, period_end, ebit, revenue, retained_earnings, total_liabilities,
       ebit / revenue AS ebit_margin
FROM read_json('c:/tmp/zscore_inputs.json');

CREATE OR REPLACE VIEW v_margin AS
SELECT ticker, period_end, ebit, revenue, retained_earnings, total_liabilities,
       ebit / revenue AS ebit_margin
FROM zscore_inputs;
```

---

## 1. `$variable` shorthand

`$name` replaces `getvariable('name')`.

```sql
SET VARIABLE min_margin = 0.20;

SELECT ticker, period_end, round(ebit_margin, 3) AS margin
FROM v_margin
WHERE ebit_margin > $min_margin
ORDER BY margin DESC
LIMIT 5;

SELECT $min_margin = getvariable('min_margin') AS same;   -- true
SELECT $undefined_var;                                    -- ERROR
```

> [!TIP]
> An undefined `$variable` is an **error**, while `getvariable()` would quietly return `NULL`. That makes typos easier to catch.

---

## 2. SQL-standard `FETCH FIRST` / `FETCH NEXT`

```sql
-- Top 5
SELECT ticker, period_end, round(ebit_margin, 3) AS margin
FROM v_margin WHERE ebit_margin IS NOT NULL
ORDER BY margin DESC
FETCH FIRST 5 ROWS ONLY;

-- Paging
SELECT ticker, period_end, round(ebit_margin, 3) AS margin
FROM v_margin WHERE ebit_margin IS NOT NULL
ORDER BY margin DESC
OFFSET 5 ROWS FETCH NEXT 2 ROWS ONLY;

-- Single row
SELECT ticker, period_end, round(ebit_margin, 3) AS margin
FROM v_margin WHERE ebit_margin IS NOT NULL
ORDER BY margin DESC
FETCH FIRST ROW ONLY;
```

> [!WARNING]
> **There is no `FETCH LAST`.** This one fails:
>
> ```sql
> SELECT ticker, period_end, round(ebit_margin, 3) AS margin
> FROM v_margin WHERE ebit_margin IS NOT NULL
> ORDER BY margin DESC
> FETCH LAST ROW ONLY;   -- ERROR
> ```
>
> To get the last row, flip the `ORDER BY` and use `FETCH FIRST`.

---

## 3. Python-style lambdas

The 2.0 syntax is `lambda parameter : expression`, written like Python. The old arrow style `x -> x + 1` is **off by default** in 2.0.

### Stage 1: collapse rows into one list per ticker

```sql
SELECT ticker, list(ebit ORDER BY period_end) AS ebit_list
FROM zscore_inputs
GROUP BY ticker;
```

- `GROUP BY ticker` collapses all rows for a company into one row.
- `list(...)` is an aggregate that gathers values into a single list.
- `ORDER BY period_end` _inside_ the parentheses sorts values oldest to newest before they go in the list. Without it, the order isn't guaranteed.

### Stage 2: three list functions, each given a small lambda

| Function         | What it does                                                                  | Lambda arguments                         |
| :--------------- | :---------------------------------------------------------------------------- | :--------------------------------------- |
| `list_transform` | Applies the lambda to every element and returns a new list of the same length | `x` (the value)                          |
| `list_reduce`    | Folds the list into a single value                                            | `a` (running result), `b` (next element) |
| `list_filter`    | Keeps only elements where the lambda returns true                             | `x` (the value), `i` (1-based position)  |

```sql
WITH per_ticker AS (
  SELECT ticker, list(ebit ORDER BY period_end) AS ebits
  FROM zscore_inputs
  GROUP BY ticker
)
SELECT ticker,
       ebits,                                                            -- the raw list
       list_transform(ebits, lambda x : round(x/1e9, 2))   AS ebit_bn,   -- dollars → billions
       list_reduce(ebits, lambda a, b : a + b)             AS ebit_total,-- running sum
       list_filter(ebits, lambda x, i : x > 1e9 AND i > 1) AS big_after_first
FROM per_ticker;
```

`big_after_first` reads as: _"over $1B, and not the first element."_

### The old arrow syntax

```sql
SELECT list_transform([1,2,3], x -> x + 1);        -- ERROR in 2.0 (breaking change)

SET lambda_syntax = 'enable_single_arrow';         -- temporary escape hatch (removed in 2.1)
SELECT list_transform([1,2,3], x -> x + 1);        -- works again
SET lambda_syntax = 'default';
```

---

## 4. `GROUP BY UNNEST`

A two-step "red flag" pattern. The first query **tags each filing** with the flags that apply to it. The second **counts how often each flag appears** across all filings.

### Part 1: build the `flagged` table

```sql
CREATE OR REPLACE TABLE flagged AS
SELECT ticker, period_end,
       list_filter([
         CASE WHEN revenue IS NULL                          THEN 'missing_revenue' END,
         CASE WHEN ebit_margin < 0.05                       THEN 'thin_margin'     END,
         CASE WHEN retained_earnings < 0                    THEN 'negative_re'     END,
         CASE WHEN total_liabilities > 3 * retained_earnings THEN 'high_leverage'  END
       ], lambda f : f IS NOT NULL) AS flags
FROM v_margin;
```

How it works:

1. **Four `CASE` expressions.** There is no `ELSE`, so each returns a flag name or `NULL`.
2. **Square brackets** build a list of those four values, for example `['missing_revenue', NULL, NULL, 'high_leverage']`. The list always has four slots, and slots with no flag hold `NULL`.
3. **`list_filter(..., lambda f : f IS NOT NULL)`** removes the `NULL` slots, leaving `['missing_revenue', 'high_leverage']`.
4. A filing with no problems ends up with an empty list, `[]`.

The result is one row per filing, with a `flags` column holding a list of strings of varying length.

### Part 2: count flags with `GROUP BY unnest`

```sql
SELECT unnest(flags) AS flag, count(*) AS n
FROM flagged
GROUP BY unnest(flags)
ORDER BY n DESC;
```

`unnest(flags)` explodes each list into separate rows, one per flag. A filing with two flags becomes two rows. Then `GROUP BY` counts each flag name.

> [!NOTE]
> **This is the 2.0 addition.** Before 2.0, you couldn't put `unnest` directly in `GROUP BY`.

<details>
<summary><b>The pre-2.0 workaround</b></summary>

Unnest in a subquery, then group the outer query:

```sql
SELECT flag, count(*) AS n
FROM (SELECT unnest(flags) AS flag FROM flagged)
GROUP BY flag;
```

</details>

**What to understand about the output:**

- `n` counts **flags, not filings**. A filing with two flags is counted once under each flag, so totals add up to more than the number of filings.
- **Clean filings disappear.** An empty list unnests to zero rows, so only filings with at least one flag contribute.

---

## 5. Explicit join types: `JOIN BY (TYPE …)`

Two concepts first:

- **Semi joins** return rows from the left table that have at least one match in the right table.
- **Anti joins** return rows from the left table that have no match in the right table.

A semi or anti join never returns more rows than the left table. Semi joins follow the same logic as `IN`. Anti joins follow the same logic as `NOT IN`, except that anti joins ignore `NULL` values from the right table.

### All join types

| Join type    | Description                                                                                                                                                                                                                                                                 |
| :----------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inner`      | Inner join.                                                                                                                                                                                                                                                                 |
| `left`       | Left outer join.                                                                                                                                                                                                                                                            |
| `right`      | Right outer join.                                                                                                                                                                                                                                                           |
| `full`       | Full outer join.                                                                                                                                                                                                                                                            |
| `semi`       | Semi join: returns the rows of the left side that have a match.                                                                                                                                                                                                             |
| `anti`       | Anti join: returns the rows of the left side that have no match.                                                                                                                                                                                                            |
| `right_semi` | Returns the rows of the right side that have a match.                                                                                                                                                                                                                       |
| `right_anti` | Returns the rows of the right side that have no match.                                                                                                                                                                                                                      |
| `mark`       | Returns all rows of the left side along with a `BOOLEAN` column `__mark_join_marker`, which has the same three-valued result as an `IN` expression.                                                                                                                         |
| `single`     | Returns all rows of the left side paired with their matching row from the right side (or `NULL` if there is no match). Similarly to scalar subqueries, it throws an error if a left row has more than one match (see the `scalar_subquery_error_on_multiple_rows` setting). |

<sub>_Source: [DuckDB Documentation, "FROM and JOIN Clauses: Specifying the Join Type Explicitly"](https://duckdb.org/docs/2.0/sql/query_syntax/from#specifying-the-join-type-explicitly)_</sub>

### Try it on the watchlist

```sql
CREATE OR REPLACE TABLE watchlist (ticker VARCHAR);
INSERT INTO watchlist VALUES ('GIS'), ('HSY'), ('ZZZ');   -- ZZZ doesn't exist in the data

-- semi: filings whose ticker is on the watchlist (no duplication)
SELECT z.ticker, z.period_end
FROM zscore_inputs z
JOIN BY (TYPE semi) watchlist w ON (z.ticker = w.ticker);

-- anti: filings NOT on the watchlist
SELECT DISTINCT z.ticker
FROM zscore_inputs z
JOIN BY (TYPE anti) watchlist w ON (z.ticker = w.ticker);

-- right_anti: watchlist entries with no data
SELECT w.ticker
FROM zscore_inputs z
JOIN BY (TYPE right_anti) watchlist w ON (z.ticker = w.ticker);

-- mark: every row, plus a boolean marker (like IN)
SELECT z.ticker, z.period_end, __mark_join_marker AS on_watchlist
FROM zscore_inputs z
JOIN BY (TYPE mark) watchlist w ON (z.ticker = w.ticker)
ORDER BY z.ticker, z.period_end
LIMIT 10;
```

---

## 6. NEAREST / APPROX NEAREST joins: "which store is closest to each customer?"

A `NEAREST` join matches each row on the left with its _k_ closest rows on the right. There is no `ON` clause, because the distance expression decides the match.

### Setup: 3 stores and 3 customers, each with an (x, y) location

```sql
CREATE OR REPLACE TABLE stores (store VARCHAR, loc FLOAT[2]);
INSERT INTO stores VALUES
  ('A', [1, 1]::FLOAT[2]),
  ('B', [5, 1]::FLOAT[2]),
  ('C', [3, 4]::FLOAT[2]);

CREATE OR REPLACE TABLE customers (customer VARCHAR, loc FLOAT[2]);
INSERT INTO customers VALUES
  ('Ann', [1, 2]::FLOAT[2]),
  ('Bob', [4, 2]::FLOAT[2]),
  ('Cy',  [2, 5]::FLOAT[2]);
```

### How distance is computed

`array_distance` is straight-line (Euclidean) distance, the Pythagorean theorem:

```
distance = sqrt( (x1 - x2)² + (y1 - y2)² )
```

All nine customer-to-store distances, with no `NEAREST` yet:

```sql
SELECT c.customer, s.store,
       round(array_distance(c.loc, s.loc), 2) AS distance
FROM customers c CROSS JOIN stores s
ORDER BY c.customer, distance;
```

| Customer  | Store   | Difference in x, y | Calculation     | Distance |
| --------- | ------- | ------------------ | --------------- | -------- |
| Ann (1,2) | A (1,1) | 0, 1               | √(0² + 1²) = √1 | **1.00** |
| Ann (1,2) | B (5,1) | 4, 1               | √(16 + 1) = √17 | 4.12     |
| Ann (1,2) | C (3,4) | 2, 2               | √(4 + 4) = √8   | 2.83     |
| Bob (4,2) | A (1,1) | 3, 1               | √(9 + 1) = √10  | 3.16     |
| Bob (4,2) | B (5,1) | 1, 1               | √(1 + 1) = √2   | **1.41** |
| Bob (4,2) | C (3,4) | 1, 2               | √(1 + 4) = √5   | 2.24     |
| Cy (2,5)  | A (1,1) | 1, 4               | √(1 + 16) = √17 | 4.12     |
| Cy (2,5)  | B (5,1) | 3, 4               | √(9 + 16) = √25 | 5.00     |
| Cy (2,5)  | C (3,4) | 1, 1               | √(1 + 1) = √2   | **1.41** |

### `NEAREST 1`: each customer's closest store

```sql
SELECT c.customer, s.store,
       round(array_distance(c.loc, s.loc), 2) AS distance
FROM customers c
JOIN stores s NEAREST 1 BY DISTANCE array_distance(c.loc, s.loc);
-- Ann -> A (1.0)   Bob -> B (1.41)   Cy -> C (1.41)
```

The result keeps the smallest distance per customer, the bold values in the table above.

### `NEAREST 2`: each customer's two closest stores

```sql
SELECT c.customer, s.store,
       round(array_distance(c.loc, s.loc), 2) AS distance
FROM customers c
JOIN stores s NEAREST 2 BY DISTANCE array_distance(c.loc, s.loc)
ORDER BY c.customer, distance;
```

| Customer | 1st choice | 2nd choice |
| -------- | ---------- | ---------- |
| Ann      | A (1.00)   | C (2.83)   |
| Bob      | B (1.41)   | C (2.24)   |
| Cy       | C (1.41)   | A (4.12)   |

Six rows come back: each customer appears twice, once per neighbor.

### Key points

- **Pattern:** `JOIN <table> NEAREST k BY DISTANCE <distance expression>`
- **`k`:** how many matches each left-side row gets.
- **`DISTANCE` vs `SIMILARITY`:** with `DISTANCE`, smaller means closer. With `BY SIMILARITY`, for example `array_cosine_similarity`, bigger means closer.

### The old way (for comparison)

Before 2.0, you computed every pair, ranked them, and kept the top _k_:

```sql
SELECT customer, store, round(dist, 2) AS distance
FROM (
  SELECT c.customer, s.store, array_distance(c.loc, s.loc) AS dist,
         row_number() OVER (PARTITION BY c.customer ORDER BY array_distance(c.loc, s.loc)) AS rn
  FROM customers c CROSS JOIN stores s
)
WHERE rn = 1;
```

Same answer, more code, and it compares every customer with every store, which doesn't scale.

### `APPROX NEAREST` (for large vector tables)

For millions of vectors, `APPROX` trades a little accuracy for speed. It uses `BY SIMILARITY`:

```sql
SELECT q.id, t.id
FROM queries q
JOIN items t APPROX NEAREST 5 BY SIMILARITY array_cosine_similarity(q.vec, t.vec);
```

---

## 7. Data-modifying CTEs

`INSERT`, `UPDATE` and `DELETE` can now live inside a `WITH` clause.

```sql
CREATE OR REPLACE TABLE staging AS FROM zscore_inputs WHERE revenue IS NULL;
CREATE OR REPLACE TABLE archive AS FROM zscore_inputs LIMIT 0;

-- Move rows: DELETE ... RETURNING feeds an INSERT, in ONE statement
WITH moved AS MATERIALIZED (
  DELETE FROM staging RETURNING *
)
INSERT INTO archive SELECT * FROM moved;

SELECT (SELECT count(*) FROM staging) AS left_in_staging,
       (SELECT count(*) FROM archive) AS in_archive;
```

```sql
-- UPDATE inside a CTE, read the result in the main query
CREATE OR REPLACE TABLE work AS FROM zscore_inputs;

WITH updated AS (
  UPDATE work SET ebit = ebit * 1.05 WHERE ticker = 'GIS' RETURNING *
)
SELECT count(*) AS rows_updated, round(avg(ebit)) AS avg_new_ebit FROM updated;
```

---

## 8. `MERGE INTO`: defined duplicate semantics

2.0 defines what happens when **several source rows match one target row**.

| Statement         | Behavior                                             |
| :---------------- | :--------------------------------------------------- |
| `MERGE INTO`      | **Errors**                                           |
| `UPDATE ... FROM` | Silently picks **one arbitrary** matching source row |

```sql
CREATE OR REPLACE TABLE m_target AS
  SELECT ticker, period_end, ebit, revenue
  FROM zscore_inputs WHERE ticker IN ('GIS', 'HSY');

CREATE OR REPLACE TABLE m_source (ticker VARCHAR, period_end DATE, ebit DOUBLE, revenue DOUBLE);
INSERT INTO m_source VALUES
  ('HSY', '2024-12-31', 3.0e9, 11.3e9),      -- matches an existing HSY row
  ('HSY', '2026-12-31', 3.2e9, 11.9e9);      -- new period

MERGE INTO m_target t
USING m_source s ON (t.ticker = s.ticker AND t.period_end = s.period_end)
WHEN MATCHED     THEN UPDATE SET ebit = s.ebit, revenue = s.revenue
WHEN NOT MATCHED THEN INSERT BY NAME
RETURNING merge_action, *;
```

**Now add a duplicate source row for one target row:**

```sql
INSERT INTO m_source VALUES ('HSY', '2024-12-31', 9.9e9, 9.9e9);

MERGE INTO m_target t
USING m_source s ON (t.ticker = s.ticker AND t.period_end = s.period_end)
WHEN MATCHED THEN UPDATE SET ebit = s.ebit;
-- Error: MERGE INTO command cannot affect the same target row more than once.

-- ...while UPDATE ... FROM silently picks ONE arbitrary matching source row
UPDATE m_target t SET ebit = s.ebit
FROM m_source s
WHERE t.ticker = s.ticker AND t.period_end = s.period_end;
```

---

## 9. WITH RECURSIVE ... USING KEY

A regular recursive CTE keeps every row it produces. A `USING KEY` CTE keeps **one row per key**: when a new row arrives with a key that already exists, it **overwrites** the old row, like a dictionary.

**The example:** start with $100 per ticker and compound it for 5 steps at each ticker's average EBIT margin.

### Setup: average EBIT margin per ticker

```sql
CREATE OR REPLACE TABLE avg_margin AS
SELECT ticker, avg(ebit / revenue) AS m
FROM zscore_inputs
GROUP BY ticker;

SELECT ticker, round(m, 4) AS avg_margin,
       round(100 * pow(1 + m, 5), 2) AS expected_step5
FROM avg_margin WHERE ticker = 'GIS';
-- GIS: avg margin about 0.153, expected step-5 value about 203.6
```

### Regular recursive CTE: every step is kept

```sql
WITH RECURSIVE proj(ticker, step, value) AS (
  SELECT ticker, 0, 100.0 FROM avg_margin
  UNION ALL
  SELECT p.ticker, p.step + 1, p.value * (1 + a.m)
  FROM proj p JOIN avg_margin a USING (ticker)
  WHERE p.step < 5
)
SELECT ticker, step, round(value, 2) AS value
FROM proj WHERE ticker = 'GIS' ORDER BY step;
```

Six rows for GIS (values approximate):

| step | value  |
| ---- | ------ |
| 0    | 100.00 |
| 1    | 115.28 |
| 2    | 132.89 |
| 3    | 153.20 |
| 4    | 176.61 |
| 5    | 203.60 |

### Same query with `USING KEY (ticker)`: only the latest row survives

```sql
WITH RECURSIVE proj(ticker, step, value) USING KEY (ticker) AS (
  SELECT ticker, 0, 100.0 FROM avg_margin
  UNION ALL
  SELECT p.ticker, p.step + 1, p.value * (1 + a.m)
  FROM proj p JOIN avg_margin a USING (ticker)
  WHERE p.step < 5
)
SELECT ticker, step, round(value, 2) AS value
FROM proj WHERE ticker = 'GIS';
```

One row for GIS:

| ticker | step | value  |
| ------ | ---- | ------ |
| GIS    | 5    | 203.60 |

`ticker` is the **key**, and `step` and `value` are the **payload**. Every iteration produces a row for the same ticker, so it replaces the previous one.

### How the row gets overwritten

| Iteration | What the recursive step does                  | Row held for GIS                  |
| --------- | --------------------------------------------- | --------------------------------- |
| start     | non-recursive part runs once                  | (GIS, 0, 100.00)                  |
| 1         | 100.00 × (1 + m)                              | **overwrites** → (GIS, 1, 115.28) |
| 2         | 115.28 × (1 + m)                              | **overwrites** → (GIS, 2, 132.89) |
| 3         | 132.89 × (1 + m)                              | **overwrites** → (GIS, 3, 153.20) |
| 4         | 153.20 × (1 + m)                              | **overwrites** → (GIS, 4, 176.61) |
| 5         | 176.61 × (1 + m)                              | **overwrites** → (GIS, 5, 203.60) |
| 6         | `WHERE p.step < 5` is false, no rows produced | iteration stops                   |

### Watch it happen: snapshot after each iteration

A table macro runs the same query but stops after `n` steps:

```sql
CREATE OR REPLACE MACRO proj_upto(n) AS TABLE
WITH RECURSIVE proj(ticker, step, value) USING KEY (ticker) AS (
  SELECT ticker, 0, 100.0 FROM avg_margin
  UNION ALL
  SELECT p.ticker, p.step + 1, p.value * (1 + a.m)
  FROM proj p JOIN avg_margin a USING (ticker)
  WHERE p.step < n
)
SELECT ticker, step, round(value, 2) AS value FROM proj;

SELECT 0 AS after_iteration, * FROM proj_upto(0) WHERE ticker = 'GIS'
UNION ALL SELECT 1, * FROM proj_upto(1) WHERE ticker = 'GIS'
UNION ALL SELECT 2, * FROM proj_upto(2) WHERE ticker = 'GIS'
UNION ALL SELECT 3, * FROM proj_upto(3) WHERE ticker = 'GIS'
UNION ALL SELECT 4, * FROM proj_upto(4) WHERE ticker = 'GIS'
UNION ALL SELECT 5, * FROM proj_upto(5) WHERE ticker = 'GIS';
```

In every snapshot the table holds exactly one GIS row, and its value grows from 100.00 to about 203.60.

### Keep the trail: carry the history in the payload

```sql
WITH RECURSIVE proj(ticker, step, value, history) USING KEY (ticker) AS (
  SELECT ticker, 0, 100.0, [100.0::DOUBLE] FROM avg_margin
  UNION ALL
  SELECT p.ticker, p.step + 1,
         p.value * (1 + a.m),
         list_append(p.history, p.value * (1 + a.m))
  FROM proj p JOIN avg_margin a USING (ticker)
  WHERE p.step < 5
)
SELECT ticker, step,
       round(value, 2) AS final_value,
       list_transform(history, lambda x : round(x, 2)) AS history
FROM proj WHERE ticker = 'GIS';
```

| ticker | step | final_value | history                                       |
| ------ | ---- | ----------- | --------------------------------------------- |
| GIS    | 5    | 203.60      | [100.0, 115.28, 132.89, 153.2, 176.61, 203.6] |

NOTE:

- A regular recursive CTE keeps history. `USING KEY` keeps state.
- It uses less memory and returns the final answer directly: one row per key.
- If you also want the trail, carry it along in a payload column.

---

## 11. JSON mutation functions

These scalar functions modify a JSON document at a given path and return the updated document. The `value` argument is a JSON value **given as JSON text**, for example `'2'` for the number 2 or `'"duck"'` for the string `duck`.

| Function       | Behavior                                            |
| :------------- | :-------------------------------------------------- |
| `json_set`     | Adds the key, or overwrites it if it exists         |
| `json_insert`  | Adds the key only if it is missing (keeps existing) |
| `json_replace` | Overwrites only if the key exists (ignores missing) |
| `json_remove`  | Removes the key                                     |

```sql
WITH j AS (
  SELECT to_json({'ticker': ticker, 'ebit': ebit}) AS doc
  FROM zscore_inputs LIMIT 1
)
SELECT doc,
       json_set(doc,     '$.rating', '"watch"') AS added_or_overwritten,
       json_insert(doc,  '$.ebit',   '0')       AS insert_keeps_existing,
       json_replace(doc, '$.rating', '"x"')     AS replace_ignores_missing,
       json_remove(doc,  '$.ebit')              AS removed
FROM j;
```

**…then straight into `VARIANT`** (ties back to the VARIANT video):

```sql
SELECT json_set(to_json({'ticker': ticker, 'ebit': ebit}), '$.source', '"edgar"')::VARIANT AS v
FROM zscore_inputs LIMIT 3;
```

### Another example

```sql
.mode line
WITH j AS (
  SELECT to_json({'ticker': ticker, 'ebit': ebit, 'rating': 'hold'}) AS doc
  FROM zscore_inputs
  WHERE ticker = 'HSY' AND period_end = DATE '2024-12-31'
)
SELECT doc,
       -- json_set: add OR overwrite
       json_set(doc,     '$.rating', '"watch"') AS set_existing,
       json_set(doc,     '$.region', '"US"')    AS set_missing,
       -- json_insert: add only, never overwrite
       json_insert(doc,  '$.rating', '"watch"') AS insert_existing,
       json_insert(doc,  '$.region', '"US"')    AS insert_missing,
       -- json_replace: overwrite only, never add
       json_replace(doc, '$.rating', '"watch"') AS replace_existing,
       json_replace(doc, '$.region', '"US"')    AS replace_missing,
       -- json_remove
       json_remove(doc,  '$.rating')            AS removed
FROM j;

.mode box

```

---

## 12. `SECURE VIEW`

A secure view doesn't leak information through statistics or query plans.

```sql
CREATE OR REPLACE VIEW normal_v AS
  SELECT ticker, ebit FROM zscore_inputs WHERE ticker = 'GIS';

CREATE OR REPLACE SECURE VIEW secure_v AS
  SELECT ticker, ebit FROM zscore_inputs WHERE ticker = 'GIS';

SELECT stats(ticker) FROM normal_v LIMIT 1;    -- leaks the filtered range
SELECT stats(ticker) FROM secure_v LIMIT 1;    -- uninformative
EXPLAIN ANALYZE SELECT * FROM secure_v;        -- single "Secure View" node
```

---

## 13. `SHOW` changes

```sql
SHOW zscore_inputs;               -- deprecated for tables, prints a warning; use DESCRIBE
DESCRIBE zscore_inputs;

SET threads = 4;
SHOW threads;                     -- settings still work

SHOW DATABASES;
SHOW SCHEMAS;

SET show_behavior = 'table';      -- 'auto' (default) | 'table' | 'setting'
SET show_behavior = 'auto';
```

---

## 14. `setval()`: set a sequence value

```sql
CREATE OR REPLACE SEQUENCE filing_id START 1;

SELECT setval('filing_id', 42);           -- next nextval = 43
SELECT nextval('filing_id');

SELECT setval('filing_id', 100, false);   -- is_called = false: next nextval = 100
SELECT nextval('filing_id');
```

---

## 15. `regexp_extract` with options

Options can now be passed without a group argument.

```sql
SELECT ticker, regexp_extract(lower(ticker), 'GIS', 'i') AS ci_match
FROM zscore_inputs
WHERE ticker = 'GIS'
LIMIT 1;                                  -- returns 'gis'
```

---
