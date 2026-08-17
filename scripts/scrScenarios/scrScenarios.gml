// SCENARIO DEFINITIONS
// A "scenario" is a COMPLETE game struct (the same _g the engine operates on). game_new, given a
// scenario, just variable_clones it and skips all generative setup - so what you write here IS the
// exact starting state. Used by the tutorial today and a future challenge mode.
//
// scenario_base(boardDef) is the SINGLE SOURCE OF TRUTH for the _g schema. game_new routes its own
// generative path through it (blank skeleton -> generative overrides -> setup), and every scenario
// starts from it and overrides only the handful of fields that make it distinct. Add a new _g field
// here and both the normal game and all scenarios get it - nothing else to touch.

/// The full default _g skeleton for a board: two empty players, empty decks, day 1 (1/5), 2-player.
/// Both a normal game (via game_new) and any scenario start here and override what differs.
function scenario_base(_boardDef) {
    // VERSUS 2-day toggle: build the 7-space/2-day track when the rule is on (adventure re-pins its own
    // length below, so this only affects normal matches). dayTrackLength = the track's segment count.
    var _twoDay = variable_struct_exists(global.expRules, "twoDayMode") && global.expRules.twoDayMode;
    var _dtDef = game_day_track_for_board(_boardDef, _twoDay);
    return {
        boardDef: _boardDef,
        board: board_create(_boardDef),
        treasures: [],       // {cards:[treasureIds], lane, idx, boss:undefined|{enemyDefId, curHp, dead}}
        players: [
            { playerIdx: 0, hand: [], pellets: [], tokens: [], score: 0, collected: [], turnsTaken: 0, flarlicBonus: 0, wildCount: 0, glowUp: false },
            { playerIdx: 1, hand: [], pellets: [], tokens: [], score: 0, collected: [], turnsTaken: 0, flarlicBonus: 0, wildCount: 0, glowUp: false },
        ],                   // player: {playerIdx, hand, pellets, tokens, score, collected, turnsTaken, flarlicBonus (FLARLIC day cap boost, persists)}
        firstPlayer: 0,
        activePlayer: 0,
        phase: "gather",     // gather | orders | move | gameover
        gatherActionsLeft: 3,// game_begin_turn resets this per turn (3 first turn, else 2)
        dayNumber: 1,
        dayTrack: 1,
        dayTrackLength: array_length(_dtDef.spaces), // per-day segment count (5 = 3-day, 7 = 2-day); a scenario can override to lengthen the day (e.g. long tutorials)
        dayTrackDef: _dtDef,  // NEW day system: the board's real per-space step events {days, spaces:[{ev,..}]}; days (2/3) drives the day limit (distinct from dayTrack, the within-day counter above)
        dayRawFree: false,      // RAW day event: building costs 1 raw this turn (reset each turn)
        dayPelletBonus: false,  // PELLET day event: pellets give +1 pikmin this turn (reset each turn)
        // (FLARLIC's persistent cap boost lives PER-PLAYER as players[_p].flarlicBonus, above)
        solo: false,         // scenarios set their own; false = normal 2-player (day flips seats)
        decks: { gather: [], gatherDiscard: [], treasure: [], enemy: [], enemyDiscard: [] },
        sprays: [],          // {playerIdx, lane, idx} - ultra-spicy tokens
        mines: [],           // {lane, idx, dmg} - arm at 10 pass-damage, then kill enders
        decoys: [],          // {playerIdx, lane, idx, hp} - pikpik carrots soak enemy damage
        pendingFree: [],     // {playerIdx, count} - boss bounty free hazard placements, killer first
        pendingDaySwap: undefined, // {playerIdx, from, to} - a player-driven day SWAP awaiting the owner's tile pick
        pendingDayPlace: undefined, // {playerIdx, kind:"pod"|"storm", count} - day POD/STORM awaiting the owner's space pick(s)
        pendingEvent: undefined,    // {playerIdx, effect, kind, hazard} - the ACTIVE adventure event space pick
        eventPending: [],           // FIFO of event effects to run this turn (one at a time; e.g. Double Event's two)
        pendingTypePick: undefined, // {playerIdx, purpose, options:[ids], lane, idx} - a CARD-TYPE chooser modal (e.g. Reconstruction's new wall)
        pendingLose: undefined,     // {playerIdx, need} - "Lose N pikmin of your choice" click-picker
        pendingSpy: undefined, // {viewer} - Spy treasure power: viewer gets a one-time read-only peek at the opponent's hand
        pendingReveal: undefined, // {chooser, lane, idx} - Reveal power: opponent picks a pile (lane<0 = still choosing) then its new top card
        popHistory: [],      // per-phase pikmin-population snapshots for the end-of-run graph: [{label,day,seats:[{typeId:count}]}]
        tileVersion: 0,      // bumped whenever a tile's TYPE changes (day swap) so the renderer rebuilds the baked tile-colour mesh
        pendingDiscard: undefined, // {playerIdx, need} - hand-limit overflow, owner picks; handoff waits
        departing: [],       // {cards, playerIdx, lane, fromIdx, total} - piles animating home, scored on arrival
        fx: [],              // presentation death events, drained by the controller (cosmetic; rules ignore it)
        resolveQueue: [],    // pending resolution beats (controller pumps game_resolve_step)
        jumpCue: "",         // "" | "pik" | "enemy" - renderer makes that side's fighters wind up
        bombCue: undefined,  // {lane, idx} - Bomb Rock/Boulder telegraph target (strobe + ring)
        sprayCue: false,     // spicy ignition beat - sprayed friendlies glow red
        soothed: false,      // a Soothe treasure power banked this turn -> enemies skip their attack
        bankCues: [],        // cosmetic: on-bank power activations {name,effect,good} - drained into toasts by the renderer
        sfxCue: [],          // cosmetic: queued one-shot SFX asset names - drained + played by the presentation (Step_0)
        trace: [false, false], // per-seat human decision tracing (controller sets from ctl)
        combatFights: undefined, // fights list persisted across staged combat beats
        log: [],
        winner: -1,
    };
}

