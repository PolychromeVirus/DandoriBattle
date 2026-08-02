frameTick += 1;

music_sync();   // start/stop/switch the map's day track (silent in menus + when the map has no music)

// menu / pause SFX on state change: entering any sub-screen (or opening pause) = open, returning to
// the title (or resuming) = close.
if (menuScreen != prevMenuScreen) { sfx(menuScreen == "main" ? "sfxMenuClose" : "sfxMenuOpen"); prevMenuScreen = menuScreen; }
if (paused != prevPaused)         { sfx(paused ? "sfxMenuOpen" : "sfxMenuClose"); prevPaused = paused; }

// drain queued one-shot SFX (game.sfxCue, pushed by the engine at events). Play only a COUPLE per
// frame + a slight random pitch, so a burst (e.g. several pikmin dying) lands as offset hits rather
// than one phase-aligned slam. The rest carry to the next frame(s). Batch runs: no audio, just clear.
if (game != undefined && variable_struct_exists(game, "sfxCue") && array_length(game.sfxCue) > 0) {
    if (batchRemaining <= 0) {
        // banks + on-bank effects are headline events: pull them out and play them NOW at high
        // priority (12) so a swarm of low-priority attack swipes can't steal their voice, and
        // don't spend the 2/frame budget on them. Everything else drains a couple per frame.
        // Entries may be a bare name (centred) or a {n,l,i} struct (positional) - snd_play_cue handles both.
        var _si = 0;
        while (_si < array_length(game.sfxCue)) {
            var _e = game.sfxCue[_si];
            var _en = is_struct(_e) ? _e.n : _e;
            if (_en == "sfxBank" || _en == "sfxBankEffect") {
                snd_play_cue(_e, 12, random_range(0.97, 1.03));
                array_delete(game.sfxCue, _si, 1);
            } else _si += 1;
        }
        var _sqBudget = min(2, array_length(game.sfxCue));
        for (var _sq = 0; _sq < _sqBudget; _sq++) {
            var _ce = game.sfxCue[_sq];
            var _cn = is_struct(_ce) ? _ce.n : _ce;
            // 2/frame drain already staggers a burst; fall gets a WIDER pitch spread so tumbling pikmin overlap
            var _cpitch = (_cn == "fall1") ? random_range(0.82, 1.18) : random_range(0.95, 1.05);
            snd_play_cue(_ce, 8, _cpitch);
        }
        array_delete(game.sfxCue, 0, _sqBudget);
    } else {
        game.sfxCue = [];
    }
}

// keep the render + GUI at the window's native resolution (crisp fullscreen). MUST
// sit above the mode!="playing" exit so the board-select menu is sharp too. Fires
// only when the window size actually changes (startup / F11 / manual resize).
if (window_get_width() != lastWinW || window_get_height() != lastWinH) sync_resolution();

// menu mode: nothing to simulate (board select is click-driven in the GUI event),
// but the main title screen runs a decorative 3D background - advance its actors and
// build a low, slowly-drifting "sitting on the field" camera so it renders behind the menu.
if (mode != "playing") {
    if (menuScreen == "main") {
        if (keyboard_check_pressed(vk_f1)) titleHideHud = !titleHideHud; // screensaver: show/hide menu HUD
        title_scene_update(titleScene);
        var _ttx  = 45 * dsin(frameTick * 0.15);   // gentle lateral target drift
        var _tyaw = 270 + 4 * dsin(frameTick * 0.10); // slow yaw sway
        var _tpit = 6;                               // very low: horizon drops to ~40% down, sky clears the title
        var _tdst = 540;
        var _tcx = _ttx + dcos(_tyaw) * dcos(_tpit) * _tdst;
        var _tcy =        dsin(_tyaw) * dcos(_tpit) * _tdst;
        var _tcz =        dsin(_tpit) * _tdst;
        viewMat = matrix_build_lookat(_tcx, _tcy, _tcz, _ttx, 0, 0, 0, 0, 1);
        projMat = matrix_build_projection_perspective_fov(-60, -window_get_width() / window_get_height(), 1, 32000);
        camera_set_view_mat(camera, viewMat);
        camera_set_proj_mat(camera, projMat);
    }
    exit;
}

// Esc: cancel active targeting first; otherwise open/close the pause menu. While paused the
// whole game is frozen here (only the pause-menu buttons, drawn in the GUI event, respond).
if (keyboard_check_pressed(vk_escape)) {
    if (paused) {
        paused = false;
    } else if (selSrc != undefined || pelletMenuIdx >= 0 || posyMenuIdx >= 0 || pendingCard != undefined) {
        selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; pendingCard = undefined;
    } else {
        paused = true;
    }
}
if (paused) exit;

