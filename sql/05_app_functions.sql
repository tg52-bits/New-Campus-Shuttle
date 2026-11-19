-- =====================================================================
-- 05_app_functions.sql
-- What an app would call. Rider functions answer the questions a person at a
-- stop actually asks; staff functions are the ways to put trip and live data
-- IN (the same insert paths the simulator uses). No new tables: everything
-- reads the tables the triggers already keep current.
--
-- Run in : pgAdmin 4 > Query Tool on campus_shuttle, after files 01-04.
-- Changes: creates functions and one view only.
-- Time   : "now" is app_now() - the demo clock if one is running, otherwise real time.
--
-- Rider  : app_where_is_bus, app_next_arrivals, app_trip_timeline,
--          app_stops_near, app_route_between, app_service_alerts
-- Staff  : staff_create_trip, staff_report_position, staff_place_bus, staff_advance_bus, staff_mark_stop
-- Flow   : v_trip_flow (what the database derived for a trip, stage by stage)
-- =====================================================================


-- =====================================================================
-- PART 1: building blocks for estimates
-- =====================================================================
-- Typical speed on a road at a time of day, from recorded traversals (15-minute bucket); falls back
-- to the road's overall average, then to the design speed when there is no history.
CREATE OR REPLACE FUNCTION public.typical_speed_kmh(p_road_id integer, p_ts timestamp)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        (SELECT s.avg_speed_kmh FROM public.v_segment_speed s
         WHERE s.road_id = p_road_id
           AND s.bucket_start = (date_trunc('hour', p_ts) + floor(EXTRACT(MINUTE FROM p_ts) / 15) * interval '15 minutes')::time),
        (SELECT round(avg(s.avg_speed_kmh), 2) FROM public.v_segment_speed s WHERE s.road_id = p_road_id),
        public.param('design_speed_kmh'))
$$;

-- Seconds to travel along a route from one distance to another, starting at a given time:
-- each road segment's length / its typical speed, plus planned dwell at the stops in between.
CREATE OR REPLACE FUNCTION public.eta_seconds(p_route_id integer, p_from_m numeric, p_to_m numeric, p_at timestamp)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum((least(rs.end_measure_m, p_to_m) - greatest(rs.start_measure_m, p_from_m))
                        / (public.typical_speed_kmh(rs.road_id, p_at) / 3.6)), 0)
         + public.param('default_dwell_s') *
           (SELECT count(*) FROM public.route_stops x
            WHERE x.route_id = p_route_id AND x.distance_from_start_m > p_from_m AND x.distance_from_start_m < p_to_m)
    FROM public.route_segments rs
    WHERE rs.route_id = p_route_id AND rs.end_measure_m > p_from_m AND rs.start_measure_m < p_to_m
$$;


-- =====================================================================
-- PART 2: rider functions
-- =====================================================================
-- Where is my bus? Every running trip with its latest position, progress, next stop and delay.
-- seconds_since_fix is in real seconds (simulated age / clock speed), so it reads naturally at any demo speed.
CREATE OR REPLACE FUNCTION public.app_where_is_bus(p_route_code text DEFAULT NULL)
RETURNS TABLE (trip_id integer, route_code varchar, vehicle_id integer,
               lon numeric, lat numeric, progress_pct numeric, last_stop varchar, next_stop varchar,
               speed_kmh numeric, seconds_since_fix integer, stale boolean, delay_min numeric)
