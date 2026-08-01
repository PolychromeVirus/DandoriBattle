#!/usr/bin/env python3
"""Extract the Adventure (Campaign) boards from PikminCardReference.xlsx -> adventure.json.

The 'Campaign Maps' sheet encodes each board as a 5-column x 7-row grid of CELL FILL COLORS
(the row-2 legend maps colour -> space type), with text overlays for structures, enemy/boss
names, and the starting pikmin kit. Boards are grouped into Adventure Scenarios (chapters).

Grid geometry (validated against boards.json via the 'Board Layouts' sheet, same colour scheme):
  - A board label 'ADVx.y' sits at (label_row, label_col); the '(players)' note is one col left.
  - The 5 lane columns are label_col-1 .. label_col+3.
  - The 7 space rows are label_row+1, +3, +5, ... +13 (every other row); pikmin kit at label_row+15.
  - The treasure row is label_row+1 (top / FAR end). Home is at the bottom, so we read the grid
    BOTTOM-UP: idx 0 = nearest home (bottom row), idx 6 = far/treasure (top row). This makes the
    board HOME-ANCHORED (one home, treasure at the far end) - exactly the adventure layout.

Output: datafiles/data/adventure.json  { scenarios: [ { name, timed, boards: [ {id,label,players,
  homeAnchored:true, basicColors, kit, lanes:[[{kind,hazard?}...]x7]x5, structures:[], enemies:[],
  unmapped:[] } ] } ] }
"""
import json, re, os, openpyxl
from openpyxl.utils import get_column_letter

XLSX = os.path.join(os.path.dirname(__file__), '..', 'PikminCardReference.xlsx')
OUT  = os.path.join(os.path.dirname(__file__), '..', 'datafiles', 'data', 'adventure.json')

# colour (ARGB) -> space kind. Both sheets' shades are covered.
COLOR_KIND = {
    'FFB6D7A8': ('plain', None),  'FFB7B7B7': ('enemy', None),
    'FFFF0000': ('hazard', 'fire'), 'FF0000FF': ('hazard', 'water'), 'FF3D85C6': ('hazard', 'water'),
    'FFFCE5CD': ('hazard', 'height'), 'FF00FFFF': ('hazard', 'ice'),
    'FF9900FF': ('hazard', 'poison'), 'FF8E7CC3': ('hazard', 'poison'),
    'FFB45F06': ('hazard', 'chasm'), 'FFFFFF00': ('treasure', None),
}
# overlay structure text -> game structure id (hazards.json). NET TRAP has no game analog yet.
STRUCT = {
    'WALL': 'wall', 'BRIDGE': 'bridge', 'CLIMBING STICK': 'climbingstick', 'CLIMB. STICK': 'climbingstick',
    'TUNNEL': 'tunnel', 'CRYSTAL WALL': 'crystalwall', 'ELECTRIC WALL': 'electricwall',
    'ICE WALL': 'icewall', 'WEBBED WALL': 'arachnodeweb', 'FIRE GEYSER': 'firegeyser',
    'WATER SPOUT': 'waterspout', 'WATER GEYSER': 'waterspout', 'ICE VENT': 'icevent',
    'POISON EMITTER': 'poisonemitter', 'ELECTRICITY GENERATOR': 'electricitygenerator',
    'ELECRICITY GENERATOR': 'electricitygenerator', 'ELECTRICITY GEN.': 'electricitygenerator',
}
PIKMIN = {'RED','BLUE','YELLOW','PURPLE','WHITE','ROCK','WINGED','ICE'}

def load_enemy_ids():
    d = json.load(open(os.path.join(os.path.dirname(__file__), '..', 'datafiles', 'data', 'enemies.json')))
    # map a normalized (letters-only) key -> the real id, so hyphenated ids (bug-eyedcrawmad,
    # man-at-legs) still match a spaced/hyphenated overlay name.
    return {re.sub(r'[^a-z]', '', e['id'].lower()): e['id'] for e in d['enemies']}
ENEMY_IDS = load_enemy_ids()

def enemy_id(text):
    """UPPER SPACED name -> the game's enemy id (matches enemies.json for most). Returns id or None."""
    return ENEMY_IDS.get(re.sub(r'[^a-z]', '', text.lower()))

def cell_kind(ws, r, c):
    col = ws.cell(r, c).fill.fgColor
    argb = col.rgb if (col is not None and col.type == 'rgb') else None
    return COLOR_KIND.get(argb)  # (kind, hazard) or None

