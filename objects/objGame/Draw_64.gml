ui_frame_begin();
var _guiW = display_get_gui_width();
var _guiH = display_get_gui_height();

// ==================== TOURNAMENT PROGRESS ====================
// while the incremental tournament runs (Step_0 pumps one sim game per frame),
// the HUD is replaced by a progress readout - and exiting here also disables
// every click handler below, so nothing can poke the held live game
if (variable_global_exists("simTourney") && global.simTourney != undefined) {
    var _stT = global.simTourney;
    draw_set_alpha(0.75); draw_set_color(c_black);
    draw_rectangle(0, 0, _guiW, _guiH, false);
    draw_set_alpha(1);
    var _fracT = _stT.done / max(1, _stT.total);
    var _bwT = min(520, _guiW - 120);
    var _bxT = (_guiW - _bwT) * 0.5;
    var _byT = _guiH * 0.5 - 14;
    draw_set_color(make_color_rgb(50, 55, 60));
    draw_rectangle(_bxT, _byT, _bxT + _bwT, _byT + 28, false);
    draw_set_color(make_color_rgb(120, 200, 120));
    draw_rectangle(_bxT, _byT, _bxT + _bwT * _fracT, _byT + 28, false);
    draw_set_color(c_white);
    draw_rectangle(_bxT, _byT, _bxT + _bwT, _byT + 28, true);
    draw_set_halign(fa_center);
    draw_set_font(-1);
    var _elT = (get_timer() - _stT.t0) / 1000000;
    var _etaT = (_stT.done > 0) ? _elT * (_stT.total - _stT.done) / _stT.done : 0;
    draw_text(_guiW * 0.5, _byT - 24, "TOURNAMENT  " + string(_stT.boardId) + "   game " + string(_stT.done) + " / " + string(_stT.total) + "  (" + string(floor(_fracT * 100)) + "%)");
    draw_text(_guiW * 0.5, _byT + 38, "elapsed " + string(floor(_elT)) + "s    eta ~" + string(floor(_etaT)) + "s    Esc = cancel (keeps partial results)");
    draw_set_halign(fa_left);
    exit;
}

// ==================== BOARD SELECT MENU ====================
if (mode == "menu") {
    var _mgx0 = device_mouse_x_to_gui(0);
    var _mgy0 = device_mouse_y_to_gui(0);

    // title
    draw_set_font(fntPikmin);
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, 34, "DANDORI BATTLE", 3 * UI_TS, 3 * UI_TS, 0);
    draw_set_color(make_color_rgb(200, 210, 205));
    draw_text_transformed(_guiW * 0.5, 82, "Select a board", 1.2 * UI_TS, 1.2 * UI_TS, 0);
    draw_set_halign(fa_left);
    draw_set_font(-1);

    // per-seat controllers (cycle Human -> AI v1 -> AI v2) + the batch runner
    var _togW = 170, _togY = 104;
    var _ctlName = function(_c) { return (_c == "human") ? "Human" : ((_c == "v1") ? "AI v1" : "AI v2"); };
    var _cycle = function(_c) { return (_c == "human") ? "v1" : ((_c == "v1") ? "v2" : "human"); };
    if (ui_button(_guiW * 0.5 - _togW - 90, _togY, _togW, 28, "P1: " + _ctlName(menuCtl[0]))) menuCtl[0] = _cycle(menuCtl[0]);
    if (ui_button(_guiW * 0.5 - 85, _togY, _togW, 28, "P2: " + _ctlName(menuCtl[1]))) menuCtl[1] = _cycle(menuCtl[1]);
    // batch: arm it, then click a board - runs N fast AI games back to back
    if (ui_button(_guiW * 0.5 + 95, _togY, _togW + 30, 28, batchArm ? "BATCH x25 ARMED - pick board" : "Batch: run 25 AI games")) batchArm = !batchArm;

    // fullscreen toggle (top-right corner; F11 works everywhere too)
    if (ui_button(_guiW - 150, 12, 138, 28, window_get_fullscreen() ? "Windowed" : "Fullscreen")) {
        window_set_fullscreen(!window_get_fullscreen());
    }

    // experimental rule toggles (off by default; playtest rules)
    var _exW = 200, _exGap = 8, _exY = 138;
    var _exX0 = _guiW * 0.5 - (_exW * 6 + _exGap * 5) * 0.5;
    if (ui_button(_exX0, _exY, _exW, 26, "Reds Strike Twice: " + (global.expRules.red ? "ON" : "off"))) global.expRules.red = !global.expRules.red;
    if (ui_button(_exX0 + (_exW + _exGap), _exY, _exW, 26, "Blues Lifeguard: " + (global.expRules.blue ? "ON" : "off"))) global.expRules.blue = !global.expRules.blue;
    if (ui_button(_exX0 + (_exW + _exGap) * 2, _exY, _exW, 26, "Yellows Cross Chasms: " + (global.expRules.yellow ? "ON" : "off"))) global.expRules.yellow = !global.expRules.yellow;
    if (ui_button(_exX0 + (_exW + _exGap) * 3, _exY, _exW, 26, "2x Weight Rushes: " + (global.expRules.rush ? "ON" : "off"))) global.expRules.rush = !global.expRules.rush;
    if (ui_button(_exX0 + (_exW + _exGap) * 4, _exY, _exW, 26, "Enemies Heal At sunset: " + (global.expRules.enemyHeal ? "ON" : "off"))) global.expRules.enemyHeal = !global.expRules.enemyHeal;
    if (ui_button(_exX0 + (_exW + _exGap) * 5, _exY, _exW, 26, "Animations: " + (global.expRules.anims ? "ON" : "off"))) global.expRules.anims = !global.expRules.anims;

    // board grid
    var _boards = global.boardData.boards;
    var _cols = 4;
    var _cardW = 300, _cardH = 92, _gapX = 16, _gapY = 14;
    var _gridW = _cols * _cardW + (_cols - 1) * _gapX;
    var _gx0 = (_guiW - _gridW) * 0.5;
    var _gy0 = 176;
    for (var _i = 0; _i < array_length(_boards); _i++) {
        var _bd = _boards[_i];
        var _cx = _gx0 + (_i mod _cols) * (_cardW + _gapX);
        var _cy = _gy0 + (_i div _cols) * (_cardH + _gapY);
        var _hover = (_mgx0 >= _cx && _mgx0 < _cx + _cardW && _mgy0 >= _cy && _mgy0 < _cy + _cardH);
        if (_hover) global.uiMouseConsumed = true;

        draw_set_alpha(_hover ? 0.95 : 0.8);
        draw_set_color(_hover ? make_color_rgb(60, 78, 66) : make_color_rgb(44, 54, 48));
        draw_rectangle(_cx, _cy, _cx + _cardW, _cy + _cardH, false);
        draw_set_alpha(1);
        draw_set_color(_hover ? make_color_rgb(255, 224, 120) : make_color_rgb(110, 124, 116));
        draw_rectangle(_cx, _cy, _cx + _cardW, _cy + _cardH, true);

        draw_set_font(fntPikmin);
        draw_set_color(c_white);
        dtext(_cx + 12, _cy + 8, _bd.name);
        draw_set_font(-1);
        draw_set_color(make_color_rgb(180, 190, 184));
        draw_text(_cx + 12, _cy + 34, "Board " + string(_bd.setNumber) + "  -  " + _bd.difficulty);

        // basic-colour swatches
        var _sw = _cx + 12;
        for (var _c = 0; _c < array_length(_bd.basicColors); _c++) {
            draw_set_color(pikmin_tint(_bd.basicColors[_c]));
            draw_circle(_sw + 8, _cy + _cardH - 16, 7, false);
            draw_set_color(make_color_rgb(20, 24, 20));
            draw_circle(_sw + 8, _cy + _cardH - 16, 7, true);
            _sw += 20;
        }
        draw_set_color(c_white);

        if (_hover && mouse_check_button_pressed(mb_left)) {
            if (batchArm) {
                // batch: force both seats to AI (human seats become v1), kill anims, go
                batchArm = false;
                batchRemaining = 25;
                batchSavedAnims = global.expRules.anims;
                global.expRules.anims = false;
                var _bc = [
                    (menuCtl[0] == "human") ? "v1" : menuCtl[0],
                    (menuCtl[1] == "human") ? "v1" : menuCtl[1]
                ];
                start_game(_bd.id, _bc);
            } else {
                start_game(_bd.id);
            }
        }
    }
    draw_set_halign(fa_left);
    draw_set_color(c_white);
    exit;
}

