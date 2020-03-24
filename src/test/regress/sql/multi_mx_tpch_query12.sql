--
-- MULTI_MX_TPCH_QUERY12
--


-- connect to the coordinator
\c - - :master_host :master_port

-- Query #12 from the TPC-H decision support benchmark

SELECT
	l_shipmode,
	sum(case
		when o_orderpriority = '1-URGENT'
			 OR o_orderpriority = '2-HIGH'
		then 1
		else 0
	end) as high_line_count,
	sum(case
		when o_orderpriority <> '1-URGENT'
			 AND o_orderpriority <> '2-HIGH'
		then 1
		else 0
		end) AS low_line_count
FROM
	orders_mx,
	lineitem_mx
WHERE
	o_orderkey = l_orderkey
	AND l_shipmode in ('MAIL', 'SHIP')
	AND l_commitdate < l_receiptdate
	AND l_shipdate < l_commitdate
	AND l_receiptdate >= date '1994-01-01'
	AND l_receiptdate < date '1994-01-01' + interval '1' year
GROUP BY
	l_shipmode
ORDER BY
	l_shipmode;

-- connect one of the workers
\c - - :public_worker_1_host :worker_1_port

-- Query #12 from the TPC-H decision support benchmark

SELECT
	l_shipmode,
	sum(case
		when o_orderpriority = '1-URGENT'
			 OR o_orderpriority = '2-HIGH'
		then 1
		else 0
	end) as high_line_count,
	sum(case
		when o_orderpriority <> '1-URGENT'
			 AND o_orderpriority <> '2-HIGH'
		then 1
		else 0
		end) AS low_line_count
FROM
	orders_mx,
	lineitem_mx
WHERE
	o_orderkey = l_orderkey
	AND l_shipmode in ('MAIL', 'SHIP')
	AND l_commitdate < l_receiptdate
	AND l_shipdate < l_commitdate
	AND l_receiptdate >= date '1994-01-01'
	AND l_receiptdate < date '1994-01-01' + interval '1' year
GROUP BY
	l_shipmode
ORDER BY
	l_shipmode;

-- connect to the other worker node
\c - - :public_worker_2_host :worker_2_port

-- Query #12 from the TPC-H decision support benchmark

SELECT
	l_shipmode,
	sum(case
		when o_orderpriority = '1-URGENT'
			 OR o_orderpriority = '2-HIGH'
		then 1
		else 0
	end) as high_line_count,
	sum(case
		when o_orderpriority <> '1-URGENT'
			 AND o_orderpriority <> '2-HIGH'
		then 1
		else 0
		end) AS low_line_count
FROM
	orders_mx,
	lineitem_mx
WHERE
	o_orderkey = l_orderkey
	AND l_shipmode in ('MAIL', 'SHIP')
	AND l_commitdate < l_receiptdate
	AND l_shipdate < l_commitdate
	AND l_receiptdate >= date '1994-01-01'
	AND l_receiptdate < date '1994-01-01' + interval '1' year
GROUP BY
	l_shipmode
ORDER BY
	l_shipmode;
