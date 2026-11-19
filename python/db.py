
import os
import getpass
import psycopg

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "172.29.160.1"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "Campus Shuttle 1.0"),
    "user": os.getenv("DB_USER", "postgres"),
}

_password = None


def get_connection():
    global _password

    if _password is None:
        _password = os.getenv("DB_PASSWORD")

        if _password is None:
            _password = getpass.getpass("PostgreSQL password: ")

    return psycopg.connect(
        **DB_CONFIG,
        password=_password
    )


def test_connection():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    SELECT
                        current_database(),
                        public.app_now(),
                        public.app_speed();
                """)

                db_name, app_time, speed = cur.fetchone()

                print("\nDatabase connection successful!")
                print("Database:", db_name)
                print("Application time:", app_time)
                print("Simulation speed:", speed)

        return True

    except psycopg.Error as e:
        print("\nDatabase connection failed:", e)
        return False
