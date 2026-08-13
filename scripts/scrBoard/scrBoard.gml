// Board state (pure data, no rendering) plus board->world geometry helpers.
// Lane spaces are indexed 0-6 from player A's side to player B's; index 3 is the
// shared treasure space. Player A's home sits at negative y, B's at positive y.

#macro TILE_W 90   // landscape card aspect, so card graphics can BE the tile
#macro TILE_H 64
#macro BLOWN_SLIDE 11   // slide speed (px/frame) for pikmin SHOVED by an enemy / Oatchi Rush, and the rushed pile - keep them equal
#macro TILE_GAP 12
#macro LANE_GAP 40

function board_create(_boardDef) {
    var _boardState = {
        boardDefId: _boardDef.id,
        laneCount: array_length(_boardDef.lanes),
        lanes: [],
    };
    for (var _laneIdx = 0; _laneIdx < _boardState.laneCount; _laneIdx++) {
        var _laneDef = _boardDef.lanes[_laneIdx];
        var _laneState = { laneName: _laneDef.name, spaces: [] };
        var _spaceCount = array_length(_laneDef.spaces);
        for (var _spaceIdx = 0; _spaceIdx < _spaceCount; _spaceIdx++) {
            var _spaceDef = _laneDef.spaces[_spaceIdx];
            array_push(_laneState.spaces, {
                kind: _spaceDef.kind,
                hazard: variable_struct_exists(_spaceDef, "hazard") ? _spaceDef.hazard : "",
                enemy: undefined,     // undefined or { enemyDefId, curHp }
                structure: undefined, // undefined or { structId, curHp } (built walls/bridges/emitters)
                laneIdx: _laneIdx,
                spaceIdx: _spaceIdx,
            });
        }
        array_push(_boardState.lanes, _laneState);
    }
    // --- board geometry metadata (drives all board->world placement below) ---
    // maxSpaces = the longest lane; uniform = every lane the same length (all shipping 2-player
    // boards are). centerRow = the space index that sits at world y=0:
    //   * uniform boards CENTRE on their length (7 -> 3), preserving the legacy symmetric layout
    //     and both homes at +/-4 pitch;
    //   * irregular (adventure) boards HOME-ANCHOR at row 0 so every lane's home space lines up and
    //     long lanes simply extend further out (there is no opposing far home in solo/adventure).
    var _maxSp = 0, _minSp = 100000;
    for (var _li = 0; _li < _boardState.laneCount; _li++) {
        var _n = array_length(_boardState.lanes[_li].spaces);
        _maxSp = max(_maxSp, _n);
        _minSp = min(_minSp, _n);
    }
    _boardState.maxSpaces = _maxSp;
    _boardState.uniform   = (_minSp == _maxSp);
    // a board home-anchors if it declares homeAnchored (adventure: uniform length but ONE home, the
    // treasure at the far end) OR if its lanes are irregular. Otherwise it centres (2-player boards).
    var _homeAnchored = (variable_struct_exists(_boardDef, "homeAnchored") && _boardDef.homeAnchored) || !_boardState.uniform;
    _boardState.homeAnchored = _homeAnchored;
    _boardState.centerRow = _homeAnchored ? 0 : (_maxSp - 1) * 0.5;
    // peakRow = the index the "toward centre / uphill" test (height crossing) references. A uniform
    // 2-player board is a hill peaking at its shared centre (both homes climb toward it). A home-
    // anchored solo board is a one-way ramp: the objective is the FAR end, so the peak sits beyond
    // every lane (a large sentinel) - the whole lane is uphill when deploying, downhill retreating.
    _boardState.peakRow = _homeAnchored ? 100000 : _boardState.centerRow;
    return _boardState;
}

/// World-space centre of a lane space. centerRow sits at y = 0 (see board_create).
function board_space_xy(_boardState, _laneIdx, _spaceIdx) {
    var _pitch = TILE_H + TILE_GAP;
    var _lanePitch = TILE_W + LANE_GAP;
    var _worldX = (_laneIdx - (_boardState.laneCount - 1) * 0.5) * _lanePitch;
    var _worldY = (_spaceIdx - _boardState.centerRow) * _pitch;
    return [_worldX, _worldY];
}

/// y coordinate of a player's HOME strip (player 0 = A/near side, 1 = B/far side). Player 0's home
/// sits one row before the nearest space; player 1's one row past the farthest. Derived from the
/// board's own dimensions so short/long/irregular boards all place their homes correctly.
function board_home_y(_boardState, _playerIdx) {
    var _pitch = TILE_H + TILE_GAP;
    var _c = _boardState.centerRow;
    return (_playerIdx == 0) ? (-_c - 1) * _pitch : (_boardState.maxSpaces - _c) * _pitch;
}

