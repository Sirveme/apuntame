-- =============================================================================
-- apuntame.online - Migración v1.1 → v1.2
-- =============================================================================
-- Fecha:       2026-05-09
-- Autor:       Duilio Restuccia / Perú Sistemas Pro E.I.R.L.
--
-- CAMBIOS:
-- 1. Auth con documento de identidad (DNI/CI/CC/RUT/CURP/DPI/Pasaporte) en
--    lugar de email. Soporte internacional (Perú, Bolivia, Ecuador, Colombia,
--    Chile, México, etc.).
-- 2. Clave inicial = documento_numero (hasheado con Argon2). Flag
--    debe_cambiar_clave fuerza cambio en primer acceso.
-- 3. Timezone del usuario guardada en su perfil, para mostrar todas las fechas
--    en su hora local.
-- 4. Timezone del asistente capturada del navegador en el registro.
--
-- IMPORTANTE: Argon2 NO se genera en SQL. Cuando insertes usuarios manualmente,
-- primero genera el hash en Python (con la misma librería del proyecto) y luego
-- haces INSERT con el hash ya calculado. Mismo patrón que CCPL.
-- =============================================================================


-- =============================================================================
-- 1. NUEVO ENUM: tipos de documento internacional
-- =============================================================================

CREATE TYPE tipo_documento AS ENUM (
    'DNI',        -- Perú, Argentina, España
    'CE',         -- Carné de Extranjería (Perú), Cédula de Extranjería (Colombia)
    'CI',         -- Bolivia, Ecuador, Paraguay, Uruguay
    'CC',         -- Cédula de Ciudadanía (Colombia), Venezuela
    'RUT',        -- Chile
    'CURP',       -- México
    'INE',        -- México (credencial de elector)
    'DPI',        -- Guatemala
    'RNE',        -- Brasil (extranjeros)
    'PASAPORTE',  -- internacional
    'OTRO'        -- caso por caso
);


-- =============================================================================
-- 2. MODIFICAR TABLA `usuarios` — login por documento, no email
-- =============================================================================

-- 2.1. Agregar columnas nuevas
ALTER TABLE usuarios
    ADD COLUMN IF NOT EXISTS documento_tipo tipo_documento,
    ADD COLUMN IF NOT EXISTS documento_numero VARCHAR(20),
    ADD COLUMN IF NOT EXISTS pais_documento VARCHAR(2) DEFAULT 'PE',
    ADD COLUMN IF NOT EXISTS debe_cambiar_clave BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50) NOT NULL DEFAULT 'America/Lima',
    ADD COLUMN IF NOT EXISTS idioma VARCHAR(5) NOT NULL DEFAULT 'es',
    ADD COLUMN IF NOT EXISTS ultimo_cambio_clave TIMESTAMPTZ;

-- 2.2. El email ya no es obligatorio (queda como dato opcional)
ALTER TABLE usuarios ALTER COLUMN email DROP NOT NULL;

-- 2.3. Migrar el DNI antiguo (si existe data) hacia el nuevo modelo
-- Asume que los DNIs viejos eran peruanos
UPDATE usuarios
SET documento_tipo = 'DNI',
    documento_numero = dni,
    pais_documento = 'PE'
WHERE dni IS NOT NULL
  AND documento_tipo IS NULL;

-- 2.4. Constraints e índices
-- Único por tipo+número+organización (un mismo DNI puede aparecer en distintas orgs)
CREATE UNIQUE INDEX IF NOT EXISTS uq_usuarios_documento_org
    ON usuarios(organizacion_id, documento_tipo, documento_numero)
    WHERE documento_numero IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_usuarios_documento
    ON usuarios(documento_tipo, documento_numero);

-- 2.5. Comentarios
COMMENT ON COLUMN usuarios.documento_tipo IS 'Tipo de documento: DNI (Perú/Arg/Esp), CI (Bo/Ec), CC (Col/Ven), RUT (Chi), CURP (Mex), etc.';
COMMENT ON COLUMN usuarios.documento_numero IS 'Número del documento. Se usa como login junto con documento_tipo.';
COMMENT ON COLUMN usuarios.debe_cambiar_clave IS 'TRUE = en el próximo login se fuerza cambio de clave. Inicialmente TRUE para usuarios nuevos.';
COMMENT ON COLUMN usuarios.timezone IS 'Timezone IANA del usuario (America/Lima, America/Bogota, Europe/Madrid). Se usa para mostrar fechas en su hora local.';
COMMENT ON COLUMN usuarios.idioma IS 'Idioma preferido: es, en, pt';


-- =============================================================================
-- 3. MODIFICAR TABLA `asistentes` — documento internacional + timezone navegador
-- =============================================================================

ALTER TABLE asistentes
    ADD COLUMN IF NOT EXISTS documento_tipo tipo_documento NOT NULL DEFAULT 'DNI',
    ADD COLUMN IF NOT EXISTS documento_numero VARCHAR(20),
    ADD COLUMN IF NOT EXISTS pais_documento VARCHAR(2) DEFAULT 'PE',
    ADD COLUMN IF NOT EXISTS timezone VARCHAR(50),       -- detectada del navegador
    ADD COLUMN IF NOT EXISTS idioma VARCHAR(5) DEFAULT 'es';

