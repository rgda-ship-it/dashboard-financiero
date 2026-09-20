import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from riesgo.rotacion import mejor_oportunidad_del_escaneo

# Las fixtures traen `indicadores_bajistas` explícito: el filtro pasó de
# "al menos 1 alcista" a "más alcistas que bajistas", así que el conteo
# bajista dejó de ser opcional para razonar sobre un candidato.
ESCANEO_EJEMPLO = [
    {"ticker": "TSLA", "fuerza": "baja", "indicadores_alcistas": 0, "indicadores_bajistas": 0,
     "resumen_confluencia": "x", "tp": 1, "sl": 1},
    {"ticker": "NVDA", "fuerza": "alta", "indicadores_alcistas": 4, "indicadores_bajistas": 0,
     "resumen_confluencia": "Confluencia alcista (4/5 indicadores)", "tp": 195.4, "sl": 178.2},
    {"ticker": "SOL", "fuerza": "media", "indicadores_alcistas": 2, "indicadores_bajistas": 0,
     "resumen_confluencia": "Confluencia alcista (2/5 indicadores)", "tp": 158.9, "sl": 142.1},
    {"ticker": "AAPL", "fuerza": "alta", "indicadores_alcistas": 5, "indicadores_bajistas": 0,
     "resumen_confluencia": "y", "tp": 300, "sl": 280},
]


def test_excluye_el_propio_ticker_en_deterioro():
    resultado = mejor_oportunidad_del_escaneo(ESCANEO_EJEMPLO, ticker_excluir="AAPL")
    assert resultado is not None
    assert resultado["ticker"] != "AAPL"
    assert resultado["ticker"] == "NVDA"  # segunda mejor tras excluir AAPL


def test_elige_la_mayor_confluencia_alcista():
    resultado = mejor_oportunidad_del_escaneo(ESCANEO_EJEMPLO, ticker_excluir="TSLA")
    assert resultado["ticker"] == "AAPL"  # 5 indicadores alcistas, la mejor


def test_sin_candidatos_alcistas_devuelve_none():
    escaneo = [{"ticker": "X", "fuerza": "baja", "indicadores_alcistas": 0,
                "indicadores_bajistas": 0, "resumen_confluencia": "", "tp": 0, "sl": 0}]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="Y")
    assert resultado is None


def test_ignora_tickers_con_error():
    escaneo = [
        {"ticker": "ERR", "error": "sin datos"},
        {"ticker": "NVDA", "fuerza": "alta", "indicadores_alcistas": 4,
         "indicadores_bajistas": 0, "resumen_confluencia": "x", "tp": 195.4, "sl": 178.2},
    ]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="ZZZ")
    assert resultado["ticker"] == "NVDA"


def test_output_no_incluye_monto_ni_datos_de_la_posicion_origen():
    resultado = mejor_oportunidad_del_escaneo(ESCANEO_EJEMPLO, ticker_excluir="AAPL")
    # Verificación explícita de la regla de diseño: el resultado solo trae
    # datos del activo DESTINO, nada que pueda haberse derivado del monto
    # invertido en la posición de origen (que ni siquiera se recibe aquí).
    claves_esperadas = {"ticker", "resumen_confluencia", "tp", "sl"}
    assert set(resultado.keys()) == claves_esperadas


def test_descarta_fuerza_alta_con_dominancia_bajista():
    # NVDA tiene fuerza "alta" y un indicador alcista, así que pasaba el
    # filtro viejo (alcistas > 0) pese a que su lectura dominante es
    # bajista: el sistema proponía rotar hacia un activo en deterioro.
    escaneo = [
        {"ticker": "NVDA", "fuerza": "alta", "indicadores_alcistas": 1,
         "indicadores_bajistas": 3, "resumen_confluencia": "Confluencia bajista (3/4)",
         "tp": 195.4, "sl": 178.2},
        {"ticker": "AAPL", "fuerza": "media", "indicadores_alcistas": 2,
         "indicadores_bajistas": 0, "resumen_confluencia": "Confluencia alcista (2/2)",
         "tp": 300, "sl": 280},
    ]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="TSLA")
    assert resultado["ticker"] == "AAPL"


def test_un_alcista_y_dos_bajistas_no_es_candidato():
    escaneo = [{"ticker": "X", "fuerza": "media", "indicadores_alcistas": 1,
                "indicadores_bajistas": 2, "resumen_confluencia": "z", "tp": 10, "sl": 5}]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="Y")
    assert resultado is None