// online (mirror side): adopt any full state the opponent broadcast. boardDef travels with it, so
// net_apply_state rebuilds the board buffers. Set netLastSent from OUR serialization of the adopted
// state so we never echo it straight back to them.
if (net_online() && (ctl[0] == "remote" || ctl[1] == "remote") && global.net.pendingState != undefined) {
    net_apply_state(global.net.pendingState);
    netLastSent = net_serialize_game(game);
    global.net.pendingState = undefined;
}

// tutorial: action steps auto-advance on their done() condition; fail-and-retry steps reset to
// their checkpoint. Intro steps advance via the Continue button (Draw). See tutorial_tick (Create).
if (tutorial != undefined) {
    tutorial_tick();
    if (tutorial == undefined) { return_to_menu(); exit; }   // tutorial just finished (action-step finale) -> menu
}

// gather-phase softlock guard: if the active human can't roll (the tutorial hides it) AND the gather
// deck is truly empty (drawing can never produce a card), there's no way to spend a gather action -
// so end the phase early instead of stranding them. Keys on the EMPTY DECK, not on the buttons being
// hidden (Draw may appear on a later step). Never fires in a normal game - rolling is always up.
if (game.phase == "gather" && ctl[game.activePlayer] == "human" && !tutorial_roll_shown()
    && array_length(game.decks.gather) == 0 && array_length(game.decks.gatherDiscard) == 0) {
    game.phase = "orders";
}

// --- toggles ---
if (keyboard_check_pressed(vk_space)) autoOrbit = !autoOrbit;
if (keyboard_check_pressed(vk_f11)) window_set_fullscreen(!window_get_fullscreen());
if (keyboard_check_pressed(vk_tab))   showDebug = !showDebug;
if (keyboard_check_pressed(ord("V")))  showCollection = !showCollection;
if (keyboard_check_pressed(vk_f1)) { // cycle P2's controller mid-game
    ctl[1] = (ctl[1] == "human") ? "v1" : ((ctl[1] == "v1") ? "v2" : ((ctl[1] == "v2") ? "v3" : ((ctl[1] == "v3") ? "v3b" : ((ctl[1] == "v3b") ? "v4" : "human"))));
    game_log(game, "P2 controller: " + ctl[1]);
    ai_dbg("### F1: P2 controller -> " + ctl[1] + " ###");   // diagnostic brain swap, logged to ai_debug.txt
}
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
// F12: BATCH - EVERY board back-to-back, unattended (~1.5-2 hr). For long AFK runs.
// Same matrix-per-board output to sim_bench.txt + CSV; Esc stops the whole batch.
if (keyboard_check_pressed(vk_f12)) {
    sim_tournament_run_boards(["familiargrotto", "stonesweptvalley", "undergroundplateau", "frozenriverbank",
        "floodedgarden", "scorchedplayground", "frigidwasteland", "theburrow", "thedoghouse", "theminefield",
        "hauntingswampland", "pricklypasture", "trickystaircase", "thehillswitheyesandteeth", "discodancefloor",
        "meadowofmelancholy"], 100);
}
// F9: run the fast scenario tests (decision-node logic checks) -> sim_bench.txt +
// console. Instant. This is the build-one-piece-at-a-time verification loop.
if (keyboard_check_pressed(vk_f9)) { sim_run_scenarios(); }
// F7: probe - ONE seeded planner-vs-base game with the full decision log kept
// (ai_debug.txt). ~2-3 seconds. The autopsy tool for tournament losers.
// Headless probe of the CURRENTLY-LOADED board, verbose log -> ai_debug.txt (+ result to
// sim_bench.txt). No HUD clutter. Currently pointed at the v3b ACHIEVEMENT brain:
//   F7 = cascade2(v3b,P1) vs base(v2,P2), FIXED seed (does v3b work vs the control)
//   F5 = cascade2(v3b,P1) vs cascade(v3,P2), RANDOM seed (the real question: v3b vs cascade)
if (keyboard_check_pressed(vk_f7)) sim_probe(boardDef.id, "v4", "base", 20260717);
if (keyboard_check_pressed(vk_f5)) sim_probe(boardDef.id, "v4", "cascade", 20260717 + irandom(99));
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
        music_stop();          // silence the old track; music_sync keeps it quiet until the cinematic ends
        sfx("sfxWhistle");     // the Pikmin whistle as the day turns over
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
            for (var _s = 0; _s < array_length(game.board.lanes[_l].spaces); _s++) {
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
    if (ctl[game.pendingDiscard.playerIdx] != "human" && ctl[game.pendingDiscard.playerIdx] != "remote") {
        aiTickTimer += 1;
        if (aiTickTimer >= (global.expRules.anims ? 20 : 1)) {
            aiTickTimer = 0;
            if (ctl[game.pendingDiscard.playerIdx] == "v4") ai4_resolve_discard(game);
            else ai_resolve_discard(game);
        }
    } else {
        aiTickTimer = 0;
    }
} else
if (game.phase != "gameover" && array_length(game.pendingFree) > 0 && ctl[game.pendingFree[0].playerIdx] != "human" && ctl[game.pendingFree[0].playerIdx] != "remote") {
    aiTickTimer += 1;
    if (aiTickTimer >= (global.expRules.anims ? 20 : 1)) {
        aiTickTimer = 0;
        var _fhb = ctl[game.pendingFree[0].playerIdx];
        if (_fhb == "v3" || _fhb == "v3b" || _fhb == "v4") ai3_place_free_hazard(game); else if (_fhb == "v2") ai2_place_free_hazard(game); else ai_place_free_hazard(game);
    }
} else
// --- AI turn: perform one chunk every ~third of a second so it's watchable. A "remote" seat is
// NOT an AI - it waits for the opponent's networked state (Phase 2), so it's excluded here. ---
if (game.phase != "gameover" && ctl[game.activePlayer] != "human" && ctl[game.activePlayer] != "remote" && array_length(game.pendingFree) == 0) {
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
            if (settleHold >= 25) { settleHold = 0; aiTickTimer = 0; if (_brain == "v3") ai3_step(game); else if (_brain == "v3b") ai3b_step(game); else if (_brain == "v4") ai4_step(game); else if (_brain == "v2") ai2_step(game); else ai_step(game); }
        } else {
            aiTickTimer = 0;
            if (_brain == "v3") ai3_step(game); else if (_brain == "v3b") ai3b_step(game); else if (_brain == "v4") ai4_step(game); else if (_brain == "v2") ai2_step(game); else ai_step(game);
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
    camTargetX = clamp(camTargetX + _panX * _panSpeed, panMinX, panMaxX);
    camTargetY = clamp(camTargetY + _panY * _panSpeed, panMinY, panMaxY);
}

