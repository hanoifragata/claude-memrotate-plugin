# memrotate

Rotación de memoria para Claude Code, al estilo `logrotate`:

- **Fichero vigente** (`notes/MEMORY-current.md`): solo contiene los últimos N días, más las entradas fijadas. Se carga en cada sesión desde `CLAUDE.md`.
- **Entradas fijadas** (`[pin]`): datos que siguen siendo ciertos con el tiempo (hosts, puertos, arquitectura, convenciones). Nunca rotan.
- **Salvas** (`notes/archive/MEMORY-AAAA-MM.md.gz`): las entradas antiguas se mueven ahí agrupadas por mes, comprimidas. Nunca se borran.
- **Índice** (`notes/archive/INDEX.md`): lista cada salva con su rango de fechas y su número de entradas.
- **Transcripts (opcional)**: en lugar de dejar que `cleanupPeriodDays` los borre, comprime los `.jsonl` antiguos en `notes/archive/transcripts-AAAA-MM.zip`.
- **Recordatorio de guardado**: si Claude trabaja un rato sin apuntar nada, le pide que guarde lo aprendido.
- **Copia de seguridad**: sube la memoria (vigente, salvas y Auto Memory de Claude Code) a un repo privado de GitHub y/o a Google Drive, y la recupera en otro PC con `restore`.

## Instalación

Desde el marketplace (dentro de Claude Code):

```
/plugin marketplace add hanoifragata/claude-memrotate-plugin
/plugin install memrotate@claude-memrotate-plugin
```

Cuando pregunte el alcance, elige **Install for you (user scope)**: queda disponible en todos tus proyectos y no hace nada en uno hasta que ejecutas `init`. Evita *project scope* en repos compartidos, porque se lo propondría a todos los colaboradores.

También puedes instalarlo desde PowerShell, fuera de Claude:

```powershell
claude plugin marketplace add hanoifragata/claude-memrotate-plugin
claude plugin install memrotate@claude-memrotate-plugin
```

Reinicia Claude Code después de instalar (`/exit` y `claude`): los hooks se cargan al abrir sesión.

Para probarlo en local sin instalarlo (en PowerShell):

```powershell
claude plugin validate C:\ruta\claude-memrotate-plugin\plugins\memrotate
claude --plugin-dir C:\ruta\claude-memrotate-plugin\plugins\memrotate
```

`--plugin-dir` apunta a la carpeta del plugin (la que contiene `.claude-plugin\plugin.json`), no a la raíz del marketplace.

## Inicio rápido

1. En la raíz de tu proyecto, dentro de Claude Code: `/memrotate:rotate init`
2. Comprueba el estado: `/memrotate:rotate status`
3. Trabaja con normalidad. Claude añadirá entradas al fichero vigente, o puedes guardarlas tú: `/memrotate:remember --pin la base de datos de producción es db.example.com:5432`.
4. Para consultar algo antiguo, pregúntale directamente: *"¿qué decidimos sobre el backup de MySQL en agosto?"*.

No hay que hacer nada más: la rotación se ejecuta sola al abrir sesión.

## Componentes

| Pieza | Qué hace |
|---|---|
| Hook `SessionStart` | Rota como máximo una vez al día y le dice a Claude dónde están el vigente y las salvas. Después de cada compactación, le recuerda guardar lo duradero del resumen. En proyectos sin inicializar no hace nada. |
| Hooks `SessionEnd` y `SessionStart` (en segundo plano) | Copia de seguridad automática si hay destino configurado y algo cambió, respetando el intervalo. No ralentiza el arranque. |
| Hook `Stop` | Recordatorio de guardado: si Claude lleva 15 herramientas sin actualizar la memoria, al terminar el turno le pide que guarde lo aprendido. |
| `/memrotate:rotate` | Menú para inicializar, rotar ya, cambiar los días, activar transcripts o el recordatorio, ver salvas o diagnosticar. |
| `/memrotate:remember` | Guarda una entrada con la fecha de hoy. Claude también la usa sola cuando le pides "apunta que...". |
| Skill `memrotate:archive` | Claude la usa sola cuando lo que buscas no está en el vigente: busca y lee en las salvas `.gz` sin descomprimirlas a disco. |
| `/config` | Opciones globales: `retention_days` (30 por defecto), `archive_transcripts`, `save_reminder` y los destinos e intervalo de la copia de seguridad. |

