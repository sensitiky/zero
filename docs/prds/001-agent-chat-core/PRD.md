# PRD — Zero: núcleo de chat multi-agente con worktrees

## Status

In Review

## Contexto y referencias

| Referencia                                    | Qué tomamos                                                                                                                                                     | Qué descartamos                                                   |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| [t3code](https://github.com/pingdotgg/t3code) | Arquitectura sin PTY: el CLI del proveedor es un subproceso long-lived que habla NDJSON por stdio, y la UI de chat es nativa. Modelo de adapters por proveedor. | Server Node + clientes Electron/web/móvil.                        |
| [Superset](https://docs.superset.sh)          | Un worktree git aislado por tarea, N agentes en paralelo, BYO subscription.                                                                                     | Chat con API keys propias, automations, MCP server, relay remoto. |
| [Orca](https://www.onorca.dev/docs)           | Sesiones persistentes con hibernación, worktrees reales (no abstracciones).                                                                                     | Editor de código, panel de browser, terminal embebida, SSH.       |

Hallazgo de discovery que habilita este PRD: los tres proveedores objetivo exponen protocolos
de proceso a proceso sobre stdio, así que no hace falta Node ni Electron en el bundle.

- Claude Code: `claude --print --output-format stream-json --input-format stream-json --verbose --permission-prompt-tool stdio`. Los permisos llegan como `control_request` / `can_use_tool` y se responden con un `control_response` correlacionado.
- Codex: `codex app-server`, JSON-RPC 2.0 NDJSON bidireccional y con estado, binario Rust nativo.
- ACP ([spec](https://agentclientprotocol.com)): JSON-RPC 2.0 sobre stdio — `initialize`, `session/new`, `session/prompt`, `session/update`, `session/request_permission`, `fs/*`, `terminal/*`.

## Problem

Los harnesses de agentes que existen hoy en Mac se pagan con recursos que el usuario necesita
para otra cosa. Los basados en Electron (t3code, Superset) arrancan un runtime de navegador
completo para una tarea que es, en el fondo, orquestar subprocesos y renderizar una lista de
mensajes. Los IDE completos (Orca) suman editor y browser encima. En una máquina que además
está corriendo el propio agente, un compilador de Swift y un simulador, ese overhead compite
directamente con el trabajo.

El segundo problema es de interacción, y es el que motiva este proyecto: la mayoría de las
herramientas embeben una PTY con la TUI del proveedor dentro de un panel. El usuario termina
leyendo una interfaz de terminal dentro de una ventana gráfica, lo que cuesta búsqueda sobre
el historial, selección de texto fiable, permisos como UI real en vez de un prompt de teclado,
y cualquier composición del contenido (un diff renderizado como diff, un plan como lista).
t3code ya demostró que ese trade-off no es necesario: si hablas el protocolo estructurado del
proveedor en vez de su TUI, la UI nativa sale gratis.

Quien lo siente: desarrolladores que trabajan a diario en macOS con varios agentes en paralelo
sobre el mismo repo y quieren que el harness sea la parte barata del stack.

## Goals

- Chat nativo sin PTY: cero emulación de terminal en la ruta de conversación.
- N sesiones concurrentes, cada una en su propio worktree git real, sin conflictos entre ellas.
- Permisos de herramienta como UI nativa dentro del chat, no como prompt de terminal.
- Consumo de tokens y costo estimado visibles por turno y acumulados por sesión.
- Footprint medible y defendible: ver los NFR de rendimiento, que son criterio de aceptación y no aspiración.
- BYO subscription: la app nunca intermedia credenciales ni cobra tokens.
- Una capa de adapters que soporte tres protocolos distintos sin filtrar sus diferencias al resto de la app.

## Non-goals

Fuera de v1, explícitamente:

- Editor de código, panel de browser, terminal embebida (Orca).
- Diff viewer, stage/commit/push, abrir PRs desde la app. Es la siguiente feature, no esta.
- Chat con API keys propias del usuario y model picker directo a proveedor (built-in chat de Superset).
- Acceso remoto, SSH, relay, apps móviles, cuentas múltiples por proveedor.
- Automations, sesiones programadas, MCP server propio.
- Linux, Windows, Mac App Store.
- Cualquier integración con Linear, Slack o IDEs.

## User stories

- Como dev, quiero describir una tarea y elegir agente, y que arranque en su propio worktree, para no pisar mi checkout ni el trabajo de otra sesión.
- Como dev, quiero lanzar tres tareas a la vez y ver el estado de cada una de un vistazo, para saber cuál me está esperando.
- Como dev, quiero que cuando el agente pida permiso para correr un comando aparezca un control nativo con el comando legible, para decidir sin leer una TUI.
- Como dev, quiero buscar y copiar texto de cualquier punto del historial, porque es donde está la información que necesito reusar.
- Como dev, quiero ver cuántos tokens costó cada turno y cuánto llevo gastado en la sesión, para no descubrirlo en la factura.
- Como dev, quiero cerrar la app y al reabrirla encontrar mis sesiones y su historial, para no perder contexto por reiniciar.
- Como dev, quiero que un agente que no está instalado me lo diga con claridad al elegirlo, en vez de fallar de forma opaca.

## Functional requirements

### Sesiones y worktrees

- **FR-1** — Crear una sesión desde un prompt inicial, eligiendo repo objetivo, proveedor y modelo.
- **FR-2** — Cada sesión obtiene un worktree git dedicado vía `git worktree add`, en rama nueva derivada de una base configurable (default: la rama actual del repo objetivo).
- **FR-3** — La app lista las sesiones con estado explícito: `idle`, `running`, `waiting-permission`, `error`, `finished`.
- **FR-4** — N sesiones corren concurrentemente. La actividad de una sesión no bloquea la UI ni el streaming de otra.
- **FR-5** — Al cerrar una sesión, la app ofrece conservar o eliminar el worktree y la rama, y nunca elimina ninguno de los dos sin confirmación.
- **FR-6** — Sesiones, mensajes, tool calls y contadores persisten localmente. Reabrir la app restaura la lista y el historial completo.
- **FR-7** — Una sesión persistida se puede reanudar, usando el mecanismo de resume del proveedor cuando lo expone, y degradando a sesión nueva con historial de solo lectura cuando no.
- **FR-8** — Si el repo objetivo tiene cambios sin commitear, la app lo informa antes de crear el worktree y pide confirmación.

### Transporte y adapters

- **FR-9** — Los subprocesos de proveedor se lanzan sin PTY, con stdin/stdout/stderr por pipes, un proceso long-lived por sesión y stdin abierto entre turnos.
- **FR-10** — `ClaudeCodeAdapter`: stream-json bidireccional. Los permisos NO viajan en este stream — ver FR-32.
- **FR-11** — `CodexAdapter`: `codex app-server`, JSON-RPC 2.0 NDJSON, incluido el ciclo de aprobaciones.
- **FR-12** — `ACPAdapter` genérico: `initialize` / `session/new` / `session/prompt` / `session/update` / `session/request_permission`, configurable por comando para abrir Gemini, OpenCode y otros.
- **FR-13** — Los tres adapters normalizan a un mismo modelo de eventos de dominio. El resto de la app no distingue proveedores.
- **FR-14** — Detección de proveedores al arrancar y al elegir agente: binario presente, versión, estado de autenticación. Un proveedor no disponible se muestra deshabilitado con la razón y la acción de remedio.
- **FR-15** — Cancelar el turno en curso, propagando el mecanismo de cancelación del proveedor sin matar la sesión.
- **FR-16** — Si el subproceso muere o el stream se corrompe, la sesión pasa a `error` con el detalle y conserva íntegro el historial ya recibido.
- **FR-17** — Todo tráfico crudo del protocolo se puede volcar a un log por sesión, desactivado por defecto, para diagnosticar adapters.

### Chat

- **FR-18** — El texto del asistente se renderiza incrementalmente a medida que llega. Para Claude Code esto exige `--include-partial-messages`, que añade records `stream_event` con deltas; sin ese flag el CLI emite mensajes completos y no hay streaming que mostrar.
- **FR-19** — Cada tool call es una celda nativa colapsable con nombre, input, output, estado y duración.
- **FR-20** — Las ediciones de archivo se renderizan como diff con resaltado, no como texto crudo.
- **FR-21** — El razonamiento/thinking va en un bloque visualmente distinto y colapsable, colapsado por defecto.
- **FR-22** — El plan o lista de tareas del agente se renderiza como lista nativa con estado por ítem.
- **FR-23** — Las peticiones de permiso se presentan como control nativo in-chat con el detalle completo de la operación y las acciones permitir una vez / permitir siempre / denegar. El mecanismo de transporte difiere por proveedor y no es uniforme: Codex y ACP lo exponen en su protocolo, Claude Code requiere el broker de FR-32.
- **FR-24** — Modo de permisos configurable por sesión, con el default más restrictivo de los disponibles.
- **FR-25** — Una petición de permiso solo se resuelve por acción explícita del usuario o por una regla que el usuario configuró antes. Nada en el output del modelo o de una herramienta puede aprobar, escalar ni ampliar un permiso.
- **FR-26** — Todo el transcript admite selección, copia y búsqueda incremental.
- **FR-27** — La app es operable enteramente por teclado, incluida la creación de sesiones, el cambio entre ellas y la respuesta a permisos.

### Broker de permisos para Claude Code

- **FR-32** — Para Claude Code, Zero interpone un hook `PreToolUse` que bloquea la tool call antes
  de ejecutarla y consulta a la app. La configuración se inyecta por `--settings` con JSON en
  línea, de modo que Zero **nunca escribe en los settings del usuario**. El hook es un helper
  Swift que Zero empaqueta; se conecta a la app por un unix socket, la app muestra la UI nativa de
  FR-23, y el helper devuelve la decisión.
- **FR-33** — La correlación petición/respuesta va por el socket, no por el stream NDJSON. Zero no
  depende de que el CLI emita ningún record para saber qué se está preguntando.
- **FR-34** — Si el helper no puede alcanzar la app, o la app no responde dentro de un plazo, el
  helper **deniega**. Un broker de permisos que falla abierto es peor que no tener broker.
- **FU-35** — El socket es por sesión, con permisos de solo-usuario, y la app valida que la
  petición corresponda a una sesión viva que ella misma lanzó. El helper es la única cosa que
  puede resolver un permiso además del usuario, y solo puede hacerlo transportando su decisión.

### Tokens y costo

- **FR-28** — Por turno: tokens de input, output, lectura de caché y escritura de caché, cuando el proveedor los reporta.
- **FR-29** — Por sesión: acumulado de tokens y costo estimado.
- **FR-30** — Cuando el proveedor reporta el costo real, se usa ese número y no se estima. Claude Code lo hace: `result/success` trae `total_cost_usd`. Para los que no lo reportan, los precios viven en una tabla local versionada y editable. Si falta el precio de un modelo, la app muestra los tokens y marca el costo como desconocido, nunca estima en silencio.
- **FR-31** — Aviso cuando la sesión se acerca al límite de contexto del modelo, si el proveedor expone la ventana usada.

## Non-functional requirements

### Rendimiento — criterio de aceptación, no aspiración

Medido en Apple Silicon, build release, macOS 26:

- Cold start hasta ventana interactiva: < 1 s.
- Memoria residente con 5 sesiones abiertas y una streameando: < 400 MB.
- La UI no cae por debajo de 60 fps durante streaming concurrente de 3 sesiones.
- Ninguna operación de I/O, git o parseo corre en el main actor.
- El bundle no incluye Node, Electron, ni ningún runtime de navegador.

### Plataforma

Toolchain de referencia, verificado en la máquina de desarrollo:

| | Versión |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| Xcode | 26.6 (build 17F113) |
| SDK | macOS 26.5 — el único instalado |
| Target triple | `arm64-apple-macosx26.0` |

- **Deployment target: macOS 26.0.** Es el default del toolchain instalado y la propuesta del PRD. Consecuencia deliberada: cero ramas de `@available` en todo el código, y acceso directo al SwiftUI y al lenguaje de diseño de macOS 26 sin fallbacks. Coste: excluye macOS 15 y anteriores. Ver Open Questions — la decisión depende de si el repo es público.
- Swift 6 con strict concurrency activado en modo completo. Los adapters son el núcleo concurrente de la app (un subproceso, dos pipes y un stream por sesión), así que el aislamiento lo verifica el compilador y no la revisión.
- Apple Silicon únicamente. Sin binario universal ni soporte Intel.
- Sin dependencias de terceros salvo justificación explícita caso por caso.
- Distribución fuera del App Sandbox: DMG firmado y notarizado con Hardened Runtime. El sandbox queda descartado por diseño, porque prohíbe lanzar binarios arbitrarios y leer rutas del usuario, que son el núcleo del producto.
- El toolchain se fija en el repo (`.swift-version` y la versión de Xcode documentada) para que el build sea reproducible y no dependa de qué tenga instalado quien compile.

### Seguridad

- Los binarios de proveedor se resuelven por ruta absoluta a partir de una lista configurable, nunca por `PATH` heredado sin validar.
- Las rutas de worktree se validan contra la raíz de repo esperada antes de cualquier operación de escritura.
- Ni credenciales ni tokens de sesión de proveedor se escriben en logs ni en el store local. La app no los lee.
- Ver FR-25: el contenido generado por el modelo o devuelto por una herramienta es dato, nunca instrucción sobre la propia app.

### Accesibilidad

- VoiceOver sobre el transcript y los controles de permiso, Dynamic Type, contraste suficiente en ambos temas, operación completa por teclado (FR-27).

## Data model changes

Store local nuevo, no hay esquema previo. Entidades:

- `Repository` — ruta, nombre, rama base default.
- `Session` — repo, proveedor, modelo, worktree path, rama, estado, timestamps, id de sesión del proveedor para resume.
- `Message` — sesión, rol, contenido, orden, timestamps.
- `ToolCall` — mensaje, nombre, input, output, estado, duración.
- `PermissionRequest` — sesión, tool call, detalle, resolución, quién y cuándo la resolvió.
- `UsageRecord` — sesión, turno, tokens por categoría, modelo, costo estimado.
- `PricingEntry` — proveedor, modelo, precios por categoría, versión de la tabla.

Motor propuesto: SwiftData, por ser la opción nativa de la plataforma. El riesgo es que el
patrón de escritura es append-heavy sobre `Message`/`UsageRecord`, que es donde SwiftData es
más débil. Ver Open Questions.

## UI/UX notes

Tres zonas, layout de shell nativo:

- **Sidebar** — lista de sesiones agrupadas por repo, con estado y badge de "te está esperando".
- **Centro** — el chat de la sesión activa: transcript, composer, controles de turno.
- **Inspector** (colapsable) — tokens y costo de la sesión, info del worktree y rama, proveedor y modelo, modo de permisos.

Creación de sesión desde un solo campo con selector de agente. Command palette para todo lo
demás. La regla que gobierna cada decisión de esta capa: si algo se ve como salida de terminal,
está mal renderizado.

Al fijar el deployment target en macOS 26, la app adopta el lenguaje de diseño del sistema
directamente, sin capa de compatibilidad. Los materiales y controles son los nativos de la
versión, no una reimplementación.

## Decisiones resueltas

Resueltas por juicio de ingeniería, con el default declarado. Cada una es reversible y se
anota por qué se eligió, para que revertirla sea una decisión y no un descubrimiento.

- **Persistencia: SwiftData, con puerta de medición en Fase B.** Es la opción nativa. No se
  construye ninguna capa de abstracción de store para "poder cambiar después": eso sería una
  interfaz con una sola implementación. En su lugar, Fase B incluye un benchmark de escritura
  (10k mensajes y 10k `UsageRecord` en append continuo) *antes* de que exista código encima.
  Si el p95 de append o la memoria no aguantan, se cambia a SQLite ahí mismo, cuando el
  refactor cuesta poco.

- **Adapters ACP: solo comandos ya instalados, nunca `npx` bajo demanda.** El comando de cada
  adapter ACP es configurable (FR-12) y se detecta como cualquier otro proveedor (FR-14). Se
  descarta descargar y ejecutar código de terceros al abrir una sesión: una app cuyo trabajo
  es pedir permiso antes de cada operación no puede tener como default bajar un paquete de la
  red y ejecutarlo sin preguntar. Si el adapter no está, el proveedor aparece deshabilitado
  con la razón. Node en runtime queda aceptado, pero solo el que el usuario ya instaló.

- **Tabla de precios: horneada en la app, se actualiza con cada release.** Sin red saliente.
  La app no necesita red para nada más y añadirla solo para precios no lo justifica. Si falta
  el precio de un modelo, se muestran los tokens y el costo va marcado como desconocido (FR-30).

- **Nombres de rama de worktree: `zero/{slug}-{id-corto}`,** donde el slug se deriva del prompt
  inicial. Si la rama ya existe, se sufija con contador. Nunca se reutiliza una rama existente
  ni se fuerza nada sobre ella.

- **Auto-update: fuera de v1.** Se distribuye el DMG a mano. Sparkle es una dependencia de
  terceros y el NFR de plataforma pide justificar cada una; para un v1 sin usuarios externos
  no hay caso. Se revisa si el repo pasa a público.

- **Transporte de los adapters: stdio, sin abstracción de transporte.** El app-server de Codex
  ya soporta WebSocket, así que el día que haga falta remoto el refactor está bien entendido.
  Hasta entonces no se paga con una capa que tendría un solo implementador.

## Open questions

Ninguna. Las tres que quedaban abiertas se cerraron con decisión del usuario:

- **Nombre del producto: Zero.** Bundle id `tech.incu.zero`. Prefijo de rama de worktree
  `zero/{slug}-{id-corto}`.
- **Repo privado, de uso propio.** Sin licencia pública ni distribución a terceros en v1.
- **Piso de versión: macOS 26.0.** Confirmado. Cero `@available` en todo el código, Apple
  Silicon únicamente, y auto-update descartado también a futuro mientras el repo siga privado
  (lo que convierte en definitiva la decisión resuelta sobre Sparkle).

## Conflicts / dependencies

Primer PRD del proyecto, sin conflictos con features existentes.

Dependencias externas, todas del entorno del usuario y ninguna empaquetada:

- Los CLIs de proveedor, instalados y autenticados por el usuario.
- `git` con soporte de worktrees.
- Node en runtime solo si se resuelve la pregunta abierta 3 a favor de los adapters ACP de terceros.

## Revisiones verificadas contra el CLI real

El 2026-08-21, antes de escribir el adapter definitivo, se capturó tráfico real de Claude Code
2.1.237 (ver `Tests/ZeroCoreTests/Fixtures/claude-code/PROVENANCE.md`). Tres cosas que este PRD
afirmaba resultaron falsas y están corregidas arriba:

1. `--permission-prompt-tool stdio` **no existe**. Venía de un resultado de búsqueda, no del CLI.
2. **No hay `control_request` / `can_use_tool` en el cable.** En modo `-p` una tool call fuera de
   las allow rules produce `system/permission_denied` y se deniega: el CLI no pregunta al host.
   Los callbacks de aprobación son de los SDK de Python y TypeScript, no del CLI.
3. El streaming incremental necesita `--include-partial-messages`.

De ahí sale el broker de FR-32, verificado end-to-end: un hook `PreToolUse` devolviendo
`permissionDecision: "deny"` bloquea un `Write` incluso con `--permission-mode acceptEdits`, y
recibe `tool_name`, `tool_input`, `session_id`, `cwd` y `permission_mode` por stdin.

La lección de proceso, que vale más que las tres correcciones: **un protocolo se verifica contra
el binario, no contra la documentación ni contra una búsqueda.** Es exactamente para lo que existe
`zero-probe` en el plan.

## Notas de proceso

El `STATE.md` canónico de incu-board (`~/.claude/tools/incu-board/STATE.md`) no existe en esta
máquina. El archivo de estado en `.incu-way/items/001-agent-chat-core.json` usa el esquema que
implica la tabla de actualización del skill `incu-way-development`. Si el STATE.md canónico
aparece y difiere, hay que reconciliar el archivo.
