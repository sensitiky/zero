# Testing — Modo de permisos por sesión (Ask / Auto / Bypass)

## Cómo probarlo

1. `swift build && swift test` — confirma que todo compila y que la suite pasa (202 tests).
2. `./Scripts/make-preview.sh && open build/ZeroPreview.app` — arranca sin agente real ni
   repositorio. La sesión "Fix flaky checkout test" queda sembrada en `.auto`, "Add OpenAPI docs
   for /webhooks" en `.bypass` (con la advertencia inline visible), y el resto en `.ask` (default).
3. Para probar contra un CLI real: `swift run zero-probe --help` (o directamente `Zero.app`)
   contra un repo de prueba, con Claude Code instalado y autenticado.

## Validado automáticamente (`swift test`)

- `HookSettings.askMatcher` incluye `WebSearch` (antes ausente); `HookSettings.autoMatcher` solo
  cubre `WebFetch`/`WebSearch`.
- `SessionRuntime.create` en `.auto`: instala el hook con `autoMatcher` y agrega
  `--permission-mode auto`.
- `SessionRuntime.create` en `.bypass`: no instala ningún hook (`--settings` ausente) y agrega
  `--permission-mode bypassPermissions`.
- `SessionRuntime.resolvePermission`: para Codex, produce el JSON-RPC de respuesta esperado
  (`id`/`decision` correlacionados); para Claude Code, lanza — nunca intenta responder en banda a
  un proveedor que no tiene ese canal.

## Pendiente de validar manualmente (no cubierto por test unitario razonable)

1. Sesión Claude Code en **Ask**: `Bash` pide permiso, como hoy.
2. Sesión Claude Code en **Auto**: `Bash`/`Write` corren sin preguntar; un `WebFetch` sí pide
   permiso.
3. Sesión Claude Code en **Bypass**: nada pide permiso, incluido un `WebFetch`; la advertencia
   inline está visible todo el tiempo que el modo esté activo.
4. Sesión Codex en **Auto**: una aprobación de comando se resuelve sola — no aparece el control de
   permiso, el tool call simplemente corre.
5. Cambiar el modo de una sesión de Claude Code **en marcha**: el proceso se relanza vía
   `--resume`, el historial sigue intacto, el nuevo modo aplica desde el siguiente tool call.
6. Cambiar el modo de una sesión de Codex **en marcha**: hoy termina en solo lectura con un aviso
   explícito en el transcript (Codex no tiene un flag de resume verificado en este repo — FR-9 del
   PRD documenta esto como comportamiento aceptado, no como fallo).
7. Todo lo anterior operable sin ratón (FR-27 de `001-agent-chat-core`).

## Limitaciones conocidas, heredadas o deliberadas — no arregladas en este PR

- **`Store.resolvePermissionRequest` no se llama en ningún camino**, ni siquiera el de Claude Code
  que ya existía antes de este PRD. Un permiso auto-resuelto en Codex/ACP queda correctamente
  desbloqueado para el agente (se le envía la respuesta real), pero su fila en
  `PermissionRequestRecord` no queda marcada como resuelta — mismo estado que tenía la app antes
  de este cambio. Arreglarlo es trabajo aparte, no de esta feature.
- ~~Verificación de `--permission-mode bypassPermissions` contra el CLI real~~ — **hecho**: `claude
  --help` (2.1.241, instalado en la máquina de desarrollo) lista `bypassPermissions` y `auto` entre
  los valores válidos de `--permission-mode`, junto a `acceptEdits`, `manual`, `dontAsk` y `plan`.
- **Codex/ACP no tienen un modo "auto" nativo verificado** — `.auto` y `.bypass` son idénticos para
  estos dos proveedores en v1 (Zero resuelve localmente en ambos). Ver el PRD, Open Questions.

## Scans de seguridad

`snyk_code_scan`, `snyk_sca_scan` y `run-sonnar.sh` **no están disponibles en esta sesión** —
mismo estado que dejó `001-agent-chat-core` (ver su propio `TESTING.md`). No se reportan como
limpios porque no corrieron; la validación disponible en esta sesión es la de arriba
(`swift build && swift test`, 202/202 verdes).