## Formato de las entradas

Una línea por entrada, siempre con fecha:

```
- [2026-10-21] Vault: el token de CI se rota cada 24h
  línea de continuación opcional (indentada), viaja con su entrada
```

### Entradas fijadas

Lo que sigue siendo cierto con el tiempo se marca con `[pin]` y no rota nunca:

```
- [2026-10-21] [pin] La base de datos de producción es db.example.com:5432
- [pin] Convención de ramas: feat/* y fix/*
```

Úsalo con moderación: si todo está fijado, el vigente crece sin límite y la rotación deja de servir. Cuando un dato fijado deja de ser cierto, quita el `[pin]` (rotará como cualquier otra entrada) y añade una entrada nueva con la corrección.

Las líneas sin fecha y sin `[pin]` (títulos, comentarios) también se quedan siempre en el vigente. El bloque que `init` añade a `CLAUDE.md` le indica a Claude, y a cada teammate de Agent Teams, que escriba con este formato.

## Uso

| Comando | Qué hace |
|---|---|
| `/memrotate:remember <texto>` | Guarda `- [hoy] texto` al final del vigente. Evita duplicados e inicializa el proyecto si hace falta |
| `/memrotate:remember --pin <texto>` | Igual, pero fijada: no rotará nunca |
| `/memrotate:rotate` | Muestra el estado y un menú de opciones |
| `/memrotate:rotate init [días]` | Inicializa el proyecto: fichero vigente, carpeta de salvas y bloque en `CLAUDE.md`. Repetirlo es seguro |
| `/memrotate:rotate status` | Muestra la configuración efectiva y la última rotación |
| `/memrotate:rotate now` | Fuerza una rotación ahora |
| `/memrotate:rotate days N` | Cambia la retención de este proyecto |
| `/memrotate:rotate transcripts on\|off` | Activa o desactiva el archivado de transcripts en este proyecto |
| `/memrotate:rotate reminder on\|off` | Activa o desactiva el recordatorio de guardado en este proyecto |
| `/memrotate:rotate reminder every N` | Cada cuántas herramientas sin guardar salta el recordatorio |
| `/memrotate:rotate list` | Muestra el índice de salvas |
| `/memrotate:rotate backup` | Copia ahora a todos los destinos configurados |
| `/memrotate:rotate backup git <ruta>` | Destino: clon local de un repo **privado** (solo este proyecto; para todos, usa `/config`) |
| `/memrotate:rotate backup folder <ruta>` | Destino: carpeta de Google Drive, OneDrive o Dropbox |
| `/memrotate:rotate backup every N` / `backup daily` | Intervalo: como mucho una copia cada N horas (`daily` = 24). 0 = en cada sesión con cambios |
| `/memrotate:rotate backup off` | Desactiva la copia en este proyecto |
| `/memrotate:rotate restore [clave]` | Recupera la memoria desde la copia (PC nuevo, disco cambiado...) |
| `/memrotate:rotate doctor` | Diagnóstico: intérprete, bloque de `CLAUDE.md`, hooks funcionando, tamaño del vigente, entradas sin fecha, `.gitignore`, transcripts |

Para consultar lo archivado no hace falta ningún comando. Pregúntale a Claude ("¿qué decidimos sobre X en agosto?") y usará la skill `memrotate:archive`.

## Configuración

Hay dos niveles. **El del proyecto tiene prioridad sobre el global.**

### 1. Por proyecto: `.claude/memrotate.json`

Lo escriben `days N`, `transcripts on|off`, `reminder on|off` y `reminder every N`, pero también se puede editar a mano:

```json
{
  "retentionDays": 30,
  "archiveTranscripts": false,
  "saveReminder": true,
  "reminderEveryTools": 15,
  "backupGit": "C:/Datos/claude-memory-backup",
  "backupDir": "",
  "backupIntervalHours": 24,
  "memoryFile": "notes/MEMORY-current.md",
  "archiveDir": "notes/archive"
}
```

