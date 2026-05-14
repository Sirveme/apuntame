-- =============================================================================
-- apuntame.online - Migración v1.0 → v1.1
-- =============================================================================
-- Fecha:       2026-05-09
-- Autor:       Duilio Restuccia / Perú Sistemas Pro E.I.R.L.
--
-- CAMBIOS:
-- 1. Diferenciación comercial: campo `producto` en eventos (congreso|asamblea|mixto)
-- 2. Subtipos granulares: asamblea_ordinaria, jga, comicios, etc.
-- 3. Tablas de actas automáticas con IA (preparadas, feature se construye en junio)
-- 4. Vínculo votaciones ↔ actas (para asambleas con votos en orden del día)
--
-- IMPORTANTE: Esta migración NO construye la feature de actas. Solo prepara la
-- estructura de datos. La lógica de generación con IA, revisión y firma se
-- desarrolla en apuntame Asamblea v1 (junio 2026).
--
-- APLICAR EN ORDEN. Cada bloque es idempotente con IF NOT EXISTS donde aplica.
-- =============================================================================


-- =============================================================================
-- 1. NUEVOS TIPOS ENUMERADOS
-- =============================================================================

-- Producto comercial (determina qué módulos se ofrecen por defecto)
CREATE TYPE producto_apuntame AS ENUM ('congreso', 'asamblea', 'mixto');

-- Subtipo granular del evento (para actas, certificados, lenguaje del UI)
CREATE TYPE subtipo_evento AS ENUM (
    -- Productos congreso
    'congreso',
    'simposio',
    'jornada',
    'seminario',
    'taller',
    'capacitacion',
    'webinar',
    'feria',

    -- Productos asamblea
    'asamblea_ordinaria',
    'asamblea_extraordinaria',
    'junta_general_accionistas',
    'sesion_directiva',
    'sesion_comite',

    -- Procesos electorales
    'eleccion_junta_directiva',
    'eleccion_decano',
    'eleccion_delegados',
    'comicios_internos',
    'plebiscito',
    'referendum_interno',

    -- Otros
    'audiencia_publica',
    'cabildo',
    'presupuesto_participativo',
    'encuesta',
    'mixto'
);

-- Estado del acta (flujo borrador IA → revisión → aprobación → firma)
CREATE TYPE estado_acta AS ENUM (
    'pendiente_audio',          -- aún no se ha procesado el audio
    'transcribiendo',           -- Whisper trabajando
    'generando_borrador',       -- Claude generando estructura
    'borrador_ia',              -- borrador listo para revisión humana
    'en_revision',              -- secretario está editando
    'aprobada',                 -- aprobada por secretario, lista para firma
    'firmada',                  -- firmada digitalmente, inmutable
    'observada',                -- requiere correcciones
    'anulada'                   -- invalidada (con razón)
);


-- =============================================================================
-- 2. MODIFICAR TABLA `eventos` — agregar producto y subtipo
-- =============================================================================

ALTER TABLE eventos
    ADD COLUMN IF NOT EXISTS producto producto_apuntame NOT NULL DEFAULT 'congreso',
    ADD COLUMN IF NOT EXISTS subtipo subtipo_evento NOT NULL DEFAULT 'congreso',
    ADD COLUMN IF NOT EXISTS requiere_acta BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS numero_correlativo_acta VARCHAR(50);  -- formato libre por org

CREATE INDEX IF NOT EXISTS idx_eventos_producto ON eventos(producto);
CREATE INDEX IF NOT EXISTS idx_eventos_subtipo  ON eventos(subtipo);

-- Comentarios para autodocumentación
COMMENT ON COLUMN eventos.producto IS 'Producto comercial: congreso (programa+ponentes+preguntas), asamblea (padron+votacion+actas), mixto (ambos)';
COMMENT ON COLUMN eventos.subtipo IS 'Subtipo legal/operativo: define lenguaje del UI, estructura del acta, plantillas de certificados';
COMMENT ON COLUMN eventos.requiere_acta IS 'TRUE si el evento debe generar acta automatica (asambleas, JGA, sesiones directivas)';


