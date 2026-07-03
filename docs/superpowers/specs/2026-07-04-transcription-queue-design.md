# Diseño: cola de transcripción en segundo plano (B9) y ficheros arrastrados (B1)

**Fecha:** 2026-07-04
**Estado:** aprobado (diseño validado en conversación; pendiente de plan de ejecución)
**Base:** `origin/develop` (d5270ab). PRs contra `develop`, no `main`.
**Alcance:** dos features del [backlog](../../BACKLOG.md) — B9 (procesado de reuniones en segundo plano con progreso y notificación) y B1 (transcribir ficheros de audio arrastrados) — sobre una arquitectura compartida: una cola serial de trabajos de transcripción persistida a disco.

## Contexto

Feedback de UAT real (2026-07-03): una reunión larga transcribe bien, pero al pararla el
único signo de vida es el pill estático "Transcribing" durante minutos — parece que la app
está colgada. El procesado ya es asíncrono (`MeetingPipeline.stop()`,
`MeetingPipeline.swift:177`), pero no hay progreso, no hay aviso al terminar (solo una
ventana de Finder que se abre sola y roba el foco, `MeetingPipeline.swift:275`), y
`meetingBusy` (`MeetingPipeline.swift:78`) impide grabar otra reunión mientras procesa.

Piezas existentes que se reutilizan:

- **F2 (historial)**: `HistoryStore` con persistencia WAV + retención + retry
  (`HistoryStore.swift:120`), patrón batch completo en `AppCoordinator.retryHistoryEntry`
  (transcribe → PostProcessor → polish LLM → update entrada).
- **`WAVFile`** lee/escribe exactamente 16 kHz mono Float32 y rechaza lo demás a propósito
  (`WAVFile.swift:9-12`) — el decodificador de formatos arbitrarios es la pieza nueva de B1.
- **En `develop`** (diverge de main): el enum `SettingsStore.Engine` tiene 4 motores
  (`parakeet`, `nemotron`, `parakeetV3`, `whisper`), y `TranscriptionEngine` ganó
  `isWarm()` — útil para distinguir "Warming up…" de "Transcribing" en la cola.
  `MeetingPipeline`, `HistoryStore`, `WAVFile`, `LLMPostProcessor`, `MeetingDocument` y
  `MeetingSummarizer` son idénticos en ambas ramas (verificado 2026-07-04).

## Decisiones cerradas

| # | Decisión | Valor |
|---|----------|-------|
| 1 | Encolado de reuniones | Sí: se puede grabar una reunión nueva mientras la anterior transcribe. Cola FIFO **serial** (un job a la vez — nunca dos modelos ASR cargados). |
| 2 | Persistencia | El audio de cada job se escribe a WAV en disco al encolar. La cola son ficheros, no RAM (una reunión de 90 min son ~660 MB en memoria con dos pistas). |
| 3 | Progreso | Item informativo en el dropdown del menú de barra (persistente, con % y tamaño de cola) + pill breve "Transcribing in background…" (~3 s, auto-oculta) al parar la reunión. |
| 4 | Aviso de finalización | Notificación del sistema; el click revela el resultado en Finder (meetings) o abre History (ficheros). Desaparece el `activateFileViewerSelecting` automático. |
| 5 | Motor para B1 | El motor de reuniones (`SettingsStore.meetingEngine`) en el momento del drop, sin preguntar. El menú Retry de la entrada permite relanzar con otro motor. |
| 6 | Quit con cola activa | Permitido: los jobs persisten y se re-encolan al relanzar (el interrumpido reempieza de cero). Grabación activa (dictado o meeting) sigue bloqueando el quit. |
| 7 | Polish LLM en B1 | Solo si el audio dura ≤ 5 min. El PostProcessor determinista se aplica siempre. |
| 8 | Tope de duración B1 | 3 horas por fichero (~690 MB de Float32 en RAM durante ese job). Más largo → rechazo con mensaje. |
| 9 | QoS | Transcripción en background con prioridad `utility` para no competir con una videollamada activa. |

## Arquitectura

### TranscriptionQueue (nuevo)

`@MainActor final class TranscriptionQueue: ObservableObject`, singleton al estilo
`HistoryStore.shared`. Único punto por el que pasa TODO el ASR batch en segundo plano
(meetings, drops de B1 y retries del historial).

- **Directorio:** `Application Support/Barktor/Queue/<jobID>/` con `job.json` + audio:
  - job meeting: `mic.wav` + `system.wav` (opcional).
  - job file: `audio.wav` (ya decodificado a 16 kHz mono Float32).
