-- =====================================================================
-- 07_query_ladder.sql  (v3)
-- 30 queries on the demo data: 10 basic, 10 medium, 10 hard.
-- Each one says which part is SPATIAL and which part is TEMPORAL, so the
-- spatio-temporal character of the database can be pointed at, query by query.
--
-- Run in : pgAdmin 4 > Query Tool on campus_shuttle, after files 02-04.
-- How    : run PART 0 once, then ONE query at a time (select it, press F5).
-- Effect : read-only (PART 0 only adds one helper function).
-- Data   : the latest fully simulated day (view v_demo_day), plus the live day if one
--          exists. All values are simulated.
--
-- Tags:  [S] spatial   [T] temporal   [ST] both together
-- Vocabulary used below:
--   fix         one timestamped GPS point in vehicle_position
--   measure     metres along a route (from the derived route geometry)
--   lateness    actual arrival minus scheduled arrival at one stop event
-- =====================================================================


-- =====================================================================
-- PART 0: helpers
-- v_demo_day: the latest date on which every trip has finished (so a day that is
-- still running live is not used for whole-day statistics).
-- =====================================================================
CREATE OR REPLACE VIEW public.v_demo_day AS
SELECT max(service_date) AS d FROM public.trips
WHERE service_date NOT IN (SELECT service_date FROM public.trips WHERE status IN ('Scheduled', 'In Progress'));

-- planned time at a point on a route:
-- Interpolates the planned time offset (seconds after trip start) at a given
-- distance along a route, between the planned times of the stops either side.
-- Planned dwell is ignored (the planned time at a stop is its departure
-- offset), so results are within one dwell (~20 s) of exact.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.planned_offset_s(p_route_id integer, p_measure numeric)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN n.dist IS NULL THEN p.arr
                ELSE p.dep + (p_measure - p.dist) / NULLIF(n.dist - p.dist, 0) * (n.arr - p.dep) END
    FROM (SELECT distance_from_start_m AS dist, planned_departure_offset_s AS dep, planned_arrival_offset_s AS arr
          FROM public.route_stops
          WHERE route_id = p_route_id AND distance_from_start_m <= p_measure
          ORDER BY distance_from_start_m DESC, stop_sequence DESC LIMIT 1) p
    LEFT JOIN (SELECT distance_from_start_m AS dist, planned_arrival_offset_s AS arr
               FROM public.route_stops
               WHERE route_id = p_route_id AND distance_from_start_m > p_measure
               ORDER BY distance_from_start_m LIMIT 1) n ON true
$$;


-- #####################################################################
-- BASIC (B1-B10): one idea each
-- #####################################################################

-- B1 [S] Where is each stop, and what did the database work out about it?
--   Spatial : location (point), the zone polygon containing it, the road it was
--             snapped to and how far the snap moved it (all derived by a trigger).
--   Temporal: none (static map data).
SELECT s.stop_code, s.stop_name, z.zone_name, rd.road_name, s.snap_distance_m,
       round(ST_X(s.location)::numeric, 5) AS lon, round(ST_Y(s.location)::numeric, 5) AS lat
FROM public.stops s
LEFT JOIN public.campus_zones z ON z.zone_id = s.zone_id
LEFT JOIN public.road_segments rd ON rd.road_id = s.road_id
ORDER BY s.stop_code;

-- B2 [S] The road network by class: how many segments, how many kilometres.
--   Spatial : segment length in metres comes from the line geometry (geography).
--   Temporal: none.
SELECT highway_class, count(*) AS segments, round(sum(length_m) / 1000, 2) AS km,
       round(avg(speed_limit_kmh), 0) AS limit_kmh
FROM public.road_segments
GROUP BY highway_class ORDER BY km DESC;

-- B3 [S] Which stops lie within 1.5 km of Main Gate, nearest first?
--   Spatial : ST_DWithin / ST_Distance on geography (metres, not degrees).
--   Temporal: none.
SELECT s.stop_name, round(ST_Distance(s.location::geography, g.location::geography)::numeric) AS metres
FROM public.stops s
JOIN public.stops g ON g.stop_name = 'Main Gate'
WHERE s.stop_id <> g.stop_id AND ST_DWithin(s.location::geography, g.location::geography, 1500)
ORDER BY metres;

-- B4 [S+T] Each route: how long it is, how many stops, how long it is planned to take.
--   Spatial : route length derived from the road-following route line.
--   Temporal: planned duration derived from distance / design speed + dwell.
SELECT r.route_code, r.route_name, count(rs.*) AS stops, round(r.length_m) AS length_m,
       round(max(rs.planned_departure_offset_s) / 60.0, 1) AS planned_minutes
FROM public.routes r JOIN public.route_stops rs USING (route_id)
GROUP BY r.route_id, r.route_code, r.route_name, r.length_m
ORDER BY r.route_code;

-- B5 [T] How many departures does the timetable have in each hour of the day?
--   Spatial : none.
--   Temporal: grouping by clock hour (the rush-hour structure of the timetable).
SELECT EXTRACT(HOUR FROM departure_time)::int AS hour_of_day, count(*) AS departures
FROM public.timetable_departures
GROUP BY 1 ORDER BY 1;

-- B6 [T] What state are the demo day's trips in?
--   Spatial : none.
--   Temporal: status is derived from observations over time (Scheduled ->
--             In Progress -> Completed); the as-of time was 16:20.
SELECT status, count(*) AS trips, min(scheduled_start)::time AS earliest_start, max(scheduled_start)::time AS latest_start
FROM public.trips WHERE service_date = (SELECT d FROM public.v_demo_day)
GROUP BY status ORDER BY status;

-- B7 [T] How late did the first ten completed trips actually start?
--   Spatial : none directly (actual_start was derived from GPS stop detection).
--   Temporal: timestamp subtraction (positive = late, negative = early).
SELECT t.trip_id, r.route_code, t.scheduled_start, t.actual_start,
       round(EXTRACT(EPOCH FROM (t.actual_start - t.scheduled_start))) AS start_delay_s
FROM public.trips t JOIN public.routes r USING (route_id)
WHERE t.service_date = (SELECT d FROM public.v_demo_day) AND t.status = 'Completed'
ORDER BY t.scheduled_start, t.trip_id LIMIT 10;

