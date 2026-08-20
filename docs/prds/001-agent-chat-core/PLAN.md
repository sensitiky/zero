# Implementation Plan — Zero: núcleo de chat multi-agente con worktrees

## Branch / worktree

Branch: `feat/001-agent-chat-core`
Isolation mode: rama en el checkout actual (`/Users/mariocorrea/Documents/Projects/zero`)
Base: `develop`

## Estrategia y orden

El orden lo dicta el riesgo, no la visibilidad. La premisa entera del producto es que se puede
hablar el protocolo estructurado de tres proveedores distintos desde Swift sin PTY. Si eso no
funciona, nada de lo demás importa, así que se valida primero — contra procesos reales, antes
de escribir una sola vista.

Consecuencia: hay dos superficies de verificación desde la Fase A.

- **Tests con fixtures** — NDJSON grabado en disco, deterministas, corren siempre y sin
  autenticación. Es donde vive la cobertura de los FR.
- **`zero-probe`** — un ejecutable pequeño que abre una sesión real contra un CLI instalado y
  vuelca eventos normalizados. No corre en CI, no depende de él ningún test, y es lo que
  confirma que el fixture se parece a la realidad. Existe porque un adapter verificado solo
  contra sus propios fixtures no está verificado.

## Phases

### Phase A — Scaffolding

- [ ] **A1** Proyecto Xcode `Zero.xcodeproj`: app SwiftUI, bundle id `tech.incu.zero`, deployment target macOS 26.0, `ARCHS = arm64`.
- [ ] **A2** Swift 6 strict concurrency en modo completo, warnings como errores, `.swift-version` fijado a 6.3.3, versión de Xcode documentada en el README.
- [ ] **A3** Targets: `Zero` (app), `ZeroCore` (lógica, sin UI), `ZeroCoreTests`, `zero-probe` (ejecutable de verificación manual). Todo el transporte y los adapters viven en `ZeroCore` para que sean testeables sin arrancar la app.
- [ ] **A4** `Tests/Fixtures/` con la estructura por proveedor, vacía de momento.

Sin App Sandbox. Hardened Runtime activado ya en A1, no al final: si una entitlement rompe el
spawn de subprocesos, quiero saberlo en la Fase B y no en la G.

### Phase B — Transporte y adapters

El núcleo. Cada adapter se considera terminado cuando pasa sus tests con fixtures **y** hace un
turno completo contra el CLI real vía `zero-probe`.

- [ ] **B1** `AgentProcess`: `Process` con tres pipes, sin PTY, long-lived, stdin abierto entre turnos. Terminación limpia y detección de muerte del hijo. (FR-9, FR-16)
- [ ] **B2** `NDJSONStream`: framing de líneas sobre bytes. Maneja línea parcial en el borde del chunk, líneas vacías, JSON inválido sin tirar el stream, y líneas grandes. Es la pieza más fácil de romper en silencio y la que más tests lleva. (FR-9)
- [ ] **B3** `AgentEvent`: el modelo de dominio normalizado — texto incremental, tool call, resultado de tool, thinking, plan, petición de permiso, uso de tokens, fin de turno, error. Es el contrato que aísla al resto de la app de los tres protocolos. (FR-13)
- [ ] **B4** `ClaudeCodeAdapter`: `--output-format stream-json --input-format stream-json --verbose --permission-prompt-tool stdio`. Incluye la correlación `control_request` → `control_response` por id, que es donde se cuelan los bugs de permisos. (FR-10, FR-23)
- [ ] **B5** `CodexAdapter`: `codex app-server`, JSON-RPC 2.0 con estado, correlación de requests y ciclo de aprobaciones. (FR-11)
- [ ] **B6** `ACPAdapter`: `initialize`, `session/new`, `session/prompt`, `session/update`, `session/request_permission`. Comando configurable por proveedor. (FR-12)
- [ ] **B7** `ProviderRegistry`: resolución del binario a ruta absoluta desde lista configurable, versión, estado de autenticación, y razón de indisponibilidad legible. Nunca hereda `PATH` sin validar. (FR-14, seguridad)
- [ ] **B8** Cancelación de turno propagada al mecanismo de cada proveedor, sin matar el proceso. (FR-15)
- [ ] **B9** Log de protocolo crudo por sesión, apagado por defecto, con redacción de credenciales. (FR-17, seguridad)

### Phase C — Persistencia y puerta de medición

