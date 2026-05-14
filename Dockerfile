FROM python:3.12-slim

WORKDIR /app

# Dependencias del sistema
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev gcc \
    && rm -rf /var/lib/apt/lists/*

# Dependencias Python
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Código
COPY . .

# Railway provee PORT dinámicamente
EXPOSE 8000

# Boot: aplicar migraciones pendientes + arrancar gunicorn
CMD python scripts/apply_migrations.py && \
    gunicorn app.main:app \
    -w 2 -k uvicorn.workers.UvicornWorker \
    --bind 0.0.0.0:${PORT:-8000} \
    --access-logfile - \
    --error-logfile - \
    --timeout 120