def test_el_empate_no_es_candidato():
    # Aquí se compromete capital NUEVO: el empate excluye. (En
    # salud_posicion.py, con capital ya expuesto, el empate mantiene la
    # vigilancia — la asimetría es deliberada.)
    escaneo = [{"ticker": "X", "fuerza": "media", "indicadores_alcistas": 2,
                "indicadores_bajistas": 2, "resumen_confluencia": "z", "tp": 10, "sl": 5}]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="Y")
    assert resultado is None


def test_gana_la_mayor_dominancia_neta():
    escaneo = [
        {"ticker": "AAPL", "fuerza": "media", "indicadores_alcistas": 2,
         "indicadores_bajistas": 1, "senales": [1, 2, 3],
         "resumen_confluencia": "a", "tp": 300, "sl": 280},
        {"ticker": "ethereum", "fuerza": "media", "indicadores_alcistas": 2,
         "indicadores_bajistas": 0, "senales": [1, 2],
         "resumen_confluencia": "b", "tp": 4200, "sl": 3800},
    ]
    resultado = mejor_oportunidad_del_escaneo(escaneo, ticker_excluir="TSLA")
    assert resultado["ticker"] == "ethereum"  # dominancia neta 2 vs 1


ESCANEO_EMPATE_DE_DOMINANCIA = [
    {"ticker": "AAPL", "fuerza": "media", "indicadores_alcistas": 2,
     "indicadores_bajistas": 0, "senales": [1, 2, 3],
     "resumen_confluencia": "a", "tp": 300, "sl": 280},
    {"ticker": "ethereum", "fuerza": "media", "indicadores_alcistas": 2,
     "indicadores_bajistas": 0, "senales": [1, 2],
     "resumen_confluencia": "b", "tp": 4200, "sl": 3800},
]


def test_desempata_por_proporcion_de_senales_alineadas():
    # Misma dominancia y misma fuerza: gana la cripto con 2 de 2 señales
    # alineadas (1,00) frente a la acción con 2 de 3 (0,67). Corrige la
    # asimetría de datos acciones/cripto sin tocar la definición de fuerza.
    resultado = mejor_oportunidad_del_escaneo(
        ESCANEO_EMPATE_DE_DOMINANCIA, ticker_excluir="TSLA"
    )
    assert resultado["ticker"] == "ethereum"


def test_el_orden_de_la_lista_no_influye():
    # El backend envía siempre las acciones primero, y max() devolvía el
    # primer máximo: la cripto mejor alineada nunca podía ganar un empate.
    resultado = mejor_oportunidad_del_escaneo(
        list(reversed(ESCANEO_EMPATE_DE_DOMINANCIA)), ticker_excluir="TSLA"
    )
    assert resultado["ticker"] == "ethereum"


def test_tp_y_sl_del_destino_nunca_son_nulos():
    # Por construcción: solo entran candidatos con dominancia alcista, es
    # decir sesgo operativo "largo", que es el único caso en el que el
    # motor asigna roles operativos a los niveles técnicos.
    for excluir in ("TSLA", "AAPL", "ZZZ"):
        resultado = mejor_oportunidad_del_escaneo(ESCANEO_EJEMPLO, ticker_excluir=excluir)
        if resultado is None:
            continue
        assert resultado["tp"] is not None
        assert resultado["sl"] is not None


if __name__ == "__main__":
    tests = [
        test_excluye_el_propio_ticker_en_deterioro,
        test_elige_la_mayor_confluencia_alcista,
        test_sin_candidatos_alcistas_devuelve_none,
        test_ignora_tickers_con_error,
        test_output_no_incluye_monto_ni_datos_de_la_posicion_origen,
        test_descarta_fuerza_alta_con_dominancia_bajista,
        test_un_alcista_y_dos_bajistas_no_es_candidato,
        test_el_empate_no_es_candidato,
        test_gana_la_mayor_dominancia_neta,
        test_desempata_por_proporcion_de_senales_alineadas,
        test_el_orden_de_la_lista_no_influye,
        test_tp_y_sl_del_destino_nunca_son_nulos,
    ]
    for t in tests:
        try:
            t()
            print(f"PASS  {t.__name__}")
        except AssertionError as e:
            print(f"FAIL  {t.__name__}: {e}")