/// World-Y extent of the board including the home strip(s). Solo boards have no far home, so the
/// far edge is the longest lane's last row. Used to frame the camera + set pan limits.
function board_bounds_y(_boardState, _solo = false) {
    var _pitch = TILE_H + TILE_GAP;
    var _minY = board_home_y(_boardState, 0);
    var _maxY = _solo ? (_boardState.maxSpaces - 1 - _boardState.centerRow) * _pitch
                      : board_home_y(_boardState, 1);
    return { minY: _minY - TILE_H * 0.5, maxY: _maxY + TILE_H * 0.5 };
}

/// Checkerboard ground colours themed per board set (2 = checker pair; board 15's
/// disco floor returns 4 colours arranged as a repeating 2x2 block).
function board_ground_palette(_setNumber) {
    switch (_setNumber) {
        case 2:  return [make_color_rgb(126, 126, 130), make_color_rgb(140, 140, 144)]; // stone
        case 3:  return [make_color_rgb(78, 76, 82),    make_color_rgb(90, 88, 94)];    // dark stone
        case 4:  return [make_color_rgb(165, 180, 198), make_color_rgb(180, 194, 212)]; // icy water / darker snow
        case 5:  return [make_color_rgb(84, 128, 168),  make_color_rgb(96, 142, 182)];  // water
        case 6:  return [make_color_rgb(142, 74, 50),   make_color_rgb(158, 86, 58)];   // fire
        case 7:  return [make_color_rgb(214, 222, 236), make_color_rgb(228, 234, 246)]; // snow (blue-tinted white)
        case 8:  return [make_color_rgb(138, 178, 88),  make_color_rgb(152, 190, 98)];  // light yellow-green grass
        case 9:
        case 13: return [make_color_rgb(186, 144, 90),  make_color_rgb(200, 158, 102)]; // indoor golden wood
        case 10: return [make_color_rgb(66, 40, 38),    make_color_rgb(84, 48, 44)];    // bomb-scorched black/red
        case 11: return [make_color_rgb(56, 108, 60),   make_color_rgb(66, 120, 70)];   // dark forest green
        case 12: return [make_color_rgb(204, 178, 128), make_color_rgb(216, 190, 140)]; // sand
        case 14: return [make_color_rgb(38, 82, 76),    make_color_rgb(46, 94, 86)];    // night forest (blue-green)
        case 15: return [make_color_rgb(198, 72, 158),  make_color_rgb(74, 158, 206),   // disco!
                         make_color_rgb(226, 196, 84),  make_color_rgb(138, 84, 198)];
        case 16: return [make_color_rgb(150, 188, 150), make_color_rgb(164, 200, 162)]; // pale green
        case 17: return [make_color_rgb(112, 124, 138), make_color_rgb(140, 152, 166)]; // steel (Beat Processing Zone - brushed blue-grey metal)
        default: return [make_color_rgb(96, 150, 78),   make_color_rgb(108, 168, 88)];  // grass
    }
}

/// Build the enemy deck for a board set, honouring that set's copy counts.
/// Each board set (1-16) has its own enemy pool ("setsCopies" in enemies.json).
function enemy_deck_build(_setNumber = 1) {
    var _deck = [];
    var _defs = global.enemyData.enemies;
    var _key = string(_setNumber);
    for (var _defIdx = 0; _defIdx < array_length(_defs); _defIdx++) {
        var _sc = _defs[_defIdx].setsCopies;
        if (!variable_struct_exists(_sc, _key)) continue;
        repeat (_sc[$ _key]) array_push(_deck, _defs[_defIdx].id);
    }
    // paranoia: an unknown set falls back to the base pool
    if (array_length(_deck) == 0 && _setNumber != 1) return enemy_deck_build(1);
    return _deck;
}

/// Fisher-Yates shuffle, in place.
function deck_shuffle(_deck) {
    for (var _i = array_length(_deck) - 1; _i > 0; _i--) {
        var _j = irandom(_i);
        var _swapTmp = _deck[_i];
        _deck[_i] = _deck[_j];
        _deck[_j] = _swapTmp;
    }
}

// --- presentation helpers (stateless colour maps + tile mesh builder) ---

function board_space_color(_space) {
    switch (_space.kind) {
        case "treasure": return make_color_rgb(232, 196, 88);
        case "enemy":    return make_color_rgb(178, 106, 84);
        case "hazard":
            switch (_space.hazard) {
                case "water":    return make_color_rgb(95, 155, 225);
                case "height":   return make_color_rgb(148, 148, 156);
                case "poison":   return make_color_rgb(168, 110, 200);
                case "fire":     return make_color_rgb(235, 140, 70);
                case "electric": return make_color_rgb(240, 220, 90);
                case "ice":      return make_color_rgb(170, 225, 235);
                case "chasm":    return make_color_rgb(52, 44, 40);
                default:         return make_color_rgb(190, 120, 210);
            }
        default: return make_color_rgb(139, 199, 116); // plain
    }
}

