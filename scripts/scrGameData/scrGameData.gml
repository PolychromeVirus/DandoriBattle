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
    global.dayTrackData = json_load_included("data/daytracks.json");   // per-board day trackers (by set number)
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
    // allSet = which shared power-card set (ALL1/ALL2) is mixed into every board's treasure deck in
    // addition to its base set: 1, 2, or 0 = pick randomly each game. (The physical game has you choose
    // ALL1 or ALL2 per play.)
    // advCleared = adventure-campaign unlock frontier (how many scenarios beaten; 0 = only the first open)
    // masterVol/bgmVol/sfxVol = 0..1 volume sliders (applied via apply_audio_settings). Default 0.8
    // so a first launch isn't ear-splitting; 1.0 reproduces the pre-slider balance.
    global.settings = { ctl: ["human", "hard"], defaultSelectAll: false, fullscreen: false, allSet: 1, advCleared: 0,
                        masterVol: 0.8, bgmVol: 0.8, sfxVol: 0.8 };
    settings_load();

    // procedural "random" board as the last entry of the board list (regenerated on demand
    // from the board-select screen; board_def_get / preview / game_new all resolve it by id)
    array_push(global.boardData.boards, board_generate_random());
    // the tutorial is a full scenario (scenario_tutorial), not a listed board - nothing to register.

    // ADVENTURE (single-player campaign): scenarios of home-anchored boards pulled from the
    // reference .xlsx by tools/extract_adventure.py. Loaded here, then finished into full board
    // defs (setNumber/pelletDie/buildable-structures) so the chapter-select + game_new can use them.
    global.adventureData = json_load_optional("data/adventure.json", { scenarios: [] });
    adventure_build_defs();
    adventure_saves_load();   // 3 adventure logs (save slots), created/repaired from advsave.json
}

/// Finish the raw extracted adventure boards into playable board DEFS: theme (setNumber), a pellet
/// die from the basic colours, buildable structures, and display metadata. The lanes / homeAnchored /
/// kit / placedStructures / placedEnemies fields come straight from the extractor. Idempotent-ish
/// (only adds fields), called once at boot.
function adventure_build_defs() {
    var _setByScenario = [12, 8, 13];   // per-chapter theming: sand / grass / golden staircase
    var _scens = global.adventureData.scenarios;
    for (var _si = 0; _si < array_length(_scens); _si++) {
        var _set = _setByScenario[_si mod array_length(_setByScenario)];
        var _boards = _scens[_si].boards;
        for (var _bi = 0; _bi < array_length(_boards); _bi++) {
            var _b = _boards[_bi];
            _b.setNumber = _set;
            _b.name = _b.label;                 // e.g. "ADV1.1" - the chapter-select formats it nicer
            _b.difficulty = "Adventure";
            _b.treasureSet = 1;
            _b.killedIfThrownOut = false;
            _b.scenarioIdx = _si;
            _b.boardIdx = _bi;
            var _die = [];
            var _bc = _b.basicColors;
            for (var _ci = 0; _ci < array_length(_bc); _ci++) {
                array_push(_die, { color: _bc[_ci], value: 1 });
                array_push(_die, { color: _bc[_ci], value: 5 });
            }
            _b.pelletDie = _die;
            // BUILDABLE structures come from the map's bracket note (buildStructs: 1=bridge, 2=climbing
            // stick, 3=tunnel - all crossings). Walls are NEVER buildable in adventure, and emitters
            // aren't offered either (only the listed crossings). Pre-placed fixtures live in placedStructures.
            var _bs = variable_struct_exists(_b, "buildStructs") ? _b.buildStructs : ["bridge"];
            _b.structures = { bridges: _bs, walls: [], emitters: [] };
            // per-SCENARIO looping music (adventure boards have label-names, not song-matching names, so
            // the normal name->track lookup can't find anything). Continues seamlessly across the
            // scenario's boards (same asset = no restart). Silent if the asset isn't imported yet.
            _b.music = adventure_scenario_music(_scens[_si].name);
        }
    }
}

/// The looping music-asset name for an adventure scenario. Default convention = the scenario name with
/// all non-alphanumeric chars removed ("Stranded Captain" -> "StrandedCaptain", "Glutton's Sweet Tooth"
/// -> "GluttonsSweetTooth"); import a sound asset with that name and it auto-hooks. To use a differently
/// named asset, add an override case below.
function adventure_scenario_music(_scenName) {
    // Override cases can point at ANY existing sound asset (no need to import a new one).
    switch (_scenName) {
        case "Stranded Captain": return "FamiliarGrotto1";   // reuse an existing track
        // case "Glutton's Sweet Tooth": return "DiscoDancefloor1";
    }
    var _out = "";
    for (var _i = 1; _i <= string_length(_scenName); _i++) {
        var _ch = string_char_at(_scenName, _i);
        if ((_ch >= "0" && _ch <= "9") || (_ch >= "A" && _ch <= "Z") || (_ch >= "a" && _ch <= "z")) _out += _ch;
    }
    return _out;
}

