// M6: board-select menu + playable build - rules engine + mode-7 presentation.

// --- data + mode ---
data_load_all();
randomize();

mode = "menu";          // "menu" | "playing"
menuScreen = "main";    // when mode=="menu": "main" (title) | "board" (board select) | "options"
menuBoardIdx = 0;       // board-select: index of the previewed board in global.boardData.boards
menuListScroll = 0;     // board-select: top row index of the scrolling board list
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

camera = camera_create();
view_enabled    = true;
view_visible[0] = true;
view_set_camera(0, camera);

viewMat = matrix_build_identity();
projMat = matrix_build_identity();

// --- static geometry ---
groundVB = build_ground(20, 14, 64, board_ground_palette(1)); // menu default; retinted per board
tileVB   = -1; // rebuilt per board when a game starts

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

// launch a game on a board id, resetting view + selection state.
// _ctl: optional seat assignment; defaults to the menu's selection.
start_game = function(_boardId, _ctl = undefined) {
    if (tileVB != -1) vertex_delete_buffer(tileVB);
    card_sprites_free();
    game = game_new(_boardId);
    boardDef = game.boardDef;
    board = game.board;
    tileVB = board_build_tile_vb(board);
    vertex_delete_buffer(groundVB); // retint the ground to the board's theme
    groundVB = build_ground(20, 14, 64, board_ground_palette(boardDef.setNumber));
    // menu picks Human / difficulty tier; resolve each seat to a concrete brain for THIS board.
    var _seats = (_ctl != undefined) ? _ctl : menuCtl;
    ctl = [seat_brain(_boardId, _seats[0]), seat_brain(_boardId, _seats[1])];
    game.trace = [ctl[0] == "human", ctl[1] == "human"]; // human seats get decision-traced to ai_debug.txt
    // record what's actually driving each seat (and the tier it resolved from) in ai_debug.txt
    var _seatLbl = function(_tok, _brain) { return (_tok == _brain) ? _brain : (_tok + "->" + _brain); };
    ai_dbg("");
    ai_dbg("### GAME START  board " + _boardId + "  P1=" + _seatLbl(_seats[0], ctl[0]) + "  P2=" + _seatLbl(_seats[1], ctl[1]) + " ###");
    mode = "playing";
    paused = false;
    selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined; freeBuild = "";
    dayCine = undefined; prevDayNumber = 1;
    fxList = [];
    presMoving = false; settleHold = 0; resolveHold = 0; biteT = 0; biteKind = "";
    prevActive = game.activePlayer; turnSettling = false; turnSettleFrames = 0; gameoverSettled = false; gameoverHold = 0;
    if (batchRemaining <= 0) { // batch rounds keep the camera (let it orbit while it grinds)
        camYaw = 270; camPitch = 52; camDist = 900;
        camTargetX = 0; camTargetY = 0; camTargetZ = 0;
    }
    aiTickTimer = 0;
};

return_to_menu = function() {
    mode = "menu";
    menuScreen = "main";
    if (batchRemaining > 0) { batchRemaining = 0; global.expRules.anims = batchSavedAnims; } // cancel a running batch
    if (tileVB != -1) { vertex_delete_buffer(tileVB); tileVB = -1; }
    vertex_delete_buffer(groundVB);
    groundVB = build_ground(20, 14, 64, board_ground_palette(1));
    card_sprites_free();
    game = undefined; board = undefined; boardDef = undefined;
};
