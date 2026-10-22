#!/usr/bin/env python3
"""memrotate para Linux y macOS. Equivalente a rotate.ps1 (Windows).

Mantiene un fichero de memoria "vigente" con los ultimos N dias y archiva lo
anterior en salvas mensuales comprimidas (.md.gz) consultables.

Mismos modos, argumentos y salida que rotate.ps1:
  init    Prepara el proyecto (fichero vigente, carpeta de salvas, bloque en CLAUDE.md)
  auto    Lo usa el hook SessionStart: rota como maximo una vez al dia y devuelve contexto
  now     Fuerza una rotacion
  status  Muestra configuracion y estado
  set     Cambia la configuracion del proyecto (-Days, -Transcripts, -Reminder, -ReminderTools)
  list    Muestra el indice de salvas
  search  Busca texto en las salvas y en el fichero vigente (-Query)
  read    Imprime una salva completa (-Month AAAA-MM)
  stop    Lo usa el hook Stop: si se ha trabajado sin tocar la memoria, pide a Claude que guarde lo aprendido
  remember  Anade una entrada con la fecha de hoy (-Text "..." o por stdin; -Pin para fijarla)
  doctor  Diagnostico de la instalacion y del proyecto

Las entradas marcadas con [pin] nunca rotan:  - [AAAA-MM-DD] [pin] texto   o   - [pin] texto
Solo usa la biblioteca estandar (Python 3.6+).
"""
import argparse
import datetime as dt
import gzip
import json
import os
import platform
import re
import sys
import zipfile

ENTRY_RE = re.compile(r'^\s*[-*]\s*\[(\d{4}-\d{2}-\d{2})\]')
PIN_RE = re.compile(r'^\s*[-*]\s*(\[\d{4}-\d{2}-\d{2}\]\s*)?\[pin\]', re.IGNORECASE)
CONT_RE = re.compile(r'^\s{2,}\S')
BULLET_RE = re.compile(r'^\s*[-*]\s')
PREFIX_RE = re.compile(r'^\s*([-*]\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)?(\[pin\]\s*)?', re.IGNORECASE)
PIN_PREFIX_RE = re.compile(r'^\s*([-*]\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)?\[pin\]', re.IGNORECASE)
ITEM_RE = re.compile(r'^\s*[-*]\s+\S')
TAG = '[memrotate]'
MD_START = '<!-- memrotate:start -->'
MD_END = '<!-- memrotate:end -->'
LEGACY_START = '<!-- memory-rotate:start -->'
LEGACY_END = '<!-- memory-rotate:end -->'
MODES = ['init', 'auto', 'now', 'status', 'set', 'list', 'search', 'read', 'stop', 'remember', 'doctor']


class UserError(Exception):
    pass


# ---------------------------------------------------------------- argumentos (estilo PowerShell)

def parse_args(argv):
    p = argparse.ArgumentParser(prog='rotate.py', allow_abbrev=False)
    p.add_argument('-Mode', default='status', type=str.lower, choices=MODES)
    p.add_argument('-Days', type=int, default=0)
    p.add_argument('-Transcripts', default='')
    p.add_argument('-Reminder', default='')
    p.add_argument('-ReminderTools', type=int, default=0)
    p.add_argument('-Query', default='')
    p.add_argument('-Text', default='')
    p.add_argument('-Pin', action='store_true')
    p.add_argument('-Month', default='')
    p.add_argument('-ProjectDir', default='')
    p.add_argument('-DataDir', default='')
    p.add_argument('-DefaultDays', default='')
    p.add_argument('-DefaultTranscripts', default='')
    p.add_argument('-DryRun', action='store_true')
    return p.parse_args(argv)


ARGS = None

# ---------------------------------------------------------------- helpers


def truthy(v):
    return bool(re.match(r'^(true|1|yes|on|si)$', str(v or ''), re.IGNORECASE))


def falsy(v):
    return bool(re.match(r'^(false|0|no|off)$', str(v or ''), re.IGNORECASE))


def substituted(v):
    """Un valor es util solo si Claude Code lo sustituyo (no quedan restos de plantilla)."""
    return bool(v) and not re.search(r'[${}]', v)


def project_root():
    if ARGS.ProjectDir:
        return os.path.realpath(ARGS.ProjectDir)
    if os.environ.get('CLAUDE_PROJECT_DIR'):
        return os.environ['CLAUDE_PROJECT_DIR']
    return os.getcwd()


def j(*parts):
    return os.path.join(*parts)


def read_text(path):
    with open(path, 'r', encoding='utf-8-sig', newline='') as f:
        return f.read()


def write_text(path, text):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
    os.replace(tmp, path)


def read_gz(path):
    with gzip.open(path, 'rb') as f:
        return f.read().decode('utf-8-sig')


