# Implementation Plan — Rediseño visual (overhaul)

## Branch / worktree

Branch name: `feat/004-ui-visual-overhaul`
Isolation mode: rama en el checkout actual (no worktree). La rama arrastra la instalación de skills
(`.agents/skills/`, `.claude/skills/`, `skills-lock.json`) que estaba sin commitear en `develop`.

## Cómo está ordenado

Diez fases. Cada una es **verificable de forma independiente** en `ZeroPreview.app` y revertible sola.
El orden no es negociable en dos puntos: las fases A y B son prerrequisito de todo lo demás (no se
puede introducir un nivel de elevación o un acento encima de 17 literales dispersos sin
multiplicarlos), y la fase J cierra al final porque depende de todas.

Una nota sobre verificación, para no prometer lo que este repo no tiene: los tests viven en
`Tests/ZeroCoreTests` y cubren `ZeroCore`. **No hay tests de vistas.** Por eso el motor de diff de la
fase F se diseña en `ZeroCore` y se prueba de verdad, mientras el resto se verifica a mano contra
`ZeroPreview.app`, que es el mecanismo que este proyecto ya usa para eso. Lo que sí se automatiza del
lado de la UI es la regla de tokens, con un script de lint en CI (A5).

Los comandos del way (`pnpm typecheck && pnpm lint && pnpm test`) no aplican: este target es Swift. El
equivalente en cada checkpoint es `swift build && swift test`, más `./Scripts/make-preview.sh` cuando
el cambio se ve.

## Phases

### Phase A — `Theme` se convierte en el sistema (FR-1 a FR-4)

- [ ] **A1** — Escala de radios como tokens con nombre en `Theme` (`composer` 22, `card` 14,
  `content` 8, `inline` 6). Reemplazar los 13 `RoundedRectangle(cornerRadius:)` literales. Corregir los
  dos fuera de escala: `TranscriptView.swift:127` (10 → `content`) y `ToolCallCell.swift:108`
  (4 → `inline`).
- [ ] **A2** — `Theme.measure` (820) y `Theme.composeMeasure` (620) + modificador `.zeroMeasure(_:)`.
  Reemplaza el idioma `.frame(maxWidth: N).frame(maxWidth: .infinity)` en los 5 call sites
  (`ConversationPane.swift:57`, `:109`, `TranscriptView.swift:25`, `PermissionPrompt.swift:58`,
  `ComposeView.swift:82`).
- [ ] **A3** — Niveles de relleno y de trazo con nombre en `Theme`. Reemplazar los ~17 literales de
  opacidad repartidos en 8 archivos. Ninguna vista aplica `.opacity(<literal>)` a un color del tema.
- [ ] **A4** — Resolver `Theme.tertiaryOpacity` (`Theme.swift:18`): eliminarlo, o darle un valor propio
  con su ratio de contraste medido y documentado como tiene `secondaryOpacity`.
- [ ] **A5** — `Scripts/lint-design-tokens.sh`: falla si aparece un `cornerRadius:` literal, un
  `.opacity(<literal>)` sobre un color del tema, o un `maxWidth: <literal>` en `Sources/Zero`.
  Cablearlo en CI (`.github/workflows`). **Esto es lo que hace que FR-1 a FR-3 sigan siendo verdad en
  seis meses**, y es la razón por la que la deriva de radios ocurrió en primer lugar.

### Phase B — Extracción de componentes (FR-5)

- [ ] **B1** — `CircleButton` como un único componente. Elimina las copias de
  `ConversationPane.swift:114` y `ComposeView.swift:100`.
- [ ] **B2** — `Composer` como componente que **posee su propio `@State draft`** y el estilo de la caja.
- [ ] **B3** — `ConversationPane` y `ComposeView` lo consumen. Limpiar de paso el `VStack(spacing: 0)`
  redundante de `ConversationPane.swift:88`, la indentación de `:134`, los tres
  `@Environment(\.colorScheme)` sin uso (`ProviderModelPicker`, `WorkspacePicker`, `ProjectHeader`) y
  los dos comentarios obsoletos (`RootView.swift:5` habla de una columna derecha que ya no existe;
  `UsageIndicator` dice "in the toolbar" y vive en el composer).
- [ ] **B4** — Verificar la ganancia que B2 compra: con `draft` fuera de `ConversationPane`, una
  pulsación de tecla deja de invalidar su `body` y por tanto de reconstruir `TranscriptView`. El
  problema está documentado en la cabecera de `MarkdownText.swift`; el cacheo de markdown lo abarató,
  esto lo elimina.
- [ ] **B5** — Separar por vista, siguiendo el patrón que ya establecen `Permissions/`, `Transcript/` y
  `Markdown/`: `Compose/` (`ComposeView`, `ProviderModelPicker`, `WorkspacePicker`) y `Sidebar/`
  (`SessionSidebar`, `SidebarHeader`, `ProjectHeader`, `SessionRow`, `StateDot`).

### Phase C — Profundidad sobre material nativo (FR-6, FR-7)

- [ ] **C1** — Tres niveles de elevación con nombre (canvas / raised / floating) sobre materiales
  nativos de macOS 26, en `Theme`.
