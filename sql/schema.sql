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
    telefono    String DEFAULT '',
    empresa     String DEFAULT '',                   -- razón social, texto libre
    -- Industria y dotación: conjuntos cerrados y cortos -> LowCardinality.
    -- Se guarda el valor canónico EN INGLÉS ("Food & Beverage"), que es el que
    -- espera Salesforce; el formulario muestra la etiqueta en español y manda
    -- el inglés. Así el dato ya sale listo, sin conversión posterior.
    industria   LowCardinality(String) DEFAULT '',
    empleados   LowCardinality(String) DEFAULT '',   -- "51-100", "10000+"
    session_id  String DEFAULT '',                   -- liga con la sesión de ClickStack
    elapsed_ms  UInt32 DEFAULT 0,                    -- 0 = registrado, no terminó
    flips       UInt16 DEFAULT 0,
    fallos      UInt16 DEFAULT 0,
    registrado  DateTime64(3) DEFAULT now64(3),
    updated_at  DateTime64(3) DEFAULT now64(3)       -- versión del Replacing
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (evento, correo);

-- Si la tabla YA existe con datos, no la recrees: añade las columnas nuevas.
-- En ClickHouse esto es solo metadatos, no reescribe las partes existentes,
-- y las filas viejas quedan con '' (el DEFAULT).
ALTER TABLE evento.partidas
    ADD COLUMN IF NOT EXISTS telefono  String                 DEFAULT '' AFTER apellido,
    ADD COLUMN IF NOT EXISTS empresa   String                 DEFAULT '' AFTER telefono,
    ADD COLUMN IF NOT EXISTS industria LowCardinality(String) DEFAULT '' AFTER empresa,
    ADD COLUMN IF NOT EXISTS empleados LowCardinality(String) DEFAULT '' AFTER industria;

-- Inserciones de una fila desde el navegador: sin esto se crean demasiadas
-- parts pequeñas. wait_for_async_insert=1 para que el endpoint solo responda
-- OK cuando el dato quedó realmente escrito.
-- Ajusta el nombre del usuario al que uses en el Query Endpoint.
ALTER USER juego_evento SETTINGS
    async_insert = 1,
    wait_for_async_insert = 1;

-- Los permisos son POR COLUMNA: al añadir columnas hay que volver a otorgarlos,
-- si no los endpoints 1 y 2 responden 403 "Not enough privileges".
GRANT INSERT(evento, correo, nombre, apellido, telefono, empresa, industria,
             empleados, session_id, elapsed_ms, flips, fallos, updated_at)
    ON evento.partidas TO juego_evento;
GRANT SELECT(evento, correo, nombre, apellido, elapsed_ms)
    ON evento.partidas TO juego_evento;


-- ============================================================
-- ENDPOINT 1 — registro  (al enviar el formulario)
-- Variables: evento, correo, nombre, apellido, telefono, empresa,
--            industria, empleados, session_id
-- ============================================================
INSERT INTO evento.partidas
    (evento, correo, nombre, apellido, telefono, empresa,
     industria, empleados, session_id, updated_at)
SELECT
    {evento:String},
    lower(trim({correo:String})),
    trim({nombre:String}),
    trim({apellido:String}),
    trim({telefono:String}),
    trim({empresa:String}),
    trim({industria:String}),
    trim({empleados:String}),
    {session_id:String},
    now64(3);


-- ============================================================
-- ENDPOINT 2 — tiempo  (al terminar la partida)
-- Variables: evento, correo, nombre, apellido, telefono, empresa, industria,
--            empleados, session_id, elapsed_ms, flips, fallos
--
-- Reinserta la fila COMPLETA: con ReplacingMergeTree la última versión
-- reemplaza a la anterior, así que omitir cualquier columna la borraría.
-- Si añades campos al formulario, tienen que aparecer TAMBIÉN aquí.
-- ============================================================
INSERT INTO evento.partidas
    (evento, correo, nombre, apellido, telefono, empresa, industria, empleados,
     session_id, elapsed_ms, flips, fallos, updated_at)
SELECT
    {evento:String},
    lower(trim({correo:String})),
    trim({nombre:String}),
    trim({apellido:String}),
    trim({telefono:String}),
    trim({empresa:String}),
    trim({industria:String}),
    trim({empleados:String}),
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

-- Lista de leads para pasar a marketing / Salesforce.
-- industria ya viene en inglés canónico; empleados, tal cual se eligió.
SELECT nombre, apellido, correo, telefono, empresa, industria, empleados,
       elapsed_ms, registrado
FROM evento.partidas FINAL
WHERE evento = {evento:String}
ORDER BY registrado ASC;

-- Leads por industria.
SELECT industria, count() AS leads
FROM evento.partidas FINAL
WHERE evento = {evento:String} AND industria != ''
GROUP BY industria
ORDER BY leads DESC;

-- Leads por tamaño de empresa.
-- Ordenamos por la posición en el array, no alfabéticamente: como texto
-- "101-250" iría antes que "11-25" y el informe saldría desordenado.
SELECT empleados, count() AS leads
FROM evento.partidas FINAL
WHERE evento = {evento:String} AND empleados != ''
GROUP BY empleados
ORDER BY indexOf(['0-10','11-25','26-50','51-100','101-250','251-500',
                  '501-1000','1001-2500','2501-5000','5001-10000','10000+'],
                 empleados);
