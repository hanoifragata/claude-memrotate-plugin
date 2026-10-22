#!/usr/bin/env python3
"""Pruebas de memrotate. Se ejecutan igual en Windows, Linux y macOS.

    python tests/run_tests.py

Que comprueban:
  1. Comportamiento: rotacion, [pin], continuaciones, salvas, busqueda, configuracion,
     remember, doctor, recordatorio (hook Stop), aviso tras compactar y transcripts.
  2. Paridad: rotate.py y rotate.ps1 producen exactamente la misma salida y los mismos ficheros.
     En Windows se prueba Windows PowerShell 5.1 y, si existe, PowerShell 7.
  3. Hooks: los comandos de hooks/hooks.json funcionan en sh (Linux/macOS), en Git Bash
     y, en Windows, en PowerShell (el caso sin Git Bash).
Solo usa la biblioteca estandar.
"""
import datetime as dt
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.normpath(os.path.join(HERE, '..', 'plugins', 'memrotate'))
SCRIPTS = os.path.join(PLUGIN, 'scripts')
WINDOWS = os.name == 'nt'

TODAY = dt.date.today()
OLD1 = TODAY - dt.timedelta(days=90)   # fuera de la retencion de 30 dias
OLD2 = TODAY - dt.timedelta(days=60)
RECENT = TODAY - dt.timedelta(days=3)

FAILURES = []
PASSED = [0]


def check(cond, msg):
    if cond:
        PASSED[0] += 1
    else:
        FAILURES.append(msg)
        print('  FAIL: ' + msg)


# ---------------------------------------------------------------- implementaciones