-- B8 [ST] Where was every shuttle at noon (its latest fix up to 12:00)?
--   Spatial : the position (lon/lat).
--   Temporal: "as of" an instant: latest observation at or before 12:00, and how old it is.
SELECT DISTINCT ON (vehicle_id) vehicle_id, recorded_at,
       round(ST_X(location)::numeric, 5) AS lon, round(ST_Y(location)::numeric, 5) AS lat,
       round(EXTRACT(EPOCH FROM (((SELECT d FROM public.v_demo_day) + TIME '12:00') - recorded_at))) AS seconds_old
FROM public.vehicle_position
WHERE recorded_at <= ((SELECT d FROM public.v_demo_day) + TIME '12:00') AND recorded_at >= ((SELECT d FROM public.v_demo_day) + TIME '00:00')
ORDER BY vehicle_id, recorded_at DESC;

-- B9 [T] When did each vehicle first and last report on the demo day, and how many fixes?
--   Spatial : none.
--   Temporal: min/max over time, counts per vehicle.
SELECT vehicle_id, count(*) AS fixes, min(recorded_at) AS first_fix, max(recorded_at) AS last_fix,
       round(count(*) / (EXTRACT(EPOCH FROM (max(recorded_at) - min(recorded_at))) / 3600)) AS fixes_per_hour_span
FROM public.vehicle_position
WHERE recorded_at::date = (SELECT d FROM public.v_demo_day)
GROUP BY vehicle_id ORDER BY vehicle_id;

-- B10 [S] How many fixes fell inside each campus zone?
--   Spatial : point-in-polygon (ST_Within), using the GiST index on the fix points.
--   Temporal: none (whole day).
SELECT z.zone_name, z.zone_type, count(*) AS fixes
FROM public.campus_zones z
JOIN public.vehicle_position vp ON ST_Within(vp.location, z.boundary)
GROUP BY z.zone_name, z.zone_type ORDER BY fixes DESC;


-- #####################################################################
-- MEDIUM (M1-M10): joins, windows, aggregation over space or time
-- #####################################################################

-- M1 [ST] Did shuttles drive more than the planned route? Rebuilds each trip's path
--   from its time-ordered fixes and compares its length with the planned route length.
--   Spatial : ST_MakeLine builds a trajectory; ST_Length(geography) measures it.
--   Temporal: ORDER BY recorded_at inside the aggregate defines the path.
--   (The path is a few percent longer than the route because GPS noise zigzags.)
WITH path AS (
    SELECT trip_id, count(*) AS fixes, ST_MakeLine(location ORDER BY recorded_at) AS g
    FROM public.vehicle_position WHERE trip_id IS NOT NULL GROUP BY trip_id HAVING count(*) >= 2)
SELECT t.trip_id, r.route_code, p.fixes,
       round(ST_Length(p.g::geography)::numeric) AS driven_m, round(r.length_m) AS planned_m,
       round((100 * ST_Length(p.g::geography) / r.length_m - 100)::numeric, 1) AS pct_longer_than_plan
FROM path p JOIN public.trips t USING (trip_id) JOIN public.routes r USING (route_id)
WHERE t.status = 'Completed'
ORDER BY pct_longer_than_plan DESC LIMIT 10;

-- M2 [T] How long do shuttles stand at each stop?
--   Spatial : the stop (a place), detected by the geofence rule.
--   Temporal: dwell = actual departure - actual arrival (final stops excluded: no departure is recorded).
SELECT s.stop_name, count(*) AS visits,
       round(avg(EXTRACT(EPOCH FROM (e.actual_departure - e.actual_arrival)))) AS mean_dwell_s,
       round(min(EXTRACT(EPOCH FROM (e.actual_departure - e.actual_arrival)))) AS min_dwell_s,
       round(max(EXTRACT(EPOCH FROM (e.actual_departure - e.actual_arrival)))) AS max_dwell_s
FROM public.trip_stop_event e JOIN public.stops s USING (stop_id)
WHERE e.actual_arrival IS NOT NULL AND e.actual_departure IS NOT NULL
GROUP BY s.stop_name ORDER BY mean_dwell_s DESC;

-- M3 [ST] Stop-by-hour lateness matrix: mean arrival lateness (minutes) at each stop for each hour.
--   Spatial : one row per place.
--   Temporal: one column per scheduled hour.
SELECT s.stop_name,
       round((avg(l) FILTER (WHERE h = 8)  / 60)::numeric, 1) AS h08,
       round((avg(l) FILTER (WHERE h = 9)  / 60)::numeric, 1) AS h09,
       round((avg(l) FILTER (WHERE h = 10) / 60)::numeric, 1) AS h10,
       round((avg(l) FILTER (WHERE h = 11) / 60)::numeric, 1) AS h11,
       round((avg(l) FILTER (WHERE h = 12) / 60)::numeric, 1) AS h12,
       round((avg(l) FILTER (WHERE h = 13) / 60)::numeric, 1) AS h13,
       round((avg(l) FILTER (WHERE h = 14) / 60)::numeric, 1) AS h14,
       round((avg(l) FILTER (WHERE h = 15) / 60)::numeric, 1) AS h15,
       round((avg(l) FILTER (WHERE h = 16) / 60)::numeric, 1) AS h16
FROM (SELECT e.stop_id, EXTRACT(HOUR FROM e.scheduled_arrival)::int AS h,
             EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) AS l
      FROM public.trip_stop_event e WHERE e.actual_arrival IS NOT NULL) x
JOIN public.stops s USING (stop_id)
GROUP BY s.stop_name ORDER BY s.stop_name;

-- M4 [ST] Does the class-change rush slow shuttles down where it should?
--   Compares mean traversal speed in the minutes :50-:10 (class change) with other minutes,
--   for roads inside academic/administrative zones versus elsewhere. Weekday, 08:00-17:59.
--   Spatial : a road's zone (the polygon containing its midpoint).
--   Temporal: minute-of-hour window of the traversal start.
SELECT coalesce(z.zone_type, 'outside any zone') AS road_zone_type,
       (EXTRACT(MINUTE FROM st.entered_at) >= 50 OR EXTRACT(MINUTE FROM st.entered_at) < 10) AS class_change_minutes,
       count(*) AS traversals, round(avg(st.avg_speed_kmh), 1) AS mean_kmh
