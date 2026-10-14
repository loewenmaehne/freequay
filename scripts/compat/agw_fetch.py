#!/usr/bin/env python3
"""Freequay: downloads the wikitext of all AppleGamingWiki pages with a macOS compatibility table.

Uses the public MediaWiki API, 50 pages per request and one request per second, and keeps the
answers in <cache dir>/pages-NNN.json. AppleGamingWiki content: CC BY-NC-SA 3.0.

Usage: agw_fetch.py <cache dir>
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = 'https://www.applegamingwiki.com/w/api.php'
AGENT = 'freequay-compat/1.0 (+https://github.com/loewenmaehne/freequay; non-commercial; one request per second)'


def get(params):
    params = dict(params, format='json', formatversion='2')
    req = urllib.request.Request(API + '?' + urllib.parse.urlencode(params), headers={'User-Agent': AGENT})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
            time.sleep(1)
            return data
        except Exception as e:  # network hiccup: wait and retry
            print('  retry', attempt + 1, e, file=sys.stderr)
            time.sleep(10 * (attempt + 1))
    raise SystemExit('API not reachable')


def main():
    cache = sys.argv[1]
    os.makedirs(cache, exist_ok=True)
    titles, cont = [], {}
    while True:
        data = get(dict({'action': 'query', 'list': 'embeddedin', 'eititle': 'Template:Compatibility/macOS',
                         'einamespace': '0', 'eilimit': '500'}, **cont))
        titles += [p['title'] for p in data['query']['embeddedin']]
        if 'continue' not in data:
            break
        cont = {'eicontinue': data['continue']['eicontinue']}
    print(len(titles), 'pages')
    with open(os.path.join(cache, 'titles.json'), 'w') as f:
        json.dump(titles, f)
    for i in range(0, len(titles), 50):
        out = os.path.join(cache, f'pages-{i // 50:03d}.json')
        if os.path.exists(out):
            continue
        data = get({'action': 'query', 'prop': 'revisions', 'rvprop': 'content|timestamp', 'rvslots': 'main',
                    'titles': '|'.join(titles[i:i + 50])})
        with open(out, 'w') as f:
            json.dump(data['query']['pages'], f)
        print(f'{min(i + 50, len(titles))}/{len(titles)}', flush=True)


if __name__ == '__main__':
    main()
