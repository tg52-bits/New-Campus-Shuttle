
from db import get_connection
import psycopg


def display_results(title, query, params=None):
    """Execute a query and display its results in a table."""

    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params or ())
                rows = cur.fetchall()

                print("\n" + "=" * 90)
                print(title.center(90))
                print("=" * 90)

                if not rows:
                    print("\nNo records found.")
                    return

                columns = [desc.name for desc in cur.description]

                # Convert values into printable strings.
                data = [
                    ["NULL" if value is None else str(value) for value in row]
                    for row in rows
                ]

                widths = [
                    max(len(columns[i]), *(len(row[i]) for row in data))
                    for i in range(len(columns))
                ]

                header = " | ".join(
                    columns[i].ljust(widths[i])
                    for i in range(len(columns))
                )

                print(header)
                print("-" * len(header))

                for row in data:
                    print(" | ".join(
                        row[i].ljust(widths[i])
                        for i in range(len(columns))
                    ))

                print(f"\nTotal records: {len(rows)}")

    except psycopg.Error as e:
        print("\nDatabase error:", e)


def where_is_my_bus():
    route = input(
        "\nEnter route code (leave blank for all routes): "
    ).strip()

    display_results(
        "LIVE BUS LOCATIONS",
        """
        SELECT *
        FROM public.app_where_is_bus(%s);
        """,
        (route if route else None,)
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
            (stop_id, limit)
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
            (trip_id,)
        )

    except ValueError:
        print("Please enter a valid trip ID.")


def service_alerts():
    display_results(
        "CURRENT SERVICE ALERTS",
        """
        SELECT *
        FROM public.app_service_alerts();
        """
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
            (from_stop, to_stop, 5)
        )

    except ValueError:
        print("Please enter valid integer stop IDs.")


def main():
    print("\n" + "=" * 50)
    print("       CAMPUS SHUTTLE - RIDER CONSOLE")
    print("=" * 50)

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
        print("\n" + "-" * 50)
        print("                 MAIN MENU")
        print("-" * 50)

        print("1. Where is my bus?")
        print("2. Next bus arrivals")
        print("3. View trip timeline")
        print("4. View service alerts")
        print("5. Find route between stops")
        print("0. Exit")

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

        elif choice == "0":
            print("\nThank you for using Campus Shuttle!")
            break

        else:
            print("\nInvalid choice. Please try again.")


if __name__ == "__main__":
    main()
