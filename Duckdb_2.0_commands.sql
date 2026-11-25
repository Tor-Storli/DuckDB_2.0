-- Open an existing database
duckdb
.open "C:/Users/storl/Desktop/Earnings_Analysis/financials.db"

-- The .tables command will return a list of tables in the database.
.tables

-- To filter to only tables that contain an du, use the LIKE pattern %du%.
.tables %du%

-- To see all SQL Statements in the database, use the .schema command
.schema

-- To see a filtered list of SQL Statements in the database, use the .schema %xxx% command
.schema %du%

-- To remove automatic pretty print for the SQL Statements (indention) use the --no-indent command
.schema %du% --no-indent

-- The .dump command shows the database content as SQL statements, including both schema definitions and data. 
-- Useful for creating backups or migrating data.
.dump

-- To get a filtered list
.dump %du%

-- To allow unescaped newline characters in the output:
.dump --newlines

-- To allow unescaped newline characters in the output:
.dump %du% %INSERT INTO% --newlines

-- Duckdb Function Documentation
https://duckdb.org/docs/2.0/sql/meta/duckdb_table_functions#duckdb_functions

-- To see a duckdb database functions signatures
.manual list
.manual .manual regexp_extract
.manual max
.manual .manual starts_with