/// The guided TUTORIAL. Solo, 3x4 board (one hazard per lane). Day track starts full (5/5) so the
/// first End-Orders rolls to day 2 and spawns the Bulborbs; enemy spaces are bare on day 1. P1
/// starts with one Red/Blue/Yellow at home and a light treasure waiting at the end of each lane.
/// Tweak the tutorial by editing the values below.
function scenario_tutorial() {
    var _g = scenario_base(board_tutorial());
    _g.solo = true;
    _g.dayTrack = _g.dayTrackLength;   // full track -> turn 1 ends day 1, spawns enemies
    _g.players[0].tokens = [
        { typeId: "red",    loc: { kind: "home" } },
        { typeId: "blue",   loc: { kind: "home" } },
        { typeId: "yellow", loc: { kind: "home" } },
    ];
    _g.treasures = [
        { cards: ["arborealfrippery"], lane: 0, idx: 3, boss: undefined },
        { cards: ["arborealfrippery"], lane: 1, idx: 3, boss: undefined },
        { cards: ["arborealfrippery"], lane: 2, idx: 3, boss: undefined },
    ];
    // a few gather cards to demonstrate; enough Bulborbs to fill the enemy row on the day-2 rollover
    _g.decks.gather = ["rawmaterial", "candypopbud", "spicyspray"];
    var _enemy = []; repeat (8) array_push(_enemy, "dwarfbulborb");
    _g.decks.enemy = _enemy;
    return _g;
}

