CREATE OR REPLACE FUNCTION pg_catalog.get_missing_partition_ranges(
    table_name regclass,
    to_date timestamptz,
    start_from timestamptz DEFAULT NULL,
    partition_interval interval DEFAULT NULL)
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
    SELECT to_value::timestamptz - from_value::timestamptz
    INTO table_partition_interval
    FROM pg_catalog.time_partitions
    WHERE parent_table = table_name
    ORDER BY from_value::timestamptz ASC
    LIMIT 1;

    IF NOT FOUND THEN
        /* first partition, use the parameter */
        table_partition_interval := partition_interval;

        IF partition_interval IS NULL THEN
            RAISE 'must specify a partition_interval when there are no partitions yet';
        ELSIF start_from IS NULL THEN
            start_from := now() - 7 * partition_interval;
        END IF;
    ELSE
        IF partition_interval IS NOT NULL AND partition_interval <> table_partition_interval THEN
            RAISE 'partition_interval does not match existing partitions';
        END IF;
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

    -- Follow the same naming schema with pg_partman
    -- to allow easy migration
    datetime_string_format := 'YYYY';
    IF table_partition_interval < '1 year' THEN
        IF table_partition_interval = INTERVAL '3 months' THEN
            datetime_string_format = 'YYYY"q"Q';
        ELSE
            datetime_string_format := datetime_string_format || '_MM';
        END IF;

        IF table_partition_interval < '1 month' THEN
            IF table_partition_interval = INTERVAL '1 week' THEN
                datetime_string_format := 'IYYY"w"IW';
            ELSE
                datetime_string_format := datetime_string_format || '_DD';
            END IF;

            IF table_partition_interval < '1 day' THEN
                datetime_string_format := datetime_string_format || '_HH24MI';
                IF table_partition_interval < '1 minute' THEN
                    datetime_string_format := datetime_string_format || 'SS';
                END IF;
            END IF;
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
    start_from timestamptz,
    partition_interval interval)
IS 'create missing partitions for the given timeseries table';
