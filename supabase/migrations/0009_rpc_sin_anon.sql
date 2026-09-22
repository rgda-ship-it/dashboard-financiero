-- ─────────────────────────────────────────────────────────────────────
-- 0009 — Los RPC de administración no son ejecutables por `anon`.
--
-- Detectado al verificar el Sprint 3 en producción (2026-09-22): con la
-- clave pública sola, `rpc_aprobar_usuario` SE EJECUTABA y era su propia
-- comprobación interna (es_admin()) la que respondía «Solo un
-- administrador…». Sin daño, pero la primera línea de defensa faltaba.
--
-- Motivo: 0007 hizo `revoke execute … from public`, y Supabase no concede
-- EXECUTE a `anon` a través de PUBLIC sino DIRECTAMENTE, con sus
-- privilegios por defecto. Hay que revocarlo por nombre. La invariante
-- I22 lo fija para cualquier función futura con prefijo rpc_ o fn_.
-- ─────────────────────────────────────────────────────────────────────

revoke execute on function public.rpc_aprobar_usuario(uuid)                          from anon;
revoke execute on function public.rpc_rechazar_usuario(uuid, text)                   from anon;
revoke execute on function public.rpc_suspender_usuario(uuid, text)                  from anon;
revoke execute on function public.fn_cambiar_estado_usuario(uuid, text, text, text)  from anon, authenticated;
revoke execute on function public.fn_alta_perfil()                                   from anon, authenticated;
revoke execute on function public.fn_promover_admin_inicial()                        from anon, authenticated;
revoke execute on function public.fn_retencion_senales()                             from public, anon, authenticated;
revoke execute on function public.fn_email_admin_inicial()                           from public, anon, authenticated;
-- service_role (keep-alive y ETL) conserva su concesión directa.

-- Y para las que vengan: ninguna función nueva de public será ejecutable
-- por `anon` salvo que se conceda explícitamente.
alter default privileges in schema public revoke execute on functions from anon;
