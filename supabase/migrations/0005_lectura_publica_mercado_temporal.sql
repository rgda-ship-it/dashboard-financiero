-- ─────────────────────────────────────────────────────────────────────
-- 0005 — Lectura pública de DATOS DE MERCADO, temporal hasta H-14.
--
-- DECISIÓN DEL DUEÑO, 2026-09-21. Al corregir en 0004 las vistas que se
-- saltaban la RLS, el escáner de la web pública se habría quedado vacío
-- hasta el Sprint 3. El dueño prefiere mantenerlo visible mientras tanto.
--
-- La diferencia con lo que había antes de 0004 es la que importa: antes
-- los datos salían por un agujero que nadie había decidido abrir; ahora
-- salen por una política EXPLÍCITA, con nombre, limitada a cuatro
-- tablas y con fecha de caducidad escrita.
--
-- ALCANCE: solo datos de mercado, que son precios públicos que
-- cualquiera puede consultar en Yahoo o CoinGecko. NUNCA:
--   · cartera_posiciones        (datos del usuario)
--   · registro_consentimiento   (audit trail del usuario)
--   · eventos_sistema           (puede llevar datos por usuario)
-- La invariante I14 falla la CI si alguna política pública aparece en
-- una tabla que no esté en la lista de mercado.
--
-- CADUCIDAD: H-14 (Sprint 3) BORRA estas cuatro políticas y las sustituye
-- por las basadas en es_usuario_aprobado(). Todas llevan el sufijo
-- `_temporal_h14` para que no se puedan pasar por alto.
-- ─────────────────────────────────────────────────────────────────────

create policy activos_lectura_publica_temporal_h14
  on public.activos for select to anon, authenticated using (true);

create policy senales_lectura_publica_temporal_h14
  on public.senales for select to anon, authenticated using (true);

create policy precios_lectura_publica_temporal_h14
  on public.precios_diarios for select to anon, authenticated using (true);

create policy indicadores_lectura_publica_temporal_h14
  on public.indicadores_diarios for select to anon, authenticated using (true);