FROM public.segment_traversal st
JOIN public.road_segments rd ON rd.road_id = st.road_id
LEFT JOIN LATERAL (SELECT zone_type FROM public.campus_zones zz
                   WHERE ST_Intersects(zz.boundary, ST_LineInterpolatePoint(rd.geom, 0.5))
                   ORDER BY ST_Area(zz.boundary) LIMIT 1) z ON true
WHERE EXTRACT(HOUR FROM st.entered_at) BETWEEN 8 AND 17
GROUP BY 1, 2 ORDER BY 1, 2;

-- M5 [ST] Sampling gaps versus movement: one trip's fixes in time order with the step
--   length and speed implied by each pair of consecutive fixes (largest gaps first).
--   Spatial : distance between consecutive points (geography).
--   Temporal: LAG over time gives the gap; implied speed = distance / gap.
--   A long gap is a sampling gap, not a deviation or an incident.
WITH tr AS (SELECT trip_id FROM public.trips WHERE service_date = (SELECT d FROM public.v_demo_day) AND status = 'Completed' ORDER BY trip_id LIMIT 1),
steps AS (
    SELECT vp.recorded_at, vp.speed_kmh,
           EXTRACT(EPOCH FROM (vp.recorded_at - lag(vp.recorded_at) OVER w)) AS gap_s,
           ST_Distance(vp.location::geography, (lag(vp.location) OVER w)::geography) AS step_m
    FROM public.vehicle_position vp JOIN tr USING (trip_id)
    WINDOW w AS (ORDER BY vp.recorded_at))
SELECT recorded_at, round(gap_s::numeric, 1) AS gap_s, round(step_m::numeric, 1) AS step_m,
       round((step_m / NULLIF(gap_s, 0) * 3.6)::numeric, 1) AS implied_kmh, speed_kmh AS reported_kmh,
       (gap_s > 8) AS longer_than_nominal_interval
FROM steps WHERE gap_s IS NOT NULL
ORDER BY gap_s DESC LIMIT 12;

-- M6 [ST] Which road segments have the most unpredictable travel time?
--   Spatial : one result per road segment (with its length).
--   Temporal: spread of the time taken to traverse it (standard deviation / mean).
SELECT rd.road_name, rd.road_id, round(rd.length_m) AS length_m, count(*) AS traversals,
       round(avg(st.travel_time_s)) AS mean_s, round(stddev(st.travel_time_s)) AS stddev_s,
       round((stddev(st.travel_time_s) / avg(st.travel_time_s))::numeric, 2) AS coefficient_of_variation
FROM public.segment_traversal st JOIN public.road_segments rd USING (road_id)
GROUP BY rd.road_id, rd.road_name, rd.length_m
HAVING count(*) >= 10
ORDER BY coefficient_of_variation DESC LIMIT 10;

-- M7 [S] Which roads do the most routes share?
--   Spatial : routes are sequences of shared road segments (network structure).
--   Temporal: none.
SELECT rd.road_id, rd.road_name, round(rd.length_m) AS length_m,
       count(DISTINCT rs.route_id) AS routes_using_it,
       string_agg(DISTINCT r.route_code, ', ' ORDER BY r.route_code) AS routes
FROM public.route_segments rs
JOIN public.road_segments rd USING (road_id)
JOIN public.routes r USING (route_id)
GROUP BY rd.road_id, rd.road_name, rd.length_m
ORDER BY routes_using_it DESC, rd.road_id LIMIT 10;

-- M8 [T] Vehicle utilisation on the demo day: trips, busy minutes, idle gaps between trips.
--   Spatial : none.
--   Temporal: LAG over each vehicle's trips ordered by time; interval arithmetic.
WITH x AS (
    SELECT vehicle_id, scheduled_start, scheduled_end,
           lag(scheduled_end) OVER (PARTITION BY vehicle_id ORDER BY scheduled_start) AS prev_end
    FROM public.trips WHERE service_date = (SELECT d FROM public.v_demo_day))
SELECT vehicle_id, count(*) AS trips,
       round(sum(EXTRACT(EPOCH FROM (scheduled_end - scheduled_start))) / 60) AS busy_minutes,
       round(avg(EXTRACT(EPOCH FROM (scheduled_start - prev_end))) / 60) AS mean_idle_gap_min,
       round(max(EXTRACT(EPOCH FROM (scheduled_start - prev_end))) / 60) AS longest_idle_gap_min
FROM x GROUP BY vehicle_id ORDER BY vehicle_id;

-- M9 [ST] Time-weighted zone occupancy: how many vehicle-minutes were spent in each zone?
--   Spatial : zone containment of each fix.
--   Temporal: each fix is weighted by the time until the vehicle's next fix (capped at 30 s so gaps
--             between trips do not count).
WITH d AS (
    SELECT vehicle_id, location,
           least(EXTRACT(EPOCH FROM (lead(recorded_at) OVER (PARTITION BY vehicle_id ORDER BY recorded_at) - recorded_at)), 30) AS dt
    FROM public.vehicle_position
    WHERE recorded_at::date = (SELECT d FROM public.v_demo_day) AND trip_id IS NOT NULL)
SELECT z.zone_name, z.zone_type, count(DISTINCT d.vehicle_id) AS vehicles, round(sum(d.dt) / 60) AS vehicle_minutes
FROM d JOIN public.campus_zones z ON ST_Within(d.location, z.boundary)
WHERE d.dt IS NOT NULL
GROUP BY z.zone_name, z.zone_type ORDER BY vehicle_minutes DESC;

-- M10 [T] Peak versus off-peak lateness per route (peak = scheduled hours 8, 9, 16, 17).
--   Spatial : per route.
--   Temporal: day-part split of arrivals.
WITH ev AS (
    SELECT r.route_code, EXTRACT(HOUR FROM e.scheduled_arrival)::int IN (8, 9, 16, 17) AS peak,
           EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) AS l
    FROM public.trip_stop_event e JOIN public.trips t USING (trip_id) JOIN public.routes r USING (route_id)
    WHERE e.actual_arrival IS NOT NULL)
