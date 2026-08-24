# PRD — Rediseño visual (overhaul): material, acento único, ritmo y diff real

## Status

Approved (gate 1, 2026-08-23)

## Contexto — qué existe hoy, verificado en el código

`docs/DESIGN.md` describe un sistema real y defendible: dos tokens tomados del logo, ningún matiz
para comunicar estado, el radio como portador de significado, un piso de opacidad del 70% para texto
secundario, y una medida de 820pt en lugar del ancho de la ventana. La regla que abre el documento es
una sola: **si se ve como salida de terminal, está mal renderizado.**

El problema no es el sistema. Es que **el sistema no está codificado en ninguna parte** y que en tres
lugares concretos la app pierde contra `git diff`.

`Theme.swift` exporta dos colores y dos constantes de opacidad. Todo lo demás que DESIGN.md promete
vive como literal dentro de las vistas:

- **La escala de radios ya se rompió.** DESIGN.md documenta 22 / 14 / 6-8 / capsule. En el código hay
  22, 14, 10, 8, 6 y 4. `TranscriptView.swift:127` usa 10 y `ToolCallCell.swift:108` usa 4, ambos
  fuera de escala.
- **La medida no es un token.** `.frame(maxWidth: 820)` está duplicado en `ConversationPane.swift:57`,
  `:109`, `TranscriptView.swift:25` y `PermissionPrompt.swift:58`. `ComposeView.swift:82` usa 620, un
  quinto valor no documentado.
- **Las superficies son literales dispersos.** Alrededor de 17 valores de opacidad distintos para
  rellenos, trazos y tintes, repartidos en 8 archivos. Nada los nombra, así que "cuál es el relleno de
  una tarjeta" no tiene respuesta salvo `grep`.
- **El mismo control existe dos veces a mano.** `circleButton` está definido en
  `ConversationPane.swift:114` y en `ComposeView.swift:100`; la caja del composer está duplicada
  entera. DESIGN.md dice que la duplicación es a propósito porque empezar y continuar una sesión son
  el mismo acto. Ese argumento pide *un componente usado dos veces*, no dos copias que pueden
  divergir en silencio.
- **`Theme.tertiaryOpacity`** (`Theme.swift:18`) no tiene ningún uso y su valor es idéntico al de
  `secondaryOpacity`.

Los tres lugares donde la app se ve como terminal, contra su propia regla:

1. **El diff no es un diff.** `ToolCallCell.swift:120` concatena: todas las líneas eliminadas y
   después todas las agregadas.

   ```swift
   if let old = edit.oldText { result += old.split(...).map { Line(marker: "−", ...) } }
   if let new = edit.newText { result += new.split(...).map { Line(marker: "+", ...) } }
   ```

   Sin intercalado, sin números de línea, sin contexto de hunk, sin algoritmo. No existe ninguna
   implementación de diff en el target: `Sources/` no contiene `difference(from:)`,
   `CollectionDifference`, manejo de hunks ni de números de línea. `FileEdit`
   (`Sources/ZeroCore/Domain/AgentEvent.swift:83`) sólo lleva `path`, `oldText` y `newText`.
   **FR-20 de `001-agent-chat-core` exige que las ediciones se rendericen "como diff con resaltado, no
   como texto crudo".** Cuarenta líneas de menos seguidas de cuarenta de más no cumplen eso, y es la
   razón declarada de existir del producto.

2. **Corridas de tool calls idénticas.** `TranscriptView` usa `spacing: 18` entre entradas sin
   importar el tipo, así que un agente que lee ocho archivos produce ocho cajas con borde idénticas.
   Un scroll de cajas uniformes es exactamente lo que produce una terminal.

3. **Copy crudo.** `ToolCallCell.statusText` devuelve palabras en minúscula sin más (`"pending"`,
   `"running"`, `"done"`, `"failed: \(reason)"`) y la duración se imprime como `"\(Int(...)) ms"`.

Además, dos afirmaciones de los NFR de `001-agent-chat-core` que el código no sostiene:

- **Movimiento reducido:** hay cinco animaciones (`ConversationPane.swift:104`,
  `ComposeView.swift:58`, el anillo de `UsageIndicator`, el hover de `PermissionButton`, el autoscroll
  del transcript) y `accessibilityReduceMotion` no aparece en ningún lugar del target.