def extract():
    wbv = openpyxl.load_workbook(XLSX, data_only=True)   # values
    wbs = openpyxl.load_workbook(XLSX, data_only=False)  # fills
    wv, wf = wbv['Campaign Maps'], wbs['Campaign Maps']

    # locate scenario headers and board labels
    scen_rows = []       # (row, name, timed)
    boards = []          # (label, label_row, label_col, players)
    for r in range(1, wv.max_row + 1):
        for c in range(1, wv.max_column + 1):
            v = wv.cell(r, c).value
            if not isinstance(v, str):
                continue
            if 'Adventure Scenario' in v:
                nm = re.sub(r'^Adventure Scenario \d+:\s*', '', v).strip()
                timed = 'TIME' in v.upper()
                nm = re.sub(r'\s*\(TIME[^)]*\)', '', nm, flags=re.I).strip()
                scen_rows.append((r, nm, timed))
            elif re.match(r'^ADV\d', v.strip()):
                boards.append((v.strip(), r, c, wv.cell(r, c - 1).value))

    scen_rows.sort()
    def scenario_for(row):
        pick = None
        for (sr, nm, timed) in scen_rows:
            if sr <= row:
                pick = (nm, timed)
        return pick or ('Adventure', False)

    scenarios = {}  # name -> {name,timed,boards:[]}
    for (label, lr, lc, players) in boards:
        sname, timed = scenario_for(lr)
        cols = [lc - 1 + i for i in range(5)]            # 5 lane columns
        grid_rows = [lr + 1 + 2 * i for i in range(7)]   # 7 space rows, top(far)..bottom(home)
        kit_row = lr + 15

        lanes, structures, enemies, unmapped = [], [], [], []
        for li, col in enumerate(cols):
            spaces = []
            # bottom-up: idx 0 = home (bottom grid row) .. idx 6 = far/treasure (top)
            for idx, grow in enumerate(reversed(grid_rows)):
                ck = cell_kind(wf, grow, col)
                kind, hazard = ck if ck else ('plain', None)
                sp = {'kind': kind}
                if hazard:
                    sp['hazard'] = hazard
                spaces.append(sp)
                # overlay text on this cell
                tv = wv.cell(grow, col).value
                if isinstance(tv, str) and tv.strip():
                    t = tv.strip().upper()
                    if t in STRUCT:
                        structures.append({'lane': li, 'idx': idx, 'structId': STRUCT[t]})
                    elif t in ('NO TREASURE HERE',):
                        sp['kind'] = 'plain'  # a treasure-coloured space with no treasure
                    else:
                        eid = enemy_id(t)
                        if eid:
                            enemies.append({'lane': li, 'idx': idx, 'enemyDefId': eid})
                        else:
                            unmapped.append({'lane': li, 'idx': idx, 'text': tv.strip()})
            lanes.append({'name': f'Lane {li + 1}', 'spaces': spaces})  # match boards.json lane shape

        # pikmin kit (colour words on the kit row, across the lane columns)
        kit = []
        for col in cols:
            kv = wv.cell(kit_row, col).value
            if isinstance(kv, str) and kv.strip().upper() in PIKMIN:
                k = kv.strip().lower()
                if k not in kit:
                    kit.append(k)
        basics = [k for k in kit if k in ('red', 'blue', 'yellow')] or ['red', 'blue', 'yellow']

        bid = 'adv' + label.replace('ADV', '').replace('.', '_')
        board = {
            'id': bid, 'label': label, 'players': str(players or ''),
            'homeAnchored': True, 'basicColors': basics, 'kit': kit or ['red', 'blue', 'yellow'],
            'lanes': lanes,
            # placedStructures / placedEnemies = fixtures ALREADY on the board (distinct from a board
            # def's `structures` = the BUILDABLE set the game adds separately). enemies on a treasure
            # space are bosses; on an enemy space, regular enemies.
            'placedStructures': structures, 'placedEnemies': enemies, 'unmapped': unmapped,
        }
        scenarios.setdefault(sname, {'name': sname, 'timed': timed, 'boards': []})
        scenarios[sname]['boards'].append(board)

    return {'_comment': 'Adventure boards extracted from PikminCardReference.xlsx "Campaign Maps" '
                        'by tools/extract_adventure.py. Home-anchored: treasure at the far end (idx 6), '
                        'home near (idx 0). unmapped[] = overlay text with no game id yet.',
            'scenarios': list(scenarios.values())}

if __name__ == '__main__':
    data = extract()
    with open(OUT, 'w') as f:
        json.dump(data, f, indent=1)
    ns = len(data['scenarios'])
    nb = sum(len(s['boards']) for s in data['scenarios'])
    print(f'wrote {OUT}: {ns} scenarios, {nb} boards')
    for s in data['scenarios']:
        print(f"  {s['name']!r} (timed={s['timed']}): {[b['label'] for b in s['boards']]}")