def write_gz(path, text):
    tmp = path + '.tmp'
    with gzip.open(tmp, 'wb', compresslevel=9) as f:
        f.write(text.encode('utf-8'))
    os.replace(tmp, path)


def split_lines(text):
    if not text:
        return []
    return text.replace('\r\n', '\n').rstrip('\n').split('\n')


def entry_date(line):
    m = ENTRY_RE.match(line)
    if not m:
        return None
    try:
        return dt.datetime.strptime(m.group(1), '%Y-%m-%d').date()
    except ValueError:
        return None


def pinned(line):
    return bool(PIN_RE.match(line))


def today():
    return dt.date.today()


def now_str(fmt):
    return dt.datetime.now().strftime(fmt)


def fmt_kb(size):
    v = round(size / 1024.0, 1)
    return str(int(v)) if v == int(v) else str(v)


def out(*lines):
    for line in lines:
        sys.stdout.write(line + '\n')


# ---------------------------------------------------------------- configuracion

def plugin_data_dir():
    if os.environ.get('CLAUDE_PLUGIN_DATA'):
        return os.environ['CLAUDE_PLUGIN_DATA']
    if substituted(ARGS.DataDir):
        return ARGS.DataDir
    return None


def project_config_path(root):
    # Admite el nombre antiguo (memory-rotate, hasta 0.2.x)
    for n in ('.claude/memrotate.json', '.claude/memory-rotate.json'):
        p = j(root, n)
        if os.path.exists(p):
            return p
    return None


def get_config(root):
    cfg = {
        'retentionDays': 30,
        'memoryFile': 'notes/MEMORY-current.md',
        'archiveDir': 'notes/archive',
        'archiveTranscripts': False,
        'saveReminder': True,
        'reminderEveryTools': 15,
    }
    source = 'defaults'
    # 1) Opciones globales del plugin (userConfig). En hooks llegan como variables de
    #    entorno y se cachean; desde la skill no llegan y se leen de esa cache.
    env_days = os.environ.get('CLAUDE_PLUGIN_OPTION_RETENTION_DAYS', '')
    env_tr = os.environ.get('CLAUDE_PLUGIN_OPTION_ARCHIVE_TRANSCRIPTS', '')
    env_rem = os.environ.get('CLAUDE_PLUGIN_OPTION_SAVE_REMINDER', '')
    data = plugin_data_dir()
    cache = j(data, 'options.json') if data else None
    if (env_days or env_tr or env_rem) and cache:
        try:
            write_text(cache, json.dumps({'retention_days': env_days, 'archive_transcripts': env_tr,
                                          'save_reminder': env_rem,
                                          'savedAt': now_str('%Y-%m-%dT%H:%M:%S')}, indent=2) + '\n')
        except OSError:
            pass
    if (not env_days or not env_tr or not env_rem) and cache and os.path.exists(cache):
        try:
            c = json.loads(read_text(cache))
            env_days = env_days or str(c.get('retention_days') or '')
            env_tr = env_tr or str(c.get('archive_transcripts') or '')
            env_rem = env_rem or str(c.get('save_reminder') or '')
        except (OSError, ValueError):
            pass
    if not env_days and substituted(ARGS.DefaultDays):
        env_days = ARGS.DefaultDays
    if not env_tr and substituted(ARGS.DefaultTranscripts):
        env_tr = ARGS.DefaultTranscripts
    if env_days or env_tr or env_rem:
        source = 'plugin options (/config)'
    try:
        n = int(str(env_days).split('.')[0]) if env_days else 0
        if n > 0:
            cfg['retentionDays'] = n
    except ValueError:
        pass
    if env_tr:
        if truthy(env_tr):
            cfg['archiveTranscripts'] = True
        elif falsy(env_tr):
            cfg['archiveTranscripts'] = False
    if env_rem:
        if truthy(env_rem):
            cfg['saveReminder'] = True
        elif falsy(env_rem):
            cfg['saveReminder'] = False

    # 2) Configuracion del proyecto (.claude/memrotate.json) tiene prioridad
    p = project_config_path(root)
    if p:
        source = os.path.basename(p)
        pj = json.loads(read_text(p))
        for k in cfg:
            if pj.get(k) is not None:
                cfg[k] = pj[k]
    cfg['retentionDays'] = int(cfg['retentionDays'])
    cfg['archiveTranscripts'] = bool(cfg['archiveTranscripts'])
    cfg['saveReminder'] = bool(cfg['saveReminder'])
    cfg['reminderEveryTools'] = max(1, int(cfg['reminderEveryTools']))
    cfg['source'] = source
    return cfg