/// Sprite for an element/hazard id, or -1 when no token sprite exists.
/// A representative colour for a hazard/emitter element (fire=red, water=blue, ...). Used to
/// tint the emitter cone so you can read what it is at a glance.
function element_color(_element) {
    switch (_element) {
        case "fire":     return make_color_rgb(235, 90, 45);
        case "water":    return make_color_rgb(70, 130, 220);
        case "electric": return make_color_rgb(240, 210, 70);
        case "ice":      return make_color_rgb(140, 220, 235);
        case "poison":   return make_color_rgb(110, 200, 70);   // the poison ICON is green, so the emitter is too
        default:         return make_color_rgb(170, 170, 178);
    }
}

function element_sprite(_element) {
    switch (_element) {
        case "fire":      return TokFire;
        case "water":     return TokWater;
        case "electric":  return TokElectric;
        case "ice":       return TokIce;
        case "crush":     return TokCrush;
        case "height":    return TokHeight;
        case "poison":    return TokPoison;
        case "swift":     return TokSwift;
        case "explosive": return TokExplosion;
        case "stab":      return TokStab;
        case "control":   return TokControl;
        case "bewilder":  return TokBewilder;
        default:          return -1;
    }
}

/// Card-decal tint for an enemy: light blue while ice-frozen (so it reads as frozen until it
/// thaws), else plain white. Bitter/shock stuns keep their own indicators; only ice tints here.
function enemy_card_tint(_enemy) {
    if (_enemy != undefined
        && variable_struct_exists(_enemy, "stunned") && _enemy.stunned > 0
        && variable_struct_exists(_enemy, "stunnedBy") && _enemy.stunnedBy == "ice")
        return make_color_rgb(150, 205, 255);
    return c_white;
}

/// Distinct terrain hazards present in a board's lanes, in a stable display order.
function board_hazards(_boardDef) {
    var _order = ["water", "fire", "ice", "poison", "height", "chasm"];
    var _seen = {};
    for (var _l = 0; _l < array_length(_boardDef.lanes); _l++) {
        var _sp = _boardDef.lanes[_l].spaces;
        for (var _s = 0; _s < array_length(_sp); _s++) {
            if (_sp[_s].kind == "hazard") _seen[$ _sp[_s].hazard] = true;
        }
    }
    var _out = [];
    for (var _i = 0; _i < array_length(_order); _i++)
        if (variable_struct_exists(_seen, _order[_i])) array_push(_out, _order[_i]);
    return _out;
}

/// Display name for a terrain hazard id.
function hazard_display_name(_h) {
    switch (_h) {
        case "water":  return "Water";
        case "fire":   return "Fire";
        case "ice":    return "Ice";
        case "poison": return "Poison";
        case "height": return "Height";
        case "chasm":  return "Chasm";
        default:       return _h;
    }
}

/// Flat list of the structure/emitter cards a board can build (emitters first, then walls,
/// then bridges) - the "hazard cards available on the map". All have CARD<id>.png art.
function board_structures(_boardDef) {
    var _st = _boardDef.structures;
    var _out = [];
    var _cats = ["emitters", "walls", "bridges"];
    for (var _c = 0; _c < array_length(_cats); _c++) {
        if (!variable_struct_exists(_st, _cats[_c])) continue;
        var _arr = _st[$ _cats[_c]];
        for (var _i = 0; _i < array_length(_arr); _i++) array_push(_out, _arr[_i]);
    }
    return _out;
}

/// Distinct gather-card TYPE ids available to a board (setsCopies keyed by board number).
/// A generated board carries its own `gatherTypes` list, so honour that when present.
function board_gather_types(_boardDef) {
    if (variable_struct_exists(_boardDef, "gatherTypes")) return _boardDef.gatherTypes;
    var _defs = global.gatherData.gather;
    var _key = string(_boardDef.setNumber);
    var _out = [];
    for (var _i = 0; _i < array_length(_defs); _i++) {
        var _sc = _defs[_i].setsCopies;
        if (variable_struct_exists(_sc, _key) && _sc[$ _key] > 0) array_push(_out, _defs[_i].id);
    }
    return _out;
}