SELECT route_code,
       count(*) FILTER (WHERE peak) AS peak_arrivals,
       round((avg(l) FILTER (WHERE peak) / 60)::numeric, 2) AS peak_mean_late_min,
       count(*) FILTER (WHERE NOT peak) AS offpeak_arrivals,
       round((avg(l) FILTER (WHERE NOT peak) / 60)::numeric, 2) AS offpeak_mean_late_min
FROM ev GROUP BY route_code ORDER BY route_code;


-- #####################################################################
-- HARD (H1-H10): interpolation, planned-vs-actual in space, recursion, evaluation
-- #####################################################################

-- H1 [ST] Where was the WHOLE fleet at 09:19:30, an instant with no exact fix?
--   Interpolates each vehicle between its fixes either side of the instant, and names the zone.
--   Spatial : interpolated point, point-in-polygon.
--   Temporal: the instant lies between observations; vehicles whose neighbouring fixes are more than
--             20 s apart (between trips) are excluded rather than guessed.
WITH t AS (SELECT ((SELECT d FROM public.v_demo_day) + TIME '09:19:30') AS at)
SELECT v.vehicle_id,
       round(ST_X(p.g)::numeric, 5) AS lon, round(ST_Y(p.g)::numeric, 5) AS lat,
       round((b.spd + (a.spd - b.spd) * p.f)::numeric, 1) AS interpolated_kmh,
       z.zone_name
FROM t
JOIN LATERAL (SELECT DISTINCT vehicle_id FROM public.vehicle_position
              WHERE recorded_at BETWEEN t.at - interval '20 seconds' AND t.at + interval '20 seconds') v ON true
JOIN LATERAL (SELECT q.recorded_at AS ts, q.location AS loc, q.speed_kmh AS spd FROM public.vehicle_position q
              WHERE q.vehicle_id = v.vehicle_id AND q.recorded_at <= t.at ORDER BY q.recorded_at DESC LIMIT 1) b ON true
JOIN LATERAL (SELECT q.recorded_at AS ts, q.location AS loc, q.speed_kmh AS spd FROM public.vehicle_position q
              WHERE q.vehicle_id = v.vehicle_id AND q.recorded_at > t.at ORDER BY q.recorded_at ASC LIMIT 1) a ON true
CROSS JOIN LATERAL (
    SELECT EXTRACT(EPOCH FROM (t.at - b.ts)) / NULLIF(EXTRACT(EPOCH FROM (a.ts - b.ts)), 0) AS f,
           ST_SetSRID(ST_MakePoint(
               ST_X(b.loc) + (ST_X(a.loc) - ST_X(b.loc)) * EXTRACT(EPOCH FROM (t.at - b.ts)) / NULLIF(EXTRACT(EPOCH FROM (a.ts - b.ts)), 0),
               ST_Y(b.loc) + (ST_Y(a.loc) - ST_Y(b.loc)) * EXTRACT(EPOCH FROM (t.at - b.ts)) / NULLIF(EXTRACT(EPOCH FROM (a.ts - b.ts)), 0)), 4326) AS g) p
LEFT JOIN public.campus_zones z ON ST_Within(p.g, z.boundary)
WHERE a.ts - b.ts <= interval '20 seconds'
ORDER BY v.vehicle_id;