def save_project_config(root, changes):
    p = j(root, '.claude/memrotate.json')
    legacy = j(root, '.claude/memory-rotate.json')
    obj = {}
    src = project_config_path(root)
    if src:
        obj.update(json.loads(read_text(src)))
    obj.update(changes)
    # Claves ordenadas alfabeticamente: mismo fichero en Windows, Linux y macOS
    write_text(p, json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + '\n')
    if os.path.exists(legacy):
        os.remove(legacy)  # migracion: ya esta copiado en el nuevo


def state_path(root, cfg):
    return j(root, cfg['archiveDir'], '.state.json')


def get_state(root, cfg):
    p = state_path(root, cfg)
    if os.path.exists(p):
        try:
            return json.loads(read_text(p))
        except (OSError, ValueError):
            pass
    return None


def save_state(root, cfg, result):
    st = {
        'lastRun': today().isoformat(),
        'lastRunAt': now_str('%Y-%m-%d %H:%M'),
        'lastMoved': result['moved'],
        'lastTrMoved': result['transcripts'],
        'retentionDays': cfg['retentionDays'],
    }
    write_text(state_path(root, cfg), json.dumps(st, indent=2) + '\n')


# ---------------------------------------------------------------- rotacion de memoria

def rotate_memory(root, cfg):
    mem = j(root, cfg['memoryFile'])
    arch = j(root, cfg['archiveDir'])
    cutoff = today() - dt.timedelta(days=cfg['retentionDays'])
    result = {'moved': 0, 'months': []}
    if not os.path.exists(mem):
        return result

    keep, moved, last_key = [], {}, None
    for line in split_lines(read_text(mem)):
        if pinned(line):
            last_key = None
            keep.append(line)
            continue
        d = entry_date(line)
        if d is not None:
            if d < cutoff:
                last_key = d.strftime('%Y-%m')
                moved.setdefault(last_key, []).append(line)
                result['moved'] += 1
                continue
            last_key = None
            keep.append(line)
            continue
        # Lineas de continuacion (indentadas) viajan con su entrada
        if last_key and CONT_RE.match(line) and not BULLET_RE.match(line):
            moved[last_key].append(line)
            continue
        last_key = None
        keep.append(line)

    result['months'] = sorted(moved)
    if result['moved'] == 0 or ARGS.DryRun:
        return result

    os.makedirs(arch, exist_ok=True)
    # 1) Primero se escriben las salvas (si algo falla, el vigente queda intacto)
    for key in sorted(moved):
        gz = j(arch, 'MEMORY-%s.md.gz' % key)
        existing = split_lines(read_gz(gz)) if os.path.exists(gz) else ['# Archived memory - %s' % key, '']
        seen = set(existing)
        out_lines = list(existing)
        for m in moved[key]:
            if m not in seen or CONT_RE.match(m):
                seen.add(m)
                out_lines.append(m)
        write_gz(gz, '\n'.join(out_lines) + '\n')
    # 2) Despues se reescribe el vigente solo con lo reciente
    write_text(mem, '\n'.join(keep) + '\n')
    return result


# ---------------------------------------------------------------- transcripts (opcional)

def claude_config_dir():
    if os.environ.get('CLAUDE_CONFIG_DIR'):
        return os.environ['CLAUDE_CONFIG_DIR']
    return j(os.path.expanduser('~'), '.claude')


def transcript_dir(root):
    projects = j(claude_config_dir(), 'projects')
    if not os.path.isdir(projects):
        return None
    encoded = re.sub(r'[^A-Za-z0-9]', '-', root)
    cand = j(projects, encoded)
    if os.path.isdir(cand):
        return cand
    for name in os.listdir(projects):
        if name.lower() == encoded.lower() and os.path.isdir(j(projects, name)):
            return j(projects, name)
    return None


def cleanup_period_days():
    p = j(claude_config_dir(), 'settings.json')
    if os.path.exists(p):
        try:
            s = json.loads(read_text(p))
            if 'cleanupPeriodDays' in s:
                return int(s['cleanupPeriodDays'])
        except (OSError, ValueError):
            pass
    return 30


def archive_transcripts(root, cfg):
    if not cfg['archiveTranscripts']:
        return 0
    d = transcript_dir(root)
    if not d:
        return 0
    cutoff = dt.datetime.combine(today() - dt.timedelta(days=cfg['retentionDays']), dt.time())
    old = []
    for name in os.listdir(d):
        full = j(d, name)
        if name.endswith('.jsonl') and os.path.isfile(full):
            mtime = dt.datetime.fromtimestamp(os.path.getmtime(full))
            if mtime < cutoff:
                old.append((full, name, mtime))
    if not old or ARGS.DryRun:
        return len(old)

    arch = j(root, cfg['archiveDir'])
    os.makedirs(arch, exist_ok=True)
    groups = {}
    for item in old:
        groups.setdefault(item[2].strftime('%Y-%m'), []).append(item)
    count = 0
    for month, items in groups.items():
        zpath = j(arch, 'transcripts-%s.zip' % month)
        with zipfile.ZipFile(zpath, 'a', compression=zipfile.ZIP_DEFLATED) as z:
            names = set(z.namelist())
            for full, name, _ in items:
                if name not in names:
                    z.write(full, name)
        # Solo se elimina el original cuando ya esta dentro del zip
        with zipfile.ZipFile(zpath, 'r') as z:
            inzip = set(z.namelist())
        for full, name, _ in items:
            if name in inzip:
                os.remove(full)
                count += 1
    return count