| Clave | Por defecto | Descripción |
|---|---|---|
| `retentionDays` | `30` | Días que se mantienen en el fichero vigente |
| `archiveTranscripts` | `false` | Comprimir los transcripts antiguos en vez de dejar que se borren |
| `saveReminder` | `true` | Recordar a Claude que guarde lo aprendido |
| `reminderEveryTools` | `15` | Herramientas sin tocar la memoria antes de recordárselo |
| `backupGit` | vacío | Clon local del repo privado de copia. `off` lo desactiva aunque esté en `/config` |
| `backupDir` | vacío | Carpeta de copia (Google Drive, OneDrive...). `off` lo desactiva |
| `backupIntervalHours` | `0` | Horas mínimas entre copias automáticas. 0 = en cada sesión con cambios |
| `memoryFile` | `notes/MEMORY-current.md` | Fichero vigente, relativo a la raíz del proyecto |
| `archiveDir` | `notes/archive` | Carpeta de salvas e índice |

Si cambias `memoryFile` o `archiveDir`, vuelve a ejecutar `/memrotate:rotate init` para que el bloque de `CLAUDE.md` apunte a la nueva ruta.

### 2. Global: `/config`

En `/config` aparecen las opciones del plugin `retention_days`, `archive_transcripts` y `save_reminder`. Sirven de valor por defecto en los proyectos que no tienen su propio `.claude/memrotate.json`.

Si cargas el plugin con `--plugin-dir`, puede que no aparezcan en `/config`. En ese caso, instálalo como marketplace local (ver el README de la raíz).

### Orden de prioridad

1. `.claude/memrotate.json` del proyecto
2. Opciones del plugin en `/config`
3. Valores por defecto

### Cómo funciona el recordatorio de guardado

Al terminar cada turno, el hook `Stop` cuenta las herramientas usadas en la sesión (leyendo el transcript). Si desde la última vez que se tocó el fichero vigente van `reminderEveryTools` o más, le pide a Claude que añada lo que haya aprendido. Si no hay nada que guardar, Claude termina sin más.

- Si Claude guarda algo por su cuenta, el contador se reinicia y no hay recordatorio.
- No entra en bucle: si Claude ya está respondiendo a un recordatorio, no se vuelve a pedir.
- Funciona igual en cada teammate de Agent Teams, porque cada uno es una sesión propia.
- **Después de compactar**: cuando Claude Code compacta la conversación (automática o con `/compact`), el hook de inicio le recuerda a Claude que guarde lo duradero que haya quedado en el resumen. Es el momento en que más detalle se pierde.
- Si te resulta pesado, sube `reminder every N` o desactívalo con `reminder off`.

### Archivado de transcripts y `cleanupPeriodDays`

Claude Code borra al arrancar los transcripts con más días que `cleanupPeriodDays`, que por defecto son 30. Si activas `archiveTranscripts`, sube ese valor por encima de tu retención en `~/.claude/settings.json` (en Windows, `%USERPROFILE%\.claude\settings.json`). Si no, Claude Code los borrará antes de que el plugin los archive.

```json
{ "cleanupPeriodDays": 365 }
```

`/memrotate:rotate status` te avisa si el valor es demasiado bajo.

## Copia de seguridad

Para no perder la memoria si le pasa algo al ordenador. Copia **el fichero vigente, todas las salvas, el índice y la Auto Memory de Claude Code** de cada proyecto. Nunca copia credenciales ni transcripts.

### Configurarla (una vez)

**A. Repo privado de GitHub** (con historial de cada cambio):
```powershell
gh repo create claude-memory-backup --private --clone   # o créalo en la web y haz git clone
```
Después, en `/config` → opciones de memrotate → **Copia: repo git local**, pon la ruta del clon, por ejemplo `C:\Datos\claude-memory-backup`. Usa tu git y tus credenciales habituales: memrotate hace `pull`, `commit` y `push`.

> El repo tiene que ser **privado**: la memoria puede contener nombres de servidores, decisiones internas o datos de clientes.