/// The fixed TUTORIAL board DEF: compact - 3 lanes x 4 spaces, each lane gated by its own hazard
/// (space 0: water / fire / height, crossed by blue / red / yellow), an enemy space (1), an empty
/// space (2), and a treasure at the lane end (3). Consumed by scenario_tutorial().
function board_tutorial() {
    var _hazByLane = ["water", "fire", "height"];   // lane 0/1/2 -> crossed by blue/red/yellow
    var _lanes = [];
    for (var _l = 0; _l < 3; _l++) {
        var _hz = _hazByLane[_l];
        array_push(_lanes, { name: "Lane " + string(_l + 1), spaces: [
            { kind: "hazard", hazard: _hz },   // 0: hazard gates the lane (matching Pikmin only)
            { kind: "enemy" },                 // 1: enemy space - bare until day 2 spawns Bulborbs
            { kind: "plain" },                 // 2: empty space
            { kind: "treasure" },              // 3: treasure (lane end)
        ] });
    }
    var _basics = ["red", "blue", "yellow"];
    var _die = [];
    for (var _i = 0; _i < 3; _i++) { array_push(_die, { color: _basics[_i], value: 1 }); array_push(_die, { color: _basics[_i], value: 5 }); }
    return {
        id: "tutorial", name: "Tutorial", setNumber: 1, difficulty: "Tutorial",
        treasureSet: 1, basicColors: _basics, killedIfThrownOut: false,
        pelletDie: _die, structures: { bridges: ["bridge"], walls: ["wall"], emitters: [] },
        lanes: _lanes,
    };
}

/// Tutorial chapter 2 (item / double-move scene). 3 lanes, each just [plain, treasure] so the
/// treasure sits at idx 1 - exactly TWO carry-steps from banking. No hazards, no enemy spaces.
/// setNumber 3 = Underground Plateau (dark-stone / cave look). See scenario_tutorial2 (scrScenarios).
function board_tutorial2() {
    var _lanes = [];
    for (var _l = 0; _l < 3; _l++) {
        array_push(_lanes, { name: "Lane " + string(_l + 1), spaces: [
            { kind: "plain" },      // 0: the one space between the treasure and home
            { kind: "treasure" },   // 1: treasure, pre-advanced to 2 spaces from home
        ] });
    }
    var _basics = ["red", "blue", "yellow"];
    var _die = [];
    for (var _i = 0; _i < 3; _i++) { array_push(_die, { color: _basics[_i], value: 1 }); array_push(_die, { color: _basics[_i], value: 5 }); }
    return {
        id: "tutorial2", name: "Tutorial", setNumber: 3, difficulty: "Tutorial",
        treasureSet: 1, basicColors: _basics, killedIfThrownOut: false,
        pelletDie: _die, structures: { bridges: ["bridge"], walls: ["wall"], emitters: [] },
        lanes: _lanes,
    };
}

/// Tutorial chapter 3 (treasure-pile scene). Middle lane all-empty with a two-card pile at idx 0
/// (right in front of home); the two flanking lanes are all chasm with an unreachable treasure at
/// the end (context: piles live across the board, some you can't reach). setNumber 13 = Tricky
/// Staircase (golden-wood/steps look). See scenario_tutorial3 (scrScenarios).
function board_tutorial3() {
    var _lanes = [
        { name: "Lane 1", spaces: [ {kind:"hazard",hazard:"chasm"}, {kind:"hazard",hazard:"chasm"}, {kind:"hazard",hazard:"chasm"}, {kind:"treasure"} ] },
        { name: "Lane 2", spaces: [ {kind:"plain"}, {kind:"plain"}, {kind:"plain"}, {kind:"plain"} ] },  // pile placed at idx 0 by the scenario
        { name: "Lane 3", spaces: [ {kind:"hazard",hazard:"chasm"}, {kind:"hazard",hazard:"chasm"}, {kind:"hazard",hazard:"chasm"}, {kind:"treasure"} ] },
    ];
    var _basics = ["red", "blue", "yellow"];
    var _die = [];
    for (var _i = 0; _i < 3; _i++) { array_push(_die, { color: _basics[_i], value: 1 }); array_push(_die, { color: _basics[_i], value: 5 }); }
    return {
        id: "tutorial3", name: "Tutorial", setNumber: 13, difficulty: "Tutorial",
        treasureSet: 1, basicColors: _basics, killedIfThrownOut: false,
        pelletDie: _die, structures: { bridges: ["bridge"], walls: ["wall"], emitters: [] },
        lanes: _lanes,
    };
}