# ---------------------------------------------------------------- indice

def update_index(root, cfg):
    arch = j(root, cfg['archiveDir'])
    os.makedirs(arch, exist_ok=True)
    lines = [
        '# Archived memory index', '',
        'Current file: `%s` (last %d days).' % (cfg['memoryFile'], cfg['retentionDays']),
        'Updated: %s' % now_str('%Y-%m-%d %H:%M'), '',
        '| Archive | Period | Entries |', '|---|---|---|',
    ]
    files = sorted((f for f in os.listdir(arch) if re.match(r'^MEMORY-.*\.md\.gz$', f)), reverse=True)
    for f in files:
        dates = sorted(d for d in (entry_date(l) for l in split_lines(read_gz(j(arch, f)))) if d is not None)
        period = '%s to %s' % (dates[0].isoformat(), dates[-1].isoformat()) if dates else '-'
        lines.append('| %s | %s | %d |' % (f, period, len(dates)))
    if not files:
        lines.append('| (no archives yet) | - | 0 |')
    zips = sorted((f for f in os.listdir(arch) if re.match(r'^transcripts-.*\.zip$', f)), reverse=True)
    if zips:
        lines += ['', '## Archived transcripts', '', '| File | Sessions |', '|---|---|']
        for z in zips:
            with zipfile.ZipFile(j(arch, z)) as zf:
                lines.append('| %s | %d |' % (z, len(zf.namelist())))
    write_text(j(arch, 'INDEX.md'), '\n'.join(lines) + '\n')


# ---------------------------------------------------------------- init

def claude_md_block(cfg):
    return '\n'.join([
        MD_START,
        '## Project memory (memrotate)',
        '',
        '@%s' % cfg['memoryFile'],
        '',
        "- The current memory file is `%s`, loaded above. It only holds recent entries." % cfg['memoryFile'],
        "- When you learn something durable (a decision, finding, configuration or solved problem), append it to the END of that file as one line `- [YYYY-MM-DD] text` with today's date. One idea per line.",
        '- If the fact stays true long-term (architecture, hostnames, ports, credentials locations, conventions), pin it so it never rotates: `- [YYYY-MM-DD] [pin] text`. Use [pin] sparingly; time-bound notes must not be pinned.',
        '- Do not rewrite or delete existing entries; if something changes, append a new entry that corrects it. If a pinned fact becomes false, remove its [pin] marker and append the correction.',
        "- Older entries are archived, compressed, in `%s/`. If something is not in the current file, use the `memrotate:archive` skill." % cfg['archiveDir'],
        MD_END,
    ])


def block_re(start, end):
    return re.compile(re.escape(start) + r'[\s\S]*?' + re.escape(end))


def do_init(root, cfg):
    mem = j(root, cfg['memoryFile'])
    created = []
    if not os.path.exists(mem):
        header = '\n'.join([
            '# Project memory', '',
            '<!-- memrotate: one entry per line, always dated. Format: - [YYYY-MM-DD] text -->',
            '<!-- Entries older than the retention period are moved automatically to the archive folder. -->',
            '<!-- Pinned entries never rotate. Format: - [YYYY-MM-DD] [pin] text -->',
            '',
        ])
        write_text(mem, header + '\n')
        created.append(cfg['memoryFile'])
    update_index(root, cfg)
    created.append('%s/INDEX.md' % cfg['archiveDir'])

    claude_md = j(root, 'CLAUDE.md')
    block = claude_md_block(cfg)
    if os.path.exists(claude_md):
        txt = read_text(claude_md)
        legacy = block_re(LEGACY_START, LEGACY_END)
        if LEGACY_START in txt and MD_START not in txt:
            txt = legacy.sub(lambda m: block, txt, count=1)
        elif MD_START in txt:
            txt = block_re(MD_START, MD_END).sub(lambda m: block, txt)
            if LEGACY_START in txt:
                txt = re.sub(r'\n*' + legacy.pattern, '', txt)
        else:
            txt = txt.rstrip() + '\n\n' + block + '\n'
        write_text(claude_md, txt)
    else:
        write_text(claude_md, block + '\n')
        created.append('CLAUDE.md')

    # Ignorar ficheros temporales del plugin en git, si hay .gitignore
    gi = j(root, '.gitignore')
    if os.path.exists(gi):
        g = read_text(gi)
        for line in ('%s/.state.json' % cfg['archiveDir'], '%s/.sessions/' % cfg['archiveDir']):
            if line not in g:
                g = g.rstrip() + '\n' + line + '\n'
        write_text(gi, g)
    return created