**B. Carpeta de Google Drive** (también OneDrive o Dropbox): instala Google Drive para escritorio y, en `/config` → **Copia: carpeta**, pon por ejemplo `G:\Mi unidad\claude-memory`. memrotate copia ahí y Drive lo sube solo.

Puedes usar las dos a la vez. Comprueba que funciona con `/memrotate:rotate backup` y `/memrotate:rotate doctor`.

### Cuándo se copia

- **Automáticamente** al cerrar cada sesión, y al abrir la siguiente en segundo plano (por si la anterior se cerró de golpe). Solo si algo cambió desde la última copia.
- **Intervalo** (`backup every N`, `backup daily` o la opción **Copia: intervalo en horas** de `/config`): con 24, como mucho una copia al día aunque haya cambios. Con 0 (por defecto), en cada sesión con cambios.
- **Manualmente** con `/memrotate:rotate backup`, que no espera al intervalo.

La memoria solo cambia mientras trabajas con Claude, así que no hace falta un proceso aparte con el PC apagado o sin sesiones.

### Qué hay en la copia

```
claude-memory-backup/
└─ myrepo-1a2b3c4d/           ← nombre del proyecto + huella de su ruta
   ├─ backup.json             ← proyecto, equipo y fecha de la copia
   ├─ memrotate/
   │  ├─ MEMORY-current.md
   │  └─ archive/ (INDEX.md, MEMORY-AAAA-MM.md.gz...)
   └─ auto-memory/            ← ~/.claude/projects/<proyecto>/memory
```

La copia **nunca borra** nada en el destino: si algo desaparece en tu PC, sigue en la copia.

### Recuperar en un PC nuevo

1. Instala el plugin y configura el mismo destino (clona el repo de copia o deja que Drive sincronice la carpeta).
2. Clona tu proyecto y, dentro de Claude Code: `/memrotate:rotate restore`.

memrotate encuentra la copia aunque el proyecto esté en otra ruta. Recupera solo lo que falta y **nunca sobrescribe** lo que ya tengas en local. Si hay varias copias posibles, te las lista para elegir con `restore <clave>`.

## Ficheros que crea

```
<proyecto>/
├─ CLAUDE.md                      ← bloque entre <!-- memrotate:start/end -->
├─ .claude/memrotate.json     ← solo si cambias algo con days/transcripts/reminder
└─ notes/
   ├─ MEMORY-current.md           ← fichero vigente
   └─ archive/
      ├─ INDEX.md                 ← índice de salvas
      ├─ MEMORY-AAAA-MM.md.gz     ← salvas mensuales
      ├─ transcripts-AAAA-MM.zip  ← si archiveTranscripts está activo
      ├─ .state.json              ← fecha de la última rotación
      ├─ .backup.json             ← huella y fecha de la última copia de seguridad
      └─ .sessions/               ← contadores del recordatorio por sesión
```

Si el proyecto tiene `.gitignore`, se le añaden `.state.json`, `.backup.json` y `.sessions/`. El resto (vigente, salvas e índice) está pensado para versionarse en git.

## Actualizar

- **Instalado desde el marketplace**: en `/plugin` → Marketplaces, selecciona `claude-memrotate-plugin`, pulsa `u` y reinicia Claude Code. También puedes usar `/plugin marketplace update claude-memrotate-plugin`.
- **Con `--plugin-dir`**: sustituye la carpeta del plugin y reinicia Claude Code.
- Después de actualizar, ejecuta `/memrotate:rotate init` en cada proyecto para refrescar el bloque de `CLAUDE.md`. No toca tus entradas.

## Problemas comunes

