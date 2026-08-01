// M6: board-select menu + playable build - rules engine + mode-7 presentation.

// --- data + mode ---
data_load_all();
randomize();
net_init();             // P2P connection state (global.net); Async - Networking event drives it

mode = "menu";          // "menu" | "playing"
menuScreen = "main";    // when mode=="menu": "main" (title) | "board" (board select) | "options" | "online" | "adventure"
menuBoardIdx = 0;       // board-select: index of the previewed board in global.boardData.boards
menuListScroll = 0;     // board-select: top row index of the scrolling board list
menuAdvIdx = 0;         // chapter-select: index of the previewed adventure board (flat across scenarios)
menuAdvScroll = 0;      // chapter-select: top row index of the scrolling chapter/board list
menuNetName = "Player"; // online lobby: local player name field
menuNetIP   = "127.0.0.1"; // online lobby: host IP to join
menuNetField = "";      // which lobby text field has focus: "" | "name" | "ip"
netLastSent = "";       // serialized state we last broadcast/adopted (only re-send on real change)
netWasMyTurn = false;   // was it our seat's turn last frame (so we still broadcast the turn-flip state)
netResolveSent = false; // we've broadcast the committed pre-resolve state; hush during the pump
netMirrorResolving = false; // we're REPLAYING a resolve received off the wire - don't rebroadcast it
game = undefined;
board = undefined;
boardDef = undefined;

// --- menu state ---

// --- UI / selection state ---
selSrc = undefined;   // undefined | {kind:"home"} | {kind:"space", lane, idx}
selCounts = {};       // colour -> count chosen to move
defaultSelectAll = global.settings.defaultSelectAll; // false = new selections start at NONE; true = start at ALL
pelletMenuIdx = -1;   // pellet hand index with an open redeem menu
posyMenuIdx = -1;     // gather hand index with an open Color Changing Posy menu
pendingCard = undefined; // {handIdx, cardId, effectId, stage, lane, idx, purples, whites} - gather card targeting
freeBuild = "";       // emitter type selected for a boss-bounty free hazard placement

// --- day-transition cinematic ---
dayCine = undefined;  // undefined | {phase:"flash"|"walk"|"reveal", timer, revealN} - plays on a new day
prevDayNumber = 1;    // last day we saw, to detect the sunset rollover

// --- death FX (animated spirits / enemy squash, drained from game.fx) ---
fxList = [];

// --- animation pacing ---
presMoving = false;   // set by Draw when any pikmin/pile is still sliding; play waits on it
settleHold = 0;       // frames the board has been still - AI holds this long before resolving
resolveHold = 0;      // stillness frames between resolution beats (the beat pump)
biteT = 0;            // 0..1 - enemies stay sunk/shaking through the bite, easing back up as it decays
biteKind = "";        // which section set biteT: "swift" or "enemy" (so only that section's biters hold the crouch)
prevActive = 0;       // last-seen active player, to detect a turn handoff
turnSettling = false; // true while a just-ended turn's animations settle before the next player acts
turnSettleFrames = 0; // frames of stillness accumulated for the handoff settle
gameoverSettled = false; // true once the end-of-game board has settled and the result is final
gameoverHold = 0;     // stillness frames for the game-over settle (own counter - settleHold gets clobbered)

// --- per-seat controllers: "human" | "v1" | "v2" (AI brains drive through the
// --- same engine API, so any seat mix works - incl. AI vs AI) ---
ctl = ["human", "v4"];                       // live assignment (resolved brains) for the running game
menuCtl = variable_clone(global.settings.ctl); // menu selection: "human" or a difficulty tier (easy/medium/hard)
aiTickTimer = 0;

// apply the saved fullscreen preference at boot (Step's size-change check syncs resolution)
if (global.settings.fullscreen != window_get_fullscreen()) window_set_fullscreen(global.settings.fullscreen);

// push the current menu-owned option state into global.settings and persist to disk.
// called after any option change on the menu screens (rule toggles write global.expRules directly).
save_settings = function() {
    global.settings.ctl = [menuCtl[0], menuCtl[1]];
    global.settings.defaultSelectAll = defaultSelectAll;
    global.settings.fullscreen = window_get_fullscreen();
    settings_save();
};