def implementations():
    impls = [('py', [sys.executable, os.path.join(SCRIPTS, 'rotate.py')])]
    ps1 = os.path.join(SCRIPTS, 'rotate.ps1')
    if WINDOWS and shutil.which('powershell'):
        impls.append(('ps51', ['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1]))
    if shutil.which('pwsh'):
        impls.append(('pwsh', ['pwsh', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ps1]))
    return impls


def run(cmd, args, stdin=None, env=None, cwd=None):
    e = dict(os.environ)
    for k in list(e):
        if k.startswith('CLAUDE_'):
            del e[k]
    e.update(env or {})
    p = subprocess.run(cmd + args, input=(stdin or '').encode('utf-8'), stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, env=e, cwd=cwd, timeout=120)
    out = p.stdout.decode('utf-8', errors='replace').replace('\r\n', '\n')
    err = p.stderr.decode('utf-8', errors='replace').replace('\r\n', '\n')
    return p.returncode, out, err


def normalize(text, root):
    text = text.replace(re.sub(r'[^A-Za-z0-9]', '-', root), 'ENCODEDROOT')
    text = text.replace(root, 'ROOT').replace(root.replace('\\', '/'), 'ROOT')
    text = re.sub(r'\(rotate\.(py|ps1), [^)]*\)', '(IMPL)', text)
    text = re.sub(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}', 'DATETIME', text)
    return text


def read(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read().replace('\r\n', '\n')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def gz_text(path):
    with gzip.open(path, 'rb') as f:
        return f.read().decode('utf-8').replace('\r\n', '\n')


# ---------------------------------------------------------------- escenario

def scenario(cmd, root):
    """Ejecuta el escenario completo y devuelve una transcripcion normalizada."""
    log = []

    def step(name, args, stdin=None, env=None):
        code, out, err = run(cmd, args + ['-ProjectDir', root], stdin=stdin, env=env)
        log.append('## %s [exit %d]\n%s%s' % (name, code, out, ('STDERR: ' + err.strip() + '\n') if err.strip() else ''))
        return code, out, err

    os.makedirs(os.path.join(root, '.claude'))
    write(os.path.join(root, 'CLAUDE.md'), '# Repo\n\nreglas\n\n<!-- memory-rotate:start -->\nviejo\n<!-- memory-rotate:end -->\n\nfin\n')
    write(os.path.join(root, '.gitignore'), 'node_modules\n')
    write(os.path.join(root, '.claude', 'memory-rotate.json'), '{ "retentionDays": 30 }\n')

    step('status sin init', ['-Mode', 'status'])
    step('doctor sin init', ['-Mode', 'doctor'])
    step('auto sin init', ['-Mode', 'auto'], stdin='{"source":"startup"}')
    step('init', ['-Mode', 'init'])

    mem = os.path.join(root, 'notes', 'MEMORY-current.md')
    with open(mem, 'a', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join([
            '- [%s] [pin] el CI se autentica con AppRole' % OLD1,
            '- [pin] ramas feat/* y fix/*',
            '- [%s] temporal viejo Ñandú' % OLD1,
            '- [%s] [PIN] postgres en db01:5432' % OLD2,
            '  continuacion de la fijada',
            '- [%s] nota antigua' % OLD2,
            '  continuacion de la antigua',
            '- [%s] reciente' % RECENT,
            'linea sin fecha',
            '- vineta sin fecha',
        ]) + '\n')

    step('now', ['-Mode', 'now'])
    step('auto mismo dia', ['-Mode', 'auto'], stdin='{"source":"startup"}')
    step('auto tras compactar', ['-Mode', 'auto'], stdin='{"source":"compact","session_id":"s"}')
    with open(mem, 'a', encoding='utf-8', newline='\n') as f:
        f.write('- [%s] otra antigua\n' % OLD2)
    step('now fusiona en salva existente', ['-Mode', 'now'])
    step('search', ['-Mode', 'search', '-Query', 'antigua'])
    step('search acentos', ['-Mode', 'search', '-Query', 'ñandú'])
    step('search sin resultados', ['-Mode', 'search', '-Query', 'zzz'])
    step('read', ['-Mode', 'read', '-Month', OLD2.strftime('%Y-%m')])
    step('read inexistente', ['-Mode', 'read', '-Month', '2001-01'])
    step('read mes invalido', ['-Mode', 'read', '-Month', 'malo'])
    step('remember', ['-Mode', 'remember', '-Text', '  la API   de staging es api.example.com '])
    step('remember duplicado', ['-Mode', 'remember', '-Text', 'La api de staging es api.example.com'])
    step('remember pin por stdin', ['-Mode', 'remember', '-Pin'], stdin='convención: línea uno\nlínea dos\n')
    step('remember con prefijo pin', ['-Mode', 'remember', '-Text', '- [pin] puerto 8443'])
    step('remember vacio', ['-Mode', 'remember', '-Text', '   '])
    step('set', ['-Mode', 'set', '-Days', '20', '-Reminder', 'off', '-ReminderTools', '5'])
    step('set valor invalido', ['-Mode', 'set', '-Transcripts', 'quizas'])
    step('set sin cambios', ['-Mode', 'set'])
    step('set reminder on', ['-Mode', 'set', '-Reminder', 'on', '-Days', '30'])
    step('list', ['-Mode', 'list'])

    # recordatorio (hook Stop)
    tr = os.path.join(root, 'transcript.jsonl')
    write(tr, '')

    def tools(n):
        with open(tr, 'a', encoding='utf-8', newline='\n') as f:
            for _ in range(n):
                f.write('{"message":{"content":[{"type":"tool_use","id":"x"}]}}\n')

    def stop(name, active=False):
        payload = json.dumps({'session_id': 'abc', 'transcript_path': tr, 'stop_hook_active': active})
        step(name, ['-Mode', 'stop'], stdin=payload, env={'CLAUDE_PROJECT_DIR': root})

    tools(3); stop('stop 3 herramientas (no avisa)')
    tools(3); stop('stop 6 herramientas (avisa)')
    stop('stop_hook_active (no repite)', active=True)
    tools(2); stop('stop +2 (no avisa)')
    time.sleep(1.1)
    with open(mem, 'a', encoding='utf-8', newline='\n') as f:
        f.write('- [%s] guardado por Claude\n' % TODAY)
    tools(9); stop('stop tras guardar (reinicia, no avisa)')
    tools(5); stop('stop +5 (avisa)')
    step('stop sin stdin', ['-Mode', 'stop'], env={'CLAUDE_PROJECT_DIR': root})

    # transcripts
    cfgdir = os.path.join(root, '_claude_home')
    enc = re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(root))
    tdir = os.path.join(cfgdir, 'projects', enc)
    os.makedirs(tdir)
    write(os.path.join(cfgdir, 'settings.json'), '{"cleanupPeriodDays": 10}\n')
    for i, d in ((1, OLD1), (2, OLD2), (3, TODAY)):
        p = os.path.join(tdir, 's%d.jsonl' % i)
        write(p, '{"s":%d}\n' % i)
        t = time.mktime(dt.datetime.combine(d, dt.time(12)).timetuple())
        os.utime(p, (t, t))
    step('transcripts on', ['-Mode', 'set', '-Transcripts', 'on'], env={'CLAUDE_CONFIG_DIR': cfgdir})
    step('now con transcripts', ['-Mode', 'now'], env={'CLAUDE_CONFIG_DIR': cfgdir})
    step('doctor final', ['-Mode', 'doctor'], env={'CLAUDE_CONFIG_DIR': cfgdir})
    step('status final', ['-Mode', 'status'], env={'CLAUDE_CONFIG_DIR': cfgdir})

    # estado final de ficheros
    arch = os.path.join(root, 'notes', 'archive')
    files = ['## FICHEROS']
    files.append('archive: ' + ' '.join(sorted(f for f in os.listdir(arch) if not f.startswith('.'))))
    files.append('transcripts restantes: ' + ' '.join(sorted(os.listdir(tdir))))
    files.append('claude dir: ' + ' '.join(sorted(os.listdir(os.path.join(root, '.claude')))))
    for name in ('CLAUDE.md', '.gitignore', os.path.join('notes', 'MEMORY-current.md'), os.path.join('.claude', 'memrotate.json')):
        files.append('### %s\n%s' % (name.replace('\\', '/'), read(os.path.join(root, name))))
    for gz in sorted(f for f in os.listdir(arch) if f.endswith('.gz')):
        files.append('### %s\n%s' % (gz, gz_text(os.path.join(arch, gz))))
    log.append('\n'.join(files))
    return normalize('\n'.join(log), root)


# ---------------------------------------------------------------- comprobaciones de comportamiento

def behaviour(t, label):
    def has(s, msg):
        check(s in t, '%s: %s' % (label, msg))

    def hasnt(s, msg):
        check(s not in t, '%s: %s' % (label, msg))

    check(re.search(r'## auto sin init \[exit 0\]\n\n## init', t) is not None, '%s: auto en proyecto sin init no imprime nada' % label)
    has('[fail] not initialized', 'doctor detecta proyecto sin init')
    has('Rotated 2 entries to: MEMORY-%s.md.gz, MEMORY-%s.md.gz.' % (OLD1.strftime('%Y-%m'), OLD2.strftime('%Y-%m')),
        'rota las 2 entradas antiguas no fijadas, cada una a su mes')
    has('The conversation was just compacted', 'aviso tras compactar')
    check(t.count('The conversation was just compacted') == 1, '%s: aviso de compactacion solo con source=compact' % label)
    has('temporal viejo Ñandú', 'acentos conservados')
    has('saved to notes/MEMORY-current.md: - [%s] la API de staging es api.example.com' % TODAY, 'remember normaliza espacios')
    has('already in memory', 'remember detecta duplicados')
    has('[pin] convención: línea uno línea dos', 'remember con -Pin por stdin y UTF-8')
    has('[pin] puerto 8443', 'remember detecta el prefijo [pin]')
    has('## remember vacio [exit 1]', 'remember vacio falla con codigo 1')
    has('[memrotate] Use -Month YYYY-MM', 'error limpio en mes invalido')
    hasnt('Exception', 'sin trazas de excepcion')
    has('<!-- memrotate:start -->', 'migra el bloque de CLAUDE.md')
    hasnt('memory-rotate:start', 'no quedan bloques antiguos')
    check(t.count('"decision":"block"') == 2, '%s: el recordatorio salta exactamente 2 veces (salto %d)'
          % (label, t.count('"decision":"block"')))
    has('Transcripts archived: 2.', 'archiva 2 transcripts')
    has('transcripts restantes: s3.jsonl', 'solo queda el transcript reciente')
    has('WARNING: cleanupPeriodDays=10', 'avisa de cleanupPeriodDays bajo')
    has('claude dir: memrotate.json', 'migra .claude/memory-rotate.json')
    has('-> 0 errors', 'doctor final sin errores')
    has('notes/archive/.sessions/', '.gitignore incluye .sessions')
    has('- [pin] ramas feat/* y fix/*', 'fijada sin fecha se queda en el vigente')
    has('  continuacion de la fijada', 'continuacion de fijada se queda')
    m = re.search(r'### MEMORY-%s\.md\.gz\n(.*?)(\n###|\Z)' % OLD2.strftime('%Y-%m'), t, re.S)
    check(m is not None and 'continuacion de la antigua' in m.group(1) and 'otra antigua' in m.group(1),
          '%s: la salva contiene la continuacion y la entrada fusionada' % label)


# ---------------------------------------------------------------- hooks reales

def hook_commands():
    with open(os.path.join(PLUGIN, 'hooks', 'hooks.json'), encoding='utf-8') as f:
        h = json.load(f)['hooks']
    root = PLUGIN.replace('\\', '/')
    return {ev: h[ev][0]['hooks'][0]['command'].replace('${CLAUDE_PLUGIN_ROOT}', root) for ev in ('SessionStart', 'Stop')}


def git_bash():
    if not WINDOWS:
        return None
    for c in (r'C:\Program Files\Git\bin\bash.exe', r'C:\Program Files (x86)\Git\bin\bash.exe'):
        if os.path.exists(c):
            return c
    return None


def test_hooks():
    shells = []
    if not WINDOWS:
        shells.append(('sh', ['sh', '-c']))
    else:
        gb = git_bash()
        if gb:
            shells.append(('git-bash', [gb, '-c']))
        shells.append(('powershell (sin Git Bash)', ['powershell', '-NoProfile', '-Command']))
    cmds = hook_commands()
    py = [sys.executable, os.path.join(SCRIPTS, 'rotate.py')]
    for name, shell in shells:
        before = len(FAILURES)
        root = tempfile.mkdtemp(prefix='memrotate-hook-')
        try:
            run(py, ['-Mode', 'init', '-ProjectDir', root])
            write(os.path.join(root, 'notes', 'MEMORY-current.md'),
                  read(os.path.join(root, 'notes', 'MEMORY-current.md')) + '- [%s] antigua\n' % OLD1)
            env = {'CLAUDE_PROJECT_DIR': root}
            code, out, err = run(shell, [cmds['SessionStart']], stdin='{"source":"compact"}', env=env)
            check(code == 0, 'hook SessionStart en %s: exit %d (%s)' % (name, code, err.strip()[:200]))
            check('Current memory' in out and 'Rotated 1 entries' in out,
                  'hook SessionStart en %s: rota y devuelve contexto (%r)' % (name, out[:200]))
            check('just compacted' in out, 'hook SessionStart en %s: recibe stdin (source=compact)' % name)
            tr = os.path.join(root, 't.jsonl')
            write(tr, '{"type":"tool_use"}\n' * 20)
            payload = json.dumps({'session_id': 'h', 'transcript_path': tr, 'stop_hook_active': False})
            code, out, err = run(shell, [cmds['Stop']], stdin=payload, env=env)
            check(code == 0, 'hook Stop en %s: exit %d (%s)' % (name, code, err.strip()[:200]))
            check('"decision":"block"' in out, 'hook Stop en %s: recibe stdin y avisa (%r)' % (name, out[:200]))
            print('  hooks en %s: %s' % (name, 'ok' if len(FAILURES) == before else 'FALLA'))
        finally:
            shutil.rmtree(root, ignore_errors=True)


def test_launcher():
    """run.sh elige el interprete correcto."""
    sh = ['sh'] if not WINDOWS else ([git_bash()] if git_bash() else None)
    if not sh:
        print('  run.sh: omitido (no hay Git Bash)')
        return
    root = tempfile.mkdtemp(prefix='memrotate-run-')
    try:
        code, out, err = run(sh, [os.path.join(SCRIPTS, 'run.sh').replace('\\', '/'), '-Mode', 'doctor', '-ProjectDir', root])
        check(code == 0, 'run.sh: exit %d (%s)' % (code, err.strip()[:200]))
        want = 'rotate.ps1' if WINDOWS else 'rotate.py'
        check(want in out, 'run.sh usa %s en este sistema (%r)' % (want, out[:160]))
        print('  run.sh: %s' % ('ok' if want in out else 'FALLA'))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_manifests():
    for rel in ('.claude-plugin/marketplace.json', 'plugins/memrotate/.claude-plugin/plugin.json', 'plugins/memrotate/hooks/hooks.json'):
        path = os.path.join(HERE, '..', rel)
        try:
            with open(path, encoding='utf-8') as f:
                json.load(f)
            PASSED[0] += 1
        except ValueError as e:
            FAILURES.append('%s no es JSON valido: %s' % (rel, e))
    for rel in ('plugins/memrotate/scripts/run.sh', 'plugins/memrotate/scripts/rotate.py'):
        with open(os.path.join(HERE, '..', rel), 'rb') as f:
            check(b'\r\n' not in f.read(), '%s debe tener finales de linea LF' % rel)


# ---------------------------------------------------------------- main

def main():
    print('memrotate tests - %s, Python %s' % (sys.platform, sys.version.split()[0]))
    test_manifests()
    results = {}
    for label, cmd in implementations():
        root = tempfile.mkdtemp(prefix='memrotate-%s-' % label)
        try:
            results[label] = scenario(cmd, os.path.realpath(root))
        finally:
            shutil.rmtree(root, ignore_errors=True)
        before = len(FAILURES)
        behaviour(results[label], label)
        print('  %-5s comportamiento: %s' % (label, 'ok' if len(FAILURES) == before else 'FALLA'))
    labels = list(results)
    for other in labels[1:]:
        same = results[labels[0]] == results[other]
        check(same, 'paridad %s vs %s' % (labels[0], other))
        print('  paridad %s vs %s: %s' % (labels[0], other, 'identica' if same else 'DIFERENTE'))
        if not same:
            import difflib
            for line in list(difflib.unified_diff(results[labels[0]].splitlines(), results[other].splitlines(),
                                                  labels[0], other, lineterm='', n=1))[:60]:
                print('    ' + line)
    if len(labels) == 1:
        print('  aviso: no hay PowerShell, solo se prueba rotate.py')
    test_hooks()
    test_launcher()
    print('\n%d comprobaciones correctas, %d fallos' % (PASSED[0], len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
