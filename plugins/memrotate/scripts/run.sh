#!/bin/sh
# memrotate: lanzador multiplataforma.
#   Windows (Git Bash / MSYS / Cygwin) -> rotate.ps1 con Windows PowerShell (o pwsh)
#   Linux / macOS                      -> rotate.py con python3 (o rotate.ps1 con pwsh si no hay python3)
# Los argumentos se pasan tal cual: run.sh -Mode status -Days 15 ...

DIR=$(cd "$(dirname "$0")" && pwd)

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    PS1="$DIR/rotate.ps1"
    if command -v cygpath >/dev/null 2>&1; then PS1=$(cygpath -w "$PS1"); fi
    for ps in powershell.exe powershell pwsh.exe pwsh; do
      if command -v "$ps" >/dev/null 2>&1; then
        exec "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PS1" "$@"
      fi
    done
    ;;
esac

for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' >/dev/null 2>&1; then
    exec "$py" "$DIR/rotate.py" "$@"
  fi
done

if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -NonInteractive -File "$DIR/rotate.ps1" "$@"
fi

echo "[memrotate] python3 (>= 3.6) or PowerShell (pwsh) is required" >&2
# No romper el arranque de sesion ni el cierre de turno por falta de interprete
exit 0