/// Tutorial chapter 4 (crush/rock, then chasm/winged, then swift). Frigid Wasteland (setNumber 7).
/// Lane 1 [enemy, enemy, treasure] = two Wollyhops (CRUSH: stomp non-immune pikmin even in death;
/// rock is crush-immune) guarding a weight-1 treasure. Lane 2 [chasm, enemy, treasure] = a chasm
/// only Winged can cross, then a swift 1/1 guarding another weight-1 treasure. All enemies/pikmin
/// placed by scenario_tutorial4. Only red pellets (roll is hidden anyway).
function board_tutorial4() {
    var _lanes = [
        { name: "Lane 1", spaces: [ {kind:"enemy"}, {kind:"enemy"}, {kind:"treasure"} ] },
        { name: "Lane 2", spaces: [ {kind:"hazard", hazard:"chasm"}, {kind:"enemy"}, {kind:"treasure"} ] },
    ];
    var _die = [];
    repeat (6) array_push(_die, { blank: true });   // BARREN die: no rolls grant pellets (so Wollyhop rewards give nothing)
    return {
        id: "tutorial4", name: "Tutorial", setNumber: 7, difficulty: "Tutorial",
        treasureSet: 1, basicColors: ["red"], killedIfThrownOut: false,
        pelletDie: _die, structures: { bridges: ["bridge"], walls: ["wall"], emitters: [] },
        lanes: _lanes,
    };
}

/// DEV: an IRREGULAR solo board to exercise the adventure geometry groundwork - four lanes of
/// DIFFERENT lengths (3/8/5/10), each with its treasure at the FAR end. Non-uniform => the board
/// HOME-ANCHORS (centerRow 0): every lane's home space lines up and the long lanes extend far out,
/// with only the near home strip (solo). A couple of hazards/enemies check that fixture decals still
/// face the player (no opponent to flip toward). See scenario_advtest / start_advtest.
function board_advtest() {
    var _lanes = [
        { name: "Short",   spaces: [ {kind:"plain"}, {kind:"enemy"}, {kind:"treasure"} ] },                                                        // 3
        { name: "Long",    spaces: [ {kind:"plain"}, {kind:"plain"}, {kind:"hazard",hazard:"water"}, {kind:"plain"}, {kind:"enemy"}, {kind:"plain"}, {kind:"plain"}, {kind:"treasure"} ] }, // 8
        { name: "Medium",  spaces: [ {kind:"plain"}, {kind:"hazard",hazard:"fire"}, {kind:"plain"}, {kind:"enemy"}, {kind:"treasure"} ] },          // 5
        { name: "Longest", spaces: [ {kind:"plain"}, {kind:"plain"}, {kind:"plain"}, {kind:"enemy"}, {kind:"plain"}, {kind:"hazard",hazard:"height"}, {kind:"plain"}, {kind:"plain"}, {kind:"plain"}, {kind:"treasure"} ] }, // 10
        { name: "Mid",     spaces: [ {kind:"plain"}, {kind:"plain"}, {kind:"enemy"}, {kind:"plain"}, {kind:"plain"}, {kind:"treasure"} ] },          // 6
    ];
    var _basics = ["red", "blue", "yellow"];
    var _die = [];
    for (var _i = 0; _i < 3; _i++) { array_push(_die, { color: _basics[_i], value: 1 }); array_push(_die, { color: _basics[_i], value: 5 }); }
    return {
        id: "advtest", name: "Adventure Test", setNumber: 8, difficulty: "Dev",
        treasureSet: 1, basicColors: _basics, killedIfThrownOut: false,
        pelletDie: _die, structures: { bridges: ["bridge"], walls: ["wall"], emitters: [] },
        lanes: _lanes,
    };
}

// ============================ RANDOM BOARD GENERATOR ============================

/// Re-roll the board list's "random" entry in place (same index, so the preview stays on it).
function regenerate_random_board() {
    var _boards = global.boardData.boards;
    for (var _i = 0; _i < array_length(_boards); _i++) {
        if (_boards[_i].id == "random") { _boards[_i] = board_generate_random(); return; }
    }
    array_push(_boards, board_generate_random());   // wasn't present (shouldn't happen)
}

/// Up to _k distinct random elements from _arr (partial Fisher-Yates on a copy).
function rnd_subset(_arr, _k) {
    var _n = array_length(_arr);
    var _copy = array_create(_n);
    array_copy(_copy, 0, _arr, 0, _n);
    var _take = min(_k, _n);
    for (var _i = 0; _i < _take; _i++) {
        var _j = _i + irandom(_n - 1 - _i);
        var _t = _copy[_i]; _copy[_i] = _copy[_j]; _copy[_j] = _t;
    }
    var _out = [];
    for (var _i = 0; _i < _take; _i++) array_push(_out, _copy[_i]);
    return _out;
}

/// Hazard-space count in a half-lane (array of {kind,...}).
function rndlane_haz(_lane) {
    var _c = 0;
    for (var _i = 0; _i < array_length(_lane); _i++) if (_lane[_i].kind == "hazard") _c++;
    return _c;
}

