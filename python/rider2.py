from db import get_connection
import psycopg
import time


def display_results(title, query, params=None):
    """Execute a query and display its results in a formatted table."""
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params or ())
                rows = cur.fetchall()

                print("\n" + "=" * 110)
                print(title.center(110))
                print("=" * 110)

                if not rows:
                    print("\nNo records found.")
                    return

                columns = [desc.name for desc in cur.description]
                data = [
                    ["NULL" if value is None else str(value) for value in row]
                    for row in rows
                ]

                widths = [
                    max(len(columns[i]), *(len(row[i]) for row in data))
                    for i in range(len(columns))
                ]

                header = " | ".join(
                    columns[i].ljust(widths[i]) for i in range(len(columns))
                )

                print(header)
                print("-" * len(header))

                for row in data:
                    print(
                        " | ".join(row[i].ljust(widths[i]) for i in range(len(columns)))
                    )

                print(f"\nTotal records: {len(rows)}")

    except psycopg.Error as e:
        print("\nDatabase error:", e)


def get_simulation_status():
    """Display the current simulation clock state."""
    display_results(
        "SIMULATION CLOCK",
        """
        SELECT
            public.app_now() AS simulation_time,
            public.app_speed() AS simulation_speed,
            c.running AS clock_running,
            c.run_id
        FROM sim.clock c;
        """,
    )


# ---------------------------------------------------------
# EXISTING RIDER FUNCTIONS
# ---------------------------------------------------------


def where_is_my_bus():
    route = input("\nEnter route code (leave blank for all routes): ").strip()

    display_results(
        "BUS LOCATIONS",
        """
        SELECT *
        FROM public.app_where_is_bus(%s);
        """,
        (route if route else None,),
    )


def next_bus_arrivals():
    try:
        stop_id = int(input("\nEnter stop ID: "))
        limit = int(input("Number of arrivals to display: "))

        if stop_id <= 0 or limit <= 0:
            print("Stop ID and arrival limit must be positive.")
            return

        display_results(
            "UPCOMING BUS ARRIVALS",
            """
            SELECT *
            FROM public.app_next_arrivals(%s, %s);
            """,
            (stop_id, limit),
        )

    except ValueError:
        print("Please enter valid integer values.")


def trip_timeline():
    try:
        trip_id = int(input("\nEnter trip ID: "))

        if trip_id <= 0:
            print("Trip ID must be positive.")
            return

        display_results(
            "TRIP TIMELINE",
            """
            SELECT *
            FROM public.app_trip_timeline(%s);
            """,
            (trip_id,),
        )

    except ValueError:
        print("Please enter a valid trip ID.")


def service_alerts():
    display_results(
        "CURRENT SERVICE ALERTS",
        """
        SELECT *
        FROM public.app_service_alerts();
        """,
    )


def route_between_stops():
    try:
        from_stop = int(input("\nEnter starting stop ID: "))
        to_stop = int(input("Enter destination stop ID: "))

        if from_stop <= 0 or to_stop <= 0:
            print("Stop IDs must be positive.")
            return

        display_results(
            "AVAILABLE ROUTES",
            """
            SELECT *
            FROM public.app_route_between(%s, %s, %s);
            """,
            (from_stop, to_stop, 5),
        )

    except ValueError:
        print("Please enter valid integer stop IDs.")


# ---------------------------------------------------------
# NEW FEATURE 1: LIVE OPERATIONS MONITOR
# ---------------------------------------------------------

