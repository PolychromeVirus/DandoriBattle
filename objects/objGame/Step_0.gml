frameTick += 1;

// keep the render + GUI at the window's native resolution (crisp fullscreen). MUST
// sit above the mode!="playing" exit so the board-select menu is sharp too. Fires
// only when the window size actually changes (startup / F11 / manual resize).
if (window_get_width() != lastWinW || window_get_height() != lastWinH) sync_resolution();

// menu mode: nothing to simulate (board select is click-driven in the GUI event)
if (mode != "playing") exit;

// --- toggles ---
if (keyboard_check_pressed(vk_space)) autoOrbit = !autoOrbit;
if (keyboard_check_pressed(vk_f11)) window_set_fullscreen(!window_get_fullscreen());
if (keyboard_check_pressed(vk_tab))   showDebug = !showDebug;
if (keyboard_check_pressed(ord("V")))  showCollection = !showCollection;
if (keyboard_check_pressed(vk_f1)) { // cycle P2's controller mid-game
    ctl[1] = (ctl[1] == "human") ? "v1" : ((ctl[1] == "v1") ? "v2" : ((ctl[1] == "v2") ? "v3" : "human"));
    game_log(game, "P2 controller: " + ctl[1]);
}
if (keyboard_check_pressed(vk_escape)) { selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined; }
if (keyboard_check_pressed(vk_f2))    { return_to_menu(); exit; }
// F3: headless sim diagnostics on THIS board (scrSim). Runs its own games via
// game_new - never touches the live one - but blocks the frame for a few seconds.
// Results -> sim_bench.txt in the save dir + the debug console.
if (keyboard_check_pressed(vk_f3)) { sim_run_diagnostics(boardDef.id, ctl); }
// F4: policy tournament on THIS board (scrSim), INCREMENTAL: one sim game per
// frame, so the window stays live and Draw_64 shows a progress bar + ETA (Esc
// cancels with partial totals). Active roster 3 -> 9 pairings x 100 = 900 games
// (~5 min riverbank). Paired seeds; NOTE: seeds only replay within ONE BUILD
// (struct-key order shifts across rebuilds) - compare within a run, never across.
// Results -> sim_bench.txt (matrix) + sim_tourney.csv (rows).
if (keyboard_check_pressed(vk_f4)) { sim_tournament_begin(boardDef.id, 100); }
// F8: BATCH - run the 5 test boards back-to-back, unattended (~25-30 min total).
// Edit the list to pick different maps. Progress bar + ETA per board; Esc stops
// the whole batch. Results append to sim_bench.txt (matrix per board) + CSV.
if (keyboard_check_pressed(vk_f8)) {
    sim_tournament_run_boards(["frozenriverbank", "familiargrotto", "theminefield", "hauntingswampland", "undergroundplateau"], 100);
}
// F9: run the fast scenario tests (decision-node logic checks) -> sim_bench.txt +
// console. Instant. This is the build-one-piece-at-a-time verification loop.
if (keyboard_check_pressed(vk_f9)) { sim_run_scenarios(); }
// F7: probe - ONE seeded planner-vs-base game with the full decision log kept
// (ai_debug.txt). ~2-3 seconds. The autopsy tool for tournament losers.
// F7: autopsy the two catastrophic-board BLOWOUT losses (works from any board -
// sim_probe builds its own game). Both verbose logs -> ai_debug.txt.
if (keyboard_check_pressed(vk_f7)) {
    // Plateau is now THE outlier catastrophe (-293): cascade under-harvests a rich
    // board (banks ~85 vs base 3685). Autopsy the worst seed - orders-level.
    sim_probe("undergroundplateau", "cascade", "base", 20260738); // cascade 85 : 3685 base
}
// tournament pump: while a run is active, tick one game and hold the live game
// (AI, cinematics, input) - the sim uses its own game structs throughout
if (variable_global_exists("simTourney") && global.simTourney != undefined) {
    if (keyboard_check_pressed(vk_escape)) { sim_tournament_cancel(); exit; }
    sim_tournament_tick();
    exit;
}
// F6: lane audit on THIS board (scrSim) - v2's lane evaluator vs tournament ground
// truth over the same 60 seeded worlds. Static, ~a second, no games played.
if (keyboard_check_pressed(vk_f6)) { sim_lane_audit(boardDef.id, 60); }

// --- GAME OVER: the game ends as day 4 would begin. Let the board settle (last pile
// --- hauls home, pikmin still) BEFORE finalizing the score and revealing the result,
// --- so it doesn't snap. Auto-opens the treasure sidebars once settled. ---
if (game.phase == "gameover") {
    if (!gameoverSettled) {
        if (presMoving && global.expRules.anims) gameoverHold = 0; else gameoverHold += 1;
        if (gameoverHold >= (global.expRules.anims ? 25 : 1)) {
            game_finalize_gameover(game);
            gameoverSettled = true;
            showCollection = true; // reveal the collected-treasure side panels
            // batch runner: record the result and immediately roll the next game
            if (batchRemaining > 0) {
                var _bf = file_text_open_append("batch_results.txt");
                file_text_write_string(_bf, boardDef.id + "," + ctl[0] + "," + ctl[1] + ","
                    + string(game_realized_score(game, 0)) + "," + string(game_realized_score(game, 1)) + "," + string(game.winner));
                file_text_writeln(_bf);
                file_text_close(_bf);
                batchRemaining -= 1;
                if (batchRemaining > 0) {
                    start_game(boardDef.id, ctl);
                    exit;
                } else {
                    global.expRules.anims = batchSavedAnims;
                    game_log(game, "BATCH COMPLETE - results in batch_results.txt (save dir).");
                }
            }
        }
    }
    // fall through so the camera still works on the end screen; the blocks below are
    // all guarded against phase == "gameover"
}

