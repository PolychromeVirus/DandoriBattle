// Loading and lookup for the JSON game data in datafiles/data/.
// Everything is loaded once into globals at boot by data_load_all().

/// Load and parse one included JSON file (path relative to the working directory).
function json_load_included(_path) {
    var _buf = buffer_load(_path);
    if (_buf == -1) show_error("Missing data file: " + _path, true);
    var _txt = buffer_read(_buf, buffer_text);
    buffer_delete(_buf);
    return json_parse(_txt);
}

/// Like json_load_included, but returns _fallback instead of crashing when the file is absent
/// (for GENERATED/optional data such as the board_ai_difficulty map).
function json_load_optional(_path, _fallback) {
    var _buf = buffer_load(_path);
    if (_buf == -1) return _fallback;
    var _txt = buffer_read(_buf, buffer_text);
    buffer_delete(_buf);
    return json_parse(_txt);
}

/// Resolve a difficulty tier ("easy"/"medium"/"hard") to a brain controller for a board, from the
/// data-derived board_ai_difficulty map (tools/derive_board_ai.py). Falls back to a sensible ladder
/// if the board (or the whole map) is missing.
function difficulty_brain(_boardId, _tier) {
    if (is_struct(global.boardAI) && variable_struct_exists(global.boardAI, _boardId)) {
        var _b = global.boardAI[$ _boardId];
        if (variable_struct_exists(_b, _tier)) return _b[$ _tier];
    }
    if (_tier == "hard")   return "v4";
    if (_tier == "medium") return "v3";
    return "v1";                                              // easy
}

/// Resolve a SEAT token to a concrete controller for a board: "human" stays human; a difficulty
/// tier maps through the board's config; anything else is already a brain id (sim/batch/F1).
function seat_brain(_boardId, _token) {
    if (_token == "human") return "human";
    if (_token == "easy" || _token == "medium" || _token == "hard") return difficulty_brain(_boardId, _token);
    return _token;
}

function data_load_all() {
    global.rules        = json_load_included("data/rules.json");
    global.pikminData   = json_load_included("data/pikmin.json");
    global.enemyData    = json_load_included("data/enemies.json");
    global.boardData    = json_load_included("data/boards.json");
    global.treasureData = json_load_included("data/treasures.json");
    global.gatherData   = json_load_included("data/gather.json");
    global.pelletData   = json_load_included("data/pellets.json");
    global.hazardData   = json_load_included("data/hazards.json");
    global.diceData     = json_load_included("data/dice.json");
    global.boardAI      = json_load_optional("data/board_ai_difficulty.json", {});   // per-board difficulty->brain (generated)

    // Experimental type-identity abilities (toggled on the board-select menu; off by
    // default). These are being playtested - not final rules.
    //  red    = second combat pass (reds strike again after the enemy turn)
    //  blue   = lifeguard (a group crosses water carrying <= 1 non-blue per blue)
    //  yellow = crosses chasms when heading toward the centre (throwable, one-way)
    //  rush   = a treasure carried by >= 2x its weight in power moves 2 spaces
    //  enemyHeal = survivors heal to full each sunset (harder); off = they stay hurt
    //  anims = beat pacing/settles/cinematics; OFF = instant resolution (fast games)
    //  (AI brains are picked per-seat on the menu, not here)
    global.expRules = { red: true, blue: true, yellow: true, rush: true, enemyHeal: false, anims: true };
}

/// Sprite index for a data record's "sprite" field, or _fallback when missing/unmatched.
function data_sprite(_record, _fallback) {
    if (!variable_struct_exists(_record, "sprite") || _record.sprite == "") return _fallback;
    var _sprIdx = asset_get_index(_record.sprite);
    return (_sprIdx == -1) ? _fallback : _sprIdx;
}

/// True if _arr contains _val.
function arr_has(_arr, _val) {
    for (var _i = 0; _i < array_length(_arr); _i++) {
        if (_arr[_i] == _val) return true;
    }
    return false;
}

function treasure_def_get(_treasureId) {
    var _defs = global.treasureData.treasures;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _treasureId) return _defs[_i];
    }
    show_error("Unknown treasure: " + string(_treasureId), true);
}

function gather_def_get(_gatherId) {
    var _defs = global.gatherData.gather;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _gatherId) return _defs[_i];
    }
    show_error("Unknown gather card: " + string(_gatherId), true);
}

function hazard_def_get(_hazardId) {
    var _defs = global.hazardData.hazards;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _hazardId) return _defs[_i];
    }
    show_error("Unknown hazard/structure: " + string(_hazardId), true);
}

function pellet_def_get(_pelletId) {
    var _defs = global.pelletData.pellets;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _pelletId) return _defs[_i];
    }
    show_error("Unknown pellet: " + string(_pelletId), true);
}

function pikmin_type_get(_typeId) {
    var _types = global.pikminData.types;
    for (var _i = 0; _i < array_length(_types); _i++) {
        if (_types[_i].id == _typeId) return _types[_i];
    }
    show_error("Unknown pikmin type: " + string(_typeId), true);
}

function enemy_def_get(_enemyId) {
    var _defs = global.enemyData.enemies;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _enemyId) return _defs[_i];
    }
    show_error("Unknown enemy: " + string(_enemyId), true);
}

function board_def_get(_boardId) {
    var _defs = global.boardData.boards;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _boardId) return _defs[_i];
    }
    show_error("Unknown board: " + string(_boardId), true);
}