var _p = game.activePlayer;
var _pl = game.players[_p];
var _aiTurn = (ctl[_p] != "human" && game.phase != "gameover");
var _cine = (dayCine != undefined); // day cinematic playing - block all human input
var _locked = _cine || turnSettling || array_length(game.resolveQueue) > 0
    || game.pendingDiscard != undefined; // settling / staged resolution / hand-limit picker
// boss bounty placements block ALL normal play until the queue is resolved
var _freePending = (array_length(game.pendingFree) > 0 && game.phase != "gameover");
var _freeHuman = _freePending && (ctl[game.pendingFree[0].playerIdx] == "human");

// ---------- hover picking: nearest space/home centre in screen space ----------
hoverKind = ""; hoverLane = -1; hoverIdx = -1;
var _vp = matrix_multiply(viewMat, projMat);
var _mgx = device_mouse_x_to_gui(0);
var _mgy = device_mouse_y_to_gui(0);
var _bestDist = 46;
for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
    for (var _spaceIdx = 0; _spaceIdx <= 6; _spaceIdx++) {
        var _wPos = board_space_xy(board, _laneIdx, _spaceIdx);
        var _scr = world_to_gui(_vp, _wPos[0], _wPos[1], 1);
        if (_scr == undefined) continue;
        var _d = point_distance(_mgx, _mgy, _scr[0], _scr[1]);
        if (_d < _bestDist) { _bestDist = _d; hoverKind = "space"; hoverLane = _laneIdx; hoverIdx = _spaceIdx; }
    }
}
for (var _h = 0; _h < 2; _h++) {
    // sample one point per lane so the whole strip is clickable
    for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
        var _lx = (_laneIdx - (board.laneCount - 1) * 0.5) * (TILE_W + LANE_GAP);
        var _scr = world_to_gui(_vp, _lx, board_home_y(_h), 1);
        if (_scr == undefined) continue;
        var _d = point_distance(_mgx, _mgy, _scr[0], _scr[1]);
        if (_d < max(_bestDist, 55)) { _bestDist = _d; hoverKind = "home"; hoverLane = -1; hoverIdx = _h; }
    }
}
// the active player's ONION discard zone (their left, mirror of the horde): a click
// target that dismisses the selected pikmin. Only the owner's zone is pickable.
if (!_aiTurn) {
    var _oScr = world_to_gui(_vp, (_p == 0) ? 440 : -440, board_home_y(_p) * 0.86, 1.66);
    if (_oScr != undefined) {
        var _oD = point_distance(_mgx, _mgy, _oScr[0], _oScr[1]);
        if (_oD < max(_bestDist, 60)) { _bestDist = _oD; hoverKind = "onion"; hoverLane = -1; hoverIdx = _p; }
    }
}

// ---------- hovered-space strength fraction: yours over theirs ----------
if (hoverKind == "space" && game.phase != "gameover") {
    var _viewP = (ctl[0] == "human") ? 0 : ((ctl[1] == "human") ? 1 : game.activePlayer);
    var _fMine = game_strength_at(game, _viewP, hoverLane, hoverIdx);
    var _fOpp  = game_strength_at(game, 1 - _viewP, hoverLane, hoverIdx);
    var _fT = game_treasure_at(game, hoverLane, hoverIdx);
    if (_fMine > 0 || _fOpp > 0 || _fT != undefined) {
        var _fw = board_space_xy(board, hoverLane, hoverIdx);
        var _fscr = world_to_gui(_vp, _fw[0], _fw[1], 30);
        if (_fscr != undefined) {
            var _fx = _fscr[0];
            var _fy = _fscr[1] - 52;
            var _hasW = (_fT != undefined && array_length(_fT.cards) > 0);
            draw_set_alpha(0.72);
            draw_set_color(c_black);
            draw_rectangle(_fx - 26, _fy - 26, _fx + (_hasW ? 62 : 26), _fy + 26, false);
            draw_set_alpha(1);
            draw_set_font(fntPikmin);
            draw_set_halign(fa_center);
            draw_set_valign(fa_middle);
            draw_set_color(player_marker(_viewP));
            dtext(_fx, _fy - 12, string(_fMine));
            draw_set_color(c_white);
            draw_line_width(_fx - 14, _fy, _fx + 14, _fy, 2);
            draw_set_color(player_marker(1 - _viewP));
            dtext(_fx, _fy + 13, string(_fOpp));
            if (_hasW) {
                draw_set_color(make_color_rgb(255, 224, 120));
                dtext(_fx + 42, _fy, "w" + string(treasure_def_get(_fT.cards[array_length(_fT.cards) - 1]).weight));
            }
            draw_set_font(-1);
            draw_set_halign(fa_left);
            draw_set_valign(fa_top);
            draw_set_color(c_white);
        }
    }
}

// ---------- Onion hover hint ----------
if (hoverKind == "onion" && game.phase == "orders" && !_aiTurn && !_locked) {
    draw_set_font(-1);
    var _otTxt = (selSrc != undefined)
        ? "Onion: Click to DISCARD the selected pikmin"
        : "Onion: Send Pikmin here to DISCARD them";
    var _otW = string_width(_otTxt);
    var _otH = string_height(_otTxt);
    var _otX = _mgx + 14;
    var _otY = _mgy - _otH * 0.5;
    draw_set_alpha(0.78);
    draw_set_color(c_black);
    draw_rectangle(_otX, _otY - 4, _otX + _otW + 16, _otY + _otH + 4, false);
    draw_set_alpha(1);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text(_otX + 8, _otY, _otTxt);
    draw_set_color(c_white);
}

// ---------- top bar ----------
var _barH = 36;
var _capMax = global.rules.pikminBoardCap;
var _midY = _barH * 0.5;
draw_set_alpha(0.9);
draw_set_color(player_tint(_p));
draw_rectangle(0, 0, _guiW, _barH, false);
draw_set_alpha(1);
draw_set_font(-1);
draw_set_valign(fa_middle);
draw_set_halign(fa_left);

// left: board + day
draw_set_color(c_white);
draw_text(10, _midY, boardDef.name + "    Day " + string(game.dayNumber) + " (" + string(game.dayTrack) + "/" + string(global.rules.dayTrackLength) + ")");
if (batchRemaining > 0) {
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text(_guiW * 0.5, 44, "[BATCH: " + string(batchRemaining) + " games left]"); // below the top bar
    draw_set_color(c_white);
    draw_set_halign(fa_left);
}

// middle: current player's detailed pikmin breakdown (token icons + counts + total)
var _bx = 320;
var _youLbl = "YOU " + string(game_realized_score(game, _p)) + "p";
draw_set_color(make_color_rgb(255, 236, 180));
draw_text(_bx, _midY, _youLbl);
_bx += string_width(_youLbl) + 18;
draw_set_color(c_white);
var _typeOrder = ["red", "blue", "yellow", "purple", "white", "rock", "ice", "winged", "bulbmin"];
var _typeCounts = {};
var _youToks = game.players[_p].tokens;
for (var _i = 0; _i < array_length(_youToks); _i++) {
    var _tt = _youToks[_i].typeId;
    _typeCounts[$ _tt] = (variable_struct_exists(_typeCounts, _tt) ? _typeCounts[$ _tt] : 0) + 1;
}
for (var _oi = 0; _oi < array_length(_typeOrder); _oi++) {
    var _tid = _typeOrder[_oi];
    if (!variable_struct_exists(_typeCounts, _tid)) continue;
    var _tokSpr = pikmin_token_sprite(_tid);
    if (_tokSpr != -1) {
        var _iw = 26 * sprite_get_width(_tokSpr) / sprite_get_height(_tokSpr);
        draw_sprite_stretched(_tokSpr, 0, _bx, _midY - 13, _iw, 26);
        _bx += _iw + 1;
    } else {
        draw_set_color(make_color_rgb(120, 200, 110)); // bulbmin: green dot fallback
        draw_circle(_bx + 10, _midY, 9, false);
        draw_set_color(c_white);
        _bx += 20;
    }
    draw_text(_bx, _midY, string(_typeCounts[$ _tid]));
    _bx += string_width(string(_typeCounts[$ _tid])) + 12;
}
var _youB = game_bulbmin_count(game, _p);
draw_set_color(make_color_rgb(200, 210, 222));
draw_text(_bx + 2, _midY, "= " + string(game_capped_count(game, _p)) + "/" + string(_capMax) + ((_youB > 0) ? ("  +" + string(_youB) + "b") : ""));