// --- day-transition cinematic: fires when a new day dawns (sunset rollover) and
// --- freezes normal play while it plays out (flash -> pikmin walk home -> monsters
// --- reveal one at a time). The engine already sent pikmin home + refilled monsters. ---
if (game != undefined && game.phase != "gameover" && game.dayNumber > prevDayNumber && dayCine == undefined) {
    prevDayNumber = game.dayNumber;
    if (global.expRules.anims) {
        dayCine = { phase: "flash", timer: 0, revealN: 0 };
        // TODO: play the Pikmin 1 whistle SFX here once the sound asset is added
    } else {
        game_clear_spawn_marks(game); // no cinematic - new enemies just appear
    }
}
if (dayCine != undefined) {
    dayCine.timer += 1;
    if (dayCine.phase == "flash") {
        if (dayCine.timer >= 96) { dayCine.phase = "walk"; dayCine.timer = 0; }
    } else if (dayCine.phase == "walk") {
        if (dayCine.timer >= 150) { dayCine.phase = "reveal"; dayCine.timer = 0; }
    } else { // reveal the NEWLY-SPAWNED enemies one at a time (survivors + bosses stay put)
        var _enemyN = 0;
        for (var _l = 0; _l < game.board.laneCount; _l++) {
            for (var _s = 0; _s <= 6; _s++) {
                var _en = game.board.lanes[_l].spaces[_s].enemy;
                if (_en != undefined && variable_struct_exists(_en, "justSpawned") && _en.justSpawned) _enemyN += 1;
            }
        }
        if (dayCine.timer >= 18) {
            dayCine.timer = 0;
            dayCine.revealN += 1;
            if (dayCine.revealN >= _enemyN) { game_clear_spawn_marks(game); dayCine = undefined; }
        }
    }
}

// --- turn handoff settle: when a turn just ended and passed to the next player, hold
// --- that player until the previous turn's carries/combat/pile-home animations settle
// --- (so each turn "settles then hands off"). The per-group orders pacing is exempt -
// --- it's driven separately below and only fires within a turn, not at handoff. ---
if (dayCine == undefined && game.phase != "gameover") {
    if (game.activePlayer != prevActive) {
        prevActive = game.activePlayer;
        turnSettling = global.expRules.anims; // anims off: hand over instantly
        turnSettleFrames = 0;
    }
    if (turnSettling) {
        if (presMoving) turnSettleFrames = 0; else turnSettleFrames += 1;
        if (turnSettleFrames >= 25) turnSettling = false;
    }
} else {
    prevActive = game.activePlayer; // stay synced so cinematic/game-over don't re-trigger a settle
    turnSettling = false;
}

// --- resolution pump: the move phase resolves as BEATS (carry, wind-up jump, pikmin
// --- strike, enemy strike...). Fire one beat, then wait for walks + death spirits to
// --- clear plus a short breath, so every step reads as its own mini-scene. ---
if (array_length(game.resolveQueue) > 0 && dayCine == undefined) {
    if (!global.expRules.anims) {
        while (array_length(game.resolveQueue) > 0) game_resolve_step(game); // anims off: instant resolution
    } else {
        if (presMoving || array_length(fxList) > 0) resolveHold = 0; else resolveHold += 1;
        var _beatGap = (game.jumpCue != "" || game.bombCue != undefined || game.sprayCue) ? 34 : 16; // linger on wind-ups/telegraphs
        if (resolveHold >= _beatGap) { resolveHold = 0; game_resolve_step(game); }
    }
}

