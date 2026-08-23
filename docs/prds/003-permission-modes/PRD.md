# PRD — Modo de permisos por sesión (Ask / Auto / Bypass)

## Status

Draft

## Contexto — qué existe hoy, verificado en el código

`001-agent-chat-core` decidió (FR-24, revisado el 2026-08-21) que Zero no debe reimplementar un
clasificador de riesgo propio: para Claude Code, `Bash`/`Write`/`Edit`/`NotebookEdit` deben quedar
enteramente bajo el juicio de `--permission-mode auto` del propio CLI, y solo `WebFetch`/
`WebSearch` deben seguir pasando por el broker nativo de Zero (FR-32), porque un fetch de red es un
vector de exfiltración que ningún clasificador de uso de herramienta detecta como riesgoso.

Esa decisión **no está implementada**:

- `ProviderDescriptor.claude.launchArguments` no incluye `--permission-mode` en absoluto
  (`Sources/ZeroCore/Providers/ProviderDescriptor.swift:75`).
- `HookSettings.defaultMatcher` intercepta `Bash|Write|Edit|NotebookEdit|WebFetch` — todo, no solo
  `WebFetch`/`WebSearch` — y a `WebSearch` ni siquiera lo nombra
  (`Sources/ZeroCore/Permissions/HookSettings.swift:12`).