/// Look up an adventure board def by id ("adv1_1"). undefined if not found.
function adventure_board_get(_id) {
    var _scens = global.adventureData.scenarios;
    for (var _si = 0; _si < array_length(_scens); _si++) {
        var _boards = _scens[_si].boards;
        for (var _bi = 0; _bi < array_length(_boards); _bi++) {
            if (_boards[_bi].id == _id) return _boards[_bi];
        }
    }
    return undefined;
}

// ===================== ADVENTURE SAVE LOGS =====================
// 3 independent save slots ("logs"). Each stores, PER CAMPAIGN (scenario), the day CHECKPOINT
// {daysLeft, daysUsed} at the start of every UNLOCKED mission. campaigns[c] length = # missions
// unlocked in campaign c (mission 0 is unlocked by default). Beating mission N writes mission N+1's
// checkpoint (and truncates any re-derived future). Persisted to a JSON file.

#macro ADV_SAVE_FILE "advsave.json"

/// The per-campaign day economy (start budget + bonus per mission cleared). Scenario 1 (idx 1)
/// earns time as it goes; the others draw from a fixed pool.
function adventure_day_config(_scenIdx, _boardCount) {
    if (_scenIdx == 0) return { start: 30, perClear: 0, dayPerTreasure: false };  // Stranded Captain: Pikmin-1-style 30-day pool (testing)
    if (_scenIdx == 1) return { start: 5,  perClear: 4, dayPerTreasure: false };  // Home Planet: start 5, +4 per mission cleared
    if (_scenIdx == 2) return { start: 3,  perClear: 0, dayPerTreasure: true };   // Glutton's: start 3, +1 day per treasure gathered
    return { start: 3 * _boardCount, perClear: 0, dayPerTreasure: false };
}

/// A fresh set of 3 empty logs: every campaign has only its FIRST mission unlocked (full budget).
function adventure_saves_default() {
    var _slots = [];
    var _scens = global.adventureData.scenarios;
    for (var _s = 0; _s < 3; _s++) {
        var _camps = [];
        for (var _c = 0; _c < array_length(_scens); _c++) {
            var _cfg = adventure_day_config(_c, array_length(_scens[_c].boards));
            _camps[_c] = [ { daysLeft: _cfg.start, daysUsed: 0, enemyDeck: adventure_deck_expand(_scens[_c].boards[0]) } ];   // mission 0 open by default
        }
        var _done = array_create(array_length(_scens), false);
        array_push(_slots, { campaigns: _camps, done: _done, curScen: -1, curBoard: -1 });
    }
    return _slots;
}

/// Ensure a loaded slot has a checkpoint array for every current campaign (handles added scenarios).
function adventure_saves_repair(_slots) {
    if (!is_array(_slots) || array_length(_slots) < 3) return adventure_saves_default();
    var _scens = global.adventureData.scenarios;
    for (var _s = 0; _s < 3; _s++) {
        if (!is_struct(_slots[_s]) || !variable_struct_exists(_slots[_s], "campaigns")) _slots[_s] = { campaigns: [], done: [], curScen: -1, curBoard: -1 };
        if (!variable_struct_exists(_slots[_s], "done") || !is_array(_slots[_s].done)) _slots[_s].done = array_create(array_length(_scens), false);
        if (!variable_struct_exists(_slots[_s], "curScen")) _slots[_s].curScen = -1;
        if (!variable_struct_exists(_slots[_s], "curBoard")) _slots[_s].curBoard = -1;
        var _camps = _slots[_s].campaigns;
        for (var _c = 0; _c < array_length(_scens); _c++) {
            if (_c >= array_length(_camps) || !is_array(_camps[_c]) || array_length(_camps[_c]) == 0) {
                var _cfg = adventure_day_config(_c, array_length(_scens[_c].boards));
                _camps[_c] = [ { daysLeft: _cfg.start, daysUsed: 0, enemyDeck: adventure_deck_expand(_scens[_c].boards[0]) } ];
            }
            if (_c >= array_length(_slots[_s].done)) _slots[_s].done[_c] = false;
        }
    }
    return _slots;
}

function adventure_saves_load() {
    if (!file_exists(ADV_SAVE_FILE)) { global.advSaves = adventure_saves_default(); return; }
    var _f = file_text_open_read(ADV_SAVE_FILE);
    var _str = "";
    while (!file_text_eof(_f)) { _str += file_text_read_string(_f); file_text_readln(_f); }
    file_text_close(_f);
    var _parsed;
    try { _parsed = json_parse(_str); } catch (_e) { _parsed = undefined; }
    global.advSaves = adventure_saves_repair(_parsed);
}

