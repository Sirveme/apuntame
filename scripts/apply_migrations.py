"""
Aplicador idempotente de migraciones SQL.

Lee db/migrations/*.sql en orden alfabético, aplica solo los pendientes
(los que no están registrados en la tabla schema_migrations).

Se ejecuta automáticamente en cada boot de Railway gracias al CMD del Dockerfile.

Uso manual:
    python scripts/apply_migrations.py
"""
import os
import sys
from pathlib import Path

import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT


DATABASE_URL = os.environ.get("DATABASE_URL", "")
# Normalizar postgres:// → postgresql:// (Railway entrega el primero)
if DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)

PROJECT_ROOT = Path(__file__).parent.parent
MIGRATIONS_DIR = PROJECT_ROOT / "db" / "migrations"


def ensure_migrations_table(conn):
    """Crea la tabla schema_migrations si no existe."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                id SERIAL PRIMARY KEY,
                filename VARCHAR(200) UNIQUE NOT NULL,
                applied_at TIMESTAMPTZ DEFAULT NOW()
            );
        """)


def get_applied(conn):
    """Retorna el conjunto de migraciones ya aplicadas."""
    with conn.cursor() as cur:
        cur.execute("SELECT filename FROM schema_migrations")
        return {row[0] for row in cur.fetchall()}


def apply_migration(conn, filepath: Path):
    """Aplica una migración y la registra como aplicada."""
    print(f"  → aplicando {filepath.name}")
    with open(filepath, encoding="utf-8") as f:
        sql = f.read()
    with conn.cursor() as cur:
        cur.execute(sql)
        cur.execute(
            "INSERT INTO schema_migrations (filename) VALUES (%s)",
            (filepath.name,),
        )


def main():
    if not DATABASE_URL:
        print("❌ DATABASE_URL no definida")
        sys.exit(1)

    if not MIGRATIONS_DIR.exists():
        print(f"⚠️  Carpeta {MIGRATIONS_DIR} no existe — sin migraciones pendientes")
        return

    print(f"🔌 Conectando a la base de datos...")
    conn = psycopg2.connect(DATABASE_URL)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)

    ensure_migrations_table(conn)
    applied = get_applied(conn)

    files = sorted(MIGRATIONS_DIR.glob("*.sql"))
    pendientes = [f for f in files if f.name not in applied]

    if not pendientes:
        print(f"✅ Sin migraciones pendientes ({len(applied)} ya aplicadas)")
        conn.close()
        return

    print(f"📦 {len(pendientes)} migración(es) pendiente(s):")
    for f in pendientes:
        try:
            apply_migration(conn, f)
        except Exception as e:
            print(f"❌ Error en {f.name}: {e}")
            conn.close()
            sys.exit(1)

    print(f"✅ {len(pendientes)} migración(es) aplicada(s) exitosamente")
    conn.close()


if __name__ == "__main__":
    main()