// right: opponent compact ("player <poko> [x/25]") + phase
var _opp = 1 - _p;
var _oppB = game_bulbmin_count(game, _opp);
var _oppCap = string(game_capped_count(game, _opp)) + "/" + string(_capMax) + ((_oppB > 0) ? ("+" + string(_oppB) + "b") : "");
var _phaseName = game.phase == "gather" ? "GATHER" : (game.phase == "orders" ? "ORDERS" : (game.phase == "move" ? "MOVE" : "GAME OVER"));
draw_set_color(c_white);
draw_set_halign(fa_right);
draw_text(_guiW - 10, _midY, "vs P" + string(_opp + 1) + " " + string(game_realized_score(game, _opp)) + "p [" + _oppCap + "]        " + (_aiTurn ? "AI" : "YOU") + " - " + _phaseName);
draw_set_halign(fa_left);
draw_set_valign(fa_top);
ui_block_rect(0, 0, _guiW, _barH);

// controls hint
draw_set_color(make_color_rgb(200, 205, 215));
draw_text(8, _guiH - 20, "Left: Select   Middle: Send All   Right-drag: Orbit Camera   WASD: Pan   Wheel: Zoom/Scroll   Alt: Inspect   V: Treasure   F2: Return to Menu");
draw_set_color(c_white);

// ---------- log panel (right) ----------
var _logX = _guiW - 330;
var _logH = 16 * 14 + 10;
draw_set_alpha(0.55);
draw_set_color(c_black);
draw_rectangle(_logX, 40, _guiW - 8, 40 + _logH, false);
draw_set_alpha(1);
draw_set_color(make_color_rgb(220, 220, 220));
var _logN = array_length(game.log);
var _logMaxW = (_guiW - 8) - (_logX + 8) - 4; // inner width
var _logTop = 40, _logBot = 40 + _logH;
// total wrapped content height, so we can clamp the scroll to what's actually there
var _logContentH = 0;
for (var _i = 0; _i < _logN; _i++) _logContentH += string_height_ext(game.log[_i], 14, _logMaxW) + 2;
logScroll = clamp(logScroll, 0, max(0, _logContentH - (_logH - 6)));
// word-wrap entries, newest anchored at the bottom, stacking upward. logScroll pushes
// the anchor DOWN (newest off the bottom) so older entries scroll into the panel.
var _ly = _logBot - 6 + logScroll;
for (var _i = _logN - 1; _i >= 0; _i--) {
    var _line = game.log[_i];
    var _lh = string_height_ext(_line, 14, _logMaxW);
    _ly -= _lh + 2;
    if (_ly + _lh < _logTop + 4) break;   // fully above the panel - older ones are too
    if (_ly > _logBot - 2) continue;      // scrolled below the panel bottom - skip drawing
    draw_text_ext(_logX + 8, _ly, _line, 14, _logMaxW);
}
draw_set_color(c_white);
// scroll affordances: a hint when more log sits above/below the visible window
if (logScroll < max(0, _logContentH - (_logH - 6))) {
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text(_guiW - 22, _logTop + 2, "^");
}
if (logScroll > 0) {
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text(_guiW - 22, _logBot - 16, "v");
}
draw_set_color(c_white);
ui_block_rect(_logX, 40, _guiW - 8 - _logX, _logH);

// ---------- phase controls (left column) ----------
var _cy = 44;
if (_cine) {
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text(12, _cy, "Sunset - Time to return home!");
    draw_set_color(c_white);
} else if (_locked) {
    draw_set_color(make_color_rgb(200, 210, 220));
    draw_text(12, _cy, (game.pendingDiscard != undefined)
        ? ("P" + string(game.pendingDiscard.playerIdx + 1) + " discards to the hand limit...")
        : (turnSettling ? "..." : "Resolving..."));
    draw_set_color(c_white);
} else if (_freePending) {
    var _fpEntry = game.pendingFree[0];
    draw_set_color(c_yellow);
    draw_text(12, _cy, "BOSS BOUNTY: P" + string(_fpEntry.playerIdx + 1) + " places " + string(_fpEntry.count) + " free hazard(s)");
    draw_set_color(c_white);
    _cy += 22;
    draw_text(12, _cy, _freeHuman ? "Pick a hazard type, then click an empty basic space." : "The AI is choosing its spot" + string_repeat(".", 1 + (frameTick div 20) mod 3));
} else if (_aiTurn) {
    draw_text(12, _cy, "AI is taking its turn" + string_repeat(".", 1 + (frameTick div 20) mod 3));
} else if (game.phase == "gather") {
    draw_text(12, _cy, "Gather actions left: " + string(game.gatherActionsLeft));
    _cy += 22;
    if (ui_button(12, _cy, 220, 34, "Draw Gather Card (" + string(array_length(game.decks.gather)) + ")")) game_gather_draw(game);
    _cy += 42;
    if (ui_button(12, _cy, 220, 34, "Roll Pellet Die")) game_gather_roll(game);
} else if (game.phase == "orders") {
    if (ui_button(12, _cy, 220, 34, "End Orders")) { game_orders_done(game); selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; }
    _cy += 42;
    draw_text(12, _cy, selSrc == undefined ? "Left-click pikmin to pick some; middle-click a space to send all there." : "Click a destination (or middle-click to send all).");
    _cy += 24;
    draw_set_color(make_color_rgb(170, 180, 190));
    draw_text(12, _cy, "Send Pikmin to Onion to DISCARD");
    draw_set_color(c_white);
    _cy += 24;
} else if (game.phase == "move") {
    if (pendingCard == undefined) {
        if (ui_button(12, _cy, 260, 40, "Resolve Moves & End Turn")) { game_resolve_moves(game); selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; }
        _cy += 48;
        draw_text(12, _cy, "Play gather cards now by clicking them in your hand.");
    } else {
        var _prompt = "";
        switch (pendingCard.stage) {
            case "space":
                switch (pendingCard.effectId) {
                    case "rawmaterial":    _prompt = "Raw Material: Select an empty space."; break;
                    case "ivoryandviolet": _prompt = "Ivory and Violet: Select a space with your Pikmin."; break;
                    case "phosbatpod":     _prompt = "Phosbat Pod: Select an empty Enemy space (red)."; break;
                    case "bombrock":       _prompt = "Bomb Rock: Select a space to blow up."; break;
                    case "spicyspray":     _prompt = "Ultra-Spicy Spray: Select a space to spray."; break;
                    case "candypopbud":    _prompt = "Candypop Bud: Select a space with your pikmin."; break;
                    case "oatchirush":     _prompt = "Oatchi Rush: Select a lane to rush."; break;
                    case "rockstorm":      _prompt = "Rock Storm: Select an empty, hazard-free space."; break;
                    case "surveydrone":    _prompt = "Survey Drone: Select a treasure pile to randomize."; break;
                    case "bitterspray":    _prompt = "Ultra-Bitter Spray: Select a space to spray."; break;
                    case "icebomb":        _prompt = "Ice Bomb: Select a space to freeze everything on it."; break;
                    case "storm":          _prompt = "Lightning Storm: Select a 2x2 area to stun."; break;
                    case "shipsignal":     _prompt = "Ship Signal: Select a treasure pile to rearrange."; break;
                    case "pikpikbundle":   _prompt = "Pikpik Carrots: Select an enemy space or treasure space to place a decoy."; break;
                    case "mine":           _prompt = "Mine: Select a space to bury a mine."; break;
                    default:               _prompt = "Select a target space."; break;
                }
                break;
            case "warpA":    _prompt = "Warp: Select a BOSS or ENEMY."; break;
            case "warpBoss": _prompt = "Warp: Select another BOSS to swap."; break;
            case "warpDest": _prompt = "Warp: Select an empty ENEMY space."; break;
            case "color":    _prompt = "Select a colour"; break;
            case "build":    _prompt = "Build what?"; break;
            case "trade":    _prompt = "Trade which Pikmin?"; break;
        }
        draw_text(12, _cy, _prompt);
        _cy += 26;
        if (ui_button(12, _cy, 150, 30, "Cancel")) pendingCard = undefined;
    }
} else if (game.phase == "gameover" && gameoverSettled) {
    draw_set_halign(fa_center);
    draw_set_color(c_yellow);
    var _msg = (game.winner == -1) ? "DRAW!" : ("PLAYER " + string(game.winner + 1) + " WINS!");
    draw_text_transformed(_guiW * 0.5, _guiH * 0.35, _msg, 3 * UI_TS, 3 * UI_TS, 0);
    draw_set_color(c_white);
    draw_text_transformed(_guiW * 0.5, _guiH * 0.35 + 50, "P1 " + string(game_realized_score(game, 0)) + "p  vs  P2 " + string(game_realized_score(game, 1)) + "p", 1.5 * UI_TS, 1.5 * UI_TS, 0);
    draw_set_halign(fa_left);
    if (ui_button(_guiW * 0.5 - 200, _guiH * 0.35 + 90, 190, 40, "Rematch (same board/players)")) {
        showCollection = false; // the auto-opened sidebars don't follow into the next game
        start_game(boardDef.id, ctl);
        exit;
    }
    if (ui_button(_guiW * 0.5 + 10, _guiH * 0.35 + 90, 190, 40, "Main Menu")) {
        showCollection = false;
        return_to_menu();
        exit;
    }
}

