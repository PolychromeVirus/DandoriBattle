"""Extract per-board day trackers from PikminCardReference.xlsx -> datafiles/data/daytracks.json.

The "Board Layouts" sheet lays boards out in difficulty bands (rows 6,20,34,48,62,76),
three boards per band at columns 1, 8, 15. Within each band the two day-track rows sit at
bandRow+11 (the 3-day / 5-space track) and bandRow+12 (the 2-day / 7-space track). Each cell
is an event token; a two-line "FROM\nTO" cell is a tile swap. Output is keyed by set number.
"""
import json, os, openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
XLSX = os.path.join(HERE, "..", "PikminCardReference.xlsx")
OUT  = os.path.join(HERE, "..", "datafiles", "data", "daytracks.json")

BANDS  = [6, 20, 34, 48, 62, 76, 90]
SETS   = [[1], [2, 3, 4], [5, 6, 7], [8, 9, 10], [11, 12, 13], [14, 15, 16], [17]]
COLS   = [1, 8, 15]
# Disco Dancefloor (set 15) is the one board whose swaps convert EVERY matching tile.
ALL_SWAP_SETS = {15}

def parse_cell(v, set_no):
    if v is None:
        return {"ev": "none"}
    s = str(v).strip()
    if s == "" or s.lower() == "regular turn":
        return {"ev": "none"}
    up = s.upper()
    if up == "SPAWN":   return {"ev": "spawn"}
    if up == "ROLL":    return {"ev": "roll"}
    if up == "DRAW":    return {"ev": "draw"}
    if up == "RAW":     return {"ev": "raw"}
    if up == "PELLET":  return {"ev": "pellet"}
    if up == "FLARLIC": return {"ev": "flarlic"}
    if up == "STORM":   return {"ev": "storm"}
    if up.startswith("POD"):
        n = "".join(ch for ch in up if ch.isdigit())
        return {"ev": "pod", "n": int(n) if n else 1}
    # two-line "FROM\nTO" swap cell
    parts = [p.strip().lower() for p in s.replace("\r", "\n").split("\n") if p.strip()]
    if len(parts) == 2:
        ev = {"ev": "swap", "from": parts[0], "to": parts[1]}
        if set_no in ALL_SWAP_SETS:
            ev["all"] = True
        return ev
    raise ValueError("Unrecognised day-track cell: %r (set %s)" % (s, set_no))

def main():
    wb = openpyxl.load_workbook(XLSX, data_only=True, read_only=True)
    rows = list(wb["Board Layouts"].iter_rows(values_only=True))
    tracks = {}
    for bi, br in enumerate(BANDS):
        r3, r2 = rows[br + 11], rows[br + 12]
        for k, cs in enumerate(COLS):
            if k >= len(SETS[bi]):
                continue
            sn = SETS[bi][k]
            three = [parse_cell(r3[cs + o] if cs + o < len(r3) else None, sn) for o in range(5)]
            two   = [parse_cell(r2[cs + o] if cs + o < len(r2) else None, sn) for o in range(7)]
            tracks[str(sn)] = {"threeDay": three, "twoDay": two}
    out = {
        "_comment": "Per-board day trackers, keyed by set number. threeDay = 5-space/3-day, "
                    "twoDay = 7-space/2-day. Extracted from PikminCardReference.xlsx 'Board Layouts' "
                    "by tools/extract_daytracks.py. Event `ev`: spawn/roll/draw/raw/pellet/flarlic/"
                    "storm/none, pod{n}, swap{from,to,all?}.",
        "tracks": tracks,
    }
    with open(OUT, "w") as f:
        json.dump(out, f, indent=2)
    print("wrote", OUT, "-", len(tracks), "boards")

if __name__ == "__main__":
    main()
