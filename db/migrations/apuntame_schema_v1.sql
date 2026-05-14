-- =============================================================================
-- apuntame.online - Schema de Base de Datos PostgreSQL
-- =============================================================================
-- Versión:     1.0 (MVP)
-- Cliente 0:   ICAL Congreso 2026 (28-30 mayo)
-- Fecha:       2026-05-09
-- Autor:       Duilio Restuccia / Perú Sistemas Pro E.I.R.L.
-- Stack:       FastAPI + PostgreSQL + Jinja2/HTMX + Vanilla JS (Railway)
-- =============================================================================
--
-- ARQUITECTURA: Multi-tenant por columna organizacion_id (no schema-per-tenant).
-- Cada Organización (ICAL, CCPL, sindicato, club) crea Eventos.
-- Cada Evento activa los Módulos que necesita y paga por ellos.
--
-- =============================================================================


-- =============================================================================
-- 1. EXTENSIONES
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- búsqueda fuzzy (asistentes, ponentes)
CREATE EXTENSION IF NOT EXISTS "unaccent";  -- búsqueda sin tildes


-- Wrapper IMMUTABLE de unaccent (PostgreSQL exige IMMUTABLE en índices).
-- unaccent() por defecto es STABLE porque depende del diccionario.
-- Este wrapper le dice a PG: "confía en mí, el resultado nunca cambia".
CREATE OR REPLACE FUNCTION immutable_unaccent(text)
RETURNS text AS $$
    SELECT public.unaccent('public.unaccent', $1);
$$ LANGUAGE sql IMMUTABLE;


-- =============================================================================
-- 2. TIPOS ENUMERADOS
-- =============================================================================

CREATE TYPE plan_organizacion   AS ENUM ('free', 'pro', 'enterprise');
CREATE TYPE tipo_institucion    AS ENUM ('colegio_profesional', 'sindicato', 'club', 'asociacion', 'colegio_escolar', 'empresa', 'iglesia', 'otro');
CREATE TYPE tipo_evento         AS ENUM ('congreso', 'asamblea', 'eleccion', 'encuesta', 'capacitacion', 'mixto');
CREATE TYPE estado_evento       AS ENUM ('borrador', 'publicado', 'en_curso', 'finalizado', 'archivado');
CREATE TYPE rol_usuario         AS ENUM ('superadmin', 'anfitrion', 'moderador', 'staff');
CREATE TYPE tipo_modulo         AS ENUM ('programa', 'registro', 'preguntas', 'votacion', 'encuesta', 'certificados', 'materiales', 'resumenes_ia', 'proyector');
CREATE TYPE estado_pregunta     AS ENUM ('pendiente', 'aprobada', 'descartada', 'respondida');
CREATE TYPE tipo_voto           AS ENUM ('publico', 'secreto', 'a_mano_alzada');
CREATE TYPE estado_votacion     AS ENUM ('borrador', 'abierta', 'cerrada', 'anulada');
CREATE TYPE tipo_certificado    AS ENUM ('asistencia', 'participacion', 'expositor', 'organizador', 'ganador', 'mencion');
CREATE TYPE estado_job_ia       AS ENUM ('pendiente', 'procesando', 'completado', 'fallido');
CREATE TYPE tipo_material       AS ENUM ('pdf', 'slides', 'link', 'video', 'paper', 'codigo', 'imagen', 'otro');
CREATE TYPE momento_material    AS ENUM ('previo', 'durante', 'posterior');


-- =============================================================================
-- 3. TENANCY: ORGANIZACIONES (clientes de apuntame.online)
-- =============================================================================

