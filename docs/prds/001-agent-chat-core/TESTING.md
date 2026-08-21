# Guía de pruebas — Zero, núcleo de chat multi-agente

## Qué está construido y qué no

**Construido:** el núcleo completo (transporte, tres adapters, git/worktrees, persistencia,
permisos) y la app SwiftUI con las tres zonas, transcript tipado, prompt de permisos y el
inspector de tokens y coste.

**No construido:** editor, panel de browser, terminal embebida, diff viewer con commit/push/PR,
acceso remoto, apps móviles. Todo eso está fuera del alcance del v1 por PRD.

**Sin verificar:** los adapters de Codex y ACP están derivados de documentación, no de tráfico
capturado, porque ninguno de esos CLIs está instalado en esta máquina. Los `TODO(B5)` y `TODO(B6)`
del código nombran cada ambigüedad. Hasta pasarlos por `zero-probe` contra un binario real, dalos
por no probados.

## Cómo correrlo

Toolchain: macOS 26, Swift 6.3.3, Xcode 26. Solo Apple Silicon.

### Los tests

```bash
swift test
```

162 tests en 16 suites, ~1,6 s. Los benchmarks se omiten salvo que los pidas:

```bash
ZERO_RUN_BENCHMARKS=1 swift test --filter 'FlushPolicy|Footprint'
```

### La app

```bash
./Scripts/make-app.sh release && open build/Zero.app
```

### El probe, sin interfaz

Verifica el núcleo contra tu `claude` real, sin app de por medio. Córrelo en un directorio que no
te importe tocar:

```bash
swift run zero-probe "lista los archivos de este directorio"
```

`swift run zero-probe --check` solo reporta qué proveedores encuentra.

## Escenarios a ejercitar

### Camino feliz

1. Abre la app, **⌘N**, elige un repo git, deja Claude Code, escribe una tarea, Start.
2. La sesión aparece en la barra lateral con su rama `zero/{slug}-{id}`.
3. El texto del asistente aparece de forma incremental.
4. Un tool call aparece como celda colapsable con nombre, estado y duración.
5. Una edición de archivo se ve **como diff**, no como JSON.
6. El inspector muestra tokens por categoría y el coste **reportado** por el CLI.

### Permisos

7. Pide algo que use Bash o Write. Debe aparecer el prompt in-chat con el comando completo.
8. **Deniega.** La operación no debe ocurrir. Compruébalo en el disco, no en la UI.
9. Responde un permiso **solo con teclado**: `a` permite una vez, `d` deniega.

### Concurrencia y aislamiento

10. Tres sesiones a la vez sobre el mismo repo. Cada una en su worktree; ninguna pisa a otra.
11. Con las tres streameando, la UI no debe trabarse. **Este es el fps que no pude medir — mira si
    se siente fluido y dímelo.**

### Fallos

12. Mata el `claude` de una sesión a mano (`pkill -f claude`). La sesión debe pasar a error y el
    historial seguir ahí.
13. Elige Codex en el selector: debe aparecer deshabilitado con la razón, no fallar de forma opaca.
14. **⌘.** durante un turno debe interrumpirlo sin matar la sesión.

### Persistencia

15. Cierra y reabre la app. Las sesiones y su historial deben volver.

### Accesibilidad

16. VoiceOver sobre la barra lateral y sobre el prompt de permisos.
17. Recorre la app entera solo con teclado: ⌘N, ⌘⇧] y ⌘⇧[ entre sesiones, ⌘⌥I el inspector.

## Mediciones

En [MEASUREMENTS.md](MEASUREMENTS.md). Resumen: arranque en frío 0,688 s (objetivo < 1 s), 5
sesiones concurrentes 48,1 MB (objetivo < 400 MB), bundle 4,3 MB sin Node ni Electron, append p50
0,84 ms, fetch de 10k mensajes 1,11 ms.

**Los fps con 3 streams no están medidos.** Requieren Instruments sobre una ventana real y no hay
forma honesta de automatizarlo. Es el punto 11 de arriba.

## Scans de seguridad — NO SE EJECUTARON

El skill `incu-way-development` pide tres scans antes de Gate 3. Ninguno pudo correr:

| Herramienta | Estado |
|---|---|
| `snyk_code_scan` (MCP) | **no disponible** en esta sesión |
| `snyk_sca_scan` (MCP) | **no disponible** en esta sesión |
| `bash run-sonnar.sh` | **el archivo no existe** en el repositorio |

No los reporto como limpios porque no se ejecutaron. Nota sobre el SCA en particular: el proyecto
no tiene ninguna dependencia de terceros — `Package.swift` no declara ni un `.package(` — así que
un escaneo de composición no tendría nada que analizar aunque estuviera disponible.

**Decisión tuya:** instalar y configurar las tres, o aceptar la revisión manual de abajo como
sustituto y seguir.

### Revisión manual hecha en su lugar

Las superficies con riesgo real y qué se verificó de cada una:

- **Lanzamiento de subprocesos.** Los binarios se resuelven a ruta absoluta desde una lista
  explícita de directorios candidatos, nunca heredando `PATH` sin validar, y se comprueba que el
  resultado sea un archivo ejecutable regular. Lo que un atacante que controle uno de esos
  directorios todavía puede hacer: poner un binario ahí. Mitigación fuera de la app: esos
  directorios deben ser escribibles solo por el usuario.
- **Broker de permisos.** Falla cerrado en todos los caminos, con test por cada uno: timeout,
  socket inalcanzable, petición malformada, sesión desconocida. El socket es 0600 y su nombre es un
  digest, no adivinable. Un `allow` solo se puede construir nombrando un `PermissionOrigin`, que
  únicamente la acción del usuario o una regla que él configuró antes pueden producir.
- **Inyección de prompt.** El contenido generado por el modelo y el devuelto por herramientas es
  dato en todo el recorrido: se renderiza, nunca se interpreta. Nada en `tool_input` puede aprobar,
  escalar ni ampliar un permiso.
- **Rutas.** `GitService` resuelve symlinks y `..` antes de comparar contra la raíz esperada, y hay
  tests con ambos vectores. `git` se invoca siempre con array de argumentos, nunca por shell.
- **Borrado.** `tearDown` exige una autorización nombrada; no hay valor por defecto que borre.
- **Secretos.** El log de protocolo está apagado por defecto y redacta antes de escribir a disco.
  Lo que su redactor no cubre está enumerado en su propio test.

## Limitaciones conocidas

- Codex y ACP sin verificar contra binario real.
- Sin auto-update: decisión tomada al ser repo privado.
- `Scripts/notarize.sh` está escrito pero **nunca ejecutado** — requiere una cuenta de Apple
  Developer. Trátalo como el procedimiento documentado, no como un camino probado.
- El resume de una sesión sin `providerSessionId` vuelve en solo lectura, a propósito.