| Síntoma | Causa y solución |
|---|---|
| `/plugin` responde como si fuera un mensaje normal | Hay un espacio antes de la `/`. Los comandos solo se reconocen si la barra es el primer carácter. |
| El marketplace está añadido pero `/memrotate:rotate` no existe | Añadir el marketplace no instala el plugin. Falta `/plugin install memrotate@claude-memrotate-plugin` y reiniciar. |
| Algo no funciona y no sabes qué | `/memrotate:rotate doctor` revisa la instalación y el proyecto y dice qué hacer en cada caso. |
| `Unknown command: /memrotate:rotate` | El plugin no está cargado. Comprueba que aparece en `/plugin` → Installed. Con `--plugin-dir`, la ruta debe ser la carpeta `plugins\memrotate`; si descomprimiste un zip, puede haber una carpeta duplicada (`claude-memrotate-plugin\claude-memrotate-plugin`). |
| `status` dice `Not initialized` | Falta `/memrotate:rotate init` en ese proyecto. Cada proyecto se inicializa por separado. |
| Las opciones no aparecen en `/config` | Con `--plugin-dir` puede pasar. Instálalo como marketplace local: `/plugin marketplace add C:\ruta\claude-memrotate-plugin`. |
| Los cambios de `/config` no se aplican | Reinicia Claude Code: el hook de inicio es quien guarda esas opciones. Comprueba también que el proyecto no tenga un `.claude/memrotate.json` con otro valor, porque tiene prioridad. |
| Windows bloquea el script | `Get-ChildItem C:\ruta\claude-memrotate-plugin -Recurse \| Unblock-File`. El plugin ya usa `-ExecutionPolicy Bypass`, así que normalmente no hace falta. |
| El hook no parece ejecutarse | Mira la pestaña Errors de `/plugin` o arranca con `claude --debug`. |
| Linux/macOS: `python3 (>= 3.6) or PowerShell (pwsh) is required` | Instala `python3` (`sudo apt install python3`, `sudo dnf install python3`, o `xcode-select --install` en macOS). El plugin no rompe la sesión mientras tanto, simplemente no rota. |
| La copia a git dice `push failed` | El commit está hecho en local. Revisa que puedes hacer `git push` a mano en el clon de copia (credenciales, rama con remoto). La próxima copia lo reintenta. |
| `restore` no encuentra la copia | Comprueba que el destino es el mismo que en el otro PC y que el clon está actualizado (`git pull`). Usa `restore <clave>` con una de las claves que lista. |
| El recordatorio salta demasiado | `/memrotate:rotate reminder every 30` o `reminder off`. |
| Una entrada antigua no rota | Tiene `[pin]` o no lleva fecha con el formato `[AAAA-MM-DD]` al principio de la línea. |

## Migrar desde `memory-rotate` (0.2.x o anterior)

El plugin se llamaba `memory-rotate`. Para pasar a `memrotate`:

1. Desinstala el antiguo en `/plugin` → Installed (o deja de usar `--plugin-dir` con la carpeta vieja).
2. Instala `memrotate` como se indica arriba y reinicia Claude Code.
3. Al abrir sesión, el bloque de `CLAUDE.md` se actualiza solo. Si quieres forzarlo: `/memrotate:rotate init`.

Tus entradas, salvas y configuración se conservan: `.claude/memory-rotate.json` se sigue leyendo y pasa a `.claude/memrotate.json` la próxima vez que cambies algo.

## Desinstalar de un proyecto

Borra la carpeta `notes/` (o solo lo que no quieras conservar), el bloque entre `<!-- memrotate:start -->` y `<!-- memrotate:end -->` de `CLAUDE.md`, y `.claude/memrotate.json` si existe.

## Requisitos

Funciona en **Windows, Linux y macOS** sin configurar nada: el plugin detecta el sistema y elige el intérprete.

| Sistema | Qué usa | Requisito |
|---|---|---|
| Windows | `scripts/rotate.ps1` | Windows PowerShell 5.1 (viene de serie) o PowerShell 7 |
| Linux / macOS | `scripts/rotate.py` | `python3` 3.9 o superior (viene en casi todas las distribuciones y en macOS con las Command Line Tools) |
| Linux / macOS sin Python | `scripts/rotate.ps1` | `pwsh` (PowerShell 7) |

Las dos implementaciones tienen los mismos comandos, la misma salida y los mismos ficheros: un repo puede usarse desde Windows y desde Linux a la vez, y cada uno lee las salvas del otro. El CI lo comprueba en cada cambio, en Windows (PowerShell 5.1 y 7), Linux y macOS.

Los hooks llaman a `scripts/run.sh`, que hace la elección. En Windows sin Git Bash, Claude Code ejecuta los hooks con PowerShell y el plugin llama directamente a `rotate.ps1`.
