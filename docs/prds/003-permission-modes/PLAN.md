# Implementation Plan — Modo de permisos por sesión (Ask / Auto / Bypass)

## Branch / worktree

Branch: `feat/003-permission-modes`
Isolation mode: rama en el checkout actual
Base: `develop`

## Hallazgos previos al plan (verificados leyendo el código, no asumidos)

Dos huecos preexistentes quedaron al descubierto durante el discovery y son prerequisito directo
de este PRD, no trabajo aparte:

- **`SessionCoordinator.answerPermission` nunca responde a Codex/ACP.** Solo resuelve
  `pendingResolvers`, poblado exclusivamente por el broker de Claude Code. Un permiso de Codex/ACP
  hoy se muestra, se puede "responder" en la UI, y esa respuesta nunca llega al proceso — el
  `PermissionRequest.id` correlacionado nunca vuelve por el wire. FR-7 no puede auto-resolver nada
  para estos dos proveedores sin esta pieza, así que se construye aquí (Fase B).
- **`SessionRuntime.resume()` no instala el hook de Claude Code.** Reanudar una sesión de Claude
  Code hoy la deja sin `PreToolUse` en absoluto — el permiso hoy vigente para la sesión original se
  pierde al reanudar. FR-9 (cambiar de modo relanza vía resume) necesita que `resume()` sepa
  instalar el hook igual que `create()`, así que se unifica ahí (Fase C).
- **`Store.resolvePermissionRequest` nunca se llama** en ningún camino existente — ni siquiera el
  de Claude Code hoy. Registrar la resolución de una petición es, por tanto, trabajo preexistente
  sin terminar en toda la app, no algo que este PRD rompa. Se deja fuera de este plan (ver PRD,
  Data model changes) y se anota como limitación heredada en `TESTING.md`, en vez de arreglarlo a
  medias solo para el camino nuevo.

## Phases

### Phase A — Modelo y contrato (FR-1, FR-2, FR-3)

- [ ] **A1** `Sources/ZeroCore/Permissions/PermissionMode.swift` (nuevo): `enum PermissionMode:
      String, Codable, Sendable, CaseIterable { case ask, auto, bypass }` con `label`.
- [ ] **A2** `HookSettings.swift`: `askMatcher` (= `Bash|Write|Edit|NotebookEdit|WebFetch|WebSearch`
      — corrige la ausencia de `WebSearch`) y `autoMatcher` (= `WebFetch|WebSearch`).
      `defaultMatcher` pasa a ser un alias de `askMatcher` para no romper la firma por defecto.
- [ ] **A3** `Session` (SwiftData): `var permissionMode: String = "ask"`. `Store.createSession`
      gana el parámetro `permissionMode: String = "ask"`; nuevo `Store.updatePermissionMode(_:
      mode:)`.

### Phase B — Codex/ACP: cerrar el camino de respuesta en banda (prerequisito de FR-7)

- [ ] **B1** `SessionRuntime.resolvePermission(requestID:optionID:origin:) async throws`: codifica
      con `encoder.encodePermissionResponse` y envía cada registro por `process.send`. Para Claude
      Code esto sigue lanzando (`ClaudeCodeEncoder` no tiene canal en banda) — el llamador nunca
      debe invocarlo para esa sesión.
- [ ] **B2** `SessionCoordinator.answerPermission`: si no hay `pendingResolvers[sessionID]` (no es
      una petición de Claude Code en curso), cae a `runtime.resolvePermission(...)` con
      `origin: .userAction`. Sin esto, Ask seguía roto para Codex/ACP y Auto/Bypass no tendrían
      nada real que reforzar.

### Phase C — Claude Code: Auto y Bypass (FR-4, FR-5, FR-6)

- [ ] **C1** `SessionRuntime.CreationConfig` gana `permissionMode: PermissionMode = .ask`.
- [ ] **C2** `SessionRuntime.create`: el bloque que instala el hook se salta por completo cuando
      `permissionMode == .bypass` (sin `--settings`, sin `broker.startSession`); usa
      `HookSettings.autoMatcher` en `.auto` y `.askMatcher` en `.ask`. Para el provider `claude`,
      agrega `--permission-mode auto` o `--permission-mode bypassPermissions` a `extraArguments`
      según el modo (nada en `.ask`).
- [ ] **C3** `SessionRuntime.resume`: mismo tratamiento que C2, parametrizado con `permissionMode` y
      un `PermissionSetup?` opcional — hoy no instalaba el hook en absoluto; unificar con `create`
      en un helper privado en vez de duplicar el bloque.
- [ ] **C4** **Verificación contra el CLI real (`zero-probe`), no contra documentación:** confirmar
      que `--permission-mode bypassPermissions` es el valor real aceptado por la versión de
      `claude` instalada. Si no lo es, corregir aquí antes de seguir — mismo proceso que usó 001
      para los flags de Claude Code.

### Phase D — Codex/ACP: Auto y Bypass auto-resuelven localmente (FR-7)