/// Tutorial chapter 2: the ITEM / double-move scene. Solo, no hazards or enemies. 2 whites + 6 reds
/// at home; three weight-2 treasures pre-advanced to idx 1 (two carry-steps from banking). Gather
/// deck = exactly one Ultra-Spicy Spray. The lesson: bank all three in ONE turn using the three
/// ways a pile moves twice - 2 whites (white-only), 4 reds (2x rush, needs rush rule ON), and
/// 2 reds + the spray. Loaded with rush ON and Underground-Plateau (cave) theming via its board def.
function scenario_tutorial2() {
    var _g = scenario_base(board_tutorial2());
    _g.solo = true;
    _g.players[0].tokens = [];
    repeat (2) array_push(_g.players[0].tokens, { typeId: "white", loc: { kind: "home" } });
    repeat (6) array_push(_g.players[0].tokens, { typeId: "red",   loc: { kind: "home" } });
    _g.treasures = [
        { cards: ["abstractmasterpiece"], lane: 0, idx: 1, boss: undefined },
        { cards: ["abstractmasterpiece"], lane: 1, idx: 1, boss: undefined },
        { cards: ["abstractmasterpiece"], lane: 2, idx: 1, boss: undefined },
    ];
    _g.decks.gather = ["spicyspray"];   // exactly one item to draw
    return _g;
}

/// Tutorial chapter 3: the TREASURE-PILE scene. Solo. Middle lane holds a two-card pile at idx 1
/// (front of home): a weight-20 item ON TOP of a weight-8 item, so the pile weighs 20 - too heavy
/// for the 8 reds. The flanking chasm lanes hold unreachable treasures (no winged pikmin). The hand
/// is full of Ship Signal (deterministic: choose the new top) and Survey Drone (random reshuffle);
/// either can put the weight-8 item on top so the 8 reds can haul the whole pile - heavy item and
/// all - home. Cards[] top = LAST element, so [w8, w20] shows w20 on top.
function scenario_tutorial3() {
    var _g = scenario_base(board_tutorial3());
    _g.solo = true;
    _g.players[0].tokens = [];
    repeat (8) array_push(_g.players[0].tokens, { typeId: "red", loc: { kind: "home" } });
    _g.players[0].hand = ["shipsignal", "surveydrone", "shipsignal", "surveydrone", "shipsignal", "surveydrone"];
    _g.treasures = [
        { cards: ["gleespinner"], lane: 0, idx: 3, boss: undefined },                        // unreachable (chasm)
        { cards: ["connectiondetector", "amplifiedamplifier"], lane: 1, idx: 0, boss: undefined }, // w8 under w20 (the lesson)
        { cards: ["lifecontroller"], lane: 2, idx: 3, boss: undefined },                      // unreachable (chasm)
    ];
    _g.decks.gather = [];   // no drawing - they already hold the tools
    return _g;
}