-- Migrar DNIs viejos al nuevo campo
UPDATE asistentes
SET documento_numero = dni,
    documento_tipo = 'DNI',
    pais_documento = 'PE'
WHERE dni IS NOT NULL AND documento_numero IS NULL;

-- Nuevo UNIQUE: documento debe ser único por evento (sin importar tipo, el numero
-- + país suele bastar; pero incluimos tipo para máxima precisión)
ALTER TABLE asistentes DROP CONSTRAINT IF EXISTS asistentes_evento_id_dni_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_asistentes_evento_documento
    ON asistentes(evento_id, documento_tipo, documento_numero)
    WHERE documento_numero IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_asistentes_documento
    ON asistentes(documento_tipo, documento_numero);

COMMENT ON COLUMN asistentes.timezone IS 'Timezone IANA capturada del navegador con Intl.DateTimeFormat().resolvedOptions().timeZone';


-- =============================================================================
-- 4. MODIFICAR TABLA `ponentes` — documento internacional
-- =============================================================================

ALTER TABLE ponentes
    ADD COLUMN IF NOT EXISTS documento_tipo tipo_documento,
    ADD COLUMN IF NOT EXISTS documento_numero VARCHAR(20),
    ADD COLUMN IF NOT EXISTS pais_documento VARCHAR(2) DEFAULT 'PE';

CREATE INDEX IF NOT EXISTS idx_ponentes_documento
    ON ponentes(documento_tipo, documento_numero);


-- =============================================================================
-- 5. MODIFICAR `padron` y `certificados` para usar documento_tipo
-- =============================================================================

ALTER TABLE votacion_padron
    ADD COLUMN IF NOT EXISTS documento_tipo tipo_documento NOT NULL DEFAULT 'DNI',
    ADD COLUMN IF NOT EXISTS documento_numero VARCHAR(20),
    ADD COLUMN IF NOT EXISTS pais_documento VARCHAR(2) DEFAULT 'PE';

-- Migrar DNIs viejos
UPDATE votacion_padron
SET documento_numero = dni
WHERE dni IS NOT NULL AND documento_numero IS NULL;

ALTER TABLE certificados_emitidos
    ADD COLUMN IF NOT EXISTS documento_tipo tipo_documento DEFAULT 'DNI',
    ADD COLUMN IF NOT EXISTS documento_numero VARCHAR(20);

-- Migrar
UPDATE certificados_emitidos
SET documento_numero = documento_identidad
WHERE documento_identidad IS NOT NULL AND documento_numero IS NULL;


-- =============================================================================
-- 6. TABLA `intentos_login` — auditoría y rate-limit
-- =============================================================================
-- Registra cada intento (exitoso o fallido) para detectar ataques y bloquear.
-- =============================================================================

CREATE TABLE IF NOT EXISTS intentos_login (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    usuario_id UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    documento_tipo tipo_documento,
    documento_numero VARCHAR(20),
    exitoso BOOLEAN NOT NULL,
    motivo_fallo VARCHAR(100),                          -- 'documento_inexistente', 'clave_incorrecta', 'cuenta_bloqueada'
    ip_address INET,
    user_agent TEXT,
    intentado_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_intentos_documento
    ON intentos_login(documento_tipo, documento_numero, intentado_at DESC);
CREATE INDEX IF NOT EXISTS idx_intentos_ip
    ON intentos_login(ip_address, intentado_at DESC);


-- =============================================================================
-- 7. FUNCIÓN UTIL: convertir UTC a timezone del usuario
-- =============================================================================
-- Para usar desde queries cuando se necesita la fecha local sin pasar por Python.
-- Ejemplo:
--   SELECT id, hora_local(check_in_at, 'America/Bogota') FROM asistentes;
-- =============================================================================

CREATE OR REPLACE FUNCTION hora_local(
    fecha_utc TIMESTAMPTZ,
    tz VARCHAR(50)
) RETURNS TIMESTAMP AS $$
BEGIN
    RETURN fecha_utc AT TIME ZONE tz;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- =============================================================================
-- 8. VISTA: usuarios con info de seguridad
-- =============================================================================
-- Útil para el panel de admin: ver últimos accesos, intentos fallidos, etc.
-- =============================================================================

CREATE OR REPLACE VIEW v_usuarios_seguridad AS
SELECT
    u.id,
    u.organizacion_id,
    u.documento_tipo,
    u.documento_numero,
    u.nombres,
    u.apellidos,
    u.email,
    u.rol,
    u.activo,
    u.debe_cambiar_clave,
    u.timezone,
    u.ultimo_login,
    u.ultimo_cambio_clave,
    (SELECT COUNT(*) FROM intentos_login il
        WHERE il.usuario_id = u.id
        AND il.exitoso = FALSE
        AND il.intentado_at > NOW() - INTERVAL '1 hour'
    ) AS intentos_fallidos_ultima_hora
FROM usuarios u;


-- =============================================================================
-- FIN MIGRACIÓN v1.2
-- =============================================================================
-- Próximos pasos en el código (NO en SQL):
-- 1. app/utils/fechas.py     → helpers de timezone
-- 2. app/services/auth.py    → flujo login con doc + cambio_clave forzado
-- 3. Filtro Jinja2 hora_local → convertir UTC a timezone del usuario al renderizar
-- 4. JS en registro → capturar Intl.DateTimeFormat().resolvedOptions().timeZone
-- =============================================================================