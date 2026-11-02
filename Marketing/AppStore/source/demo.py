"""Writes the demo workspace the shots start from (Studio, Client, Personal), which state.py
then puts in each shot: a fresh simulator has none. The iPad's Studio also has Lanes, as its
tab row shows. Usage: python3 demo.py <container> iphone|ipad"""
import json, os, shutil, sys, time, uuid
C, kind = sys.argv[1], sys.argv[2]
base = 813773645.0  # seconds since 2001, like the app's own `shown`
n = [0]
def tab(url, title='', pinned=False):
    n[0] += 1
    t = {'id': str(uuid.uuid4()).upper(), 'title': title, 'url': url, 'shown': base + n[0]}
    if pinned: t['pinned'] = url
    return t
def mark(title, url):
    return {'id': str(uuid.uuid4()).upper(), 'title': title, 'url': url}
P = ':8765/'
studio_tabs = [tab('http://mail.localhost' + P + 'mail.html', pinned=True),
               tab('http://week.localhost' + P + 'week.html', pinned=True),
               tab('http://localhost' + P + 'canvas.html'),
               tab('http://127.0.0.1' + P + 'notes.html')]
if kind == 'ipad':
    studio_tabs.append(tab('http://board.localhost' + P + 'board.html'))
client_tabs = [tab('http://mail.localhost' + P + 'mail.html', pinned=True),
               tab('http://board.localhost' + P + 'board.html?dark'),
               tab('http://notes.localhost' + P + 'notes.html'),
               tab('http://canvas.localhost' + P + 'canvas.html')]
home_tabs = [{'id': str(uuid.uuid4()).upper(), 'title': '', 'shown': base}]
# The grid the start page shows: the demo pages, then sites that are only their icons (site/icons.mjs).
bookmarks = [mark('Forma', 'http://localhost' + P + 'canvas.html'), mark('Margin', 'http://127.0.0.1' + P + 'notes.html'),
             mark('Lanes', 'http://board.localhost' + P + 'board.html'), mark('Post', 'http://mail.localhost' + P + 'mail.html'),
             mark('Week', 'http://week.localhost' + P + 'week.html')]
bookmarks += [mark(name, 'http://' + name.lower() + '.localhost' + P) for name in
              ('Palette', 'Type', 'Atlas', 'Sound', 'Kiln', 'Pixel', 'North', 'Loop', 'Ledger', 'Orbit', 'Grain', 'Tide', 'Prism', 'Fold', 'Spark', 'Chord')]
def space(name, symbol, color, tabs, marks=()):
    return {'id': str(uuid.uuid4()).upper(), 'name': name, 'symbol': symbol, 'color': color, 'tabs': tabs,
            'selected': tabs[2 if len(tabs) > 2 else 0]['id'], 'bookmarks': list(marks), 'splits': []}
w = {'spaces': [space('Studio', 'paintpalette', 'teal', studio_tabs, bookmarks),
                space('Client', 'briefcase', 'orange', client_tabs),
                space('Personal', 'house', 'indigo', home_tabs)], 'closed': []}
d = os.path.join(C, 'Library/Application Support/Safience'); os.makedirs(d, exist_ok=True)
json.dump(w, open(os.path.join(d, 'workspace.json'), 'w'))
# The start page's icons: the app takes a site's icon only from its cache or from a page it has
# loaded, and the grid's sites are only their icons, so they go in the cache (Shared/SiteIcons.swift:
# Library/Caches/Safience/Icons/<host>.png). site/icons/ is named by host already.
icons = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'site', 'icons')
cache = os.path.join(C, 'Library/Caches/Safience/Icons'); os.makedirs(cache, exist_ok=True)
for name in os.listdir(icons):
    if name.endswith('.png'):
        shutil.copy(os.path.join(icons, name), os.path.join(cache, name))
print('demo workspace', kind, [(s['name'], len(s['tabs'])) for s in w['spaces']])