- [ ] **D1** `SessionCoordinator.pump`: antes de reenviar un evento a `model.apply`, si es
      `.permissionRequested` y el modo de la sesión no es `.ask`, no se muestra — se resuelve de
      inmediato con `runtime.resolvePermission`, eligiendo la opción `.allowOnce` de
      `request.options` (fallback a `.denyOnce` si no hay ninguna, fail-closed) y
      `origin: .rule("permission-mode:\(mode.rawValue)")`.
- [ ] **D2** Test: fixture de Codex con una `execCommandApproval` — sesión en `.auto`, se verifica
      que sale un registro de respuesta con `optionID: "accept"` sin pasar por
      `model.pendingPermission`.

### Phase E — Cambiar de modo en una sesión viva (FR-8, FR-9)

- [ ] **E1** `SessionRuntime.terminate() async` — delega a `process.terminate()`, expuesto para que
      el coordinator pueda cerrar el proceso viejo antes de relanzar.
- [ ] **E2** `SessionCoordinator.setPermissionMode(_:for:)`: persiste el modo
      (`store.updatePermissionMode`), actualiza el snapshot. Si la sesión está viva: cancela su
      pump, `broker.stopSession(id:)` si tenía hook, `runtime.terminate()`, y relanza con
      `SessionRuntime.resume(sessionID:store:providerRegistry:permissionMode:permissionSetup:)`.
      Si el resume degrada a solo-lectura (Codex/ACP, o Claude Code sin `providerSessionId` aún),
      se añade un `.notice` al transcript explicándolo — nunca falla en silencio.

### Phase F — UI (FR-10, FR-11)

- [ ] **F1** `Sources/Zero/Permissions/PermissionModeControl.swift` (nuevo): fila de tres pills
      (Ask/Auto/Bypass), mismo lenguaje que `PermissionButton` (relleno = seleccionado, contorno =
      el resto, sin color), accessibility label con el estado actual, operable por teclado.
- [ ] **F2** `ConversationPane`: la fila se inserta encima del composer, dentro del mismo
      `zeroSurface`. Bypass activo muestra una línea de advertencia inline (texto, no icono de
      color) mientras dure.
- [ ] **F3** `AppModel.SessionSnapshot` gana `permissionMode: PermissionMode`; `SessionCoordinator.
      startSession` acepta el modo elegido en `ComposeView` (default `.ask`) y lo pasa a
      `CreationConfig`.
- [ ] **F4** `PreviewData.seed()`: al menos una sesión en cada modo, por la regla de proceso de
      `docs/DESIGN.md`.

## Test plan

| Área | Tests | FR |
|---|---|---|
| `PermissionMode` | round-trip Codable, `CaseIterable` cubre los 3 | A1 |
| `HookSettings` | `askMatcher` incluye `WebSearch`; `autoMatcher` solo red | A2 |
| `SessionRuntime.create`/`resume` | matcher y `--permission-mode` correctos por modo; `.bypass` no llama a `broker.startSession` | C2, C3 |
| `SessionRuntime.resolvePermission` | Codex: produce el registro JSON-RPC esperado; Claude Code: lanza | B1 |
| `SessionCoordinator` (o su lógica extraída y testeada en `ZeroCoreTests` donde sea posible) | auto-resuelve en `.auto`/`.bypass` sin tocar `pendingPermission`; `.ask` sigue mostrando el control | D1 |
| `PermissionOrigin` | `.rule("permission-mode:auto")` nunca se puede construir desde datos decodificados — mismo test que ya cubre FR-25 de 001, extendido | D1 |

**Checklist de validación manual:**

1. Sesión Claude Code en Ask: Bash pide permiso, como hoy.
2. Sesión Claude Code en Auto: Bash/Write corren sin preguntar; un `WebFetch` sí pide permiso.
3. Sesión Claude Code en Bypass: nada pide permiso, incluido un `WebFetch`; la advertencia inline
   está visible todo el tiempo.
4. Sesión Codex en Auto: una aprobación de comando se resuelve sola, visible solo como que el tool
   call corrió — no aparece el control de permiso.
5. Cambiar el modo de una sesión de Claude Code en marcha: el proceso se relanza, el historial
   sigue intacto, el nuevo modo aplica desde el siguiente tool call.
6. Cambiar el modo de una sesión de Codex en marcha: termina en solo-lectura con un aviso explícito
   en el transcript — comportamiento documentado, no un fallo silencioso.
7. Todo lo anterior operable sin ratón (F27 de 001).

## Comandos de verificación

```
swift build
swift test
```

Snyk/SonarQube: mismo estado que dejó 001 — a confirmar en Fase G-equivalente (Gate 3) si corren
sobre un paquete Swift puro; si no, se anota en `TESTING.md` el comando exacto que falló.

## Rollback notes

- Todo el trabajo cuelga de `feat/003-permission-modes`; revertir es descartar la rama.
- `Session.permissionMode` tiene default `"ask"`, así que ninguna fila existente queda en un
  estado inválido si se revierte a un build anterior que no conoce el campo.
- Si C4 revela que `bypassPermissions` no es el flag real, Bypass para Claude Code se implementa
  en su lugar sin `--settings` y sin ningún `--permission-mode` (el CLI usa su propio default), y
  se documenta la diferencia en el PRD — no bloquea el resto del plan.
