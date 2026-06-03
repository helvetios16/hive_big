-- ============================================================
-- Consultas analíticas de referencia  |  taxiscope — Actividad 4
--
-- NO se ejecutan automáticamente. Cópialas y pégalas dentro de la
-- sesión interactiva de Hive (taxiscope/scripts/hive_shell.sh).
-- Tras cada consulta, Hive imprime "Time taken: N seconds" → ese es
-- el tiempo real del análisis distribuido.
--
-- Tabla particionada: taxi_part (anio, mes) — creada con partition.hql.
-- ============================================================

-- ── 1. Total de viajes ───────────────────────────────────────────────
SELECT COUNT(*) AS total_viajes
FROM taxi_part;

-- ── 2. Promedio de distancia (km/millas) ─────────────────────────────
--    Filtramos distancias <= 0 (registros erróneos del TLC).
SELECT
    ROUND(AVG(trip_distance), 3) AS distancia_promedio,
    ROUND(MAX(trip_distance), 2) AS distancia_maxima
FROM taxi_part
WHERE trip_distance > 0;

-- ── 3. Horas con mayor tráfico ───────────────────────────────────────
--    Nº de viajes por hora de recogida; revela las horas punta.
SELECT
    HOUR(tpep_pickup_datetime) AS hora,
    COUNT(*)                   AS viajes
FROM taxi_part
GROUP BY HOUR(tpep_pickup_datetime)
ORDER BY viajes DESC;

-- ── 4. Métodos de pago utilizados ────────────────────────────────────
--    Mapeo según el diccionario de datos del TLC.
SELECT
    payment_type,
    CASE payment_type
        WHEN 1 THEN 'Tarjeta de crédito'
        WHEN 2 THEN 'Efectivo'
        WHEN 3 THEN 'Sin cargo'
        WHEN 4 THEN 'Disputa'
        WHEN 5 THEN 'Desconocido'
        WHEN 6 THEN 'Viaje anulado'
        ELSE 'Otro'
    END                              AS metodo_pago,
    COUNT(*)                         AS viajes,
    ROUND(AVG(total_amount), 2)      AS ticket_promedio
FROM taxi_part
GROUP BY payment_type
ORDER BY viajes DESC;

-- ── 5. Top 10 viajes más costosos ────────────────────────────────────
SELECT
    tpep_pickup_datetime,
    trip_distance,
    payment_type,
    total_amount
FROM taxi_part
WHERE total_amount > 0
ORDER BY total_amount DESC
LIMIT 10;

-- ── 6. Consulta con particiones (partition pruning) ──────────────────
--    Al filtrar por anio/mes, Hive lee SOLO esas particiones, no todo
--    el dataset. Compara el "Time taken" frente a una consulta global.
SELECT
    anio, mes,
    COUNT(*)                    AS viajes,
    ROUND(AVG(fare_amount), 2)  AS tarifa_promedio,
    ROUND(SUM(total_amount), 2) AS recaudacion
FROM taxi_part
WHERE anio = 2024 AND mes IN (1, 2, 3)
GROUP BY anio, mes
ORDER BY anio, mes;

--    (Opcional) Ver el plan y confirmar que solo toca las particiones
--    filtradas — busca "partitions" en la salida:
-- EXPLAIN SELECT COUNT(*) FROM taxi_part WHERE anio = 2024 AND mes = 1;

-- Salir de Hive
-- exit;
