# Backlog de features

Ideas validadas en la ronda de diseño del 2026-07-02 pero fuera del alcance de F1–F4
(ver [spec](superpowers/specs/2026-07-02-history-engines-postprocessing-design.md)).
Ordenadas por valor/esfuerzo estimado.

## Candidatas a la siguiente ronda

### B1 — Transcribir ficheros de audio arrastrados
Soltar un `.m4a`/`.wav`/`.mp3` (nota de voz, audio de WhatsApp, grabación descargada) sobre la
ventana de History y transcribirlo con el motor que se elija. Entra al historial como una entrada
más, con retry y copia. Reutiliza el pipeline batch y la infraestructura de F2 casi entera; lo único
nuevo es la decodificación del fichero a 16 kHz mono Float32 (AVAudioFile + conversión).
*No lo tiene Wispr Flow; probablemente la de más uso real de esta lista.*

### B2 — Snippets hablados
Trigger natural dentro de la frase ("mándalo a mi correo" → dirección completa), estilo Wispr Flow:
trigger ≤60 caracteres, expansión ≤4000, match case-insensitive de palabra completa. Encaja como
extensión del diccionario actual (`SettingsStore.dictionary`) y del `PostProcessor`.

### B3 — Grabador de hotkey personalizado
Hoy solo hay presets (el README lo admite). Un recorder tipo MASShortcut en Settings para asignar
cualquier combinación a dictado/meeting/voice-edit. Tocaría `HotkeyManager` y los bindings de
`AppCoordinator.installHotkeys()`.

### B9 — Procesado de reuniones en segundo plano: aviso, progreso y notificación
Feedback de UAT real (2026-07-03): una reunión larga funciona bien pero el pill "Transcribing" se
queda quieto durante minutos y parece que la app está colgada. Tres piezas: (1) al parar, aviso
claro de que la transcripción sigue en segundo plano; (2) progreso consultable en la app (pill con
% y/o estado en el menú — whisper.cpp expone `progress_callback`, Parakeet procesa por chunks, así
que hay señal real de avance en ambos motores); (3) notificación del sistema (UNUserNotificationCenter)
al terminar, con click que revela el transcript/summary en vez del `activateFileViewerSelecting`
inmediato de hoy. Tocaría el protocolo `TranscriptionEngine` (canal de progreso), `MeetingPipeline`,
`RecordingHUD` y `MenuBarController`. Decisión de diseño (UAT 2026-07-03): **sí se encola** — se permite grabar una reunión nueva mientras
la anterior transcribe. Requisito estructural: persistir el audio a WAV en disco al parar (la cola
son ficheros, no arrays en RAM — hoy una reunión de 90 min son ~660 MB en memoria con dos pistas, y
encolar en RAM no escala en Macs de 8 GB). Cola FIFO serial (una transcripción a la vez), QoS
`utility` para no competir con la videollamada activa, y de regalo: recuperación ante crash
(mismo principio persist-before-transcribe de F2).
*Prioridad alta: viene de fricción observada en uso real, no de speculación.*

## Más caras / delicadas (evaluar tras la siguiente ronda)

### B4 — Pase LLM final para Smart Typing
Aplicar el postprocesado LLM (F3) también en streaming: al terminar, borrar lo tecleado y repegar
la versión pulida. Frágil: cursor movido por el usuario, undo múltiple en la app destino, borrado
por backspaces sintéticos, `AXSelection` falla en Chrome/Electron. Requiere diseño propio.

### B5 — Context awareness (formato según la app activa)
Leer una cantidad limitada de texto alrededor del cursor (AX API) para ajustar capitalización y
puntuación al contexto (p. ej. minúscula si continúas una frase). Wispr Flow lo hace. Sensible en
privacidad (aunque todo sea local) y frágil por app; necesita opt-in explícito y allowlist.

### B6 — Estilos por categoría de app
Tono (formal/casual/…) por cubo de apps (mensajería personal, trabajo, email, otros) con tarjetas
de preview, estilo Wispr. Depende de detectar la app activa (frontmost) y de F3.

### B7 — Auto-añadir al diccionario desde correcciones
Detectar cuándo el usuario corrige una palabra recién dictada y proponer añadirla al diccionario
(marcada como sugerencia automática, estilo ✨ de Wispr). Requiere observar el campo de texto tras
la inserción — complejo y delicado.

### B8 — Reproducción inline de audio en el historial
Player embebido por entrada en vez de (o además de) "Exportar audio". Wispr no lo tiene (solo
extract); QoL menor una vez existe B1/F2.