// ---------- selection panel (orders) ----------
if (game.phase == "orders" && selSrc != undefined) {
    var _avail = game_counts_struct(game, _p, selSrc);
    var _availColors = variable_struct_get_names(_avail);
    if (array_length(_availColors) == 0) {
        selSrc = undefined;
    } else {
        var _panelY = _cy + 8;
        var _panelH = array_length(_availColors) * 30 + 78;
        draw_set_alpha(0.6);
        draw_set_color(c_black);
        draw_rectangle(8, _panelY, 250, _panelY + _panelH, false);
        draw_set_alpha(1);
        draw_set_color(c_white);
        ui_block_rect(8, _panelY, 242, _panelH);
        var _rowY = _panelY + 8;
        for (var _c = 0; _c < array_length(_availColors); _c++) {
            var _colId = _availColors[_c];
            var _have = _avail[$ _colId];
            var _cur = variable_struct_exists(selCounts, _colId) ? min(selCounts[$ _colId], _have) : 0;
            selCounts[$ _colId] = _cur;
            draw_text(16, _rowY + 3, _colId + ": " + string(_cur) + "/" + string(_have));
            if (ui_button(160, _rowY, 26, 24, "-")) selCounts[$ _colId] = max(0, _cur - 1);
            if (ui_button(192, _rowY, 26, 24, "+")) selCounts[$ _colId] = min(_have, _cur + 1);
            _rowY += 30;
        }
        if (ui_button(16, _rowY, 60, 26, "All")) {
            for (var _c = 0; _c < array_length(_availColors); _c++) selCounts[$ _availColors[_c]] = _avail[$ _availColors[_c]];
        }
        if (ui_button(84, _rowY, 60, 26, "None")) {
            for (var _c = 0; _c < array_length(_availColors); _c++) selCounts[$ _availColors[_c]] = 0;
        }
        if (ui_button(152, _rowY, 66, 26, "Cancel")) selSrc = undefined;
        _rowY += 30;
        if (ui_button(16, _rowY, 202, 24, "Default Selection: " + (defaultSelectAll ? "ALL" : "NONE"))) defaultSelectAll = !defaultSelectAll;
    }
}

var _altZoomAlias = "";

// ---------- hand (active player's gather + pellet cards) ----------
var _handEntries = [];
for (var _i = 0; _i < array_length(_pl.hand); _i++) array_push(_handEntries, { kind: "gather", cardId: _pl.hand[_i], pelletIdx: -1 });
for (var _i = 0; _i < array_length(_pl.pellets); _i++) array_push(_handEntries, { kind: "pellet", cardId: _pl.pellets[_i], pelletIdx: _i });
var _numCards = array_length(_handEntries);
if (_numCards > 0 && game.phase != "gameover" && !_aiTurn && !_freePending && !_locked) {
    var _cardH = 170;
    var _cardW = _cardH * 0.714;
    var _step = (_numCards * (_cardW + 10) <= _guiW - 560) ? (_cardW + 10) : max(34, (_guiW - 560 - _cardW) / max(1, _numCards - 1));
    var _handW = _cardW + _step * (_numCards - 1);
    var _hx0 = (_guiW - 330 - _handW) * 0.5;
    var _hy = _guiH - _cardH * 0.62;
    ui_block_rect(_hx0 - 10, _hy - 12, _handW + 20, _cardH);
    var _hovered = -1;
    for (var _i = 0; _i < _numCards; _i++) {
        var _cx = _hx0 + _i * _step;
        var _cw = (_i == _numCards - 1) ? _cardW : _step;
        if (_mgx >= _cx && _mgx < _cx + _cw && _mgy >= _hy - 12) _hovered = _i;
    }
    for (var _i = 0; _i < _numCards; _i++) {
        if (_i == _hovered) continue;
        card_draw(_handEntries[_i].cardId, _hx0 + _i * _step, _hy, _cardH);
    }
    if (_hovered != -1) {
        _altZoomAlias = _handEntries[_hovered].cardId;
        var _bigH = _cardH * 1.85;
        var _bigW = _bigH * 0.714;
        var _bcx = _hx0 + _hovered * _step + _cardW * 0.5;
        var _bigX = clamp(_bcx - _bigW * 0.5, 8, _guiW - _bigW - 8);
        card_draw(_handEntries[_hovered].cardId, _bigX, _guiH - _bigH - 6, _bigH);
        // Captain Clone: show what it would actually copy
        if (_handEntries[_hovered].cardId == "captainclone") {
            var _dn = array_length(game.decks.gatherDiscard);
            var _copyTxt = (_dn > 0) ? "Will copy: " + gather_def_get(game.decks.gatherDiscard[_dn - 1]).name : "Nothing to copy.";
            if (_dn > 0) {
                var _copyX = (_bigX + _bigW * 2 + 16 <= _guiW) ? _bigX + _bigW + 8 : _bigX - _bigW - 8;
                card_draw(game.decks.gatherDiscard[_dn - 1], _copyX, _guiH - _bigH - 6, _bigH);
            }
            draw_set_halign(fa_center);
            draw_set_color(c_yellow);
            draw_text(_bigX + _bigW * 0.5, _guiH - _bigH - 26, _copyTxt);
            draw_set_color(c_white);
            draw_set_halign(fa_left);
        }
        if (mouse_check_button_pressed(mb_left)) {
            if (game.phase == "orders" && _handEntries[_hovered].kind == "pellet") {
                pelletMenuIdx = _handEntries[_hovered].pelletIdx;
                posyMenuIdx = -1;
            } else if (_handEntries[_hovered].kind == "gather") {
                var _gid = _handEntries[_hovered].cardId;
                if (game.phase == "orders" && _gid == "colorchangingposy") {
                    posyMenuIdx = _hovered; // gather cards sit first in the hand, so this is the hand index
                    pelletMenuIdx = -1;
                } else if (game.phase == "move") {
                    // start the card's targeting flow (Captain Clone resolves to the discard top)
                    var _eff = _gid;
                    if (_gid == "captainclone") {
                        var _dn = array_length(game.decks.gatherDiscard);
                        _eff = (_dn > 0) ? game.decks.gatherDiscard[_dn - 1] : "";
                    }
                    if (_eff == "" || _eff == "captainclone" || _eff == "pikminextinction") {
                        game_play_gather(game, _hovered, {}); // instant, or the engine logs why not
                    } else if (_eff == "colorchangingposy") {
                        pendingCard = { handIdx: _hovered, cardId: _gid, effectId: _eff, stage: "color", lane: -1, idx: -1, atHome: false, purples: 0, whites: 0 };
                    } else if (_eff == "warp") {
                        pendingCard = { handIdx: _hovered, cardId: _gid, effectId: _eff, stage: "warpA", lane: -1, idx: -1, atHome: false, purples: 0, whites: 0 };
                    } else {
                        pendingCard = { handIdx: _hovered, cardId: _gid, effectId: _eff, stage: "space", lane: -1, idx: -1, atHome: false, purples: 0, whites: 0 };
                    }
                } else {
                    game_log(game, "Gather cards cannot be played now. (Wrong phase)");
                }
            }
        }
    }
}

// ---------- pellet redeem menu ----------
if (pelletMenuIdx >= 0) {
    if (game.phase != "orders" || pelletMenuIdx >= array_length(_pl.pellets)) {
        pelletMenuIdx = -1;
    } else {
        var _pDef = pellet_def_get(_pl.pellets[pelletMenuIdx]);
        var _cols = boardDef.basicColors;
        var _menuW = 200;
        var _menuH = 66 + array_length(_cols) * 38;
        var _menuX = _guiW * 0.5 - _menuW * 0.5;
        var _menuY = _guiH - 200 - _menuH;
        draw_set_alpha(0.75);
        draw_set_color(c_black);
        draw_rectangle(_menuX, _menuY, _menuX + _menuW, _menuY + _menuH, false);
        draw_set_alpha(1);
        draw_set_color(c_white);
        ui_block_rect(_menuX, _menuY, _menuW, _menuH);
        draw_set_halign(fa_center);
        draw_text(_menuX + _menuW * 0.5, _menuY + 8, _pDef.name);
        draw_set_halign(fa_left);
        var _by = _menuY + 30;
        for (var _c = 0; _c < array_length(_cols); _c++) {
            var _colId = _cols[_c];
            var _amt = (_colId == _pDef.color) ? _pDef.sameTypeAmount : _pDef.offTypeAmount;
            if (ui_button(_menuX + 12, _by, _menuW - 24, 30, string(_amt) + "x " + _colId)) {
                game_play_pellet(game, pelletMenuIdx, _colId);
                pelletMenuIdx = -1;
            }
            _by += 38;
        }
        if (pelletMenuIdx >= 0 && ui_button(_menuX + 12, _by, _menuW - 24, 26, "Cancel")) pelletMenuIdx = -1;
    }
}