# ---------------------------------------------------------------- salida

def mem_lines(root, cfg):
    mem = j(root, cfg['memoryFile'])
    return split_lines(read_text(mem)) if os.path.exists(mem) else []


def entry_count(root, cfg):
    return sum(1 for l in mem_lines(root, cfg) if entry_date(l) is not None or pinned(l))


def pinned_count(root, cfg):
    return sum(1 for l in mem_lines(root, cfg) if pinned(l))


def transcript_warning(cfg):
    if not cfg['archiveTranscripts']:
        return None
    cp = cleanup_period_days()
    if cp <= cfg['retentionDays']:
        return ('WARNING: cleanupPeriodDays=%d in settings.json is <= the retention period (%d). Claude Code may '
                'delete transcripts before they are archived; raise it (e.g. %d).'
                % (cp, cfg['retentionDays'], cfg['retentionDays'] + 30))
    return None


def write_status(root, cfg):
    state = get_state(root, cfg)
    mem = j(root, cfg['memoryFile'])
    size = os.path.getsize(mem) if os.path.exists(mem) else 0
    out('%s status' % TAG,
        '  project             : %s' % root,
        '  retention           : %d days' % cfg['retentionDays'],
        '  current file        : %s (%d entries, %d pinned, %s KB)' % (
            cfg['memoryFile'], entry_count(root, cfg), pinned_count(root, cfg), fmt_kb(size)),
        '  archive folder      : %s' % cfg['archiveDir'],
        '  archive transcripts : %s' % cfg['archiveTranscripts'],
        '  save reminder       : %s (every %d tool calls without saving)' % (
            cfg['saveReminder'], cfg['reminderEveryTools']))
    if state:
        out('  last rotation       : %s (entries moved: %s)' % (state.get('lastRunAt'), state.get('lastMoved')))
    else:
        out('  last rotation       : never')
    if not os.path.exists(mem):
        out('  -> Not initialized in this project. Run: /memrotate:rotate init')
    if cfg['archiveTranscripts']:
        td = transcript_dir(root)
        out('  transcripts         : %s' % td if td else '  transcripts         : project folder not found in ~/.claude/projects')
    w = transcript_warning(cfg)
    if w:
        out('  ' + w)


# ---------------------------------------------------------------- stdin (hooks y remember)

def read_stdin_text():
    try:
        if sys.stdin is not None and not sys.stdin.isatty():
            data = sys.stdin.buffer.read()
            return data.decode('utf-8-sig', errors='replace')
    except (OSError, ValueError, AttributeError):
        pass
    return ''


def read_hook_input():
    # Mismo contrato que rotate.ps1: el hook puede pasar la entrada en MEMROTATE_HOOK_INPUT
    raw = os.environ.get('MEMROTATE_HOOK_INPUT') or read_stdin_text()
    if raw.strip():
        try:
            data = json.loads(raw)
            return data if isinstance(data, dict) else {}
        except ValueError:
            pass
    return {}


# ---------------------------------------------------------------- remember

def entry_body(line):
    return PREFIX_RE.sub('', line, count=1).strip()


def remember(root, cfg):
    raw = ARGS.Text or read_stdin_text()
    pin_it = ARGS.Pin
    body = re.sub(r'\s+', ' ', raw or '').strip()
    if PIN_PREFIX_RE.match(body):
        pin_it = True
    body = entry_body(body)
    if not body:
        raise UserError('Nothing to remember. Use -Text "..." or pass the text on stdin.')

    mem = j(root, cfg['memoryFile'])
    notes = []
    if not os.path.exists(mem):
        do_init(root, cfg)
        notes.append('%s initialized in %s' % (TAG, root))
    for line in split_lines(read_text(mem)):
        if (entry_date(line) is not None or pinned(line)) and entry_body(line).lower() == body.lower():
            notes.append('%s already in memory: %s' % (TAG, line.strip()))
            out(*notes)
            return
    line = '- [%s] %s%s' % (today().isoformat(), '[pin] ' if pin_it else '', body)
    txt = read_text(mem)
    if txt and not txt.endswith('\n'):
        txt += '\n'
    write_text(mem, txt + line + '\n')
    notes.append('%s saved to %s: %s' % (TAG, cfg['memoryFile'], line))
    out(*notes)


# ---------------------------------------------------------------- doctor