LANGUAGE sql STABLE AS $$
    WITH candidates AS (
        SELECT
            t.trip_id, r.route_code, t.vehicle_id,
            lf.location, lf.measure_m, lf.speed_kmh, lf.recorded_at,
            r.length_m, ls.stop_name AS last_stop, ls.actual_arrival, ls.scheduled_arrival,
            ns.stop_name AS next_stop,
            greatest(EXTRACT(EPOCH FROM (public.app_now() - lf.recorded_at))
                     / public.app_speed(), 0)::integer AS age_s,
            row_number() OVER (
                PARTITION BY t.vehicle_id
                ORDER BY lf.recorded_at DESC, t.scheduled_start DESC, t.trip_id DESC
            ) AS vehicle_rank
        FROM public.trips t
        JOIN public.routes r ON r.route_id = t.route_id
        JOIN LATERAL (
            SELECT v.location, v.measure_m, v.speed_kmh, v.recorded_at
            FROM public.vehicle_position v
            WHERE v.trip_id = t.trip_id
            ORDER BY v.recorded_at DESC
            LIMIT 1
        ) lf ON true
        LEFT JOIN LATERAL (
            SELECT s.stop_name, e.actual_arrival, e.scheduled_arrival
            FROM public.trip_stop_event e
            JOIN public.stops s USING (stop_id)
            WHERE e.trip_id = t.trip_id AND e.actual_arrival IS NOT NULL
            ORDER BY e.stop_sequence DESC
            LIMIT 1
        ) ls ON true
        LEFT JOIN LATERAL (
            SELECT s.stop_name
            FROM public.trip_stop_event e
            JOIN public.stops s USING (stop_id)
            WHERE e.trip_id = t.trip_id AND e.actual_departure IS NULL
            ORDER BY e.stop_sequence ASC
            LIMIT 1
        ) ns ON true
        WHERE t.status = 'In Progress'
          AND (p_route_code IS NULL OR r.route_code = p_route_code)
          AND EXTRACT(EPOCH FROM (public.app_now() - lf.recorded_at))
              / public.app_speed() <= public.param('lost_bus_s')
    )
    SELECT
        c.trip_id, c.route_code, c.vehicle_id,
        round(ST_X(c.location)::numeric, 5),
        round(ST_Y(c.location)::numeric, 5),
        round(100 * c.measure_m / NULLIF(c.length_m, 0), 0),
        c.last_stop, c.next_stop, c.speed_kmh, c.age_s,
        c.age_s > public.param('stale_fix_s'),
        round(EXTRACT(EPOCH FROM (c.actual_arrival - c.scheduled_arrival)) / 60, 1)
    FROM candidates c
    WHERE c.vehicle_rank = 1
    ORDER BY c.route_code, c.trip_id
$$;

-- When is the next bus at my stop? Running trips use live position and typical road speeds;
-- trips that have not started use the schedule plus any delay their vehicle is already carrying.

