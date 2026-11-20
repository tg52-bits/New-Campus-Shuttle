-- 1. Overall delay summary
SELECT
    COUNT(*) AS total_stop_arrivals,

    ROUND(AVG(
        EXTRACT(EPOCH FROM (
            actual_arrival - scheduled_arrival
        )) / 60
    )::numeric, 2) AS avg_delay_min,

    ROUND(MAX(
        EXTRACT(EPOCH FROM (
            actual_arrival - scheduled_arrival
        )) / 60
    )::numeric, 2) AS max_delay_min,

    ROUND(MIN(
        EXTRACT(EPOCH FROM (
            actual_arrival - scheduled_arrival
        )) / 60
    )::numeric, 2) AS min_delay_min,

    COUNT(*) FILTER (
        WHERE actual_arrival > scheduled_arrival
    ) AS late_arrivals,

    COUNT(*) FILTER (
        WHERE actual_arrival <= scheduled_arrival
    ) AS on_time_or_early

FROM trip_stop_event
WHERE actual_arrival IS NOT NULL
  AND scheduled_arrival IS NOT NULL;



-- 2. Route Wise delay analysis
SELECT
    r.route_code,
    r.route_name,
    COUNT(*) AS total_arrivals,

    ROUND(AVG(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS avg_delay_min,

    ROUND(MAX(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS max_delay_min

FROM trip_stop_event tse
JOIN trips t
    ON t.trip_id = tse.trip_id
JOIN routes r
    ON r.route_id = t.route_id

WHERE tse.actual_arrival IS NOT NULL
  AND tse.scheduled_arrival IS NOT NULL

GROUP BY r.route_id, r.route_code, r.route_name
ORDER BY avg_delay_min DESC;

-- 3. Vehicle wise delay analysis
SELECT
    v.vehicle_id,
    v.registration_no,

    COUNT(*) AS completed_arrivals,

    ROUND(AVG(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS avg_delay_min,

    ROUND(MAX(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS max_delay_min

FROM trip_stop_event tse
JOIN trips t
    ON t.trip_id = tse.trip_id
JOIN vehicles v
    ON v.vehicle_id = t.vehicle_id

WHERE tse.actual_arrival IS NOT NULL
  AND tse.scheduled_arrival IS NOT NULL

GROUP BY v.vehicle_id, v.registration_no
ORDER BY avg_delay_min DESC;


-- 4. Stop wise Delay analysis
SELECT
    s.stop_id,
    s.stop_name,

    COUNT(*) AS total_arrivals,

    ROUND(AVG(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS avg_delay_min,

    ROUND(MAX(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS max_delay_min

FROM trip_stop_event tse
JOIN stops s
    ON s.stop_id = tse.stop_id

WHERE tse.actual_arrival IS NOT NULL
  AND tse.scheduled_arrival IS NOT NULL

GROUP BY s.stop_id, s.stop_name
ORDER BY avg_delay_min DESC;

-- 5. Individual trip delay breakdown
SELECT
    t.trip_id,
    r.route_code,
    t.vehicle_id,
    tse.stop_sequence,
    s.stop_name,

    tse.scheduled_arrival,
    tse.actual_arrival,

    ROUND((
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS delay_min

FROM trip_stop_event tse
JOIN trips t
    ON t.trip_id = tse.trip_id
JOIN routes r
    ON r.route_id = t.route_id
JOIN stops s
    ON s.stop_id = tse.stop_id

WHERE t.trip_id = 4860
  AND tse.actual_arrival IS NOT NULL

ORDER BY tse.stop_sequence;


-- 7. Same-vehicle consecutive trip analysis
WITH vehicle_trips AS (
    SELECT
        t.trip_id,
        t.vehicle_id,
        t.service_date,
        t.scheduled_start,
        t.scheduled_end,
        t.actual_start,
        t.actual_end,

        LAG(t.trip_id) OVER w AS previous_trip_id,
        LAG(t.scheduled_end) OVER w AS previous_scheduled_end,
        LAG(t.actual_end) OVER w AS previous_actual_end

    FROM trips t

    WINDOW w AS (
        PARTITION BY t.vehicle_id, t.service_date
        ORDER BY t.scheduled_start
    )
)
SELECT
    vehicle_id,
    service_date,
    previous_trip_id,
    trip_id,

    previous_scheduled_end,
    previous_actual_end,
    scheduled_start,
    actual_start,

    ROUND((
        EXTRACT(EPOCH FROM (
            previous_actual_end - previous_scheduled_end
        )) / 60
    )::numeric, 2) AS previous_trip_end_delay_min,

    ROUND((
        EXTRACT(EPOCH FROM (
            actual_start - scheduled_start
        )) / 60
    )::numeric, 2) AS current_trip_start_delay_min,

    ROUND((
        EXTRACT(EPOCH FROM (
            actual_start - previous_actual_end
        )) / 60
    )::numeric, 2) AS actual_turnaround_min

FROM vehicle_trips
WHERE previous_trip_id IS NOT NULL
  AND previous_actual_end IS NOT NULL
  AND actual_start IS NOT NULL

ORDER BY vehicle_id, service_date, scheduled_start;


-- 8. Delay distribution
SELECT
    CASE
        WHEN delay_min <= 0 THEN 'On time / Early'
        WHEN delay_min <= 2 THEN '0–2 minutes'
        WHEN delay_min <= 5 THEN '2–5 minutes'
        WHEN delay_min <= 10 THEN '5–10 minutes'
        ELSE 'Above 10 minutes'
    END AS delay_category,

    COUNT(*) AS arrival_count

FROM (
    SELECT
        EXTRACT(EPOCH FROM (
            actual_arrival - scheduled_arrival
        )) / 60 AS delay_min

    FROM trip_stop_event
    WHERE actual_arrival IS NOT NULL
      AND scheduled_arrival IS NOT NULL
) d

GROUP BY 1
ORDER BY MIN(delay_min);


-- 9. Road-segment speed and congestion analysis
SELECT
    road_id,

    COUNT(*) AS traversal_count,

    ROUND(AVG(avg_speed_kmh), 2) AS avg_speed_kmh,

    ROUND(AVG(travel_time_s), 2) AS avg_travel_time_sec,

    ROUND(MIN(avg_speed_kmh), 2) AS min_speed_kmh,

    ROUND(MAX(avg_speed_kmh), 2) AS max_speed_kmh

FROM segment_traversal

WHERE avg_speed_kmh IS NOT NULL
  AND travel_time_s IS NOT NULL

GROUP BY road_id
ORDER BY avg_speed_kmh ASC;


-- 10. Historical delay trend by service date
SELECT
    t.service_date,

    COUNT(*) AS total_arrivals,

    ROUND(AVG(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS avg_delay_min,

    ROUND(MAX(
        EXTRACT(EPOCH FROM (
            tse.actual_arrival - tse.scheduled_arrival
        )) / 60
    )::numeric, 2) AS max_delay_min,

    COUNT(*) FILTER (
        WHERE tse.actual_arrival > tse.scheduled_arrival
    ) AS late_arrivals

FROM trip_stop_event tse
JOIN trips t
    ON t.trip_id = tse.trip_id

WHERE tse.actual_arrival IS NOT NULL
  AND tse.scheduled_arrival IS NOT NULL

GROUP BY t.service_date
ORDER BY t.service_date;

-- 11. Latest GPS position for each active trip
WITH latest_positions AS (
    SELECT DISTINCT ON (vp.trip_id)
        vp.trip_id,
        vp.vehicle_id,
        vp.recorded_at,
        vp.speed_kmh,
        vp.measure_m,
        vp.dist_to_route_m,
        vp.on_route

    FROM vehicle_position vp

    WHERE vp.trip_id IS NOT NULL

    ORDER BY vp.trip_id, vp.recorded_at DESC
)
SELECT
    t.trip_id,
    r.route_code,
    lp.vehicle_id,
    lp.recorded_at,
    lp.speed_kmh,
    lp.measure_m,
    lp.dist_to_route_m,
    lp.on_route,
    t.status

FROM latest_positions lp
JOIN trips t
    ON t.trip_id = lp.trip_id
JOIN routes r
    ON r.route_id = t.route_id

WHERE t.status = 'In Progress'
ORDER BY t.trip_id;

-- 12. Delay carry-over comparison across trips
WITH trip_delays AS (
    SELECT
        t.trip_id,
        t.vehicle_id,
        t.service_date,
        t.scheduled_start,
        t.scheduled_end,
        t.actual_start,
        t.actual_end,

        EXTRACT(EPOCH FROM (
            t.actual_start - t.scheduled_start
        )) / 60 AS start_delay_min,

        EXTRACT(EPOCH FROM (
            t.actual_end - t.scheduled_end
        )) / 60 AS end_delay_min

    FROM trips t
),
ordered_trips AS (
    SELECT
        *,

        LAG(trip_id) OVER w AS previous_trip_id,
        LAG(end_delay_min) OVER w AS previous_trip_end_delay_min

    FROM trip_delays

    WINDOW w AS (
        PARTITION BY vehicle_id, service_date
        ORDER BY scheduled_start
    )
)
SELECT
    vehicle_id,
    service_date,
    previous_trip_id,
    trip_id,

    ROUND(
        previous_trip_end_delay_min::numeric, 2
    ) AS previous_trip_end_delay_min,

    ROUND(
        start_delay_min::numeric, 2
    ) AS current_trip_start_delay_min,

    ROUND((
        start_delay_min - previous_trip_end_delay_min
    )::numeric, 2) AS delay_difference_min

FROM ordered_trips

WHERE previous_trip_id IS NOT NULL
  AND previous_trip_end_delay_min IS NOT NULL
  AND start_delay_min IS NOT NULL

ORDER BY vehicle_id, service_date, scheduled_start;
