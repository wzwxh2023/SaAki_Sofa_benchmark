-- Simple test for PostgreSQL WITH syntax
WITH 
test1 AS (
    SELECT 1 AS id, 'test' AS name
),
test2 AS (
    SELECT 2 AS id, 'test2' AS name
)
SELECT * FROM test1 UNION ALL SELECT * FROM test2;
