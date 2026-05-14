# apuntame.online

**Plataforma de Participación, Eventos y Votaciones con IA**

Perú Sistemas Pro E.I.R.L. · Iquitos, Loreto

---

## Stack

- **Backend:** FastAPI + SQLAlchemy + PostgreSQL
- **Frontend:** Jinja2 + HTMX + Vanilla JS (sin frameworks)
- **Deploy:** Railway
- **IA:** Claude API (Anthropic) + Whisper (OpenAI)

---

## Estructura

```
apuntame/
├── app/                  # código de la aplicación
│   ├── main.py
│   ├── config.py
│   ├── database.py
│   └── ...
├── db/migrations/        # migraciones SQL (v1.sql, v1.1, v1.2, ...)
├── scripts/              # utilidades CLI
└── docs/zClaude/         # prompts para Claude Code
```

---

## Desarrollo local

```bash
# 1. Crear entorno virtual
python -m venv venv
source venv/bin/activate           # Linux/Mac
venv\Scripts\activate              # Windows

# 2. Instalar dependencias
pip install -r requirements.txt

# 3. Configurar variables
cp .env.example .env
# Editar .env con la DATABASE_URL real

# 4. Aplicar migraciones (solo la primera vez)
python scripts/apply_migrations.py

# 5. Arrancar el servidor
uvicorn app.main:app --reload
```

App disponible en `http://localhost:8000`.

---

## Deploy en Railway

Cada `git push` a `main` dispara un nuevo deploy automáticamente.

El `Dockerfile` está configurado para:
1. Instalar dependencias
2. Aplicar migraciones pendientes
3. Arrancar `gunicorn` con workers `uvicorn`

---

## Convenciones

- Nombres de archivos: `snake_case.py`
- Nombres de clases: `PascalCase`
- Nombres de funciones/variables: `snake_case`
- Endpoints en español (`/registro`, `/preguntas`, `/programa`)
- Comentarios en español
- Sin curl, sin Alembic, sin frameworks CSS/JS
- Queries vía PGAdmin o scripts Python
