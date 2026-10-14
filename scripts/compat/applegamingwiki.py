#!/usr/bin/env python3
"""Freequay: turns the CrossOver tips of AppleGamingWiki into compat/applegamingwiki.txt.

AppleGamingWiki (applegamingwiki.com, CC BY-NC-SA 3.0) rates every game for CrossOver, Wine and
Parallels on Apple Silicon and collects free-text reports. The tips are written by people, so
this is careful: a graphics backend becomes a rule only when the reports for a game that runs
recommend exactly one backend and none of them reports problems with it; environment variables
only from sections about CrossOver or Wine. Ratings and the first lines of
the notes go to compat/notes.tsv for freequay info, and so do launch options found in the text,
which turned out to be too often installer flags or tips for the native Mac version.

Usage: applegamingwiki.py <cache dir of agw_fetch.py> [<version note>]
"""

import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import Rules, clean  # noqa: E402

BACKENDS = [
    (re.compile(r'\b(d3d ?metal|gptk|game porting toolkit)\b', re.I), 'd3dmetal'),
    (re.compile(r'\bdxmt\b', re.I), 'dxmt'),
    (re.compile(r'\b(dxvk|moltenvk)\b', re.I), 'dxvk'),
    (re.compile(r'\bwine ?d3d\b', re.I), 'wined3d'),
]
NEGATIVE = re.compile(r"crash|black screen|n[o']t (work|run|launch|start|load)|does ?n[o']t|doesn|did ?n[o']t|"
                      r"won'?t|can'?t|cannot|unable|broken|issue|glitch|artifact|fail|problem|freez|missing|"
                      r"invisible|flicker|corrupt|bug|error|unplayable|black|white screen|hang", re.I)
BETTER = re.compile(r'\b(better|faster|smoother|more stable|best)\b', re.I)
GOOD_RATINGS = {'perfect', 'playable', 'runs'}
# launch options that only change looks or window mode, or that belong to the native Mac version
PREFERENCE_ARGS = re.compile(r'^-(windowed|window|noborder|borderless|fullscreen|full|w|h|width|height|refresh|freq|'
                             r'fps|high|console|dev|novsync|vsync|popupwindow|screen-.*|monitor)$', re.I)
KEEP_ENV = re.compile(r'^(ROSETTA_ADVERTISE_AVX|D3DM_[A-Z0-9_]+|DXMT_[A-Z0-9_]+|MVK_[A-Z0-9_]+)$')


def strip_markup(text):
    text = re.sub(r'<ref[^>]*/>', ' ', text)
    text = re.sub(r'<ref[^>]*>.*?</ref>', ' ', text, flags=re.S)
    text = re.sub(r'\{\{code\|([^}]*)\}\}', r'\1', text)
    text = re.sub(r'\[\[(?:[^|\]]*\|)?([^\]]*)\]\]', r'\1', text)
    text = re.sub(r'\[https?://\S+\s*([^\]]*)\]', r'\1', text)
    text = re.sub(r"'{2,}", '', text)
    text = re.sub(r'<br\s*/?>', '. ', text)
    text = re.sub(r'<[^>]+>', ' ', text)
    return clean(text)


def refdevice_fields(text):
    """method, settings and comment of the {{Refdevice}} reports"""
    out = []
    for m in re.finditer(r'\{\{Refdevice(.*?)\}\}', text, re.S):
        for field in re.findall(r'\|\s*(?:method|settings|comment)\s*=([^|]*)', m.group(1)):
            if field.strip():
                out.append(strip_markup(field))
    return out


def clauses(text):
    for sentence in re.split(r'(?<=[.!?;])\s+|\n+', text):
        for clause in re.split(r',\s*(?=with|but|while|whereas|although|though|on|using|via)\b', sentence, flags=re.I):
            if clause.strip():
                yield clause


def score_backends(texts):
    score, negative = {}, set()
    for text in texts:
        for clause in clauses(text):
            found = [(m.start(), b) for rx, b in BACKENDS for m in [rx.search(clause)] if m]
            if not found:
                continue
            better = BETTER.search(clause)
            if better and ' than ' in clause.lower():
                than = clause.lower().index(' than ')
                for pos, b in found:
                    score[b] = score.get(b, 0) + (2 if pos < than else -1)
                    if pos > than:
                        negative.add(b)
                continue
            bad = NEGATIVE.search(clause)
            for pos, b in found:
                if bad:
                    negative.add(b)
                    score[b] = score.get(b, 0) - 1
                else:
                    score[b] = score.get(b, 0) + 1
    return score, negative


def param(block, name):
    m = re.search(r'\|\s*' + re.escape(name) + r'\s*=(.*?)(?=\n\s*\|[a-z0-9 ./-]+=|\Z)', block, re.S | re.I)
    return m.group(1).strip() if m else ''


def wine_sections(text):
    """text of sections about CrossOver, Wine or the compatibility layer"""
    out = []
    parts = re.split(r'^(==+[^=\n]+==+)\s*$', text, flags=re.M)
    for i in range(1, len(parts) - 1, 2):
        head, body = parts[i], parts[i + 1]
        if re.search(r'macos|native|parallels|rosetta|windows|linux', head, re.I) and \
                not re.search(r'crossover|wine|whisky', head, re.I):
            continue
        if re.search(r'crossover|wine|whisky|game porting|gptk|compatibility layer', head, re.I):
            out.append(body)
        elif re.search(r'issues? (fixed|resolved)', head, re.I) and re.search(r'crossover|wine\b|whisky', body, re.I):
            out.append(body)
    return out


