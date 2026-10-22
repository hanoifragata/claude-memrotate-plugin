---
name: remember
description: Guarda una entrada en la memoria del proyecto (memrotate) con la fecha de hoy. Usala cuando el usuario escriba /memrotate:remember, o le pida a Claude apuntar, recordar, guardar o anotar algo en memoria ("apunta que...", "recuerda que...", "guarda en memoria..."). Admite --pin para datos que no deben caducar.
argument-hint: "[--pin] texto a recordar"
---

# Guardar en memoria

Anade una linea `- [AAAA-MM-DD] texto` (o `- [AAAA-MM-DD] [pin] texto`) al final del fichero de memoria vigente. Si el proyecto no esta inicializado, el script lo inicializa.

## Argumentos recibidos

`$ARGUMENTS`

## Pasos

1. **Decide si es fijada.** Usa `-Pin` si los argumentos empiezan por `--pin`, `-p` o `pin:` (quita ese prefijo del texto), o si el usuario dice "fijado", "fija" o "pin". Fija solo lo que seguira siendo cierto mucho tiempo: arquitectura, hosts, puertos, ubicaciones de credenciales, convenciones.
2. **Prepara el texto.** Una sola idea, concreta y autocontenida, en el idioma del usuario. Si el usuario pide guardar varias cosas, ejecuta el comando una vez por cada una. Si no hay argumentos y el usuario no ha dicho que guardar, preguntale que quiere guardar.
3. **Ejecuta el script**, pasando el texto por la entrada estandar para que no haya problemas con comillas ni caracteres especiales. Comando para Linux, macOS y Windows con Git Bash:

```
sh '${CLAUDE_PLUGIN_ROOT}/scripts/run.sh' -Mode remember -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' <<'MEMROTATE_EOF'
<texto>
MEMROTATE_EOF
```

   Anade `-Pin` antes de `<<'MEMROTATE_EOF'` si es fijada.

   En Windows sin `sh` (herramienta PowerShell), pasa el texto con `-Text` entre comillas simples, duplicando cualquier comilla simple del texto (`'` pasa a ser `''`):

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${CLAUDE_PLUGIN_ROOT}/scripts/rotate.ps1' -Mode remember -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' -Text '<texto>'
```

   Windows PowerShell 5.1 puede perder las comillas dobles (`"`) al pasar el texto con `-Text`: si el texto las lleva, quitalas o cambialas por comillas simples.

4. **Responde con una sola linea** confirmando lo guardado, usando la salida del script. Si dice `already in memory`, indica que ya estaba apuntado.

No edites el fichero de memoria a mano para esto: el script pone la fecha, evita duplicados y respeta el formato que necesita la rotacion.
