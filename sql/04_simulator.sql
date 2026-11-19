-- =====================================================================
-- 04_simulator.sql
-- A GPS simulator with two modes that share the same movement model:
--   LIVE         an adjustable clock advances and, on every tick, each trip that
--                is currently running emits the GPS fixes that have become due.
--                The triggers (file 03) update the database as the fixes arrive.
--   FAST-FORWARD plays whole past days at once, to build history (typical
--                speeds per road, lateness patterns) before a live demo.
-- It generates ONLY raw GPS fixes (and ground truth in schema sim). Stop
-- times, trip status, route matches and traversals are derived by the database.
--
-- Run in : pgAdmin 4 > Query Tool on campus_shuttle, after files 01-03
--          (or from psql / PowerShell; see README for the live loop).
-- Changes: creates functions and one procedure in schemas sim and public.
--          Nothing is inserted until you call the functions (see PART 3).
--
-- Random (reproducible with a seed): speed factor per trip (0.8-1.2 of the
--   road limit, capped at 25 km/h), start offset, dwell 15-45 s, speed noise per
--   segment, GPS noise (+/- 6 m per axis), time jitter, 2% fix dropout.
-- Systematic: congestion at class changes (minutes :50-:10 of each hour,
--   08:00-17:59), strongest on roads in academic/administrative zones; one
--   injected incident per run; knock-on delay (a vehicle cannot start its next
--   trip before it has finished the previous one + 60 s).
-- Limits: vehicles teleport between a trip's end and the next trip's start;
--   closures do not reroute; no skipped stops. Terminal GPS emission ends at final-stop arrival.
-- =====================================================================


