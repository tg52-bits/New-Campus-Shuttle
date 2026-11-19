# Campus Shuttle Delay Analysis Database — Complete Walkthrough

**Platform:** PostgreSQL 17 + PostGIS, pgAdmin 4  
**Database:** `Campus Shuttle 1.0`  
**Purpose:** Rebuild/verify the database, generate historical and live simulated GPS data, inspect derived data, and finally run the analytical workload in `campus_shuttle_delay_analysis_queries.sql`.

> **Important:** This walkthrough distinguishes *installing the database* from *running the simulator*. Installing SQL creates the schema, map, timetable, triggers, functions and checks. It does **not** automatically generate three days of GPS history or start a live simulation.
>
> **Do not run the clean-install script against a database that already contains your project data.** It is intended for a new, empty database. For the existing `Campus Shuttle 1.0`, start at Section 4 (reopen and inspect) or Section 5 (continue simulation).

---

## 1. What the project demonstrates

The database stores a campus road network, zones, stops, routes, vehicles, drivers and a timetable. Simulated GPS fixes are the raw moving-vehicle observations. Database triggers/functions derive route matching, stop arrivals/departures, trip status and road-segment traversals.

The analysis then asks questions such as:

- Which routes/stops experience the greatest delay?
- How does lateness change by hour (peak vs off-peak)?
- Which road segments have low or unpredictable speeds?
- Where do slow-moving GPS observations cluster spatially?
- Does a late trip appear to be associated with a late next trip assigned to the same vehicle?
- How do actual stop-to-stop journey times compare with the timetable?

**Important interpretation:** a temporal association between a late trip and a subsequent late trip is evidence of *possible delay propagation*, not proof of causation. The simulator also has known injected congestion events, which can be used as ground truth for evaluation.

## 2. Database and SQL file order

The project SQL bundle is organised in this dependency order:

| Order | File | Purpose |
|---|---|---|
| 1 | `01_schema.sql` | Extensions, schemas, tables, constraints, indexes, configuration |
| 2 | `02_map_and_data.sql` | Road network, campus zones, stops, routes, vehicles, drivers, timetable |
| 3 | `03_derivation.sql` | Spatial derivation, route building, GPS processing, stop detection, segment traversals |
| 4 | `04_simulator.sql` | Fast-forward history generator, adjustable clock and live GPS simulator |
| 5 | `05_app_functions.sql` | ETA helpers, rider/staff functions and `v_trip_flow` |
| 6 | `06_checks.sql` | Rollback-safe database validation suite |
| 7 | `07_query_ladder.sql` / `campus_shuttle_delay_analysis_queries.sql` | Analytical query workload (run after installation and data generation) |

### Two ways to install

**Option A — one-pass installer (recommended for a genuinely new, empty database):**

- Run `00_install_and_check.sql` once, from top to bottom.
- This combined file contains the content of `01_schema.sql` through `06_checks.sql` in order. It installs the objects, loads the reference map/data, builds derived route structures, creates simulator and application functions, and executes the validation suite.
- It does **not** call `sim.load_demo`, `sim.start_clock` or `sim.run_live`; those are separate data-generation steps.

**Option B — individual scripts:**

Run the six component files in the numbered order in the table. Do not run `03_derivation.sql` before the map/data is loaded. Do not run `04_simulator.sql` before derivation triggers exist. Run the query file only after the installation and data-generation stages.

The combined installer is the authoritative all-in-one source available in this project bundle. If using the individual-file route, use the matching component scripts from the project folder, not fragments copied out of order.

## 3. First-time setup from scratch (new database only)

### 3.1 Confirm PostgreSQL and PostGIS

1. Open pgAdmin 4 and connect to the PostgreSQL 17 server.
2. Right-click **Databases → Create → Database**.
3. Create a new database named `Campus Shuttle 1.0` (or another name you deliberately choose; then use that exact name consistently).
4. Open Query Tool for that new database.
5. Check the server and database:

```sql
SELECT current_database(), version(), inet_server_addr(), inet_server_port();
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'postgis';
```

PostGIS must be available. The installer creates the extension with `CREATE EXTENSION IF NOT EXISTS postgis` (and `btree_gist`).

### 3.2 Run the installer

In pgAdmin Query Tool connected to the new empty database:

1. Open `00_install_and_check.sql`.
2. Execute the whole file with **F5** (or the Execute button).
3. Read the Messages tab for errors/notices. Do not continue if the installer stops on an SQL error; fix that first.

The installer includes checks for the map, connected road network, stop snapping, route construction, timetable and provenance. It also creates and runs `public.run_checks()`.

### 3.3 Verify installation

Run:

```sql
SELECT * FROM public.run_checks();
```

Expected on the validated build: **68 passed, 0 failed**.

Check the static/reference data:

```sql
SELECT
  (SELECT count(*) FROM public.road_segments) AS road_segments,
  (SELECT count(*) FROM public.campus_zones) AS campus_zones,
  (SELECT count(*) FROM public.stops) AS stops,
  (SELECT count(*) FROM public.routes) AS routes,
  (SELECT count(*) FROM public.vehicles) AS vehicles,
  (SELECT count(*) FROM public.drivers) AS drivers,
  (SELECT count(*) FROM public.timetable_departures) AS timetable_departures;
```

Expected validated seed counts: 46 road segments, 8 zones, 12 stops, 10 routes, 13 vehicles, 12 drivers and 280 timetable departures. A small difference means compare against the exact seed script version before proceeding.

Check route geometries and stop snapping:

```sql
SELECT route_code, ST_SRID(route_geometry) AS srid,
       round(length_m) AS length_m,
       (SELECT count(*) FROM public.route_segments rs WHERE rs.route_id = r.route_id) AS road_parts
FROM public.routes r
ORDER BY route_code;

SELECT stop_id, stop_name, road_id, zone_id, round(snap_distance_m) AS snap_m
FROM public.stops
ORDER BY stop_id;
```

All ten routes should have a non-null route geometry and route-segment rows. Stops should have been snapped/associated by the derivation triggers; a stop outside a campus zone may legitimately have a null `zone_id` if the map definition places it outside a polygon.

## 4. Reopening the existing database after closing pgAdmin

Closing pgAdmin does not delete PostgreSQL data. PostgreSQL persists committed rows on disk. The simulator is not a background service: it only produces more GPS fixes when you explicitly execute simulator functions/procedures.

1. Start/connect to the same PostgreSQL 17 server in pgAdmin.
2. Expand **Databases → Campus Shuttle 1.0**.
3. Open Query Tool on that database (verify the database name before running SQL).
4. Run this identity check:

```sql
SELECT current_database(), version(), inet_server_addr(), inet_server_port();
```

Expected database: `Campus Shuttle 1.0`; the validated server was PostgreSQL 17.11 on port 5432.

### 4.1 Inspect the simulator clock before doing anything

```sql
SELECT singleton, running, sim_start, wall_start, speed, run_id
FROM sim.clock;

SELECT public.app_now() AS application_time,
       public.app_speed() AS application_speed;
```

Interpretation:

- `running = true`: the adjustable clock is advancing according to wall-clock elapsed time × `speed` (provided some process is calling the live tick loop; the clock expression itself advances while marked running).
- `running = false`: the clock is frozen at `sim_start`; `app_speed()` reports 1.
- No row in `sim.clock`: rider-facing `app_now()` falls back to the PostgreSQL real clock and `app_speed()` is 1.
- A row in `sim.clock` does not mean a GPS generator is continuously running. GPS rows are emitted by `sim.tick()` / `sim.run_live()`.

If a previous live procedure was interrupted or its client disconnected before the normal end-of-run pause, freeze the clock explicitly:

```sql
SELECT sim.pause_clock();
```

### 4.2 Inspect which service dates exist and how complete they are

```sql
SELECT t.service_date,
       count(*) AS trips,
       count(*) FILTER (WHERE t.status = 'Completed') AS completed,
       count(*) FILTER (WHERE t.status = 'In Progress') AS in_progress,
       count(*) FILTER (WHERE t.status = 'Scheduled') AS scheduled,
       count(*) FILTER (WHERE t.status = 'Cancelled') AS cancelled,
       count(vp.position_id) AS gps_fixes,
       count(DISTINCT t.sim_run_id) AS simulator_runs
FROM public.trips t
LEFT JOIN public.vehicle_position vp ON vp.trip_id = t.trip_id
GROUP BY t.service_date
ORDER BY t.service_date;
```

This is the definitive way to determine the historical dates in *this database*. Do not assume the dates just from an earlier terminal output. A date with only some trips completed may be an active/partial service day; a fully completed date is suitable for full-day comparisons.

