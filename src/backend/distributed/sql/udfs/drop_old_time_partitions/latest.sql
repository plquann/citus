-- Heavily inspired by the procedure alter_old_partitions_set_access_method
CREATE OR REPLACE PROCEDURE pg_catalog.drop_old_time_partitions(
	parent_table_name regclass,
	older_than timestamptz)
LANGUAGE plpgsql
AS $$
DECLARE
    r record;
	schema_name_text text;
BEGIN
	/* first check whether we can convert all the to_value's to timestamptz */
	BEGIN
		PERFORM
		FROM pg_catalog.time_partitions
		WHERE parent_table = parent_table_name
		AND to_value IS NOT NULL
		AND to_value::timestamptz <= older_than;
	EXCEPTION WHEN invalid_datetime_format THEN
		RAISE 'partition column of % cannot be cast to a timestamptz', parent_table_name;
	END;

    FOR r IN
		SELECT partition, nspname AS schema_name, relname AS table_name, from_value, to_value
		FROM pg_catalog.time_partitions, pg_catalog.pg_class c, pg_catalog.pg_namespace n
		WHERE parent_table = parent_table_name AND partition = c.oid AND c.relnamespace = n.oid
		AND to_value IS NOT NULL
		AND to_value::timestamptz <= older_than
		ORDER BY to_value::timestamptz
    LOOP
        RAISE NOTICE 'dropping % with start time % and end time %', r.partition, r.from_value, r.to_value;
        EXECUTE format('DROP TABLE %I.%I', r.schema_name, r.table_name);
    END LOOP;
END;
$$;
COMMENT ON PROCEDURE pg_catalog.drop_old_time_partitions(
	parent_table_name regclass,
	older_than timestamptz)
IS 'drop old partitions of a time-partitioned table';