/// Tutorial chapter 4: CRUSH/Rock -> chasm/Winged -> swift, all via Candypop. Solo, Frigid Wasteland.
/// Lane 1 = two Wollyhops (curHp 3, CRUSH - stomp non-immune pikmin even in death) guarding a
/// weight-1 treasure. Lane 2 = a chasm (only Winged cross), a swift 1/1 Shearwig (attacks BEFORE the
/// player), and a second weight-1 treasure. Player: 3 Reds already ON the first Wollyhop + 3 home, NO
/// cards. Scene starts in the MOVE phase (turn 1 = resolve+watch the Reds die). Gather deck =
/// Candypop Bud (candypopbud2: Rock/Ice/Winged). Arc: Rock beats crush losslessly -> Winged cross the
/// chasm -> commit 2 to the swift (it eats one, one kills it). Weight-1 treasures so a single carrier
/// banks lane 1, freeing the rest for lane 2.
function scenario_tutorial4() {
    var _g = scenario_base(board_tutorial4());
    _g.solo = true;
    _g.dayTrackLength = 10;   // long, multi-turn scene - keep the day from rolling over (pikmin flying home) mid-lesson
    _g.board.lanes[0].spaces[0].enemy = { enemyDefId: "wollyhop", curHp: 3, dead: false };  // first Wollyhop
    _g.board.lanes[0].spaces[1].enemy = { enemyDefId: "wollyhop", curHp: 3, dead: false };  // second Wollyhop
    _g.board.lanes[1].spaces[1].enemy = { enemyDefId: "shearwig", curHp: 1, dead: false };  // swift 1/1, behind the chasm
    _g.treasures = [
        { cards: ["arborealfrippery"], lane: 0, idx: 2, boss: undefined },   // weight 1
        { cards: ["arborealfrippery"], lane: 1, idx: 2, boss: undefined },   // weight 1, across the chasm
    ];
    _g.players[0].hand = [];       // no cards to start - they draw the first Candypop themselves
    _g.players[0].pellets = [];    // and no pellet cards at all (roll is hidden this scene)
    _g.players[0].tokens = [];
    repeat (3) array_push(_g.players[0].tokens, { typeId: "red", loc: { kind: "space", lane: 0, idx: 0 } }); // on the first Wollyhop
    repeat (3) array_push(_g.players[0].tokens, { typeId: "red", loc: { kind: "home" } });
    var _deck = []; repeat (2) array_push(_deck, "candypopbud2");   // exactly Rock + Winged; empty gather phases auto-skip (Step_0 guard), checkpoints restore the hand
    _g.decks.gather = _deck;
    return _g;
}

/// DEV: a free-roam solo game on the irregular board_advtest (unequal 3/8/5/10 lanes, treasure at
/// each far end). Purpose = eyeball the adventure geometry groundwork: home-anchored layout, long
/// lanes, board-relative pan, and solo-gated dressing (one home, no opponent onion/hand). A generous
/// R/B/Y/Winged kit crosses every hazard; enemies sit on each enemy space so their card decals show.
/// Launched from the main-menu "Adv Test" button (start_advtest -> full renderer + frame_board).
function scenario_advtest() {
    var _g = scenario_base(board_advtest());
    _g.solo = true;
    _g.dayTrackLength = 12;   // long day so the rollover (fly-home) doesn't interrupt a wander
    _g.players[0].tokens = [];
    repeat (5) array_push(_g.players[0].tokens, { typeId: "red",    loc: { kind: "home" } });
    repeat (3) array_push(_g.players[0].tokens, { typeId: "blue",   loc: { kind: "home" } });
    repeat (3) array_push(_g.players[0].tokens, { typeId: "yellow", loc: { kind: "home" } });
    repeat (2) array_push(_g.players[0].tokens, { typeId: "winged", loc: { kind: "home" } });
    // one treasure at each lane's FAR space (last index of each lane)
    _g.treasures = [
        { cards: ["arborealfrippery"], lane: 0, idx: 2, boss: undefined },
        { cards: ["arborealfrippery"], lane: 1, idx: 7, boss: undefined },
        { cards: ["arborealfrippery"], lane: 2, idx: 4, boss: undefined },
        { cards: ["arborealfrippery"], lane: 3, idx: 9, boss: undefined },
        { cards: ["arborealfrippery"], lane: 4, idx: 5, boss: undefined },
    ];
    // populate every enemy space so its card decal renders (checks solo fixture-facing = no flip)
    for (var _l = 0; _l < array_length(_g.board.lanes); _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].kind == "enemy") _sp[_i].enemy = { enemyDefId: "dwarfbulborb", curHp: enemy_def_get("dwarfbulborb").hp, dead: false };
        }
    }
    _g.decks.gather = ["rawmaterial", "rawmaterial", "candypopbud", "spicyspray", "rawmaterial"];
    var _enemy = []; repeat (8) array_push(_enemy, "dwarfbulborb");   // respawn pool for day rollovers
    _g.decks.enemy = _enemy;
    return _g;
}