function adventure_saves_save() {
    if (!variable_global_exists("advSaves")) return;
    var _f = file_text_open_write(ADV_SAVE_FILE);
    file_text_write_string(_f, json_stringify(global.advSaves));
    file_text_close(_f);
}

/// ERASE one save log: reset it to a fresh default (only its first missions unlocked). Persists.
function adventure_slot_reset(_slotIdx) {
    if (!variable_global_exists("advSaves") || _slotIdx < 0 || _slotIdx >= array_length(global.advSaves)) return;
    var _fresh = adventure_saves_default();     // builds 3 blank logs; take the matching one
    global.advSaves[_slotIdx] = _fresh[_slotIdx];
    adventure_saves_save();
}

/// COPY one save log over another: overwrite _toIdx with a deep clone of _fromIdx. Persists.
function adventure_slot_copy(_fromIdx, _toIdx) {
    if (!variable_global_exists("advSaves") || _fromIdx == _toIdx) return;
    if (_fromIdx < 0 || _fromIdx >= array_length(global.advSaves)) return;
    if (_toIdx   < 0 || _toIdx   >= array_length(global.advSaves)) return;
    global.advSaves[_toIdx] = variable_clone(global.advSaves[_fromIdx]);   // deep copy (nested campaigns/decks/popHistory)
    adventure_saves_save();
}

/// NEW ADVENTURE: reset ONE campaign (scenario) inside a log back to its base start - a single
/// fresh mission-0 checkpoint (full day budget + starting deck), cleared 'done'. Leaves the log's
/// OTHER campaigns untouched. Persists.
function adventure_campaign_reset(_slotIdx, _scenIdx) {
    if (!variable_global_exists("advSaves") || _slotIdx < 0 || _slotIdx >= array_length(global.advSaves)) return;
    var _scens = global.adventureData.scenarios;
    if (_scenIdx < 0 || _scenIdx >= array_length(_scens)) return;
    var _cfg = adventure_day_config(_scenIdx, array_length(_scens[_scenIdx].boards));
    var _slot = global.advSaves[_slotIdx];
    _slot.campaigns[_scenIdx] = [ { daysLeft: _cfg.start, daysUsed: 0, enemyDeck: adventure_deck_expand(_scens[_scenIdx].boards[0]) } ];
    if (_scenIdx < array_length(_slot.done)) _slot.done[_scenIdx] = false;
    adventure_saves_save();
}

/// Has this campaign been TOUCHED in this log (so "New Adventure" would destroy progress)? True if a
/// later mission is unlocked, it's marked done, or its first mission was already played.
function adventure_campaign_started(_slotIdx, _scenIdx) {
    var _cp = adventure_mission_checkpoint(_slotIdx, _scenIdx, 0);
    if (_cp == undefined) return false;
    var _slot = global.advSaves[_slotIdx];
    if (array_length(_slot.campaigns[_scenIdx]) > 1) return true;
    if (_scenIdx < array_length(_slot.done) && _slot.done[_scenIdx]) return true;
    if (variable_struct_exists(_cp, "daysUsed") && _cp.daysUsed > 0) return true;
    return variable_struct_exists(_cp, "popHistory") && is_array(_cp.popHistory) && array_length(_cp.popHistory) > 0;
}

/// Is mission (scen, board) unlocked in slot _slotIdx? Unlocked = it has a saved start-checkpoint.
function adventure_mission_unlocked(_slotIdx, _scen, _board) {
    if (!variable_global_exists("advSaves") || _slotIdx < 0 || _slotIdx >= array_length(global.advSaves)) return _board == 0;
    var _camps = global.advSaves[_slotIdx].campaigns;
    if (_scen < 0 || _scen >= array_length(_camps)) return _board == 0;
    return _board >= 0 && _board < array_length(_camps[_scen]);
}

/// The saved day checkpoint {daysLeft, daysUsed, enemyDeck} for a mission (undefined if not unlocked).
function adventure_mission_checkpoint(_slotIdx, _scen, _board) {
    if (!adventure_mission_unlocked(_slotIdx, _scen, _board)) return undefined;
    return global.advSaves[_slotIdx].campaigns[_scen][_board];
}

// ---- ENEMY DECK EVOLUTION (culling) --------------------------------------------------
// The campaign enemy deck is PERSISTENT and evolves map-to-map: each map's enemyDeck [{id,count}]
// is that map's ADVANCED-CARD ADDITIONS (map 0's is the whole starting deck), and cullBefore
// {remove,thr,type} is the cut applied to the carried deck right before the map is played (remove
// <remove> cards whose hp/dmg is </= thr). Every UNLOCKED checkpoint stores the exact flat id deck
// used to play that map, so "play from here" replays that map's saved deck faithfully.