// --- boss bounty: the AI resolves its owed free-hazard placements first,
// --- regardless of whose turn it is (the queue blocks normal play) ---
if (dayCine != undefined || turnSettling || array_length(game.resolveQueue) > 0) {
    aiTickTimer = 0; // cinematic / handoff settle / staged resolution playing - hold the AI
} else
// --- hand-limit overflow: an AI seat picks its own discards (one per tick); a
// --- human seat resolves it via the modal picker in Draw_64 ---
if (game.phase != "gameover" && game.pendingDiscard != undefined) {
    if (ctl[game.pendingDiscard.playerIdx] != "human") {
        aiTickTimer += 1;
        if (aiTickTimer >= (global.expRules.anims ? 20 : 1)) {
            aiTickTimer = 0;
            ai_resolve_discard(game);
        }
    } else {
        aiTickTimer = 0;
    }
} else
if (game.phase != "gameover" && array_length(game.pendingFree) > 0 && ctl[game.pendingFree[0].playerIdx] != "human") {
    aiTickTimer += 1;
    if (aiTickTimer >= (global.expRules.anims ? 20 : 1)) {
        aiTickTimer = 0;
        var _fhb = ctl[game.pendingFree[0].playerIdx];
        if (_fhb == "v3") ai3_place_free_hazard(game); else if (_fhb == "v2") ai2_place_free_hazard(game); else ai_place_free_hazard(game);
    }
} else
// --- AI turn: perform one chunk every ~third of a second so it's watchable ---
if (game.phase != "gameover" && ctl[game.activePlayer] != "human" && array_length(game.pendingFree) == 0) {
    selSrc = undefined;
    pelletMenuIdx = -1;
    posyMenuIdx = -1;
    pendingCard = undefined;
    aiTickTimer += 1;
    if (aiTickTimer >= (global.expRules.anims ? 20 : 1)) {
        // Resolving the move phase carries + fights everything - hold it until the
        // pikmin deployed this turn have walked into position (plus a short beat), so
        // the resolution doesn't fire while they're mid-stride. Other steps (gather,
        // per-group orders) run at the normal pace. Anims off: no waiting at all.
        var _brain = ctl[game.activePlayer];
        if (game.phase == "move" && global.expRules.anims) {
            if (presMoving) settleHold = 0; else settleHold += 1;
            if (settleHold >= 25) { settleHold = 0; aiTickTimer = 0; if (_brain == "v3") ai3_step(game); else if (_brain == "v2") ai2_step(game); else ai_step(game); }
        } else {
            aiTickTimer = 0;
            if (_brain == "v3") ai3_step(game); else if (_brain == "v2") ai2_step(game); else ai_step(game);
        }
    }
} else {
    aiTickTimer = 0;
    settleHold = 0;
}

// --- camera controls: right-click drag orbits and tilts, wheel zooms ---
if (autoOrbit) camYaw += 0.15;
var _mouseX = window_mouse_get_x();
var _mouseY = window_mouse_get_y();
if (mouse_check_button(mb_right)) {
    camYaw   += (_mouseX - dragPrevX) * 0.35;
    camPitch  = clamp(camPitch + (_mouseY - dragPrevY) * 0.25, 15, 85);
    if (_mouseX != dragPrevX || _mouseY != dragPrevY) autoOrbit = false;
}
dragPrevX = _mouseX;
dragPrevY = _mouseY;
// wheel over the log panel scrolls the log (older entries); elsewhere it zooms
var _gW = display_get_gui_width();
var _mGuiX = device_mouse_x_to_gui(0);
var _mGuiY = device_mouse_y_to_gui(0);
var _logPanelX = _gW - 330;
var _logPanelBot = 40 + (16 * 14 + 10);
var _overLog = (_mGuiX >= _logPanelX && _mGuiX <= _gW - 8 && _mGuiY >= 40 && _mGuiY <= _logPanelBot);
if (_overLog) {
    if (mouse_wheel_up())   logScroll += 48; // reveal older entries (clamped in Draw against content height)
    if (mouse_wheel_down()) logScroll = max(0, logScroll - 48);
} else {
    if (mouse_wheel_up())   camDist = max(camDist - 60, 200);
    if (mouse_wheel_down()) camDist = min(camDist + 60, 1800);
}

// --- WASD pans the camera target across the board (screen-relative) ---
var _panSpeed = camDist * 0.016;
var _fwdX = -dcos(camYaw), _fwdY = -dsin(camYaw);   // camera -> target, on the ground plane
var _rgtX =  dsin(camYaw), _rgtY = -dcos(camYaw);   // screen right, on the ground plane
var _panX = 0, _panY = 0;
if (keyboard_check(ord("W"))) { _panX += _fwdX; _panY += _fwdY; }
if (keyboard_check(ord("S"))) { _panX -= _fwdX; _panY -= _fwdY; }
if (keyboard_check(ord("D"))) { _panX += _rgtX; _panY += _rgtY; }
if (keyboard_check(ord("A"))) { _panX -= _rgtX; _panY -= _rgtY; }
if (_panX != 0 || _panY != 0) {
    camTargetX = clamp(camTargetX + _panX * _panSpeed, -620, 620);
    camTargetY = clamp(camTargetY + _panY * _panSpeed, -520, 520);
}

// --- camera position from spherical coordinates, z-up ---
var _camX = camTargetX + dcos(camYaw) * dcos(camPitch) * camDist;
var _camY = camTargetY + dsin(camYaw) * dcos(camPitch) * camDist;
var _camZ = camTargetZ + dsin(camPitch) * camDist;

viewMat = matrix_build_lookat(_camX, _camY, _camZ, camTargetX, camTargetY, camTargetZ, 0, 0, 1);
projMat = matrix_build_projection_perspective_fov(-60, -window_get_width() / window_get_height(), 1, 32000);
camera_set_view_mat(camera, viewMat);
camera_set_proj_mat(camera, projMat);
