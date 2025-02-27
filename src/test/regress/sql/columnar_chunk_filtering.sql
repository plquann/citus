--
-- Test chunk filtering in columnar using min/max values in stripe skip lists.
--


--
-- filtered_row_count returns number of rows filtered by the WHERE clause.
-- If chunks get filtered by columnar, less rows are passed to WHERE
-- clause, so this function should return a lower number.
--
CREATE OR REPLACE FUNCTION filtered_row_count (query text) RETURNS bigint AS
$$
    DECLARE
        result bigint;
        rec text;
    BEGIN
        result := 0;

        FOR rec IN EXECUTE 'EXPLAIN ANALYZE ' || query LOOP
            IF rec ~ '^\s+Rows Removed by Filter' then
                result := regexp_replace(rec, '[^0-9]*', '', 'g');
            END IF;
        END LOOP;

        RETURN result;
    END;
$$ LANGUAGE PLPGSQL;

set columnar.qual_pushdown_correlation = 0.0;

-- Create and load data
-- chunk_group_row_limit '1000', stripe_row_limit '2000'
set columnar.stripe_row_limit = 2000;
set columnar.chunk_group_row_limit = 1000;
CREATE TABLE test_chunk_filtering (a int)
    USING columnar;

INSERT INTO test_chunk_filtering SELECT generate_series(1,10000);


-- Verify that filtered_row_count is less than 1000 for the following queries
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a < 200');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a > 200');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a < 9900');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a > 9900');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a < 0');


-- Verify that filtered_row_count is less than 2000 for the following queries
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a BETWEEN 1 AND 10');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a BETWEEN 990 AND 2010');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a BETWEEN -10 AND 0');


-- Load data for second time and verify that filtered_row_count is exactly twice as before
INSERT INTO test_chunk_filtering SELECT generate_series(1,10000);
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a < 200');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a < 0');
SELECT filtered_row_count('SELECT count(*) FROM test_chunk_filtering WHERE a BETWEEN 990 AND 2010');

set columnar.stripe_row_limit to default;
set columnar.chunk_group_row_limit to default;

-- Verify that we are fine with collations which use a different alphabet order
CREATE TABLE collation_chunk_filtering_test(A text collate "da_DK")
    USING columnar;
COPY collation_chunk_filtering_test FROM STDIN;
A
Å
B
\.

SELECT * FROM collation_chunk_filtering_test WHERE A > 'B';

CREATE TABLE simple_chunk_filtering(i int) USING COLUMNAR;
INSERT INTO simple_chunk_filtering SELECT generate_series(0,234567);
EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT * FROM simple_chunk_filtering WHERE i > 123456;
SET columnar.enable_qual_pushdown = false;
EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT * FROM simple_chunk_filtering WHERE i > 123456;
SET columnar.enable_qual_pushdown TO DEFAULT;

-- https://github.com/citusdata/citus/issues/4555
TRUNCATE simple_chunk_filtering;
INSERT INTO simple_chunk_filtering SELECT generate_series(0,200000);
COPY (SELECT * FROM simple_chunk_filtering WHERE i > 180000) TO '/dev/null';
EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT * FROM simple_chunk_filtering WHERE i > 180000;

DROP TABLE simple_chunk_filtering;


CREATE TABLE multi_column_chunk_filtering(a int, b int) USING columnar;
INSERT INTO multi_column_chunk_filtering SELECT i,i+1 FROM generate_series(0,234567) i;

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT count(*) FROM multi_column_chunk_filtering WHERE a > 50000;

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT count(*) FROM multi_column_chunk_filtering WHERE a > 50000 AND b > 50000;

-- make next tests faster
TRUNCATE multi_column_chunk_filtering;
INSERT INTO multi_column_chunk_filtering SELECT generate_series(0,5);

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT b FROM multi_column_chunk_filtering WHERE a > 50000 AND b > 50000;

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT b, a FROM multi_column_chunk_filtering WHERE b > 50000;

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT FROM multi_column_chunk_filtering WHERE a > 50000;

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT FROM multi_column_chunk_filtering;

BEGIN;
  ALTER TABLE multi_column_chunk_filtering DROP COLUMN a;
  ALTER TABLE multi_column_chunk_filtering DROP COLUMN b;
  EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT * FROM multi_column_chunk_filtering;
ROLLBACK;

CREATE TABLE another_columnar_table(x int, y int) USING columnar;
INSERT INTO another_columnar_table SELECT generate_series(0,5);

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT a, y FROM multi_column_chunk_filtering, another_columnar_table WHERE x > 1;

EXPLAIN (costs off, timing off, summary off)
  SELECT y, * FROM another_columnar_table;

EXPLAIN (costs off, timing off, summary off)
  SELECT *, x FROM another_columnar_table;

EXPLAIN (costs off, timing off, summary off)
  SELECT y, another_columnar_table FROM another_columnar_table;

EXPLAIN (costs off, timing off, summary off)
  SELECT another_columnar_table, x FROM another_columnar_table;

DROP TABLE multi_column_chunk_filtering, another_columnar_table;

--
-- https://github.com/citusdata/citus/issues/4780
--
create table part_table (id int) partition by range (id);
create table part_1_row partition of part_table for values from (150000) to (160000);
create table part_2_columnar partition of part_table for values from (0) to (150000) using columnar;
insert into part_table select generate_series(1,159999);
select filtered_row_count('select count(*) from part_table where id > 75000');
drop table part_table;

-- test join parameterization

set columnar.stripe_row_limit = 2000;
set columnar.chunk_group_row_limit = 1000;

create table r1(id1 int, n1 int); -- row
create table r2(id2 int, n2 int); -- row
create table r3(id3 int, n3 int); -- row
create table r4(id4 int, n4 int); -- row
create table r5(id5 int, n5 int); -- row
create table r6(id6 int, n6 int); -- row
create table r7(id7 int, n7 int); -- row

