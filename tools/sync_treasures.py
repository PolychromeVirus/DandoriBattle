#!/usr/bin/env python3
"""Append the treasures missing from datafiles/data/treasures.json using the .xlsx "Treasure" sheet.

treasures.json was generated with only the base numeric sets (1-7, 350 treasures). The sheet has 494 -
the extra 144 are the shared POWER cards (sets ALL1/ALL2, effectType Good/Bad, 50) and the ADVENTURE
series (sets A1/A2/A3, 94). This script adds ONLY the missing ones (idempotent), preserving every
existing entry byte-for-byte. The on-bank power itself is `effectType` (Good/Bad) + `effectName` +
`effect` (the effect sentence) - wired in-engine separately (game_finalize_departing).

Sheet cols: B Name, C alias(=id), D set, E Value ("0150"), F Description, G EffectType, H EffectName,
I Effect, J Weight. sprite = id with '-'->'_' (GameMaker asset names can't contain hyphens).
"""
import json, os, openpyxl

XLSX = os.path.join(os.path.dirname(__file__), '..', 'PikminCardReference.xlsx')
JSON = os.path.join(os.path.dirname(__file__), '..', 'datafiles', 'data', 'treasures.json')

def as_int(v):
    if v is None or str(v).strip() == '': return 0
    return int(float(str(v).strip()))

# the existing file is ASCII-only; keep appended text ASCII too (map common smart punctuation, drop
# any stray replacement chars) so the data file stays encoding-safe for GameMaker's JSON loader.
_SMART = {'’': "'", '‘': "'", '“': '"', '”': '"', '–': '-', '—': '-',
          '…': '...', 'é': 'e', '�': '', ' ': ' '}
def ascii_clean(s):
    s = str(s or '')
    for k, v in _SMART.items():
        s = s.replace(k, v)
    return s.encode('ascii', 'ignore').decode('ascii').strip()

def as_set(v):
    """Numeric sets stay ints (base boards match by int treasureSet); ALL*/A* stay strings."""
    s = str(v).strip()
    try:
        return int(float(s))
    except ValueError:
        return s

def main():
    doc = json.load(open(JSON, encoding='utf-8'))
    treasures = doc['treasures']
    have = {t['id'] for t in treasures}

    wb = openpyxl.load_workbook(XLSX, data_only=True)
    ws = wb['Treasure']
    added = 0
    by_type = {}
    for r in range(2, ws.max_row + 1):
        alias = ws.cell(r, 3).value
        if not alias or not str(alias).strip():
            continue
        aid = str(alias).strip()
        if aid in have:
            continue                      # already present - never touch existing entries
        name = ws.cell(r, 2).value
        if not name:                      # skip blank rows
            continue
        et  = ws.cell(r, 7).value or ''
        entry = {
            'id': aid,
            'name': ascii_clean(name),
            'sprite': aid.replace('-', '_'),
            'copies': 1,
            'set': as_set(ws.cell(r, 4).value),
            'value': as_int(ws.cell(r, 5).value),
            'weight': as_int(ws.cell(r, 10).value),
            'effectType': ascii_clean(et),
            'effectName': ascii_clean(ws.cell(r, 8).value),
            'effect': ascii_clean(ws.cell(r, 9).value),
            'description': ascii_clean(ws.cell(r, 6).value),
        }
        treasures.append(entry)
        have.add(aid)
        added += 1
        by_type[str(et).strip()] = by_type.get(str(et).strip(), 0) + 1

    # ensure_ascii=True reproduces the existing entries byte-for-byte (the file stores non-ascii as
    # \uXXXX escapes); appended text is already ascii via ascii_clean, so nothing new gets escaped.
    with open(JSON, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=2, ensure_ascii=True)
    print(f'appended {added} treasures (total now {len(treasures)}). by effectType: {by_type}')

if __name__ == '__main__':
    main()