- [ ] **C2** — Cada superficie declara su nivel: composer y caja de compose → raised; tarjeta de
  permiso y popover de uso → floating; celda de tool call, bloque de código y diff → raised; fondo de
  ventana y sidebar → canvas.
- [ ] **C3** — Fallback bajo `accessibilityReduceTransparency`: rellenos sólidos que preservan el mismo
  contraste y la misma separación entre niveles.
- [ ] **C4** — `PreviewData` cubre los tres niveles a la vez en una sola pantalla, para poder juzgar la
  separación.

### Phase D — El acento (FR-8 a FR-10)

- [ ] **D1** — Medir candidatos ámbar contra `ink` y contra `paper`, elegir, y **documentar el ratio**.
  Sin este número la fase no avanza (FR-10).
- [ ] **D2** — `Theme.accent`, aplicado **sólo** en dos lugares: `StateDot` cuando `awaiting` es true, y
  la superficie de permiso pendiente.
- [ ] **D3** — Verificar la redundancia de FR-9: `StateDot` conserva su anillo y la superficie de
  permiso su forma, así que la información llega sin percibir el color. Comprobar en escala de grises.
- [ ] **D4** — Extender `Scripts/lint-design-tokens.sh`: `Theme.accent` referenciado en exactamente dos
  archivos. Es la única defensa real contra que el acento se filtre a un botón el mes que viene.
- [ ] **D5** — Actualizar la sección "Palette" de DESIGN.md: deja de decir "There is no third color" y
  pasa a describir un acento con un trabajo único y su ratio. **Es la única decisión de esta PRD que
  contradice un documento aprobado**, así que el documento se corrige, no se ignora.

### Phase E — Tipografía (FR-11, FR-12)

- [ ] **E1** — Tratamiento de display para los dos anclajes que hoy se leen como formulario: el titular
  de `ComposeView` (hoy `.title2.weight(.medium)`) y `EmptyStatePane`. Fuente del sistema, escala y
  tracking distintos; sin segunda familia para prosa.
- [ ] **E2** — Helper de `Theme` para la face monoespaciada del sistema con el conjunto estilístico de
  cero alternativo activado. Aplicarlo a las cinco superficies de código (`ToolCallCell`, `DiffView`,
  `CodeBlock`, detalle de `PermissionPrompt`, nombre de modelo en `UsageDetail`).
- [ ] **E3** — Si el conjunto estilístico no está disponible, **parar y levantarlo** en vez de
  empaquetar una tipografía en silencio: la Open question 2 lo decidió así por el historial de bugs de
  recursos en el bundle de este repo.

### Phase F — El motor de diff (FR-15 a FR-18) — en `ZeroCore`, con tests primero

- [ ] **F1** — Tipos del diff calculado en `ZeroCore`: línea con marcador, número de línea en cada lado,
  agrupadas en hunks. Derivado de `FileEdit`, no persistido.
- [ ] **F2** — Diff real por líneas **intercalado**, con `CollectionDifference` de la stdlib. Sin
  dependencia nueva.
- [ ] **F3** — Agrupación en hunks: contexto alrededor de cada cambio, tramos largos sin cambios
  colapsados.
- [ ] **F4** — Caso `Write` (sin `oldText`): sigue mostrándose como bloque completo, sin inventar un
  diff contra nada. Es el comportamiento que `DiffView` ya documenta y hay que preservarlo.
- [ ] **F5** — Tests en `Tests/ZeroCoreTests/`: intercalado correcto, números de línea en ambos lados,
  límites de hunk, caso `Write`, entrada vacía, textos idénticos, archivo grande (coste). **Esta es la
  parte del overhaul que recibe tests de verdad**, porque es la única con lógica.
- [ ] **F6** — `DiffView` renderiza el resultado. Preserva el lenguaje monocromo (marcador + tinte, sin
  rojo/verde, sin el acento de D2) y **cachea por edición, no calcula en `body`** — el precedente está
  en la cabecera de `MarkdownText.swift`.

### Phase G — Ritmo del transcript (FR-13, FR-14, FR-19)

- [ ] **G1** — Espaciado derivado de la adyacencia de tipos en `TranscriptView`, en lugar de la
  constante `spacing: 18`.
- [ ] **G2** — Tool calls consecutivas agrupadas en una corrida expandible ("Read 4 files"). Expandida,
  cada llamada muestra el detalle que hoy da `ToolCallCell`.
- [ ] **G3** — La corrida **se auto-expande cuando la búsqueda coincide dentro** (Open question 3), para
  no regresionar FR-26 de 001.
- [ ] **G4** — `ToolCallCell.statusText` y la duración dejan de ser palabras crudas y milisegundos
  crudos (FR-19).
- [ ] **G5** — Etiquetas de accesibilidad para la corrida colapsada y expandida: hoy `ToolCallCell` ya
  tiene la suya y no se pierde al agrupar.

### Phase H — Movimiento (FR-20, FR-21)