- **Modelo** (`TranscriptionJob`, Codable): id, fecha de creación, tipo con payload:
  - `.meeting`: duración, fecha de grabación, motor elegido (string estilo `engineUsed`:
    `"whisper:<model>"` etc. — resuelto al parar la reunión y CONGELADO en el job, así un
    relanzamiento no cambia el motor), flag `systemAudioSilentButActive`.
  - `.file`: id de la entrada de History que representa, nombre del fichero original
    (para UI y notificación), duración, motor congelado, flag `isRetry`. Un retry no
    posee `audio.wav` propio: referencia el WAV existente en el directorio de audio de
    History (sin decode, sin mover audio al completar, sin crear entrada — ya existe).
    El tope de polish LLM ≤ 5 min aplica a TODOS los jobs `.file`, drops y retries (los
    dictados duran segundos, así que en la práctica solo afecta a audios largos de B1).
- **Worker serial:** un único `Task` procesa FIFO. Publica
  `state: QueueState` (`idle` / `processing(label, fraction: Double?, queuedCount)`) para
  el menú de barra, y el conjunto de entry-IDs en cola/proceso para `HistoryView`.
- **Arranque:** escanea `Queue/`, re-encola todo job existente (recuperación ante crash y
  quit). Entradas de History en `.queued`/`.transcribing` sin job correspondiente → `.failed`.
- **Progreso por etapas**, ponderado: decode/echo-cancel (peso fijo pequeño) → pasadas ASR
  (peso dominante; en meetings de dos pistas, repartido por número de samples) → summary
  (indeterminado). Etiquetas: "Warming up… / Transcribiendo 43% / Resumiendo…".

### Canal de progreso en los motores

`TranscriptionEngine` gana variantes con callback y default que lo ignora (extensión de
protocolo — Parakeet/Nemotron no cambian):

```swift
func transcribe(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> String
func transcribeDetailed(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> DetailedTranscription
```

`WhisperEngine` la implementa con el callback por segmento de WhisperKit:
`fraction = min(1, últimoTimestampEmitido / duraciónAudio)`. Whisper es el caso lento que
motivó B9; Parakeet es ~10× tiempo real y queda con progreso indeterminado (solo etiqueta).

### MeetingPipeline (adelgaza)

`stop()` pasa a: parar captura → guard 2 s mínimo → persistir WAV(s) al directorio de cola
(off-main) → encolar → `state = .idle` inmediatamente → pill breve. El estado `.processing`
y `meetingBusy` desaparecen: se puede grabar otra reunión al momento. Echo cancel,
diarización, las dos pasadas ASR, `MeetingDocument.format/write` y el summary se mudan al
procesador de jobs SIN cambios de lógica. El aviso one-time de "system audio silencioso"
se dispara desde el job usando el flag congelado al parar.

### B1 — drop de ficheros en History

- **Target:** toda la `HistoryView` (ventana + tab de Settings), overlay "Suelta audios
  para transcribir" durante el drag. Acepta ficheros que conformen `UTType.audio`
  (m4a, mp3, wav, aiff, caf, flac…); el resto se filtra del drag. Multi-drop: un job y una
  entrada por fichero, FIFO.
- **`AudioFileDecoder` (nuevo):** `AVAudioFile` + `AVAudioConverter` → 16 kHz mono Float32.
  Rechaza > 3 h. Corre en task detached (decode de un podcast largo no bloquea la UI).
- **Por fichero:** entrada placeholder en History (`.queued`, con `sourceFilename` nuevo
  campo opcional para mostrar el origen) → decode → WAV a la cola → encolar con el
  `meetingEngine` congelado.
- **Al completar:** PostProcessor determinista siempre; polish LLM solo si duración ≤ 5 min;
  `rawText`/`processedText`/`engineUsed`/`.ok`; el WAV se mueve al directorio de audio de
  History si la retención lo permite (con "Never" se borra — como los dictados); notificación.
- **Retry unificado:** `retryHistoryEntry` deja de transcribir inline y encola un job
  `.file` con `isRetry` (reutiliza el WAV de History, sin decode, sin mover audio). Todo el
  ASR batch queda serializado — nunca dos Whispers cargados. La UI de retry no cambia
  (spinner en la fila); `beginRetry` se conserva solo como guard anti-doble-encolado.

### DictationEntry

- `Status` gana `.queued` y `.transcribing`, y un `init(from:)` con fallback para valores
  desconocidos (que el próximo caso nuevo no reviente el decode y provoque el wipe a
  `.bak` de history.json en versiones viejas — el fallback protege hacia adelante).