/// How many more of hazard _hz a half-lane may take: cap 2, or 3 if all its hazards are _hz.
function rndlane_room(_lane, _hz) {
    var _h = 0, _allSame = true;
    for (var _i = 0; _i < array_length(_lane); _i++) {
        if (_lane[_i].kind == "hazard") { _h++; if (_lane[_i].hazard != _hz) _allSame = false; }
    }
    return max(0, (_allSame ? 3 : 2) - _h);
}

/// Build a fresh procedural board def (id "random"). Mirror-symmetric 5x7; only places terrain
/// hazards the kit can actually cross; custom decks (gather w/ rawmaterial guaranteed, random
/// treasure subset sized like a normal deck, random enemy deck matching size + boss ratio).
function board_generate_random() {
    // --- 3 basic colours; pellet die built from them ---
    var _basics = rnd_subset(["red", "blue", "yellow", "rock", "ice", "winged"], 3);

    // --- gather pool: rawmaterial guaranteed + a random assortment of the rest ---
    var _gTypes = ["rawmaterial"];
    var _allG = global.gatherData.gather;
    for (var _i = 0; _i < array_length(_allG); _i++) {
        if (_allG[_i].id != "rawmaterial" && random(1) < 0.5) array_push(_gTypes, _allG[_i].id);
    }

    // --- accessible pikmin types (basics + candypop conversions) ---
    var _acc = [];
    for (var _i = 0; _i < array_length(_basics); _i++) array_push(_acc, _basics[_i]);
    if (arr_has(_gTypes, "candypopbud"))  { array_push(_acc, "red");  array_push(_acc, "blue"); array_push(_acc, "yellow"); }
    if (arr_has(_gTypes, "candypopbud2")) { array_push(_acc, "rock"); array_push(_acc, "ice");  array_push(_acc, "winged"); }

    // --- placeable terrain hazards (crossability rules: only poison [DOT] + height are off-colour) ---
    var _placeable = ["poison"];
    if (arr_has(_acc, "blue"))                              array_push(_placeable, "water");
    if (arr_has(_acc, "red"))                               array_push(_placeable, "fire");
    if (arr_has(_acc, "ice"))                               array_push(_placeable, "ice");
    if (arr_has(_acc, "winged"))                            array_push(_placeable, "chasm");
    if (arr_has(_acc, "yellow") || arr_has(_acc, "winged")) array_push(_placeable, "height");
    var _chosen = rnd_subset(_placeable, irandom_range(min(2, array_length(_placeable)), min(3, array_length(_placeable))));

    // --- half-grid: 5 lanes x 3 spaces, all plain ---
    var _half = [];
    for (var _l = 0; _l < 5; _l++) _half[_l] = [{kind:"plain"}, {kind:"plain"}, {kind:"plain"}];

    // --- place each chosen hazard type ---
    var _cntW = [1, 1, 1, 1, 1, 2, 2, 3]; // per-lane count weights: heavily 1, sometimes 2, rarely 3
    var _used3 = false;               // at most ONE lane on the whole board may hold 3 of a kind
    var _n2 = 0;                      // lanes that received a 2-of-a-kind (cap 3)
    for (var _c = 0; _c < array_length(_chosen); _c++) {
        var _hz = _chosen[_c];
        var _cand = [];
        for (var _l = 0; _l < 5; _l++) {
            if (rndlane_room(_half[_l], _hz) <= 0) continue;
            var _hasPlain = false;
            for (var _s = 0; _s < 3; _s++) if (_half[_l][_s].kind == "plain") _hasPlain = true;
            if (_hasPlain) array_push(_cand, _l);
        }
        if (array_length(_cand) == 0) {          // fallback: wipe fewest-hazard lane's non-hazards
            var _best = 0, _bestH = 99;
            for (var _l = 0; _l < 5; _l++) { var _h = rndlane_haz(_half[_l]); if (_h < _bestH) { _bestH = _h; _best = _l; } }
            for (var _s = 0; _s < 3; _s++) if (_half[_best][_s].kind != "hazard") _half[_best][_s] = {kind:"plain"};
            _cand = [_best];
        }
        var _lns = rnd_subset(_cand, irandom_range(min(2, array_length(_cand)), min(3, array_length(_cand))));
        for (var _li = 0; _li < array_length(_lns); _li++) {
            var _l = _lns[_li];
            var _plain = [];
            for (var _s = 0; _s < 3; _s++) if (_half[_l][_s].kind == "plain") array_push(_plain, _s);
            var _want = _cntW[irandom(array_length(_cntW) - 1)];
            if (_want >= 3 && _used3) _want = 2;   // keep 3-of-a-kind to a single lane per board
            if (_want == 2 && _n2 >= 3) _want = 1; // and no more than 3 lanes with a 2-of-a-kind
            var _put = min(_want, rndlane_room(_half[_l], _hz), array_length(_plain));
            if (_put >= 3) _used3 = true; else if (_put == 2) _n2++;
            var _slots = rnd_subset(_plain, _put);
            for (var _pi = 0; _pi < array_length(_slots); _pi++) _half[_l][_slots[_pi]] = {kind:"hazard", hazard:_hz};
        }
    }

    // --- enemies on the leftover plains (~65%), with a floor so a board is never empty ---
    var _plains = [];
    for (var _l = 0; _l < 5; _l++)
        for (var _s = 0; _s < 3; _s++)
            if (_half[_l][_s].kind == "plain") array_push(_plains, {l: _l, s: _s});
    var _eCount = 0;
    for (var _i = 0; _i < array_length(_plains); _i++)
        if (random(1) < 0.65) { _half[_plains[_i].l][_plains[_i].s] = {kind:"enemy"}; _eCount++; }
    // guarantee a handful of enemy spaces even if the roll was stingy (promote leftover plains)
    var _floor = min(4, array_length(_plains));
    if (_eCount < _floor) {
        var _left = [];
        for (var _i = 0; _i < array_length(_plains); _i++)
            if (_half[_plains[_i].l][_plains[_i].s].kind == "plain") array_push(_left, _plains[_i]);
        var _promote = rnd_subset(_left, _floor - _eCount);
        for (var _i = 0; _i < array_length(_promote); _i++) _half[_promote[_i].l][_promote[_i].s] = {kind:"enemy"};
    }

    // --- mirror into full 7-space lanes (space 3 = centre treasure) ---
    var _lanes = [];
    for (var _l = 0; _l < 5; _l++) {
        var _sp = [];
        _sp[0] = _half[_l][0]; _sp[1] = _half[_l][1]; _sp[2] = _half[_l][2];
        _sp[3] = {kind:"treasure"};
        _sp[4] = variable_clone(_half[_l][2]);
        _sp[5] = variable_clone(_half[_l][1]);
        _sp[6] = variable_clone(_half[_l][0]);
        array_push(_lanes, {name: "Lane " + string(_l + 1), spaces: _sp});
    }

    // --- structures: basic wall + bridge always, plus random extras ---
    var _walls = ["wall"];
    var _ew = rnd_subset(["arachnodeweb", "crystalwall", "electricwall", "icewall"], irandom_range(0, 3));
    for (var _i = 0; _i < array_length(_ew); _i++) array_push(_walls, _ew[_i]);
    var _bridges = ["bridge"];
    var _sb = rnd_subset(["climbingstick", "tunnel"], irandom_range(0, 2));
    for (var _i = 0; _i < array_length(_sb); _i++) array_push(_bridges, _sb[_i]);
    var _emitters = rnd_subset(["poisonemitter", "firegeyser", "waterspout", "electricitygenerator", "icevent"], irandom_range(1, 4));

    // --- decks ---
    var _gDeck = [];
    for (var _i = 0; _i < array_length(_gTypes); _i++) {
        repeat (max(1, gather_def_get(_gTypes[_i]).copies)) array_push(_gDeck, _gTypes[_i]);
    }
    var _allTIds = [];
    for (var _i = 0; _i < array_length(global.treasureData.treasures); _i++) array_push(_allTIds, global.treasureData.treasures[_i].id);
    var _tDeck = rnd_subset(_allTIds, array_length(deck_build_treasure(1)));   // same size as a normal deck
    var _eRef = enemy_deck_build(1);                                          // reference for size + boss ratio
    var _eTot = array_length(_eRef), _eBoss = 0;
    for (var _i = 0; _i < _eTot; _i++) if (enemy_def_get(_eRef[_i]).boss) _eBoss++;
    var _bossIds = [], _normIds = [];
    var _allE = global.enemyData.enemies;
    for (var _i = 0; _i < array_length(_allE); _i++) {
        if (_allE[_i].boss) array_push(_bossIds, _allE[_i].id); else array_push(_normIds, _allE[_i].id);
    }
    var _eDeck = [];
    for (var _i = 0; _i < _eBoss; _i++)         array_push(_eDeck, _bossIds[irandom(array_length(_bossIds) - 1)]);
    for (var _i = 0; _i < _eTot - _eBoss; _i++) array_push(_eDeck, _normIds[irandom(array_length(_normIds) - 1)]);

    var _die = [];
    for (var _i = 0; _i < array_length(_basics); _i++) {
        array_push(_die, {color: _basics[_i], value: 1});
        array_push(_die, {color: _basics[_i], value: 5});
    }

    return {
        id: "random",
        name: "Random Board",
        setNumber: irandom_range(1, 16),   // theme (sky + ground palette) only; decks are custom
        difficulty: "Random",
        treasureSet: 1,                    // unused - randomDecks override deck building
        basicColors: _basics,
        killedIfThrownOut: false,
        pelletDie: _die,
        structures: {bridges: _bridges, walls: _walls, emitters: _emitters},
        lanes: _lanes,
        gatherTypes: _gTypes,
        randomDecks: {gather: _gDeck, treasure: _tDeck, enemy: _eDeck},
    };
}

