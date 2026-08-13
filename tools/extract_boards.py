"""Re-import the 16+ main board SPACE LAYOUTS from PikminCardReference.xlsx into
datafiles/data/boards.json.

WHY THIS EXISTS: boards.json was originally "Extracted from the Board Layouts tab" by a
one-off script that was never saved. When the day-1 (pre-transition) layouts of the
accessibility boards got reverted, there was no way to re-import them. This is that importer.

It UPDATES ONLY each board's lane[].spaces[].kind/hazard from the sheet, keyed by setNumber,
and PRESERVES every other field (id, name, difficulty, treasureSet, basicColors, pelletDie,
structures, killedIfThrownOut, lane names, and any extra per-space keys). So it is safe to run
any time the .xlsx layouts change or an external edit gets clobbered - it re-syncs the grids
without touching the hand-maintained metadata that isn't derivable from the layout sheet.

Sheet geometry ("Board Layouts", 0-indexed rows, same scheme extract_daytracks.py uses):
  difficulty BANDS at rows [6,20,34,48,62,76,90]; 3 boards/band at column offsets [1,8,15];
  sets per band [[1],[2,3,4],[5,6,7],[8,9,10],[11,12,13],[14,15,16],[17]]. The layout grid is
  7 consecutive rows (bandRow+1..+7) x 5 lane cols (colOff..colOff+4). openpyxl (1-indexed):
  cell(row=bandRow+2+spaceIdx, column=colOff+lane+1). Space idx 0..6 top->bottom, treasure at
  idx 3 (the boards are vertically symmetric, so orientation is moot). Cells are FILL COLOURS.
"""
import json, os, openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
XLSX = os.path.join(HERE, "..", "PikminCardReference.xlsx")
OUT  = os.path.join(HERE, "..", "datafiles", "data", "boards.json")

BANDS = [6, 20, 34, 48, 62, 76, 90]
SETS  = [[1], [2, 3, 4], [5, 6, 7], [8, 9, 10], [11, 12, 13], [14, 15, 16], [17]]
COLS  = [1, 8, 15]

# ARGB fill colour -> (kind, hazard). Shared with extract_adventure.py's COLOR_KIND (both
# sheets use the same palette). Add a shade here if a new board trips "unmapped colour".
COLOR_KIND = {
    "FFB6D7A8": ("plain", ""),    "FFB7B7B7": ("enemy", ""),    "FFFFFF00": ("treasure", ""),
    "FFFF0000": ("hazard", "fire"),   "FF0000FF": ("hazard", "water"), "FF3D85C6": ("hazard", "water"),
    "FFFCE5CD": ("hazard", "height"), "FF00FFFF": ("hazard", "ice"),
    "FF9900FF": ("hazard", "poison"), "FF8E7CC3": ("hazard", "poison"), "FFB45F06": ("hazard", "chasm"),
}

def set_location(sn):
    for bi, ss in enumerate(SETS):
        if sn in ss:
            return BANDS[bi], COLS[ss.index(sn)]
    return None

def cell_kind(ws, band_row, col_off, lane, space_idx, sn):
    c = ws.cell(row=band_row + 2 + space_idx, column=col_off + lane + 1)
    f = c.fill
    rgb = getattr(f.fgColor, "rgb", None) if (f is not None and f.patternType is not None) else None
    if rgb not in COLOR_KIND:
        raise ValueError("Unmapped fill colour %r at set %s lane %d space %d" % (rgb, sn, lane, space_idx))
    return COLOR_KIND[rgb]

def main():
    wb = openpyxl.load_workbook(XLSX, data_only=True)   # NOT read_only - we need .fill styles
    ws = wb["Board Layouts"]
    raw = open(OUT, encoding="utf-8").read()
    data = json.loads(raw)

    changed = 0
    for b in data["boards"]:
        sn = b.get("setNumber")
        loc = set_location(sn)
        if loc is None:
            print("  skip set %s (%s) - no sheet location" % (sn, b.get("name")))
            continue
        band_row, col_off = loc
        for lane in range(5):
            spaces = b["lanes"][lane]["spaces"]
            for i in range(7):
                kind, hazard = cell_kind(ws, band_row, col_off, lane, i, sn)
                s = spaces[i]
                if s.get("kind") != kind or (s.get("hazard", "") or "") != hazard:
                    changed += 1
                s["kind"] = kind
                if hazard:
                    s["hazard"] = hazard
                elif "hazard" in s:
                    del s["hazard"]

    out = json.dumps(data, indent=2, ensure_ascii=False)
    if raw.endswith("\n"):
        out += "\n"
    tmp = OUT + ".tmp"                       # temp+replace: GameMaker may hold a write lock on the live file
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    os.replace(tmp, OUT)
    print("wrote", OUT, "-", changed, "spaces re-synced from the xlsx")

if __name__ == "__main__":
    main()
