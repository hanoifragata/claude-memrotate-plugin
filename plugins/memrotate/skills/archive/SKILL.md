---
name: archive
description: Consulta la memoria archivada del proyecto (salvas mensuales comprimidas MEMORY-AAAA-MM.md.gz creadas por memrotate). Usala cuando el usuario pregunte por algo de hace semanas o meses, por decisiones, hallazgos o configuraciones pasadas, o cuando lo que se busca no aparece en el fichero de memoria vigente.
---

# Consultar la memoria archivada

Las salvas son de solo lectura y estan comprimidas en gzip. No las descomprimas a disco ni las edites: usa el script del plugin, que las lee al vuelo.

Comando base (Linux, macOS y Windows con Git Bash):

```
sh '${CLAUDE_PLUGIN_ROOT}/scripts/run.sh' -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' <opciones>
```

En Windows sin `sh` (herramienta PowerShell):

```
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '${CLAUDE_PLUGIN_ROOT}/scripts/rotate.ps1' -ProjectDir '<raiz del proyecto>' -DataDir '${CLAUDE_PLUGIN_DATA}' <opciones>
```

Usa comillas simples tal cual. Si `-DataDir` llega sin sustituir, el script lo ignora.

## Pasos

1. **Busca primero**: `-Mode search -Query "terminos"`. Todos los terminos tienen que aparecer en la linea, sin distinguir mayusculas. Busca tambien en el fichero vigente. Prueba sinonimos o nombres de host o servicio si no hay resultados.
2. **Si necesitas el contexto completo de un mes**: `-Mode read -Month AAAA-MM`.
3. **Para saber que periodos hay**: `-Mode list`, que muestra `INDEX.md` con cada salva, su rango de fechas y su numero de entradas.

Las entradas fijadas (`[pin]`) nunca se archivan: si buscas un dato estable (hosts, puertos, arquitectura, convenciones), mira primero el fichero vigente.

## Al responder

- Cita la fecha de la entrada y la salva de la que sale (por ejemplo: "segun la entrada del 2026-08-03, en MEMORY-2026-08").
- Si una entrada antigua contradice una mas reciente, manda la mas reciente y dilo.
- Si el usuario quiere recuperar algo archivado como conocimiento vigente, anade una entrada nueva con la fecha de hoy al final del fichero vigente, por ejemplo `- [AAAA-MM-DD] (recuperado de MEMORY-2026-08) ...`. Si es un dato que seguira siendo cierto, fijalo: `- [AAAA-MM-DD] [pin] ...`. Nunca muevas lineas de vuelta desde la salva.
- Si hay transcripts archivados (`transcripts-AAAA-MM.zip`), solo abrelos si el usuario lo pide expresamente: son grandes y contienen conversaciones completas.