/// Expand a board's enemyDeck [{id,count}] into a flat array of enemy ids (its additions).
function adventure_deck_expand(_advBoard) {
    var _out = [];
    var _dk = _advBoard.enemyDeck;
    for (var _i = 0; _i < array_length(_dk); _i++) repeat (_dk[_i].count) array_push(_out, _dk[_i].id);
    return _out;
}

/// The stat (hp or damage) a cull rule filters an enemy id on. Missing def -> huge (never matches).
function adventure_cull_stat(_id, _rule) {
    var _def = enemy_def_get(_id);
    if (_def == undefined) return 99999;
    return (_rule.type == "dmg") ? _def.damage : _def.hp;
}

/// Does this enemy id match a cull rule (its stat is </= the threshold)?
function adventure_cull_match(_id, _rule) {
    return adventure_cull_stat(_id, _rule) <= _rule.thr;
}

/// Carry deck -> next checkpoint deck: apply the board's cull (AUTO = lowest-stat matching first),
/// then mix in the board's additions. Returns a NEW flat id array. The interactive menu overrides
/// WHICH matching cards are cut; this auto path seeds/back-fills and drives play-from-here.
function adventure_deck_advance(_deckIds, _advBoard) {
    var _deck = [];
    for (var _c = 0; _c < array_length(_deckIds); _c++) array_push(_deck, _deckIds[_c]);
    var _rule = variable_struct_exists(_advBoard, "cullBefore") ? _advBoard.cullBefore : undefined;
    if (_rule != undefined) {
        var _match = [];   // {idx, s} for every matching card, sorted by stat ascending
        for (var _i = 0; _i < array_length(_deck); _i++)
            if (adventure_cull_match(_deck[_i], _rule)) array_push(_match, { idx: _i, s: adventure_cull_stat(_deck[_i], _rule) });
        array_sort(_match, function(_a, _b) { return _a.s - _b.s; });
        var _rm = [];      // absolute indices to delete (the lowest-stat <remove> matches)
        for (var _m = 0; _m < array_length(_match) && _m < _rule.remove; _m++) array_push(_rm, _match[_m].idx);
        array_sort(_rm, function(_a, _b) { return _b - _a; });   // descending: delete high-to-low so indices don't shift
        for (var _d = 0; _d < array_length(_rm); _d++) array_delete(_deck, _rm[_d], 1);
    }
    var _adds = adventure_deck_expand(_advBoard);
    for (var _a = 0; _a < array_length(_adds); _a++) array_push(_deck, _adds[_a]);
    return _deck;
}

/// Build (scen,board)'s enemy deck from scratch by walking boards 0..board with AUTO cull. Used to
/// seed/back-fill a checkpoint whose deck wasn't stored (old saves, or a re-derived future mission).
function adventure_deck_derive(_scen, _board) {
    var _boards = global.adventureData.scenarios[_scen].boards;
    var _deck = adventure_deck_expand(_boards[0]);
    for (var _b = 1; _b <= _board && _b < array_length(_boards); _b++) _deck = adventure_deck_advance(_deck, _boards[_b]);
    return _deck;
}

/// The flat enemy deck to PLAY a checkpoint's map (lazily derives + back-fills if none was stored).
function adventure_checkpoint_deck(_slotIdx, _scen, _board) {
    var _cp = adventure_mission_checkpoint(_slotIdx, _scen, _board);
    if (_cp == undefined) return adventure_deck_derive(_scen, _board);
    if (!variable_struct_exists(_cp, "enemyDeck") || !is_array(_cp.enemyDeck) || array_length(_cp.enemyDeck) == 0)
        _cp.enemyDeck = adventure_deck_derive(_scen, _board);
    return _cp.enemyDeck;
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
    _s.allSet           = ini_read_real("game", "allSet", _s.allSet);
    _s.advCleared       = ini_read_real("game", "advCleared", _s.advCleared);
    _s.masterVol        = clamp(ini_read_real("audio", "master", _s.masterVol), 0, 1);
    _s.bgmVol           = clamp(ini_read_real("audio", "bgm",    _s.bgmVol),    0, 1);
    _s.sfxVol           = clamp(ini_read_real("audio", "sfx",    _s.sfxVol),    0, 1);
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
    ini_write_real("game", "allSet", _s.allSet);
    ini_write_real("game", "advCleared", _s.advCleared);
    ini_write_real("audio", "master", _s.masterVol);
    ini_write_real("audio", "bgm",    _s.bgmVol);
    ini_write_real("audio", "sfx",    _s.sfxVol);
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
