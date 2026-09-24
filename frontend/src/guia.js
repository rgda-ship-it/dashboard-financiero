/**
 * Contenido de la guía de lectura.
 *
 * Vive separado del componente a propósito: es texto que se corrige y se
 * amplía a menudo, y no debería obligar a tocar JSX. Cada fórmula está
 * transcrita del código real —`indicadores/tecnicos.py`,
 * `riesgo/apalancamiento.py`, `riesgo/salud_posicion.py`,
 * `riesgo/rotacion.py` y `backend/src/routes/portfolio.js`—; si alguna de
 * esas reglas cambia, este archivo cambia con ella.
 */

export const SECCIONES = [
  {
    id: "escaner",
    titulo: "Escáner de mercado",
    resumen: "Qué mira el motor en cada activo, columna por columna.",
    items: [
      {
        termino: "Activo",
        formula: null,
        lectura:
          "EQ es una acción (Yahoo Finance) y CRP una cripto (CoinGecko). Debajo del ticker va el último cierre disponible, siempre en USD.",
      },
      {
        termino: "Confluencia",
        formula:
          "dominante = máx(indicadores alcistas, indicadores bajistas)\n\nalta   → dominante ≥ 3\nmedia  → dominante = 2\nbaja   → el resto (incluido 0)",
        lectura:
          "La flecha da la dirección; los tres segmentos, cuántos indicadores la sostienen. El motor nunca dispara por un indicador aislado: «baja» significa señal no confirmada, no que el activo vaya a caer. Despliega la fila para ver qué indicador aporta qué.",
        nota: "La dirección ya no solo colorea la fila: determina si el motor la encuadra como operación y, por tanto, si emite apalancamiento y niveles con rol. Ver «Sesgo operativo».",
      },
      {
        termino: "Sesgo operativo",
        formula:
          "alcistas > bajistas  → largo      · el motor sí encuadra operación\nalcistas < bajistas  → corto      · no encuadra\nalcistas = bajistas  → sin sesgo  · no encuadra",
        lectura:
          "Es la diferencia entre lo que dice el mercado y lo que el sistema está dispuesto a dimensionar. Este terminal solo encuadra operaciones en largo: no modela coste de préstamo ni funding, y la máquina de fases razona sobre capital comprometido en una sola dirección. Por eso, fuera del sesgo largo, no emite apalancamiento operable ni asigna roles de stop y objetivo — las filas siguen mostrando su estructura de precio, pero sin disfraz de orden.",
        nota: "«Corto» NO es una sugerencia de vender en corto, ni existe un setup de corto calculado: es la constatación de que la lectura dominante es bajista y de que el sistema no la dimensiona. Si operas en corto, lo haces por tu cuenta y la referencia de volatilidad es lo único que el motor aporta.",
      },
      {
        termino: "Los cuatro indicadores",
        formula:
          "Cruce de medias  · SMA 50 > SMA 200 → alcista;  < → bajista\nRSI (14)         · < 30 → alcista (sobreventa);  > 70 → bajista\nMACD (12,26,9)   · histograma > 0 → alcista;  ≤ 0 → bajista\nVolumen relativo · volumen / media de 20 sesiones",
        lectura:
          "Un RSI entre 30 y 70 no aporta señal: no cuenta ni a favor ni en contra. El volumen es el único que no vota — solo entra si supera 1.5× su media y solo para confirmar la dirección que ya domina, nunca para decidirla ni para desempatar.",
      },
      {
        termino: "Volatilidad (ATR %)",
        formula: "ATR(14) / precio actual × 100\n\nalta ≥ 6 %   ·   media 3–6 %   ·   baja < 3 %",
        lectura:
          "Cuánto se mueve el activo en un día típico, en porcentaje de su precio. Es el dato que más pesa en el apalancamiento: por eso está junto a él y no escondido en el detalle.",
      },
      {
        termino: "Apalancamiento",
        formula:
          "base = 1.0×  si ATR % ≥ 6\n       2.0×  si ATR % ≥ 3\n       3.0×  si ATR % < 3\n\nSolo con sesgo largo:\n  ajuste = +2.0× alta · +1.0× media · +0.0× baja\n  recomendado = mín(base + ajuste, tope duro), nunca < 1.0×\n\nCon sesgo corto o sin sesgo:\n  recomendado = ninguno\n  referencia de volatilidad = base",
        lectura:
          "La volatilidad manda sobre la señal: una confluencia alta sobre un activo muy volátil sigue dando poco apalancamiento. El remache de latón al final de la barra es el tope duro del sistema (5× en Fase 1, 3× en Fase 2) — el mín() del motor garantiza que la barra no lo cruce nunca, venga la señal que venga.",
        nota: "Si la fila no es operable no verás una cifra recomendada, sino la referencia de volatilidad en gris: la base sin el bonus de confluencia. El bonus premia que los indicadores estén alineados con la operación implícita, así que aplicarlo a una lectura bajista sería premiar la convicción y apuntarla en la dirección contraria. Una fila también puede quedar no operable si el proveedor no dio volatilidad utilizable.",
      },
      {
        termino: "Riesgo / objetivo (SL – TP · Sop. – Res.)",
        formula:
          "soporte     = mínimo de los últimos 20 mínimos\nresistencia = máximo de los últimos 20 máximos\n\nSi la ventana no describe estructura\n(resistencia − soporte < ATR, o ≤ 0):\n  soporte     = precio − 2 × ATR\n  resistencia = precio + 2 × ATR\n\nSolo con sesgo largo:\n  SL = soporte   ·   TP = resistencia",
        lectura:
          "Los mismos dos números tienen dos lecturas. Con sesgo largo llevan rol: SL en rojo es lo que se pierde, TP en verde lo que se busca. Sin sesgo largo aparecen en gris como «Sop.» y «Res.» — estructura de precio, válida en cualquier dirección, pero sin ninguna operación propuesta detrás. El punto es el precio actual entre ambos: pegado a la resistencia queda poco recorrido al alza; pegado al soporte, casi todo el rango está por debajo.",
        nota: "Nunca se invierten los roles para una lectura bajista. Emitir un SL arriba y un TP abajo sería entregar un setup de corto completo justo después de negarse a apalancarlo, y sin modelar el coste de mantener un corto eso sería engañoso. El detalle de la fila indica si los niveles vienen de la estructura o del fallback por ATR.",
      },
    ],
  },

  {
    id: "kpis",
    titulo: "Las cuatro cifras de arriba",
    resumen: "Resumen del estado del sistema. No dispara ninguna consulta extra.",
    items: [
      {
        termino: "Universo escaneado",
        formula: "activos con datos / total del universo",
        lectura:
          "El hueco son tickers que el proveedor no devolvió en este ciclo (típicamente un 429 de CoinGecko). Aparecen igualmente en la tabla, al final y con su motivo.",
      },
      {
        termino: "Confluencia alta",
        formula: "activos con fuerza «alta» / activos con datos",
        lectura:
          "Hacen falta tres o más indicadores alineados en la misma dirección. Desde que acciones y cripto disponen de los cuatro indicadores, «alta» dejó de ser excepcional: en un mercado tranquilo y direccional, varios activos pueden alcanzarla a la vez, y con volatilidad baja eso son filas en el tope de 5.0×.",
        nota: "Que suba este número no significa que el mercado mejore: significa que más activos tienen sus indicadores de acuerdo. Conviene mirarlo junto a la volatilidad, porque son las dos entradas del apalancamiento y la volatilidad pesa más.",
      },
      {
        termino: "Apalancamiento medio",
        formula: "media de los recomendados de las señales OPERABLES",
        lectura:
          "Solo entran las filas con sesgo largo: las bajistas y las neutrales no tienen cifra recomendada, así que no ensucian la media. El subtítulo dice cuántas son sobre el total con datos — si esa proporción es baja, el universo está mayoritariamente sin operación encuadrada, que es información en sí misma. Comparado contra el tope duro: acercarse al tope describe un mercado poco volátil con señales alineadas, no es una invitación a usarlo.",
      },
      {
        termino: "P&L de cartera",
        formula: "suma de los P&L absolutos de las posiciones cargadas",
        lectura: "Solo se llena tras cargar o restaurar una cartera, y se calcula íntegramente en tu equipo.",
      },
    ],
  },

  {
    id: "cartera",
    titulo: "Diagnóstico de cartera",
    resumen: "Modo diagnóstico: informa sobre lo que ya tienes, no dimensiona operaciones.",
    items: [
      {
        termino: "P&L",
        formula:
          "P&L % = (precio actual − precio de compra) / precio de compra × 100\nP&L $ = monto × P&L % / 100",
        lectura:
          "El monto invertido se usa exclusivamente en esta resta y nunca sale de tu equipo: no viaja al motor analítico ni participa en la sugerencia de rotación. Es una regla del diseño del sistema, no una casualidad.",
      },
      {
        termino: "Salud de la posición",
        formula:
          "bajistas    = indicadores bajistas, pero solo si igualan\n              o superan a los alcistas; si no, 0\nfundamental = EPS actual < 0   (solo acciones)\n\nDeterioro (rojo)  → bajistas ≥ 2  Y  fundamental\nVigilar (ámbar)   → bajistas ≥ 1  O  fundamental\nSaludable (verde) → ninguno de los dos",
        lectura:
          "Usa exactamente la misma confluencia que el escáner general: no existe una lógica paralela para tu cartera. Un bajista suelto dentro de una lectura dominante alcista ya no cuenta como deterioro. El rojo es deliberadamente difícil de alcanzar — exige deterioro técnico y fundamental a la vez.",
        nota: "Dos matices. El empate sí mantiene la vigilancia, a diferencia de la rotación, que lo descarta: aquí hay capital ya expuesto y allí se comprometería capital nuevo. Y no se guardan los fundamentales del día de compra, así que la parte fundamental solo comprueba el estado actual (EPS negativo), no su caída desde que compraste — un EPS negativo deja la posición en ámbar por sí solo, por muy alcista que sea la lectura técnica.",
      },
      {
        termino: "Rotación sugerida",
        formula:
          "Se propone solo si la salud es «rojo».\n\ncandidatos = activos del último escaneo\n             ≠ el activo deteriorado\n             con fuerza media o alta\n             y MÁS alcistas que bajistas\n\nelegido, por orden:\n  1. mayor dominancia neta (alcistas − bajistas)\n  2. mayor fuerza\n  3. mayor proporción de indicadores alineados\n  4. ticker alfabético\n\nsin candidatos → sin sugerencia",
        lectura:
          "El TP y el SL que ves son los que el escáner ya había calculado para ese activo, sin recalcular nada con tu monto ni con tu precio de entrada. Es una alternativa mejor posicionada hoy, no una orden ni un tamaño de posición.",
        nota: "Exigir dominancia alcista —y no «al menos un indicador alcista»— evita que un aviso de riesgo se convierta en riesgo nuevo. Si ningún activo la cumple no se relaja el criterio: no hay sugerencia, y esa es la respuesta correcta. El desempate por proporción corrige además un sesgo antiguo por el que una cripto nunca podía ganarle a una acción aunque tuviera todos sus indicadores disponibles alineados.",
      },
    ],
  },

  {
    id: "eventos",
    titulo: "Registro del sistema",
    resumen: "Lo que ocurre en tiempo real, según el color del punto.",
    items: [
      {
        termino: "Tipos de evento",
        formula:
          "cian   · sistema (estado del stream)\námbar  · proveedor de datos (reintentos, 429)\nlatón  · cambio de fase de riesgo\nrojo   · deterioro detectado en una posición",
        lectura:
          "Se conservan los últimos 50 eventos en este navegador, así que sobreviven a una recarga. No viajan a ningún servidor: son avisos del sistema, no datos de cartera. El botón «Limpiar» del pie vacía ese historial.",
      },
      {
        termino: "Fases de riesgo",
        formula:
          "Fase 1 · Aceleración    → tope duro 5×\nFase 2 · Consolidación  → tope duro 3×\n\n1 → 2 : el primer criterio que se cumpla entre\n        3× el capital inicial,\n        −30 % de caída desde el pico alcanzado,\n        u 8 operaciones cerradas.\n2 → 1 : solo por acción manual explícita.",
        lectura:
          "La caída se mide desde el máximo alcanzado, nunca desde el capital inicial. La vuelta a Fase 1 jamás ocurre de forma automática: el sistema puede bajarte el techo de riesgo solo, pero no subírtelo.",
      },
    ],
  },

  {
    id: "plantilla",
    tipo: "plantilla",
    titulo: "Plantilla de cartera (CSV)",
    resumen: "Las tres columnas que el backend acepta y el formato numérico que espera.",
  },

  {
    id: "simulador",
    titulo: "Simulador",
    resumen: "De dónde sale el tamaño de una posición y por qué el saldo no se puede editar.",
    items: [
      {
        termino: "El saldo es derivado",
        formula:
          "saldo_disponible = saldo_inicial + suma de los apuntes del libro mayor\n\nequity = disponible + bloqueado + P&L flotante",
        lectura:
          "El número que ves arriba no está guardado en ninguna parte como número: es la suma del libro mayor, que aparece entero al final de la pantalla. Cada operación deja tres apuntes —bloqueo del margen, liberación del margen y resultado— y ninguno se puede editar ni borrar, tampoco desde el servidor. El equity, en cambio, no se guarda nunca: depende del precio de este instante, así que se calcula al leerlo.",
        nota: "Una consulta de la integración continua comprueba en cada cambio que el saldo de toda cuenta se reconstruye sumando sus apuntes. Si alguna vez no cuadrara, el despliegue no sale.",
      },
      {
        termino: "El tamaño sale del riesgo, no del saldo",
        formula:
          "riesgo_max = equity × riesgo por operación %\ndistancia al stop = (precio − stop) / precio\nnominal = riesgo_max / distancia al stop\nmargen = nominal / apalancamiento\ncantidad = margen × apalancamiento / precio",
        lectura:
          "No se elige cuánto comprar: se elige cuánto se está dispuesto a perder, y el tamaño se deduce. Con 1.000 $ de equity, un 2 % de riesgo y un stop un 10 % por debajo, el nominal tiene que ser 200 $ para que tocar el stop cueste exactamente 20 $. Ese es todo el cálculo; lo demás son topes.",
      },
      {
        termino: "Precio de liquidación",
        formula: "precio_liquidacion = precio de entrada × (1 − 1 / apalancamiento)",
        lectura:
          "Es el tercer nivel, el que nadie declara: el precio al que el margen se agota. A 5× basta una caída del 20 %. Si tu stop estuviera más abajo que ese punto, la posición se liquidaría ANTES de tocarlo y la pérdida real sería el margen entero en vez del riesgo declarado. Cuando eso pasa, el sistema BAJA el apalancamiento hasta que la liquidación queda por debajo del stop; y si ni a 1× cabe, no ofrece la operación.",
        nota: "Va en latón, como el tope de apalancamiento: es un límite que el sistema impone, no una decisión tuya.",
      },
      {
        termino: "Los cinco límites del servidor",
        formula:
          "1 · apalancamiento ≤ tope de la fase (5× en Fase 1, 3× en Fase 2)\n2 · riesgo por operación ≤ 10 % del equity\n3 · margen comprometido total ≤ 60 % del equity\n4 · posiciones abiertas ≤ máximo de la cuenta\n5 · solo señales operables y de menos de 90 minutos",
        lectura:
          "Los impone PostgreSQL, no esta pantalla. Da lo mismo desde dónde llegue la petición —el navegador, un script, un agente del Sprint 6 con un fallo—: una orden que cruce cualquiera de los cinco se rechaza con el motivo escrito. Que el límite viva en el navegador sería no tener límite.",
      },
      {
        termino: "Tú ajustas la entrada, no los niveles",
        formula: null,
        lectura:
          "Al confirmar una orden puedes cambiar el precio de entrada y la fecha —también una fecha pasada, si registras algo que hiciste antes—. El stop y el objetivo son del motor y no se editan: moverlos convertiría el simulador en una hoja de cálculo de colores. Si tu entrada se sale del rango entre stop y objetivo, no hay operación que registrar.",
        nota: "El tamaño y el margen se recalculan en el servidor con el precio que confirmes, así que pueden diferir de la sugerencia.",
      },
      {
        termino: "Quién cierra las posiciones",
        formula:
          "cada minuto, por cada posición abierta con precio de menos de 15 min:\n  si precio ≤ liquidación  → cierra por LIQUIDACIÓN\n  si no, si precio ≤ stop   → cierra por STOP\n  si no, si precio ≥ objetivo → cierra por OBJETIVO",
        lectura:
          "Un proceso dentro de la base de datos, cada minuto, sin que nadie mire la pantalla. El orden no es casual: con un solo precio no se puede saber si en ese minuto se tocó primero el objetivo o el stop, así que ante la duda gana siempre el lado conservador. Y la liquidación se evalúa antes que el stop porque a 5× puede llegar primero.",
      },
      {
        termino: "Se cierra al nivel, no al precio observado",
        formula: null,
        lectura:
          "Si el precio se desploma un 3 % por debajo de tu stop entre dos pasadas, la operación se registra AL STOP, no a ese precio. Premiar o castigar por ese hueco sería simular una ejecución que el sistema no modela. El precio que disparó el cierre se guarda aparte, en la columna «observado» del histórico: la diferencia entre las dos cifras es el deslizamiento, y está ahí para poder medirlo el día que se modele.",
      },
      {
        termino: "Un precio añejo no cierra nada",
        formula: "cripto: > 15 min · acción: > 35 min o bolsa cerrada",
        lectura:
          "Un precio del viernes por la tarde congelado en la tabla cerraría posiciones todo el fin de semana contra un mercado que no existe. Así que sin precio fresco no se evalúa —ni el proceso automático ni el botón de cerrar a mano—. Para cripto el precio se refresca cada minuto mientras tengas algo abierto; para acciones lo escribe el escaneo cada media hora y solo se evalúan con Nueva York abierta.",
      },
      {
        termino: "Fases y Game Over",
        formula:
          "Fase 1 → Fase 2 con el PRIMER criterio que se cumpla:\n  · caída del 30 % desde el máximo alcanzado\n  · capital × 3 sobre el inicial\n  · 8 operaciones cerradas en Fase 1\n\nGame Over: equity ≤ 0     ·     Inoperante: equity < 10 $ sin posiciones",
        lectura:
          "La caída se mide desde el PICO de capital, nunca desde el saldo inicial: una cuenta que subió a 2.000 y bajó a 1.300 ha perdido el 35 % de su máximo aunque siga ganando sobre el inicio. Al pasar a Fase 2 el tope de apalancamiento baja a 3×, y de Fase 2 no se vuelve nunca de forma automática: hace falta una acción de administrador con confirmación explícita.",
        nota: "«Inoperante» y «game over» no son lo mismo y el sistema los distingue a propósito: quedarse con 8 $ no es lo mismo que quedarse con 0, y el histórico de un intento fallido es el dato más valioso del experimento.",
      },
    ],
  },
  {
    id: "limites",
    titulo: "Límites que conviene conocer",
    resumen: "Lo que el sistema no puede ver hoy, por el origen de los datos.",
    items: [
      {
        termino: "La vela de cripto es reconstruida",
        formula:
          "cierres, precio vivo y volumen  → /market_chart (365 días)\nmáximos y mínimos diarios       → /ohlc a 4 h, agregado (30 días)",
        lectura:
          "CoinGecko no ofrece velas diarias con máximo y mínimo reales en su tier gratuito, así que el motor las reconstruye con dos peticiones por moneda. Consecuencia: solo los últimos 30 días tienen rango real, y el ATR y los niveles técnicos se calculan únicamente sobre esas filas. El resto de la serie sirve para las medias y el MACD, que solo necesitan el cierre.",
        nota: "Antes se pedían velas de 4 días, y eso inflaba la volatilidad de cripto alrededor del doble y dejaba el precio mostrado hasta 4 días por detrás del real. Las cifras de cripto anteriores a septiembre de 2026 no son comparables con las de ahora.",
      },
      {
        termino: "El ATR de cripto se apoya en 30 días",
        formula: null,
        lectura:
          "Con solo 30 filas con rango real, el ATR de una cripto es más ruidoso que el de una acción y puede moverla de tramo de volatilidad cuando está pegada al 3 % o al 6 % — justo los umbrales que deciden la base de apalancamiento. Los máximos y mínimos provienen además de velas de 4 horas agregadas, no del rango real de un mercado concreto, así que pueden quedarse algo cortos.",
      },
      {
        termino: "Una posición cripto nunca llega a «rojo»",
        formula: null,
        lectura:
          "El deterioro fundamental se apoya en el EPS, que CoinGecko no expone. Como el rojo exige deterioro técnico Y fundamental, una cripto se queda como mucho en ámbar — y sin rojo tampoco recibe sugerencia de rotación.",
      },
      {
        termino: "Fuentes no oficiales",
        formula: null,
        lectura:
          "yfinance no es una API oficial de Yahoo: si cambian su estructura interna, las acciones dejan de escanearse (las criptos no). CoinGecko en tier gratuito permite del orden de 10-15 peticiones por minuto, y como cada cripto necesita dos peticiones, el escaneo lo hace un proceso programado —acciones cada 30 min con la bolsa abierta, cripto cada hora— y la pantalla solo lee su último resultado.",
      },
      {
        termino: "Dato atrasado o suspendido",
        formula: "cripto: > 90 min · acción: > 60 min con Nueva York abierto",
        lectura:
          "Bajo el precio aparece «atrasado · hace N» cuando ese activo debería haberse recalculado ya y no lo ha hecho; se muestra su última lectura válida. Con la bolsa cerrada una acción no se atrasa: el dato del cierre es el último posible. «Suspendido» significa tres fallos seguidos del proveedor: el sistema lo reintenta con espera creciente y, mientras, conserva la última lectura. Los festivos de NYSE no se descuentan aquí y pueden marcar acciones como atrasadas.",
      },
      {
        termino: "Esto no es asesoramiento",
        formula: null,
        lectura:
          "El sistema describe confluencias técnicas y acota el riesgo con topes duros. No conoce tu situación financiera, tu horizonte ni tu tolerancia a la pérdida, y ninguna de sus cifras es una recomendación de inversión.",
      },
    ],
  },
];
