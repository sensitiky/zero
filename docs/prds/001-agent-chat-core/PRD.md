# PRD — Núcleo de chat multi-agente con worktrees (Zero)

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
- **FR-10** — `ClaudeCodeAdapter`: stream-json bidireccional, con permisos por `control_request`/`control_response`.
- **FR-11** — `CodexAdapter`: `codex app-server`, JSON-RPC 2.0 NDJSON, incluido el ciclo de aprobaciones.
- **FR-12** — `ACPAdapter` genérico: `initialize` / `session/new` / `session/prompt` / `session/update` / `session/request_permission`, configurable por comando para abrir Gemini, OpenCode y otros.
- **FR-13** — Los tres adapters normalizan a un mismo modelo de eventos de dominio. El resto de la app no distingue proveedores.
- **FR-14** — Detección de proveedores al arrancar y al elegir agente: binario presente, versión, estado de autenticación. Un proveedor no disponible se muestra deshabilitado con la razón y la acción de remedio.
- **FR-15** — Cancelar el turno en curso, propagando el mecanismo de cancelación del proveedor sin matar la sesión.
- **FR-16** — Si el subproceso muere o el stream se corrompe, la sesión pasa a `error` con el detalle y conserva íntegro el historial ya recibido.
- **FR-17** — Todo tráfico crudo del protocolo se puede volcar a un log por sesión, desactivado por defecto, para diagnosticar adapters.

### Chat

- **FR-18** — El texto del asistente se renderiza incrementalmente a medida que llega.
- **FR-19** — Cada tool call es una celda nativa colapsable con nombre, input, output, estado y duración.
- **FR-20** — Las ediciones de archivo se renderizan como diff con resaltado, no como texto crudo.
- **FR-21** — El razonamiento/thinking va en un bloque visualmente distinto y colapsable, colapsado por defecto.
- **FR-22** — El plan o lista de tareas del agente se renderiza como lista nativa con estado por ítem.
- **FR-23** — Las peticiones de permiso se presentan como control nativo in-chat con el detalle completo de la operación y las acciones permitir una vez / permitir siempre / denegar, mapeadas al mecanismo de respuesta del adapter correspondiente.
- **FR-24** — Modo de permisos configurable por sesión, con el default más restrictivo de los disponibles.
- **FR-25** — Una petición de permiso solo se resuelve por acción explícita del usuario o por una regla que el usuario configuró antes. Nada en el output del modelo o de una herramienta puede aprobar, escalar ni ampliar un permiso.
- **FR-26** — Todo el transcript admite selección, copia y búsqueda incremental.
- **FR-27** — La app es operable enteramente por teclado, incluida la creación de sesiones, el cambio entre ellas y la respuesta a permisos.

### Tokens y costo

- **FR-28** — Por turno: tokens de input, output, lectura de caché y escritura de caché, cuando el proveedor los reporta.
- **FR-29** — Por sesión: acumulado de tokens y costo estimado.
- **FR-30** — Los precios viven en una tabla local versionada y editable por el usuario. Si falta el precio de un modelo, la app muestra los tokens y marca el costo como desconocido, nunca estima en silencio.
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

## Open questions

1. **Nombre del producto.** Asumido "Zero" por el directorio del proyecto. Confirmar o cambiar antes de que aparezca en el bundle id.
   Rta: Si
2. **SwiftData vs SQLite directo** (GRDB o el driver de C). SwiftData es la opción nativa pero el patrón es append-heavy. Propuesta: medir en Fase B con volumen realista y decidir con dato, no con preferencia.
   Rta: SwiftData siempre
3. **Cómo se lanzan los adapters ACP.** Los de Gemini y OpenCode son paquetes Node de terceros. ¿`npx` bajo demanda, o exigir instalación previa y solo detectarlos? Esto reintroduce Node en runtime, aunque no en el bundle.
   Rta: On demand
4. **Tabla de precios.** ¿Se hornea en la app y se actualiza con releases, o se busca en remoto? Buscarla en remoto implica red saliente, que hasta ahora la app no necesita.
   Rta: Se hornea en la app
5. **Modelo de nombres de rama** para los worktrees, y qué pasa cuando la rama ya existe.
   Rta: a tu criteria
6. **Licencia y si el repo es público.** t3code argumenta la apertura como garantía de fork; si eso importa aquí, condiciona decisiones desde ya. Está acoplada a la pregunta 9: un repo público con piso en macOS 26 excluye a buena parte de los usuarios potenciales.
   Rta: es un producto para mi
7. **Auto-update.** Sparkle es la opción estándar y es una dependencia de terceros, contra el NFR de plataforma. ¿Se acepta la excepción o se distribuye manual?
   Rta: se acepta la excepcion
8. **Transporte remoto.** El app-server de Codex ya soporta WebSocket. Está fuera de v1, pero ¿se reserva la abstracción de transporte en el adapter, o se asume stdio y se refactoriza el día que haga falta?
9. **Piso de versión de macOS.** El PRD propone macOS 26.0, que es el default del toolchain y elimina todo `@available`. Si la app es solo para tu máquina, es la elección correcta sin discusión. Si el repo va a ser público, bajar a macOS 15 amplía el alcance a cambio de ramas de compatibilidad en la capa de UI. Requiere además instalar el SDK de macOS 15, que hoy no está en la máquina.
   Rta: elije la mejor opcion

## Conflicts / dependencies

Primer PRD del proyecto, sin conflictos con features existentes.

Dependencias externas, todas del entorno del usuario y ninguna empaquetada:

- Los CLIs de proveedor, instalados y autenticados por el usuario.
- `git` con soporte de worktrees.
- Node en runtime solo si se resuelve la pregunta abierta 3 a favor de los adapters ACP de terceros.

## Notas de proceso

El `STATE.md` canónico de incu-board (`~/.claude/tools/incu-board/STATE.md`) no existe en esta
máquina. El archivo de estado en `.incu-way/items/001-agent-chat-core.json` usa el esquema que
implica la tabla de actualización del skill `incu-way-development`. Si el STATE.md canónico
aparece y difiere, hay que reconciliar el archivo.