- Campo nuevo **opcional** `sourceFilename: String?` (regla de F2: todo campo nuevo debe
  ser opcional o con default).

### Menú de barra y HUD

- **Icono:** cola activa → estado "transcribing" existente (mic + waveform). Prioridad:
  grabación activa > cola > idle.
- **Dropdown:** item informativo (disabled) arriba: "Transcribiendo reunión · 43% — 2 en
  cola" / "Transcribiendo nota-voz.m4a · 12%". Con el menú abierto NSMenu corre en modo
  event-tracking: la actualización en vivo necesita timer en `.common` mode (mismo patrón
  que el timer del pill de meeting, `MeetingPipeline.swift:394`).
- **Pill:** copy nueva "Transcribing in background…", auto-oculta ~3 s. El dictado
  foreground no cambia.

### Notifier (nuevo)

Wrapper de `UNUserNotificationCenter`. Permiso pedido lazy en el primer encolado (nunca en
el arranque). Payload con la acción de click: revelar URL en Finder (meetings) o abrir la
ventana de History (ficheros). Delegate en `AppDelegate`. Permiso denegado → silencio, el
menú de barra sigue contando el estado; sin insistencia.

### Quit

`canQuitSafely()` deja de mirar el procesado de meeting (ya no existe): bloquean el quit
solo dictado `.recording`/`.transcribing` y meeting `.recording`. Cola activa NO bloquea —
los jobs persisten y se retoman al relanzar.

## Manejo de errores

- **Job meeting falla:** los WAV se rescatan a la carpeta de Meetings como
  `Meeting YYYY-MM-DD HHmm (audio only).wav` (+ ` (system)` para la segunda pista),
  notificación con el motivo, job eliminado. Nada se pierde; el WAV rescatado puede
  arrastrarse a History (B1) como reintento manual (mono, sin diarización — fallback
  aceptado).
- **Job file falla:** entrada `.failed` + `errorMessage`, audio conservado según retención
  (Retry disponible), job eliminado, notificación.
- **Decode falla / fichero > 3 h:** entrada `.failed` con mensaje claro; no se encola.
- **Crash / quit a medias:** el job re-escaneado reempieza de cero al relanzar. Entradas
  `.queued`/`.transcribing` huérfanas → `.failed`.
- **Escritura del WAV de cola falla** (disco lleno): para meetings, intento de rescate
  directo a la carpeta de Meetings antes de rendirse + error en HUD; para files, entrada
  `.failed`.
- **Retry encolado cuyo WAV desaparece** (sweep de retención o borrado manual antes de que
  le toque el turno): el job falla limpio con "audio no longer available" → entrada
  `.failed`, sin rescate (no hay nada que rescatar).

## Tests

Swift Testing vía `make test` (CLT-only: sin XCTest, `-DNO_APPLE_FM`). Con motor fake:

- `AudioFileDecoderTests`: fixtures diminutos en bundle (m4a, mp3, wav 44.1 kHz estéreo) →
  formato/recuento correcto; corrupto lanza; tope de duración.
- `TranscriptionQueueTests`: orden FIFO; nunca dos jobs concurrentes; round-trip de
  `job.json`; rescan del directorio re-encola; job meeting produce documento; job file
  actualiza entrada + mueve audio según retención; fallos → rescate de WAVs / entrada
  `.failed`; progreso monótono no-decreciente; entradas huérfanas → `.failed`.
- `DictationEntryTests`: decode con status desconocido no revienta (fallback).
- `MeetingPipelineTests` (adaptar): `stop()` encola y vuelve a `.idle`; el aviso de system
  audio usa el flag congelado.

Manual (UAT del usuario): % real de WhisperKit en reunión larga, click-through de las
notificaciones, quit + relaunch con cola a medias, drop de un audio real de WhatsApp,
grabar reunión B mientras A transcribe.

## Fuera de alcance

- Diarización / etiquetas de hablante para ficheros arrastrados (B1 es pipeline mono).
- Player inline de audio en el historial (B8).
- Cola visible dentro de la ventana de History (descartado con el enfoque C).
- Reintento automático de jobs fallidos (el rescate manual cubre el caso).
- Streaming del decode a disco durante la grabación de meeting (el límite práctico de RAM
  al grabar no cambia respecto a hoy; solo se persiste al parar).

## Entrega

Rama `feature/transcription-queue` (desde `origin/develop`), PR contra **develop**.
El plan de ejecución decide si se parte en dos PRs apiladas (cola + B9 primero, B1 encima)
o va en una; la cola y B9 son inseparables, B1 es apilable.