- [ ] **H1** — Condicionar a `accessibilityReduceMotion` las **cinco** animaciones que ya existen
  (`ConversationPane.swift:104`, `ComposeView.swift:58`, anillo de `UsageIndicator`, hover de
  `PermissionButton`, autoscroll de `TranscriptView`). Hoy no hay ninguna referencia a ese entorno en
  el target.
- [ ] **H2** — Las cuatro nuevas de FR-20: fade por chunk del texto en streaming; transición de forma
  del tool call (pending → running → done); llegada de la superficie de permiso desde el borde del
  composer; entrada escalonada de las líneas de diff (~200ms).
- [ ] **H3** — Verificar que las nueve colapsan a estático o instantáneo con movimiento reducido
  activado. Nada infinito, nada decorativo.

### Phase I — Paridad de accesibilidad con lo que los NFR ya afirman

- [ ] **I1** — `@ScaledMetric` en los cinco frames fijos: botón circular (`26x26` +
  `.system(size: 12)`), anillo (`18x18`), popover de uso (`width: 250`), detalle de permiso
  (`maxHeight: 140`), campo de modelo (`width: 180`).
- [ ] **I2** — Atajo de teclado para las pills de `PermissionModeControl`, hoy sólo alcanzables con el
  ratón, mientras `PermissionPrompt` sí tiene `a`/`A`/`d`/`D`. FR-27 de 001 pide operación completa por
  teclado.
- [ ] **I3** — Pasada de VoiceOver sobre lo nuevo: niveles de elevación, acento, corrida de tool calls,
  hunks del diff.

### Phase J — Docs, preview y validación

- [ ] **J1** — DESIGN.md al día: la sección "Palette" con el acento y su ratio (viene de D5),
  "Typography and shape" describiendo tokens que existen en vez de convenciones que hay que recordar, y
  secciones nuevas para elevación y movimiento.
- [ ] **J2** — `PreviewData.seed()` cubre cada estado nuevo, **siempre a través de `Transcript.apply`**,
  nunca ensamblando un `Transcript` a mano. Es la regla de proceso de DESIGN.md y es condición de
  "hecho", no un seguimiento.
- [ ] **J3** — Matriz de verificación manual en `ZeroPreview.app`: tema claro × tema oscuro ×
  movimiento reducido × transparencia reducida × Dynamic Type (por defecto y el tamaño más grande).
- [ ] **J4** — Escaneos de seguridad antes del gate 3: Snyk SAST, Snyk SCA y SonarQube.

## Test plan

**Unit tests (`Tests/ZeroCoreTests/`)** — concentrados donde hay lógica:
- Motor de diff (F5): intercalado, números de línea en ambos lados, límites de hunk, colapso de tramos
  sin cambios, caso `Write` sin `oldText`, entrada vacía, textos idénticos, coste en archivo grande.
- Sin regresiones en los 207 tests existentes, en particular `FootprintBenchmarkTests` y los de
  `Transcript`, que la fase G toca de cerca.

**Lint automatizado (A5, D4)** — en CI: ningún `cornerRadius:` literal, ningún `.opacity(<literal>)`
sobre un color del tema, ningún `maxWidth:` literal en `Sources/Zero`, y `Theme.accent` referenciado en
exactamente dos archivos.

**Verificación manual (`ZeroPreview.app`)** — es el mecanismo que este proyecto ya usa para la UI, y no
hay tests de vistas que lo sustituyan:
- Los tres niveles de elevación se distinguen, y siguen distinguiéndose con transparencia reducida.
- El acento aparece **sólo** en el punto esperando-permiso, y la pantalla sigue siendo legible en escala
  de grises (D3).
- Ocho lecturas seguidas se leen como una corrida, no como ocho cajas.
- Un diff de un `Edit` real se lee intercalado, con números de línea.
- Una búsqueda que coincide dentro de una corrida colapsada la abre (G3).
- Con movimiento reducido, nada se mueve.
- Con el Dynamic Type más grande, nada se recorta.
- Arranque: `StartupClock` no empeora.

**Checkpoints** — `swift build && swift test` antes de cada commit; `./Scripts/make-preview.sh` cuando
el cambio se ve.

## Rollback notes

Cada fase es un commit o un grupo de commits revertible por separado, y el orden de riesgo es conocido:

- **D (acento)** es la más reversible y la más discutible: revertir `Theme.accent` y sus dos call sites
  devuelve la app a monocromo estricto sin tocar nada más. Si el acento no convence al verlo, se cae
  solo.
- **F (motor de diff)** es la de más lógica nueva, y queda **detrás del límite que `DiffView` ya
  tiene**: el tipo calculado vive en `ZeroCore` y `DiffView` es el único consumidor, así que volver al
  render anterior es cambiar un archivo de vista.
- **C (material)** puede degradarse al camino de `accessibilityReduceTransparency` de C3 para todos, que
  es rellenos sólidos, si un material nativo da problemas de rendimiento.
- **A y B (tokens y componentes)** son las menos reversibles porque todo lo demás se apoya en ellas, y
  también las más seguras: no cambian ni un píxel salvo los dos radios fuera de escala que corrigen a
  propósito.

El punto de retorno seguro es `develop`. Nada de esta rama toca persistencia, esquema, precios ni el
broker de permisos, así que no hay migración que deshacer.