/// Flat board-game token sprite for a pikmin type (-1 for bulbmin, which has none).
function pikmin_token_sprite(_typeId) {
    switch (_typeId) {
        case "red":    return RedToken;
        case "blue":   return BlueToken;
        case "yellow": return YellowToken;
        case "purple": return PurpleToken;
        case "white":  return WhiteToken;
        case "rock":   return BlackToken;
        case "ice":    return CyanToken;
        case "winged": return PinkToken;
        default:       return -1; // bulbmin: no token art
    }
}

// --- team colours: player 0 (the human) is cool blue, player 1 (enemy/AI) is red ---
function player_tint(_p)   { return (_p == 0) ? make_color_rgb(56, 92, 168)  : make_color_rgb(170, 58, 44); }
function player_shadow(_p) { return (_p == 0) ? make_color_rgb(26, 44, 96)   : make_color_rgb(102, 32, 24); }
function player_marker(_p) { return (_p == 0) ? make_color_rgb(90, 150, 255) : make_color_rgb(255, 120, 60); }

/// Fallback colour for elements that have no token sprite yet.
function element_fallback_color(_element) {
    switch (_element) {
        case "poison":    return make_color_rgb(168, 90, 200);
        case "swift":     return make_color_rgb(235, 235, 235);
        case "explosive": return make_color_rgb(240, 120, 40);
        default:          return make_color_rgb(230, 60, 200);
    }
}

