-- ─────────────────────────────────────────────────────────────────────
-- 0012 — Las vistas del simulador necesitan que `authenticated` pueda
-- ejecutar las funciones PURAS que usan.
--
-- QUÉ PASÓ, PORQUE MERECE QUEDAR ESCRITO
--
-- Recién aplicada la 0011, `/simulador` cargaba pero mostraba
-- «permission denied for function fn_tope_fase». La cadena es exacta:
-- `v_cuentas_equity` lleva `security_invoker = true` (obligatorio, I13),
-- así que se ejecuta con el rol de quien consulta —`authenticated`—, y
-- ese rol no tenía EXECUTE sobre `fn_tope_fase` porque la 0011 se la
-- revocó a todas las `fn_` sin distinguir.
--
-- Y POR QUÉ NO LO VIERON LAS INVARIANTES: el bloque del Sprint 5 probaba
-- los RPC con el JWT de cada usuario, pero leía las VISTAS como dueño del
-- esquema. El dueño ejecuta cualquier función, así que el fallo no podía
-- aparecer. La invariante I40 que añade este cambio cierra ese agujero
-- leyendo TODAS las vistas de `public` con el rol `authenticated`, que es
-- exactamente lo que hace el navegador.
--
-- LA REGLA, AFINADA
--
-- La invariante I23 decía «`authenticated` no ejecuta ninguna `fn_`». La
-- intención nunca fue la forma del nombre: era que un cliente no pueda
-- invocar las funciones que TOCAN DATOS o que se saltan la RLS, que son
-- las `SECURITY DEFINER`. Una función pura —sin acceso a tablas, sin
-- `SECURITY DEFINER`— no concede nada: `fn_tope_fase('fase_2...')`
-- devuelve 3.0 y punto. Concederla es tan peligroso como conceder
-- `round()`.
--
-- Así que la regla pasa a ser: **`authenticated` no ejecuta ninguna `fn_`
-- que sea `SECURITY DEFINER`**. Las cinco puras de abajo, y solo esas, se
-- conceden. `fn_equity`, `fn_registrar_movimiento`, las del monitor y el
-- trigger del libro mayor siguen revocadas, que es donde estaba el
-- peligro de verdad.
--
-- La alternativa era copiar el cuerpo de `fn_dimensionar_posicion` dentro
-- de `v_recomendaciones_usuario`: sesenta líneas de algoritmo de riesgo
-- duplicadas por TERCERA vez (ya vive en SQL y en Python). Un límite de
-- riesgo copiado tres veces es un límite que algún día dirá tres cosas
-- distintas.
-- ─────────────────────────────────────────────────────────────────────

-- Cálculo puro, sin acceso a tablas y sin SECURITY DEFINER.
grant execute on function public.fn_tope_fase(text)                to authenticated;
grant execute on function public.fn_piso_decimal(numeric)          to authenticated;
grant execute on function public.fn_mercado_abierto(timestamptz)   to authenticated;
grant execute on function public.fn_frescura_precio_min(text)      to authenticated;
grant execute on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
                                                                   to authenticated;

-- `anon` sigue sin nada: la 0009 se lo revocó por nombre y aquí no se le
-- concede. La invariante I22 lo comprueba en cada pasada.
revoke execute on function public.fn_tope_fase(text)               from anon;
revoke execute on function public.fn_piso_decimal(numeric)         from anon;
revoke execute on function public.fn_mercado_abierto(timestamptz)  from anon;
revoke execute on function public.fn_frescura_precio_min(text)     from anon;
revoke execute on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
                                                                   from anon;

comment on function public.fn_tope_fase(text) is
  'Pura: tope de apalancamiento de la fase. Concedida a authenticated porque v_cuentas_equity la usa con security_invoker. No toca tablas ni es SECURITY DEFINER.';
comment on function public.fn_dimensionar_posicion(
    numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) is
  'Pura: traduce riesgo en tamaño (doc 03 §5.3). Concedida a authenticated porque v_recomendaciones_usuario la usa con security_invoker. Gemela de motor-analitico/riesgo/dimensionado.py.';
