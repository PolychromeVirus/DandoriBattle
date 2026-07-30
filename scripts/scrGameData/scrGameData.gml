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

/// Human-readable AI label for a seat's difficulty/brain token: "Easy AI" / "Medium AI" /
/// "Hard AI" for the menu tiers, or the raw brain id as-is (e.g. "v4") for an F1/batch/sim
/// swap where no tier applies.
function seat_ai_label(_token) {
    switch (_token) {
        case "easy":   return "Easy AI";
        case "medium": return "Medium AI";
        case "hard":   return "Hard AI";
        default:       return _token;
    }
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
    //  iceFreeze = ice pikmin >= ceil(hp/2) freeze an enemy (skip a turn); off = ice just damages
    //  bossCap = max bosses per spawn instance: -1 no cap, 0 none, 1..5 that many
    //  explodeEnemies = an explosive enemy's + blast also damages OTHER enemies (no reward)
    global.expRules = { red: true, blue: true, yellow: true, rush: true, enemyHeal: false, anims: true, iceFreeze: true, bossCap: -1, explodeEnemies: false };

    // Persisted menu/options (seat choices + selection default + fullscreen). Defaults here;
    // settings_load() overlays whatever's saved in settings.ini from a previous run.
    global.settings = { ctl: ["human", "hard"], defaultSelectAll: false, fullscreen: false };
    settings_load();

    // procedural "random" board as the last entry of the board list (regenerated on demand
    // from the board-select screen; board_def_get / preview / game_new all resolve it by id)
    array_push(global.boardData.boards, board_generate_random());
    // the tutorial is a full scenario (scenario_tutorial), not a listed board - nothing to register.
}

#macro SETTINGS_FILE "settings.ini"

/// Overlay saved options from settings.ini onto the in-memory defaults (global.expRules +
/// global.settings). First run (no file) leaves the defaults untouched. Booleans are stored
/// as 1/0 reals; each read falls back to the current default so a partial/old file is safe.
function settings_load() {
    if (!file_exists(SETTINGS_FILE)) return;
    ini_open(SETTINGS_FILE);
    var _r = global.expRules;
    _r.red       = ini_read_real("rules", "red",       _r.red       ? 1 : 0) != 0;
    _r.blue      = ini_read_real("rules", "blue",      _r.blue      ? 1 : 0) != 0;
    _r.yellow    = ini_read_real("rules", "yellow",    _r.yellow    ? 1 : 0) != 0;
    _r.rush      = ini_read_real("rules", "rush",      _r.rush      ? 1 : 0) != 0;
    _r.enemyHeal = ini_read_real("rules", "enemyHeal", _r.enemyHeal ? 1 : 0) != 0;
    _r.anims     = ini_read_real("rules", "anims",     _r.anims     ? 1 : 0) != 0;
    _r.iceFreeze = ini_read_real("rules", "iceFreeze", _r.iceFreeze ? 1 : 0) != 0;
    _r.bossCap   = ini_read_real("rules", "bossCap",   _r.bossCap);
    _r.explodeEnemies = ini_read_real("rules", "explodeEnemies", _r.explodeEnemies ? 1 : 0) != 0;
    var _s = global.settings;
    _s.ctl[0]           = ini_read_string("game", "p1", _s.ctl[0]);
    _s.ctl[1]           = ini_read_string("game", "p2", _s.ctl[1]);
    _s.defaultSelectAll = ini_read_real("game", "defaultSelectAll", _s.defaultSelectAll ? 1 : 0) != 0;
    _s.fullscreen       = ini_read_real("game", "fullscreen", _s.fullscreen ? 1 : 0) != 0;
    ini_close();
}

/// Write the current options (global.expRules + global.settings) back to settings.ini.
/// Called by objGame whenever the player changes an option on the menu.
function settings_save() {
    ini_open(SETTINGS_FILE);
    var _r = global.expRules;
    ini_write_real("rules", "red",       _r.red       ? 1 : 0);
    ini_write_real("rules", "blue",      _r.blue      ? 1 : 0);
    ini_write_real("rules", "yellow",    _r.yellow    ? 1 : 0);
    ini_write_real("rules", "rush",      _r.rush      ? 1 : 0);
    ini_write_real("rules", "enemyHeal", _r.enemyHeal ? 1 : 0);
    ini_write_real("rules", "anims",     _r.anims     ? 1 : 0);
    ini_write_real("rules", "iceFreeze", _r.iceFreeze ? 1 : 0);
    ini_write_real("rules", "bossCap",   _r.bossCap);
    ini_write_real("rules", "explodeEnemies", _r.explodeEnemies ? 1 : 0);
    var _s = global.settings;
    ini_write_string("game", "p1", _s.ctl[0]);
    ini_write_string("game", "p2", _s.ctl[1]);
    ini_write_real("game", "defaultSelectAll", _s.defaultSelectAll ? 1 : 0);
    ini_write_real("game", "fullscreen", _s.fullscreen ? 1 : 0);
    ini_close();
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

/// Display name for a gather card - differentiates the two Candypop Buds by their colour set
/// (classic RBY vs candypopbud2's rock/ice/winged = CMK); everything else uses the def name.
function gather_display_name(_gatherId) {
    switch (_gatherId) {
        case "candypopbud":  return "Candypop Bud (RBY)";
        case "candypopbud2": return "Candypop Bud (CMK)";
        default:             return gather_def_get(_gatherId).name;
    }
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

/// Curated pause-menu info for a pikmin type: `chips` = element/space tags shown as boxed
/// chips (each {label, el}; el drives the icon - a sprite, or the brownish square for "chasm"
/// which has none), and `note` = a plain-text line of pikmin properties drawn under the chips
/// (or "" for none). Hand-written because the wording isn't in the data. [[dandori-battle-project]]
function pikmin_display_tags(_id) {
    switch (_id) {
        case "red":     return { chips: [{label:"Fire", el:"fire"}], note: "" };
        case "blue":    return { chips: [{label:"Water", el:"water"}], note: "" };
        case "yellow":  return { chips: [{label:"Electric", el:"electric"}, {label:"Height", el:"height"}], note: "" };
        case "purple":  return { chips: [], note: "Has 5 strength" };
        case "white":   return { chips: [{label:"Poison", el:"poison"}], note: "Moves fast and damages enemies when eaten" };
        case "rock":    return { chips: [{label:"Crush", el:"crush"}, {label:"Stab", el:"stab"}], note: "" };
        case "ice":     return { chips: [{label:"Ice", el:"ice"}], note: "" };
        case "winged":  return { chips: [{label:"Chasm", el:"chasm"}, {label:"Height", el:"height"}], note: "Not affected by ground hazards, blocked by walls." };
        case "bulbmin": return { chips: [{label:"Fire",el:"fire"},{label:"Water",el:"water"},{label:"Electric",el:"electric"},{label:"Ice",el:"ice"},{label:"Poison",el:"poison"},{label:"Control",el:"control"}], note: "" };
        default:        return { chips: [], note: "" };
    }
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