CREATE TABLE organizaciones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug VARCHAR(50) NOT NULL UNIQUE,                -- 'ical', 'ccpl', 'sindicato-construccion'
    nombre VARCHAR(200) NOT NULL,
    razon_social VARCHAR(200),
    ruc VARCHAR(11),
    tipo tipo_institucion NOT NULL DEFAULT 'otro',

    -- Branding (cada organización personaliza sus eventos)
    logo_url TEXT,
    color_primario VARCHAR(7) DEFAULT '#1e40af',
    color_secundario VARCHAR(7) DEFAULT '#3b82f6',

    -- Plan
    plan plan_organizacion NOT NULL DEFAULT 'free',
    fecha_inicio_plan DATE,
    fecha_fin_plan DATE,

    -- Contacto
    email_contacto VARCHAR(255),
    telefono VARCHAR(20),
    sitio_web VARCHAR(255),
    direccion TEXT,
    pais VARCHAR(2) DEFAULT 'PE',

    -- Auditoría
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_org_slug   ON organizaciones(slug) WHERE deleted_at IS NULL;
CREATE INDEX idx_org_plan   ON organizaciones(plan) WHERE deleted_at IS NULL;


-- =============================================================================
-- 4. USUARIOS DEL SISTEMA (anfitriones, moderadores, staff)
-- =============================================================================
-- NOTA: Los Asistentes NO son usuarios del sistema. Son registros públicos
-- con auto-registro por DNI. Tienen su propia tabla.