/// Build a playable SOLO game from an extracted ADVENTURE board def (see adventure_build_defs). The
/// board is home-anchored (treasure at the far end of each lane). We place: the board's pikmin kit at
/// home, a light treasure on every treasure space (a boss on it if one was named there), any named
/// enemies on their enemy spaces (bare enemy spaces fill from a small deck), and the pre-placed
/// structures. FIRST PASS: treasures are a generic light item and the enemy respawn deck is generic -
/// the campaign's specific treasure series / event cards / timed rules come later.
function scenario_adventure(_advBoard, _daysLeft = 3, _enemyIds = undefined) {
    var _g = scenario_base(_advBoard);
    _g.solo = true;
    // ADVENTURE campaign: this board draws from the RUN's shared day budget. When it's
    // spent the board ends (game_advance_day -> gameover), which the controller reads as
    // the run running out of time. Clearing the board (all treasures banked) ends it early.
    _g.dayLimit = max(1, _daysLeft);
    // starting pikmin: a handful of each type in the board's kit, at home
    _g.players[0].tokens = [];
    var _kit = _advBoard.kit;
    for (var _k = 0; _k < array_length(_kit); _k++)
        array_push(_g.players[0].tokens, { typeId: _kit[_k], loc: { kind: "home" } });   // 1 of each, like a normal game

    // index named enemies by space; those sitting ON a treasure space are that pile's BOSS
    var _bossAt = {};
    for (var _e = 0; _e < array_length(_advBoard.placedEnemies); _e++) {
        var _pe = _advBoard.placedEnemies[_e];
        var _sp = _g.board.lanes[_pe.lane].spaces[_pe.idx];
        if (_sp.kind == "treasure") _bossAt[$ string(_pe.lane) + "_" + string(_pe.idx)] = _pe.enemyDefId;
        else if (_sp.kind == "enemy") _sp.enemy = { enemyDefId: _pe.enemyDefId, curHp: enemy_def_get(_pe.enemyDefId).hp, dead: false };
    }
    // place the map's treasure POOL onto its treasure spaces. BOSS-guarded spaces are always fed
    // first (a boss must guard a real treasure); the rest are shuffled so that - when the map lists
    // FEWER treasures than it has treasure spaces - WHICH space ends up empty is random per run. An
    // empty treasure space stays a treasure space (never converted to plain), just with no pile.
    var _bossSpaces = [];   // {lane, idx, boss}
    var _freeSpaces = [];   // {lane, idx}
    for (var _l = 0; _l < array_length(_g.board.lanes); _l++) {
        var _lsp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_lsp); _i++) {
            if (_lsp[_i].kind != "treasure") continue;
            var _tkey = string(_l) + "_" + string(_i);
            if (variable_struct_exists(_bossAt, _tkey)) array_push(_bossSpaces, { lane: _l, idx: _i, boss: _bossAt[$ _tkey] });
            else array_push(_freeSpaces, { lane: _l, idx: _i });
        }
    }
    // Fisher-Yates shuffle the FREE spaces (boss spaces stay guaranteed)
    for (var _s = array_length(_freeSpaces) - 1; _s > 0; _s--) {
        var _j = irandom(_s); var _sw = _freeSpaces[_s]; _freeSpaces[_s] = _freeSpaces[_j]; _freeSpaces[_j] = _sw;
    }
    var _order = [];
    for (var _b = 0; _b < array_length(_bossSpaces); _b++) array_push(_order, _bossSpaces[_b]);
    for (var _f = 0; _f < array_length(_freeSpaces); _f++) array_push(_order, _freeSpaces[_f]);
    _g.treasures = [];
    var _pool = _advBoard.treasures;
    for (var _t = 0; _t < array_length(_pool) && _t < array_length(_order); _t++) {
        var _os = _order[_t];
        var _tboss = undefined;
        if (variable_struct_exists(_os, "boss")) _tboss = { enemyDefId: _os.boss, curHp: enemy_def_get(_os.boss).hp, dead: false };
        array_push(_g.treasures, { cards: [_pool[_t].id], lane: _os.lane, idx: _os.idx, boss: _tboss });
    }
    // pre-placed structures (walls / geysers already standing on the board)
    for (var _s2 = 0; _s2 < array_length(_advBoard.placedStructures); _s2++) {
        var _ps = _advBoard.placedStructures[_s2];
        var _psp = _g.board.lanes[_ps.lane].spaces[_ps.idx];
        _psp.structure = { structId: _ps.structId, curHp: hazard_def_get(_ps.structId).hp };
    }
    // ENEMY DECK: the map's own deck (from the campaign enemy sheets) fills bare enemy spaces now
    // and respawns at sunset. Falls back to a filler if a map shipped no deck.
    // In a campaign run the EVOLVED per-checkpoint deck (_enemyIds) is passed in; a bare dev launch
    // (no deck) falls back to expanding this board's own additions column.
    var _enemyDeck = [];
    if (is_array(_enemyIds) && array_length(_enemyIds) > 0) {
        for (var _ei = 0; _ei < array_length(_enemyIds); _ei++) array_push(_enemyDeck, _enemyIds[_ei]);
    } else {
        for (var _ed = 0; _ed < array_length(_advBoard.enemyDeck); _ed++) {
            var _ee = _advBoard.enemyDeck[_ed];
            repeat (_ee.count) array_push(_enemyDeck, _ee.id);
        }
    }
    if (array_length(_enemyDeck) == 0) repeat (8) array_push(_enemyDeck, "dwarfbulborb");
    deck_shuffle(_enemyDeck);
    _g.decks.enemy = _enemyDeck;
    board_spawn_enemies(_g.board, _g.decks.enemy);
    // GATHER DECK: the shared campaign gather deck (the 12 campaign cards).
    var _gatherDeck = [];
    for (var _gd = 0; _gd < array_length(_advBoard.gatherDeck); _gd++) array_push(_gatherDeck, _advBoard.gatherDeck[_gd]);
    if (array_length(_gatherDeck) == 0) _gatherDeck = ["rawmaterial", "spicyspray"];
    deck_shuffle(_gatherDeck);
    _g.decks.gather = _gatherDeck;
    _g.decks.treasure = [];
    // BLANK day tracker: still SHOWN in the HUD (all blank-sun segments), but it fires NOTHING -
    // adventure uses random EVENT CARDS (one drawn per turn) instead of the standard day events.
    // (all-"none" spaces => game_day_track_fire / day-spawn are no-ops, and the strip draws suns.)
    _g.dayTrackLength = global.rules.dayTrackLength;   // adventure uses the STANDARD day length - isolate from the versus 2-day toggle
    var _blankTrack = [];
    repeat (_g.dayTrackLength) array_push(_blankTrack, { ev: "none" });
    _g.dayTrackDef = { days: _g.dayLimit, spaces: _blankTrack };
    // build the shuffled per-turn event draw pile from the map's event deck ({name,good,n,desc})
    var _evDeck = variable_struct_exists(_advBoard, "eventDeck") ? _advBoard.eventDeck : [];
    var _pile = [];
    for (var _ev = 0; _ev < array_length(_evDeck); _ev++) {
        var _evc = _evDeck[_ev];
        var _edesc = variable_struct_exists(_evc, "desc") ? _evc.desc : "";
        repeat (_evc.n) array_push(_pile, { name: _evc.name, good: _evc.good, desc: _edesc });
    }
    deck_shuffle(_pile);
    _g.advEventPile = _pile;
    _g.advEventDiscard = [];
    // per-turn event MODIFIERS (reset + re-applied each turn by game_adv_event_step)
    _g.advForceAttack = ""; _g.advForceDefense = ""; _g.advEnemyDmgMult = 1;
    _g.advNoImmunities = false; _g.advNoPellets = false; _g.advTreasureHeavier = 0; _g.advSkipTurn = false;
    return _g;
}
