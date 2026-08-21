# Mediciones — 001-agent-chat-core

Máquina: Apple Silicon, macOS 26.5.2, Swift 6.3.3, build debug, contenedor SwiftData en memoria.
Fecha: 2026-08-21.

## C2 — Puerta de medición de persistencia

### Veredicto: **SwiftData se queda.**

La decisión no era el motor, era la política de flush — que nadie había elegido a propósito.

### Coste de append, serializado

1.000 appends de `Message`, un solo benchmark a la vez:

| Política de flush | p50 | p95 | p99 | Total |
|---|---|---|---|---|
| `flush()` en cada append | 3.07 ms | 5.50 ms | 5.78 ms | 3.04 s |
| `flush()` cada 50 appends | **0.84 ms** | 1.56 ms | 6.29 ms | **0.92 s** |

El p99 de la fila batched es la propia escritura: el pico aparece cuando toca flush, no en el append.

### Lectura

Traer una sesión con **10.000 mensajes: 1.11 ms.** Las lecturas nunca fueron el problema, y son
lo que paga abrir una sesión larga — el caso que más importa para la percepción de la app.

### Por qué la primera medición dictaminó lo contrario

La primera pasada concluyó "SwiftData es inadecuado, migrar a SQLite" con ~120 ms por append.
Ese número no medía SwiftData. Medía dos bugs y un error de método:

1. **Escaneo O(n²) en el propio `Store`.** `appendMessage` y `appendUsageRecord` derivaban el
   número de secuencia con `session.messages.map { $0.sequenceNumber }.max()`, materializando toda
   la colección en cada append con faulting de SwiftData por elemento. O(n) por append, O(n²) por
   sesión. Corregido con contadores monótonos en `Session`.
2. **Append redundante al inverso de la relación.** El init de `Message` ya fija `session`, así que
   `session.messages.append(...)` solo servía para materializar la colección otra vez.
3. **Cuatro benchmarks en paralelo.** Los cuatro tests reportaron "passed after 1082s" — corrían a
   la vez, compitiendo por CPU. Tras corregir los bugs, esa ejecución paralela seguía dando 27.6 ms
   de p50; serializada da 3.07 ms. Un factor de ~9 que era puramente contención.

Medición paralela, ya sin el O(n²), para dejar constancia del sesgo: p50 27.6 ms, p95 51.6 ms,
275,7 s para 10k appends.

### Consecuencia de diseño

`Store.appendMessage` y `appendUsageRecord` ya no hacen flush. `Store.flush()` es explícito y el
runtime de sesión lo llama en frontera de turno y con un debounce corto.

El coste honesto de eso: un crash pierde lo que no se haya flusheado, acotado a unos cientos de
milisegundos de mensajes. Se acepta a cambio de 3,7× en throughput de escritura — y con 3,07 ms de
p50 la política por-append también sería viable, así que esto es margen, no rescate.

## G1 — NFR de rendimiento

Build release, Apple Silicon, macOS 26.5.2.

| NFR | Objetivo | Medido | |
|---|---|---|---|
| Cold start a primer frame | < 1 s | **0,688 s** en frío, **0,140 s** templado | cumple |
| Memoria, app en reposo | — | **89,7 MB** | referencia |
| Memoria, 5 sesiones concurrentes (librería) | < 400 MB | **48,1 MB** residentes, delta 29,0 MB | cumple |
| Bundle sin Node ni Electron | obligatorio | **4,3 MB**, cuatro archivos | cumple |
| fps con 3 streams en paralelo | ≥ 60 | **no medido** | ver abajo |

El cold start se mide desde la creación del proceso según el kernel, no desde `main`: buena parte
de un arranque en frío es dyld y el runtime antes de que corra nuestro código, y medir desde `main`
daría un número que nos favorece escondiéndolo. La instrumentación está en `StartupClock` y solo se
activa con `ZERO_MEASURE_STARTUP`.

La cifra de 5 sesiones mide **lo que cuesta Zero**, con los procesos de proveedor sustituidos por
`cat` sobre un fixture capturado repetido 200 veces. Es la forma honesta para este NFR: mide
decodificar, persistir y sostener cinco transcripts, no lo que cuestan los CLIs de agente, que es
su propio presupuesto y no algo que la app pueda cambiar. Sumado al reposo de la app, el total
queda muy por debajo del límite.

**Los fps no están medidos.** Requieren Instruments sobre una ventana real con tres agentes
streameando, y no hay forma honesta de automatizarlo desde aquí. Queda como paso manual en
`TESTING.md`. No lo reporto como cumplido porque no lo he visto.

## G2 — Auditoría de main actor

- `SessionRuntime` es `public actor`, no `@MainActor`. El bucle de salida del proceso y
  `decoder.decode(line:)` corren en su propio actor.
- El único tipo `@MainActor` de `ZeroCore` es `Store`, por la confinación de `ModelContext` de
  SwiftData.
- Los 7 `MainActor.run` del runtime tocan exclusivamente `store`: seis son transiciones de ciclo de
  vida de sesión (una vez por sesión) y uno es la persistencia por lotes de eventos.
- Verificado por test, no por inspección: *"decoding a real stream never runs on the main thread"*
  usa un decoder espía que registra `Thread.isMainThread` en cada llamada y asevera que ninguna
  devuelve `true`. Ese test falla si alguien vuelve a poner el runtime en el main actor.

## G3 — Contenido del bundle

```
Zero.app/Contents/Info.plist
Zero.app/Contents/MacOS/Zero
Zero.app/Contents/MacOS/zero-permission-hook
Zero.app/Contents/_CodeSignature/CodeResources
```

4,3 MB. Sin Node, sin Electron, sin frameworks embebidos, sin Chromium. El helper de permisos viaja
dentro porque la app le pasa su ruta absoluta al CLI del proveedor.