CREATE TABLE usuarios (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizacion_id UUID REFERENCES organizaciones(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    dni VARCHAR(8),
    telefono VARCHAR(20),
    rol rol_usuario NOT NULL DEFAULT 'staff',
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    ultimo_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_usuarios_org   ON usuarios(organizacion_id);
CREATE INDEX idx_usuarios_email ON usuarios(email);


-- =============================================================================
-- 5. EVENTOS
-- =============================================================================

CREATE TABLE eventos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizacion_id UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
    slug VARCHAR(80) NOT NULL,                         -- 'congreso-2026', 'asamblea-mayo'
    nombre VARCHAR(200) NOT NULL,
    descripcion TEXT,
    tipo tipo_evento NOT NULL DEFAULT 'congreso',
    estado estado_evento NOT NULL DEFAULT 'borrador',

    -- Fechas
    fecha_inicio DATE NOT NULL,
    fecha_fin DATE NOT NULL,
    hora_inicio TIME,
    hora_fin TIME,
    timezone VARCHAR(50) DEFAULT 'America/Lima',

    -- Sede
    sede_nombre VARCHAR(200),
    sede_direccion TEXT,
    sede_ciudad VARCHAR(100),
    sede_lat NUMERIC(10, 7),
    sede_lng NUMERIC(10, 7),
    es_virtual BOOLEAN NOT NULL DEFAULT FALSE,
    url_streaming TEXT,

    -- Personalización visual (hereda de organizacion si null)
    logo_url TEXT,
    banner_url TEXT,
    color_primario VARCHAR(7),
    color_secundario VARCHAR(7),

    -- Capacidad y registro
    capacidad_maxima INTEGER,
    registro_abierto BOOLEAN NOT NULL DEFAULT TRUE,
    requiere_aprobacion BOOLEAN NOT NULL DEFAULT FALSE,
    requiere_pago BOOLEAN NOT NULL DEFAULT FALSE,
    precio NUMERIC(10, 2) DEFAULT 0,

    -- Marketing (la "puerta de entrada" que mencionó Duilio)
    permite_optin_marketing BOOLEAN NOT NULL DEFAULT TRUE,
    texto_optin_marketing TEXT,

    -- Auditoría
    created_by UUID REFERENCES usuarios(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,

    UNIQUE(organizacion_id, slug)
);

CREATE INDEX idx_eventos_org_slug ON eventos(organizacion_id, slug) WHERE deleted_at IS NULL;
CREATE INDEX idx_eventos_estado   ON eventos(estado) WHERE deleted_at IS NULL;
CREATE INDEX idx_eventos_fechas   ON eventos(fecha_inicio, fecha_fin);


-- Configuración de módulos activos por evento
CREATE TABLE evento_modulos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    modulo tipo_modulo NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    config JSONB DEFAULT '{}'::jsonb,                  -- configuración específica del módulo
    UNIQUE(evento_id, modulo)
);

CREATE INDEX idx_modulos_evento ON evento_modulos(evento_id);


-- =============================================================================
-- 6. PROGRAMA: PONENCIAS Y PONENTES
-- =============================================================================

CREATE TABLE ponentes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizacion_id UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    titulo_profesional VARCHAR(100),                   -- 'CPC', 'Mg.', 'Dr.', 'Abg.'
    cargo_actual VARCHAR(200),
    institucion VARCHAR(200),
    pais VARCHAR(2) DEFAULT 'PE',
    biografia TEXT,
    bibliografia TEXT,                                 -- libros/papers publicados
    foto_url TEXT,

    -- Redes sociales y contacto
    email VARCHAR(255),
    linkedin_url VARCHAR(255),
    twitter_handle VARCHAR(50),
    sitio_web VARCHAR(255),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ponentes_org    ON ponentes(organizacion_id);
CREATE INDEX idx_ponentes_busqueda ON ponentes USING gin(
    (immutable_unaccent(lower(nombres || ' ' || apellidos))) gin_trgm_ops
);


CREATE TABLE ponencias (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    titulo VARCHAR(300) NOT NULL,
    resumen TEXT,                                      -- abstract
    eje_tematico VARCHAR(100),                         -- 'NICSP', 'IFRS', 'Auditoría'

    -- Programación
    fecha DATE NOT NULL,
    hora_inicio TIME NOT NULL,
    hora_fin TIME NOT NULL,
    sala VARCHAR(100),                                 -- 'Auditorio Principal', 'Sala 2'
    orden INTEGER DEFAULT 0,                           -- para ordenar dentro del día

    -- Estado en vivo
    en_curso BOOLEAN NOT NULL DEFAULT FALSE,
    finalizada BOOLEAN NOT NULL DEFAULT FALSE,

    -- Configuración por ponencia
    permite_preguntas BOOLEAN NOT NULL DEFAULT TRUE,
    preguntas_abiertas BOOLEAN NOT NULL DEFAULT FALSE,  -- el moderador abre cuando quiere
    grabar_audio BOOLEAN NOT NULL DEFAULT FALSE,        -- para resumen IA

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ponencias_evento ON ponencias(evento_id);
CREATE INDEX idx_ponencias_fecha  ON ponencias(evento_id, fecha, hora_inicio);


-- M:N porque puede haber co-expositores
CREATE TABLE ponencia_ponentes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ponencia_id UUID NOT NULL REFERENCES ponencias(id) ON DELETE CASCADE,
    ponente_id UUID NOT NULL REFERENCES ponentes(id) ON DELETE RESTRICT,
    rol VARCHAR(50) DEFAULT 'principal',               -- 'principal', 'co-expositor', 'moderador'
    orden INTEGER DEFAULT 0,
    UNIQUE(ponencia_id, ponente_id)
);

CREATE INDEX idx_pp_ponencia ON ponencia_ponentes(ponencia_id);
CREATE INDEX idx_pp_ponente  ON ponencia_ponentes(ponente_id);


-- =============================================================================
-- 7. MATERIALES (entrega de PDFs, slides, links, etc.)
-- =============================================================================

CREATE TABLE materiales (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    ponencia_id UUID REFERENCES ponencias(id) ON DELETE CASCADE,  -- NULL = material general del evento
    tipo tipo_material NOT NULL DEFAULT 'pdf',
    momento momento_material NOT NULL DEFAULT 'durante',
    titulo VARCHAR(200) NOT NULL,
    descripcion TEXT,
    archivo_url TEXT,                                  -- si es archivo subido
    enlace_url TEXT,                                   -- si es link externo
    archivo_size_bytes BIGINT,
    requiere_registro BOOLEAN NOT NULL DEFAULT TRUE,   -- solo asistentes registrados
    descargas_count INTEGER NOT NULL DEFAULT 0,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_materiales_evento   ON materiales(evento_id) WHERE activo = TRUE;
CREATE INDEX idx_materiales_ponencia ON materiales(ponencia_id) WHERE activo = TRUE;


-- =============================================================================
-- 8. ASISTENTES (auto-registro público, NO usuarios del sistema)
-- =============================================================================

CREATE TABLE asistentes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,

    -- Identidad
    dni VARCHAR(8),
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    email VARCHAR(255),
    telefono VARCHAR(20),

    -- Datos profesionales (opcional, según evento)
    profesion VARCHAR(100),
    institucion VARCHAR(200),
    cargo VARCHAR(150),
    ciudad VARCHAR(100),
    pais VARCHAR(2) DEFAULT 'PE',
    numero_colegiatura VARCHAR(50),                    -- para Colegios Profesionales

    -- Auto-registro
    foto_dni_url TEXT,                                 -- foto opcional del DNI
    qr_acceso VARCHAR(100) UNIQUE NOT NULL DEFAULT replace(uuid_generate_v4()::text, '-', ''),

    -- Asistencia (check-in)
    check_in_at TIMESTAMPTZ,
    check_out_at TIMESTAMPTZ,

    -- Marketing
    optin_marketing BOOLEAN NOT NULL DEFAULT FALSE,
    optin_terceros BOOLEAN NOT NULL DEFAULT FALSE,     -- compartir con sponsors

    -- Datos arbitrarios según evento (campos extra configurables)
    datos_extra JSONB DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(evento_id, dni)
);

CREATE INDEX idx_asistentes_evento  ON asistentes(evento_id);
CREATE INDEX idx_asistentes_dni     ON asistentes(dni);
CREATE INDEX idx_asistentes_email   ON asistentes(email);
CREATE INDEX idx_asistentes_qr      ON asistentes(qr_acceso);
CREATE INDEX idx_asistentes_busqueda ON asistentes USING gin(
    (immutable_unaccent(lower(nombres || ' ' || apellidos))) gin_trgm_ops
);


-- Asistencia detallada por ponencia (para certificados con horas exactas)
CREATE TABLE asistencia_ponencia (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    asistente_id UUID NOT NULL REFERENCES asistentes(id) ON DELETE CASCADE,
    ponencia_id UUID NOT NULL REFERENCES ponencias(id) ON DELETE CASCADE,
    check_in_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    check_out_at TIMESTAMPTZ,
    UNIQUE(asistente_id, ponencia_id)
);

CREATE INDEX idx_asis_pon_asistente ON asistencia_ponencia(asistente_id);
CREATE INDEX idx_asis_pon_ponencia  ON asistencia_ponencia(ponencia_id);


-- Tracking de descargas de materiales (analytics + restricción a registrados)
CREATE TABLE material_descargas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    material_id UUID NOT NULL REFERENCES materiales(id) ON DELETE CASCADE,
    asistente_id UUID REFERENCES asistentes(id) ON DELETE SET NULL,
    ip_address INET,
    user_agent TEXT,
    descargado_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_descargas_material  ON material_descargas(material_id);
CREATE INDEX idx_descargas_asistente ON material_descargas(asistente_id);


-- =============================================================================
-- 9. PREGUNTAS AL EXPOSITOR (con moderación)
-- =============================================================================

CREATE TABLE preguntas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ponencia_id UUID NOT NULL REFERENCES ponencias(id) ON DELETE CASCADE,
    asistente_id UUID REFERENCES asistentes(id) ON DELETE SET NULL,
    texto TEXT NOT NULL,
    estado estado_pregunta NOT NULL DEFAULT 'pendiente',

    -- Clasificación (para filtrar/agrupar)
    categoria VARCHAR(50),                             -- 'NICSP', 'práctica', 'normativa'
    es_anonima BOOLEAN NOT NULL DEFAULT FALSE,

    -- Moderación
    moderado_por UUID REFERENCES usuarios(id),
    moderado_at TIMESTAMPTZ,
    razon_descarte TEXT,
    visible_pantalla BOOLEAN NOT NULL DEFAULT FALSE,   -- el moderador la pone en proyector

    -- Likes / votos por relevancia (asistentes votan qué les interesa)
    likes_count INTEGER NOT NULL DEFAULT 0,

    -- Respuesta del expositor (si la registró)
    respuesta_texto TEXT,
    respondida_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_preguntas_ponencia ON preguntas(ponencia_id, estado);
CREATE INDEX idx_preguntas_pantalla ON preguntas(ponencia_id) WHERE visible_pantalla = TRUE;


-- Likes de preguntas (para que las más relevantes suban)
CREATE TABLE pregunta_likes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pregunta_id UUID NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    asistente_id UUID NOT NULL REFERENCES asistentes(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(pregunta_id, asistente_id)
);

CREATE INDEX idx_likes_pregunta ON pregunta_likes(pregunta_id);


-- =============================================================================
-- 10. VOTACIONES Y ELECCIONES (asambleas, colegios profesionales, sindicatos)
-- =============================================================================

CREATE TABLE votaciones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    titulo VARCHAR(300) NOT NULL,
    descripcion TEXT,
    tipo_voto tipo_voto NOT NULL DEFAULT 'secreto',
    estado estado_votacion NOT NULL DEFAULT 'borrador',

    -- Tipo de votación
    es_eleccion BOOLEAN NOT NULL DEFAULT FALSE,        -- TRUE = candidatos, FALSE = opciones
    permite_blanco BOOLEAN NOT NULL DEFAULT TRUE,
    permite_viciado BOOLEAN NOT NULL DEFAULT TRUE,
    seleccion_multiple BOOLEAN NOT NULL DEFAULT FALSE,
    max_selecciones INTEGER DEFAULT 1,

    -- Padrón
    requiere_padron BOOLEAN NOT NULL DEFAULT TRUE,     -- solo padrón puede votar
    quorum_minimo INTEGER,                             -- número mínimo para validar

    -- Tiempos
    abierta_desde TIMESTAMPTZ,
    abierta_hasta TIMESTAMPTZ,

    -- Configuración avanzada
    config JSONB DEFAULT '{}'::jsonb,

    created_by UUID REFERENCES usuarios(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_votaciones_evento ON votaciones(evento_id, estado);


-- Opciones de la votación (sirve para elecciones con candidatos Y para asambleas con opciones)
CREATE TABLE votacion_opciones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    votacion_id UUID NOT NULL REFERENCES votaciones(id) ON DELETE CASCADE,
    titulo VARCHAR(300) NOT NULL,                      -- nombre del candidato O texto de la opción
    descripcion TEXT,                                  -- plan de gobierno, sustento de la moción
    foto_url TEXT,                                     -- foto del candidato si aplica
    numero_lista VARCHAR(20),                          -- 'Lista 1', 'Plancha A'
    orden INTEGER DEFAULT 0,
    activa BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_opciones_votacion ON votacion_opciones(votacion_id);


-- Padrón electoral (quiénes pueden votar)
CREATE TABLE votacion_padron (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    votacion_id UUID NOT NULL REFERENCES votaciones(id) ON DELETE CASCADE,
    asistente_id UUID REFERENCES asistentes(id) ON DELETE CASCADE,
    -- Si el asistente aún no se registró, podemos pre-cargar el padrón con DNI
    dni VARCHAR(8),
    nombres VARCHAR(100),
    apellidos VARCHAR(100),
    numero_colegiatura VARCHAR(50),
    -- Estado
    voto_emitido BOOLEAN NOT NULL DEFAULT FALSE,
    voto_emitido_at TIMESTAMPTZ,
    UNIQUE(votacion_id, dni)
);

CREATE INDEX idx_padron_votacion ON votacion_padron(votacion_id);
CREATE INDEX idx_padron_dni      ON votacion_padron(dni);


-- Voto emitido (en voto secreto NO se vincula al asistente, solo se marca emitido en padron)
CREATE TABLE votos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    votacion_id UUID NOT NULL REFERENCES votaciones(id) ON DELETE CASCADE,
    opcion_id UUID REFERENCES votacion_opciones(id) ON DELETE RESTRICT,

    -- En voto público: se guarda el padron_id. En voto secreto: NULL.
    padron_id UUID REFERENCES votacion_padron(id),

    -- Tipo
    es_blanco BOOLEAN NOT NULL DEFAULT FALSE,
    es_viciado BOOLEAN NOT NULL DEFAULT FALSE,

    -- Hash anti-fraude (HMAC del DNI + secreto + votacion_id) para auditar sin revelar
    hash_verificacion VARCHAR(64),

    -- Auditoría mínima (sin revelar identidad en voto secreto)
    ip_address INET,
    user_agent TEXT,
    emitido_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_votos_votacion ON votos(votacion_id);
CREATE INDEX idx_votos_opcion   ON votos(opcion_id);


-- =============================================================================
-- 11. ENCUESTAS (en vivo, durante el evento)
-- =============================================================================

CREATE TABLE encuestas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    ponencia_id UUID REFERENCES ponencias(id) ON DELETE CASCADE,  -- NULL = encuesta del evento
    titulo VARCHAR(300) NOT NULL,
    descripcion TEXT,
    es_anonima BOOLEAN NOT NULL DEFAULT TRUE,
    abierta BOOLEAN NOT NULL DEFAULT FALSE,
    abierta_desde TIMESTAMPTZ,
    abierta_hasta TIMESTAMPTZ,
    mostrar_resultados_en_vivo BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_encuestas_evento ON encuestas(evento_id);


CREATE TABLE encuesta_preguntas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    encuesta_id UUID NOT NULL REFERENCES encuestas(id) ON DELETE CASCADE,
    texto TEXT NOT NULL,
    tipo VARCHAR(20) NOT NULL DEFAULT 'opcion_unica',  -- opcion_unica, opcion_multiple, escala, abierta
    opciones JSONB DEFAULT '[]'::jsonb,                -- ['Sí', 'No', 'Tal vez']
    orden INTEGER DEFAULT 0,
    obligatoria BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_enc_preg_encuesta ON encuesta_preguntas(encuesta_id);


CREATE TABLE encuesta_respuestas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    encuesta_pregunta_id UUID NOT NULL REFERENCES encuesta_preguntas(id) ON DELETE CASCADE,
    asistente_id UUID REFERENCES asistentes(id) ON DELETE SET NULL,
    respuesta JSONB NOT NULL,                          -- valor según tipo de pregunta
    respondida_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_enc_resp_pregunta  ON encuesta_respuestas(encuesta_pregunta_id);
CREATE INDEX idx_enc_resp_asistente ON encuesta_respuestas(asistente_id);


-- =============================================================================
-- 12. CERTIFICADOS (Asistencia, Participación, Expositor, Ganador, etc.)
-- =============================================================================

CREATE TABLE plantillas_certificado (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizacion_id UUID NOT NULL REFERENCES organizaciones(id) ON DELETE CASCADE,
    nombre VARCHAR(150) NOT NULL,
    tipo tipo_certificado NOT NULL,
    fondo_url TEXT,                                    -- imagen base del certificado
    html_template TEXT,                                -- HTML con variables {{nombre}}, {{evento}}, {{horas}}
    config JSONB DEFAULT '{}'::jsonb,                  -- posiciones de campos, fuentes, colores
    activa BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_plantillas_org ON plantillas_certificado(organizacion_id) WHERE activa = TRUE;


CREATE TABLE certificados_emitidos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    asistente_id UUID REFERENCES asistentes(id) ON DELETE SET NULL,
    ponente_id UUID REFERENCES ponentes(id) ON DELETE SET NULL,
    plantilla_id UUID REFERENCES plantillas_certificado(id),
    tipo tipo_certificado NOT NULL,

    -- Contenido del certificado
    nombre_completo VARCHAR(200) NOT NULL,
    documento_identidad VARCHAR(20),
    horas_lectivas NUMERIC(5, 2),                      -- horas certificadas (24.5h)

    -- Códigos de verificación (dual code, como en CCPL)
    codigo_correlativo VARCHAR(50) UNIQUE NOT NULL,    -- ICAL-2026-0001
    codigo_seguridad VARCHAR(20) UNIQUE NOT NULL,      -- generado random
    qr_url TEXT NOT NULL,                              -- url pública de validación

    -- Archivos generados
    pdf_url TEXT,
    imagen_url TEXT,

    -- Estado
    emitido_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    descargado_at TIMESTAMPTZ,
    descargas_count INTEGER NOT NULL DEFAULT 0,

    -- Notificación al asistente
    enviado_por_email BOOLEAN NOT NULL DEFAULT FALSE,
    enviado_por_whatsapp BOOLEAN NOT NULL DEFAULT FALSE,

    -- Anulación
    anulado BOOLEAN NOT NULL DEFAULT FALSE,
    anulado_at TIMESTAMPTZ,
    razon_anulacion TEXT
);

CREATE INDEX idx_cert_evento     ON certificados_emitidos(evento_id);
CREATE INDEX idx_cert_asistente  ON certificados_emitidos(asistente_id);
CREATE INDEX idx_cert_correlativo ON certificados_emitidos(codigo_correlativo);
CREATE INDEX idx_cert_seguridad  ON certificados_emitidos(codigo_seguridad);


-- =============================================================================
-- 13. RESÚMENES IA (transcripción + síntesis automática post-ponencia)
-- =============================================================================

CREATE TABLE transcripciones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ponencia_id UUID NOT NULL REFERENCES ponencias(id) ON DELETE CASCADE,
    audio_url TEXT NOT NULL,
    audio_duracion_segundos INTEGER,
    audio_size_bytes BIGINT,
    texto_completo TEXT,
    idioma VARCHAR(5) DEFAULT 'es',
    modelo_usado VARCHAR(50),                          -- 'whisper-1', 'whisper-large-v3'
    estado estado_job_ia NOT NULL DEFAULT 'pendiente',
    error_mensaje TEXT,
    procesado_at TIMESTAMPTZ,
    costo_estimado_usd NUMERIC(8, 4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_transcripciones_ponencia ON transcripciones(ponencia_id);
CREATE INDEX idx_transcripciones_estado   ON transcripciones(estado);


CREATE TABLE resumenes_ia (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ponencia_id UUID NOT NULL REFERENCES ponencias(id) ON DELETE CASCADE,
    transcripcion_id UUID REFERENCES transcripciones(id),

    -- Síntesis estructurada (usar Claude API)
    resumen_ejecutivo TEXT,                            -- 2-3 párrafos
    puntos_clave JSONB DEFAULT '[]'::jsonb,            -- ["punto 1", "punto 2", ...]
    conclusiones JSONB DEFAULT '[]'::jsonb,
    citas_relevantes JSONB DEFAULT '[]'::jsonb,        -- frases textuales destacadas
    preguntas_formuladas JSONB DEFAULT '[]'::jsonb,
    referencias_mencionadas JSONB DEFAULT '[]'::jsonb, -- libros, normas, papers citados
    glosario JSONB DEFAULT '{}'::jsonb,                -- términos técnicos definidos

    -- Modelo y costo
    modelo_usado VARCHAR(50),                          -- 'claude-sonnet-4-7', 'gpt-4o'
    tokens_input INTEGER,
    tokens_output INTEGER,
    costo_estimado_usd NUMERIC(8, 4),

    -- Estado y publicación
    estado estado_job_ia NOT NULL DEFAULT 'pendiente',
    publicado BOOLEAN NOT NULL DEFAULT FALSE,          -- aprobado por anfitrión para mostrar
    aprobado_por UUID REFERENCES usuarios(id),
    aprobado_at TIMESTAMPTZ,

    -- Output
    pdf_url TEXT,
    error_mensaje TEXT,
    procesado_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_resumenes_ponencia ON resumenes_ia(ponencia_id);
CREATE INDEX idx_resumenes_estado   ON resumenes_ia(estado);


-- Compendio del evento (consolidado de todas las ponencias)
CREATE TABLE compendios_evento (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL REFERENCES eventos(id) ON DELETE CASCADE,
    titulo VARCHAR(300) NOT NULL,
    introduccion TEXT,
    cierre TEXT,
    config JSONB DEFAULT '{}'::jsonb,                  -- secciones, índice, etc.
    pdf_url TEXT,
    publicado BOOLEAN NOT NULL DEFAULT FALSE,
    publicado_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_compendios_evento ON compendios_evento(evento_id);


-- =============================================================================
-- 14. PROYECTOR (vista en pantalla grande del evento, controlada por moderador)
-- =============================================================================

CREATE TABLE proyector_estado (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    evento_id UUID NOT NULL UNIQUE REFERENCES eventos(id) ON DELETE CASCADE,
    -- Modo actual: 'agenda', 'ponencia_actual', 'pregunta_destacada', 'votacion_en_vivo', 'resultados', 'pausa'
    modo VARCHAR(50) NOT NULL DEFAULT 'agenda',
    ponencia_id UUID REFERENCES ponencias(id),
    pregunta_id UUID REFERENCES preguntas(id),
    votacion_id UUID REFERENCES votaciones(id),
    mensaje_personalizado TEXT,
    config JSONB DEFAULT '{}'::jsonb,
    actualizado_por UUID REFERENCES usuarios(id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- =============================================================================
-- 15. AUDITORÍA Y LOGS
-- =============================================================================

CREATE TABLE log_eventos (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organizacion_id UUID,
    evento_id UUID,
    usuario_id UUID,
    asistente_id UUID,
    tipo_accion VARCHAR(50) NOT NULL,                  -- 'login', 'voto_emitido', 'pregunta_creada', etc.
    descripcion TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_log_org      ON log_eventos(organizacion_id);
CREATE INDEX idx_log_evento   ON log_eventos(evento_id);
CREATE INDEX idx_log_tipo     ON log_eventos(tipo_accion);
CREATE INDEX idx_log_fecha    ON log_eventos(created_at DESC);


-- =============================================================================
-- 16. TRIGGERS DE updated_at
-- =============================================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Aplicar a todas las tablas con updated_at
DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        SELECT table_name FROM information_schema.columns
        WHERE column_name = 'updated_at' AND table_schema = 'public'
    LOOP
        EXECUTE format('
            CREATE TRIGGER set_updated_at_%I
            BEFORE UPDATE ON %I
            FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
        ', t, t);
    END LOOP;
END $$;


-- =============================================================================
-- 17. DATOS SEMILLA: ICAL Congreso 2026 (solo estructura, datos reales después)
-- =============================================================================

-- Insertar organización ICAL como ejemplo
-- INSERT INTO organizaciones (slug, nombre, razon_social, ruc, tipo, plan, email_contacto)
-- VALUES ('ical', 'Ilustre Colegio de Abogados de Loreto', 'ICAL', '20XXXXXXXXX',
--         'colegio_profesional', 'pro', 'contacto@ical.org.pe');


-- =============================================================================
-- FIN DEL SCHEMA v1.0
-- =============================================================================