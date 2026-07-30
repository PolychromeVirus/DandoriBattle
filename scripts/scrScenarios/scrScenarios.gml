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
    return {
        boardDef: _boardDef,
        board: board_create(_boardDef),
        treasures: [],       // {cards:[treasureIds], lane, idx, boss:undefined|{enemyDefId, curHp, dead}}
        players: [
            { playerIdx: 0, hand: [], pellets: [], tokens: [], score: 0, collected: [], turnsTaken: 0 },
            { playerIdx: 1, hand: [], pellets: [], tokens: [], score: 0, collected: [], turnsTaken: 0 },
        ],                   // player: {playerIdx, hand:[gatherIds], pellets:[pelletIds], tokens:[{typeId,loc}], score, collected, turnsTaken}
        firstPlayer: 0,
        activePlayer: 0,
        phase: "gather",     // gather | orders | move | gameover
        gatherActionsLeft: 3,// game_begin_turn resets this per turn (3 first turn, else 2)
        dayNumber: 1,
        dayTrack: 1,
        solo: false,         // scenarios set their own; false = normal 2-player (day flips seats)
        decks: { gather: [], gatherDiscard: [], treasure: [], enemy: [], enemyDiscard: [] },
        sprays: [],          // {playerIdx, lane, idx} - ultra-spicy tokens
        mines: [],           // {lane, idx, dmg} - arm at 10 pass-damage, then kill enders
        decoys: [],          // {playerIdx, lane, idx, hp} - pikpik carrots soak enemy damage
        pendingFree: [],     // {playerIdx, count} - boss bounty free hazard placements, killer first
        pendingDiscard: undefined, // {playerIdx, need} - hand-limit overflow, owner picks; handoff waits
        departing: [],       // {cards, playerIdx, lane, fromIdx, total} - piles animating home, scored on arrival
        fx: [],              // presentation death events, drained by the controller (cosmetic; rules ignore it)
        resolveQueue: [],    // pending resolution beats (controller pumps game_resolve_step)
        jumpCue: "",         // "" | "pik" | "enemy" - renderer makes that side's fighters wind up
        bombCue: undefined,  // {lane, idx} - Bomb Rock/Boulder telegraph target (strobe + ring)
        sprayCue: false,     // spicy ignition beat - sprayed friendlies glow red
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
    _g.dayTrack = global.rules.dayTrackLength;   // full track -> turn 1 ends day 1, spawns enemies
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