// ---------- Color Changing Posy menu (played as a pellet: 5 of a starting colour) ----------
if (posyMenuIdx >= 0) {
    if (game.phase != "orders" || posyMenuIdx >= array_length(_pl.hand) || _pl.hand[posyMenuIdx] != "colorchangingposy") {
        posyMenuIdx = -1;
    } else {
        var _cols = boardDef.basicColors;
        var _menuW = 200;
        var _menuH = 66 + array_length(_cols) * 38;
        var _menuX = _guiW * 0.5 - _menuW * 0.5;
        var _menuY = _guiH - 200 - _menuH;
        draw_set_alpha(0.75);
        draw_set_color(c_black);
        draw_rectangle(_menuX, _menuY, _menuX + _menuW, _menuY + _menuH, false);
        draw_set_alpha(1);
        draw_set_color(c_white);
        ui_block_rect(_menuX, _menuY, _menuW, _menuH);
        draw_set_halign(fa_center);
        draw_text(_menuX + _menuW * 0.5, _menuY + 8, "Color Changing Posy");
        draw_set_halign(fa_left);
        var _by = _menuY + 30;
        for (var _c = 0; _c < array_length(_cols); _c++) {
            if (ui_button(_menuX + 12, _by, _menuW - 24, 30, "5x " + _cols[_c])) {
                game_play_gather(game, posyMenuIdx, { color: _cols[_c] });
                posyMenuIdx = -1;
            }
            _by += 38;
        }
        if (posyMenuIdx >= 0 && ui_button(_menuX + 12, _by, _menuW - 24, 26, "Cancel")) posyMenuIdx = -1;
    }
}

// ---------- boss bounty: free hazard type picker (human placer only) ----------
if (_freeHuman) {
    var _fEmits = boardDef.structures.emitters;
    if (!arr_has(_fEmits, freeBuild)) freeBuild = (array_length(_fEmits) > 0) ? _fEmits[0] : "";
    var _menuW = 230;
    var _menuH = 66 + array_length(_fEmits) * 38;
    var _menuX = _guiW * 0.5 - _menuW * 0.5;
    var _menuY = _guiH - 200 - _menuH;
    draw_set_alpha(0.75);
    draw_set_color(c_black);
    draw_rectangle(_menuX, _menuY, _menuX + _menuW, _menuY + _menuH, false);
    draw_set_alpha(1);
    draw_set_color(c_white);
    ui_block_rect(_menuX, _menuY, _menuW, _menuH);
    draw_set_halign(fa_center);
    draw_text(_menuX + _menuW * 0.5, _menuY + 8, "Free hazard - Select a space");
    draw_set_halign(fa_left);
    var _by = _menuY + 30;
    for (var _e = 0; _e < array_length(_fEmits); _e++) {
        var _sel = (_fEmits[_e] == freeBuild) ? "> " : "";
        if (ui_button(_menuX + 12, _by, _menuW - 24, 30, _sel + hazard_def_get(_fEmits[_e]).name)) freeBuild = _fEmits[_e];
        _by += 38;
    }
    if (ui_button(_menuX + 12, _by, _menuW - 24, 26, "Pass")) game_skip_free_hazard(game);
}

// ---------- gather card targeting menus ----------
if (pendingCard != undefined && (game.phase != "move" || game.pendingDiscard != undefined || pendingCard.handIdx >= array_length(_pl.hand))) pendingCard = undefined;
if (pendingCard != undefined && pendingCard.stage == "pilePick") {
    // Ship Signal: choose which card ends up on top of the pile
    var _psT = game_treasure_at(game, pendingCard.lane, pendingCard.idx);
    if (_psT == undefined || array_length(_psT.cards) < 2) {
        pendingCard.stage = "space"; // not a valid pile - keep targeting
    } else {
        var _menuW = 340;
        var _menuH = 66 + array_length(_psT.cards) * 34;
        var _menuX = _guiW * 0.5 - _menuW * 0.5;
        var _menuY = max(40, _guiH - 240 - _menuH);
        draw_set_alpha(0.8);
        draw_set_color(c_black);
        draw_rectangle(_menuX, _menuY, _menuX + _menuW, _menuY + _menuH, false);
        draw_set_alpha(1);
        draw_set_color(c_white);
        ui_block_rect(_menuX, _menuY, _menuW, _menuH);
        draw_set_halign(fa_center);
        draw_text(_menuX + _menuW * 0.5, _menuY + 8, "Ship Signal: choose the new TOP card");
        draw_set_halign(fa_left);
        var _by = _menuY + 30;
        for (var _pc = array_length(_psT.cards) - 1; _pc >= 0; _pc--) {
            var _pcDef = treasure_def_get(_psT.cards[_pc]);
            var _lbl = _pcDef.name + "  (" + string(_pcDef.value) + "p, w" + string(_pcDef.weight) + ")" + ((_pc == array_length(_psT.cards) - 1) ? "  [current top]" : "");
            if (ui_button(_menuX + 12, _by, _menuW - 24, 28, _lbl)) {
                game_play_gather(game, pendingCard.handIdx, { lane: pendingCard.lane, idx: pendingCard.idx, topCard: _pc });
                pendingCard = undefined;
                break;
            }
            _by += 34;
        }
        if (pendingCard != undefined && ui_button(_menuX + 12, _by, _menuW - 24, 26, "Cancel")) pendingCard = undefined;
    }
}
if (pendingCard != undefined && (pendingCard.stage == "color" || pendingCard.stage == "build" || pendingCard.stage == "trade")) {
    var _menuW = 240;
    var _options = [];
    if (pendingCard.stage == "color") {
        if (pendingCard.effectId == "candypopbud2")      _options = ["rock", "winged", "ice"];
        else if (pendingCard.effectId == "candypopbud")  _options = ["red", "blue", "yellow"]; // classic bud: RBY always
        else                                             _options = boardDef.basicColors;      // queen / posy: starting colours
    } else if (pendingCard.stage == "build") {
        if (pendingCard.effectId == "rockstorm") {
            _options = boardDef.structures.emitters;
        } else {
            _options = [];
            for (var _i = 0; _i < array_length(boardDef.structures.walls); _i++) array_push(_options, boardDef.structures.walls[_i]);
            for (var _i = 0; _i < array_length(boardDef.structures.bridges); _i++) array_push(_options, boardDef.structures.bridges[_i]);
        }
    }
    var _menuH = 56 + array_length(_options) * 38;
    if (pendingCard.stage == "trade") {
        // trade menu: fixed header/footer plus one payment row per colour present
        var _tLoc0 = pendingCard.atHome ? { kind: "home" } : { kind: "space", lane: pendingCard.lane, idx: pendingCard.idx };
        _menuH = 196 + array_length(variable_struct_get_names(game_counts_struct(game, _p, _tLoc0))) * 26;
    }
    var _menuX = _guiW * 0.5 - _menuW * 0.5;
    var _menuY = _guiH - 220 - _menuH;
    draw_set_alpha(0.78);
    draw_set_color(c_black);
    draw_rectangle(_menuX, _menuY, _menuX + _menuW, _menuY + _menuH, false);
    draw_set_alpha(1);
    draw_set_color(c_white);
    ui_block_rect(_menuX, _menuY, _menuW, _menuH);
    draw_set_halign(fa_center);
    draw_text(_menuX + _menuW * 0.5, _menuY + 8, gather_def_get(pendingCard.effectId).name);
    draw_set_halign(fa_left);
    var _by = _menuY + 30;

    if (pendingCard.stage == "trade") {
        var _tradeLoc = pendingCard.atHome ? { kind: "home" } : { kind: "space", lane: pendingCard.lane, idx: pendingCard.idx };
        var _tCounts = game_counts_struct(game, _p, _tradeLoc);
        var _tCols = variable_struct_get_names(_tCounts);
        var _have = array_length(game_tokens_at(game, _p, _tradeLoc));
        var _cost = pendingCard.purples * 5 + pendingCard.whites * 2;
        draw_text(_menuX + 12, _by, "Cost: " + string(_cost) + " / " + string(_have) + " pikmin there");
        _by += 24;
        draw_text(_menuX + 12, _by + 4, "Purple x" + string(pendingCard.purples));
        if (ui_button(_menuX + 130, _by, 26, 24, "-")) pendingCard.purples = max(0, pendingCard.purples - 1);
        if (ui_button(_menuX + 162, _by, 26, 24, "+")) { if (_cost + 5 <= _have) pendingCard.purples += 1; }
        _by += 30;
        draw_text(_menuX + 12, _by + 4, "White x" + string(pendingCard.whites));
        if (ui_button(_menuX + 130, _by, 26, 24, "-")) pendingCard.whites = max(0, pendingCard.whites - 1);
        if (ui_button(_menuX + 162, _by, 26, 24, "+")) { if (_cost + 2 <= _have) pendingCard.whites += 1; }
        _by += 30;
        // payment picker: WHICH pikmin get fed to the trade. Leave it blank to pay
        // cheapest-first; otherwise the mix must add up to the cost exactly.
        if (!variable_struct_exists(pendingCard, "pay")) pendingCard.pay = {};
        draw_set_color(make_color_rgb(180, 190, 200));
        draw_text(_menuX + 12, _by, "Pay with (blank = cheapest first):");
        draw_set_color(c_white);
        _by += 22;
        var _paySum = 0;
        for (var _tc = 0; _tc < array_length(_tCols); _tc++) {
            var _colId = _tCols[_tc];
            var _availC = _tCounts[$ _colId];
            var _curP = variable_struct_exists(pendingCard.pay, _colId) ? min(pendingCard.pay[$ _colId], _availC) : 0;
            pendingCard.pay[$ _colId] = _curP;
            _paySum += _curP;
            draw_set_color(pikmin_tint(_colId));
            draw_circle(_menuX + 18, _by + 11, 6, false);
            draw_set_color(c_white);
            draw_text(_menuX + 30, _by + 2, _colId + ": " + string(_curP) + "/" + string(_availC));
            if (ui_button(_menuX + 158, _by, 26, 22, "-")) pendingCard.pay[$ _colId] = max(0, _curP - 1);
            if (ui_button(_menuX + 190, _by, 26, 22, "+")) pendingCard.pay[$ _colId] = min(_availC, _curP + 1);
            _by += 26;
        }
        _by += 6;
        var _payOk = (_paySum == 0 || _paySum == _cost);
        if (!_payOk) {
            draw_set_color(make_color_rgb(255, 140, 120));
            draw_text(_menuX + 12, _by + 6, "payment " + string(_paySum) + "/" + string(_cost) + " - match the cost");
            draw_set_color(c_white);
        } else if (ui_button(_menuX + 12, _by, 100, 30, "Confirm")) {
            game_play_gather(game, pendingCard.handIdx, { lane: pendingCard.lane, idx: pendingCard.idx, atHome: pendingCard.atHome,
                purples: pendingCard.purples, whites: pendingCard.whites, pay: (_paySum > 0) ? pendingCard.pay : undefined });
            pendingCard = undefined;
        }
        if (pendingCard != undefined && ui_button(_menuX + 124, _by, 100, 30, "Cancel")) pendingCard = undefined;
    } else {
        for (var _o = 0; _o < array_length(_options); _o++) {
            var _optLabel = (pendingCard.stage == "build") ? hazard_def_get(_options[_o]).name : _options[_o];
            if (ui_button(_menuX + 12, _by, _menuW - 24, 30, _optLabel)) {
                var _args = { lane: pendingCard.lane, idx: pendingCard.idx, atHome: pendingCard.atHome };
                if (pendingCard.stage == "color") _args.color = _options[_o];
                else _args.build = _options[_o];
                game_play_gather(game, pendingCard.handIdx, _args);
                pendingCard = undefined;
                break;
            }
            _by += 38;
        }
        if (pendingCard != undefined && ui_button(_menuX + 12, _by, _menuW - 24, 26, "Cancel")) pendingCard = undefined;
    }
}