CREATE OR REPLACE FUNCTION public.app_next_arrivals(
    p_stop_id integer,
    p_limit integer DEFAULT 5
)
RETURNS TABLE (
    route_code varchar,
    route_name varchar,
    trip_id integer,
    vehicle_id integer,
    eta timestamp,
    minutes_away numeric,
    basis text,
    delay_min numeric,
    stops_away integer
)
LANGUAGE sql STABLE AS $$
    WITH n AS (
        SELECT public.app_now() AS t
    ),
    cand AS (
        SELECT
            t.trip_id,
            t.route_id,
            t.vehicle_id,
            t.status,
            rs.distance_from_start_m AS stop_m,
            e.scheduled_arrival,
            e.actual_arrival,
            e.actual_departure,
            lf.measure_m,
            lf.recorded_at AS fix_at
        FROM public.trips t
        JOIN public.route_stops rs
          ON rs.route_id = t.route_id
         AND rs.stop_id = p_stop_id
        JOIN public.trip_stop_event e
          ON e.trip_id = t.trip_id
         AND e.stop_sequence = rs.stop_sequence
        LEFT JOIN LATERAL (
            SELECT v.measure_m, v.recorded_at
            FROM public.vehicle_position v
            WHERE v.trip_id = t.trip_id
              AND v.measure_m IS NOT NULL
            ORDER BY v.recorded_at DESC
            LIMIT 1
        ) lf ON true
        CROSS JOIN n
        WHERE t.status IN ('Scheduled', 'In Progress')
          AND t.scheduled_end >= n.t - interval '30 minutes'
          AND t.scheduled_start <=
              n.t + make_interval(
                  mins => public.param('eta_horizon_min')::int
              )
          AND e.actual_departure IS NULL
          AND NOT (
              t.status = 'In Progress'
              AND lf.recorded_at IS NOT NULL
              AND EXTRACT(EPOCH FROM (n.t - lf.recorded_at))
                  / public.app_speed() > public.param('lost_bus_s')
          )
    ),
    est AS (
        SELECT
            c.*,

            CASE
                WHEN c.actual_arrival IS NOT NULL
                    THEN c.actual_arrival

                WHEN c.status = 'In Progress'
                     AND c.measure_m IS NOT NULL
                     AND c.stop_m >= c.measure_m - public.param('geofence_radius_m')
                    THEN
                        n.t + make_interval(
                            secs => public.eta_seconds(
                                c.route_id,
                                c.measure_m,
                                c.stop_m,
                                n.t
                            )::double precision
                        )

                ELSE
                    c.scheduled_arrival
                    + make_interval(
                        secs => greatest(
                            coalesce((
                                SELECT EXTRACT(
                                    EPOCH FROM (
                                        e2.actual_arrival -
                                        e2.scheduled_arrival
                                    )
                                )
                                FROM public.trips t2
                                JOIN public.trip_stop_event e2
                                  ON e2.trip_id = t2.trip_id
                                WHERE t2.vehicle_id = c.vehicle_id
                                  AND t2.scheduled_start < (
                                      SELECT scheduled_start
                                      FROM public.trips
                                      WHERE trip_id = c.trip_id
                                  )
                                  AND t2.status IN ('In Progress', 'Completed')
                                  AND e2.actual_arrival IS NOT NULL
                                  AND t2.scheduled_end >= (
                                      SELECT scheduled_start
                                      FROM public.trips
                                      WHERE trip_id = c.trip_id
                                  ) - interval '30 minutes'
                                ORDER BY
                                    t2.scheduled_start DESC,
                                    e2.stop_sequence DESC
                                LIMIT 1
                            ), 0),
                            0
                        )::double precision
                    )
            END AS eta_ts,

            CASE
                WHEN c.actual_arrival IS NOT NULL
                    THEN 'at stop now'

                WHEN c.status = 'In Progress'
                     AND c.measure_m IS NOT NULL
                     AND c.stop_m >= c.measure_m - public.param('geofence_radius_m')
                    THEN 'live'

                ELSE 'scheduled'
            END AS basis_txt

        FROM cand c
        CROSS JOIN n
    )

    SELECT
        r.route_code,
        r.route_name,
        e.trip_id,
        e.vehicle_id,
        e.eta_ts,

        round(
            greatest(
                EXTRACT(EPOCH FROM (e.eta_ts - n.t)),
                0
            ) / 60,
            1
        ),

        e.basis_txt,

        round(
            EXTRACT(EPOCH FROM (
                e.eta_ts - e.scheduled_arrival
            )) / 60,
            1
        ),

        CASE
            WHEN e.basis_txt = 'live'
            THEN (
                SELECT count(*)::int
                FROM public.route_stops x
                WHERE x.route_id = e.route_id
                  AND x.distance_from_start_m > e.measure_m
                  AND x.distance_from_start_m < e.stop_m
            )
        END

    FROM est e
    CROSS JOIN n
    JOIN public.routes r
      ON r.route_id = e.route_id

    WHERE e.eta_ts >= n.t - interval '30 seconds'
      AND e.eta_ts <=
          n.t + make_interval(
              mins => public.param('eta_horizon_min')::int
          )

    ORDER BY e.eta_ts
    LIMIT p_limit;
$$;


-- One trip stop by stop: visited (with the delay), at the stop now, or upcoming (with an estimate).

CREATE OR REPLACE FUNCTION public.app_trip_timeline(p_trip_id integer)
RETURNS TABLE (
    stop_sequence integer,
    stop_name varchar,
    state text,
    scheduled_arrival timestamp,
    actual_or_estimated timestamp,
    delay_min numeric
)
LANGUAGE sql STABLE AS $$
    WITH
    t AS (
        SELECT tr.route_id, tr.status
        FROM public.trips tr
        WHERE tr.trip_id = p_trip_id
    ),
    n AS (
        SELECT public.app_now() AS now_ts
    ),
    lf AS (
        SELECT v.measure_m, v.recorded_at
        FROM public.vehicle_position v
        WHERE v.trip_id = p_trip_id
          AND v.measure_m IS NOT NULL
        ORDER BY v.recorded_at DESC
        LIMIT 1
    ),
    estimates AS (
        SELECT
            e.stop_sequence,
            s.stop_name,

            CASE
                WHEN e.actual_departure IS NOT NULL THEN 'visited'
                WHEN e.actual_arrival IS NOT NULL THEN 'at stop'
                ELSE 'upcoming'
            END AS stop_state,

            e.scheduled_arrival,

            CASE
                WHEN e.actual_arrival IS NOT NULL
                    THEN e.actual_arrival

                WHEN lf.measure_m IS NOT NULL
                     AND rs.distance_from_start_m >=
                         lf.measure_m - public.param('geofence_radius_m')
                    THEN
                        n.now_ts + make_interval(
                            secs => public.eta_seconds(
                                t.route_id,
                                lf.measure_m,
                                rs.distance_from_start_m,
                                n.now_ts
                            )::double precision
                        )

                ELSE e.scheduled_arrival
            END AS estimated_ts

        FROM t
        CROSS JOIN n
        JOIN public.trip_stop_event e
          ON e.trip_id = p_trip_id
        JOIN public.stops s
          ON s.stop_id = e.stop_id
        JOIN public.route_stops rs
          ON rs.route_id = t.route_id
         AND rs.stop_sequence = e.stop_sequence
        LEFT JOIN lf ON true
    )

    SELECT
        stop_sequence,
        stop_name,
        stop_state,
        scheduled_arrival,
        estimated_ts,
        round(
            EXTRACT(EPOCH FROM (
                estimated_ts - scheduled_arrival
            )) / 60,
            1
        )
    FROM estimates
    ORDER BY stop_sequence;