- [ ] **C1** Modelos SwiftData: `Repository`, `Session`, `Message`, `ToolCall`, `PermissionRequest`, `UsageRecord`, `PricingEntry`.
- [ ] **C2** **Puerta de medición.** Benchmark de append: 10k `Message` y 10k `UsageRecord` en escritura continua, midiendo p95 por append y memoria. El resultado se escribe en `docs/prds/001-agent-chat-core/MEASUREMENTS.md`. **Si no aguanta, aquí se pivota a SQLite**, antes de que exista código encima. No sigo a C3 sin este número.
- [ ] **C3** Persistir sesiones, mensajes, tool calls y uso. Restaurar la lista y el historial completo al arrancar. (FR-6)
- [ ] **C4** Reanudar sesión con el mecanismo de resume del proveedor, degradando a sesión nueva con historial de solo lectura cuando no lo expone. (FR-7)

### Phase D — Worktrees

- [ ] **D1** `GitService`: `worktree add` / `remove`, naming `zero/{slug}-{id-corto}` con contador ante colisión, detección de repo sucio, validación de que toda ruta de escritura cae bajo la raíz esperada. (FR-2, FR-8, seguridad)
- [ ] **D2** Creación de sesión: repo objetivo, proveedor, modelo, prompt inicial → worktree + proceso + sesión persistida. (FR-1)
- [ ] **D3** Cierre de sesión con confirmación explícita antes de borrar worktree o rama. Nunca borra ninguno sin ella. (FR-5)
- [ ] **D4** Estado de sesión: `idle` / `running` / `waiting-permission` / `error` / `finished`, derivado de los eventos del adapter. (FR-3)
- [ ] **D5** Concurrencia: N sesiones activas, cada una con su proceso y su stream, sin que ninguna bloquee a otra ni al main actor. (FR-4, NFR de rendimiento)

### Phase E — UI de chat

- [ ] **E1** Shell: sidebar de sesiones agrupadas por repo con estado y badge de "te está esperando", chat central, inspector colapsable. (FR-3)
- [ ] **E2** Transcript con streaming incremental de texto, y selección, copia y búsqueda incremental sobre todo el historial. (FR-18, FR-26)
- [ ] **E3** Celdas nativas: tool call colapsable con nombre/input/output/estado/duración, diffs de edición renderizados como diff, thinking en bloque aparte colapsado por defecto, plan del agente como lista con estado por ítem. (FR-19, FR-20, FR-21, FR-22)
- [ ] **E4** Permisos: control nativo in-chat con el detalle completo de la operación y permitir una vez / permitir siempre / denegar, mapeado al mecanismo de cada adapter. Modo de permisos por sesión, default el más restrictivo disponible. **Ninguna resolución puede originarse en output del modelo o de una herramienta.** (FR-23, FR-24, FR-25)
- [ ] **E5** Operación completa por teclado, incluida creación de sesión, cambio entre sesiones y respuesta a permisos. Command palette. (FR-27)
- [ ] **E6** Pase de accesibilidad: VoiceOver sobre transcript y controles de permiso, Dynamic Type, contraste en ambos temas. (NFR)

### Phase F — Tokens y costo

- [ ] **F1** Extraer uso por turno de los eventos de cada adapter: input, output, lectura y escritura de caché, cuando el proveedor lo reporta. (FR-28)
- [ ] **F2** Tabla de precios horneada y versionada, editable por el usuario. Precio ausente → tokens visibles y costo marcado como desconocido, nunca estimado en silencio. (FR-30)
- [ ] **F3** Inspector: acumulado por sesión y costo estimado, más aviso al acercarse al límite de contexto cuando el proveedor expone la ventana usada. (FR-29, FR-31)

### Phase G — Rendimiento y empaquetado

- [ ] **G1** Medir los NFR y registrarlos en `MEASUREMENTS.md`: cold start < 1 s, memoria < 400 MB con 5 sesiones y una streameando, ≥ 60 fps con 3 sesiones streameando en paralelo. **Son criterio de aceptación: si no se cumplen, la fase no termina.**
- [ ] **G2** Auditoría de main actor: ninguna operación de I/O, git o parseo fuera de un contexto en background. Se verifica leyendo el código y con Instruments, no por inspección casual.
- [ ] **G3** Verificar que el bundle no contiene Node, Electron ni ningún runtime de navegador.
- [ ] **G4** Firma, notarización y DMG.

## Test plan

Regla del proceso: cada FR mapea al menos a un test. Cobertura declarada:

| Área | Tests | FRs |
|---|---|---|
| `NDJSONStream` | línea partida entre chunks, línea vacía, JSON inválido no tira el stream, línea muy grande, EOF a media línea | FR-9 |
| `ClaudeCodeAdapter` | decode de fixtures a `AgentEvent`, correlación `control_request`/`control_response`, denegación, evento de uso | FR-10, FR-13, FR-23, FR-28 |
| `CodexAdapter` | decode de fixtures, correlación JSON-RPC por id, ciclo de aprobación | FR-11, FR-13, FR-23 |
| `ACPAdapter` | handshake, `session/update` en sus variantes, `session/request_permission` | FR-12, FR-13, FR-23 |
| `AgentProcess` | arranque, stdin persiste entre turnos, muerte del hijo → error con historial intacto, cancelación no mata el proceso | FR-9, FR-15, FR-16 |
| `ProviderRegistry` | binario ausente, versión no soportada, sin auth → razón legible; rechazo de ruta no validada | FR-14 |
| Log de protocolo | apagado por defecto; con log activo, ninguna credencial aparece en el output | FR-17 |
| Persistencia | round-trip de sesión con historial, restauración al arrancar, resume y su degradación | FR-6, FR-7 |
| Benchmark de append | 10k `Message` + 10k `UsageRecord`, p95 y memoria | C2, decisión SwiftData/SQLite |
| `GitService` | sobre repo temporal: worktree add/remove, colisión de rama → sufijo, repo sucio detectado, ruta fuera de la raíz rechazada | FR-2, FR-5, FR-8 |
| Estado de sesión | cada evento produce la transición esperada | FR-3, FR-4 |
| Permisos | una resolución solo se origina en acción del usuario o regla previa; contenido de tool output no puede aprobar ni escalar | **FR-25** |
| Costo | uso acumulado correcto; precio ausente → desconocido, no estimado | FR-29, FR-30, FR-31 |
| Rendimiento (medición, no test) | cold start, memoria con 5 sesiones, fps con 3 streams | NFR |

Los FR de UI que no admiten test unitario razonable — FR-18 a FR-22, FR-26, FR-27, y la
accesibilidad — van a la lista manual de abajo, y así queda dicho en vez de fingir cobertura.

**Checklist de validación manual:**

1. Tres sesiones en paralelo, proveedores distintos, sobre el mismo repo: cada una en su worktree, ninguna se pisa.
2. Streaming visible e incremental, no en bloques al terminar el turno.
3. Un tool call que pide permiso: el control aparece, el comando se lee completo, denegar lo detiene de verdad.
4. Una edición de archivo se ve como diff.
5. Búsqueda y copia sobre un transcript largo.
6. Crear sesión, cambiar de sesión y responder un permiso sin tocar el ratón.
7. Matar el CLI del proveedor a mano: la sesión va a `error` y el historial sigue ahí.
8. Cerrar y reabrir la app: sesiones e historial vuelven.
9. VoiceOver sobre transcript y control de permiso.

## Comandos de verificación

El skill `incu-way-development` especifica `pnpm typecheck && pnpm lint && pnpm test`, que no
aplica a este proyecto. Los equivalentes reales, a correr antes de cada commit:

```
xcodebuild -scheme Zero -destination 'platform=macOS' build
xcodebuild -scheme ZeroCoreTests -destination 'platform=macOS' test
```

Sin SwiftLint en v1: strict concurrency más warnings-as-errors cubre lo que importa, y añadir la
herramienta es instalar una dependencia de desarrollo para reglas de estilo en un proyecto de un
solo autor. Se revisa si el repo deja de ser privado.

Para Gate 3, los scans de seguridad del skill (`snyk_code_scan`, `snyk_sca_scan`,
`run-sonnar.sh`) hay que confirmar que soportan un proyecto Swift sin manifiesto de paquetes de
terceros — el SCA en particular puede no tener nada que analizar. Lo verifico en la Fase G y, si
alguno no corre, queda anotado en `TESTING.md` con el comando exacto que falló, no reportado
como limpio.

## Rollback notes

- El repo es nuevo y privado, y todo cuelga de `feat/001-agent-chat-core`. Revertir es descartar la rama; `develop` no tiene código de esta feature.
- Los worktrees que cree la app durante el desarrollo se limpian con `git worktree prune` más el borrado de las ramas `zero/*`. Ninguno vive dentro de este repo.
- El punto de pivote real es **C2**. Si la medición manda a SQLite, se rehace C1 y C3 y no se toca nada más, porque no hay capa de abstracción que reescribir ni consumidores encima todavía. Eso es precisamente por qué la puerta está antes de C3.
- La Fase B no toca disco del usuario salvo por lo que hagan los propios agentes dentro de su worktree.