// ---------- hand-limit discard picker: the turn is over but the hand is too big.
// ---------- Modal until enough cards/pellets are tossed (game_discard_choice
// ---------- finishes the deferred handoff); AI seats resolve theirs in Step. ----------
if (game.pendingDiscard != undefined && game.phase != "gameover" && ctl[game.pendingDiscard.playerIdx] == "human") {
    var _pdP = game.pendingDiscard.playerIdx;
    var _pdPl = game.players[_pdP];
    var _pdEntries = [];
    for (var _i = 0; _i < array_length(_pdPl.hand); _i++) array_push(_pdEntries, { kind: "gather", cardId: _pdPl.hand[_i], idx: _i });
    for (var _i = 0; _i < array_length(_pdPl.pellets); _i++) array_push(_pdEntries, { kind: "pellet", cardId: _pdPl.pellets[_i], idx: _i });
    var _pdN = array_length(_pdEntries);
    var _pdCardH = 170;
    var _pdCardW = _pdCardH * 0.714;
    var _pdStep = (_pdN * (_pdCardW + 10) <= _guiW - 120) ? (_pdCardW + 10) : max(40, (_guiW - 120 - _pdCardW) / max(1, _pdN - 1));
    var _pdRowW = _pdCardW + _pdStep * (_pdN - 1);
    var _pdX0 = (_guiW - _pdRowW) * 0.5;
    var _pdY = _guiH * 0.5 - _pdCardH * 0.5;
    // dark backdrop + banner
    draw_set_alpha(0.6);
    draw_set_color(c_black);
    draw_rectangle(0, _pdY - 70, _guiW, _pdY + _pdCardH + 30, false);
    draw_set_alpha(1);
    draw_set_font(fntPikmin);
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, _pdY - 60, "HAND LIMIT", 1.6 * UI_TS, 1.6 * UI_TS, 0);
    draw_set_font(-1);
    draw_set_color(c_white);
    draw_text(_guiW * 0.5, _pdY - 26, "Click " + string(game.pendingDiscard.need) + " card" + ((game.pendingDiscard.need > 1) ? "s" : "") + " to discard");
    draw_set_halign(fa_left);
    ui_block_rect(0, _pdY - 70, _guiW, _pdCardH + 100);
    // the whole hand fanned out; hovered card lifts and gets a frame
    var _pdHov = -1;
    for (var _i = 0; _i < _pdN; _i++) {
        var _cx = _pdX0 + _i * _pdStep;
        var _cw = (_i == _pdN - 1) ? _pdCardW : _pdStep;
        if (_mgx >= _cx && _mgx < _cx + _cw && _mgy >= _pdY - 16 && _mgy < _pdY + _pdCardH) _pdHov = _i;
    }
    for (var _i = 0; _i < _pdN; _i++) {
        if (_i == _pdHov) continue;
        card_draw(_pdEntries[_i].cardId, _pdX0 + _i * _pdStep, _pdY, _pdCardH);
    }
    if (_pdHov != -1) {
        var _hcx = _pdX0 + _pdHov * _pdStep;
        card_draw(_pdEntries[_pdHov].cardId, _hcx, _pdY - 14, _pdCardH);
        draw_set_color(make_color_rgb(255, 120, 90));
        draw_rectangle(_hcx - 2, _pdY - 16, _hcx + _pdCardW + 2, _pdY - 14 + _pdCardH + 2, true);
        draw_set_color(c_white);
        if (mouse_check_button_pressed(mb_left)) {
            game_discard_choice(game, _pdEntries[_pdHov].kind, _pdEntries[_pdHov].idx);
        }
    }
}

// ---------- debug overlay ----------
if (showDebug) {
    var _dbgY = _guiH * 0.5;
    draw_set_alpha(0.5);
    draw_set_color(c_black);
    draw_rectangle(8, _dbgY - 6, 620, _dbgY + board.laneCount * 20 + 6, false);
    draw_set_alpha(1);
    draw_set_color(c_white);
    for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
        var _lane = board.lanes[_laneIdx];
        var _lineText = _lane.laneName + ": ";
        for (var _spaceIdx = 0; _spaceIdx < array_length(_lane.spaces); _spaceIdx++) {
            var _space = _lane.spaces[_spaceIdx];
            if (_space.enemy != undefined) {
                _lineText += "[" + enemy_def_get(_space.enemy.enemyDefId).name + " " + string(_space.enemy.curHp) + "] ";
            } else if (_space.kind == "treasure")  _lineText += "[T] ";
            else if (_space.kind == "enemy")       _lineText += "[e] ";
            else if (_space.kind == "hazard")      _lineText += "[h" + string_char_at(_space.hazard, 1) + "] ";
            else                                   _lineText += "[] ";
        }
        draw_text(16, _dbgY + _laneIdx * 20, _lineText);
    }
}