def live_operations_monitor():
    """
    Live operations dashboard.
    Reads current bus positions; does not advance simulation time.
    """

    try:
        interval = int(
            input("\nRefresh interval in seconds (default 5): ") or "5"
        )

        if interval < 1:
            print("Refresh interval must be at least 1 second.")
            return

    except ValueError:
        print("Please enter a valid number.")
        return

    print("\nLIVE OPERATIONS MONITOR STARTED")
    print("Press Ctrl+C to return to the menu.")
    print("This monitor reads the simulator; it does not advance simulation time.")
    print("Delay: Negative = Early | Positive = Late")

    try:
        while True:

            # Overall service summary
            display_results(
                "LIVE SERVICE SUMMARY",
                """
                WITH live AS (
                    SELECT *
                    FROM public.app_where_is_bus()
                )
                SELECT
                    COUNT(*) AS active_trips,

                    COUNT(*) FILTER (
                        WHERE delay_min < -1
                    ) AS early_trips,

                    COUNT(*) FILTER (
                        WHERE delay_min BETWEEN -1 AND 1
                    ) AS on_time_trips,

                    COUNT(*) FILTER (
                        WHERE delay_min > 1
                    ) AS delayed_trips,

                    ROUND(AVG(delay_min)::numeric, 2)
                        AS average_delay_min

                FROM live;
                """
            )

            # Current running trip details
            display_results(
                "LIVE SHUTTLE OPERATIONS",
                """
                WITH live AS (
                    SELECT *
                    FROM public.app_where_is_bus()
                )
                SELECT
                    b.trip_id AS trip,
                    b.route_code AS route,
                    b.vehicle_id AS vehicle,

                    concat(b.progress_pct::text, chr(37))
                        AS progress,

                    b.last_stop,
                    b.next_stop,

                    ROUND(b.speed_kmh::numeric, 1)
                        AS speed_kmh,

                    ROUND(b.delay_min::numeric, 1)
                        AS delay_min,

                    CASE
                        WHEN eta.minutes_away IS NULL
                            THEN 'N/A'
                        ELSE ROUND(
                            eta.minutes_away::numeric, 1
                        )::text || ' min'
                    END AS eta

                FROM live b

                LEFT JOIN LATERAL (
                    SELECT a.minutes_away
                    FROM public.stops s
                    CROSS JOIN LATERAL
                        public.app_next_arrivals(s.stop_id, 100) a
                    WHERE s.stop_name = b.next_stop
                      AND a.trip_id = b.trip_id
                    ORDER BY a.eta
                    LIMIT 1
                ) eta ON true

                ORDER BY b.route_code, b.trip_id;
                """
            )

            # Simulation clock status
            display_results(
                "SIMULATION STATUS",
                """
                SELECT
                    public.app_now() AS simulation_time,
                    public.app_speed() AS simulation_speed,
                    c.running AS clock_running
                FROM sim.clock c;
                """
            )

            print("\nDelay: Negative = Early | Positive = Late")
            print(f"\nNext refresh in {interval} seconds...")
            print("Press Ctrl+C to return to the menu.")

            time.sleep(interval)

    except KeyboardInterrupt:
        print("\n\nLive monitoring stopped.")


# ---------------------------------------------------------
# NEW FEATURE 2: TRACK A SPECIFIC TRIP
# ---------------------------------------------------------


def track_specific_trip():
    try:
        trip_id = int(input("\nEnter trip ID to track: "))

        if trip_id <= 0:
            print("Trip ID must be positive.")
            return

        # Verify that the trip exists.
        display_results(
            "SELECTED TRIP",
            """
            SELECT
                t.trip_id,
                r.route_code,
                r.route_name,
                t.vehicle_id,
                t.status,
                t.scheduled_start,
                t.actual_start,
                t.actual_end
            FROM public.trips t
            JOIN public.routes r USING (route_id)
            WHERE t.trip_id = %s;
            """,
            (trip_id,),
        )

        try:
            interval = int(input("\nRefresh interval in seconds (default 5): ") or "5")

            if interval < 1:
                print("Refresh interval must be at least 1 second.")
                return

        except ValueError:
            print("Invalid refresh interval.")
            return

        print("\nTRIP TRACKING STARTED")
        print("Press Ctrl+C to stop.")

        while True:
            display_results(
                f"TRIP {trip_id} - STOP-BY-STOP PROGRESS",
                """
                SELECT *
                FROM public.app_trip_timeline(%s);
                """,
                (trip_id,),
            )

            display_results(
                "TRIP STATUS AND GPS ACTIVITY",
                """
                SELECT
                    t.trip_id,
                    t.status,
                    t.actual_start,
                    t.actual_end,
                    f.gps_fixes,
                    f.fixes_matched_to_route,
                    f.stops_arrived,
                    f.stops_departed,
                    f.last_fix_at
                FROM public.trips t
                JOIN public.v_trip_flow f USING (trip_id)
                WHERE t.trip_id = %s;
                """,
                (trip_id,),
            )

            display_results(
                "SIMULATION TIME",
                """
                SELECT
                    public.app_now() AS simulation_time,
                    public.app_speed() AS simulation_speed;
                """,
            )

            print(f"\nRefreshing in {interval} seconds...")
            time.sleep(interval)

    except KeyboardInterrupt:
        print("\n\nTrip tracking stopped.")

    except ValueError:
        print("Please enter a valid trip ID.")


# ---------------------------------------------------------
# NEW FEATURE 3: COMPLETED TRIP REPORT
# ---------------------------------------------------------


