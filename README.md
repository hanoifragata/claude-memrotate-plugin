# claude-memrotate-plugin

[![CI](https://github.com/hanoifragata/claude-memrotate-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/hanoifragata/claude-memrotate-plugin/actions/workflows/ci.yml)

**memrotate**: rotación de memoria para Claude Code, al estilo `logrotate`. Funciona en Windows, Linux y macOS.

Claude mantiene un fichero de memoria **vigente** con lo aprendido en los últimos N días, más las entradas **fijadas** que nunca caducan. Lo antiguo no se borra: se archiva en salvas mensuales comprimidas que Claude consulta cuando le preguntas por algo pasado. Un recordatorio se encarga de que guarde lo aprendido antes de que se pierda.

Pensado para trabajar con varias sesiones o con Agent Teams: si se cierra una pestaña, lo aprendido sigue en disco, versionado en git. Y si le pasa algo al ordenador, la **copia de seguridad** a un repo privado de GitHub o a Google Drive te permite recuperarlo todo con `restore`.

```
notes/
├─ MEMORY-current.md        ← vigente: últimos 30 días + [pin]
└─ archive/
   ├─ INDEX.md              ← qué salva cubre qué periodo
   ├─ MEMORY-2026-09.md.gz
   └─ MEMORY-2026-08.md.gz
```

## ¿Por qué memrotate?

Claude Code ya trae memoria, y hay plugins muy completos. memrotate ocupa un hueco distinto: **lo antiguo no se borra ni se resume, se rota**, como hace `logrotate` con los logs.

| | memrotate | Auto Dream (nativo) | Claude Remember | claude-mem |
|---|---|---|---|---|
| Qué hace con lo antiguo | Lo **archiva intacto** en salvas mensuales | Lo consolida y **borra** lo obsoleto | Lo **resume** por niveles (día → semana → archivo) | Lo comprime con IA en una base de datos |
| ¿Se pierde información? | No | Sí, sin copia | Sí, el detalle se resume | Se conserva un resumen comprimido |
| Datos que nunca caducan | Sí, con `[pin]` | No | No | No |
| Retención configurable en días | Sí | No | No | No |
| Formato | Markdown en el repo, versionable en git | Ficheros en `~/.claude` | Markdown en el proyecto | SQLite + ChromaDB |
| Coste y dependencias | Ninguno: no llama a ninguna API | Incluido en Claude Code | Llamadas a Claude Haiku con tu API key; Python, Bash y `jq` | Servicio local, base de datos y compresión con el SDK de Claude |
| Windows | Nativo (PowerShell 5.1 o 7) | Sí | Con Git Bash o WSL | Ver su documentación |
| Búsqueda | Por texto en vigente y salvas | No aplica | Ver su documentación | **Semántica** (la mejor) |
| Captura | Claude apunta, con recordatorio y comando `remember` | Automática | **Automática** | **Automática** |
| Copia de seguridad | GitHub privado y/o Google Drive, con `restore` en otro PC | No | No | Ver su documentación |

**Elige memrotate si** quieres una memoria que puedas leer, revisar en un PR y compartir con tu equipo, que no pierda nada, que separe lo que caduca de lo que no, y que no dependa de servicios ni tenga coste por uso.

**Elige otra si** necesitas que se capture todo automáticamente sin que nadie decida qué apuntar, o búsqueda semántica sobre mucho historial: en eso claude-mem es más potente.

Comparativa a octubre de 2026, según la documentación pública de cada proyecto.

Son compatibles: memrotate solo usa sus propios ficheros (`notes/` y un bloque en `CLAUDE.md`), así que puede convivir con la memoria nativa de Claude Code.

## Instalación

Dentro de Claude Code:

```
/plugin marketplace add hanoifragata/claude-memrotate-plugin
/plugin install memrotate@claude-memrotate-plugin
```

Elige **user scope** al instalar, reinicia Claude Code y, en la raíz de tu proyecto:

```
/memrotate:rotate init
```

Para guardar algo: `/memrotate:remember la API de staging escucha en el puerto 8443` (o `--pin` para que no caduque). Para la copia de seguridad: `/memrotate:rotate backup git <ruta>` o `backup folder <ruta>`. Si algo no va bien: `/memrotate:rotate doctor`.

Toda la documentación (uso, configuración, recordatorio, problemas comunes) está en el [README del plugin](plugins/memrotate/README.md).

## Plugins

| Plugin | Versión | Qué hace |
|---|---|---|
| [memrotate](plugins/memrotate/) | 0.6.0 | Memoria vigente con rotación, entradas fijadas, salvas mensuales consultables y recordatorio de guardado |

## Desarrollo

Probar en local sin instalar:

```bash
claude plugin validate ./plugins/memrotate
claude --plugin-dir ./plugins/memrotate
```

O como marketplace local:

```
/plugin marketplace add C:\ruta\claude-memrotate-plugin
/plugin install memrotate@claude-memrotate-plugin
```

El plugin tiene dos implementaciones con el mismo comportamiento: `scripts/rotate.ps1` (Windows) y `scripts/rotate.py` (Linux/macOS). `scripts/run.sh` elige una según el sistema. Cualquier cambio de lógica tiene que hacerse en las dos.

El script se puede ejecutar directamente:

```bash
# Linux / macOS / Git Bash
sh ./plugins/memrotate/scripts/run.sh -Mode status -ProjectDir /ruta/proyecto
```

```powershell
# Windows PowerShell
powershell -ExecutionPolicy Bypass -File .\plugins\memrotate\scripts\rotate.ps1 -Mode status -ProjectDir C:\ruta\proyecto
```

### Pruebas

```bash
python tests/run_tests.py
```

Prueba el comportamiento completo (rotación, `[pin]`, salvas, búsqueda, `remember`, `doctor`, recordatorio, aviso tras compactar, transcripts, copia de seguridad a git y a carpeta, intervalo y `restore` en otra ruta), que `rotate.py` y `rotate.ps1` den **exactamente la misma salida**, y que los hooks funcionen en `sh`, Git Bash y PowerShell. Usa los intérpretes que encuentre: en Windows prueba Windows PowerShell 5.1 y PowerShell 7.

El [CI](.github/workflows/ci.yml) las ejecuta en cada push en Windows, Linux y macOS.

### Publicar una versión nueva

1. Sube `version` en `plugins/memrotate/.claude-plugin/plugin.json` y añade la entrada en su `CHANGELOG.md`. Comprueba que `python tests/run_tests.py` pasa.
2. Haz commit y push.
3. Los usuarios actualizan desde `/plugin` → Marketplaces → `u`, o con `/plugin marketplace update claude-memrotate-plugin`.

## Licencia

MIT
