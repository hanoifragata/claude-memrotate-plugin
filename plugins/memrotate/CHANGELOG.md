# Changelog

## 0.6.0 - 2026-10-22

- **Copia de seguridad**: copia el fichero vigente, las salvas, el índice y la Auto Memory de Claude Code a un **repo privado de GitHub** (clon local: pull, commit y push con tu git) y/o a una **carpeta** sincronizada (Google Drive, OneDrive, Dropbox). Nunca borra nada en el destino ni copia credenciales o transcripts.
  - Automática al cerrar la sesión y, en segundo plano, al abrir la siguiente; solo si algo cambió.
  - **Intervalo configurable**: `backup every N` / `backup daily`, o la opción de `/config`.
  - `/memrotate:rotate backup` manual, `backup git|folder <ruta>`, `backup off`.
  - **`restore`**: recupera la memoria en otro PC aunque el proyecto esté en otra ruta, sin sobrescribir nada local.
  - `status` y `doctor` muestran destinos, intervalo, última copia y errores.
- `INDEX.md` solo se reescribe cuando cambia su contenido (antes cambiaba la fecha en cada rotación y habría generado una copia diaria sin cambios reales). Ahora usa LF también en Windows.
- Las líneas de estado que faltan en `.gitignore` se añaden solas al abrir sesión.

## 0.5.1 - 2026-10-22

- Corregido: en Windows **sin** Git Bash, los hooks no recibían la entrada de Claude Code (en Windows PowerShell 5.1, `$input` llega vacío con `-Command`). Afectaba al aviso tras compactar y al recordatorio de guardado. Ahora la entrada se lee con `[Console]::In` y se pasa al script en `MEMROTATE_HOOK_INPUT`, sin tubería ni problemas de codificación. Detectado por el CI en Windows.
- README: comparativa con Auto Dream, Claude Remember y claude-mem.

## 0.5.0 - 2026-10-21

- **`/memrotate:remember [--pin] <texto>`**: guarda una entrada con la fecha de hoy sin tener que escribir el formato. Normaliza espacios, evita duplicados, reconoce `[pin]` en el texto e inicializa el proyecto si hace falta. Claude también la usa cuando le pides "apunta que...".
- **Aviso tras compactar**: cuando Claude Code compacta la conversación, el hook de inicio le recuerda a Claude que guarde lo duradero que haya quedado en el resumen.
- **`/memrotate:rotate doctor`**: diagnóstico de la instalación y del proyecto (intérprete, bloque de `CLAUDE.md`, hooks funcionando, tamaño del vigente, entradas sin fecha, `.gitignore`, transcripts), con la solución de cada problema.
- **Pruebas y CI**: `tests/run_tests.py` comprueba el comportamiento, la paridad exacta entre `rotate.py` y `rotate.ps1`, y los hooks en `sh`, Git Bash y PowerShell. GitHub Actions las ejecuta en Windows (PowerShell 5.1 y 7), Linux y macOS.
- `rotate.ps1` escribe JSON con un formato propio y determinista: el mismo en Windows PowerShell 5.1, PowerShell 7 y Python (antes 5.1 escapaba las comillas simples y cambiaba el formato). `.claude/memrotate.json` guarda las claves en orden alfabético.
- Requisito de Python documentado como 3.9 o superior (la versión probada en CI).

## 0.4.0 - 2026-10-21

- **Multiplataforma**: funciona en Windows, Linux y macOS.
  - Nueva implementación en Python (`scripts/rotate.py`) para Linux y macOS, con los mismos modos, argumentos, salida y formato de ficheros que `rotate.ps1`.
  - Nuevo lanzador `scripts/run.sh`: elige PowerShell en Windows (Git Bash), `python3` en Linux/macOS, o `pwsh` si no hay Python.
  - Los hooks funcionan en `sh`, Git Bash y, en Windows sin Git Bash, en PowerShell.
- `rotate.ps1`: los errores de uso se muestran como `[memrotate] mensaje` en lugar de una traza de PowerShell; `read` y `list` ya no añaden una línea en blanco al final.

## 0.3.0 - 2026-10-21

- Renombrado de `memory-rotate` a **memrotate**. Repo y marketplace: `claude-memrotate-plugin`.
  - Comando: `/memrotate:rotate` (antes `/memory-rotate:rotate`). Skill: `memrotate:archive`.
  - Configuración del proyecto: `.claude/memrotate.json`. Se sigue leyendo `.claude/memory-rotate.json` y se migra al guardar.
  - El bloque antiguo de `CLAUDE.md` se migra solo al abrir sesión.

## 0.2.0 - 2026-10-21

- Entradas fijadas: las líneas `- [AAAA-MM-DD] [pin] texto` o `- [pin] texto` nunca rotan.
- Recordatorio de guardado: un hook `Stop` pide a Claude que guarde lo aprendido tras N herramientas sin tocar la memoria (`reminder on|off`, `reminder every N`, opción `save_reminder` en `/config`).
- `status` muestra el número de entradas fijadas y el estado del recordatorio.
- README: instalación, inicio rápido, actualización y problemas comunes.

## 0.1.2 - 2026-10-21

- `/memory-rotate:rotate` muestra la salida del script literal, sin traducir ni resumir.
- README con la configuración completa.

## 0.1.1 - 2026-10-21

- Mensajes del script en inglés.
- Corregido: con `--plugin-dir`, `${user_config.*}` no se sustituía en la skill. Las opciones de `/config` se guardan ahora desde el hook en la carpeta de datos del plugin.

## 0.1.0 - 2026-10-21

- Primera versión: fichero vigente, salvas mensuales `.md.gz`, índice, skill `archive`, hook `SessionStart` y archivado opcional de transcripts.
