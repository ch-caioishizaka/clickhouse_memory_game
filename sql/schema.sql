-- ============================================================
-- Memoria ClickHouse — esquema y consultas parametrizadas
-- Pensado para exponerse como Query Endpoints de ClickHouse Cloud.
-- ============================================================

CREATE DATABASE IF NOT EXISTS evento;

-- Una fila por persona y por evento.
--
-- ReplacingMergeTree en vez de UPDATE: el registro se inserta al llenar el
-- formulario y se vuelve a insertar completo al terminar la partida. La
-- versión más nueva (updated_at) gana en el merge. Sin mutaciones.
--
-- ORDER BY (evento, correo):
--   · es la clave de deduplicación — define qué significa "la misma persona";
--   · 'evento' va primero por ser de baja cardinalidad (unos pocos stands),
--     lo que permite descartar granules completos al filtrar por evento.
--
-- Sin PARTITION BY a propósito: son miles de filas, no hay retención ni
-- archivado que gestionar. Se añade después si aparece esa necesidad.
CREATE TABLE IF NOT EXISTS evento.partidas
(
    evento      LowCardinality(String),              -- "Stand ClickHouse Chile"
    correo      String,                              -- normalizado: lower+trim
    nombre      String DEFAULT '',
    apellido    String DEFAULT '',
    session_id  String DEFAULT '',                   -- liga con la sesión de ClickStack
    elapsed_ms  UInt32 DEFAULT 0,                    -- 0 = registrado, no terminó
    flips       UInt16 DEFAULT 0,
    fallos      UInt16 DEFAULT 0,
    registrado  DateTime64(3) DEFAULT now64(3),
    updated_at  DateTime64(3) DEFAULT now64(3)       -- versión del Replacing
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (evento, correo);

-- Inserciones de una fila desde el navegador: sin esto se crean demasiadas
-- parts pequeñas. wait_for_async_insert=1 para que el endpoint solo responda
-- OK cuando el dato quedó realmente escrito.
-- Ajusta el nombre del usuario al que uses en el Query Endpoint.
ALTER USER juego_evento SETTINGS
    async_insert = 1,
    wait_for_async_insert = 1;


-- ============================================================
-- ENDPOINT 1 — registro  (al enviar el formulario)
-- Variables: evento, correo, nombre, apellido, session_id
-- ============================================================
INSERT INTO evento.partidas
    (evento, correo, nombre, apellido, session_id, updated_at)
SELECT
    {evento:String},
    lower(trim({correo:String})),
    trim({nombre:String}),
    trim({apellido:String}),
    {session_id:String},
    now64(3);


-- ============================================================
-- ENDPOINT 2 — tiempo  (al terminar la partida)
-- Variables: evento, correo, nombre, apellido, session_id, elapsed_ms, flips, fallos
--
-- Reinserta la fila COMPLETA: con ReplacingMergeTree la última versión
-- reemplaza a la anterior, así que omitir nombre/apellido los borraría.
-- ============================================================
INSERT INTO evento.partidas
    (evento, correo, nombre, apellido, session_id, elapsed_ms, flips, fallos, updated_at)
SELECT
    {evento:String},
    lower(trim({correo:String})),
    trim({nombre:String}),
    trim({apellido:String}),
    {session_id:String},
    {elapsed_ms:UInt32},
    {flips:UInt16},
    {fallos:UInt16},
    now64(3);


-- ============================================================
-- ENDPOINT 3 — top  (tabla de posiciones)
-- Variables: evento, limite
--
-- substringUTF8/upperUTF8 y no substring/upper: con bytes crudos un
-- apellido como "Ñuñez" se parte a la mitad. Esto reproduce exactamente
-- initial() de index.html -> "Camila R.", "José Ñ."
-- ============================================================
SELECT
    concat(nombre, ' ', upperUTF8(substringUTF8(apellido, 1, 1)), '.') AS name,
    elapsed_ms                                                        AS ms
FROM evento.partidas FINAL
WHERE evento = {evento:String}
  AND elapsed_ms > 0
ORDER BY ms ASC
LIMIT {limite:UInt8};


-- ============================================================
-- ENDPOINT 4 — posicion  (puesto y total, para la pantalla de resultado)
-- Variables: evento, correo
-- ============================================================
WITH clasificados AS
(
    SELECT
        correo,
        row_number() OVER (ORDER BY elapsed_ms ASC) AS pos
    FROM evento.partidas FINAL
    WHERE evento = {evento:String}
      AND elapsed_ms > 0
)
SELECT
    (SELECT pos FROM clasificados WHERE correo = lower(trim({correo:String}))) AS pos,
    (SELECT count() FROM clasificados)                                         AS total;


-- ============================================================
-- ENDPOINT 5 — ya_jugo  (un intento por persona)
-- Variables: evento, correo
-- ============================================================
SELECT count() > 0 AS dup
FROM evento.partidas FINAL
WHERE evento = {evento:String}
  AND correo = lower(trim({correo:String}))
  AND elapsed_ms > 0;


-- ============================================================
-- Consultas para el stand / seguimiento (no son endpoints)
-- ============================================================

-- Embudo del día: cuántos se registraron vs cuántos terminaron.
SELECT
    count()                              AS registrados,
    countIf(elapsed_ms > 0)              AS jugaron,
    round(100 * countIf(elapsed_ms > 0) / count(), 1) AS conversion_pct,
    round(avg(elapsed_ms) FILTER (WHERE elapsed_ms > 0) / 1000, 1) AS promedio_seg,
    min(elapsed_ms) FILTER (WHERE elapsed_ms > 0)     AS mejor_ms
FROM evento.partidas FINAL
WHERE evento = {evento:String};

-- Lista de leads para pasar a marketing.
SELECT nombre, apellido, correo, elapsed_ms, registrado
FROM evento.partidas FINAL
WHERE evento = {evento:String}
ORDER BY registrado ASC;
