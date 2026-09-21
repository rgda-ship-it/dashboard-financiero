"""
Qué activos entran en una pasada del ETL, y por qué.

Lógica pura, sin red ni base de datos: recibe las filas de `activos` y
devuelve la decisión. Vive fuera de `etl.py` por el mismo criterio con el
que se separaron `riesgo/rotacion.py` y `ventana_mercado.py`: es la pieza
con reglas de verdad y tiene que poder probarse sin levantar nada.

Cuatro reglas, en este orden:

1. `invalido` nunca entra. Es terminal: el proveedor rechazó el símbolo y
   reintentarlo es cuota tirada.

2. BACKOFF. Un activo con `proximo_intento_en` en el futuro espera, sea
   cual sea su estado. Incluye a los `suspendido`: se reintentan cuando
   vence su espera, y una pasada buena los devuelve a `activo`.
   (Corrige un fallo del Sprint 1: la consulta solo pedía `activo` y
   `pendiente_backfill`, así que un activo suspendido no volvía nunca.)

3. FRESCURA. Si el activo se procesó hace menos de N minutos, se omite.
   Es lo que hace que una pasada repetida a mano, o un reintento de GitHub,
   no gaste cuota de CoinGecko en datos que ya están en la tabla.

   Sustituye a la regla que escribía la especificación original de H-09
   («si la vela de hoy ya está, no se llama al proveedor»), que era
   errónea: la vela del día se actualiza durante toda la sesión y el
   precio vivo sale de ella. Aplicada literalmente, habría congelado el
   precio del día tras la primera pasada — y el monitor de órdenes del
   Sprint 5 cierra posiciones con ese precio.

   La ventana es la MITAD de la cadencia del cron (30 min en acciones,
   60 en cripto). No puede acercarse a la cadencia entera: GitHub retrasa
   los cron programados a veces 10-15 minutos, y una pasada retrasada
   haría que la siguiente, puntual, cayera dentro de la ventana y se
   saltara. Con la mitad hay margen para ese retraso.

4. PRIORIDAD Y TOPE. Primero los activos con una posición abierta —un TP
   o un SL vigilándose no puede depender de un precio de hace horas—, que
   además ignoran la frescura y el tope. Después el resto, del más
   antiguo al más reciente, hasta completar el tope.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

FRESCURA_MINUTOS = {"accion": 15, "cripto": 30}


@dataclass
class Seleccion:
    procesar: list[dict] = field(default_factory=list)
    frescos: list[dict] = field(default_factory=list)
    en_espera: list[dict] = field(default_factory=list)
    fuera_de_tope: list[dict] = field(default_factory=list)


def _instante(valor) -> datetime | None:
    """PostgREST devuelve timestamptz como texto ISO; los tests, a veces
    como datetime. Se aceptan los dos, y un naive se lee como UTC."""
    if valor is None or valor == "":
        return None
    if isinstance(valor, datetime):
        instante = valor
    else:
        instante = datetime.fromisoformat(str(valor).replace("Z", "+00:00"))
    if instante.tzinfo is None:
        instante = instante.replace(tzinfo=timezone.utc)
    return instante


def seleccionar(
    candidatos: list[dict],
    ahora: datetime | None = None,
    ids_con_posicion: set[int] | frozenset[int] = frozenset(),
    tope: int | None = None,
    ignorar_frescura: bool = False,
    frescura: dict[str, int] | None = None,
) -> Seleccion:
    ahora = _instante(ahora) or datetime.now(timezone.utc)
    frescura = frescura or FRESCURA_MINUTOS
    resultado = Seleccion()

    prioritarios: list[dict] = []
    resto: list[dict] = []

    for activo in candidatos:
        if activo.get("estado") == "invalido":
            continue

        espera = _instante(activo.get("proximo_intento_en"))
        if espera is not None and espera > ahora:
            resultado.en_espera.append(activo)
            continue

        if activo.get("id") in ids_con_posicion:
            prioritarios.append(activo)
            continue

        ultimo = _instante(activo.get("ultimo_etl_en"))
        ventana = timedelta(minutes=frescura.get(activo.get("clase"), 0))
        if (
            not ignorar_frescura
            and activo.get("estado") != "pendiente_backfill"
            and ultimo is not None
            and ahora - ultimo < ventana
        ):
            resultado.frescos.append(activo)
            continue

        resto.append(activo)

    # Del más antiguo al más reciente; los que nunca se procesaron, primero.
    # El símbolo desempata para que el orden no dependa de la consulta.
    minimo = datetime.min.replace(tzinfo=timezone.utc)
    resto.sort(key=lambda a: (_instante(a.get("ultimo_etl_en")) or minimo, a.get("simbolo", "")))

    if tope is not None:
        hueco = max(0, tope - len(prioritarios))
        resultado.fuera_de_tope = resto[hueco:]
        resto = resto[:hueco]

    resultado.procesar = prioritarios + resto
    return resultado