Inspect run descriptions and injected events:

```sql
SELECT run_id, seed, description, started_at
FROM sim.run
ORDER BY run_id;

SELECT ie.event_id, ie.run_id, ie.event_type, rd.road_name,
       ie.valid_period, ie.magnitude, ie.note
FROM sim.injected_event ie
LEFT JOIN public.road_segments rd USING (road_id)
ORDER BY ie.run_id, ie.event_id;
```

Inspect the current data-flow pipeline:

```sql
SELECT * FROM public.v_trip_flow
ORDER BY scheduled_start DESC
LIMIT 20;
```

## 5. Generate historical days (fast-forward)

Historical data is generated in one call per day. `sim.load_demo` is a convenience wrapper around `sim.run_full_day`; it creates `p_days` consecutive completed days beginning at `p_first_day`.

**Only do this if you intentionally need to build history in a fresh database.** Do not rerun it for dates already present: `sim.run_full_day` detects an existing service date and skips it.

Example: create three historical days, November 17–19, leaving November 20 for a live demonstration:

```sql
SELECT sim.load_demo(DATE '2026-11-17', 3, 100);
```

General form:

```sql
SELECT sim.load_demo(DATE 'YYYY-MM-DD', 3, 100);
```

Replace the date with the first historical date you want. The next date after the three generated dates is the intended live-demo date. The function prints notices showing trips and fixes generated for each date.

Check the results:

```sql
SELECT service_date, count(*) AS trips,
       count(*) FILTER (WHERE status = 'Completed') AS completed,
       count(*) FILTER (WHERE status <> 'Completed') AS not_completed
FROM public.trips
GROUP BY service_date
ORDER BY service_date;

SELECT recorded_at::date AS service_date, count(*) AS gps_fixes,
       count(DISTINCT vehicle_id) AS vehicles
FROM public.vehicle_position
GROUP BY recorded_at::date
ORDER BY service_date;

SELECT recorded_at::date AS service_date, count(*) AS segment_traversals
FROM public.segment_traversal
GROUP BY recorded_at::date
ORDER BY service_date;
```

A complete fast-forward day should have its trips completed and GPS fixes inserted. `segment_traversal` is derived when trips complete; it is a key source for road-speed and variability analysis.

## 6. Start the live demonstration day

The live day is separate from the earlier historical days. In the validated demonstration, the historical dates preceded **November 20, 2026**, and the live clock was started on November 20 at 07:50.

Example command used in the working demonstration:

```sql
SELECT sim.start_clock(
    TIMESTAMP '2026-11-20 07:50:00',
    30,
    7
);
```

Parameters:

1. Simulated start timestamp.
2. Simulation speed multiplier (30 means 30 simulated seconds per wall-clock second while running).
3. Random seed (for reproducibility of simulator behaviour).

What `sim.start_clock` does:

- creates a new simulator run;
- inserts an injected congestion event;
- inserts a planned road closure for the demonstration;
- creates the service-day trips if they do not already exist;
- fast-forwards GPS for trips up to the chosen start time;
- creates the adjustable clock in the running state.

Check:

```sql
SELECT * FROM sim.clock;
SELECT public.app_now(), public.app_speed();

SELECT service_date, status, count(*)
FROM public.trips
WHERE service_date = DATE '2026-11-20'
GROUP BY service_date, status
ORDER BY status;
```

### 6.1 Run the live simulator for a bounded time

```sql
CALL sim.run_live(60, 1000);
```

- `60` = run for 60 real/wall-clock seconds.
- `1000` = wait 1000 milliseconds between ticks.
- The procedure emits due GPS fixes, and triggers process them into route matches, stop events, trip state and traversals.
- The procedure commits between ticks so another database session can inspect progress.
- At normal completion it freezes the clock (`running = false`). It does **not** run forever.

To run for two minutes:

```sql
CALL sim.run_live(120, 1000);
```

The procedure occupies that Query Tool connection while running. Wait for it to finish, or use another Query Tool session to inspect committed progress. Avoid closing/terminating the running session mid-call; if it is interrupted, inspect `sim.clock` and run `SELECT sim.pause_clock();` if necessary.

### 6.2 Continue/resume the live day later

A normal completed `CALL sim.run_live(...)` leaves the clock paused at its final simulated timestamp. Calling it again resumes from that frozen timestamp and runs for the new bounded duration:

```sql
CALL sim.run_live(60, 1000);
```

You can also explicitly resume/pause the clock, but GPS fixes are only emitted when ticks are executed:

```sql
SELECT sim.resume_clock();
SELECT sim.tick();          -- one tick only; emits fixes due at current simulated time
SELECT sim.pause_clock();
```

Changing speed:

```sql
SELECT sim.set_speed(30);
```

`set_speed` marks the clock running. For a controlled demo, use the bounded `CALL sim.run_live(...)` and let it pause normally.

### 6.3 Check live data accumulation

```sql
SELECT public.app_now() AS sim_time, public.app_speed() AS sim_speed;
SELECT singleton, running, sim_start, speed, run_id FROM sim.clock;

SELECT count(*) AS gps_fixes,
       count(DISTINCT vehicle_id) AS vehicles,
       min(recorded_at) AS first_fix,
       max(recorded_at) AS last_fix
FROM public.vehicle_position
WHERE recorded_at::date = DATE '2026-11-20';

SELECT status, count(*)
FROM public.trips
WHERE service_date = DATE '2026-11-20'
GROUP BY status
ORDER BY status;

SELECT * FROM public.v_trip_flow
WHERE scheduled_start::date = DATE '2026-11-20'
ORDER BY scheduled_start;
```

Use the actual live date if it is not November 20. The date shown above is the date used in the validated run captured in this project session.

## 7. How the historical days and live day differ

There are two data-generation modes, both persistent in the same tables:

| Mode | Function | Behaviour | Typical use |
|---|---|---|---|
| Fast-forward | `sim.load_demo(first_date, days, seed)` | Generates complete days and GPS history in one operation | Build multi-day baseline history |
| Live | `sim.start_clock(...)` + `CALL sim.run_live(...)` | Starts a simulated clock; bounded loop emits fixes as simulated time advances | Demonstrate live operation and current-day delay |

The historical dates and live date are not separate databases. They are separate `service_date` values in `public.trips`, with GPS observations in `public.vehicle_position`, and simulator run metadata in `sim.run`.

The live day is usually intentionally incomplete at the moment of demonstration: some trips are completed, some in progress, and later trips still scheduled. That is why the query file keeps two analysis scopes:

- **Latest completed day:** `public.v_demo_day`, used for whole-day statistics that need complete observations.
- **Current/live day:** the date in `sim.clock.sim_start` (or the latest service date if there is no clock row), used for live progress and accumulated-so-far reports. Partial-day results must be labelled as partial; they should not be compared to a full day without qualification.

The simulator does not automatically continue generating GPS when pgAdmin is closed. Committed rows remain stored, and a later bounded `CALL sim.run_live(...)` can continue from the frozen clock.

## 8. Intermediate checks before analytical queries

Run these checks after generating the historical data and after the live run.

### 8.1 Date/run inventory

```sql
SELECT service_date, count(*) AS trips,
       count(*) FILTER (WHERE status = 'Completed') AS completed,
       count(*) FILTER (WHERE status = 'In Progress') AS in_progress,
       count(*) FILTER (WHERE status = 'Scheduled') AS scheduled
FROM public.trips
GROUP BY service_date
ORDER BY service_date;

SELECT run_id, seed, description FROM sim.run ORDER BY run_id;
```

### 8.2 GPS, matching and stop detection

```sql
SELECT
  count(*) AS total_fixes,
  count(*) FILTER (WHERE trip_id IS NOT NULL) AS assigned_to_trip,
  count(*) FILTER (WHERE measure_m IS NOT NULL) AS route_matched,
  count(*) FILTER (WHERE off_route) AS flagged_off_route
FROM public.vehicle_position;

SELECT
  count(*) AS stop_events,
  count(*) FILTER (WHERE actual_arrival IS NOT NULL) AS arrivals_detected,
  count(*) FILTER (WHERE actual_departure IS NOT NULL) AS departures_detected
FROM public.trip_stop_event;
```

### 8.3 Segment traversal derivation

```sql
SELECT count(*) AS traversals,
       count(DISTINCT road_id) AS distinct_roads,
       round(avg(avg_speed_kmh), 2) AS mean_speed_kmh,
       round(min(avg_speed_kmh), 2) AS minimum_traversal_speed,
       round(max(avg_speed_kmh), 2) AS maximum_traversal_speed
FROM public.segment_traversal;
```