- No existe ningún campo de modo de permisos en `Session` (`Persistence/Models.swift`) ni en
  `AppModel.SessionSnapshot` (`Sources/Zero/AppModel.swift:35`). FR-24 lo exige ("modo de permisos
  configurable por sesión, con el default más restrictivo") pero no hay dónde guardarlo ni cómo
  elegirlo.
- Codex y ACP sí resuelven permisos en banda hoy (`CodexEncoder.encodePermissionResponse`,
  `ACPEncoder.encodePermissionResponse` ya funcionan), pero siempre preguntan — no hay equivalente
  a "auto" ni a "bypass" para ninguno de los dos.

## Problem

Hoy, toda sesión de cualquier proveedor pregunta por cada tool call gateada, sin excepción y sin
forma de cambiarlo. Eso es exactamente lo opuesto a lo que FR-24 ya decidió para Claude Code, y dos
casos de uso reales quedan sin cubrir: (1) confiar en el juicio del proveedor para el trabajo de
rutina sin renunciar a la protección de red, y (2) un modo explícito de "no preguntes nada" para
cuando el usuario ya audita cada turno de otra forma (una sesión aislada, un worktree descartable)
y el prompt constante es fricción pura. Ninguno de los dos existe como control de usuario.

Quien lo siente: el mismo dev de `001-agent-chat-core` corriendo N sesiones en paralelo — cuantas
más sesiones activas, más prompts compitiendo por su atención, y hoy no tiene ningún dial entre
"pregúntame todo" y "no hay Zero en absoluto".

## Goals

- Un control de modo de permisos visible por encima del chat de cada sesión, con tres estados:
  **Ask**, **Auto**, **Bypass**.
- Implementar de una vez lo que FR-24 ya decidió para Claude Code (Auto delega en
  `--permission-mode auto` del CLI para `Bash`/`Write`/`Edit`/`NotebookEdit`; `WebFetch`/
  `WebSearch` quedan siempre gateados salvo en Bypass).
- Extender el mismo control, con semántica honesta según lo que cada protocolo expone hoy, a Codex
  y ACP — sin inventar flags de proveedor que este repo no ha verificado contra el binario real.
- El modo es una decisión del usuario o una regla que configuró antes (FR-25 de 001 sigue
  aplicando sin excepción): nada en el output del modelo puede cambiarlo.
- Default de sesión nueva: **Ask** — el más restrictivo, igual que exige FR-24.

## Non-goals

- Un clasificador de riesgo propio para Codex o ACP. Ya se descartó una vez para Claude Code
  (FR-36, retirado en 001) por duplicar peor un juicio que el proveedor hace con más contexto; no
  se reintroduce por la puerta de atrás para otro proveedor.
- Verificar o adoptar flags nativos de aprobación de Codex (`--ask-for-approval`, `--sandbox` o
  equivalentes) — no están capturados ni verificados en este repo todavía. Queda en Open Questions
  como trabajo futuro, sujeto al mismo proceso de verificación contra el binario real que ya usó
  Claude Code.
- Un modo por-herramienta granular (permitir Bash pero no Write, etc.). Los tres modos son la
  unidad de configuración; más granularidad es la siguiente feature si hace falta.
- Persistir el modo como preferencia global entre sesiones nuevas. Cada sesión nueva arranca en
  Ask; el usuario la sube de nivel si quiere.
- Cambiar el modo de permisos de una sesión ya en marcha sin relanzar el proceso del proveedor
  (ver FR-8 más abajo: cambiar de modo relanza, reusando el mecanismo de resume que ya existe).

## User stories

- Como dev, quiero poner una sesión de Claude Code en Auto para que el propio CLI decida sobre
  comandos y ediciones de rutina, sin dejar de ver un permiso cuando intenta salir a la red.
- Como dev, quiero un modo Bypass para una sesión desechable donde ya reviso todo el diff al final,
  sin que cada llamada a herramienta me interrumpa.
- Como dev, quiero que el modo se vea y se cambie sin abrir un inspector — es una decisión que tomo
  tan seguido como elijo el proveedor.
- Como dev, quiero que cambiar el modo en medio de una sesión no me haga perder el historial, igual
  que no lo pierdo hoy si el proceso muere y la sesión pasa a `error`.

## Functional requirements

### Modelo y contrato

1. Nuevo tipo `PermissionMode: String, Codable, Sendable` en `ZeroCore` con casos `ask`, `auto`,
   `bypass`. Vive junto a `PermissionRequest`/`PermissionOrigin` en `Permissions/`, porque es el
   mismo dominio.
2. `Session` (SwiftData) gana `var permissionMode: String = "ask"`. `SessionRuntime.CreationConfig`
   y `AppModel.SessionSnapshot` lo exponen como `PermissionMode`. Migración: un valor por defecto
   en el modelo cubre las filas existentes sin script de migración explícito (SwiftData rellena el
   default al leer una fila sin la columna).
3. Un cambio de modo solo puede originarse en una acción explícita del usuario sobre el control de
   esta feature. Ninguna ruta de decodificación de eventos del proveedor puede escribir
   `permissionMode` — mismo principio que FR-25 de `001-agent-chat-core`, extendido al modo en vez
   de a la resolución de un permiso puntual.

### Claude Code

4. **Ask** (default): matcher del hook = `Bash|Write|Edit|NotebookEdit|WebFetch|WebSearch` (corrige
   la ausencia de `WebSearch` en `HookSettings.defaultMatcher` hoy). Sin `--permission-mode` en el
   launch — se comporta como hoy.
5. **Auto**: matcher del hook = `WebFetch|WebSearch` únicamente, y se agrega `--permission-mode
auto` al launch de `claude`. `Bash`/`Write`/`Edit`/`NotebookEdit` no pasan por Zero en absoluto;
   el CLI decide y, si deniega algo, lo dice en su propia respuesta de texto (verificado en 001
   contra 2.1.237).
6. **Bypass**: no se instala ningún hook `PreToolUse` (sin `--settings`, sin `PermissionBroker`
   para esa sesión) y se agrega `--permission-mode bypassPermissions` al launch. Cero prompts,
   incluido `WebFetch`/`WebSearch`. **A verificar contra el CLI real en la Fase 3** (`zero-probe`,
   mismo proceso que ya usó 001) antes de dar el valor del flag por bueno — si `bypassPermissions`
   no es el nombre real o no existe en la versión instalada, el plan se ajusta ahí, no se asume.

### Codex y ACP

7. Ninguno de los dos protocolos expone hoy, verificado en este repo, un mecanismo para que el
   propio proveedor apruebe sin preguntar (Codex: sin flag de approval-policy capturado; ACP: el
   spec no tiene equivalente a "el agente decide solo"). Por eso Auto y Bypass en estos dos
   proveedores **no delegan en el proveedor** — Zero resuelve la petición localmente sin mostrar la
   UI:
   - **Ask**: como hoy — `permissionRequested` muestra `PermissionPrompt` y espera al usuario.
   - **Auto** y **Bypass**: Zero responde cada `permissionRequested` con `allow_once` sin mostrar el
     control, con `PermissionOrigin` = regla de sesión (`userConfiguredRule("permission-mode:
<modo>")`), nunca como si viniera del output del modelo (FR-25).
   - Auto y Bypass son idénticos para estos dos proveedores en v1, porque ninguno distingue hoy una
     categoría "red" separable como sí lo hace Claude Code con `WebFetch`/`WebSearch`. Ver Open
     Questions.

### UI

8. Control de modo por encima del composer, siempre visible mientras una sesión está seleccionada
   — no dentro del inspector colapsable (FR-24 pide "configurable por sesión"; esta feature pide
   además que sea la superficie primaria, no una secundaria). Tres opciones, sin color: mismo
   lenguaje del resto de la app (peso y forma, no matiz — ver `docs/DESIGN.md`).
9. Cambiar el modo en una sesión con proceso activo relanza el proceso del proveedor con el nuevo
   modo, reusando el mecanismo de resume de FR-7 (resume nativo cuando el proveedor lo expone,
   degradando a sesión nueva con historial de solo lectura cuando no). No se inventa un mecanismo
   de "hot swap" nuevo.
10. Seleccionar Bypass muestra una advertencia inline junto al control (no un modal — no rompe
    FR-27, operación por teclado) mientras ese modo esté activo, para que la sesión sin ningún
    prompt nunca se vea igual que una sesión en Ask.
11. `PreviewData.seed()` se actualiza con sesiones en los tres modos, por la regla de proceso de
    `docs/DESIGN.md` ("todo cambio de UI actualiza el preview").

## Non-functional requirements

- **Seguridad.** El broker sigue fail-closed: si Zero no puede determinar el modo de una sesión
  (fila corrupta, valor inesperado), se trata como `ask`, nunca como `bypass`. Un modo de permisos
  que falla abierto es exactamente el bug que `PermissionBroker` ya evita para una petición
  puntual (ver su doc comment) — el mismo principio cubre ahora la lectura del modo.
- **Accesibilidad.** El control de modo lleva accessibility label explícito con el estado actual y
  es operable enteramente por teclado (FR-27 de 001).
- **Sin nueva superficie de red ni credenciales.** Esta feature no toca transporte ni auth.

## Data model changes

- `Session.permissionMode: String` (nuevo campo, default `"ask"`).
- Sin tablas nuevas. `PermissionRequestRecord` no cambia — un permiso auto-resuelto en Codex/ACP se
  sigue registrando igual, con `resolvedBySource = "userConfiguredRule:permission-mode:<modo>"` en
  vez de `"userAction"`, para que quede trazable qué lo aprobó.

## UI/UX notes

- Ubicación: una fila delgada inmediatamente encima del composer, dentro del mismo `zeroSurface`
  que ya envuelve `TranscriptView` + `PermissionPrompt` + composer en `ConversationPane` — no un
  panel nuevo. Un `Menu` o control segmentado de tres opciones, capsule, mismo lenguaje visual que
  `PermissionButton` (relleno = seleccionado, contorno = el resto, sin color).
- El nombre del modo activo es visible sin abrir nada — "Ask" / "Auto" / "Bypass" — igual que el
  proveedor y el modelo ya son visibles sin abrir el inspector.
- La advertencia de Bypass (FR-10) usa el mismo tono que el resto de la app: texto, no un icono de
  alerta de color — este palette no tiene un color de "peligro" y no se inventa uno para un solo
  estado.

## Open questions

1. **Flags nativos de Codex.** ¿Vale la pena, en una siguiente PRD, verificar contra el binario
   real (`codex app-server --help` y tráfico capturado, mismo proceso que Claude Code) si existe un
   modo de aprobación propio que Auto pueda delegar, en vez de que Zero auto-resuelva localmente?
   No bloquea esta PRD — la v1 de Codex/ACP descrita arriba (FR-7) es coherente y honesta con lo que
   hoy está verificado.
   Rta: De momento con claude alcanza
2. ~~`--permission-mode bypassPermissions`.~~ **Resuelto**: verificado contra `claude --help`
   (2.1.241, instalado en la máquina de desarrollo) — `bypassPermissions` y `auto` son valores
   válidos reales, junto a `acceptEdits`, `manual`, `dontAsk` y `plan`.
   Rta: De momento busca la mejor implementacion
3. **Relanzar en medio de sesión (FR-9).** Para Codex y ACP, ¿el resume nativo ya cubierto en
   `001-agent-chat-core` (FR-7) alcanza para relanzar sin perder contexto, o degradan siempre a
   "sesión nueva con historial de solo lectura" al cambiar de modo? Se resuelve con la misma
   verificación de FR-7, no con un mecanismo nuevo — a confirmar en el plan de implementación.
   Rta: Alcanza para relanzar sin perder contexto

## Conflicts / dependencies

Extiende `001-agent-chat-core`: implementa la parte de FR-24 que quedó pendiente, corrige el
matcher de `HookSettings` para incluir `WebSearch` (hoy ausente pese a que el PRD ya lo nombra), y
reutiliza sin cambios FR-25 (origen de una resolución), FR-32/33/34/35 (broker) y FR-7 (resume).
No hay conflicto con `002-ci-cd-releases` (CI/CD, no toca este subsistema).