-- =============================================================================
-- 3. TABLA `actas_automaticas`
-- =============================================================================
-- Estructura preparada para soportar el flujo completo:
-- audio → transcripción (Whisper) → borrador IA (Claude) → revisión → aprobación → firma
-- =============================================================================

CREATE TABLE IF NOT EXISTS actas_automaticas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    transcripcion_id UUID REFERENCES transcripciones(id) ON DELETE SET NULL,

    -- Identificación legal del acta
    numero_acta VARCHAR(50) NOT NULL,                          -- 'CCPL-ASAM-2026-001'
    titulo VARCHAR(300) NOT NULL,                              -- 'Asamblea Ordinaria CCPL - Mayo 2026'

    -- Cabecera del acta (datos del momento de la sesión)
    fecha_sesion DATE NOT NULL,
    hora_inicio TIMESTAMPTZ NOT NULL,
    hora_fin TIMESTAMPTZ,
    lugar TEXT NOT NULL,
    tipo_sesion subtipo_evento NOT NULL,                       -- ordinaria, extraordinaria, JGA

    -- Quórum
    padron_total INTEGER,
    asistentes_registrados INTEGER,
    quorum_minimo INTEGER,
    quorum_alcanzado BOOLEAN,
    quorum_segunda_convocatoria BOOLEAN DEFAULT FALSE,

    -- Mesa directiva (quiénes presidieron)
    presidida_por VARCHAR(200),                                -- Nombre del decano/presidente
    secretario_acta VARCHAR(200),                              -- Nombre del secretario

    -- =========================================================================
    -- CONTENIDO ESTRUCTURADO GENERADO POR IA (todos en JSONB para flexibilidad)
    -- =========================================================================

    -- Orden del día: [{numero: 1, tema: "...", expositor: "...", duracion_min: 15}, ...]
    orden_del_dia JSONB DEFAULT '[]'::jsonb,

    -- Intervenciones: [{punto: 1, persona: "Juan Perez", dni: "12345678",
    --                  tema: "...", resumen_intervencion: "...", timestamp: "00:23:45"}, ...]
    intervenciones JSONB DEFAULT '[]'::jsonb,

    -- Acuerdos: [{numero: 1, punto_orden: 2, texto: "Se aprueba...",
    --            votacion_id: uuid, votos_favor: 35, votos_contra: 12,
    --            abstenciones: 3, resultado: "aprobado"}, ...]
    acuerdos JSONB DEFAULT '[]'::jsonb,

    -- Asuntos varios planteados al final
    asuntos_varios JSONB DEFAULT '[]'::jsonb,

    -- Observaciones del secretario (campo libre)
    observaciones TEXT,

    -- Resumen ejecutivo (1-2 párrafos para difusión rápida)
    resumen_ejecutivo TEXT,

    -- =========================================================================
    -- METADATA DE PROCESAMIENTO IA
    -- =========================================================================

    modelo_transcripcion VARCHAR(50),                          -- 'whisper-large-v3', 'deepgram-nova-2'
    modelo_acta VARCHAR(50),                                   -- 'claude-sonnet-4-7'
    tokens_input INTEGER,
    tokens_output INTEGER,
    costo_usd NUMERIC(8, 4),
    duracion_audio_segundos INTEGER,

    -- =========================================================================
    -- ESTADO Y FLUJO DE APROBACIÓN
    -- =========================================================================

    estado estado_acta NOT NULL DEFAULT 'pendiente_audio',
    error_mensaje TEXT,

    -- Generación
    generada_at TIMESTAMPTZ,

    -- Revisión (puede haber varias iteraciones, ver tabla actas_revisiones)
    revisada_por UUID REFERENCES usuarios(id),
    revisada_at TIMESTAMPTZ,

    -- Aprobación final
    aprobada_por UUID REFERENCES usuarios(id),
    aprobada_at TIMESTAMPTZ,

    -- Firma digital del secretario (con certificado o codigo verificable)
    firmada_por UUID REFERENCES usuarios(id),
    firmada_at TIMESTAMPTZ,
    firma_metodo VARCHAR(30),                                  -- 'certificado_digital', 'codigo_verificable'
    firma_certificado_huella VARCHAR(128),                     -- huella del certificado si aplica

    -- Hash de integridad: SHA-256 del contenido completo al momento de firmar
    -- Si alguien edita el acta después de firmada, el hash cambia y se detecta
    hash_integridad VARCHAR(64),

    -- =========================================================================
    -- ARCHIVOS GENERADOS
    -- =========================================================================

    pdf_url TEXT,
    pdf_size_bytes BIGINT,
    docx_url TEXT,                                             -- versión Word para edición posterior

    -- =========================================================================
    -- AUDITORÍA
    -- =========================================================================

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(evento_id, numero_acta)
);

