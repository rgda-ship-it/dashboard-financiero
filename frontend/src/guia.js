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
          "Los eventos viven en la base de datos y llegan en tiempo real, sin recargar: los del sistema y los de los agentes los ve todo usuario aprobado; los tuyos, solo tú. El histórico sobrevive al cierre de sesión y se ve igual en cualquier dispositivo. «Limpiar» no borra nada —los eventos globales son de todos—: mueve tu marca de lectura, que se guarda en tu perfil y te sigue a otro equipo.",
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
        termino: "Poder de trading y tope de apalancamiento",
        formula:
          "poder de trading (lo que el bróker permite, escalas QuantFury):\n  equity <  1.000 $  →  20 × equity\n  equity ≥  1.000 $  →     20.000 $\n  equity ≥  2.000 $  →     40.000 $\n  equity ≥  5.000 $  →    100.000 $\n  equity ≥ 10.000 $  →    200.000 $\n  equity ≥ 15.000 $  →    300.000 $\n  equity ≥ 20.000 $  →    400.000 $\n  equity ≥ 25.000 $  →    500.000 $\n  equity ≥ 50.000 $  →  1.000.000 $\n\ntope de apalancamiento (lo recomendable): 5× en Fase 1, 3× en Fase 2",
        lectura:
          "Son dos cifras distintas y ninguna sustituye a la otra. El poder de trading es la capacidad que la cuenta tendría en el bróker por su saldo, hasta 20×. El tope de apalancamiento es lo que el sistema considera razonable operar y lo que el servidor impone en cada orden. «En uso» es el nominal de tus posiciones abiertas: con el tope de 5× y el límite de margen comprometido, nunca pasa de 3 veces tu equity, muy lejos del poder de trading.",
        nota: "Por encima de 50.000 $ de equity la escala no tiene más tramos: el poder de trading se queda en 1.000.000 $.",
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
        termino: "Cuánto comprar: el cupo y tu cantidad",
        formula:
          "cupo por posición = margen máx ÷ nº máx de posiciones\n                   (60 % ÷ 3 = 20 % del equity por defecto)\n\nacciones  → unidades enteras (hacia abajo)\ncripto    → admite fracciones",
        lectura:
          "La cantidad sugerida no deja que una sola posición se lleve todo el margen: si el stop está muy cerca, el cálculo por riesgo pediría un nominal enorme, y sin cupo esa primera orden agotaría el margen de la cuenta. La sugerencia es solo eso: puedes escribir la cantidad que quieras. Lo que el servidor impone siempre es el riesgo hasta el stop (≤ 10 % del equity), el margen total (≤ tu tope) y el apalancamiento de la fase.",
        nota: "Con unidades enteras, el riesgo declarado puede no llegar para una acción: con 500 $ y un 1,5 % de riesgo (7,50 $), una acción de 100 $ con el stop al 10 % arriesga 10 $. Entonces se compra UNA, siempre que su riesgo no pase del 10 % del equity y su margen quepa. No es falta de poder de compra: el apalancamiento cambia el margen, no lo que se pierde si salta el stop.",
      },
      {
        termino: "Cerrar una parte",
        formula: "cerrar el 25 / 50 / 75 %  →  libera esa parte del margen\n                          y realiza su P&L al precio de ahora",
        lectura:
          "Sirve para asegurar parte de la ganancia o para liberar margen y entrar en otra operación sin salir del todo. Deja sus dos apuntes en el libro mayor, como un cierre completo, y cuenta para el P&L realizado del día. Una acción se cierra por unidades enteras: la mitad de 3 acciones es 1.",
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
    id: "agentes",
    titulo: "Agentes",
    resumen: "Tres estrategias deterministas sobre el mismo mercado, con meta diaria, corte semanal y memoria compartida.",
    items: [
      {
        termino: "Tres perfiles, no tres números",
        formula:
          "            meta   riesgo/op   posiciones   R:R mín   fuerza         margen máx\nPrudencia    2 %     1,5 %          3          2,0     alta             40 %\nCadencia     5 %     3,0 %          2          1,5     media o alta     55 %\nAudacia      7 %     5,0 %          2          1,2     media o alta     60 %",
        lectura:
          "Prudencia solo opera acciones, con niveles de estructura, ATR por debajo del 3 % y como mucho 3×. Audacia exige un ATR de al menos 1,5 % porque necesita recorrido. Si los tres compartieran parámetros y solo cambiara la meta, abrirían las mismas órdenes y el experimento no compararía nada. Los tres empiezan con 500 $ ficticios y deciden sin ningún modelo de lenguaje: con el mismo estado toman siempre la misma decisión, y por eso un mal día se puede reproducir paso a paso.",
      },
      {
        termino: "Cómo elige un agente",
        formula:
          "candidatos = señales frescas de todo el catálogo activo\n             con MÁS indicadores alcistas que bajistas\n             operables, de su fuerza, origen y R:R\n             sin posición abierta en ese activo\n             que cumplan las prácticas que ha adoptado\n\nelegido, por orden:\n  1. mayor R:R   2. mayor fuerza\n  3. mayor dominancia neta   4. símbolo alfabético",
        lectura:
          "Cada cinco minutos. «Sin candidatos» es una salida válida: no se relaja ningún criterio para forzar una operación. Cada orden guarda su racional —cuánto faltaba para la meta, qué se evaluó y los tres mejores descartes con su motivo— y se lee desplegando la fila en la tabla de operaciones.",
        nota: "El agente propone y la base de datos dispone: sus órdenes pasan por los mismos cinco límites del servidor que las tuyas.",
      },
      {
        termino: "Meta diaria sobre saldo compuesto",
        formula:
          "objetivo de hoy = saldo con el que amanece × meta %\ncumplido        = P&L REALIZADO de hoy ≥ objetivo\nmeta cumplida   → no abre nada más hoy",
        lectura:
          "El interés compuesto no es una fórmula: es que el objetivo de cada día se calcula sobre el saldo con el que ese día empieza. Si ayer se perdió, hoy la meta es más pequeña en dólares. Solo cuenta el dinero que volvió a la cuenta: una posición flotando a favor no cumple nada, porque mañana puede revertir. Y con la meta cumplida el agente deja de abrir posiciones — sin esa regla, quien llega al 7 % a las diez sigue operando hasta perderlo.",
        nota: "La línea discontinua del gráfico es la trayectoria teórica si se cumpliera la meta todos los días operables: 500 × (1 + meta)^n. Es una referencia, no un plan.",
      },
      {
        termino: "Corte semanal",
        formula:
          "ratio = días cumplidos / días OPERABLES (nunca / 7)\n\nvalidada    ratio ≥ 0,70  → publica lo que le funcionó\naviso       ratio ≥ 0,40  → adopta una práctica ajena\ndeficiente  ratio < 0,40  → adopta, y riesgo a la mitad\n2 deficientes seguidas    → cuarentena: solo fuerza alta, 1 posición",
        lectura:
          "Lo hace el sistema cada lunes de madrugada (UTC) sobre la semana que acaba de terminar. Prudencia se mide sobre sus cinco días de bolsa y Audacia sobre siete: cada uno contra su propio calendario. Un agente en pausa tampoco suma días operables. El riesgo reducido y la cuarentena se levantan con la siguiente semana validada.",
      },
      {
        termino: "Prácticas compartidas",
        formula:
          "se publica si:  ≥ 3 operaciones con la misma firma\n                ≥ 66 % cerradas en objetivo\n                P&L medio > 0\n\nse refuta si:   2 agentes la adoptan y les empeora",
        lectura:
          "Una práctica no es un consejo en prosa: es un filtro ejecutable sobre las señales —clase, fuerza, origen de niveles, tramo de ATR y de R:R— que otro agente aplica al elegir. Adoptarla cambia de verdad sus candidatos. Dos semanas después se compara su rendimiento medio antes y después; si empeora, la abandona y le pone un voto negativo, y con dos fracasos la práctica deja de ofrecerse a nadie.",
      },
      {
        termino: "Lo que piden los agentes",
        formula: "prioridad  = ocurrencias × agentes distintos que lo piden\nocurrencia = un agente, un día",
        lectura:
          "Los agentes no opinan: cada petición nace de un disparador que observa una limitación real —tres días sin ninguna señal alcista, un activo sin volatilidad conocida, stops que antes rozaron el objetivo— y lleva la evidencia con las órdenes o los días concretos. Sin evidencia, la base de datos no la admite. Lo que los tres piden a la vez sube solo a lo más alto.",
      },
      {
        termino: "Repartir, rotar y asegurar",
        formula:
          "              reparto       rota si la nueva tiene…       toma parcial\nPrudencia     cupo          R:R ≥ 2,0 × el restante       mitad al 50 %, stop a la entrada\nCadencia      cupo          R:R ≥ 1,5 × el restante       mitad al 50 %\nAudacia       concentrado   R:R ≥ 1,2 × el restante       ninguna",
        lectura:
          "Es el punto de partida de cada uno, no una regla fija. «Restante» es lo que le queda a una posición abierta por ganar hasta el objetivo frente a lo que le queda por perder hasta el stop, al precio de ahora: una posición a punto de llegar al objetivo tiene poco recorrido, y si aparece una señal mucho mejor el agente la cierra para entrar en la otra. La toma parcial cierra la mitad a mitad de camino; con «stop a la entrada», lo que queda ya no puede perder.",
      },
      {
        termino: "Aprender de cada decisión",
        formula:
          "rotación : lo que dio la nueva − lo que habría dado la cerrada\nparcial  : lo que se aseguró − lo que habría dado esa parte al final\nreparto  : retorno sobre el margen, concentrando frente a repartiendo\n\ncada 10 decisiones resueltas de un tipo → un paso del parámetro",
        lectura:
          "Cada decisión se juzga contra lo que habría pasado sin ella, no contra la nota de la semana: una semana mala puede tener una decisión excelente. Si sus rotaciones pierden, el agente sube su umbral; si las tomas parciales le cuestan dinero, las deja; si concentrar rinde menos que repartir, cambia de modo. Cada cambio queda registrado con su evidencia en la pestaña «Decisiones».",
        nota: "El contrafactual de una rotación se observa con el precio que el ciclo ve cada 5 minutos: si el precio tocó el objetivo y volvió entre dos lecturas, no se ve.",
      },
      {
        termino: "Los errores también enseñan",
        formula: "firma con ≥ 3 operaciones, 2 de cada 3 en stop y P&L medio < 0\n  → práctica «evitar»: no entrar en esas señales",
        lectura:
          "Igual que se comparte lo que funciona, se comparte lo que falla: una combinación de rasgos que acaba en el stop una y otra vez se publica como filtro de exclusión. Otros agentes la adoptan, se mide si les mejora, y si no, se refuta.",
      },
      {
        termino: "Game Over y reinicio",
        formula: null,
        lectura:
          "Un Game Over no se revierte. Reiniciar a un agente es una acción de administrador que crea una cuenta NUEVA de 500 $ y conserva la anterior entera: el histórico del intento fallido es el dato más valioso del experimento.",
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
        termino: "El monitor ve un precio por minuto",
        formula: null,
        lectura:
          "Las posiciones se evalúan una vez por minuto contra un único precio: lo que el mercado haga entre dos pasadas no se ve. Entre que un precio cruza un nivel y la posición se cierra pueden pasar unos dos minutos, y un hueco de mercado se registra al nivel, no al precio del hueco.",
      },
      {
        termino: "Las señales tienen la edad del escaneo",
        formula: "acciones: cada 30 min con la bolsa abierta · cripto: cada hora",
        lectura:
          "Ni tú ni los agentes operáis sobre el mercado de este segundo, sino sobre el último escaneo. Por eso una señal de más de 90 minutos no abre posiciones: describe un mercado que ya no existe.",
      },
      {
        termino: "Sin trailing stop ni órdenes limitadas",
        formula: null,
        lectura:
          "Una posición se abre a mercado y se cierra en el objetivo, en el stop, por liquidación, a mano o por partes. No hay órdenes limitadas ni stops que sigan al precio: lo más parecido es la toma parcial con el stop a la entrada. Los agentes piden el trailing stop solos en su backlog cuando lo echan en falta, con las órdenes que lo demuestran.",
      },
      {
        termino: "Esto no es asesoramiento",
        formula: null,
        lectura:
          "Es una simulación educativa. El sistema describe confluencias técnicas y acota el riesgo con topes duros. No conoce tu situación financiera, tu horizonte ni tu tolerancia a la pérdida, y ninguna de sus cifras es una recomendación de inversión.",
        nota: "Ninguna cifra de este sistema es dinero real, y por eso los importes se guardan sin cifrar. Es la condición que hace segura esa decisión: si algún día hubiera dinero real, habría que revisarla antes de introducir un solo importe.",
      },
    ],
  },
];