- **Dynamic Type:** cinco frames fijos no escalan — el botón circular (`26x26` con
  `.system(size: 12)`), el anillo (`18x18`), el popover de uso (`width: 250`), el detalle de permiso
  (`maxHeight: 140`) y el campo de modelo (`width: 180`).

## Problem

La app está bien pensada y se lee plana. Toda la jerarquía se construye apilando opacidades del único
color de primer plano sobre un fondo liso, porque es la única herramienta disponible: de ahí los 17
literales. Nada puede señalarse, así que cada elemento interactivo suena al mismo volumen, incluido el
único que de verdad interrumpe al usuario ("el agente te está esperando"). Y la superficie que
justifica el producto entero — el diff — es hoy una concatenación que se lee peor que la salida de
`git diff`, que es precisamente lo que DESIGN.md prohíbe en su primera línea.

## Goals

- Que DESIGN.md quede **codificado en `Theme`** y sea verificable, en vez de ser prosa que hay que
  recordar. La deriva de radios y medidas que ya ocurrió deja de ser posible en silencio.
- Cambiar la jerarquía de "apilar opacidades" a **profundidad real** sobre materiales nativos de
  macOS 26, sin agregar color para lograrlo.
- Dar a la app **un único punto de urgencia visual** — un acento, un solo trabajo — sin perder el
  argumento de accesibilidad que sostiene la regla monocroma.
- **Cumplir FR-20 de verdad**: diff real por líneas, intercalado, con números de línea y contexto.
- Dar **ritmo** al transcript, de modo que una corrida de ocho lecturas no se lea como ocho cajas.
- Cerrar la brecha entre lo que los NFR de 001 afirman (Dynamic Type, movimiento reducido) y lo que
  el código hace.

## Non-goals

- **No se reemplaza la paleta.** `ink` y `paper` se quedan, igual que el piso del 70%. Cambiar los dos
  tokens del logo sería un cambio de marca, no un rediseño, y necesitaría su propia dirección.
- **No se usa matiz para comunicar estado.** `StateDot`, `PlanList` y `DiffView` conservan forma,
  glifo y tinte como portadores de información.
- **No cambia la arquitectura de información.** Sidebar agrupado por proyecto, transcript central,
  composer abajo: igual. La idea de partir el panel de detalle en un carril de cambios acumulados más
  un carril de actividad es mejor para este producto y **es un cambio de IA**, así que va en su propia
  PRD con su propio gate (ver Conflicts / dependencies).
- **No se toca el comportamiento de permisos** de `003-permission-modes`. La superficie cambia de
  aspecto; el modelo, los atajos y el default `.ask` no.
- No se agregan dependencias de paquete. La única incorporación externa posible es un asset de
  tipografía (ver Open questions).
- No se cambian rutas, nombres de comandos de menú, ni los atajos de teclado existentes.
- **No entra el énfasis intra-línea del diff** (resaltar qué cambió dentro de una línea modificada). Es
  aditivo sobre FR-15 a FR-18 y no hace falta para cumplir FR-20 de 001; va a un seguimiento propio
  (Open question 4).

## User stories

- Como desarrollador con cuatro sesiones abiertas, quiero **ver de un golpe cuál me está esperando**,
  sin recorrer la barra lateral punto por punto.
- Como desarrollador revisando lo que hizo el agente, quiero **leer el cambio como un diff**, con
  números de línea y las líneas viejas y nuevas intercaladas, para no reconstruir a mano qué
  reemplazó a qué.
- Como desarrollador siguiendo una sesión larga, quiero que **una corrida de lecturas ocupe una
  línea** y no ocho cajas, para que el transcript siga siendo legible.
- Como usuario de VoiceOver o de movimiento reducido, quiero que **la app respete mi configuración**,
  no que anime igual y me diga en un PRD que soporta Dynamic Type.
- Como persona que no distingue dos grises, quiero que **la información siga llegando por forma**
  aunque ahora exista un acento.

## Functional requirements

### Tokens: DESIGN.md, codificado

