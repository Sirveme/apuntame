"""
Configuración de SQLAlchemy: engine + sesión + Base declarativa.
"""
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from sqlalchemy.pool import QueuePool

from app.config import settings


# Railway entrega DATABASE_URL con prefijo "postgres://" pero SQLAlchemy 2.x
# requiere "postgresql://". Normalizamos por seguridad.
db_url = settings.DATABASE_URL.replace("postgres://", "postgresql://", 1)


engine = create_engine(
    db_url,
    poolclass=QueuePool,
    pool_size=settings.DATABASE_POOL_SIZE,
    max_overflow=settings.DATABASE_MAX_OVERFLOW,
    pool_pre_ping=True,
    echo=settings.DEBUG,
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def get_db():
    """
    Dependencia FastAPI para inyectar sesión de BD.
    Uso en routers:

        @router.get("/...")
        def listar(db: Session = Depends(get_db)):
            ...
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