// --- batch runner: N fast AI-vs-AI games back to back, results appended to
// --- batch_results.txt in the save dir (board,p1ctl,p2ctl,p1score,p2score,winner) ---
batchRemaining = 0;
batchArm = false;           // menu: armed -> next board click runs the batch
batchSavedAnims = true;
hoverKind = "";       // "" | "space" | "home"
hoverLane = -1;
hoverIdx = -1;
showDebug = false;
paused = false;         // Esc opens the in-game pause menu (game frozen while up)
tutorial = undefined;   // undefined | {steps:[{text,done}], cur} - guided tutorial overlay
tutorialSavedExpRules = undefined; // snapshot of global.expRules while the tutorial forces its preset
compactBoard = false;   // tutorial's clean lesson view: strip ALL table dressing (onions/decks/hordes/hands).
                        // STABLE across the whole tutorial (unlike tutorial!=undefined, which clears on completion);
                        // NOT solo - adventure/co-op keeps its own onion + gather deck (only P2's onion is 2-player).
showCollection = false; // V toggles the dual collected-treasure side panels
logScroll = 0;          // pixels the log is scrolled UP from newest-at-bottom (wheel over the panel)

// --- camera (spherical orbit around the board centre) ---
camYaw    = 270;
camPitch  = 52;
camDist   = 900;
camTargetX = 0;
camTargetY = 0;
camTargetZ = 0;
autoOrbit = false;
// WASD pan bounds - recomputed per board from its extent (cam_pan_limits); legacy defaults here.
panMinX = -620; panMaxX = 620;
panMinY = -520; panMaxY = 520;

camera = camera_create();
view_enabled    = true;
view_visible[0] = true;
view_set_camera(0, camera);

viewMat = matrix_build_identity();
projMat = matrix_build_identity();

// --- static geometry ---
groundVB = build_ground(20, 14, 64, board_ground_palette(1)); // menu default; retinted per board
tileVB   = -1; // rebuilt per board when a game starts

// --- living title background: a decorative 3D checker field with Pikmin wandering
// --- across it, drawn behind the main menu (see title_scene_* in scr3D). Built once,
// --- on a random board set (skipping the two too-dark/busy skies). ---
titleScene = title_scene_create(title_random_set());
titleHideHud = false;   // F1 on the main title toggles this: hide ALL menu HUD to just watch the field

// --- gpu state that can stay on permanently ---
gpu_set_cullmode(cull_noculling);
gpu_set_texfilter(true);

frameTick = 0;
dragPrevX = window_mouse_get_x();
dragPrevY = window_mouse_get_y();

// --- crisp fullscreen: render the 3D + GUI at the window's NATIVE resolution ---
// The app surface (3D scene) and GUI default to the 1366x768 room size and get
// bilinear-scaled up when fullscreen -> blur. Resize the app surface to the window,
// and maximise the GUI keeping a FIXED logical HEIGHT of 768 (design) with a variable
// width, rendered at native pixels. HUD layout is unchanged (its X is gui-width
// relative, its Y absolute against 768); device_mouse_*_to_gui stays in the 768-tall
// space so all picking still matches. Driven by a size-change check in Step (covers
// startup, F11, and manual window resizing) - see objGame Step.
#macro DESIGN_H 768
lastWinW = -1;
lastWinH = -1;
sync_resolution = function() {
    var _w = window_get_width(), _h = window_get_height();
    if (_w <= 0 || _h <= 0 || !surface_exists(application_surface)) return; // retry next frame
    surface_resize(application_surface, _w, _h);
    var _scale = _h / DESIGN_H;                 // logical stays 768-tall; rendered at native
    display_set_gui_maximise(_scale, _scale);
    lastWinW = _w; lastWinH = _h;
};

// Which seat's perspective the camera + ground decals should face. Online: our own seat (the
// joiner sits at P2, so they view/orient from the red side). Hotseat (both human, future): whoever's
// turn it is. Otherwise (vs AI): the human seat, which is P1 unless the human is explicitly seat 1.
view_seat = function() {
    if (net_online() && (ctl[0] == "remote" || ctl[1] == "remote")) return global.net.localSeat;
    if (ctl[0] == "human" && ctl[1] == "human") return game.activePlayer;
    return (ctl[0] != "human" && ctl[1] == "human") ? 1 : 0;
};

