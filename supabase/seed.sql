-- ─────────────────────────────────────────────────────────────────────
-- Semilla del catálogo: el universo de la Fase 1, tal cual.
--
-- Estos 24 símbolos son exactamente los que hoy viven hardcodeados en
-- backend/src/routes/escaner.js como UNIVERSO_ACCIONES y UNIVERSO_CRIPTO.
-- Traerlos aquí es lo que permite retirar esas dos constantes en H-17:
-- pasan de ser código a ser datos, y a partir del Sprint 4 cada usuario
-- gestiona su propia lista.
--
-- Nacen en 'pendiente_backfill' a propósito: el ETL los rellena en su
-- primera pasada. Así la primera ejecución del pipeline se verifica
-- sobre el mismo universo que el dashboard local ya conoce, y cualquier
-- divergencia de cifras es una señal de alarma y no una duda.
-- ─────────────────────────────────────────────────────────────────────

insert into public.activos (simbolo, clase, proveedor, id_proveedor, nombre)
values
    -- ── Acciones y ETF (21) — vía yfinance, API NO oficial ──────────
    ('O',     'accion', 'yahoo', 'O',     'Realty Income'),
    ('QFIN',  'accion', 'yahoo', 'QFIN',  'Qifu Technology'),
    ('GM',    'accion', 'yahoo', 'GM',    'General Motors'),
    ('UAL',   'accion', 'yahoo', 'UAL',   'United Airlines'),
    ('BAC',   'accion', 'yahoo', 'BAC',   'Bank of America'),
    ('F',     'accion', 'yahoo', 'F',     'Ford Motor'),
    ('EWY',   'accion', 'yahoo', 'EWY',   'iShares MSCI South Korea ETF'),
    ('CLX',   'accion', 'yahoo', 'CLX',   'Clorox'),
    ('AMCR',  'accion', 'yahoo', 'AMCR',  'Amcor'),
    ('TROW',  'accion', 'yahoo', 'TROW',  'T. Rowe Price'),
    ('NLY',   'accion', 'yahoo', 'NLY',   'Annaly Capital Management'),
    ('KMB',   'accion', 'yahoo', 'KMB',   'Kimberly-Clark'),
    ('IBM',   'accion', 'yahoo', 'IBM',   'IBM'),
    ('WFC',   'accion', 'yahoo', 'WFC',   'Wells Fargo'),
    ('MO',    'accion', 'yahoo', 'MO',    'Altria Group'),
    ('SSTK',  'accion', 'yahoo', 'SSTK',  'Shutterstock'),
    ('HRL',   'accion', 'yahoo', 'HRL',   'Hormel Foods'),
    ('CSCO',  'accion', 'yahoo', 'CSCO',  'Cisco Systems'),
    ('AGNC',  'accion', 'yahoo', 'AGNC',  'AGNC Investment'),
    ('CCOI',  'accion', 'yahoo', 'CCOI',  'Cogent Communications'),
    ('FLO',   'accion', 'yahoo', 'FLO',   'Flowers Foods'),

    -- ── Cripto (3) — vía CoinGecko, tier gratuito sin clave ─────────
    -- `id_proveedor` sustituye al diccionario IDS_CRIPTO de
    -- servicio_interno.py. Cada moneda cuesta DOS llamadas por pasada
    -- (/market_chart para cierres y precio vivo, /ohlc a 4 h para
    -- máximos y mínimos), de ahí el techo de 20 criptos globales.
    ('bitcoin',  'cripto', 'coingecko', 'bitcoin',  'Bitcoin'),
    ('ethereum', 'cripto', 'coingecko', 'ethereum', 'Ethereum'),
    ('solana',   'cripto', 'coingecko', 'solana',   'Solana')
on conflict (simbolo) do nothing;