-- =====================================================================
-- PART 1: movement model
-- =====================================================================
CREATE OR REPLACE FUNCTION sim.new_run(p_seed bigint, p_description text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE rid integer;
BEGIN
    INSERT INTO sim.run (seed, parameters, description)
    VALUES (p_seed, jsonb_build_object('simulator', 'v3', 'gps_noise_m', 6, 'fix_interval_s', 5,
                                       'dropout', 0.02, 'speed_cap_kmh', 25), p_description)
    RETURNING run_id INTO rid;
    PERFORM setseed(((p_seed % 1000000) / 1000000.0)::double precision);
    RETURN rid;
END $$;

-- Speed multiplier (1 = free flow) for a road at a time within a run.
CREATE OR REPLACE FUNCTION sim.congestion_factor(p_road_id integer, p_ts timestamp, p_run_id integer)
RETURNS double precision LANGUAGE plpgsql STABLE AS $$
DECLARE f double precision := 1.0; central boolean; m numeric;
BEGIN
    IF EXTRACT(HOUR FROM p_ts) BETWEEN 8 AND 17
       AND (EXTRACT(MINUTE FROM p_ts) >= 50 OR EXTRACT(MINUTE FROM p_ts) < 10) THEN
        SELECT EXISTS (
            SELECT 1 FROM public.road_segments r
            JOIN public.campus_zones z ON ST_Intersects(z.boundary, ST_LineInterpolatePoint(r.geom, 0.5))
            WHERE r.road_id = p_road_id AND z.zone_type IN ('academic', 'service')) INTO central;
        f := f * CASE WHEN central THEN 0.60 ELSE 0.90 END;
    END IF;
    SELECT min(e.magnitude) INTO m
    FROM sim.injected_event e
    WHERE e.run_id = p_run_id AND e.event_type = 'congestion' AND e.road_id = p_road_id AND e.valid_period @> p_ts;
    IF m IS NOT NULL THEN f := f * m::double precision; END IF;
    RETURN f;
END $$;

-- Build a trip's movement plan: when the bus is at which distance along its route
-- (driving, then dwelling at each stop). Stored in sim.trip_plan; true stop times
-- go to sim.true_stop_visit.
CREATE OR REPLACE FUNCTION sim.plan_trip(p_trip_id integer, p_run_id integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    t record;
    sg record;
    stp integer;
    last_stp integer;
    times double precision[];
    meas double precision[];
    clk double precision;
    trip_factor double precision;
    v_ms double precision;
    lim double precision;
    dwell double precision;
    prev_end timestamp;
    min_off double precision;
BEGIN
    SELECT tr.trip_id, tr.vehicle_id, tr.route_id, tr.scheduled_start
    INTO t
    FROM public.trips tr
    WHERE tr.trip_id = p_trip_id;

    IF t.trip_id IS NULL THEN
        RAISE EXCEPTION 'trip % not found', p_trip_id;
    END IF;

    SELECT max(stop_sequence)
    INTO last_stp
    FROM public.route_stops
    WHERE route_id = t.route_id;

    IF NOT EXISTS (
        SELECT 1
        FROM public.route_segments
        WHERE route_id = t.route_id
    ) THEN
        RAISE EXCEPTION 'route % has not been built', t.route_id;
    END IF;

    trip_factor := 0.80 + random() * 0.40;
    clk := (random() - 0.4) * 180; -- -72 s .. +108 s relative to schedule

    -- The vehicle cannot start before it finished its previous simulated trip.
    SELECT max(tv.true_departure)
    INTO prev_end
    FROM sim.true_stop_visit tv
    JOIN public.trips p2 ON p2.trip_id = tv.trip_id
    WHERE tv.run_id = p_run_id
      AND p2.vehicle_id = t.vehicle_id
      AND p2.scheduled_start < t.scheduled_start;

    IF prev_end IS NOT NULL THEN
        min_off := EXTRACT(
            EPOCH FROM (prev_end + interval '60 seconds' - t.scheduled_start)
        );
        clk := greatest(clk, min_off);
    END IF;

    DELETE FROM sim.true_stop_visit
    WHERE run_id = p_run_id
      AND trip_id = p_trip_id;

    -- Initial stop: retain its normal dwell.
    dwell := 15 + random() * 30;

    SELECT stop_sequence
    INTO stp
    FROM public.route_stops
    WHERE route_id = t.route_id
      AND distance_from_start_m < 1
    ORDER BY stop_sequence
    LIMIT 1;

    INSERT INTO sim.true_stop_visit (
        run_id, trip_id, stop_sequence, true_arrival, true_departure
    )
    VALUES (
        p_run_id,
        p_trip_id,
        stp,
        t.scheduled_start + make_interval(secs => clk),
        t.scheduled_start + make_interval(secs => clk + dwell)
    );

    times := ARRAY[clk];
    meas := ARRAY[0.0::double precision];

    clk := clk + dwell;
    times := times || clk;
    meas := meas || 0.0::double precision;

    FOR sg IN
        SELECT
            rs.road_id,
            rs.start_measure_m,
            rs.end_measure_m,
            rd.speed_limit_kmh
        FROM public.route_segments rs
        JOIN public.road_segments rd USING (road_id)
        WHERE rs.route_id = t.route_id
        ORDER BY rs.seq
    LOOP
        lim := least(coalesce(sg.speed_limit_kmh, 25), 25);

        v_ms := greatest(
            lim * trip_factor
            * sim.congestion_factor(
                sg.road_id,
                t.scheduled_start + make_interval(secs => clk),
                p_run_id
            )
            * (0.9 + random() * 0.2),
            4
        ) / 3.6;

        clk := clk
            + (sg.end_measure_m - sg.start_measure_m)::double precision / v_ms;

        times := times || clk;
        meas := meas || sg.end_measure_m::double precision;

        SELECT stop_sequence
        INTO stp
        FROM public.route_stops
        WHERE route_id = t.route_id
          AND abs(distance_from_start_m - sg.end_measure_m) < 1
        ORDER BY stop_sequence
        LIMIT 1;

        IF FOUND THEN
            IF stp = last_stp THEN
                -- Terminal stop: record its visit, but do not append a dwell
                -- interval to the GPS movement plan. The schema currently
                -- requires true_departure NOT NULL, so retain the 20-second
                -- terminal dwell in ground truth only.
                INSERT INTO sim.true_stop_visit (
                    run_id, trip_id, stop_sequence, true_arrival, true_departure
                )
                VALUES (
                    p_run_id,
                    p_trip_id,
                    stp,
                    t.scheduled_start + make_interval(secs => clk),
                    t.scheduled_start + make_interval(secs => clk + 20)
                )
                ON CONFLICT (run_id, trip_id, stop_sequence) DO NOTHING;

                -- Do not advance clk or append another same-measure point.
                -- GPS emission therefore ends at final-stop arrival.
            ELSE
                dwell := 15 + random() * 30;

                INSERT INTO sim.true_stop_visit (
                    run_id, trip_id, stop_sequence, true_arrival, true_departure
                )
                VALUES (
                    p_run_id,
                    p_trip_id,
                    stp,
                    t.scheduled_start + make_interval(secs => clk),
                    t.scheduled_start + make_interval(secs => clk + dwell)
                )
                ON CONFLICT (run_id, trip_id, stop_sequence) DO NOTHING;

                clk := clk + dwell;
                times := times || clk;
                meas := meas || sg.end_measure_m::double precision;
            END IF;
        END IF;
    END LOOP;

    INSERT INTO sim.trip_plan (
        trip_id, run_id, times_s, measures_m, last_emit_s, done
    )
    VALUES (
        p_trip_id, p_run_id, times, meas, NULL, false
    )
    ON CONFLICT (trip_id) DO UPDATE
    SET run_id = EXCLUDED.run_id,
        times_s = EXCLUDED.times_s,
        measures_m = EXCLUDED.measures_m,
        last_emit_s = NULL,
        done = false;
END;
$$;

-- Emit the GPS fixes of a planned trip that are due up to p_up_to_s seconds after its scheduled
-- start (pass a huge number to emit everything). Fixes are on a regular grid, so how often this
-- is called does not change the data. trip_id is left empty: the database infers it.

CREATE OR REPLACE FUNCTION sim.emit_fixes(
    p_trip_id integer,
    p_up_to_s double precision,
    p_noise_m double precision DEFAULT 6,
    p_interval_s double precision DEFAULT 5,
    p_dropout double precision DEFAULT 0.02
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    pl record;
    r_m geometry;
    L double precision;
    srid integer := public.param('metric_srid')::int;

    s double precision;
    i integer := 1;
    last_i integer;
    end_s double precision;
    last_s double precision;

    m double precision;
    spd double precision;
    pt geometry;
    x double precision;
    y double precision;
    ts timestamp;

    n integer := 0;
BEGIN
    SELECT
        p.times_s,
        p.measures_m,
        p.last_emit_s,
        p.done,
        p.run_id,
        t.vehicle_id,
        t.scheduled_start,
        r.route_geometry
    INTO pl
    FROM sim.trip_plan p
    JOIN public.trips t USING (trip_id)
    JOIN public.routes r ON r.route_id = t.route_id
    WHERE p.trip_id = p_trip_id;

    IF pl.times_s IS NULL OR pl.done THEN
        RETURN 0;
    END IF;

    r_m := public.to_m(pl.route_geometry);
    L := ST_Length(r_m);

    last_i := array_length(pl.times_s, 1);
    end_s := pl.times_s[last_i];

    s := coalesce(
        pl.last_emit_s + p_interval_s,
        pl.times_s[1]
    );

    last_s := pl.last_emit_s;

    -- Emit normal GPS observations at regular intervals.
    WHILE s <= least(p_up_to_s, end_s) LOOP

        WHILE i < last_i - 1
          AND pl.times_s[i + 1] < s
        LOOP
            i := i + 1;
        END LOOP;

        IF s >= end_s THEN

            -- Guaranteed final observation at the route endpoint.
            m := pl.measures_m[last_i];
            spd := 0;

            ts := pl.scheduled_start
                  + make_interval(secs => end_s);

            pt := ST_LineInterpolatePoint(r_m, 1.0);

            x := ST_X(pt);
            y := ST_Y(pt);

            INSERT INTO public.vehicle_position (
                vehicle_id,
                trip_id,
                recorded_at,
                location,
                speed_kmh,
                accuracy_m,
                sim_run_id,
                data_source
            )
            VALUES (
                pl.vehicle_id,
                NULL,
                ts,
                ST_Transform(
                    ST_SetSRID(ST_MakePoint(x, y), srid),
                    4326
                ),
                0,
                p_noise_m,
                pl.run_id,
                'simulated'
            )
            ON CONFLICT (vehicle_id, recorded_at)
            DO NOTHING;

            IF FOUND THEN
                n := n + 1;
            END IF;

        ELSE

            -- Normal interpolated GPS observation.
            IF pl.times_s[i + 1] = pl.times_s[i] THEN
                m := pl.measures_m[i];
                spd := 0;
            ELSE
                m := pl.measures_m[i]
                    + (s - pl.times_s[i])
                    / (pl.times_s[i + 1] - pl.times_s[i])
                    * (pl.measures_m[i + 1] - pl.measures_m[i]);

                spd := (
                    pl.measures_m[i + 1] - pl.measures_m[i]
                ) / (
                    pl.times_s[i + 1] - pl.times_s[i]
                ) * 3.6;
            END IF;

            IF random() >= p_dropout THEN

                ts := pl.scheduled_start
                      + make_interval(secs => s + (random() - 0.5));

                pt := ST_LineInterpolatePoint(
                    r_m,
                    least(m / L, 1.0)
                );

                x := ST_X(pt)
                     + (random() - 0.5) * 2 * p_noise_m;

                y := ST_Y(pt)
                     + (random() - 0.5) * 2 * p_noise_m;

                INSERT INTO public.vehicle_position (
                    vehicle_id,
                    trip_id,
                    recorded_at,
                    location,
                    speed_kmh,
                    accuracy_m,
                    sim_run_id,
                    data_source
                )
                VALUES (
                    pl.vehicle_id,
                    NULL,
                    ts,
                    ST_Transform(
                        ST_SetSRID(ST_MakePoint(x, y), srid),
                        4326
                    ),
                    round(
                        greatest(spd + (random() - 0.5), 0)::numeric,
                        2
                    ),
                    p_noise_m,
                    pl.run_id,
                    'simulated'
                )
                ON CONFLICT (vehicle_id, recorded_at)
                DO NOTHING;

                IF FOUND THEN
                    n := n + 1;
                END IF;

            END IF;
        END IF;

        last_s := s;
        s := s + p_interval_s;

    END LOOP;

    -- If the regular 5-second interval did not land exactly
    -- on the final arrival time, emit the endpoint separately.
    IF p_up_to_s >= end_s
       AND (last_s IS NULL OR last_s < end_s)
    THEN

        pt := ST_LineInterpolatePoint(r_m, 1.0);

        INSERT INTO public.vehicle_position (
            vehicle_id,
            trip_id,
            recorded_at,
            location,
            speed_kmh,
            accuracy_m,
            sim_run_id,
            data_source
        )
        VALUES (
            pl.vehicle_id,
            NULL,
            pl.scheduled_start
                + make_interval(secs => end_s),
            ST_Transform(
                ST_SetSRID(
                    ST_MakePoint(ST_X(pt), ST_Y(pt)),
                    srid
                ),
                4326
            ),
            0,
            p_noise_m,
            pl.run_id,
            'simulated'
        )
        ON CONFLICT (vehicle_id, recorded_at)
        DO NOTHING;

        IF FOUND THEN
            n := n + 1;
        END IF;

        last_s := end_s;
    END IF;

    -- A plan is complete only after its final arrival time is reached.
    IF last_s IS DISTINCT FROM pl.last_emit_s
       OR (p_up_to_s >= end_s AND NOT pl.done)
    THEN
        UPDATE sim.trip_plan
        SET
            last_emit_s = CASE
                WHEN p_up_to_s >= end_s THEN end_s
                ELSE last_s
            END,
            done = (p_up_to_s >= end_s)
        WHERE trip_id = p_trip_id;
    END IF;

    RETURN n;
END;
$$;


-- Plan a trip and emit everything up to an optional as-of time (NULL = the whole trip).
CREATE OR REPLACE FUNCTION sim.generate_trip_gps(
    p_trip_id integer, p_run_id integer,
    p_noise_m double precision DEFAULT 6, p_interval_s double precision DEFAULT 5,
    p_dropout double precision DEFAULT 0.02, p_asof timestamp DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE st timestamp;
BEGIN
    PERFORM sim.plan_trip(p_trip_id, p_run_id);
    SELECT scheduled_start INTO st FROM public.trips WHERE trip_id = p_trip_id;
    RETURN sim.emit_fixes(p_trip_id,
        CASE WHEN p_asof IS NULL THEN 1e12 ELSE EXTRACT(EPOCH FROM (p_asof - st)) END,
        p_noise_m, p_interval_s, p_dropout);
END $$;

-- Every trip of a date in chronological order, up to an optional as-of time.
CREATE OR REPLACE FUNCTION sim.run_day(p_date date, p_run_id integer, p_asof timestamp DEFAULT NULL)
RETURNS TABLE (trips_simulated integer, fixes_inserted bigint)
LANGUAGE plpgsql AS $$
DECLARE tr record; n_trips integer := 0; n_fix bigint := 0; k integer;
BEGIN
    FOR tr IN SELECT trip_id FROM public.trips
              WHERE service_date = p_date AND status <> 'Cancelled'
                AND (p_asof IS NULL OR scheduled_start <= p_asof)
              ORDER BY scheduled_start, trip_id
    LOOP
        k := sim.generate_trip_gps(tr.trip_id, p_run_id, p_asof => p_asof);
        n_trips := n_trips + 1; n_fix := n_fix + k;
    END LOOP;
    RETURN QUERY SELECT n_trips, n_fix;
END $$;

-- FAST-FORWARD: a complete day (schedule, one injected incident, GPS for every trip).
CREATE OR REPLACE FUNCTION sim.run_full_day(p_date date, p_seed bigint)
RETURNS TABLE (trips_simulated integer, fixes_inserted bigint)
LANGUAGE plpgsql AS $$
DECLARE rid integer; busy_road integer; g record; start_h integer;
BEGIN
    IF EXISTS (SELECT 1 FROM public.trips WHERE service_date = p_date) THEN
        RAISE NOTICE '% already has trips; skipped', p_date;
        RETURN QUERY SELECT 0, 0::bigint; RETURN;
    END IF;
    rid := sim.new_run(p_seed, 'full day ' || p_date || ', seed ' || p_seed);
    SELECT road_id INTO busy_road
    FROM (SELECT road_id FROM public.route_segments GROUP BY road_id ORDER BY count(*) DESC, road_id LIMIT 5) t
    OFFSET (p_seed % 5)::int LIMIT 1;
    start_h := 9 + (p_seed % 7)::int;
    INSERT INTO sim.injected_event (run_id, event_type, road_id, valid_period, magnitude, note)
    VALUES (rid, 'congestion', busy_road,
            tsrange(p_date + make_interval(hours => start_h), p_date + make_interval(hours => start_h, mins => 40)),
            0.35, 'injected incident: speed x0.35 for 40 minutes');
    SELECT * INTO g FROM public.generate_service_day(p_date);
    RAISE NOTICE '% : % trips created, % unassigned', p_date, g.trips_created, g.unassigned;
    RETURN QUERY SELECT * FROM sim.run_day(p_date, rid, NULL);
END $$;


-- =====================================================================
-- PART 2: the adjustable clock and the live loop
-- =====================================================================
-- "Now" for everything rider-facing. If the demo clock is running it is
-- sim_start + elapsed wall time x speed; otherwise it is the real time.
CREATE OR REPLACE FUNCTION public.app_now() RETURNS timestamp
LANGUAGE sql VOLATILE AS $$
    SELECT coalesce(
        (SELECT CASE WHEN c.running
                     THEN c.sim_start + (clock_timestamp() - c.wall_start) * c.speed::double precision
                     ELSE c.sim_start END
         FROM sim.clock c),
        now()::timestamp)
$$;

-- How many simulated seconds pass per real second (1 when no demo clock is running).
CREATE OR REPLACE FUNCTION public.app_speed() RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT CASE WHEN c.running THEN c.speed ELSE 1 END FROM sim.clock c), 1)
$$;

-- Start the demo clock at a chosen simulated time and speed (30 = half a minute of
-- simulated time per wall-clock second). Creates a run, injects one incident 8 minutes
-- later, and plays the earlier part of that day instantly so the demo starts mid-day with
-- history behind it. Trips that are still in progress at the start continue live.
CREATE OR REPLACE FUNCTION sim.start_clock(p_sim_start timestamp, p_speed numeric DEFAULT 30, p_seed bigint DEFAULT 7)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE rid integer; busy_road integer; g record; d date := p_sim_start::date; n_trips integer; n_fix bigint;
BEGIN
    DELETE FROM sim.clock;
    rid := sim.new_run(p_seed, 'live clock from ' || p_sim_start);

    SELECT road_id INTO busy_road
    FROM (SELECT road_id FROM public.route_segments GROUP BY road_id ORDER BY count(*) DESC, road_id LIMIT 5) t
    OFFSET (p_seed % 5)::int LIMIT 1;
    INSERT INTO sim.injected_event (run_id, event_type, road_id, valid_period, magnitude, note)
    VALUES (rid, 'congestion', busy_road,
            tsrange(p_sim_start + interval '8 minutes', p_sim_start + interval '38 minutes'),
            0.35, 'live incident: speed x0.35 for 30 minutes');

    -- a planned closure on the second-busiest road, 30-70 minutes after the clock starts
    INSERT INTO public.road_closures (road_id, valid_period, reason)
    SELECT t.road_id, tsrange(p_sim_start + interval '30 minutes', p_sim_start + interval '70 minutes'), 'planned maintenance (demo)'
    FROM (SELECT road_id FROM public.route_segments GROUP BY road_id ORDER BY count(*) DESC, road_id OFFSET 1 LIMIT 1) t
    WHERE NOT EXISTS (SELECT 1 FROM public.road_closures c
                      WHERE c.road_id = t.road_id AND c.valid_period && tsrange(p_sim_start, p_sim_start + interval '2 hours'));

    IF NOT EXISTS (SELECT 1 FROM public.trips WHERE service_date = d) THEN
        SELECT * INTO g FROM public.generate_service_day(d);
    END IF;
    SELECT t.trips_simulated, t.fixes_inserted INTO n_trips, n_fix FROM sim.run_day(d, rid, p_sim_start) t;

    INSERT INTO sim.clock (running, sim_start, wall_start, speed, run_id)
    VALUES (true, p_sim_start, clock_timestamp(), p_speed, rid);
    RETURN format('clock started at %s, speed x%s; %s earlier trips played (%s fixes); incident on road %s at %s; road closure %s-%s',
                  p_sim_start, p_speed, n_trips, n_fix, busy_road, p_sim_start + interval '8 minutes',
                  (p_sim_start + interval '30 minutes')::time(0), (p_sim_start + interval '70 minutes')::time(0));
END $$;

-- Change speed without jumping in time.
CREATE OR REPLACE FUNCTION sim.set_speed(p_speed numeric) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE cur timestamp := public.app_now();
BEGIN
    UPDATE sim.clock SET sim_start = cur, wall_start = clock_timestamp(), speed = p_speed, running = true;
    RETURN format('speed x%s from %s', p_speed, cur);
END $$;

CREATE OR REPLACE FUNCTION sim.pause_clock() RETURNS text
LANGUAGE plpgsql AS $$
DECLARE cur timestamp := public.app_now();
BEGIN
    UPDATE sim.clock SET sim_start = cur, wall_start = clock_timestamp(), running = false;
    RETURN 'paused at ' || cur;
END $$;

CREATE OR REPLACE FUNCTION sim.resume_clock() RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE sim.clock SET wall_start = clock_timestamp(), running = true;
    RETURN 'resumed at ' || public.app_now();
END $$;

-- Remove the demo clock (the system then uses the real time).
CREATE OR REPLACE FUNCTION sim.stop_clock() RETURNS text
LANGUAGE sql AS $$ DELETE FROM sim.clock RETURNING 'clock removed'::text $$;

-- One step of the live simulation: make sure today's trips exist, plan trips that are about to
-- start (2 minutes ahead), and emit the fixes that have become due for every running trip.
CREATE OR REPLACE FUNCTION sim.tick() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE now_s timestamp := public.app_now(); c record; tr record; n integer := 0; g record;
BEGIN
    SELECT * INTO c FROM sim.clock WHERE running;
    IF c.run_id IS NULL THEN RETURN 0; END IF;

    IF NOT EXISTS (SELECT 1 FROM public.trips WHERE service_date = now_s::date) THEN
        SELECT * INTO g FROM public.generate_service_day(now_s::date);
    END IF;

    FOR tr IN SELECT t.trip_id FROM public.trips t
              WHERE t.service_date = now_s::date AND t.status = 'Scheduled' AND t.data_source <> 'real_observed'
                AND t.scheduled_start <= now_s + interval '120 seconds'
                AND NOT EXISTS (SELECT 1 FROM sim.trip_plan p WHERE p.trip_id = t.trip_id)
              ORDER BY t.scheduled_start, t.trip_id
    LOOP
        PERFORM sim.plan_trip(tr.trip_id, c.run_id);
    END LOOP;

    FOR tr IN SELECT p.trip_id, t.scheduled_start FROM sim.trip_plan p
              JOIN public.trips t USING (trip_id)
              WHERE NOT p.done AND p.run_id = c.run_id ORDER BY t.scheduled_start
    LOOP
        n := n + sim.emit_fixes(tr.trip_id, EXTRACT(EPOCH FROM (now_s - tr.scheduled_start)));
    END LOOP;
    RETURN n;
END $$;

-- Run the live loop for a number of WALL-CLOCK seconds, committing after every tick so that
-- other sessions see each step. Call it (not SELECT):  CALL sim.run_live(120);
-- It occupies this connection until it finishes; use a second window or the Python console
-- to watch. Interrupt with Cancel.
CREATE OR REPLACE PROCEDURE sim.run_live(p_wall_seconds integer, p_tick_ms integer DEFAULT 1000)
LANGUAGE plpgsql AS $$
DECLARE
    t_end timestamptz;
    n integer;
    k integer := 0;
    c record;
BEGIN
    IF p_wall_seconds < 1 OR p_tick_ms < 1 THEN
        RAISE EXCEPTION 'p_wall_seconds and p_tick_ms must both be positive';
    END IF;

    SELECT * INTO c FROM sim.clock ORDER BY singleton LIMIT 1;
    IF c.run_id IS NULL THEN
        RAISE EXCEPTION 'simulation clock is not initialized; call sim.start_clock() first';
    END IF;

    -- Resume from the frozen simulation timestamp, so time does not jump
    -- forward while this procedure is not running.
    IF NOT c.running THEN
        UPDATE sim.clock SET wall_start = clock_timestamp(), running = true;
        COMMIT;
    END IF;

    t_end := clock_timestamp() + make_interval(secs => p_wall_seconds);
    WHILE clock_timestamp() < t_end LOOP
        n := sim.tick();
        COMMIT;
        k := k + 1;
        IF k % 10 = 0 THEN
            RAISE NOTICE 'sim time % (fixes this tick: %)', public.app_now(), n;
        END IF;
        PERFORM pg_sleep(p_tick_ms / 1000.0);
    END LOOP;

    -- Freeze the clock at the exact end of this bounded live session.
    UPDATE sim.clock
       SET sim_start = public.app_now(),
           wall_start = clock_timestamp(),
           running = false;
    COMMIT;
END $$;


-- =====================================================================
-- PART 3: one-call demo setup
-- Builds history by fast-forwarding p_days complete days from p_first_day. The next day is then
-- free for the live demo (sim.start_clock adds that day's incident and a road closure).
-- Takes about 2-3 minutes per day.
--   SELECT sim.load_demo(DATE '2026-11-10', 3);   -- days 10, 11, 12; live day = 13
-- =====================================================================
CREATE OR REPLACE FUNCTION sim.load_demo(p_first_day date, p_days integer, p_seed_base bigint DEFAULT 100)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE d date; r record;
BEGIN
    FOR i IN 0 .. p_days - 1 LOOP
        d := p_first_day + i;
        SELECT * INTO r FROM sim.run_full_day(d, p_seed_base + i);
        RAISE NOTICE '% : % trips, % fixes', d, r.trips_simulated, r.fixes_inserted;
    END LOOP;
    RETURN format('history loaded for %s days; the next day, %s, is free for the live demo',
                  p_days, p_first_day + p_days);
END $$;

-- Wipe the demo data of ONE date so a demonstration can be repeated from scratch:
-- its trips (and their stop events), GPS fixes, traversals, simulator plans, closures, and
-- the demo clock. Reference data, the map and the other days' history are untouched.
-- DESTRUCTIVE for that date only.
CREATE OR REPLACE FUNCTION sim.reset_day(p_date date) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE n_trips integer; runs integer[];
BEGIN
    SELECT array_agg(DISTINCT sim_run_id) INTO runs FROM public.vehicle_position
    WHERE recorded_at >= p_date AND recorded_at < p_date + 1 AND sim_run_id IS NOT NULL;
    DELETE FROM sim.clock;
    DELETE FROM public.segment_traversal WHERE trip_id IN (SELECT trip_id FROM public.trips WHERE service_date = p_date);
    DELETE FROM sim.trip_plan WHERE trip_id IN (SELECT trip_id FROM public.trips WHERE service_date = p_date);
    DELETE FROM public.vehicle_position WHERE recorded_at >= p_date AND recorded_at < p_date + 1;
    DELETE FROM public.trips WHERE service_date = p_date;
    GET DIAGNOSTICS n_trips = ROW_COUNT;
    DELETE FROM public.road_closures WHERE lower(valid_period)::date = p_date;
    DELETE FROM sim.run r WHERE r.run_id = ANY (coalesce(runs, '{}'))
      AND NOT EXISTS (SELECT 1 FROM public.vehicle_position v WHERE v.sim_run_id = r.run_id);
    RETURN format('%s: %s trips and their data removed; clock removed', p_date, n_trips);
END $$;

-- Verify: simulator objects exist
SELECT n.nspname AS schema, p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'sim' OR p.proname = 'app_now' ORDER BY 1, 2;