def plugin_version():
    pj = j(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.claude-plugin', 'plugin.json')
    try:
        return json.loads(read_text(pj)).get('version', 'unknown')
    except (OSError, ValueError):
        return 'unknown'


def doctor(root, cfg):
    counts = {'fail': 0, 'warn': 0}
    lines = ['%s doctor' % TAG]

    def check(level, msg):
        if level in counts:
            counts[level] += 1
        lines.append('  %-6s %s' % ('[%s]' % level, msg))

    check('ok', 'plugin %s (rotate.py, Python %s)' % (plugin_version(), platform.python_version()))
    check('ok', 'project: %s' % root)
    check('ok', 'settings: %s (retention %d days)' % (cfg['source'], cfg['retentionDays']))
    if os.path.exists(j(root, '.claude/memory-rotate.json')):
        check('warn', 'old settings file .claude/memory-rotate.json: it is migrated on the next /memrotate:rotate days|transcripts|reminder')

    mem = j(root, cfg['memoryFile'])
    if not os.path.exists(mem):
        check('fail', 'not initialized in this project: run /memrotate:rotate init')
    else:
        size = os.path.getsize(mem)
        ml = split_lines(read_text(mem))
        entries = sum(1 for l in ml if entry_date(l) is not None or pinned(l))
        pins = sum(1 for l in ml if pinned(l))
        undated = sum(1 for l in ml if ITEM_RE.match(l) and entry_date(l) is None and not pinned(l))
        check('ok', 'current file: %s (%d entries, %d pinned, %s KB)' % (cfg['memoryFile'], entries, pins, fmt_kb(size)))
        if size > 40 * 1024:
            check('warn', 'current file is %d KB and is loaded in every session: lower the retention or unpin entries'
                  % int(round(size / 1024.0)))
        if undated > 0:
            check('warn', '%d bullet lines without a date never rotate (format: - [YYYY-MM-DD] text)' % undated)
        if pins > 30:
            check('warn', '%d pinned entries: pinned entries never rotate, review if all still matter' % pins)

        cmd = j(root, 'CLAUDE.md')
        ctxt = read_text(cmd) if os.path.exists(cmd) else ''
        if MD_START in ctxt:
            if ('@' + cfg['memoryFile']) in ctxt:
                check('ok', 'CLAUDE.md loads %s' % cfg['memoryFile'])
            else:
                check('warn', 'CLAUDE.md block does not load %s: run /memrotate:rotate init' % cfg['memoryFile'])
        elif LEGACY_START in ctxt:
            check('warn', 'CLAUDE.md has the old memory-rotate block: restart Claude Code or run /memrotate:rotate init')
        else:
            check('fail', 'CLAUDE.md has no memrotate block: run /memrotate:rotate init')

        state = get_state(root, cfg)
        if not state:
            check('warn', 'no rotation recorded yet: restart Claude Code so the SessionStart hook runs')
        else:
            last = dt.datetime.strptime(str(state.get('lastRun')), '%Y-%m-%d').date()
            ago = (today() - last).days
            if ago <= 1:
                check('ok', 'SessionStart hook: last rotation %s' % state.get('lastRunAt'))
            else:
                check('warn', 'last rotation was %d days ago (%s): the SessionStart hook may not be running, check /plugin > Errors'
                      % (ago, state.get('lastRunAt')))

        if cfg['saveReminder']:
            sdir = j(root, cfg['archiveDir'], '.sessions')
            seen = []
            if os.path.isdir(sdir):
                seen = sorted((os.path.getmtime(j(sdir, f)) for f in os.listdir(sdir) if f.endswith('.json')), reverse=True)
            if seen:
                check('ok', 'Stop hook: save reminder every %d tool calls, last seen %s'
                      % (cfg['reminderEveryTools'], dt.datetime.fromtimestamp(seen[0]).strftime('%Y-%m-%d %H:%M')))
            else:
                check('warn', 'Stop hook has not run in this project yet (normal right after installing; it runs when Claude ends a turn)')
        else:
            check('ok', 'save reminder: off')

        arch = j(root, cfg['archiveDir'])
        gzc = sum(1 for f in os.listdir(arch) if re.match(r'^MEMORY-.*\.md\.gz$', f)) if os.path.isdir(arch) else 0
        check('ok', 'archives: %d in %s' % (gzc, cfg['archiveDir']))

        gi = j(root, '.gitignore')
        if os.path.exists(gi):
            g = read_text(gi)
            if ('%s/.state.json' % cfg['archiveDir']) in g and ('%s/.sessions/' % cfg['archiveDir']) in g:
                check('ok', '.gitignore ignores the plugin state files')
            else:
                check('warn', '.gitignore does not ignore the plugin state files: run /memrotate:rotate init')

    if cfg['archiveTranscripts']:
        w = transcript_warning(cfg)
        if w:
            check('warn', w)
        else:
            check('ok', 'transcript archiving on (cleanupPeriodDays=%d)' % cleanup_period_days())
    lines.append('  -> %d errors, %d warnings' % (counts['fail'], counts['warn']))
    out(*lines)


# ---------------------------------------------------------------- recordatorio de guardado (hook Stop)

def tool_use_count(path):
    if not path or not os.path.exists(path):
        return 0
    rx = re.compile(r'"type"\s*:\s*"tool_use"')
    n = 0
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            n += len(rx.findall(line))
    return n


def stop_hook(root, cfg):
    data = read_hook_input()
    # Evitar bucles: si Claude ya esta continuando por un Stop hook, no volver a bloquear
    if data.get('stop_hook_active'):
        return
    if not cfg['saveReminder']:
        return
    mem = j(root, cfg['memoryFile'])
    if not os.path.exists(mem):
        return

    sid = re.sub(r'[^A-Za-z0-9_-]', '', str(data.get('session_id') or 'default')) or 'default'
    tools = tool_use_count(data.get('transcript_path'))
    sdir = j(root, cfg['archiveDir'], '.sessions')
    sp = j(sdir, '%s.json' % sid)
    mem_ticks = os.stat(mem).st_mtime_ns
    st = None
    if os.path.exists(sp):
        try:
            st = json.loads(read_text(sp))
        except (OSError, ValueError):
            st = None
    base, last_mem = (int(st.get('baseTools', 0)), int(st.get('memTicks', mem_ticks))) if st else (0, mem_ticks)

    remind, since = False, 0
    if mem_ticks != last_mem:
        base = tools  # Claude ha guardado algo: se reinicia el contador
    elif tools - base >= cfg['reminderEveryTools']:
        remind, since, base = True, tools - base, tools
    write_text(sp, json.dumps({'baseTools': base, 'memTicks': mem_ticks,
                               'updated': now_str('%Y-%m-%dT%H:%M:%S')}) + '\n')

    # Limpieza de estados de sesiones antiguas
    limit = dt.datetime.now().timestamp() - 7 * 86400
    for name in os.listdir(sdir):
        full = j(sdir, name)
        try:
            if name.endswith('.json') and os.path.getmtime(full) < limit:
                os.remove(full)
        except OSError:
            pass

    if remind:
        reason = ("%s Memory checkpoint: %d tool calls since the memory file was last updated. "
                  "If this work produced durable knowledge (decisions, configurations, hostnames, ports, fixes, gotchas) "
                  "that is not already in %s, append it now at the end of that file, one line per fact: '- [%s] text'. "
                  "Mark facts that stay true long-term with [pin]: '- [YYYY-MM-DD] [pin] text'. Do not duplicate existing entries. "
                  "If there is nothing worth saving, end your turn without any further output."
                  % (TAG, since, cfg['memoryFile'], today().isoformat()))
        sys.stdout.write(json.dumps({'decision': 'block', 'reason': reason}, separators=(',', ':'), ensure_ascii=False))


# ---------------------------------------------------------------- main

def main(argv):
    global ARGS
    ARGS = parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except (AttributeError, ValueError):
        pass
    root = project_root()
    cfg = get_config(root)
    mode = ARGS.Mode

    if mode == 'init':
        if ARGS.Days > 0:
            save_project_config(root, {'retentionDays': ARGS.Days})
            cfg = get_config(root)
        created = do_init(root, cfg)
        out('%s initialized in %s' % (TAG, root))
        for c in created:
            out('  + %s' % c)
        out('  retention: %d days' % cfg['retentionDays'])

    elif mode == 'set':
        changes = {}
        if ARGS.Days > 0:
            changes['retentionDays'] = ARGS.Days
        for arg, key in ((ARGS.Transcripts, 'archiveTranscripts'), (ARGS.Reminder, 'saveReminder')):
            if arg:
                if truthy(arg):
                    changes[key] = True
                elif falsy(arg):
                    changes[key] = False
                else:
                    name = 'Transcripts' if key == 'archiveTranscripts' else 'Reminder'
                    raise UserError('Invalid -%s value: %s (use on|off)' % (name, arg))
        if ARGS.ReminderTools > 0:
            changes['reminderEveryTools'] = ARGS.ReminderTools
        if not changes:
            raise UserError('Nothing to change. Use -Days N, -Transcripts on|off, -Reminder on|off and/or -ReminderTools N.')
        save_project_config(root, changes)
        cfg = get_config(root)
        if os.path.exists(j(root, cfg['memoryFile'])):
            update_index(root, cfg)
        out('%s settings saved to .claude/memrotate.json' % TAG)
        write_status(root, cfg)

    elif mode in ('auto', 'now'):
        mem = j(root, cfg['memoryFile'])
        if not os.path.exists(mem):
            if mode == 'now':
                out('%s not initialized in this project. Run first: /memrotate:rotate init' % TAG)
            return 0  # en modo auto, silencio total en proyectos que no usan el plugin
        hook_in = read_hook_input() if mode == 'auto' else {}
        try:
            # Migracion automatica desde memory-rotate (<= 0.2.x): refresca el bloque de CLAUDE.md
            cmd = j(root, 'CLAUDE.md')
            if os.path.exists(cmd) and LEGACY_START in read_text(cmd):
                do_init(root, cfg)
            state = get_state(root, cfg)
            result = {'moved': 0, 'months': [], 'transcripts': 0}
            if mode == 'now' or not state or state.get('lastRun') != today().isoformat():
                r = rotate_memory(root, cfg)
                result['moved'], result['months'] = r['moved'], r['months']
                result['transcripts'] = archive_transcripts(root, cfg)
                if not ARGS.DryRun:
                    update_index(root, cfg)
                    save_state(root, cfg, result)
            msg = ('%s Current memory: %s (%d entries, %d pinned, last %d days). Older archives: %s/INDEX.md; '
                   'use the memrotate:archive skill to query them.'
                   % (TAG, cfg['memoryFile'], entry_count(root, cfg), pinned_count(root, cfg),
                      cfg['retentionDays'], cfg['archiveDir']))
            if result['moved'] > 0:
                msg += ' Rotated %d entries to: %s.' % (
                    result['moved'], ', '.join('MEMORY-%s.md.gz' % m for m in result['months']))
            if result['transcripts'] > 0:
                msg += ' Transcripts archived: %d.' % result['transcripts']
            if ARGS.DryRun:
                msg += ' (dry run: nothing was written)'
            out(msg)
            if str(hook_in.get('source', '')) == 'compact':
                out("%s The conversation was just compacted. Durable knowledge from before the compaction (decisions, "
                    "configurations, hostnames, ports, fixes) that is not yet in %s should be appended there now, one line "
                    "per fact: '- [%s] text', with [pin] for long-lived facts." % (TAG, cfg['memoryFile'], today().isoformat()))
            w = transcript_warning(cfg)
            if w:
                out('%s %s' % (TAG, w))
        except Exception as e:  # nunca romper el arranque de la sesion por un fallo de rotacion
            sys.stderr.write('%s error: %s\n' % (TAG, e))
            return 1 if mode == 'now' else 0

    elif mode == 'status':
        write_status(root, cfg)

    elif mode == 'remember':
        remember(root, cfg)

    elif mode == 'doctor':
        doctor(root, cfg)

    elif mode == 'stop':
        # Nunca bloquear ni romper el cierre de un turno por un fallo del plugin
        try:
            stop_hook(root, cfg)
        except Exception as e:
            sys.stderr.write('%s stop hook error: %s\n' % (TAG, e))
        return 0

    elif mode == 'list':
        idx = j(root, cfg['archiveDir'], 'INDEX.md')
        if os.path.exists(j(root, cfg['memoryFile'])):
            update_index(root, cfg)
        if os.path.exists(idx):
            sys.stdout.write(read_text(idx))
        else:
            out('%s no archives in %s' % (TAG, cfg['archiveDir']))

    elif mode == 'search':
        if not ARGS.Query:
            raise UserError('Missing -Query "text"')
        arch = j(root, cfg['archiveDir'])
        sources = []
        mem = j(root, cfg['memoryFile'])
        if os.path.exists(mem):
            sources.append(('current', split_lines(read_text(mem))))
        if os.path.isdir(arch):
            for f in sorted((f for f in os.listdir(arch) if re.match(r'^MEMORY-.*\.md\.gz$', f)), reverse=True):
                sources.append((f[:-len('.md.gz')], split_lines(read_gz(j(arch, f)))))
        terms = [t.lower() for t in ARGS.Query.split() if t]
        hits, limit = 0, 200
        for label, lines in sources:
            for line in lines:
                low = line.lower()
                if line.strip() and all(t in low for t in terms):
                    out('%s: %s' % (label, line.strip()))
                    hits += 1
                    if hits >= limit:
                        out('%s ... limit of %d results reached, narrow the search' % (TAG, limit))
                        break
            if hits >= limit:
                break
        if hits == 0:
            out('%s no results for: %s' % (TAG, ARGS.Query))

    elif mode == 'read':
        if not re.match(r'^\d{4}-\d{2}$', ARGS.Month):
            raise UserError('Use -Month YYYY-MM (e.g. 2026-09)')
        gz = j(root, cfg['archiveDir'], 'MEMORY-%s.md.gz' % ARGS.Month)
        if not os.path.exists(gz):
            out('%s archive MEMORY-%s.md.gz does not exist' % (TAG, ARGS.Month))
            return 0
        sys.stdout.write(read_gz(gz))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except UserError as e:
        sys.stderr.write('%s %s\n' % (TAG, e))
        sys.exit(1)
