-- SERVER
--------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "SERVER> "

CALL quack_serve(
    token = 'my_token'
);

CREATE TABLE events
    (date DATE, name VARCHAR);

INSERT INTO events VALUES
    ('2027-04-07',
     'DuckCon #8');


CLIENT 1
------------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "CLIENT 1> "

ATTACH 'quack:localhost'
    AS qk1 (TOKEN 'my_token');

CONNECT qk1;
SELECT * FROM events;


CLIENT 2
------------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "CLIENT 2> "

ATTACH 'quack:localhost'
    AS qk2 (TOKEN 'my_token');

CONNECT qk2;
SELECT * FROM events;

------------------
-- A real Example
-----------------
-- SERVER
--------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "SERVER> "

.open "C:/Users/storl/Desktop/Earnings_Analysis/financials.db"

show tables;

CALL quack_serve(
    token = 'my_financials'
);



CLIENT 1
------------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "CLIENT 1> "

ATTACH 'quack:localhost'
    AS qk1 (TOKEN 'my_financials');

CONNECT qk1;
FROM companies;


CLIENT 2
------------------------
-- Open a new command window and type in "duckdb"
-- C:\Users\storl>duckdb
duckdb

.prompt "CLIENT 2> "

ATTACH 'quack:localhost'
    AS qk2 (TOKEN 'my_financials');

CONNECT qk2;
from  dupont_avg limit 10;












