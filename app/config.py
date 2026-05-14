"""
Configuración global desde variables de entorno.
Railway inyecta DATABASE_URL automáticamente cuando hay un servicio PostgreSQL vinculado.
"""
from pydantic_settings import BaseSettings, SettingsConfigDict
from functools import lru_cache


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    # App
    VERSION: str = "1.0.0"
    ENV: str = "development"
    DEBUG: bool = True
    SECRET_KEY: str = "dev-secret-change-in-production"
    BASE_URL: str = "http://localhost:8000"

    # Base de datos
    DATABASE_URL: str
    DATABASE_POOL_SIZE: int = 5
    DATABASE_MAX_OVERFLOW: int = 10

    # JWT
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_HOURS: int = 8

    # Timezone
    TZ_DEFAULT: str = "America/Lima"
    IDIOMA_DEFAULT: str = "es"

    # IA (opcionales por ahora)
    ANTHROPIC_API_KEY: str = ""
    OPENAI_API_KEY: str = ""

    # SMTP (opcional por ahora)
    SMTP_HOST: str = ""
    SMTP_PORT: int = 587
    SMTP_USER: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM: str = "no-reply@apuntame.online"

    # Facturalo
    FACTURALO_API_URL: str = "https://api.facturalo.pro"
    FACTURALO_API_KEY: str = ""
    FACTURALO_API_SECRET: str = ""


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