- **FR-1** — `Theme` expone la escala de radios como tokens con nombre (`composer` 22, `card` 14,
  `content` 8, `inline` 6). Ninguna vista construye un `RoundedRectangle` con un literal. Se corrigen
  los dos radios fuera de escala: `TranscriptView.swift:127` (10 → `content`) y
  `ToolCallCell.swift:108` (4 → `inline`).
- **FR-2** — `Theme` expone la medida (820) y la medida de composición (620) como tokens, más un
  modificador `.zeroMeasure(_:)` que reemplaza el idioma `.frame(maxWidth: N).frame(maxWidth: .infinity)`
  en los cinco call sites actuales.
- **FR-3** — `Theme` expone los niveles de relleno y de trazo con nombre. Ninguna vista aplica
  `.opacity(<literal>)` a un color del tema para construir una superficie.
- **FR-4** — `Theme.tertiaryOpacity` se elimina, o recibe un valor propio con su ratio de contraste
  medido y documentado igual que `secondaryOpacity`. No se queda como duplicado sin uso.
- **FR-5** — `circleButton` y la caja del composer existen **una vez** como componentes, consumidos
  por `ConversationPane` y por `ComposeView`. La intención de DESIGN.md ("el mismo control en los dos
  lugares") pasa de mantenida a mano a garantizada por estructura.

### Profundidad en lugar de opacidades apiladas

- **FR-6** — Tres niveles de elevación con nombre (canvas / raised / floating) construidos sobre los
  materiales nativos de macOS 26. Cada superficie de la app declara su nivel; ninguna elige un relleno.
- **FR-7** — Bajo `accessibilityReduceTransparency` los tres niveles degradan a rellenos sólidos que
  preservan el mismo contraste y la misma separación entre niveles.

### El acento: uno, y un solo trabajo

- **FR-8** — Existe **un único** color de acento, aplicado exclusivamente al estado "el agente te está
  esperando": `StateDot` cuando `awaiting` es true, y la superficie de permiso pendiente. Ningún otro
  uso — ni acciones primarias (eso lo sigue diciendo el relleno), ni estado de sesión, ni enlaces, ni
  el anillo de uso.
- **FR-9** — El acento es **refuerzo redundante, nunca el único portador**: `StateDot` conserva su
  anillo y la superficie de permiso conserva su forma, de modo que la misma información llega sin
  percibir el color (WCAG 1.4.1). Esto es lo que permite agregar un matiz sin romper el argumento de
  accesibilidad con el que DESIGN.md defiende la regla monocroma.
- **FR-10** — El valor se fija contra **contraste medido** sobre `ink` y sobre `paper`, AA mínimo para
  cualquier texto que lo use, y el número queda documentado en DESIGN.md. No se elige a ojo.

### Tipografía

- **FR-11** — Un tratamiento de display para los dos anclajes de pantalla que hoy se leen como
  formulario: el titular de `ComposeView` (hoy `.title2.weight(.medium)`) y `EmptyStatePane`. Fuente del
  sistema, escala y tracking distintos. No se introduce una segunda familia para prosa.
- **FR-12** — Las superficies de código dejan de usar `.callout.monospaced()` directamente y pasan por
  un helper de `Theme` que aplica la face monoespaciada del sistema **con el conjunto estilístico de
  cero alternativo activado**, de modo que `0`/`O` y `1`/`l`/`I` se distingan a tamaño de cuerpo. Aplica
  a las cinco superficies de código: `ToolCallCell`, `DiffView`, `CodeBlock`, el detalle de
  `PermissionPrompt` y el nombre de modelo en `UsageDetail`. Es un requisito de legibilidad: el
  contenido central de esta app son diffs. **No se empaqueta una tipografía** (ver Open question 2).

### Ritmo del transcript

- **FR-13** — El espaciado entre entradas del transcript deriva de la adyacencia de tipos, no es la
  constante `18` actual: prosa junto a prosa va ajustado, prosa junto a tool call va holgado.
- **FR-14** — Las tool calls consecutivas se agrupan en **una sola corrida expandible** ("Read 4
  files") en lugar de N celdas con borde. Expandida, muestra cada llamada con el detalle que hoy
  muestra `ToolCallCell`.

### El diff (FR-20 de 001, cumplido)

- **FR-15** — Diff real por líneas, **intercalado**, calculado con `CollectionDifference` de la
  biblioteca estándar. Sin dependencia nueva. Vive en `ZeroCore`, no en la vista, y es testeable sin UI.
- **FR-16** — Números de línea y contexto de hunk: las líneas sin cambios alrededor de cada cambio se
  muestran, y los tramos largos sin cambios se colapsan.
- **FR-17** — Cuando `oldText` está ausente (el caso `Write`, que ya documenta `DiffView`), se sigue
  mostrando el bloque completo como bloque, sin inventar un diff contra nada.
- **FR-18** — Se preserva el lenguaje monocromo del diff: marcador `+`/`−` más tinte del único color de
  primer plano. **Nada de rojo y verde**, y el acento de FR-8 no entra aquí.
- **FR-19** — `statusText` y la duración dejan de ser palabras crudas y milisegundos crudos.

### Movimiento (2 → 4), motivado

- **FR-20** — Exactamente cuatro animaciones nuevas o reformuladas, cada una con su justificación:
  1. **Texto en streaming**: la respuesta del asistente aparece con fade por chunk, de modo que "sigue
     generando" no necesita un spinner (estado).
  2. **Transición de tool call**: pending → running → done cambia de forma, no de etiqueta de texto
     (estado).
  3. **Llegada de la superficie de permiso**: sube desde el borde del composer, para que no se pueda
     pasar por alto (feedback).
  4. **Aparición de líneas de diff**: entran escalonadas en ~200ms, para que se vea *qué* llegó
     (narrativa).
- **FR-21** — Las cuatro, más las cinco animaciones que ya existen, quedan condicionadas a
  `accessibilityReduceMotion`. Nada infinito, nada decorativo.

## Non-functional requirements

- **Contraste** — El piso del 70% para texto secundario se mantiene sin excepciones. El acento de FR-8
  se mide en ambos temas antes de fijarse (FR-10).
- **Dynamic Type** — Los cinco frames fijos identificados pasan a `@ScaledMetric`, de modo que el NFR
  de Dynamic Type de `001-agent-chat-core` deje de ser una afirmación sin respaldo.
- **Movimiento reducido** — Cubierto por FR-21. Es la otra afirmación de 001 hoy sin respaldo.
- **Teclado** — Se preserva íntegro lo que existe (⌘N, ⌘⇧] / ⌘⇧[, `a`/`A`/`d`/`D`). Las pills de
  `PermissionModeControl`, hoy sólo alcanzables con el ratón, ganan atajo: FR-27 de 001 pide operación
  completa por teclado.
- **VoiceOver** — Toda etiqueta de accesibilidad existente se conserva. Las superficies nuevas
  (corrida de tool calls de FR-14, hunks de FR-16) llevan la suya.
- **Rendimiento** — El overhaul no puede regresar el arranque medido por `StartupClock` ni el footprint
  cubierto por `FootprintBenchmarkTests`. El diff de FR-15 se calcula una vez por edición y se cachea,
  no en `body`; el precedente está documentado en la cabecera de `MarkdownText.swift`.
- **Copy de UI** — Sin guiones largos en cadenas visibles. Es una regla para la UI, no para estos docs.
- **Preview** — Por la regla de proceso de DESIGN.md, `PreviewData.seed()` cubre cada estado nuevo en el
  mismo cambio, y siempre a través de `Transcript.apply`, nunca ensamblando un `Transcript` a mano.

## Data model changes

`FileEdit` no cambia: `path`, `oldText`, `newText` siguen siendo lo que los proveedores reportan.

Se agrega en `ZeroCore` un tipo para el diff **calculado** (líneas con su marcador, su número de línea
en cada lado, y agrupadas en hunks), derivado de `FileEdit` y testeable sin levantar la UI. No se
persiste: es una proyección de datos que ya están en el transcript, así que `Store` y los modelos de
`Persistence` no se tocan.

Ninguna migración. Nada en `pricing.json` ni en el esquema de permisos cambia.

## UI/UX notes

Dials, en la escala del skill de diseño: se pasa de `VARIANCE 3 / MOTION 2 / DENSITY 5` a
**`5 / 4 / 5`**. La densidad se mantiene a propósito: esta app es para alguien que mira código, no una
landing.

Lo que **se conserva** de DESIGN.md, sin discusión: los dos tokens y el piso del 70%; forma y posición
para el estado, nunca matiz; los glifos `○ ◐ ●` del plan; marcador más tinte en el diff;
relleno-significa-primario; entradas tipadas en el transcript; el sidebar agrupado por proyecto; y la
forma del composer, que es lo mejor diseñado de la app.

Lo que **cambia**: la sección "Palette" de DESIGN.md deja de decir "no hay un tercer color" y pasa a
describir un acento con un trabajo único y su ratio medido. La sección "Typography and shape" pasa a
describir tokens que existen en `Theme` en lugar de convenciones que hay que recordar. Ese cambio de
documento es parte del entregable, no un seguimiento.

## Open questions

Las cuatro se resolvieron en el gate 1. Quedan escritas con su decisión y su razón, porque el plan de
implementación depende de ellas.

1. **El acento — resuelta: aprobado, dirección ámbar / señal.** Se acepta modificar la regla "There is
   no third color" de DESIGN.md de forma acotada: un acento, un solo trabajo (FR-8), siempre redundante
   con una forma que ya lleva la misma información (FR-9), con su ratio medido y documentado (FR-10).
   FR-8 a FR-10 quedan **dentro** del alcance. El valor exacto se fija midiendo, no eligiendo a ojo, y
   la sección "Palette" de DESIGN.md se actualiza como parte del entregable.

2. **La face monoespaciada — resuelta: no se empaqueta ninguna.** Se usa la face monoespaciada del
   sistema con el conjunto estilístico de cero alternativo activado (FR-12 reescrito arriba). Dos
   razones: DESIGN.md sostiene "System font throughout — no custom typeface", y este repo ya se rompió
   dos veces enviando recursos dentro del `.app` (`001-dmg-resource-bundle-crash`,
   `002-bundle-module-lookup-path`), así que agregar un asset de tipografía compra un riesgo conocido
   por una mejora que el conjunto estilístico ya da. Si en la implementación resulta que el conjunto no
   está disponible, se levanta como bloqueo y se decide ahí, no antes.

3. **FR-14 contra FR-26 de 001 — resuelta: la corrida se auto-expande cuando la búsqueda coincide
   dentro.** FR-26 es un requisito aprobado y vigente ("todo el transcript admite selección, copia y
   búsqueda incremental"); dejar contenido colapsado fuera del alcance de la búsqueda sería una
   regresión introducida por una mejora estética. Cuesta más trabajo y entra igual.

4. **Alcance del diff — resuelta: FR-15 a FR-18 entran, el énfasis intra-línea no.** Ver Non-goals. El
   diff intercalado con números de línea y hunks es lo que hace falta para que FR-20 de 001 se cumpla;
   el énfasis intra-línea es una mejora aditiva encima de eso y no debe retrasarlo.

## Conflicts / dependencies

- **DESIGN.md, sección "Palette"** — dice explícitamente "There is no third color" y lo defiende con un
  argumento de accesibilidad. FR-8 a FR-10 lo modifican de forma deliberada y acotada. Es la única
  decisión de esta PRD que contradice un documento aprobado, y por eso es la Open question 1.
- **`003-permission-modes`** — la superficie de permiso cambia de aspecto (FR-6, FR-8, FR-20.3) y
  `PermissionModeControl` gana atajo de teclado. El modelo, el default `.ask` y los atajos
  `a`/`A`/`d`/`D` se preservan sin cambio.
- **`001-agent-chat-core`** — esta PRD toca FR-20 (por fin lo cumple), FR-26 (Open question 3), FR-27
  (lo amplía a las pills de modo) y los NFR de Dynamic Type y contraste.
- **Refactor estructural** — la tokenización (FR-1 a FR-5) es **prerrequisito del overhaul, no una PRD
  aparte**: no se puede introducir un nivel de elevación o un acento encima de 17 literales dispersos
  sin multiplicarlos.
- **Fuera de alcance, con su propia PRD** — partir el panel de detalle en un carril de cambios
  acumulados más un carril de actividad, con el permiso promovido fuera del scroll. Es un cambio de
  arquitectura de información y por 11.F del protocolo de rediseño necesita aprobación explícita y
  separada.