// Recompute the WASD pan bounds from the current board's extent, so long adventure lanes stay
// reachable while the stock boards keep (at least) their legacy hand-tuned range. Call after a
// board loads and the camera target is set.
cam_pan_limits = function() {
    // slacks chosen so a stock 7-space board reproduces the old hand-tuned +/-520 (Y) / +/-620 (X)
    // exactly (its home edge sits ~336px out, +184 = 520; a 5-lane half-width ~325, +295 = 620),
    // while longer/wider boards expand to keep their far rows reachable.
    var _halfW = board.laneCount * (TILE_W + LANE_GAP) * 0.5;
    var _b = board_bounds_y(board, game.solo);
    panMaxX =  max(620, _halfW + 295);
    panMinX = -panMaxX;
    panMaxY =  max(520, _b.maxY + 184);
    panMinY =  min(-520, _b.minY - 184);
};

// Fit the FULL renderer's camera + ground slab to the whole board (the adventure/long-board analog of
// frame_compact_board, which is tutorial-only). Recenters on the board midpoint, rebuilds the ground
// to cover it, and pulls the camera back to frame the full span. Call after start_game for a solo /
// irregular board; the stock 2-player boards keep start_game's fixed camera + 20x14 ground.
frame_board = function() {
    var _b = board_bounds_y(board, game.solo);
    var _cyMid = (_b.minY + _b.maxY) * 0.5;
    var _spanY = _b.maxY - _b.minY;
    vertex_delete_buffer(groundVB);
    // 20 cols = the stock boards' panel width (~+/-640). Every board is 5 lanes, so the side furniture
    // - onion/horde discs and deck stacks out at |x|~440-530 - lands ON the panel just like normal.
    // Rows scale with the board's length (never below the stock 14) so long lanes stay on the panel.
    var _rows = max(14, ceil((_spanY + 300) / 64));
    groundVB = build_ground(20, _rows, 64, board_ground_palette(boardDef.setNumber), 0, _cyMid);
    camTargetX = 0;
    camTargetY = _cyMid;
    camDist    = clamp(_spanY + 350, 800, 1800);
    camPitch   = 52;
    camYaw     = (view_seat() == 1) ? 90 : 270;
    cam_pan_limits();
};

// launch a game on a board id, resetting view + selection state.
// _ctl: optional seat assignment; defaults to the menu's selection.
start_game = function(_boardId, _ctl = undefined, _scenario = undefined, _keepTutorial = false) {
    if (tileVB != -1) vertex_delete_buffer(tileVB);
    card_sprites_free();
    game = game_new(_boardId, _scenario);
    boardDef = game.boardDef;
    board = game.board;
    var _bid = boardDef.id;   // scenarios carry no board id arg; read it back from the built game
    tileVB = board_build_tile_vb(board, game.solo);
    vertex_delete_buffer(groundVB); // retint the ground to the board's theme
    groundVB = build_ground(20, 14, 64, board_ground_palette(boardDef.setNumber));
    // menu picks Human / difficulty tier; resolve each seat to a concrete brain for THIS board.
    var _seats = (_ctl != undefined) ? _ctl : menuCtl;
    ctl = [seat_brain(_bid, _seats[0]), seat_brain(_bid, _seats[1])];
    game.trace = [ctl[0] == "human", ctl[1] == "human"]; // human seats get decision-traced to ai_debug.txt
    // record what's actually driving each seat (and the tier it resolved from) in ai_debug.txt
    var _seatLbl = function(_tok, _brain) { return (_tok == _brain) ? _brain : (_tok + "->" + _brain); };
    ai_dbg("");
    ai_dbg("### GAME START  board " + _bid + "  P1=" + _seatLbl(_seats[0], ctl[0]) + "  P2=" + _seatLbl(_seats[1], ctl[1]) + " ###");
    mode = "playing";
    paused = false;
    if (!_keepTutorial) { tutorial = undefined; compactBoard = false; }   // a normal game clears the tutorial overlay + clean-board view; a tutorial scene-load keeps them
    selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined; freeBuild = "";
    dayCine = undefined; prevDayNumber = 1;
    fxList = [];
    presMoving = false; settleHold = 0; resolveHold = 0; biteT = 0; biteKind = "";
    prevActive = game.activePlayer; turnSettling = false; turnSettleFrames = 0; gameoverSettled = false; gameoverHold = 0;
    if (batchRemaining <= 0) { // batch rounds keep the camera (let it orbit while it grinds)
        // seat 2 (a local human on the red side) starts orbited 180 deg to face the board from THEIR side
        camYaw = (view_seat() == 1) ? 90 : 270; camPitch = 52; camDist = 900;
        camTargetX = 0; camTargetY = 0; camTargetZ = 0;
    }
    cam_pan_limits();
    aiTickTimer = 0;
};