function pikmin_tint(_typeId) {
    switch (_typeId) {
        case "red":     return make_color_rgb(240, 96, 84);
        case "blue":    return make_color_rgb(96, 140, 240);
        case "yellow":  return make_color_rgb(245, 214, 76);
        case "purple":  return make_color_rgb(150, 100, 190);
        case "white":   return c_white;
        case "rock":    return make_color_rgb(90, 90, 100);
        case "ice":     return make_color_rgb(150, 220, 235);
        case "winged":  return make_color_rgb(240, 150, 190);
        case "bulbmin": return make_color_rgb(120, 200, 110);
        default:        return c_white;
    }
}

/// Build the frozen vertex buffer for the board tiles + both home strips.
function board_build_tile_vb(_boardState, _solo = false) {
    var _vb = vertex_create_buffer();
    vertex_begin(_vb, vformat_3d());
    var _stripW  = _boardState.laneCount * (TILE_W + LANE_GAP);
    var _homeCol = make_color_rgb(222, 205, 160);
    vb_tile(_vb, 0, board_home_y(_boardState, 0), 0.5, _stripW, TILE_H, merge_color(_homeCol, player_tint(0), 0.35));
    // solo / co-op: only one player, no opponent home strip on the far side
    if (!_solo) vb_tile(_vb, 0, board_home_y(_boardState, 1), 0.5, _stripW, TILE_H, merge_color(_homeCol, player_tint(1), 0.35));
    for (var _laneIdx = 0; _laneIdx < _boardState.laneCount; _laneIdx++) {
        var _spaces = _boardState.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _spacePos = board_space_xy(_boardState, _laneIdx, _spaceIdx);
            vb_tile(_vb, _spacePos[0], _spacePos[1], 1, TILE_W, TILE_H, board_space_color(_spaces[_spaceIdx]));
        }
    }
    vertex_end(_vb);
    vertex_freeze(_vb);
    return _vb;
}

/// Fill every empty enemy space from the deck (setup / respawn rule).
/// TODO M3: drawn bosses must go onto the highest-value treasure pile instead;
/// until the treasure deck is encoded they are set aside (redrawn).
function board_spawn_enemies(_boardState, _deck) {
    for (var _laneIdx = 0; _laneIdx < _boardState.laneCount; _laneIdx++) {
        var _spaces = _boardState.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _space = _spaces[_spaceIdx];
            // skip enemy spaces already occupied by a card (enemy or a structure/emitter on top)
            if (_space.kind != "enemy" || _space.enemy != undefined || _space.structure != undefined) continue;
            while (array_length(_deck) > 0) {
                var _enemyId = array_pop(_deck);
                var _enemyDef = enemy_def_get(_enemyId);
                if (_enemyDef.boss) continue;
                _space.enemy = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false };  // dead: matches game_spawn_enemy_at (renderer reads .dead)
                break;
            }
        }
    }
}
