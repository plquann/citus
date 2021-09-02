CREATE OR REPLACE FUNCTION pg_catalog.get_missing_partition_ranges(
    table_name regclass,
    to_date timestamptz,
    start_from timestamptz DEFAULT NULL)
returns table(
    partition_name text,
    range_from_value text,
    range_to_value text)
LANGUAGE plpgsql
AS $$
DECLARE
    current_partition_count int;
    table_partition_interval INTERVAL;
    table_partition_column_type_name text;
    manual_partition_from_value_text text;
    manual_partition_to_value_text text;
    current_range_from_value timestamptz := NULL;
    current_range_to_value timestamptz := NULL;
    current_range_from_value_text text;
    current_range_to_value_text text;
    datetime_string_format text;
    max_table_name_length int;
BEGIN
    /*
     * First check whether such timeseries table exists. If not, error out.
     *
     * Then check if start_from is given. If it is, create the range using that time
     * and let remaining of the function fill the gap till to_date.
     */

    SELECT partitioninterval
    INTO table_partition_interval
    FROM timeseries.tables
    WHERE logicalrelid = table_name;

    IF NOT found THEN
        RAISE '% must be timeseries table', table_name;
    END IF;

    IF start_from IS NOT NULL THEN

        SELECT count(*)
        INTO current_partition_count
        FROM pg_catalog.time_partitions
        WHERE parent_table = table_name;

        /*
         * If any partition exist for the given table, we must start from the initial partition
         * for that table and go backward to have consistent range values. Otherwise, if we start
         * directly from the given start_from, we may end up with inconsistent range values.
         */
        IF current_partition_count > 0 THEN
            SELECT from_value::timestamptz, to_value::timestamptz
            INTO current_range_from_value, current_range_to_value
            FROM pg_catalog.time_partitions
            WHERE parent_table = table_name
            ORDER BY from_value::timestamptz ASC
            LIMIT 1;

            IF start_from >= current_range_from_value THEN
                RAISE 'given start_from value must be before any of the existing partition ranges';
            END IF;

            WHILE current_range_from_value > start_from LOOP
                 current_range_from_value := current_range_from_value - table_partition_interval;
            END LOOP;

            current_range_to_value := current_range_from_value + table_partition_interval;
        ELSE
            /*
             * Decide on the current_range_from_value of the initial partition according to interval of the timeseries table.
             * Since we will create all other partitions by adding intervals, truncating given start time will provide
             * more intuitive interval ranges, instead of starting from start_from directly.
             */
            IF table_partition_interval < INTERVAL '1 hour' THEN
                current_range_from_value = date_trunc('minute', start_from);
            ELSIF table_partition_interval < INTERVAL '1 day' THEN
                current_range_from_value = date_trunc('hour', start_from);
            ELSIF table_partition_interval < INTERVAL '1 week' THEN
                current_range_from_value = date_trunc('day', start_from);
            ELSIF table_partition_interval < INTERVAL '1 month' THEN
                current_range_from_value = date_trunc('week', start_from);
            ELSIF table_partition_interval < INTERVAL '1 year' THEN
                current_range_from_value = date_trunc('month', start_from);
            ELSE
                current_range_from_value = date_trunc('year', start_from);
            END IF;

            current_range_to_value := current_range_from_value + table_partition_interval;
        END IF;
    END IF;

    /*
     * To be able to fill any gaps after the initial partition of the timeseries table,
     * we are starting from the first partition instead of the last. If start_from
     * is given we've already used that to initiate ranges.
     *
     * Note that we must have either start_from or an initial partition for the timeseries
     * table, as we call that function while creating timeseries table first.
     */
    IF current_range_from_value IS NULL AND current_range_to_value IS NULL THEN
        SELECT from_value::timestamptz, to_value::timestamptz
        INTO current_range_from_value, current_range_to_value
        FROM pg_catalog.time_partitions
        WHERE parent_table = table_name
        ORDER BY from_value::timestamptz ASC
        LIMIT 1;
    END IF;

    /*
     * Get datatype here to generate range values in the right data format
     * Since we already check that timeseries tables have single column to partition the table
     * we can directly get the 0th element of the partattrs column
     */
    SELECT atttypid::regtype::text
    INTO table_partition_column_type_name
    FROM pg_attribute
    WHERE attrelid = table_name::oid
    AND attnum = (select partattrs[0] from pg_partitioned_table where partrelid = table_name::oid);

    /*
     * Get max_table_name_length to use it while finding partitions' name
     */
    SELECT max_val
    INTO max_table_name_length
    FROM pg_settings
    WHERE name = 'max_identifier_length';

    /* reuse pg_partman naming scheme for back-and-forth migration */
    IF table_partition_interval = INTERVAL '3 months' THEN
        /* include quarter in partition name */
        datetime_string_format = 'YYYY"q"Q';
    ELSIF table_partition_interval = INTERVAL '1 week' THEN
        /* include week number in partition name */
        datetime_string_format := 'IYYY"w"IW';
    ELSE
        /* in all other cases, start with the year */
        datetime_string_format := 'YYYY';

        IF table_partition_interval < INTERVAL '1 year'
            /* include month in partition name */
            datetime_string_format := datetime_string_format || '_MM';
        END IF;

        IF table_partition_interval < INTERVAL '1 month' THEN
            /* include day of month in partition name */
            datetime_string_format := datetime_string_format || '_DD';
        END IF;

        IF table_partition_interval < INTERVAL '1 day' THEN
            /* include time of day in partition name */
            datetime_string_format := datetime_string_format || '_HH24MI';
        END IF;

        IF table_partition_interval < INTERVAL '1 minute' THEN
             /* include seconds in time of day in partition name */
             datetime_string_format := datetime_string_format || 'SS';
        END IF;
    END IF;

    WHILE current_range_from_value < to_date LOOP
        /*
         * Check whether partition with given range has already been created
         * Since partition interval can be given with different types, we are converting
         * all variables to timestamptz to make sure that we are comparing same type of parameters
         */
        PERFORM * FROM pg_catalog.time_partitions
        WHERE
            from_value::timestamptz = current_range_from_value::timestamptz AND
            to_value::timestamptz = current_range_to_value::timestamptz AND
            parent_table = table_name;
        IF found THEN
            current_range_from_value := current_range_to_value;
            current_range_to_value := current_range_to_value + table_partition_interval;
            CONTINUE;
        END IF;

        /*
         * Check whether any other partition covers from_value or to_value
         * That means some partitions have been created manually and we must error out.
         */
        SELECT from_value::text, to_value::text
        INTO manual_partition_from_value_text, manual_partition_to_value_text
        FROM pg_catalog.time_partitions
        WHERE
            ((current_range_from_value::timestamptz > from_value::timestamptz AND current_range_from_value < to_value::timestamptz) OR
            (current_range_to_value::timestamptz > from_value::timestamptz AND current_range_to_value::timestamptz < to_value::timestamptz)) AND
            parent_table = table_name;

        IF found THEN
            RAISE 'Partition with the range from % to % has been created manually. Please remove all manually created partitions to use the table as timeseries table',
            manual_partition_from_value_text,
            manual_partition_to_value_text;
        END IF;

        /*
         * Use range values within the name of partition to have unique partition names. We need to
         * convert values which are not proper for table to '_'.
         */
        IF table_partition_column_type_name = 'date' THEN
            SELECT current_range_from_value::date::text INTO current_range_from_value_text;
            SELECT current_range_to_value::date::text INTO current_range_to_value_text;
        ELSIF table_partition_column_type_name = 'timestamp without time zone' THEN
            SELECT current_range_from_value::timestamp::text INTO current_range_from_value_text;
            SELECT current_range_to_value::timestamp::text INTO current_range_to_value_text;
        ELSIF table_partition_column_type_name = 'timestamp with time zone' THEN
            SELECT current_range_from_value::timestamptz::text INTO current_range_from_value_text;
            SELECT current_range_to_value::timestamptz::text INTO current_range_to_value_text;
        ELSE
            RAISE 'type of the partition column of the table % must be date, timestamp or timestamptz', table_name;
        END IF;

        RETURN QUERY
        SELECT
            substring(table_name::text, 0, max_table_name_length - length(to_char(current_range_from_value, datetime_string_format)) - 1) || '_p' ||
            to_char(current_range_from_value, datetime_string_format),
            current_range_from_value_text,
            current_range_to_value_text;

        current_range_from_value := current_range_to_value;
        current_range_to_value := current_range_to_value + table_partition_interval;
    END LOOP;

    RETURN;
END;
$$;
COMMENT ON FUNCTION pg_catalog.create_missing_partitions(
	table_name regclass,
    to_date timestamptz,
    start_from timestamptz)
IS 'create missing partitions for the given timeseries table';
