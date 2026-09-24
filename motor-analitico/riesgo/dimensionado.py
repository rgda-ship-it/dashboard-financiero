"""
Dimensionado de posición: cuántas unidades comprar.

Pieza NUEVA de la Fase 2. La Fase 1 calculaba apalancamiento y niveles
(`riesgo/apalancamiento.py`) pero nunca el tamaño, y no le hacía falta
porque no operaba. Vive aquí y no en `servicio_interno.py` por la misma
regla de ubicación que separó `riesgo/rotacion.py`: esto es lógica de
negocio pura, testeable sin levantar nada.

LO QUE HAY QUE ENTENDER ANTES DE TOCAR ESTE FICHERO

El tamaño no se elige: se DEDUCE de cuánto se está dispuesto a perder.
Con un riesgo del 2 % sobre 1.000 $ y un stop al 10 % por debajo de la
entrada, el nominal tiene que ser 200 $ para que tocar el stop cueste
exactamente 20 $. Ese es todo el cálculo. El resto son topes.

Y hay un tercer nivel que nadie declara: el precio al que el margen se
agota. A 5x, una caída del 20 % liquida la posición. Si el stop está a un
25 % por debajo —perfectamente posible con un activo volátil y niveles de
origen `atr`— la posición se liquida ANTES de tocar el stop y la pérdida
real es el 100 % del margen en vez del 2 % del equity que se creía
arriesgar. El paso 6 baja el apalancamiento hasta que la liquidación queda
por debajo del stop, en vez de aceptar una operación cuyo riesgo real no es
el declarado. Es la regla N4 y es coherente con la regla protegida nº4 de
la Fase 1: ante ambigüedad de riesgo, se degrada hacia el mínimo.

GEMELO EN SQL

`public.fn_dimensionar_posicion` (migración 0011) hace exactamente esto.
Existe en los dos sitios a propósito: el servidor no puede fiarse de un
tamaño que venga del cliente —sería saltarse los guardarraíles G2 y G3
escribiendo un número— y el ciclo de agentes necesita simular tamaños en
Python antes de decidir a qué candidato entra. Los mismos casos se
verifican de los dos lados: `pruebas/test_dimensionado.py` aquí y la
invariante I33 allí. Si se cambia una fórmula, se cambian las dos.

DESVIACIÓN ANOTADA respecto al pseudocódigo del doc 03 §5.3: su paso 6
termina con `margen := nominal / apalancamiento`, que descarta los topes
que el paso 5 acababa de aplicar. Bajar el apalancamiento SUBE el margen
necesario, así que tal cual está escrito puede devolver un margen por
encima del saldo o del tope de G3. Aquí los topes se vuelven a aplicar
después del paso 6: son límites duros, y el orden en que se escribió el
pseudocódigo no los convierte en sugerencias.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import ROUND_DOWN, ROUND_FLOOR, Decimal

# Margen mínimo con el que merece la pena abrir algo (doc 03 §5.5). Por
# debajo de esto la cuenta es `inoperante`, que no es lo mismo que muerta.
MARGEN_MINIMO = Decimal("10")

# El apalancamiento se almacena en `numeric(4,1)`: un decimal y no más.
PASO_APALANCAMIENTO = Decimal("0.1")

# Se deja un 5 % del saldo disponible sin comprometer. No es superstición:
# el precio de entrada que confirma el usuario puede diferir del de la
# señal, y un margen calculado al céntimo del saldo fallaría el CHECK.
FRACCION_SALDO_UTILIZABLE = Decimal("0.95")


class SinOperacion(Exception):
    """El dimensionado no encuadra ninguna operación.

    Es un resultado legítimo, no un fallo: significa que con este stop,
    este saldo y este riesgo no hay tamaño que respete los límites. El
    ciclo del agente lo registra como descarte y sigue con el candidato
    siguiente.
    """

    def __init__(self, motivo: str) -> None:
        super().__init__(motivo)
        self.motivo = motivo


@dataclass(frozen=True)
class Dimension:
    """Lo que hay que escribir en `ordenes` para abrir la posición."""

    cantidad: Decimal
    apalancamiento: Decimal
    margen: Decimal
    precio_liquidacion: Decimal
    # `True` cuando el paso 6 tuvo que bajar el apalancamiento. La interfaz
    # lo dice al usuario: es la diferencia entre «el sistema decidió» y «el
    # sistema me cambió los números sin avisar».
    apalancamiento_reducido: bool = False

    @property
    def nominal(self) -> Decimal:
        return self.margen * self.apalancamiento


def _dec(valor) -> Decimal:
    """Todo entra por aquí. Nunca se construye un Decimal desde un float
    sin pasar por str: `Decimal(0.1)` son 0,1000000000000000055511151231…
    y eso, sumado cien veces, descuadra un libro mayor."""
    if isinstance(valor, Decimal):
        return valor
    return Decimal(str(valor))


def piso_a_un_decimal(valor: Decimal) -> Decimal:
    """Suelo, no redondeo. Redondear hacia arriba el apalancamiento
    ajustado volvería a poner la liquidación por encima del stop, que es
    justo lo que el ajuste está evitando."""
    return valor.quantize(PASO_APALANCAMIENTO, rounding=ROUND_FLOOR)


def precio_de_liquidacion(precio: Decimal, apalancamiento: Decimal) -> Decimal:
    """Precio al que el margen se agota en una posición larga.

    A 1x no hay liquidación posible (el margen es el nominal entero), y la
    fórmula lo refleja sola: devuelve 0.
    """
    return _dec(precio) * (Decimal(1) - Decimal(1) / _dec(apalancamiento))


def dimensionar_posicion(
    *,
    equity: Decimal | float | str,
    saldo_disponible: Decimal | float | str,
    saldo_bloqueado: Decimal | float | str,
    precio: Decimal | float | str,
    sl: Decimal | float | str,
    riesgo_pct: Decimal | float | str,
    margen_comprometido_max_pct: Decimal | float | str = Decimal("60"),
    leverage_recomendado: Decimal | float | str | None = None,
    apalancamiento_maximo_propio: Decimal | float | str | None = None,
    tope_fase: Decimal | float | str = Decimal("5"),
) -> Dimension:
    """Traduce «cuánto estoy dispuesto a perder» en «cuántas unidades».

    Los argumentos son de palabra clave a propósito: son diez números del
    mismo tipo y una llamada posicional sería una invitación a cruzar dos.

    Lanza `SinOperacion` cuando no hay tamaño posible. Los motivos son los
    mismos textos que devuelve `fn_dimensionar_posicion` en SQL, para que
    un descarte se lea igual venga de donde venga.
    """
    equity = _dec(equity)
    saldo_disponible = _dec(saldo_disponible)
    saldo_bloqueado = _dec(saldo_bloqueado)
    precio = _dec(precio)
    sl = _dec(sl)
    riesgo_pct = _dec(riesgo_pct)
    margen_max_pct = _dec(margen_comprometido_max_pct)
    tope_fase = _dec(tope_fase)

    if precio <= 0:
        raise SinOperacion("precio_no_valido")
    if equity <= 0:
        raise SinOperacion("equity_agotado")

    # 1. Cuánto estoy dispuesto a PERDER en esta operación.
    riesgo_max = equity * riesgo_pct / Decimal(100)

    # 2. Distancia relativa al stop: es lo que convierte riesgo en tamaño.
    distancia_sl = (precio - sl) / precio
    if distancia_sl <= 0:
        raise SinOperacion("stop_por_encima_del_precio")

    # 3. Nominal que hace que tocar el SL cueste exactamente riesgo_max.
    nominal = riesgo_max / distancia_sl

    # 4. Tres topes de apalancamiento; el de la fase manda (G1).
    candidatos = [tope_fase]
    if leverage_recomendado is not None:
        candidatos.append(_dec(leverage_recomendado))
    if apalancamiento_maximo_propio is not None:
        candidatos.append(_dec(apalancamiento_maximo_propio))
    apalancamiento = min(candidatos)
    if apalancamiento < 1:
        raise SinOperacion("apalancamiento_bajo_uno")

    # 6. La liquidación puede llegar ANTES que el stop (regla N4).
    reducido = False
    liquidacion = precio_de_liquidacion(precio, apalancamiento)
    if liquidacion > sl:
        apalancamiento = piso_a_un_decimal(Decimal(1) / distancia_sl) - PASO_APALANCAMIENTO
        if apalancamiento < 1:
            raise SinOperacion("sin_operacion_liquidacion_antes_del_stop")
        reducido = True
        liquidacion = precio_de_liquidacion(precio, apalancamiento)

    # 5. Topes por saldo y por margen total comprometido (G3). Después del
    #    paso 6, no antes: ver la desviación anotada en el docstring.
    margen_libre = equity * margen_max_pct / Decimal(100) - saldo_bloqueado
    margen = min(
        nominal / apalancamiento,
        saldo_disponible * FRACCION_SALDO_UTILIZABLE,
        margen_libre,
    )
    # Céntimos hacia abajo: hacia arriba pediría un céntimo más de margen
    # del que hay y el CHECK de la base de datos abortaría el INSERT.
    margen = margen.quantize(Decimal("0.01"), rounding=ROUND_DOWN)
    if margen <= 0:
        raise SinOperacion("margen_insuficiente")

    cantidad = (margen * apalancamiento / precio).quantize(
        Decimal("0.00000001"), rounding=ROUND_DOWN
    )
    if cantidad <= 0:
        raise SinOperacion("cantidad_nula")

    return Dimension(
        cantidad=cantidad,
        apalancamiento=apalancamiento,
        margen=margen,
        precio_liquidacion=liquidacion,
        apalancamiento_reducido=reducido,
    )


def riesgo_real(dimension: Dimension, precio: Decimal | float | str, sl: Decimal | float | str) -> Decimal:
    """Lo que cuesta de verdad tocar el stop con este tamaño.

    Existe como función y no como comentario porque es la comprobación que
    convierte el cálculo en una afirmación verificable: después de todos
    los topes, el riesgo real nunca debe superar el declarado.
    """
    return dimension.cantidad * (_dec(precio) - _dec(sl))