$$;


-- Stops near a point (a rider's location), nearest first, with the routes that serve each.
CREATE OR REPLACE FUNCTION public.app_stops_near(p_lon double precision, p_lat double precision,
                                                 p_radius_m integer DEFAULT 500, p_limit integer DEFAULT 5)
RETURNS TABLE (stop_id integer, stop_name varchar, metres integer, routes text)
LANGUAGE sql STABLE AS $$
    WITH me AS (SELECT ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326) AS g)
    SELECT s.stop_id, s.stop_name,
           round(ST_Distance(s.location::geography, me.g::geography))::integer,
           (SELECT string_agg(DISTINCT r.route_code, ', ' ORDER BY r.route_code)
            FROM public.route_stops rs JOIN public.routes r USING (route_id) WHERE rs.stop_id = s.stop_id)
    FROM public.stops s CROSS JOIN me
    WHERE s.location && ST_Expand(me.g, p_radius_m / 90000.0)
      AND ST_DWithin(s.location::geography, me.g::geography, p_radius_m)
    ORDER BY s.location <-> me.g
    LIMIT p_limit
$$;

-- Direct rides from one stop to another: the next departures and when they arrive.
CREATE OR REPLACE FUNCTION public.app_route_between(p_from_stop integer, p_to_stop integer, p_limit integer DEFAULT 5)
RETURNS TABLE (route_code varchar, trip_id integer, leaves_at timestamp, arrives_at timestamp,
               ride_minutes numeric, basis text)
LANGUAGE sql STABLE AS $$
    SELECT a.route_code, a.trip_id, a.eta,
           a.eta + make_interval(secs => public.eta_seconds(r.route_id, rf.distance_from_start_m, rt.distance_from_start_m, a.eta)::double precision),
           round(public.eta_seconds(r.route_id, rf.distance_from_start_m, rt.distance_from_start_m, a.eta) / 60, 1),
           a.basis
    FROM public.app_next_arrivals(p_from_stop, 30) a
    JOIN public.routes r ON r.route_code = a.route_code
    JOIN public.route_stops rf ON rf.route_id = r.route_id AND rf.stop_id = p_from_stop
    JOIN public.route_stops rt ON rt.route_id = r.route_id AND rt.stop_id = p_to_stop
    WHERE rt.stop_sequence > rf.stop_sequence
    ORDER BY a.eta
    LIMIT p_limit
$$;

-- Active or upcoming (next 2 hours) road closures, with the routes they affect.
CREATE OR REPLACE FUNCTION public.app_service_alerts()
RETURNS TABLE (road_name varchar, reason text, starts_at timestamp, ends_at timestamp,
               state text, routes_affected text, trips_running_now integer)
