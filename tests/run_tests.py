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
import hashlib
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


# ---------------------------------------------------------------- copia de seguridad

def project_key(root):
    norm = root.replace('\\', '/').rstrip('/').lower()
    name = re.sub(r'[^A-Za-z0-9._-]', '-', os.path.basename(root.replace('\\', '/').rstrip('/'))) or 'project'
    return '%s-%s' % (name, hashlib.sha1(norm.encode('utf-8')).hexdigest()[:8])


def git(*args, cwd=None):
    p = subprocess.run(['git'] + list(args), cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0:
        raise RuntimeError('git %s: %s' % (' '.join(args), p.stdout.decode(errors='replace')))
    return p.stdout.decode().strip()


def commits(bare):
    return int(git('--git-dir', bare, 'rev-list', '--count', 'HEAD'))


def backup_scenario(cmd, base):
    """Copia a git (clon de un repo 'remoto' local) y a carpeta; restauracion en otra ruta."""
    log = []
    # Ruta real: en macOS /var es un enlace a /private/var y en Windows TEMP usa nombres cortos (RUNNER~1)
    base = os.path.realpath(base)
    bare, clone, drive = os.path.join(base, 'remote.git'), os.path.join(base, 'clone'), os.path.join(base, 'drive')
    home = os.path.join(base, 'home')
    git('init', '-q', '--bare', bare)
    git('clone', '-q', bare, clone)
    git('config', 'user.name', 'memrotate-test', cwd=clone)
    git('config', 'user.email', 'test@example.com', cwd=clone)
    git('commit', '-q', '--allow-empty', '-m', 'init', cwd=clone)
    git('push', '-q', '-u', 'origin', 'HEAD', cwd=clone)
    os.makedirs(drive)
    proj = os.path.realpath(os.path.join(base, 'pc1', 'myrepo'))
    newpc = os.path.realpath(os.path.join(base, 'pc2', 'myrepo'))
    os.makedirs(proj)
    os.makedirs(newpc)
    am = os.path.join(home, 'projects', re.sub(r'[^A-Za-z0-9]', '-', proj), 'memory')
    write(os.path.join(am, 'MEMORY.md'), '- nota de auto memory\n')
    write(os.path.join(am, 'temas', 'infra.md'), 'infra\n')
    env = {'CLAUDE_CONFIG_DIR': home}
    counts = {}

    def step(name, args, root):
        code, out, err = run(cmd, args + ['-ProjectDir', root], env=env)
        log.append('## %s [exit %d]\n%s%s' % (name, code, out, ('STDERR: ' + err.strip() + '\n') if err.strip() else ''))

    step('backup sin destino', ['-Mode', 'backup'], proj)
    step('init', ['-Mode', 'init'], proj)
    with open(os.path.join(proj, 'notes', 'MEMORY-current.md'), 'a', encoding='utf-8', newline='\n') as f:
        f.write('- [%s] antigua\n- [%s] [pin] fijada\n- [%s] reciente\n' % (OLD2, OLD1, RECENT))
    step('now', ['-Mode', 'now'], proj)
    step('set destinos', ['-Mode', 'set', '-BackupGit', clone, '-BackupDir', drive, '-BackupEvery', '0'], proj)
    step('backup', ['-Mode', 'backup'], proj)
    counts['tras backup'] = commits(bare)
    step('backup sin cambios', ['-Mode', 'backup'], proj)
    step('backup quiet sin cambios', ['-Mode', 'backup', '-Quiet'], proj)
    counts['tras sin cambios'] = commits(bare)
    mem = os.path.join(proj, 'notes', 'MEMORY-current.md')
    with open(mem, 'a', encoding='utf-8', newline='\n') as f:
        f.write('- [%s] cambio 1\n' % TODAY)
    step('backup quiet con cambios', ['-Mode', 'backup', '-Quiet'], proj)
    counts['tras cambio'] = commits(bare)
    step('intervalo 24h', ['-Mode', 'set', '-BackupEvery', '24'], proj)
    with open(mem, 'a', encoding='utf-8', newline='\n') as f:
        f.write('- [%s] cambio 2\n' % TODAY)
    step('backup quiet dentro del intervalo', ['-Mode', 'backup', '-Quiet'], proj)
    counts['dentro del intervalo'] = commits(bare)
    step('backup manual ignora el intervalo', ['-Mode', 'backup'], proj)
    counts['manual'] = commits(bare)
    step('status', ['-Mode', 'status'], proj)
    step('doctor', ['-Mode', 'doctor'], proj)

    # PC nuevo: otra ruta, misma configuracion de copia
    write(os.path.join(newpc, '.claude', 'memrotate.json'), json.dumps({'backupGit': clone, 'backupDir': drive}) + '\n')
    step('restore en pc nuevo', ['-Mode', 'restore'], newpc)
    step('restore repetido', ['-Mode', 'restore'], newpc)
    step('restore clave inexistente', ['-Mode', 'restore', '-From', 'nada-00000000'], newpc)
    step('backup destino roto', ['-Mode', 'set', '-BackupDir', os.path.join(base, 'no-existe')], proj)
    step('backup con carpeta inexistente', ['-Mode', 'backup'], proj)

    files = ['## FICHEROS']
    for top in (os.path.join(clone, project_key(proj)), os.path.join(drive, project_key(proj))):
        rels = []
        for b, _, names in os.walk(top):
            rels += [os.path.relpath(os.path.join(b, n), top).replace('\\', '/') for n in names]
        files.append('%s: %s' % (os.path.basename(os.path.dirname(top)), ' '.join(sorted(rels))))
    files.append('pc2 notas: ' + ' '.join(sorted(os.listdir(os.path.join(newpc, 'notes', 'archive')))))
    files.append('pc2 auto memory: ' + read(os.path.join(home, 'projects', re.sub(r'[^A-Za-z0-9]', '-', newpc), 'memory', 'temas', 'infra.md')).strip())
    files.append('pc2 vigente:\n' + read(os.path.join(newpc, 'notes', 'MEMORY-current.md')))
    log.append('\n'.join(files))
    text = '\n'.join(log)
    for k, v in ((project_key(proj), 'KEY1'), (project_key(newpc), 'KEY2')):
        text = text.replace(k, v)
    text = text.replace(socket_host(), 'HOST')
    return normalize(text, os.path.realpath(base)), counts


def socket_host():
    import socket
    return socket.gethostname()


def backup_behaviour(t, counts, label):
    def has(x, msg):
        check(x in t, '%s backup: %s' % (label, msg))
    has('backup: no destination configured', 'avisa si no hay destino')
    has('[ok]   git ROOT/clone: committed and pushed', 'primera copia a git: commit y push')
    has('[ok]   folder ROOT/drive: 5 files updated', 'primera copia a carpeta: 5 ficheros (vigente, salva, indice y 2 de auto memory)')
    has('[ok]   git ROOT/clone: up to date', 'sin cambios: git al dia')
    check(re.search(r'## backup quiet sin cambios \[exit 0\]\n\n', t) is not None, '%s backup: -Quiet no imprime nada' % label)
    check(counts == {'tras backup': 2, 'tras sin cambios': 2, 'tras cambio': 3, 'dentro del intervalo': 3, 'manual': 4},
          '%s backup: commits en el remoto %r' % (label, counts))
    has('every 24 h (last DATETIME)', 'status muestra el intervalo')
    has('[ok]   last backup DATETIME', 'doctor muestra la ultima copia')
    has('restore from git ROOT/clone: KEY1 (backup of DATETIME from HOST)', 'restore encuentra la copia aunque cambie la ruta')
    for r in ('+ auto-memory/MEMORY.md', '+ auto-memory/temas/infra.md', '+ memrotate/MEMORY-current.md',
              '+ memrotate/archive/INDEX.md', '+ CLAUDE.md block'):
        has(r, 'restore recupera %s' % r[2:])
    has('nothing to restore: everything is already here', 'restore repetido no hace nada')
    has('available backups (use /memrotate:rotate restore <key>):', 'restore con clave inexistente lista las copias')
    has('[fail] folder ROOT/no-existe: folder does not exist', 'carpeta inexistente da error claro')
    has('pc2 auto memory: infra', 'auto memory restaurada en la ruta nueva')
    has('[pin] fijada', 'vigente restaurado')


# ---------------------------------------------------------------- hooks reales

def hook_commands():
    with open(os.path.join(PLUGIN, 'hooks', 'hooks.json'), encoding='utf-8') as f:
        h = json.load(f)['hooks']
    root = PLUGIN.replace('\\', '/')
    return {ev: h[ev][0]['hooks'][0]['command'].replace('${CLAUDE_PLUGIN_ROOT}', root) for ev in ('SessionStart', 'Stop', 'SessionEnd')}


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
        root = os.path.realpath(tempfile.mkdtemp(prefix='memrotate-hook-'))
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
            drive = os.path.join(root, '_drive')
            os.makedirs(drive)
            write(os.path.join(root, '.claude', 'memrotate.json'), json.dumps({'backupDir': drive}) + '\n')
            code, out, err = run(shell, [cmds['SessionEnd']], stdin='{"reason":"exit"}', env=env)
            check(code == 0 and out.strip() == '', 'hook SessionEnd en %s: silencioso (exit %d, %r, %s)' % (name, code, out[:120], err.strip()[:200]))
            check(os.path.isfile(os.path.join(drive, project_key(os.path.realpath(root)), 'memrotate', 'MEMORY-current.md'))
                  or os.path.isfile(os.path.join(drive, project_key(root), 'memrotate', 'MEMORY-current.md')),
                  'hook SessionEnd en %s: copia la memoria a la carpeta' % name)
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
    results, backups = {}, {}
    for label, cmd in implementations():
        root = tempfile.mkdtemp(prefix='memrotate-%s-' % label)
        try:
            results[label] = scenario(cmd, os.path.realpath(root))
        finally:
            shutil.rmtree(root, ignore_errors=True)
        before = len(FAILURES)
        behaviour(results[label], label)
        print('  %-5s comportamiento: %s' % (label, 'ok' if len(FAILURES) == before else 'FALLA'))
        if shutil.which('git'):
            base = tempfile.mkdtemp(prefix='memrotate-bk-%s-' % label)
            try:
                text, counts = backup_scenario(cmd, base)
            finally:
                shutil.rmtree(base, ignore_errors=True)
            before = len(FAILURES)
            backup_behaviour(text, counts, label)
            backups[label] = text
            print('  %-5s copia de seguridad: %s' % (label, 'ok' if len(FAILURES) == before else 'FALLA'))
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
    for other in list(backups)[1:]:
        first = list(backups)[0]
        same = backups[first] == backups[other]
        check(same, 'paridad backup %s vs %s' % (first, other))
        print('  paridad backup %s vs %s: %s' % (first, other, 'identica' if same else 'DIFERENTE'))
        if not same:
            import difflib
            for line in list(difflib.unified_diff(backups[first].splitlines(), backups[other].splitlines(),
                                                  first, other, lineterm='', n=1))[:60]:
                print('    ' + line)
    if len(labels) == 1:
        print('  aviso: no hay PowerShell, solo se prueba rotate.py')
    test_hooks()
    test_launcher()
    print('\n%d comprobaciones correctas, %d fallos' % (PASSED[0], len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