// ---------- collected-treasure side panels (V toggles) ----------
if (showCollection) {
    var _mgxC = device_mouse_x_to_gui(0);
    var _mgyC = device_mouse_y_to_gui(0);
    var _panW = 336;
    var _panY = 40;
    var _panH = _guiH - 84;
    var _hovL = draw_collection_panel(game, 0, 8, _panY, _panW, _panH, _mgxC, _mgyC);
    var _hovR = draw_collection_panel(game, 1, _guiW - 8 - _panW, _panY, _panW, _panH, _mgxC, _mgyC);
    if (_hovL != "") _altZoomAlias = _hovL;
    if (_hovR != "") _altZoomAlias = _hovR;
}

// ---------- Alt: inspect the hovered card, zoomed (tabletop-sim style) ----------
if (keyboard_check(vk_alt)) {
    var _zoomAlias = _altZoomAlias;
    var _zoomCaption = "";
    var _zoomTitle = "";   // fallback info-card title when there's no exported art
    var _zoomText = "";    // fallback info-card body
    var _zoomPile = undefined; // treasure-pile card array: fan them all out
    if (_zoomAlias == "captainclone") {
        var _dn = array_length(game.decks.gatherDiscard);
        _zoomCaption = (_dn > 0) ? "Will copy: " + gather_def_get(game.decks.gatherDiscard[_dn - 1]).name : "Nothing to copy.";
    }
    if (_zoomAlias == "" && hoverKind == "space") {
        var _hSpace = board.lanes[hoverLane].spaces[hoverIdx];
        var _hT = game_treasure_at(game, hoverLane, hoverIdx);
        if (_hSpace.enemy != undefined) {
            var _hDef = enemy_def_get(_hSpace.enemy.enemyDefId);
            _zoomAlias = card_enemy_alias(_hDef.id, boardDef.setNumber);
            _zoomCaption = _hDef.name + "   HP " + string(_hSpace.enemy.curHp) + "/" + string(_hDef.hp);
        } else if (_hT != undefined && _hT.boss != undefined) {
            var _hDef = enemy_def_get(_hT.boss.enemyDefId);
            _zoomAlias = card_enemy_alias(_hDef.id, boardDef.setNumber);
            _zoomCaption = _hDef.name + " (BOSS)   HP " + string(_hT.boss.curHp) + "/" + string(_hDef.hp);
        } else if (_hT != undefined && array_length(_hT.cards) > 0) {
            var _hDef = treasure_def_get(_hT.cards[array_length(_hT.cards) - 1]);
            _zoomAlias = _hDef.id;
            _zoomPile = _hT.cards; // fan out the whole pile
            var _hVal = 0;
            for (var _i = 0; _i < array_length(_hT.cards); _i++) _hVal += treasure_def_get(_hT.cards[_i]).value;
            _zoomCaption = "Pile: " + string(_hVal) + "p, " + string(array_length(_hT.cards)) + " cards, top weight " + string(_hDef.weight) + " (" + _hDef.name + ")";
        } else if (_hSpace.structure != undefined) {
            var _hDef = hazard_def_get(_hSpace.structure.structId);
            _zoomAlias = _hDef.id;
            _zoomCaption = _hDef.name + "   HP " + string(_hSpace.structure.curHp) + "/" + string(_hDef.hp);
            // most hazard cards have no exported art - carry the data for a text fallback
            _zoomTitle = _hDef.name;
            _zoomText = string_upper(string_char_at(_hDef.type, 1)) + string_delete(_hDef.type, 1, 1);
            if (_hDef.element != "") _zoomText += " (" + _hDef.element + ")";
            _zoomText += "\nHP " + string(_hSpace.structure.curHp) + "/" + string(_hDef.hp) + "\n\n" + _hDef.text;
        }
    }
    if (_zoomPile != undefined) {
        // fan the whole pile out side by side, shrinking to fit the screen width
        var _n = array_length(_zoomPile);
        var _pileH = min(_guiH * 0.5, 430);
        var _pileW = _pileH * 1.45;
        var _gap = 12;
        var _maxRowW = _guiW * 0.94;
        if (_n * (_pileW + _gap) > _maxRowW) {
            _pileW = _maxRowW / _n - _gap;
            _pileH = _pileW / 1.45;
        }
        var _rowW = _n * _pileW + (_n - 1) * _gap;
        var _rx0 = (_guiW - _rowW) * 0.5;
        var _ry0 = (_guiH - _pileH) * 0.42;
        // backdrop + caption (tall enough to contain both label rows under each card)
        draw_set_alpha(0.62);
        draw_set_color(c_black);
        draw_rectangle(_rx0 - 14, _ry0 - 40, _rx0 + _rowW + 14, _ry0 + _pileH + 46, false);
        draw_set_alpha(1);
        draw_set_font(fntPikmin);
        draw_set_halign(fa_center);
        draw_set_valign(fa_top);
        draw_set_color(make_color_rgb(255, 224, 120));
        dtext(_guiW * 0.5, _ry0 - 34, _zoomCaption);
        draw_set_font(-1);
        for (var _i = 0; _i < _n; _i++) {
            var _cx = _rx0 + _i * (_pileW + _gap);
            var _isTop = (_i == _n - 1);
            var _tdef = treasure_def_get(_zoomPile[_i]);
            card_draw(_zoomPile[_i], _cx, _ry0, _pileH);
            // top card (the one whose values are in play) gets a gold frame
            if (_isTop) {
                draw_set_color(make_color_rgb(255, 224, 120));
                draw_rectangle(_cx - 2, _ry0 - 2, _cx + _pileW + 2, _ry0 + _pileH + 2, true);
            }
            draw_set_color(c_white);
            draw_text(_cx + _pileW * 0.5, _ry0 + _pileH + 4, string(_tdef.value) + "p" + (_isTop ? " (top)" : ""));
            // series tag so buried set pieces are easy to spot
            if (_tdef.effectType == "Set") {
                draw_set_color(make_color_rgb(150, 200, 255));
                draw_text(_cx + _pileW * 0.5, _ry0 + _pileH + 20, _tdef.effect);
            } else {
                draw_set_color(make_color_rgb(150, 155, 160));
                draw_text(_cx + _pileW * 0.5, _ry0 + _pileH + 20, "loose");
            }
        }
        draw_set_halign(fa_left);
        draw_set_color(c_white);
    } else if (_zoomAlias != "") {
        var _zSpr = card_sprite_get(_zoomAlias);
        if (_zSpr != -1) {
            // real card art
            var _zH = min(_guiH * 0.78, 720);
            var _zW = sprite_get_width(_zSpr) * (_zH / sprite_get_height(_zSpr));
            if (_zW > _guiW * 0.85) { var _shrink = (_guiW * 0.85) / _zW; _zW *= _shrink; _zH *= _shrink; }
            var _zX = (_guiW - _zW) * 0.5;
            var _zY = (_guiH - _zH) * 0.42;
            draw_set_alpha(0.6);
            draw_set_color(c_black);
            draw_rectangle(_zX - 10, _zY - 10, _zX + _zW + 10, _zY + _zH + 34, false);
            draw_set_alpha(1);
            draw_set_color(c_white);
            card_draw(_zoomAlias, _zX, _zY, _zH);
            if (_zoomCaption != "") {
                draw_set_halign(fa_center);
                draw_text(_zX + _zW * 0.5, _zY + _zH + 8, _zoomCaption);
                draw_set_halign(fa_left);
            }
        } else {
            // no exported art: synthesize a readable info card from the data we have
            var _zW2 = 360, _zH2 = 480;
            var _zX2 = (_guiW - _zW2) * 0.5;
            var _zY2 = (_guiH - _zH2) * 0.42;
            draw_set_alpha(0.94);
            draw_set_color(make_color_rgb(28, 32, 38));
            draw_rectangle(_zX2, _zY2, _zX2 + _zW2, _zY2 + _zH2, false);
            draw_set_alpha(1);
            draw_set_color(make_color_rgb(150, 162, 178));
            draw_rectangle(_zX2, _zY2, _zX2 + _zW2, _zY2 + _zH2, true);
            draw_set_font(fntPikmin);
            draw_set_halign(fa_center);
            draw_set_color(make_color_rgb(255, 236, 170));
            dtext_ext(_zX2 + _zW2 * 0.5, _zY2 + 20, (_zoomTitle != "") ? _zoomTitle : _zoomAlias, 26, _zW2 - 28);
            draw_set_halign(fa_left);
            draw_set_font(-1);
            draw_set_color(make_color_rgb(214, 220, 230));
            draw_text_ext(_zX2 + 18, _zY2 + 96, (_zoomText != "") ? _zoomText : "(no card art exported)", 20, _zW2 - 36);
            draw_set_color(make_color_rgb(150, 160, 175));
            draw_text(_zX2 + 18, _zY2 + _zH2 - 26, "art: CARD" + _zoomAlias + ".png (missing)");
            draw_set_color(c_white);
        }
    }

    // discard-pile list: Alt-hover the centre-side discard decal to read the pile
    var _ddScr = world_to_gui(_vp, 380, 0, 1.63);
    var _discList = game.decks.gatherDiscard;
    var _discNn = array_length(_discList);
    if (_ddScr != undefined && _discNn > 0 && point_distance(_mgx, _mgy, _ddScr[0], _ddScr[1]) < 80) {
        var _dlShow = min(_discNn, 16);
        var _dlW = 260, _dlH = 34 + (_dlShow + (_discNn > _dlShow ? 1 : 0)) * 18;
        var _dlX = clamp(_ddScr[0] + 40, 8, _guiW - _dlW - 8);
        var _dlY = clamp(_ddScr[1] - _dlH * 0.5, 8, _guiH - _dlH - 8);
        draw_set_alpha(0.92);
        draw_set_color(make_color_rgb(20, 24, 30));
        draw_rectangle(_dlX, _dlY, _dlX + _dlW, _dlY + _dlH, false);
        draw_set_alpha(1);
        draw_set_color(make_color_rgb(180, 190, 200));
        draw_rectangle(_dlX, _dlY, _dlX + _dlW, _dlY + _dlH, true);
        draw_set_color(c_yellow);
        draw_text(_dlX + 10, _dlY + 8, "DISCARD (" + string(_discNn) + ") - Newest first");
        draw_set_color(c_white);
        for (var _dli = 0; _dli < _dlShow; _dli++) {
            draw_text(_dlX + 10, _dlY + 30 + _dli * 18, gather_def_get(_discList[_discNn - 1 - _dli]).name);
        }
        if (_discNn > _dlShow) draw_text(_dlX + 10, _dlY + 30 + _dlShow * 18, "...and " + string(_discNn - _dlShow) + " more");
    }
}

