import psycopg
from getpass import getpass

DB_CONFIG = {
    "host": "172.29.160.1",
    "port": 5432,
    "dbname": "Campus Shuttle 1.0",
    "user": "postgres",
}


def main():
    password = getpass("Enter PostgreSQL password: ")

    try:
        with psycopg.connect(**DB_CONFIG, password=password) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT
                        current_database(),
                        version(),
                        public.app_now(),
                        public.app_speed();
                """)

                result = cur.fetchone()

                print("\nDatabase connection successful!")
                print("Database:", result[0])
                print("PostgreSQL:", result[1].split(",")[0])
                print("Application time:", result[2])
                print("Simulation speed:", result[3])

    except psycopg.Error as e:
        print("\nDatabase connection failed!")
        print(e)


if __name__ == "__main__":
    main()
