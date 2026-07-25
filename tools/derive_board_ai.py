#!/usr/bin/env python3
"""
derive_board_ai.py — read sim_bench.txt tournament results and emit a per-board
difficulty->brain mapping (easy / medium / hard), picking the brain best suited
to each board by HEAD-TO-HEAD standing (not the skew-prone pooled winrate).

Run after an F12 (all-boards) tournament. Uses the LATEST run for each board.

    python tools/derive_board_ai.py

Writes board_ai_difficulty.json next to the game data and prints a table.
"""
import re, json, os, sys

BENCH = os.environ.get("SIM_BENCH",
    os.path.expandvars(r"%LOCALAPPDATA%\DandoriBattle\sim_bench.txt"))
OUT = os.path.join(os.path.dirname(__file__), "..", "datafiles", "data",
                   "board_ai_difficulty.json")

# normalize legacy nicknames -> brain version labels (older logs used ids, newer use versions)
LABEL = {"base": "v2", "cascade": "v3", "cascade2": "v3b"}
def norm(b):
    return LABEL.get(b, b)


def parse(path):
    """board -> list of (order, column_brains, matrix[row][col]=winsP1) in file order."""
    text = open(path, encoding="utf-8", errors="replace").read()
    blocks = re.split(r"#{4,}\s*TOURNAMENT", text)
    out = {}
    for i, blk in enumerate(blocks[1:]):
        m = re.match(r"\s+board\s+(\S+)", blk)
        if not m:
            continue
        board = m.group(1)
        mi = blk.find("WIN MATRIX")
        if mi < 0:
            continue
        # The sim prints the matrix in FIXED-WIDTH columns (label col + N value cols, all the
        # same width). An 8-char name like "cascade2" fills its field with no trailing space, so
        # split() merges neighbours - parse by fixed width instead (the boundaries are clean).
        lines = blk[mi:].splitlines()
        if len(lines) < 3:
            continue
        hdr = lines[1]
        w = len(hdr) - len(hdr.lstrip())                # label column width == field width
        if w <= 0:
            w = 8
        cols, k = [], w
        while k < len(hdr):
            name = hdr[k:k + w].strip()
            if name:
                cols.append(name)
            k += w
        matrix = {}
        for ln in lines[2:]:
            row = ln[0:w].strip()
            if not row or row.startswith("("):
                break
            vals, k = [], w
            while k < len(ln) and len(vals) < len(cols):
                vals.append(ln[k:k + w].strip())
                k += w
            if not vals or not vals[0].lstrip("-").isdigit():
                break
            matrix[row] = {cols[j]: int(vals[j])
                           for j in range(min(len(cols), len(vals)))}
        if matrix:
            out.setdefault(board, []).append((i, cols, matrix))
    return out


def h2h_standing(brains, matrix):
    """Round-robin head-to-head wins per brain, counting BOTH seats.
    A-vs-B over 200 games = (A as P1 beats B) + (100 - B as P1 beats A)."""
    score = {}
    for a in brains:
        tot = 0
        for b in brains:
            if a == b:
                continue
            tot += matrix.get(a, {}).get(b, 0) + (100 - matrix.get(b, {}).get(a, 0))
        score[a] = tot
    return score


def tiers(ranked):
    """ranked = weakest->strongest. Map to easy/medium/hard."""
    n = len(ranked)
    if n == 0:
        return {}
    if n == 1:
        return {"easy": ranked[0], "medium": ranked[0], "hard": ranked[0]}
    if n == 2:
        return {"easy": ranked[0], "medium": ranked[0], "hard": ranked[1]}
    return {"easy": ranked[0], "medium": ranked[n // 2], "hard": ranked[-1]}


def main():
    if not os.path.exists(BENCH):
        sys.exit("sim_bench.txt not found at " + BENCH)
    runs = parse(BENCH)
    config = {}
    print(f"{'board':<26} {'easy':<9} {'medium':<9} {'hard':<9}  (h2h wins, weakest->strongest)")
    print("-" * 84)
    for board in sorted(runs):
        _, cols, matrix = runs[board][-1]                # latest run for this board
        score = h2h_standing(cols, matrix)
        ranked = [norm(b) for b in sorted(cols, key=lambda b: score[b])]   # weakest -> strongest, version labels
        nscore = {norm(b): score[b] for b in cols}
        t = tiers(ranked)
        # keep the full ladder too (for level-1..N schemes) + the raw h2h scores
        t["ranking"] = ranked
        t["h2h"] = {b: nscore[b] for b in ranked}
        config[board] = t
        sc = "  ".join(f"{b}:{nscore[b]}" for b in ranked)
        print(f"{board:<26} {t.get('easy',''):<9} {t.get('medium',''):<9} {t.get('hard',''):<9}  ({sc})")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(os.path.normpath(OUT), "w") as f:
        json.dump(config, f, indent=2)
    print("\nwrote", os.path.normpath(OUT), f"({len(config)} boards)")


if __name__ == "__main__":
    main()