// launch an ONLINE game: the host is seat 0 (local human) vs the remote at seat 1; the joiner is
// seat 1 (local human) vs the remote host at seat 0. A "remote" seat waits for network state
// instead of running the AI (see Step). Turn sync itself is Phase 2.
start_game_online = function(_boardId, _isHost) {
    start_game(_boardId, _isHost ? ["human", "remote"] : ["remote", "human"]);
    netLastSent = "";       // fresh game -> the host will broadcast it; the joiner will adopt the host's
    netWasMyTurn = false;
};

// DEV: launch the irregular solo adventure-geometry test board (full renderer, then fit the camera).
start_advtest = function() {
    start_game(undefined, ["human", "human"], scenario_advtest(), false);
    frame_board();
};

// Launch an ADVENTURE board (from the chapter select) as a solo home-anchored game, framed to fit.
start_adventure = function(_advBoard) {
    start_game(undefined, ["human", "human"], scenario_adventure(_advBoard), false);
    frame_board();
};

// Adopt a full game state received from the peer (the mirror side). boardDef travels in the state,
// so we rebuild the board buffers to match (handles random boards, whose layout differs per client).
net_apply_state = function(_json) {
    var _g = net_deserialize_game(_json);
    if (_g == undefined) return;
    game = _g;
    board = game.board;
    boardDef = game.boardDef;
    if (tileVB != -1) vertex_delete_buffer(tileVB);
    tileVB = board_build_tile_vb(board, game.solo);
    vertex_delete_buffer(groundVB);
    groundVB = build_ground(20, 14, 64, board_ground_palette(boardDef.setNumber));
    // the mirror doesn't own selection/targeting/fx - clear them so stale UI doesn't linger
    selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined; freeBuild = "";
    fxList = [];
    prevActive = game.activePlayer;
    // if the adopted state carries a live resolveQueue, this is a committed turn we now REPLAY
    // locally (deterministically) - suppress our own broadcasts until the peer's final state lands.
    netMirrorResolving = (array_length(game.resolveQueue) > 0);
};

// launch the guided tutorial. The tutorial is a sequence of SCENES (chapters), each a full solo
// scenario + its own ruleset + steps. Snapshot the player's expRules first; return_to_menu restores.
start_tutorial = function(_startScene = 0) {
    tutorialSavedExpRules = variable_clone(global.expRules);
    compactBoard = true;   // clean lesson board (stays set through completion until return_to_menu)
    var _scenes = tutorial_scenes();
    _startScene = clamp(_startScene, 0, array_length(_scenes) - 1);   // jump straight to a scene (testing / replay)
    tutorial = { scenes: _scenes, si: _startScene, cur: 0, checkpoint: undefined };
    tutorial_load_scene(tutorial.scenes[_startScene]);
};

// Load one tutorial scene: apply its ruleset (a fixed tutorial base + per-scene deltas), swap in
// its scenario as a fresh solo game (keeping the tutorial overlay), frame the compact board, and
// run the first step's side effects. Used by start_tutorial and by scene-to-scene advancement.
tutorial_load_scene = function(_scene) {
    // fixed tutorial base ruleset so guidance always matches outcomes (basic-colour powers off, no
    // rush, enemies don't heal; ice-freeze / uncapped bosses / explosion-damage on). `anims` left be.
    global.expRules.red = false;   global.expRules.blue = false;  global.expRules.yellow = false;
    global.expRules.rush = false;  global.expRules.enemyHeal = false;
    global.expRules.iceFreeze = true; global.expRules.bossCap = -1; global.expRules.explodeEnemies = true;
    if (variable_struct_exists(_scene, "rules")) {   // per-scene overrides (e.g. ch.2 turns rush ON)
        var _rk = variable_struct_get_names(_scene.rules);
        for (var _i = 0; _i < array_length(_rk); _i++) global.expRules[$ _rk[_i]] = _scene.rules[$ _rk[_i]];
    }
    start_game(undefined, ["human", "human"], _scene.scenario, true); // true = keep the tutorial overlay
    if (variable_struct_exists(_scene, "gatherActions")) game.gatherActionsLeft = _scene.gatherActions;
    if (variable_struct_exists(_scene, "startPhase"))    game.phase = _scene.startPhase; // e.g. skip gather when the hand is pre-dealt
    frame_compact_board();
    tutorial.checkpoint = undefined;
    tutorial_enter_step();   // apply the first step's side effects (e.g. checkpoint snapshot)
};