def completed_trip_report():
    try:
        trip_id = int(input("\nEnter completed trip ID: "))

        if trip_id <= 0:
            print("Trip ID must be positive.")
            return

        # First verify that the trip exists and is completed.
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT status
                    FROM public.trips
                    WHERE trip_id = %s;
                    """,
                    (trip_id,),
                )
                result = cur.fetchone()

        if result is None:
            print(f"\nTrip {trip_id} does not exist.")
            return

        status = str(result[0])

        if status.lower() != "completed":
            print(f"\nTrip {trip_id} has status: {status}")
            print("A completed-trip performance report is not available yet.")
            print("Use option 3 (View trip timeline) to inspect its progress.")
            return

        # Completed trip summary
        display_results(
            "COMPLETED TRIP SUMMARY",
            """
            SELECT
                t.trip_id,
                r.route_code,
                r.route_name,
                t.vehicle_id,
                t.status,
                t.scheduled_start,
                t.actual_start,
                t.actual_end,
                COUNT(e.stop_sequence) AS total_stops,
                COUNT(e.actual_arrival) AS stops_arrived,
                COUNT(e.actual_departure) AS stops_departed,

                ROUND(
                    AVG(
                        EXTRACT(EPOCH FROM
                            (e.actual_arrival - e.scheduled_arrival)
                        ) / 60
                    ) FILTER (
                        WHERE e.actual_arrival IS NOT NULL
                    )::numeric,
                    2
                ) AS average_arrival_delay_min,

                ROUND(
                    MAX(
                        EXTRACT(EPOCH FROM
                            (e.actual_arrival - e.scheduled_arrival)
                        ) / 60
                    ) FILTER (
                        WHERE e.actual_arrival IS NOT NULL
                    )::numeric,
                    2
                ) AS maximum_arrival_delay_min

            FROM public.trips t
            JOIN public.routes r USING (route_id)
            LEFT JOIN public.trip_stop_event e
                ON e.trip_id = t.trip_id
            WHERE t.trip_id = %s
            GROUP BY
                t.trip_id, r.route_code, r.route_name,
                t.vehicle_id, t.status,
                t.scheduled_start, t.actual_start, t.actual_end;
            """,
            (trip_id,),
        )

        # Stop-by-stop performance
        display_results(
            "DETAILED STOP-BY-STOP PERFORMANCE",
            """
            SELECT
                e.stop_sequence,
                s.stop_name,
                e.scheduled_arrival,
                e.actual_arrival,

                ROUND(
                    EXTRACT(EPOCH FROM
                        (e.actual_arrival - e.scheduled_arrival)
                    )::numeric,
                    1
                ) AS arrival_delay_seconds,

                CASE
                    WHEN e.actual_arrival IS NULL THEN 'Not recorded'
                    WHEN e.actual_arrival < e.scheduled_arrival
                        THEN 'Early'
                    WHEN e.actual_arrival <=
                         e.scheduled_arrival + interval '5 minutes'
                        THEN 'On time'
                    ELSE 'Late'
                END AS arrival_status,

                NULLIF(
                    to_jsonb(e)->>'scheduled_departure', ''
                )::timestamp AS scheduled_departure,

                e.actual_departure,

                ROUND(
                    EXTRACT(EPOCH FROM (
                        e.actual_departure -
                        NULLIF(
                            to_jsonb(e)->>'scheduled_departure', ''
                        )::timestamp
                    ))::numeric,
                    1
                ) AS departure_delay_seconds

            FROM public.trip_stop_event e
            JOIN public.stops s USING (stop_id)
            WHERE e.trip_id = %s
            ORDER BY e.stop_sequence;
            """,
            (trip_id,),
        )

        # Data generation and GPS matching details
        display_results(
            "TRIP DATA FLOW",
            """
            SELECT *
            FROM public.v_trip_flow
            WHERE trip_id = %s;
            """,
            (trip_id,),
        )

    except ValueError:
        print("Please enter a valid trip ID.")

    except psycopg.Error as e:
        print("\nDatabase error:", e)


# ---------------------------------------------------------
# MAIN MENU
# ---------------------------------------------------------


def main():
    print("\n" + "=" * 60)
    print("          CAMPUS SHUTTLE OPERATIONS CONSOLE")
    print("=" * 60)

    print("\nConnecting to Campus Shuttle database...")

    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT public.app_now();")
                print("Connected successfully!")
                print("Simulation time:", cur.fetchone()[0])

    except psycopg.Error as e:
        print("\nCould not connect to the database:", e)
        return

    while True:
        print("\n" + "-" * 60)
        print("                       MAIN MENU")
        print("-" * 60)

        print("\nEXISTING RIDER FEATURES")
        print("1. Where is my bus?")
        print("2. Next bus arrivals")
        print("3. View trip timeline")
        print("4. View service alerts")
        print("5. Find route between stops")

        print("\nLIVE OPERATIONS AND ANALYSIS")
        print("6. Live operations monitor")
        print("7. Track a specific trip")
        print("8. Completed trip report")
        print("9. View simulation clock")

        print("\n0. Exit")

        choice = input("\nEnter your choice: ").strip()

        if choice == "1":
            where_is_my_bus()

        elif choice == "2":
            next_bus_arrivals()

        elif choice == "3":
            trip_timeline()

        elif choice == "4":
            service_alerts()

        elif choice == "5":
            route_between_stops()

        elif choice == "6":
            live_operations_monitor()

        elif choice == "7":
            track_specific_trip()

        elif choice == "8":
            completed_trip_report()

        elif choice == "9":
            get_simulation_status()

        elif choice == "0":
            print("\nThank you for using Campus Shuttle!")
            break

        else:
            print("\nInvalid choice. Please try again.")


if __name__ == "__main__":
    main()