LANGUAGE sql STABLE AS $$
    SELECT rd.road_name, c.reason, lower(c.valid_period), upper(c.valid_period),
           CASE WHEN c.valid_period @> public.app_now() THEN 'active' ELSE 'upcoming' END,
           (SELECT string_agg(DISTINCT r.route_code, ', ' ORDER BY r.route_code)
            FROM public.route_segments rs JOIN public.routes r USING (route_id) WHERE rs.road_id = c.road_id),
           (SELECT count(*)::int FROM public.trips t
            WHERE t.status = 'In Progress'
              AND EXISTS (SELECT 1 FROM public.route_segments rs WHERE rs.route_id = t.route_id AND rs.road_id = c.road_id))
    FROM public.road_closures c
    JOIN public.road_segments rd USING (road_id)
    WHERE c.valid_period && tsrange(public.app_now(), public.app_now() + interval '2 hours')
    ORDER BY lower(c.valid_period)
$$;


-- =====================================================================
-- PART 3: staff functions (ways to put data IN; each is just an insert or update,
-- so the triggers do all the rest)
-- =====================================================================
-- Create a trip. Its planned stop events and scheduled end appear automatically.
CREATE OR REPLACE FUNCTION public.staff_create_trip(p_route_code text, p_vehicle_id integer,
                                                    p_start timestamp, p_driver_id integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE rid integer; tid integer;
BEGIN
    SELECT route_id INTO rid FROM public.routes WHERE route_code = p_route_code;
    IF rid IS NULL THEN RAISE EXCEPTION 'unknown route %', p_route_code; END IF;
    INSERT INTO public.trips (service_date, route_id, vehicle_id, driver_id, scheduled_start, status, data_source)
    VALUES (p_start::date, rid, p_vehicle_id, p_driver_id, p_start, 'Scheduled', 'real_observed')
    RETURNING trip_id INTO tid;
    RETURN tid;
END $$;

-- Report a live GPS position for a vehicle (what a bus unit or driver app would send).
-- Time defaults to app_now(). The database works out the trip, route position and any stop visit.
CREATE OR REPLACE FUNCTION public.staff_report_position(p_vehicle_id integer, p_lon double precision, p_lat double precision,
                                                        p_speed_kmh numeric DEFAULT NULL, p_at timestamp DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE pid bigint; ts timestamp;
BEGIN
    ts := greatest(coalesce(p_at, public.app_now()),
                   coalesce((SELECT max(recorded_at) + interval '1 second' FROM public.vehicle_position WHERE vehicle_id = p_vehicle_id), '-infinity'));
    INSERT INTO public.vehicle_position (vehicle_id, recorded_at, location, speed_kmh, data_source)
    VALUES (p_vehicle_id, ts, ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), p_speed_kmh, 'real_observed')
    RETURNING position_id INTO pid;
    RETURN pid;
END $$;

DROP FUNCTION IF EXISTS public.staff_place_bus(integer, numeric, numeric);   -- replaced by the 4-argument version below

-- Demo helper: put a trip's bus at a distance along its route (no coordinates needed).
CREATE OR REPLACE FUNCTION public.staff_place_bus(p_trip_id integer, p_metres numeric, p_speed_kmh numeric DEFAULT 18, p_at timestamp DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE r_m geometry; L double precision; pt geometry; veh integer; pid bigint;
BEGIN
    SELECT public.to_m(r.route_geometry), t.vehicle_id INTO r_m, veh
    FROM public.trips t JOIN public.routes r USING (route_id) WHERE t.trip_id = p_trip_id;
    IF r_m IS NULL THEN RAISE EXCEPTION 'trip % not found', p_trip_id; END IF;
    L := ST_Length(r_m);
    pt := ST_Transform(ST_LineInterpolatePoint(r_m, least(greatest(p_metres, 0) / L, 1.0)), 4326);
    pid := public.staff_report_position(veh, ST_X(pt), ST_Y(pt), p_speed_kmh, p_at);
    RETURN format('bus %s placed %s m along its route (position id %s)', veh, round(p_metres), pid);
END $$;

-- Demo helper: move a trip's bus FORWARD along its route, stopping exactly at the next stop if the
-- step would pass it. Call it repeatedly; each call is one reported position. At a stop the next
-- call leaves it (a stop also gets a second fix 25 s later, the dwell). Reaching the last stop
-- completes the trip.
CREATE OR REPLACE FUNCTION public.staff_advance_bus(p_trip_id integer, p_metres numeric DEFAULT 250)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE cur numeric; nxt numeric; target numeric; r_id integer; nm varchar; res text;
BEGIN
    SELECT route_id INTO r_id FROM public.trips WHERE trip_id = p_trip_id;
    IF r_id IS NULL THEN RAISE EXCEPTION 'trip % not found', p_trip_id; END IF;
    SELECT measure_m INTO cur FROM public.vehicle_position
    WHERE trip_id = p_trip_id AND measure_m IS NOT NULL ORDER BY recorded_at DESC LIMIT 1;
    IF cur IS NULL THEN
        target := 0;
    ELSE
        SELECT rs.distance_from_start_m, s.stop_name INTO nxt, nm
        FROM public.route_stops rs JOIN public.stops s USING (stop_id)
        WHERE rs.route_id = r_id AND rs.distance_from_start_m > cur + 1
        ORDER BY rs.distance_from_start_m LIMIT 1;
        IF nxt IS NULL THEN RETURN 'the bus is already at the end of its route'; END IF;
        target := least(cur + p_metres, nxt);
    END IF;
    res := public.staff_place_bus(p_trip_id, target);
    SELECT s.stop_name INTO nm FROM public.route_stops rs JOIN public.stops s USING (stop_id)
    WHERE rs.route_id = r_id AND abs(rs.distance_from_start_m - target) < 1 LIMIT 1;
    IF nm IS NOT NULL THEN
        -- standing at a stop: report a second fix 25 s later, as a real unit would while the bus dwells
        PERFORM public.staff_place_bus(p_trip_id, target, 0,
            (SELECT max(recorded_at) FROM public.vehicle_position WHERE trip_id = p_trip_id) + interval '25 seconds');
    END IF;
    RETURN res || CASE WHEN nm IS NOT NULL THEN ' - at stop ' || nm || ' (dwelling 25 s)' ELSE '' END;
END $$;

-- Record a stop visit by hand (a driver or conductor reporting an arrival/departure).
CREATE OR REPLACE FUNCTION public.staff_mark_stop(p_trip_id integer, p_stop_sequence integer,
                                                  p_arrival timestamp DEFAULT NULL, p_departure timestamp DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.trip_stop_event
    SET actual_arrival = coalesce(p_arrival, actual_arrival, public.app_now()),
        actual_departure = coalesce(p_departure, actual_departure),
        detection_method = 'manual'
    WHERE trip_id = p_trip_id AND stop_sequence = p_stop_sequence;
    IF NOT FOUND THEN RAISE EXCEPTION 'trip % has no stop %', p_trip_id, p_stop_sequence; END IF;
    RETURN format('trip %s stop %s recorded', p_trip_id, p_stop_sequence);
END $$;


-- =====================================================================
-- PART 4: the data-flow view (for demonstrations)
-- One row per trip showing what exists at each stage, so you can watch a single entered
-- fact travel: trip created -> GPS fixes arrive -> matched to the route -> stops detected ->
-- status changes -> road traversals recorded when the trip completes.
-- =====================================================================
CREATE OR REPLACE VIEW public.v_trip_flow AS
SELECT t.trip_id, r.route_code, t.vehicle_id, t.status, t.scheduled_start, t.actual_start, t.actual_end,
       (SELECT count(*) FROM public.trip_stop_event e WHERE e.trip_id = t.trip_id)                                  AS planned_stop_events,
       (SELECT count(*) FROM public.vehicle_position v WHERE v.trip_id = t.trip_id)                                 AS gps_fixes,
       (SELECT count(*) FROM public.vehicle_position v WHERE v.trip_id = t.trip_id AND v.measure_m IS NOT NULL)    AS fixes_matched_to_route,
       (SELECT count(*) FROM public.trip_stop_event e WHERE e.trip_id = t.trip_id AND e.actual_arrival IS NOT NULL) AS stops_arrived,
       (SELECT count(*) FROM public.trip_stop_event e WHERE e.trip_id = t.trip_id AND e.actual_departure IS NOT NULL) AS stops_departed,
       (SELECT count(*) FROM public.segment_traversal s WHERE s.trip_id = t.trip_id)                                AS road_traversals,
       (SELECT max(v.recorded_at) FROM public.vehicle_position v WHERE v.trip_id = t.trip_id)                       AS last_fix_at
FROM public.trips t JOIN public.routes r USING (route_id);

-- Verify: nine app functions and one view
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND (proname LIKE 'app\_%' OR proname LIKE 'staff\_%') ORDER BY proname;
