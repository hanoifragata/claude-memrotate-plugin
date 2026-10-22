---
name: rotate
description: Configura y ejecuta la rotacion de memoria del proyecto (fichero vigente con los ultimos N dias + salvas mensuales comprimidas). Usala cuando el usuario escriba /memrotate:rotate o pida inicializar la memoria rotada, rotar ahora, cambiar los dias de retencion, activar el archivado de transcripts o ver el estado.
argument-hint: "[init [dias] | now | status | days N | transcripts on|off | reminder on|off | reminder every N | list | doctor]"
disable-model-invocation: true
---

# Rotacion de memoria del proyecto

Todo se hace con el script del plugin. Ejecutalo siempre con este comando base, que funciona en Linux, macOS y Windows con Git Bash (el lanzador elige PowerShell o Python segun el sistema):

```
sh '${CLAUDE_PLUGIN_ROOT}/scripts/run.sh' -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' <opciones>
```

Si estas en Windows y no tienes `sh` (por ejemplo, usas la herramienta PowerShell en lugar de Bash), usa:

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${CLAUDE_PLUGIN_ROOT}/scripts/rotate.ps1' -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' <opciones>
```

- `<raiz del proyecto>` es el directorio de trabajo actual de la sesion.
- Usa comillas simples tal cual, para que ni bash ni PowerShell expandan nada.
- Si `-DataDir` aparece sin sustituir (empieza por `${`), dejalo igual: el script lo ignora y usa sus valores por defecto. No le pases opciones de `/config` a mano.
- Muestra la salida del script EXACTAMENTE como la devuelve, dentro de un bloque de codigo, sin traducirla, resumirla ni reformatearla. Despues, como mucho una linea de comentario en el idioma del usuario.

## Argumentos recibidos

`$ARGUMENTS`

## Que hacer segun el argumento

| Argumento | Opciones del script |
|---|---|
| `init` | `-Mode init` |
| `init 15` | `-Mode init -Days 15` |
| `now` | `-Mode now` |
| `status` | `-Mode status` |
| `days 15` | `-Mode set -Days 15` |
| `transcripts on` / `transcripts off` | `-Mode set -Transcripts on` / `off` |
| `reminder on` / `reminder off` | `-Mode set -Reminder on` / `off` |
| `reminder every N` | `-Mode set -ReminderTools N` |
| `list` | `-Mode list` |
| `doctor` | `-Mode doctor` |

Si no hay argumentos, ejecuta primero `-Mode status` y despues pregunta al usuario con AskUserQuestion que quiere hacer, con estas opciones:

1. **Rotar ahora**: `-Mode now`
2. **Cambiar dias de retencion**: pregunta el numero y ejecuta `-Mode set -Days N`
3. **Ver salvas archivadas**: `-Mode list`
4. **Inicializar en este proyecto**: `-Mode init`. Ofrecela solo si el estado dice que no esta inicializado; en ese caso ponla la primera.

Si `status` o cualquier comando muestra algo raro, sugiere `doctor`. Para guardar una entrada, el comando es `/memrotate:remember` (otra skill del plugin).

Para activar o desactivar el archivado de transcripts o el recordatorio de guardado, el usuario puede escribir "Other" o usar `transcripts on|off` / `reminder on|off`.

## Notas

- `init` crea el fichero vigente, la carpeta de salvas con su `INDEX.md` y anade a `CLAUDE.md` un bloque delimitado por `<!-- memrotate:start -->` y `<!-- memrotate:end -->`. Repetirlo es seguro: el bloque se reemplaza, no se duplica.
- Los dias globales se cambian tambien en `/config` (opciones del plugin). Lo que se fije con `days N` se guarda en `.claude/memrotate.json` y tiene prioridad en ese proyecto.
- Si el script avisa de `cleanupPeriodDays`, explicale al usuario que debe subir ese valor en su `settings.json` para que Claude Code no borre transcripts antes de archivarlos. No lo cambies sin que lo pida.