CREATE INDEX IF NOT EXISTS idx_actas_evento     ON actas_automaticas(evento_id);
CREATE INDEX IF NOT EXISTS idx_actas_estado     ON actas_automaticas(estado);
CREATE INDEX IF NOT EXISTS idx_actas_numero     ON actas_automaticas(numero_acta);
CREATE INDEX IF NOT EXISTS idx_actas_fecha      ON actas_automaticas(fecha_sesion DESC);

COMMENT ON TABLE actas_automaticas IS 'Actas de sesión generadas automáticamente con IA. Feature implementada en apuntame Asamblea v1 (junio 2026)';
COMMENT ON COLUMN actas_automaticas.hash_integridad IS 'SHA-256 del contenido firmado. Detecta manipulación post-firma.';


-- =============================================================================
-- 4. TABLA `actas_revisiones` — historial de versiones del acta
-- =============================================================================
-- Cada vez que el secretario edita el borrador IA, se guarda la versión anterior.
-- Permite auditar qué cambió respecto al borrador original generado por IA.
-- Útil legalmente: el acta firmada puede compararse con el borrador IA crudo.
-- =============================================================================

CREATE TABLE IF NOT EXISTS actas_revisiones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    acta_id UUID NOT NULL REFERENCES actas_automaticas(id) ON DELETE CASCADE,
    version INTEGER NOT NULL,                                  -- 1, 2, 3...

    -- Snapshot del contenido en ese momento
    snapshot_contenido JSONB NOT NULL,                         -- copia completa de los JSONB del acta

    -- Qué cambió (resumen para el log)
    cambios_resumen TEXT,
    campos_modificados TEXT[],                                 -- ['intervenciones', 'acuerdos']

    -- Quién y cuándo
    editado_por UUID REFERENCES usuarios(id),
    editado_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Comentario opcional del editor
    comentario TEXT,

    UNIQUE(acta_id, version)
);

CREATE INDEX IF NOT EXISTS idx_revisiones_acta ON actas_revisiones(acta_id, version DESC);


-- =============================================================================
-- 5. MODIFICAR TABLA `votaciones` — vincular con acta y orden del día
-- =============================================================================
-- En una asamblea, cada votación corresponde a un punto del orden del día.
-- El acta debe poder referenciar cada votación con su punto correspondiente.
-- =============================================================================

