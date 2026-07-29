// Board state (pure data, no rendering) plus board->world geometry helpers.
// Lane spaces are indexed 0-6 from player A's side to player B's; index 3 is the
// shared treasure space. Player A's home sits at negative y, B's at positive y.

#macro TILE_W 90   // landscape card aspect, so card graphics can BE the tile
#macro TILE_H 64
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
    return _boardState;
}

/// World-space centre of a lane space. Index 3 (treasure) sits at y = 0.
function board_space_xy(_boardState, _laneIdx, _spaceIdx) {
    var _pitch = TILE_H + TILE_GAP;
    var _lanePitch = TILE_W + LANE_GAP;
    var _worldX = (_laneIdx - (_boardState.laneCount - 1) * 0.5) * _lanePitch;
    var _worldY = (_spaceIdx - 3) * _pitch;
    return [_worldX, _worldY];
}

/// y coordinate of a player's HOME strip (player 0 = A/near side, 1 = B/far side).
function board_home_y(_playerIdx) {
    var _pitch = TILE_H + TILE_GAP;
    return (_playerIdx == 0) ? -4 * _pitch : 4 * _pitch;
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
function board_gather_types(_boardDef) {
    var _defs = global.gatherData.gather;
    var _key = string(_boardDef.setNumber);
    var _out = [];
    for (var _i = 0; _i < array_length(_defs); _i++) {
        var _sc = _defs[_i].setsCopies;
        if (variable_struct_exists(_sc, _key) && _sc[$ _key] > 0) array_push(_out, _defs[_i].id);
    }
    return _out;
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
function board_build_tile_vb(_boardState) {
    var _vb = vertex_create_buffer();
    vertex_begin(_vb, vformat_3d());
    var _stripW  = _boardState.laneCount * (TILE_W + LANE_GAP);
    var _homeCol = make_color_rgb(222, 205, 160);
    vb_tile(_vb, 0, board_home_y(0), 0.5, _stripW, TILE_H, merge_color(_homeCol, player_tint(0), 0.35));
    vb_tile(_vb, 0, board_home_y(1), 0.5, _stripW, TILE_H, merge_color(_homeCol, player_tint(1), 0.35));
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
            if (_space.kind != "enemy" || _space.enemy != undefined) continue;
            while (array_length(_deck) > 0) {
                var _enemyId = array_pop(_deck);
                var _enemyDef = enemy_def_get(_enemyId);
                if (_enemyDef.boss) continue;
                _space.enemy = { enemyDefId: _enemyId, curHp: _enemyDef.hp };
                break;
            }
        }
    }
}