create table coltest(id int, x1 int, x2 int, x3 int) using columnar;
create table coltest_part(id int, x1 int, x2 int, x3 int)
  partition by range (id);
create table coltest_part0
  partition of coltest_part for values from (0) to (10000)
  using columnar;
create table coltest_part1
  partition of coltest_part for values from (10000) to (20000); -- row

set columnar.stripe_row_limit to default;
set columnar.chunk_group_row_limit to default;

insert into r1 values(1234, 12350);
insert into r1 values(4567, 45000);
insert into r1 values(9101, 176000);
insert into r1 values(14202, 7);
insert into r1 values(18942, 189430);

insert into r2 values(1234, 123502);
insert into r2 values(4567, 450002);
insert into r2 values(9101, 1760002);
insert into r2 values(14202, 72);
insert into r2 values(18942, 1894302);

insert into r3 values(1234, 1235075);
insert into r3 values(4567, 4500075);
insert into r3 values(9101, 17600075);
insert into r3 values(14202, 775);
insert into r3 values(18942, 18943075);

insert into r4 values(1234, -1);
insert into r5 values(1234, -1);
insert into r6 values(1234, -1);
insert into r7 values(1234, -1);

insert into coltest
  select g, g*10, g*100, g*1000 from generate_series(0, 19999) g;
insert into coltest_part
  select g, g*10, g*100, g*1000 from generate_series(0, 19999) g;

ANALYZE r1, r2, r3, coltest, coltest_part;

-- force nested loop
set enable_mergejoin=false;
set enable_hashjoin=false;
set enable_material=false;

-- test different kinds of expressions
EXPLAIN (analyze on, costs off, timing off, summary off)
SELECT * FROM r1, coltest WHERE
  id1 = id AND x1 > 15000 AND x1::text > '000000' AND n1 % 10 = 0;
SELECT * FROM r1, coltest WHERE
  id1 = id AND x1 > 15000 AND x1::text > '000000' AND n1 % 10 = 0;

-- test equivalence classes

EXPLAIN (analyze on, costs off, timing off, summary off)
SELECT * FROM r1, r2, r3, r4, r5, r6, r7, coltest WHERE
  id = id1 AND id1 = id2 AND id2 = id3 AND id3 = id4 AND
  id4 = id5 AND id5 = id6 AND id6 = id7;
SELECT * FROM r1, r2, r3, r4, r5, r6, r7, coltest WHERE
  id = id1 AND id1 = id2 AND id2 = id3 AND id3 = id4 AND
  id4 = id5 AND id5 = id6 AND id6 = id7;

-- test path generation with different thresholds

set columnar.planner_debug_level = 'notice';
set columnar.max_custom_scan_paths to 10;

EXPLAIN (costs off, timing off, summary off)
  SELECT * FROM coltest c1, coltest c2, coltest c3, coltest c4 WHERE
    c1.id = c2.id and c1.id = c3.id and c1.id = c4.id;

set columnar.max_custom_scan_paths to 2;

EXPLAIN (costs off, timing off, summary off)
  SELECT * FROM coltest c1, coltest c2, coltest c3, coltest c4 WHERE
    c1.id = c2.id and c1.id = c3.id and c1.id = c4.id;

set columnar.max_custom_scan_paths to default;

set columnar.planner_debug_level to default;

-- test more complex parameterization

set columnar.planner_debug_level = 'notice';

EXPLAIN (analyze on, costs off, timing off, summary off)
SELECT * FROM r1, r2, r3, coltest WHERE
  id1 = id2 AND id2 = id3 AND id3 = id AND
  n1 > x1 AND n2 > x2 AND n3 > x3;

set columnar.planner_debug_level to default;

SELECT * FROM r1, r2, r3, coltest WHERE
  id1 = id2 AND id2 = id3 AND id3 = id AND
  n1 > x1 AND n2 > x2 AND n3 > x3;

-- test partitioning parameterization
EXPLAIN (analyze on, costs off, timing off, summary off)
SELECT * FROM r1, coltest_part WHERE
  id1 = id AND n1 > x1;
SELECT * FROM r1, coltest_part WHERE
  id1 = id AND n1 > x1;

set enable_mergejoin to default;
set enable_hashjoin to default;
set enable_material to default;

set columnar.planner_debug_level = 'notice';

alter table coltest add column x5 int default (random()*20000)::int;
analyze coltest;

-- test that expressions on whole-row references are not pushed down
select * from coltest where coltest = (1,1,1,1);

-- test that expressions on uncorrelated attributes are not pushed down
set columnar.qual_pushdown_correlation to default;
select * from coltest where x5 = 23484;

-- test that expressions on volatile functions are not pushed down
create function vol() returns int language plpgsql as $$
BEGIN
  RETURN 1;
END;
$$;
select * from coltest where x3 = vol();

EXPLAIN (analyze on, costs off, timing off, summary off)
  SELECT * FROM coltest c1 WHERE ceil(x1) > 4222;

set columnar.planner_debug_level to default;

--
-- https://github.com/citusdata/citus/issues/4488
--
create table columnar_prepared_stmt (x int, y int) using columnar;
insert into columnar_prepared_stmt select s, s from generate_series(1,5000000) s;
prepare foo (int) as select x from columnar_prepared_stmt where x = $1;
execute foo(3);
execute foo(3);
execute foo(3);
execute foo(3);
select filtered_row_count('execute foo(3)');
select filtered_row_count('execute foo(3)');
select filtered_row_count('execute foo(3)');
select filtered_row_count('execute foo(3)');
drop table columnar_prepared_stmt;
