"""
Aplicación FastAPI principal — apuntame.online

Por ahora solo expone /health y un landing temporal en /.
Los routers se irán sumando conforme avanzamos.
"""
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from contextlib import asynccontextmanager
from sqlalchemy import text

from app.config import settings
from app.database import engine


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    print(f"🚀 apuntame.online v{settings.VERSION} arrancando en entorno: {settings.ENV}")
    # Verificar conexión a BD
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        print("✅ Conexión a PostgreSQL exitosa")
    except Exception as e:
        print(f"❌ Error de conexión a BD: {e}")
    yield
    # Shutdown
    print("👋 apuntame.online detenido")


app = FastAPI(
    title="apuntame.online",
    description="Plataforma de Participación, Eventos y Votaciones con IA",
    version=settings.VERSION,
    lifespan=lifespan,
)

# Static files (cuando agreguemos css/js/img)
# Se monta solo si la carpeta existe (evita error en desarrollo temprano)
import os
if os.path.isdir("app/static"):
    app.mount("/static", StaticFiles(directory="app/static"), name="static")


# =============================================================================
# Endpoints temporales (se reemplazan cuando agreguemos routers reales)
# =============================================================================

@app.get("/health")
def health():
    """Endpoint de salud para Railway healthcheck."""
    try:
        with engine.connect() as conn:
            result = conn.execute(text("SELECT COUNT(*) FROM organizaciones"))
            org_count = result.scalar()
        return {
            "status": "ok",
            "version": settings.VERSION,
            "env": settings.ENV,
            "db": "connected",
            "organizaciones": org_count,
        }
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"status": "error", "db": "disconnected", "error": str(e)},
        )


@app.get("/", response_class=HTMLResponse)
def landing_temporal():
    """Landing temporal mientras desarrollamos la real."""
    return """
    <!DOCTYPE html>
    <html lang="es">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>apuntame.online</title>
        <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: linear-gradient(135deg, #1e40af 0%, #3b82f6 100%);
                min-height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
                color: white;
                padding: 2rem;
            }
            .container {
                max-width: 600px;
                text-align: center;
            }
            h1 { font-size: 3.5rem; margin-bottom: 1rem; font-weight: 700; }
            .tagline {
                font-size: 1.25rem;
                margin-bottom: 2rem;
                opacity: 0.9;
            }
            .status {
                background: rgba(255, 255, 255, 0.15);
                padding: 1rem 2rem;
                border-radius: 8px;
                display: inline-block;
                backdrop-filter: blur(10px);
            }
            .footer {
                margin-top: 3rem;
                font-size: 0.875rem;
                opacity: 0.7;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>apúntame</h1>
            <p class="tagline">Plataforma de Participación, Eventos y Votaciones con IA</p>
            <div class="status">
                ✅ Sistema operativo · Próximamente disponible
            </div>
            <p class="footer">Perú Sistemas Pro E.I.R.L. · Iquitos, Loreto</p>
        </div>
    </body>
    </html>
    """