def launch_options(texts):
    args, env = [], []
    for text in texts:
        for fix in re.finditer(r'launch (option|argument|parameter)|command line', text, re.I):
            window = text[max(0, fix.start() - 400):fix.end() + 400]
            for code in re.findall(r'<code>(.*?)</code>|\{\{code\|([^}]*)\}\}|<pre>(.*?)</pre>', window, re.S):
                code = clean(''.join(code))
                if '%command%' in code.lower() or '.exe' in code.lower() or '\\' in code or '/' in code:
                    continue
                for tok in code.split():
                    if re.fullmatch(r'[A-Z][A-Z0-9_]+=\S+', tok) and KEEP_ENV.match(tok.split('=')[0]):
                        env.append(tok)
                # a launch option string: switches with their values, nothing that only changes the looks
                units = re.findall(r'[-+][A-Za-z][\w.-]*(?:\s+(?![-+])[^\s-][^\s]*)?', code)
                if units and ' '.join(units) == ' '.join(code.split()):
                    for unit in units:
                        if not PREFERENCE_ARGS.match(unit.split()[0]) and \
                                not re.search(r'\.(cfg|ini|txt|lua|json)$', unit, re.I):
                            args.append(unit)
        for tok in re.findall(r'\b((?:ROSETTA_ADVERTISE_AVX|MVK_[A-Z0-9_]+)=\w+)', text):
            env.append(tok)
    return list(dict.fromkeys(args)), list(dict.fromkeys(env))


def main():
    cache = sys.argv[1]
    note = sys.argv[2] if len(sys.argv) > 2 else ''
    pages = []
    for fn in sorted(glob.glob(os.path.join(cache, 'pages-*.json'))):
        with open(fn, encoding='utf-8') as f:
            pages += json.load(f)
    rules = Rules()
    backends = {}
    stats = {'pages': 0, 'steam': 0, 'backend': 0, 'args': 0, 'env': 0}
    for page in pages:
        revs = page.get('revisions')
        if not revs:
            continue
        text = revs[0]['slots']['main']['content']
        stats['pages'] += 1
        ids = re.findall(r'\d+', param(text, 'steam appid').split('\n')[0])
        # other editions; many pages carry a placeholder 10 there
        ids += [i for i in re.findall(r'\d+', param(text, 'steam appid side').split('\n')[0]) if int(i) >= 1000]
        ids = list(dict.fromkeys(ids))
        if not ids:
            continue
        stats['steam'] += 1
        keys = ['steam:' + i for i in ids]
        rules.title(ids[0], page['title'])
        m = re.search(r'\{\{Compatibility/macOS(.*?)\n\}\}', text, re.S)
        block = m.group(1) if m else ''
        rating = param(block, 'crossover').lower().replace('’', "'")
        notes = param(block, 'crossover notes')
        wine_notes = param(block, 'wine notes')
        sections = wine_sections(text)
        reports = [strip_markup(notes), strip_markup(wine_notes)] + refdevice_fields(notes) + \
            refdevice_fields(wine_notes) + [strip_markup(s) for s in sections]
        summary = strip_markup(notes)[:220]
        for key in keys:
            if rating and rating not in ('na', 'unknown'):
                rules.note(key, f'AppleGamingWiki: CrossOver {rating}' + (f' – {summary}' if summary else ''))
        if rating in GOOD_RATINGS:
            score, negative = score_backends(reports)
            ranked = sorted(score.items(), key=lambda kv: -kv[1])
            if ranked and ranked[0][1] >= 1 and ranked[0][0] not in negative and \
                    (len(ranked) == 1 or ranked[1][1] < ranked[0][1]):
                stats['backend'] += 1
                for key in keys:
                    backends.setdefault(key, set()).add(ranked[0][0])
            elif score:
                for key in keys:
                    rules.note(key, 'AppleGamingWiki mentions backends without a clear recommendation: ' +
                               ', '.join(f'{b} {s:+d}' for b, s in ranked))
        args, env = launch_options(sections + [notes, wine_notes])
        if args:
            # found near "launch option" in free text; often installer flags or old tips, so only a note
            stats['args'] += 1
            for key in keys:
                rules.note(key, 'AppleGamingWiki mentions launch options: ' + ' '.join(args))
        for e in env:
            stats['env'] += 1
            for key in keys:
                rules.add(key, 'env=' + e)
    for key, found in backends.items():
        if len(found) == 1:
            rules.add(key, 'backend=' + found.pop())
        else:
            rules.note(key, 'AppleGamingWiki: pages recommend different backends: ' + ', '.join(sorted(found)))
    out = rules.write('applegamingwiki', [
        'Freequay: rules from AppleGamingWiki (applegamingwiki.com), pages with a macOS compatibility table,',
        f'as of {note}. License CC BY-NC-SA 3.0 (attribution, non-commercial, share alike); this file and the',
        'applegamingwiki rows of notes.tsv are under the same license. A backend only when the reports for a game that',
        'runs recommend exactly one and none reports problems with it; variables only from sections about CrossOver and',
        'Wine. Generated by scripts/compat/applegamingwiki.py, do not edit by hand.',
    ])
    print(f'{out}: {stats["pages"]} pages, {stats["steam"]} with a Steam ID; rules: {stats["backend"]} backend, '
          f'{stats["args"]} launch options, {stats["env"]} variables')


if __name__ == '__main__':
    main()