// ---------- board clicks (only when the HUD didn't take the mouse) ----------
// boss bounty: while the queue is live, a space click IS the placement
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && !_locked && _freeHuman && hoverKind == "space" && freeBuild != "") {
    game_place_free_hazard(game, hoverLane, hoverIdx, freeBuild);
}
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && !_locked && !_freePending && !_aiTurn && game.phase == "move" && pendingCard != undefined && (hoverKind == "space" || hoverKind == "home")) {
    switch (pendingCard.stage) {
        case "space":
            if (hoverKind == "home") {
                // HOME is a legal target for in-place conversion cards
                if (hoverIdx == _p && (pendingCard.effectId == "ivoryandviolet" || pendingCard.effectId == "candypopbud"
                    || pendingCard.effectId == "queencandypopbud" || pendingCard.effectId == "candypopbud2")) {
                    pendingCard.lane = -1;
                    pendingCard.idx = -1;
                    pendingCard.atHome = true;
                    pendingCard.stage = (pendingCard.effectId == "ivoryandviolet") ? "trade" : "color";
                }
                break;
            }
            pendingCard.lane = hoverLane;
            pendingCard.idx = hoverIdx;
            pendingCard.atHome = false;
            switch (pendingCard.effectId) {
                case "rawmaterial":
                case "rockstorm":      pendingCard.stage = "build"; break;
                case "candypopbud":
                case "queencandypopbud":
                case "candypopbud2":   pendingCard.stage = "color"; break;
                case "ivoryandviolet": pendingCard.stage = "trade"; break;
                case "shipsignal":     pendingCard.stage = "pilePick"; break;
                default:
                    game_play_gather(game, pendingCard.handIdx, { lane: hoverLane, idx: hoverIdx });
                    pendingCard = undefined;
                    break;
            }
            break;
        case "warpA": {
            if (hoverKind != "space") break;
            var _wt = game_treasure_at(game, hoverLane, hoverIdx);
            if (_wt != undefined && _wt.boss != undefined) {
                pendingCard.lane = hoverLane; pendingCard.idx = hoverIdx; pendingCard.stage = "warpBoss";
            } else if (board.lanes[hoverLane].spaces[hoverIdx].enemy != undefined) {
                pendingCard.lane = hoverLane; pendingCard.idx = hoverIdx; pendingCard.stage = "warpDest";
            }
            break;
        }
        case "warpBoss":
            if (hoverKind != "space") break;
            game_play_gather(game, pendingCard.handIdx, { mode: "swap", lane: pendingCard.lane, idx: pendingCard.idx, lane2: hoverLane, idx2: hoverIdx });
            pendingCard = undefined;
            break;
        case "warpDest":
            if (hoverKind != "space") break;
            game_play_gather(game, pendingCard.handIdx, { mode: "move", lane: pendingCard.lane, idx: pendingCard.idx, lane2: hoverLane, idx2: hoverIdx });
            pendingCard = undefined;
            break;
    }
}
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && !_locked && !_freePending && !_aiTurn && game.phase == "orders") {
    if (hoverKind == "home" && hoverIdx == _p) {
        var _homeLoc = { kind: "home" };
        if (selSrc != undefined && selSrc.kind != "home") {
            game_order_move(game, selSrc, _homeLoc, selCounts);
            selSrc = undefined;
        } else if (array_length(game_tokens_at(game, _p, _homeLoc)) > 0) {
            selSrc = _homeLoc;
            selCounts = defaultSelectAll ? game_counts_struct(game, _p, _homeLoc) : {};
        }
    } else if (hoverKind == "space") {
        var _spaceLoc = { kind: "space", lane: hoverLane, idx: hoverIdx };
        if (selSrc != undefined && !game_loc_eq(selSrc, _spaceLoc)) {
            game_order_move(game, selSrc, _spaceLoc, selCounts);
            selSrc = undefined;
        } else {
            var _counts = game_counts_struct(game, _p, _spaceLoc);
            if (array_length(variable_struct_get_names(_counts)) > 0) {
                selSrc = _spaceLoc;
                selCounts = defaultSelectAll ? _counts : {};
            }
        }
    } else if (hoverKind == "onion" && hoverIdx == _p) {
        // dismiss the selected pikmin - they walk home and return to the Onion
        if (selSrc != undefined) {
            game_order_discard(game, selSrc, selCounts);
            selSrc = undefined;
        } else {
            game_log(game, "Select Pikmin, then click the Onion to discard them.");
        }
    } else {
        selSrc = undefined;
    }
}

// middle-click a destination: send ALL eligible pikmin there in one action, from
// the selected source if there is one, otherwise straight from HOME (the reserve)
if (mouse_check_button_pressed(mb_middle) && !global.uiMouseConsumed && !_locked && !_freePending && !_aiTurn && game.phase == "orders") {
    var _validDst = (hoverKind == "space") || (hoverKind == "home" && hoverIdx == _p);
    if (hoverKind == "onion" && hoverIdx == _p) {
        // whole selected group to the Onion (an explicit selection is required -
        // no default-from-HOME here, a stray middle-click must not wipe the reserve)
        if (selSrc != undefined) {
            game_order_discard(game, selSrc, game_counts_struct(game, _p, selSrc));
            selSrc = undefined;
        }
    } else if (_validDst) {
        var _src = (selSrc != undefined) ? selSrc : { kind: "home" };
        var _dst = (hoverKind == "home") ? { kind: "home" } : { kind: "space", lane: hoverLane, idx: hoverIdx };
        if (!game_loc_eq(_src, _dst)) {
            game_order_move(game, _src, _dst, game_counts_struct(game, _p, _src));
            selSrc = undefined;
        }
    }
}

// ---------- day-transition cinematic overlay: dark flash + "DAY'S OVER!" ----------
if (dayCine != undefined && dayCine.phase == "flash") {
    var _ft = dayCine.timer;
    var _fa = 0.85;
    if (_ft < 20) _fa = 0.85 * (_ft / 20);              // fade in
    else if (_ft > 76) _fa = 0.85 * ((96 - _ft) / 20);  // fade back out into the walk
    draw_set_alpha(_fa);
    draw_set_color(c_black);
    draw_rectangle(0, 0, _guiW, _guiH, false);
    draw_set_alpha(1);
    draw_set_font(fntPikmin);
    draw_set_halign(fa_center);
    draw_set_valign(fa_middle);
    draw_set_color(make_color_rgb(255, 224, 120));
    var _pulse = (3.2 + dsin(_ft * 8) * 0.12) * UI_TS;
    draw_text_transformed(_guiW * 0.5, _guiH * 0.42, "DAY'S OVER!", _pulse, _pulse, 0);
    draw_set_color(make_color_rgb(210, 220, 230));
    draw_text_transformed(_guiW * 0.5, _guiH * 0.42 + 60, "Day " + string(game.dayNumber) + " dawns", 1.1 * UI_TS, 1.1 * UI_TS, 0);
    draw_set_color(c_white);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
    draw_set_font(-1);
}