// --- camera position from spherical coordinates, z-up ---
var _camX = camTargetX + dcos(camYaw) * dcos(camPitch) * camDist;
var _camY = camTargetY + dsin(camYaw) * dcos(camPitch) * camDist;
var _camZ = camTargetZ + dsin(camPitch) * camDist;

viewMat = matrix_build_lookat(_camX, _camY, _camZ, camTargetX, camTargetY, camTargetZ, 0, 0, 1);
projMat = matrix_build_projection_perspective_fov(-60, -window_get_width() / window_get_height(), 1, 32000);
camera_set_view_mat(camera, viewMat);
camera_set_proj_mat(camera, projMat);

// spatial audio: the ear sits at the camera looking at its target (up = world z). Derived from the
// real eye->target, so the seat-2 lateral flip is already baked in - left/right pan matches the view.
audio_listener_position(_camX, _camY, _camZ);
// up = world -z: GM's audio space is opposite-handed to the render, so this un-mirrors L/R pan
audio_listener_orientation(camTargetX - _camX, camTargetY - _camY, camTargetZ - _camZ, 0, 0, -1);

// online (authoritative side): broadcast our state whenever it actually changes. Serialize once per
// frame and only send on a real diff. `_my || netWasMyTurn` covers our whole turn PLUS the turn-flip
// state after we resolve (so the peer learns it's their turn) - and stops the joiner from blasting
// its placeholder during the host's turn. netLastSent is set on both send AND mirror, so no echo.
if (net_online() && (ctl[0] == "remote" || ctl[1] == "remote")) {
    var _my = (game.activePlayer == global.net.localSeat);
    var _resolving = array_length(game.resolveQueue) > 0;
    // During a resolve, send only the COMMITTED pre-resolve state, then hush and let both sides play
    // the (deterministic) resolution locally - that's what kills the mid-animation stutter. And never
    // rebroadcast a resolve we're merely REPLAYING off the wire (the peer sends the authoritative final).
    if ((_my || netWasMyTurn) && !(_resolving && netResolveSent) && !netMirrorResolving) {
        var _s = net_serialize_game(game);
        if (_s != netLastSent) {
            net_send(NETMSG.state, _s);
            netLastSent = _s;
            if (_resolving) netResolveSent = true;
        }
    }
    if (!_resolving) netResolveSent = false;
    netWasMyTurn = _my;
}