ALTER TABLE votaciones
    ADD COLUMN IF NOT EXISTS acta_id UUID REFERENCES actas_automaticas(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS punto_orden_dia INTEGER,
    ADD COLUMN IF NOT EXISTS texto_acuerdo TEXT;                -- texto literal del acuerdo aprobado

CREATE INDEX IF NOT EXISTS idx_votaciones_acta ON votaciones(acta_id);

COMMENT ON COLUMN votaciones.punto_orden_dia IS 'Numero del punto del orden del día al que corresponde esta votación';
COMMENT ON COLUMN votaciones.texto_acuerdo IS 'Texto literal del acuerdo sometido a votación, aparece en el acta';


-- =============================================================================
-- 6. MODIFICAR TABLA `eventos` — campo producto controla módulos por defecto
-- =============================================================================
-- Configuración por defecto al crear un evento, según el producto:
--
-- producto = 'congreso':
--   programa, registro, preguntas, materiales, certificados, resumenes_ia
--
-- producto = 'asamblea':
--   registro (con padrón), votacion, actas (cuando esté lista), certificados
--
-- producto = 'mixto':
--   todos los módulos disponibles
-- =============================================================================

-- Función helper para activar módulos por defecto al crear un evento
CREATE OR REPLACE FUNCTION activar_modulos_por_defecto()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.producto = 'congreso' THEN
        INSERT INTO evento_modulos (evento_id, modulo, activo)
        VALUES
            (NEW.id, 'programa', TRUE),
            (NEW.id, 'registro', TRUE),
            (NEW.id, 'preguntas', TRUE),
            (NEW.id, 'materiales', TRUE),
            (NEW.id, 'certificados', TRUE),
            (NEW.id, 'resumenes_ia', TRUE),
            (NEW.id, 'proyector', TRUE)
        ON CONFLICT (evento_id, modulo) DO NOTHING;

    ELSIF NEW.producto = 'asamblea' THEN
        INSERT INTO evento_modulos (evento_id, modulo, activo)
        VALUES
            (NEW.id, 'registro', TRUE),
            (NEW.id, 'votacion', TRUE),
            (NEW.id, 'certificados', TRUE),
            (NEW.id, 'proyector', TRUE)
            -- 'actas' se agrega cuando la feature esté lista
        ON CONFLICT (evento_id, modulo) DO NOTHING;

    ELSIF NEW.producto = 'mixto' THEN
        INSERT INTO evento_modulos (evento_id, modulo, activo)
        VALUES
            (NEW.id, 'programa', TRUE),
            (NEW.id, 'registro', TRUE),
            (NEW.id, 'preguntas', TRUE),
            (NEW.id, 'votacion', TRUE),
            (NEW.id, 'encuesta', TRUE),
            (NEW.id, 'materiales', TRUE),
            (NEW.id, 'certificados', TRUE),
            (NEW.id, 'resumenes_ia', TRUE),
            (NEW.id, 'proyector', TRUE)
        ON CONFLICT (evento_id, modulo) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_activar_modulos ON eventos;
CREATE TRIGGER trg_activar_modulos
    AFTER INSERT ON eventos
    FOR EACH ROW
    EXECUTE FUNCTION activar_modulos_por_defecto();


-- =============================================================================
-- 7. TRIGGERS updated_at en tablas nuevas
-- =============================================================================

CREATE TRIGGER set_updated_at_actas_automaticas
    BEFORE UPDATE ON actas_automaticas
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- =============================================================================
-- 8. VISTA UTIL: eventos con conteos rápidos
-- =============================================================================
-- Para el dashboard del anfitrión. Una sola query muestra estado del evento.
-- =============================================================================

CREATE OR REPLACE VIEW v_eventos_resumen AS
SELECT
    e.id,
    e.organizacion_id,
    e.slug,
    e.nombre,
    e.producto,
    e.subtipo,
    e.estado,
    e.fecha_inicio,
    e.fecha_fin,

    -- Conteos
    (SELECT COUNT(*) FROM asistentes a WHERE a.evento_id = e.id) AS total_asistentes,
    (SELECT COUNT(*) FROM ponencias p WHERE p.evento_id = e.id) AS total_ponencias,
    (SELECT COUNT(*) FROM votaciones v WHERE v.evento_id = e.id) AS total_votaciones,
    (SELECT COUNT(*) FROM materiales m WHERE m.evento_id = e.id AND m.activo) AS total_materiales,
    (SELECT COUNT(*) FROM certificados_emitidos c WHERE c.evento_id = e.id AND NOT c.anulado) AS certificados_emitidos,
    (SELECT COUNT(*) FROM actas_automaticas ac WHERE ac.evento_id = e.id) AS actas_generadas

FROM eventos e
WHERE e.deleted_at IS NULL;


-- =============================================================================
-- FIN MIGRACIÓN v1.1
-- =============================================================================
-- Próxima migración v1.2 (cuando se construya la feature de actas en junio):
-- - Tabla `actas_firmas` para firmas múltiples (presidente + secretario + 2 testigos)
-- - Tabla `actas_observaciones` para que los miembros puedan observar acta antes de firma
-- - Workflow de envío de borrador a junta directiva por email
-- =============================================================================