// frame the compact solo board: a floor slab that hugs just the board's rows, and the camera pulled
// in and re-centred on the board's midpoint (the board only occupies its owner's half).
// (camDist / camPitch / margins below are the tuning knobs.)
frame_compact_board = function() {
    var _pitch = TILE_H + TILE_GAP;
    var _yTop  = board_home_y(board, 0) - _pitch;                         // a touch behind the home strip
    var _yBot  = (board.maxSpaces - 1 - board.centerRow) * _pitch + _pitch; // a touch past the far (treasure) row
    var _cyMid = (_yTop + _yBot) * 0.5;
    var _tw    = board.laneCount * (TILE_W + LANE_GAP);
    vertex_delete_buffer(groundVB);
    groundVB = build_ground(ceil((_tw + 90) / 64), ceil((_yBot - _yTop + 90) / 64), 64,
                            board_ground_palette(boardDef.setNumber), 0, _cyMid);
    camTargetY = _cyMid;
    camDist    = 560;
    camPitch   = 54;
    cam_pan_limits();
};

// --- tutorial navigation helpers ---
tutorial_cur_scene = function() {
    if (tutorial == undefined || tutorial.si >= array_length(tutorial.scenes)) return undefined;
    return tutorial.scenes[tutorial.si];
};
// the step currently in view (or undefined if none / finished). Used by the banner + gating.
tutorial_step = function() {
    var _sc = tutorial_cur_scene();
    if (_sc == undefined || tutorial.cur >= array_length(_sc.steps)) return undefined;
    return _sc.steps[tutorial.cur];
};
// gather Draw button: shown outside the tutorial; inside, hidden until THIS scene reaches a step
// that opts in (showDraw:true), then sticky-shown for the rest of the scene.
tutorial_draw_shown = function() {
    if (tutorial == undefined) return true;
    var _sc = tutorial_cur_scene();
    if (_sc == undefined) return true;
    var _n = min(tutorial.cur + 1, array_length(_sc.steps));
    for (var _i = 0; _i < _n; _i++) {
        var _s = _sc.steps[_i];
        if (variable_struct_exists(_s, "showDraw") && _s.showDraw) return true;
    }
    return false;
};
// Roll button: shown by default; a step may hide it (hideRoll:true) to force a specific action.
tutorial_roll_shown = function() {
    var _s = tutorial_step();
    if (_s == undefined) return true;
    return !(variable_struct_exists(_s, "hideRoll") && _s.hideRoll);
};

// entering a step: run its one-time side effects (currently just the checkpoint snapshot used by
// the fail-and-retry steps). Called whenever tutorial.cur/si lands on a new step.
tutorial_enter_step = function() {
    var _s = tutorial_step();
    if (_s == undefined) return;
    if (variable_struct_exists(_s, "checkpoint") && _s.checkpoint) tutorial.checkpoint = variable_clone(game);
};

// advance one step; roll into the next scene (loading its game) when a scene's steps run out, and
// end the tutorial after the last scene.
tutorial_advance = function() {
    var _sc = tutorial_cur_scene();
    if (_sc == undefined) { tutorial = undefined; return; }
    tutorial.cur += 1;
    if (tutorial.cur < array_length(_sc.steps)) { tutorial_enter_step(); return; }
    tutorial.si += 1;
    if (tutorial.si >= array_length(tutorial.scenes)) { tutorial = undefined; return; }
    tutorial.cur = 0;
    tutorial_load_scene(tutorial.scenes[tutorial.si]); // loads the next scene's game + enters step 0
};

// fail-and-retry: restore the current scene's checkpoint (board state as of when the retry step was
// entered) without touching the board layout buffers or the step pointer - "reset, redraw, no dialog".
tutorial_restore_checkpoint = function() {
    if (tutorial == undefined || tutorial.checkpoint == undefined) return;
    game = variable_clone(tutorial.checkpoint);
    board = game.board; boardDef = game.boardDef;
    selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined; freeBuild = "";
    dayCine = undefined; prevDayNumber = game.dayNumber;
    fxList = []; presMoving = false;
    settleHold = 0; resolveHold = 0; biteT = 0; biteKind = "";
    prevActive = game.activePlayer; turnSettling = false; turnSettleFrames = 0; gameoverSettled = false; gameoverHold = 0;
    aiTickTimer = 0;
};