### 8.4 Trip pipeline sample

```sql
SELECT trip_id, route_code, vehicle_id, status,
       planned_stop_events, gps_fixes, fixes_matched_to_route,
       stops_arrived, stops_departed, road_traversals, last_fix_at
FROM public.v_trip_flow
ORDER BY trip_id DESC
LIMIT 15;
```

A trip progresses through the pipeline: scheduled trip and planned stop events → raw GPS fixes → route matching → inferred stop arrivals/departures → trip status → segment traversals when complete. Some counts are naturally incomplete for trips still in progress.

## 9. Run the delay-analysis query file (final demonstration stage)

Only after the database is installed and the desired historical/live data exists:

1. Open `campus_shuttle_delay_analysis_queries.sql` in pgAdmin Query Tool connected to `Campus Shuttle 1.0`.
2. Run **PART 0** once. It creates `public.v_demo_day` and `public.planned_offset_s`, two analytical helpers. It does not delete or rewrite operational data.
3. Run the **CURRENT-DATA SNAPSHOT** section to show the actual accumulated dates, simulator clock, trip statuses, GPS counts and derived-event counts.
4. Run the **BASIC** queries B1–B10. Select one query at a time and press F5.
5. Run **MEDIUM** M1–M10 one at a time.
6. Run **HARD** H1–H10 one at a time. Some hard queries need enough completed trips/fixes; an empty result on a small partial dataset is not necessarily a database error.
7. Finish with the **ACCUMULATED-DATA DELAY REPORTS**. These reports use the rows already generated by the simulator and do not start or advance the simulator.

The query file is read-only except for PART 0 helper creation. It does not reset a day, regenerate trips or start the clock.

## 10. Resetting or rebuilding data — caution

`sim.reset_day(date)` is destructive for that one service date. It removes that date's trips, GPS fixes, segment traversals, trip plans, associated road closures and the demo clock. It does not remove the static map or other service dates.

Example (do not run unless you intentionally want to erase that date's simulation data):

```sql
SELECT sim.reset_day(DATE '2026-11-20');
```

To rebuild the live day after resetting it, call `sim.start_clock(...)` again. Do not use `DROP DATABASE`, `DROP SCHEMA`, `TRUNCATE` or rerun the clean installer as a routine restart procedure.

## 11. Suggested live presentation sequence

For a short, clear demonstration:

1. Show the database identity and PostGIS extension.
2. Show the static campus map counts: roads, zones, stops, routes and vehicles.
3. Show `public.run_checks()` passing.
4. Show the service-date inventory to distinguish completed historical days from the partial live day.
5. Show the `sim.clock` row and explain the adjustable clock.
6. Run `CALL sim.run_live(30, 1000);` (30 seconds is enough for a short live demonstration) and show that the clock pauses afterward.
7. Show the GPS → route match → stop event → segment traversal pipeline with `public.v_trip_flow` and the intermediate checks.
8. Run selected analytical queries: B7 (trip start delay), M3 (stop/hour lateness), M6 (road variability), H3 (slow stop-to-stop legs), H6 (candidate delay-propagation chains), H7 (incident detection evaluation), then the accumulated-data reports.
9. Explain that a positive delay is late, a negative delay is early, and partial-day results are not directly comparable to completed-day totals.

## 12. Key explanation for viva/demo

- **Raw data:** `public.vehicle_position` stores timestamped GPS point observations.
- **Spatial reference data:** road segments, zones, stops and route geometries are represented with PostGIS geometry.
- **Temporal reference data:** timetable departures and road-closure validity intervals.
- **Derived data:** route measures/matching, stop events, trip actual start/end/status and road-segment traversals are maintained by database logic.
- **Delay:** actual event time minus scheduled event time. Positive means late; negative means early.
- **Congestion evidence:** lower observed segment speeds and longer travel times in particular places/time windows.
- **Propagation:** compare consecutive trips assigned to the same vehicle. Treat the result as a candidate relationship, not definitive causation.
- **Incident evaluation:** compare slow-traversal flags against the simulator's injected event windows (ground truth).
- **Persistence:** committed rows survive closing pgAdmin. The live generator is an explicitly invoked bounded procedure, not an always-on daemon.

---

**End of walkthrough.** The next file to open is `campus_shuttle_delay_analysis_queries.sql`.