-- H2 [ST] Schedule adherence in SPACE: how many metres ahead of or behind plan was one trip, minute by minute?
--   For each fix it computes where the schedule says the shuttle should be at that time
--   (between the planned stop times, by distance) and subtracts that from where it really is.
--   Spatial : position along the route (measure_m, derived when each fix arrived).
--   Temporal: planned position as a function of time, from scheduled stop times.
--   Negative = behind plan. (This is one trip's time-distance diagram, thinned to every 12th fix.)
WITH tgt AS (SELECT trip_id, route_id FROM public.trips
             WHERE service_date = (SELECT d FROM public.v_demo_day) AND status = 'Completed' ORDER BY trip_id OFFSET 20 LIMIT 1),
ev AS (
    SELECT e.stop_sequence, e.scheduled_arrival AS sa, e.scheduled_departure AS sd, rs.distance_from_start_m AS m
    FROM public.trip_stop_event e
    JOIN tgt ON tgt.trip_id = e.trip_id
    JOIN public.route_stops rs ON rs.route_id = tgt.route_id AND rs.stop_sequence = e.stop_sequence),
fx AS (
    SELECT vp.recorded_at, vp.measure_m,
           row_number() OVER (ORDER BY vp.recorded_at) AS rn
    FROM public.vehicle_position vp JOIN tgt ON tgt.trip_id = vp.trip_id WHERE vp.measure_m IS NOT NULL)
SELECT fx.recorded_at, round(fx.measure_m) AS actual_m, round(pl.m) AS planned_m,
       round(fx.measure_m - pl.m) AS metres_ahead_of_plan
FROM fx
CROSS JOIN LATERAL (
    SELECT coalesce(
        (SELECT m FROM ev WHERE sa <= fx.recorded_at AND fx.recorded_at < sd LIMIT 1),          -- planned to be standing at a stop
        (SELECT CASE WHEN n.sa IS NULL THEN p.m
                     WHEN p.sd IS NULL THEN 0
                     ELSE p.m + (n.m - p.m) * EXTRACT(EPOCH FROM (fx.recorded_at - p.sd))
                                            / EXTRACT(EPOCH FROM (n.sa - p.sd)) END
         FROM (SELECT m, sd FROM ev WHERE sd <= fx.recorded_at ORDER BY sd DESC LIMIT 1) p
         FULL JOIN (SELECT m, sa FROM ev WHERE sa > fx.recorded_at ORDER BY sa ASC LIMIT 1) n ON true)
    ) AS m) pl
WHERE fx.rn % 12 = 0
ORDER BY fx.recorded_at;

-- H3 [ST] Where does time get lost? For every pair of consecutive stops: planned versus actual leg time
--   (actual departure to next actual arrival), averaged over all trips, ranked by seconds lost.
--   Spatial : the leg is a pair of places (with the straight-line distance between them).
--   Temporal: window functions (LAG) over each trip's stop events.
WITH legs AS (
    SELECT t.route_id, lag(e.stop_id) OVER w AS from_stop, e.stop_id AS to_stop,
           EXTRACT(EPOCH FROM (e.actual_arrival - lag(e.actual_departure) OVER w)) AS actual_s,
           EXTRACT(EPOCH FROM (e.scheduled_arrival - lag(e.scheduled_departure) OVER w)) AS planned_s
    FROM public.trip_stop_event e JOIN public.trips t USING (trip_id)
    WINDOW w AS (PARTITION BY e.trip_id ORDER BY e.stop_sequence))
SELECT sf.stop_name AS from_stop, st.stop_name AS to_stop, count(*) AS observations,
       round(ST_Distance(sf.location::geography, st.location::geography)::numeric) AS straight_line_m,
       round(avg(planned_s)) AS planned_s, round(avg(actual_s)) AS actual_s,
       round(avg(actual_s - planned_s)) AS lost_s
FROM legs l
JOIN public.stops sf ON sf.stop_id = l.from_stop
JOIN public.stops st ON st.stop_id = l.to_stop
WHERE l.from_stop IS NOT NULL AND l.actual_s IS NOT NULL
GROUP BY sf.stop_name, st.stop_name, sf.location, st.location
HAVING count(*) >= 10
ORDER BY lost_s DESC LIMIT 10;

-- H4 [ST] Slow-traffic hotspot map: 100 m grid cells where shuttles crawled (under 12 km/h) away from any stop,
--   by hour. Fixes within 40 m of a stop are excluded so ordinary stopping is not mistaken for congestion.
--   Spatial : projection to metres, snapping to a grid (ST_SnapToGrid), distance to stops.
--   Temporal: grouped by hour, first/last time seen in the cell.
WITH slow AS (
    SELECT vp.vehicle_id, vp.recorded_at, ST_SnapToGrid(public.to_m(vp.location), 100) AS cell
    FROM public.vehicle_position vp
    WHERE vp.trip_id IS NOT NULL AND vp.speed_kmh < 12 AND vp.recorded_at::date = (SELECT d FROM public.v_demo_day)
      AND NOT EXISTS (SELECT 1 FROM public.stops s WHERE ST_DWithin(vp.location::geography, s.location::geography, 40)))
SELECT round(ST_X(ST_Transform(cell, 4326))::numeric, 4) AS cell_lon, round(ST_Y(ST_Transform(cell, 4326))::numeric, 4) AS cell_lat,
       EXTRACT(HOUR FROM recorded_at)::int AS hour_of_day,
       count(*) AS slow_fixes, count(DISTINCT vehicle_id) AS vehicles,
       min(recorded_at)::time AS first_seen, max(recorded_at)::time AS last_seen
FROM slow GROUP BY cell, 3 ORDER BY slow_fixes DESC LIMIT 10;

-- H5 [ST] Unplanned slow stretches (gaps-and-islands): consecutive slow fixes away from stops that lasted at least 40 s.
--   Spatial : location of the stretch (centroid) and the nearest road.
--   Temporal: runs of consecutive fixes found with the row_number difference trick; duration of each run.
WITH f AS (
    SELECT vp.vehicle_id, vp.trip_id, vp.recorded_at, vp.location, vp.speed_kmh,
           (vp.speed_kmh < 12 AND NOT EXISTS (SELECT 1 FROM public.stops s
                                              WHERE ST_DWithin(vp.location::geography, s.location::geography, 40))) AS slow
    FROM public.vehicle_position vp WHERE vp.trip_id IS NOT NULL AND vp.recorded_at::date = (SELECT d FROM public.v_demo_day)),
g AS (
    SELECT *, row_number() OVER (PARTITION BY vehicle_id ORDER BY recorded_at)
            - row_number() OVER (PARTITION BY vehicle_id, slow ORDER BY recorded_at) AS grp
    FROM f),
runs AS (
    SELECT vehicle_id, trip_id, min(recorded_at) AS run_start, max(recorded_at) AS run_end, count(*) AS fixes,
           round(avg(speed_kmh), 1) AS mean_kmh, ST_Centroid(ST_Collect(location)) AS centre
    FROM g WHERE slow GROUP BY vehicle_id, trip_id, grp
    HAVING max(recorded_at) - min(recorded_at) >= interval '40 seconds')
SELECT r.vehicle_id, r.trip_id, r.run_start, round(EXTRACT(EPOCH FROM (r.run_end - r.run_start))) AS duration_s,
       r.fixes, r.mean_kmh, rd.road_name
FROM runs r
CROSS JOIN LATERAL (SELECT road_name FROM public.road_segments ORDER BY geom <-> r.centre LIMIT 1) rd
ORDER BY duration_s DESC LIMIT 10;

-- H6 [T] Chains of delay propagation (recursive). A link means: same vehicle, consecutive trips, the earlier trip ended
--   more than 1 min late, the turnaround to the next scheduled start was under 2 min, and the next trip started
--   more than 30 s late. Links are followed recursively into chains. These are CANDIDATE chains: temporal
--   association between consecutive trips of one vehicle, not proof of cause.
--   Spatial : none directly (trip times were derived from GPS); chains are per vehicle.
--   Temporal: lead() orders each vehicle's trips; recursion follows the order.
WITH RECURSIVE seq AS (
    SELECT t.trip_id, t.vehicle_id, t.scheduled_start, t.scheduled_end, t.actual_start, t.actual_end,
           lead(t.trip_id)         OVER w AS next_trip,
           lead(t.scheduled_start) OVER w AS next_sched_start,
           lead(t.actual_start)    OVER w AS next_actual_start
    FROM public.trips t WHERE t.service_date = (SELECT d FROM public.v_demo_day) AND t.status <> 'Cancelled'
    WINDOW w AS (PARTITION BY t.vehicle_id ORDER BY t.scheduled_start)),
edges AS (
    SELECT trip_id AS a, next_trip AS b, vehicle_id
    FROM seq
    WHERE actual_end IS NOT NULL AND next_actual_start IS NOT NULL
      AND actual_end - scheduled_end > interval '1 minute'
      AND next_sched_start - actual_end < interval '2 minutes'
      AND next_actual_start - next_sched_start > interval '30 seconds'),
chain AS (
    SELECT e.vehicle_id, e.a AS root, e.b AS last_trip, 2 AS trips_in_chain, ARRAY[e.a, e.b] AS path
    FROM edges e WHERE NOT EXISTS (SELECT 1 FROM edges x WHERE x.b = e.a)
    UNION ALL
    SELECT c.vehicle_id, c.root, e.b, c.trips_in_chain + 1, c.path || e.b
    FROM chain c JOIN edges e ON e.a = c.last_trip)
SELECT c.vehicle_id, c.path, c.trips_in_chain,
       round(EXTRACT(EPOCH FROM (t1.actual_end - t1.scheduled_end))) AS first_trip_end_delay_s,
       round(EXTRACT(EPOCH FROM (t2.actual_start - t2.scheduled_start))) AS last_trip_start_delay_s
FROM chain c
JOIN public.trips t1 ON t1.trip_id = c.root
JOIN public.trips t2 ON t2.trip_id = c.last_trip
WHERE NOT EXISTS (SELECT 1 FROM edges x WHERE x.a = c.last_trip)
ORDER BY c.trips_in_chain DESC, last_trip_start_delay_s DESC LIMIT 10;

-- H7 [ST + evaluation] Flag unusually slow traversals (below a fraction of the road's median speed) and score the
--   flags against the simulator's injected incident, for three thresholds.
--   Spatial : the unit of analysis is the road segment (the incident is on one road).
--   Temporal: a flag is correct if the traversal began inside the incident's time window (tsrange containment).
WITH med AS (
    SELECT road_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY avg_speed_kmh) AS m
    FROM public.segment_traversal GROUP BY road_id),
tr AS (
    SELECT st.traversal_id, st.avg_speed_kmh, med.m,
           EXISTS (SELECT 1 FROM sim.injected_event ie
                   WHERE ie.road_id = st.road_id AND ie.event_type = 'congestion'
                     AND ie.valid_period @> st.entered_at) AS truly_in_incident
    FROM public.segment_traversal st JOIN med USING (road_id))
SELECT th.frac AS flag_below_fraction_of_median,
       count(*) FILTER (WHERE avg_speed_kmh < th.frac * m AND truly_in_incident)         AS true_positives,
       count(*) FILTER (WHERE avg_speed_kmh < th.frac * m AND NOT truly_in_incident)     AS false_positives,
       count(*) FILTER (WHERE NOT avg_speed_kmh < th.frac * m AND truly_in_incident)     AS missed,
       round((count(*) FILTER (WHERE avg_speed_kmh < th.frac * m AND truly_in_incident))::numeric
             / NULLIF(count(*) FILTER (WHERE avg_speed_kmh < th.frac * m), 0), 2)        AS precision,
       round((count(*) FILTER (WHERE avg_speed_kmh < th.frac * m AND truly_in_incident))::numeric
             / NULLIF(count(*) FILTER (WHERE truly_in_incident), 0), 2)                  AS recall
FROM tr CROSS JOIN (VALUES (0.5), (0.6), (0.7)) AS th(frac)
GROUP BY th.frac ORDER BY th.frac;

-- H8 [ST] Corridor view across routes: everything that used the busiest road, by hour, regardless of route.
--   Spatial : fixes within 25 m of the road's line (ST_DWithin on geography), not matched to it by route.
--   Temporal: grouped by hour; includes vehicles from several different routes.
WITH hub AS (
    SELECT road_id FROM public.route_segments GROUP BY road_id ORDER BY count(DISTINCT route_id) DESC, road_id LIMIT 1)
SELECT rd.road_name, EXTRACT(HOUR FROM vp.recorded_at)::int AS hour_of_day,
       count(*) AS fixes, count(DISTINCT vp.vehicle_id) AS vehicles, count(DISTINCT t.route_id) AS routes,
       round(avg(vp.speed_kmh), 1) AS mean_kmh
FROM hub
JOIN public.road_segments rd USING (road_id)
JOIN public.vehicle_position vp ON ST_DWithin(vp.location::geography, rd.geom::geography, 25)
JOIN public.trips t ON t.trip_id = vp.trip_id
WHERE vp.recorded_at::date = (SELECT d FROM public.v_demo_day)
GROUP BY rd.road_name, 2 ORDER BY 2;

-- H9 [ST] Which trips will actually be ON the closed road during the closure?
--   (needs trips on the closure's date: start the demo clock or generate that day first)
--   Refines the whole-trip window overlap: it works out when each trip is planned to enter and leave the
--   closed road (from distance along the route and the planned stop times) and tests that interval against
--   the closure period. Shown next to the cruder whole-trip count.
--   Spatial : the closed road's position along each route (route_segments measures).
--   Temporal: planned time at a point = interpolation of the schedule; overlap of two time ranges.
WITH exposure AS (
    SELECT c.closure_id, c.valid_period, t.trip_id, r.route_code, t.scheduled_start,
           t.scheduled_start + make_interval(secs => public.planned_offset_s(rs.route_id, rs.start_measure_m)::double precision) AS planned_enter,
           t.scheduled_start + make_interval(secs => public.planned_offset_s(rs.route_id, rs.end_measure_m)::double precision)   AS planned_leave,
           tsrange(t.scheduled_start, t.scheduled_end) && c.valid_period AS whole_trip_overlaps
    FROM public.road_closures c
    JOIN public.route_segments rs ON rs.road_id = c.road_id
    JOIN public.routes r ON r.route_id = rs.route_id
    JOIN public.trips t ON t.route_id = rs.route_id AND t.service_date = lower(c.valid_period)::date)
SELECT count(*) FILTER (WHERE whole_trip_overlaps) AS trips_overlapping_closure_anywhere,
       count(*) FILTER (WHERE tsrange(planned_enter, planned_leave) && valid_period) AS trips_on_closed_road_during_closure
FROM exposure;

-- H10 [T] Rolling 15-minute window over the whole fleet: the slowest windows of the day.
--   For each minute: how many vehicles reported and their mean speed; then a trailing 15-minute average
--   (a RANGE window over a timestamp, not a row count).
--   Spatial : (none per row; speeds were measured by moving points).
--   Temporal: interval-based window frames.
WITH m AS (
    SELECT date_trunc('minute', recorded_at) AS minute, count(DISTINCT vehicle_id) AS active_vehicles, avg(speed_kmh) AS mean_kmh
    FROM public.vehicle_position
    WHERE recorded_at::date = (SELECT d FROM public.v_demo_day) AND trip_id IS NOT NULL GROUP BY 1)
SELECT minute, active_vehicles, round(mean_kmh, 1) AS minute_mean_kmh,
       round(avg(mean_kmh) OVER w, 1) AS rolling_15min_kmh,
       max(active_vehicles) OVER w AS peak_vehicles_in_window
FROM m
WINDOW w AS (ORDER BY minute RANGE BETWEEN INTERVAL '15 minutes' PRECEDING AND CURRENT ROW)
ORDER BY rolling_15min_kmh ASC LIMIT 10;

-- #####################################################################
-- CURRENT-DATA SNAPSHOT + ACCUMULATED-DATA DELAY REPORTS
-- These sections are intentionally separate from B1-H10. They analyse
-- the actual data already accumulated by the simulator, including a
-- partial/live service date. They do NOT call the simulator.
-- Run after PART 0. All dates are discovered from the database; no date
-- is hard-coded here. A partial live day must be labelled as partial.
-- #####################################################################

-- C1. What is the database's current simulation-clock state?
SELECT c.running, c.sim_start, c.speed, c.run_id,
       public.app_now() AS app_time,
       public.app_speed() AS app_speed
FROM (SELECT 1) seed
LEFT JOIN sim.clock c ON true;

-- C2. Which service dates exist, and how much data has accumulated on each?
SELECT t.service_date,
       count(DISTINCT t.trip_id) AS trips,
       count(DISTINCT t.trip_id) FILTER (WHERE t.status = 'Completed') AS completed_trips,
       count(DISTINCT t.trip_id) FILTER (WHERE t.status = 'In Progress') AS in_progress_trips,
       count(DISTINCT t.trip_id) FILTER (WHERE t.status = 'Scheduled') AS scheduled_trips,
       count(DISTINCT vp.position_id) AS gps_fixes,
       count(DISTINCT st.traversal_id) AS segment_traversals
FROM public.trips t
LEFT JOIN public.vehicle_position vp ON vp.trip_id = t.trip_id
LEFT JOIN public.segment_traversal st ON st.trip_id = t.trip_id
GROUP BY t.service_date
ORDER BY t.service_date;

-- C3. Identify the current/live service date. Prefer the simulation clock;
-- otherwise use the most recent service_date. This is an accumulated-so-far view.
WITH live_day AS (
    SELECT coalesce((SELECT sim_start::date FROM sim.clock LIMIT 1),
                    (SELECT max(service_date) FROM public.trips)) AS d
)
SELECT d AS live_service_date,
       (SELECT count(*) FROM public.trips t WHERE t.service_date = d) AS trips_created,
       (SELECT count(*) FROM public.trips t WHERE t.service_date = d AND t.status = 'Completed') AS completed,
       (SELECT count(*) FROM public.trips t WHERE t.service_date = d AND t.status = 'In Progress') AS in_progress,
       (SELECT count(*) FROM public.trips t WHERE t.service_date = d AND t.status = 'Scheduled') AS scheduled,
       (SELECT count(*) FROM public.vehicle_position vp WHERE vp.recorded_at::date = d) AS gps_fixes,
       (SELECT count(*) FROM public.segment_traversal st WHERE st.entered_at::date = d) AS traversals
FROM live_day;

-- C4. Live-day route status and mean observed arrival delay so far.
-- Averages use only stop arrivals that have actually been detected.
WITH live_day AS (
    SELECT coalesce((SELECT sim_start::date FROM sim.clock LIMIT 1),
                    (SELECT max(service_date) FROM public.trips)) AS d
)
SELECT r.route_code,
       count(DISTINCT t.trip_id) AS trips,
       count(e.trip_stop_id) FILTER (WHERE e.actual_arrival IS NOT NULL) AS observed_arrivals,
       round(avg(EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60)
             FILTER (WHERE e.actual_arrival IS NOT NULL), 2) AS mean_delay_min,
       round(max(EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60)
             FILTER (WHERE e.actual_arrival IS NOT NULL), 2) AS worst_delay_min
FROM live_day d
JOIN public.trips t ON t.service_date = d.d
JOIN public.routes r USING (route_id)
LEFT JOIN public.trip_stop_event e USING (trip_id)
GROUP BY r.route_code
ORDER BY mean_delay_min DESC NULLS LAST, r.route_code;

-- C5. Most delayed observed stop arrivals on the current/live service date.
WITH live_day AS (
    SELECT coalesce((SELECT sim_start::date FROM sim.clock LIMIT 1),
                    (SELECT max(service_date) FROM public.trips)) AS d
)
SELECT t.trip_id, r.route_code, v.vehicle_id, s.stop_name,
       e.scheduled_arrival, e.actual_arrival,
       round((EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60)::numeric, 2) AS delay_min
FROM live_day d
JOIN public.trips t ON t.service_date = d.d
JOIN public.routes r USING (route_id)
JOIN public.trip_stop_event e USING (trip_id)
JOIN public.stops s USING (stop_id)
JOIN public.vehicles v USING (vehicle_id)
WHERE e.actual_arrival IS NOT NULL
ORDER BY delay_min DESC
LIMIT 20;

-- C6. Live-day GPS activity by 15-minute interval.
WITH live_day AS (
    SELECT coalesce((SELECT sim_start::date FROM sim.clock LIMIT 1),
                    (SELECT max(service_date) FROM public.trips)) AS d
)
SELECT date_trunc('hour', vp.recorded_at)
         + floor(EXTRACT(MINUTE FROM vp.recorded_at) / 15) * interval '15 minutes' AS interval_start,
       count(*) AS fixes,
       count(DISTINCT vp.vehicle_id) AS vehicles,
       round(avg(vp.speed_kmh), 1) AS mean_speed_kmh
FROM live_day d
JOIN public.vehicle_position vp ON vp.recorded_at::date = d.d
WHERE vp.trip_id IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- C7. Live-day road-segment traversal performance accumulated so far.
WITH live_day AS (
    SELECT coalesce((SELECT sim_start::date FROM sim.clock LIMIT 1),
                    (SELECT max(service_date) FROM public.trips)) AS d
)
SELECT rd.road_name, count(*) AS traversals,
       round(avg(st.travel_time_s), 1) AS mean_travel_time_s,
       round(avg(st.avg_speed_kmh), 1) AS mean_speed_kmh,
       round(stddev(st.avg_speed_kmh), 1) AS speed_stddev_kmh
FROM live_day d
JOIN public.segment_traversal st ON st.entered_at::date = d.d
JOIN public.road_segments rd USING (road_id)
GROUP BY rd.road_id, rd.road_name
ORDER BY mean_speed_kmh ASC NULLS LAST, traversals DESC;

-- C8. Compare completed historical days: mean stop-arrival delay by service date.
-- This excludes unfinished arrivals by construction; interpret each date as a full-day
-- comparison only if its trips are in fact complete (check C2 first).
SELECT t.service_date,
       count(*) AS observed_arrivals,
       round(avg(EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60), 2) AS mean_delay_min,
       round(percentile_cont(0.50) WITHIN GROUP
             (ORDER BY EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60)::numeric, 2) AS median_delay_min,
       round(percentile_cont(0.90) WITHIN GROUP
             (ORDER BY EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60)::numeric, 2) AS p90_delay_min,
       count(*) FILTER (WHERE e.actual_arrival > e.scheduled_arrival + interval '5 minutes') AS late_over_5min
FROM public.trips t
JOIN public.trip_stop_event e USING (trip_id)
WHERE e.actual_arrival IS NOT NULL
GROUP BY t.service_date
ORDER BY t.service_date;

-- C9. Route-level delay comparison across all recorded service dates.
SELECT t.service_date, r.route_code,
       count(*) AS observed_arrivals,
       round(avg(EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60), 2) AS mean_delay_min,
       round(max(EXTRACT(EPOCH FROM (e.actual_arrival - e.scheduled_arrival)) / 60), 2) AS max_delay_min,
       count(*) FILTER (WHERE e.actual_arrival > e.scheduled_arrival + interval '5 minutes') AS arrivals_over_5min_late
FROM public.trips t
JOIN public.routes r USING (route_id)
JOIN public.trip_stop_event e USING (trip_id)
WHERE e.actual_arrival IS NOT NULL
GROUP BY t.service_date, r.route_code
ORDER BY t.service_date, mean_delay_min DESC;

-- C10. Candidate vehicle-level delay carry-over across consecutive trips.
-- This is descriptive association, not causal proof. It uses actual_end/actual_start
-- derived from GPS and compares each trip with the next trip assigned to that vehicle.
WITH ordered AS (
    SELECT t.service_date, t.vehicle_id, t.trip_id,
           t.scheduled_start, t.scheduled_end, t.actual_start, t.actual_end,
           lead(t.trip_id) OVER w AS next_trip_id,
           lead(t.scheduled_start) OVER w AS next_scheduled_start,
           lead(t.actual_start) OVER w AS next_actual_start
    FROM public.trips t
    WHERE t.status <> 'Cancelled'
    WINDOW w AS (PARTITION BY t.vehicle_id ORDER BY t.scheduled_start, t.trip_id)
)
SELECT service_date, vehicle_id, trip_id, next_trip_id,
       round(EXTRACT(EPOCH FROM (actual_end - scheduled_end))::numeric) AS previous_end_delay_s,
       round(EXTRACT(EPOCH FROM (next_actual_start - next_scheduled_start))::numeric) AS next_start_delay_s,
       round(EXTRACT(EPOCH FROM (next_scheduled_start - actual_end))::numeric) AS actual_turnaround_s
FROM ordered
WHERE actual_end IS NOT NULL AND next_actual_start IS NOT NULL
  AND actual_end > scheduled_end + interval '1 minute'
  AND next_actual_start > next_scheduled_start + interval '30 seconds'
ORDER BY service_date, previous_end_delay_s DESC;

-- C11. Compare recorded segment speeds with the simulator's injected congestion windows.
-- Each traversal is labelled by whether its entered_at timestamp falls inside an injected
-- congestion interval on that same road. This is useful for evaluating the synthetic signal.
SELECT rd.road_name,
       count(*) FILTER (WHERE ie.event_id IS NOT NULL) AS traversals_during_injected_congestion,
       count(*) FILTER (WHERE ie.event_id IS NULL) AS traversals_outside_injected_congestion,
       round(avg(st.avg_speed_kmh) FILTER (WHERE ie.event_id IS NOT NULL), 2) AS mean_speed_during_kmh,
       round(avg(st.avg_speed_kmh) FILTER (WHERE ie.event_id IS NULL), 2) AS mean_speed_outside_kmh
FROM public.segment_traversal st
JOIN public.road_segments rd USING (road_id)
LEFT JOIN sim.injected_event ie
  ON ie.road_id = st.road_id
 AND ie.event_type = 'congestion'
 AND ie.valid_period @> st.entered_at
GROUP BY rd.road_id, rd.road_name
ORDER BY mean_speed_during_kmh ASC NULLS LAST;

-- C12. One-row summary suitable for a final demonstration slide/report.
SELECT
  (SELECT count(*) FROM public.trips) AS total_trips,
  (SELECT count(*) FROM public.vehicle_position) AS total_gps_fixes,
  (SELECT count(*) FROM public.trip_stop_event WHERE actual_arrival IS NOT NULL) AS detected_stop_arrivals,
  (SELECT count(*) FROM public.segment_traversal) AS derived_segment_traversals,
  (SELECT count(*) FROM sim.injected_event) AS injected_events,
  (SELECT count(DISTINCT service_date) FROM public.trips) AS service_dates,
  (SELECT count(*) FROM public.trips WHERE status = 'Completed') AS completed_trips;

-- End of analytical workload. All reports above read the accumulated database data;
-- none of them starts, resumes, pauses, resets or advances the simulator.