// per-frame tutorial logic (called from Step): action steps auto-advance on done(game); a step with
// failIf resets to its checkpoint when the attempt is judged a failure.
tutorial_tick = function() {
    var _s = tutorial_step();
    if (_s == undefined || _s.kind != "action") return;
    if (_s.done(game)) { tutorial_advance(); return; }
    if (variable_struct_exists(_s, "failIf") && _s.failIf(game, tutorial.checkpoint)) tutorial_restore_checkpoint();
};

// The tutorial script: an ordered list of SCENES. Each scene = { scenario: full-_g factory,
// rules?: expRules deltas, gatherActions?: override, steps: [...] }. A step is
// { kind:"intro"|"action", text, done?(g), showDraw?, hideRoll?, checkpoint?, failIf?(g, cp) }.
// intro = read + Continue; action = auto-advance when done(game). No input gating - board STATE
// shapes each lesson. (User-authored content.)
tutorial_scenes = function() {
    return [
        // ---- Scene 1: the basics (pellets, movement, elements, combat) ----
        { scenario: scenario_tutorial(), steps: [
            { kind: "intro", text: "Welcome to Dandori Battle! The classic game of Tug-of-War with Pikmin!" },
            { kind: "intro", text: "All actions in this game require assigning Pikmin - and to do that, you'll need reinforcements." },
            { kind: "action", text: "Roll the pellet die a few times to collect some Pellet Cards!",
              done: function(_g) { return array_length(_g.players[0].pellets) >= 3; } },
            { kind: "action", text: "Great. Now click your HOME tile - it highlights so you can pick which Pikmin to move, then click a space to send them (middle-click sends everything). Try moving a Pikmin onto each treasure.",
              done: function(_g) {
                  for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                      var _tr = _g.treasures[_ti];
                      var _has = false, _tk = _g.players[0].tokens;
                      for (var _i = 0; _i < array_length(_tk); _i++) {
                          var _lc = _tk[_i].loc;
                          if (_lc.kind == "space" && _lc.lane == _tr.lane && _lc.idx == _tr.idx) { _has = true; break; }
                      }
                      if (!_has) return false;
                  }
                  return array_length(_g.treasures) > 0;
              } },
            { kind: "intro", text: "Notice the element icons on the ground. Most Pikmin are immune to one element, and where the ground shows that icon, only they may pass. The Height space (left lane) is special: only certain Pikmin can climb it toward the centre - but anyone can come back down." },
            { kind: "action", text: "Now hit \"End Orders\" to enter the Move phase, then \"Resolve Moves & End Turn\" to let your Pikmin move.",
              done: function(_g) { return _g.dayNumber >= 2; } },
            { kind: "intro", text: "Day 2. Enemies respawn overnight on most maps, filling every enemy space. You can move freely in a lane, but you can't pass an enemy without defeating it - and you can't pass the treasure." },
            { kind: "action", text: "Grow some Pikmin and defeat one of the Bulborbs that spawned in. The green number is the Pikmin strength needed to defeat it; the red number is how many Pikmin it eats if it survives.",
              done: function(_g) {
                  if (_g.dayNumber < 2) return false;
                  var _live = 0;
                  for (var _l = 0; _l < _g.board.laneCount; _l++) {
                      var _sp = _g.board.lanes[_l].spaces;
                      for (var _s = 0; _s < array_length(_sp); _s++) { var _e = _sp[_s].enemy; if (_e != undefined && !_e.dead) _live += 1; }
                  }
                  return _live < 3;   // spawned 3, at least one defeated
              } },
            { kind: "intro", text: "One more rule of thumb for the Move phase: \"things move, then things die.\" Keep that order in mind when planning a turn. You've got the basics down - now let's look at moving treasures faster." },
        ] },
        // ---- Scene 2: items + the three ways a treasure moves twice ----
        // rush ON (needed for the 4-red method); 1 gather action so the draw = the single Spicy Spray.
        { scenario: scenario_tutorial2(), rules: { rush: true }, gatherActions: 1, steps: [
            // hideRoll through these intros so the player can't burn the single gather action before
            // the draw step (rolling is never needed in this scene anyway).
            { kind: "intro", hideRoll: true, text: "At the start of each turn you get 2-3 gather actions, each action lets you either draw a card, or roll the pellet die once." },
            { kind: "intro", hideRoll: true, text: "Gather cards are used after the orders phase, but before locking in your turn. After you hit 'End Orders' you have the option to play any green cards in your hand." },
            { kind: "action", text: "For now, you have 1 gather action remaining this turn, draw a card.",
              showDraw: true, hideRoll: true,
              done: function(_g) { return array_length(_g.players[0].hand) >= 1; } },
            // checkpoint here (entered the instant the draw completes) = the pristine retry state:
            // pikmin home, spray in hand, orders phase - before the player can touch anything.
            { kind: "intro", checkpoint: true, text: "In some cases, treasures can be moved two spaces at once. White pikmin move two spaces if they're the only pikmin type holding a treasure, if the 2x rush option is on then any pikmin can move two spaces if you have twice as many as you need, and using a spicy spray item on a treasure makes it act twice." },
            { kind: "action", text: "Try banking all three of these items in a single turn.",
              done: function(_g) { return array_length(_g.players[0].collected) >= 3; },
              failIf: function(_g, _cp) {
                  if (_cp == undefined) return false;
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false; // let the turn fully settle
                  return _g.players[0].turnsTaken > _cp.players[0].turnsTaken && array_length(_g.players[0].collected) < 3;
              } },
            // success beat: banking advances here (after resolution settles), Continue loads scene 3.
            { kind: "intro", text: "Great, on to the next lesson..." },
        ] },
        // ---- Scene 3: the treasure-pile system (weight = top card; Ship Signal / Survey Drone) ----
        // Starts in ORDERS (hand is pre-dealt, no gathering). checkpoint on the intro (taken at load,
        // before the player acts) so a failed attempt resets clean to orders phase / full hand / pile
        // reset. Success = the heavy item reaches home in the collected pile.
        { scenario: scenario_tutorial3(), startPhase: "orders", steps: [
            { kind: "intro", checkpoint: true, text: "In a real game, treasures aren't single cards, they're piles of around 500p. The weight of the pile is the card on top. You can use the Survey Drone or Ship Signal to change which item's weight is being used." },
            { kind: "action", text: "Bank this heavy item to continue.",
              done: function(_g) {
                  var _c = _g.players[0].collected;
                  for (var _i = 0; _i < array_length(_c); _i++) if (_c[_i] == "amplifiedamplifier") return true;
                  return false;
              },
              failIf: function(_g, _cp) {
                  if (_cp == undefined) return false;
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false; // let the turn fully settle
                  return _g.players[0].turnsTaken > _cp.players[0].turnsTaken;   // turn resolved; done() already ruled out success
              } },
            { kind: "intro", text: "Nicely done. One more lesson..." },
        ] },
        // ---- Scene 4: CRUSH/Rock -> chasm/Winged -> swift (discovery combat lesson) ----
        // Two lanes (see scenario_tutorial4). Starts in the MOVE phase (turn 1 = resolve+watch the
        // Reds die). A dialogue beat + checkpoint after each success; each action's failIf resets to
        // the latest checkpoint when the force is too thin to finish. Lane index 0 = the crush lane,
        // 1 = the chasm/swift lane. Helper reads inline (winged count, lane-treasure position).
        // rush RULE ON so a weight-1 treasure with 3 carriers hauls TWO spaces/turn (the first haul
        // is one turn, not three) - matches the intended pacing.
        { scenario: scenario_tutorial4(), startPhase: "move", rules: { rush: true }, steps: [
            // turn 1: forced demo - Reds kill the first Wollyhop but get stomped.
            { kind: "action", hideRoll: true, text: "Just you and a treasure. You've got twice as many Pikmin as you need, and there should be nothing in your way. Right? Take them out and claim the treasure!",
              done: function(_g) {
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  var _e1 = _g.board.lanes[0].spaces[0].enemy;
                  return _e1 == undefined || _e1.dead;
              } },
            {kind: "intro", text: "Oops."},
			// draw prompt: advances the instant a Candypop is in hand (not a Continue button).
            { kind: "action", checkpoint: true, showDraw: true, hideRoll: true, text: "If you lose all your Pikmin fighting the monsters, you won't have enough to carry the treasure home. Let's try drawing some cards.",
              done: function(_g) { return array_length(_g.players[0].hand) >= 1; } },
            // Rock the second Wollyhop, then carry the crush-lane treasure down to space 0. Checkpoint
            // here (post-draw) so a botched fight resets with the card already in hand.
            { kind: "action", checkpoint: true, showDraw: true, hideRoll: true, text: "Great! Now assign your remaining 3 Pikmin to the Wollyhop and end your Orders phase, then apply the Bud to turn them into Rocks - see what happens.",
              done: function(_g) {
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  for (var _i = 0; _i < array_length(_g.treasures); _i++) if (_g.treasures[_i].lane == 0) return _g.treasures[_i].idx <= 0; // reached space 0
                  return false;   // crush-lane treasure gone before space 0 shouldn't happen
              },
              failIf: function(_g, _cp) {
                  if (_cp == undefined) return false;
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  return array_length(_g.players[0].tokens) < 3;   // crushed too many Reds -> reset
              } },
            { kind: "intro", checkpoint: true, hideRoll: true, text: "Now it's time to think ahead. To get the other treasure, you'll need Pikmin that can cross chasms. Use a Candypop Bud on your 3 Rock Pikmin now and turn them into Winged Pikmin so you can use them next turn." },
            // turn them Winged and bank the crush-lane treasure. Reset if they end with < 2 flyers.
            { kind: "action", showDraw: true, hideRoll: true, text: "Turn your Rocks into Winged Pikmin before ending your turn.",
              done: function(_g) {
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  for (var _i = 0; _i < array_length(_g.treasures); _i++) if (_g.treasures[_i].lane == 0) return false; // crush-lane treasure not banked yet
                  var _w = 0; for (var _i = 0; _i < array_length(_g.players[0].tokens); _i++) if (_g.players[0].tokens[_i].typeId == "winged") _w += 1;
                  return _w >= 2;
              },
              failIf: function(_g, _cp) {
                  if (_cp == undefined) return false;
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  for (var _i = 0; _i < array_length(_g.treasures); _i++) if (_g.treasures[_i].lane == 0) return false; // not banked yet -> no reset
                  var _w = 0; for (var _i = 0; _i < array_length(_g.players[0].tokens); _i++) if (_g.players[0].tokens[_i].typeId == "winged") _w += 1;
                  return _w < 2;   // banked but too few flyers to take the swift -> reset
              } },
            { kind: "intro", checkpoint: true, hideRoll: true, text: "Now go after the last treasure. That enemy is SWIFT - it takes its combat turn before yours. Commit enough Pikmin that you can still kill it after it eats one of them." },
            // cross the chasm, kill the swift 1/1, and get the last treasure moving.
            { kind: "action", hideRoll: true, text: "Fly across the chasm, defeat the swift Shearwig, and get the last treasure moving.",
              done: function(_g) {
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  for (var _i = 0; _i < array_length(_g.treasures); _i++) if (_g.treasures[_i].lane == 1) return _g.treasures[_i].idx < 2; // moved off idx 2
                  return true;   // chasm-lane treasure banked also counts
              },
              failIf: function(_g, _cp) {
                  if (_cp == undefined) return false;
                  if (array_length(_g.resolveQueue) > 0 || array_length(_g.departing) > 0) return false;
                  var _sw = _g.board.lanes[1].spaces[1].enemy;
                  return (_sw != undefined && !_sw.dead) && array_length(_g.players[0].tokens) < 2; // lost the flyers to the swift -> reset
              } },
            { kind: "intro", hideRoll: true, text: "The third colour, Ice, freezes enemies. Attack a monster with Ice Pikmin equal to half its health, and it skips its next attack entirely." },
            { kind: "intro", hideRoll: true, text: "Freezing can be switched off in the settings, along with the other special Pikmin interactions that aren't part of the base rules." },
            { kind: "intro", hideRoll: true, text: "And that's the basics of combat. Enemies come with all sorts of attack elements, and most Pikmin are immune to some of them - check the pause menu (Esc) for a full reference." },
        ] },
    ];
};

return_to_menu = function() {
    mode = "menu";
    menuScreen = "main";
    tutorial = undefined;
    compactBoard = false;
    if (tutorialSavedExpRules != undefined) { global.expRules = tutorialSavedExpRules; tutorialSavedExpRules = undefined; } // restore the player's ruleset after a tutorial
    if (batchRemaining > 0) { batchRemaining = 0; global.expRules.anims = batchSavedAnims; } // cancel a running batch
    if (tileVB != -1) { vertex_delete_buffer(tileVB); tileVB = -1; }
    vertex_delete_buffer(groundVB);
    groundVB = build_ground(20, 14, 64, board_ground_palette(1));
    card_sprites_free();
    game = undefined; board = undefined; boardDef = undefined;
    // re-roll the living title backdrop on each quit-to-title (Options/Board back-outs
    // stay on the current theme - they never come through here). Free the old plane first.
    vertex_delete_buffer(titleScene.groundVB);
    titleScene = title_scene_create(title_random_set());
    titleHideHud = false;   // always come back to a visible menu
};
