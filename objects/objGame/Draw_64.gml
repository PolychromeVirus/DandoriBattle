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
    draw_set_font(fntMaru);
    var _elT = (get_timer() - _stT.t0) / 1000000;
    var _etaT = (_stT.done > 0) ? _elT * (_stT.total - _stT.done) / _stT.done : 0;
    dtext(_guiW * 0.5, _byT - 24, "TOURNAMENT  " + string(_stT.boardId) + "   game " + string(_stT.done) + " / " + string(_stT.total) + "  (" + string(floor(_fracT * 100)) + "%)");
    dtext(_guiW * 0.5, _byT + 38, "elapsed " + string(floor(_elT)) + "s    eta ~" + string(floor(_etaT)) + "s    Esc = cancel (keeps partial results)");
    draw_set_halign(fa_left);
    exit;
}

// ==================== ADVENTURE RESULT BANNER ====================
// Board cleared (between-board), scenario complete, or out of days. Overlays the board
// while advBanner is up (Step drives the hold + transition).
if (advBanner != "") {
    var _abTxt = (advBanner == "cleared") ? "Board Complete!" : ((advBanner == "complete") ? "Scenario Complete!" : "Out of Days");
    var _abSub = (advBanner == "cleared") ? "All treasures found!" : ((advBanner == "complete" && advRun != undefined) ? advRun.name : "");
    draw_set_alpha(0.72); draw_set_color(c_black); draw_rectangle(0, 0, _guiW, _guiH, false); draw_set_alpha(1);
    draw_set_halign(fa_center); draw_set_font(fntMaru);
    draw_set_color((advBanner == "failed") ? make_color_rgb(235, 90, 80) : make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, _guiH * 0.42, _abTxt, 2.4 * UI_TS, 2.4 * UI_TS, 0);
    if (_abSub != "") { draw_set_color(make_color_rgb(210, 220, 214)); draw_text_transformed(_guiW * 0.5, _guiH * 0.53, _abSub, 1.2 * UI_TS, 1.2 * UI_TS, 0); }
    draw_set_halign(fa_left); draw_set_color(c_white);
    exit;
}

// ==================== ADVENTURE RESULTS SCREEN (population graph) ====================
// After the flash, the run pauses here so the player can read the Pikmin-population graph before
// continuing. "cleared" -> next board (or the deck-cull menu); "complete"/"failed" -> campaign list.
if (advResults != "") {
    // drawn over the plain menu backdrop (mode==menu) - same as the cull, not over the dimmed board
    draw_set_halign(fa_center); draw_set_font(fntMaru);
    var _rTxt = (advResults == "cleared") ? "Board Complete!" : ((advResults == "complete") ? "Scenario Complete!" : "Out of Days");
    draw_set_color((advResults == "failed") ? make_color_rgb(235, 90, 80) : make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, _guiH * 0.06, _rTxt, 2.1 * UI_TS, 2.1 * UI_TS, 0);
    if (advRun != undefined) {
        draw_set_color(make_color_rgb(210, 220, 214));
        dtext(_guiW * 0.5, _guiH * 0.06 + 44, advRun.name + "     Days left: " + string(advRun.daysLeft));
    }
    draw_set_color(make_color_rgb(200, 210, 205));
    dtext(_guiW * 0.5, _guiH * 0.06 + 74, "Pikmin population by phase");
    draw_set_halign(fa_left);

    var _grW = min(760, _guiW - 160), _grH = 260;
    var _grX = (_guiW - _grW) * 0.5, _grY = _guiH * 0.24;
    draw_results_graph(_grX, _grY, _grW, _grH);

    var _rby = _grY + _grH + 66;
    draw_set_halign(fa_center);
    // ORDER: pop graph -> (deck build, if this map has a cull rule) -> log text -> Save/Continue.
    // So a clear with a cull hands off to advCull, and it's the CULL's confirm that opens the log
    // (adventure_cull_confirm). Without a cull we go straight to the log from here.
    // adventure_show_lore_or skips the log entirely when dialog_text has no entry for the beat.
    if (advResults == "cleared") {
        if (ui_button(_guiW * 0.5 - 120, _rby, 240, 46, (advCull != undefined) ? "Continue (build deck)" : "Next Board", fntMaru)) {
            advResults = "";
            if (advCull != undefined) { mode = "menu"; menuScreen = "advCull"; }
            else adventure_show_lore_or("cleared", "next");
            draw_set_halign(fa_left); exit;
        }
    } else {
        if (ui_button(_guiW * 0.5 - 120, _rby, 240, 46, "Campaign List", fntMaru)) {
            var _outc2 = advResults;
            advResults = "";
            adventure_show_lore_or(_outc2, "menu");
            draw_set_halign(fa_left); exit;
        }
    }
    draw_set_halign(fa_left); draw_set_color(c_white);
    exit;
}

// ==================== ADVENTURE BETWEEN-MISSION LOG ====================
// A big ship's-log bubble shown after the results/pop-graph screen, streaming in letter-by-letter
// exactly like the tutorial banner - but with sfxText (a computer-log blip) instead of the
// tutorial's sfxTalk voice chatter, since this is a written transmission rather than someone
// speaking. Text comes from dialog_text(id) in scrDialog; the reveal is advanced by
// adventure_lore_tick (Step_0, ABOVE its mode!="playing" exit - this screen runs with mode=="menu").
if (advLore != undefined) {
    var _lrW = min(1040, _guiW - 160);
    var _lrPadX = 44, _lrPadTop = 34, _lrPadBot = 44, _lrSep = 30, _lrSc = 1.7 * UI_TS, _lrNs = 0.62;
    var _lrCf = 48;   // confirm-disc diameter
    draw_set_font(fntDialog);
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    var _lrTxtW = _lrW - _lrPadX * 2;
    var _lrTxtH = string_height_ext(advLore.text, _lrSep / _lrSc, _lrTxtW / _lrSc) * _lrSc;
    var _lrH = max(140, _lrPadTop + _lrTxtH + _lrCf + 14 + _lrPadBot);   // disc sits BELOW a long log
    var _lrX = (_guiW - _lrW) * 0.5;
    var _lrY = max(24, (_guiH - _lrH) * 0.5);
    draw_nineslice_scaled(sprTextBox, _lrX, _lrY, _lrW, _lrH, _lrNs, c_white, 1);
    draw_set_color(c_white);
    var _lrShown = string_copy(advLore.text, 1, floor(advLore.revealChars));
    draw_text_ext_transformed(_lrX + _lrPadX, _lrY + _lrPadTop, _lrShown, _lrSep / _lrSc, _lrTxtW / _lrSc, _lrSc, _lrSc, 0);
    draw_set_color(c_white);
    // Wordless green disc, DOUBLE DUTY: while the log is still streaming the first click dumps the
    // rest of the text; once fully revealed a click hands off to the between-mission hub.
    var _lrDone = (advLore.revealChars >= string_length(advLore.text));
    if (ui_icon_button(sprButtonConfirm, _lrX + _lrW - _lrPadX - _lrCf, _lrY + _lrH - _lrPadBot - _lrCf, _lrCf, "advLoreOk")) {
        if (!_lrDone) advLore.revealChars = string_length(advLore.text);
        else if (variable_struct_exists(advLore, "toHub") && !advLore.toHub) {
            var _lrThen = advLore.nextAct;   // standalone log (e.g. the campaign preamble): no hub after it
            advLore = undefined;
            adventure_after_results(_lrThen);
        } else adventure_show_outro(advLore.nextAct);
        draw_set_font(fntMaru); draw_set_halign(fa_left); exit;
    }
    ui_block_rect(_lrX, _lrY, _lrW, _lrH);
    draw_set_font(fntMaru); draw_set_halign(fa_left); draw_set_color(c_white);
    exit;
}

// ==================== ADVENTURE BETWEEN-MISSION HUB ====================
// Save / Play Next Map / Return to Menu, shown after the log text. Reached on EVERY mission, whether
// or not that beat had lore written - the log screen is the optional part, this isn't, or Save and
// Return-to-Menu would be unavailable on any mission without text.
if (advOutro != undefined) {
    var _hbW = min(620, _guiW - 200);
    var _hbPadX = 40, _hbPadTop = 34, _hbPadBot = 40, _hbNs = 0.62;
    var _hbBtnH = 46, _hbGap = 12;
    var _hbNext = (advOutro.nextAct == "next");   // no "next map" to play on a completed/failed run
    var _hbH = _hbPadTop + _hbBtnH * 3 + _hbGap * 2 + 26 + _hbPadBot;   // +26 = room for the unsaved-warning line
    var _hbX = (_guiW - _hbW) * 0.5;
    var _hbY = max(24, (_guiH - _hbH) * 0.5);
    draw_nineslice_scaled(sprTextBox, _hbX, _hbY, _hbW, _hbH, _hbNs, c_white, 1);
    var _hbBw = _hbW - _hbPadX * 2, _hbBx = _hbX + _hbPadX, _hbBy = _hbY + _hbPadTop;
    draw_set_font(fntDialog);

    // chrome-less ui_button_text entries (invisible until hovered, then a faint panel + orange
    // label) so the three read as one menu list inside the bubble rather than three boxed buttons.
    // Save is the ONLY path to disk for run progress - see adventure_saves_save's call sites.
    if (advOutro.saved) ui_button_text(_hbBx, _hbBy, _hbBw, _hbBtnH, "Saved", fntDialog, false);
    else if (ui_button_text(_hbBx, _hbBy, _hbBw, _hbBtnH, "Save", fntDialog)) { adventure_saves_save(); advOutro.saved = true; }
    _hbBy += _hbBtnH + _hbGap;

    if (!_hbNext) {
        ui_button_text(_hbBx, _hbBy, _hbBw, _hbBtnH, "Play Next Map", fntDialog, false);
    } else if (ui_button_text(_hbBx, _hbBy, _hbBw, _hbBtnH, "Play Next Map", fntDialog)) {
        advOutro = undefined;
        adventure_after_results("next");
        draw_set_font(fntMaru); exit;
    }
    _hbBy += _hbBtnH + _hbGap;

    if (ui_button_text(_hbBx, _hbBy, _hbBw, _hbBtnH, "Return to Menu", fntDialog)) {
        advOutro = undefined;
        adventure_after_results("menu");   // drops advRun and lands on the adventure/campaign select
        draw_set_font(fntMaru); exit;
    }
    // Save is the ONLY route to disk now, so leaving unsaved really does discard the run's progress -
    // say so plainly rather than letting the player find out afterwards.
    if (!advOutro.saved) {
        draw_set_halign(fa_center);
        draw_set_color(make_color_rgb(235, 170, 90));
        dtext(_hbX + _hbW * 0.5, _hbBy + _hbBtnH + 8, "Unsaved - leaving now discards this run's progress");
        draw_set_halign(fa_left); draw_set_color(c_white);
    }
    ui_block_rect(_hbX, _hbY, _hbW, _hbH);
    draw_set_font(fntMaru); draw_set_color(c_white);
    exit;
}

// ==================== BOARD SELECT MENU ====================
if (mode == "menu") {
    var _mgx0 = device_mouse_x_to_gui(0);
    var _mgy0 = device_mouse_y_to_gui(0);

    // screensaver: F1 on the main title (toggled in Step) hides the ENTIRE menu HUD -
    // title, buttons, fullscreen toggle, everything - so you just watch the field. F1 restores it.
    if (menuScreen == "main" && titleHideHud) exit;

    // fullscreen toggle (top-right corner on every menu screen; F11 works everywhere too)
    draw_set_font(fntMaru);
    if (ui_button(_guiW - 150, 12, 138, 28, window_get_fullscreen() ? "Windowed" : "Fullscreen")) {
        window_set_fullscreen(!window_get_fullscreen());
        save_settings();
    }

    // ============================= MAIN MENU =============================
    if (menuScreen == "main") {
        draw_set_halign(fa_center);
        draw_set_font(fntPikmin);        // the title keeps the stylised Pikmin font
        // PIKMIN, big - with a dark drop-shadow so it reads over the busy living background
        draw_set_color(make_color_rgb(22, 30, 24));
        draw_text_transformed(_guiW * 0.5 + 5, 138 + 5, "PIKMIN", 5.2 * UI_TS, 5.2 * UI_TS, 0);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 138, "PIKMIN", 5.2 * UI_TS, 5.2 * UI_TS, 0);
        // "Dandori Battle!" as the subtitle (no subtitles-that-aren't-titles here)
        draw_set_color(make_color_rgb(22, 30, 24));
        draw_text_transformed(_guiW * 0.5 + 3, 250 + 3, "Dandori Battle!", 1.9 * UI_TS, 1.9 * UI_TS, 0);
        draw_set_color(make_color_rgb(235, 245, 240));
        draw_text_transformed(_guiW * 0.5, 250, "Dandori Battle!", 1.9 * UI_TS, 1.9 * UI_TS, 0);
        draw_set_font(fntMaru);

        var _bw = 320, _bh = 54, _bx = _guiW * 0.5 - _bw * 0.5, _by = 312;
        if (ui_button(_bx, _by,        _bw, _bh, "Play",        fntMaru)) menuScreen = "board";
        if (ui_button(_bx + _bw + 10, _by, 150, _bh, "Adventure", fntMaru)) { menuScreen = "adventure"; menuAdvIdx = 0; menuAdvScroll = 0; advSaveConfirm = undefined; }
        // "How to Play" now opens the LESSON SELECT screen rather than launching straight into
        // scene 1 - replaying a single lesson used to be dev-only (the numbered squares that lived
        // here), and that's now a first-class player-facing choice on that screen.
        if (ui_button(_bx, _by + 66,   _bw, _bh, "How to Play", fntMaru)) { menuScreen = "tutorial"; menuTutIdx = 0; menuTutScroll = 0; }
        if (ui_button(_bx, _by + 132,  _bw, _bh, "Online",      fntMaru)) { menuScreen = "online"; menuNetField = ""; }
        if (ui_button(_bx, _by + 198,  _bw, _bh, "Options",     fntMaru)) menuScreen = "options";
        if (ui_button(_bx, _by + 264,  _bw, _bh, "Quit",        fntMaru)) game_end();
        // DEV: irregular solo board that exercises the adventure geometry + balance-data/board-jump
        // panel - both hidden unless Options > Interface > "Dev/Debug Tools" is ON (default off).
        if (global.settings.devTools) {
            if (ui_button(12, _guiH - 40, 96, 28, "Adv Test", fntMaru)) { start_advtest(); exit; }
            if (ui_button(116, _guiH - 40, 96, 28, "Debug", fntMaru)) { menuScreen = "debug"; menuDebugScroll = 0; }
        }

        // developer logo: animated fursona head, bottom-right corner (sprite origin is bottom-right,
        // faces left into the menu). Only drawn here, so F1's HUD-hide (above) also hides it.
        var _pfH  = 160;                                             // on-screen height (tuning knob)
        var _pfSc = _pfH / sprite_get_height(sprPolyFace);
        var _pfSub = (frameTick div 30) mod max(1, sprite_get_number(sprPolyFace)); // ~2 fps idle
        draw_sprite_ext(sprPolyFace, _pfSub, _guiW - 14, _guiH - 10, _pfSc, _pfSc, 0, c_white, 1);

        draw_set_halign(fa_left);
        draw_set_color(c_white);
        exit;
    }

    // ============================== ONLINE LOBBY ==============================
    // ======================= TUTORIAL / LESSON SELECT =======================
    // Same shape as the adventure menu: a scrolling list on the left with tier HEADERS and one row
    // per lesson, a description panel on the right, and a bottom action bar. Replaces the old
    // "How to Play launches scene 1, plus dev-only numbered jump squares" - replaying one lesson is
    // a normal thing a player wants, not a testing shortcut.
    if (menuScreen == "tutorial") {
        var _tuAll = tutorial_scenes();
        // flatten to display rows: a header per tier, then that tier's lessons. _tuIdx maps a row
        // back to its index in the FULL scene list, which is what the action buttons launch from.
        var _tuFlat = [];
        var _tuPick = [];
        var _tiers = tutorial_tiers();
        for (var _ti = 0; _ti < array_length(_tiers); _ti++) {
            var _tierId = _tiers[_ti].id;
            var _hdrPushed = false;
            for (var _li = 0; _li < array_length(_tuAll); _li++) {
                var _lt = variable_struct_exists(_tuAll[_li], "tier") ? _tuAll[_li].tier : "basic";
                if (_lt != _tierId) continue;
                if (!_hdrPushed) { array_push(_tuFlat, { hdr: true, text: _tiers[_ti].label }); _hdrPushed = true; }
                array_push(_tuFlat, { hdr: false, pick: array_length(_tuPick), scene: _tuAll[_li] });
                array_push(_tuPick, { scene: _tuAll[_li], idx: _li });
            }
        }
        var _nTu = array_length(_tuPick);
        menuTutIdx = clamp(menuTutIdx, 0, max(0, _nTu - 1));
        var _selL = (_nTu > 0) ? _tuPick[menuTutIdx] : undefined;

        draw_set_alpha(0.62); draw_set_color(c_black); draw_rectangle(0, 0, _guiW, _guiH, false); draw_set_alpha(1);

        draw_set_halign(fa_center); draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 14, "HOW TO PLAY", 2.0 * UI_TS, 2.0 * UI_TS, 0);
        draw_set_halign(fa_left); draw_set_color(c_white);
        if (ui_button(20, 12, 110, 30, "< Back")) { menuScreen = "main"; exit; }

        var _tuBarY = _guiH - 74;
        var _tuLX = 20, _tuLW = 340, _tuLTop = 74, _tuRowH = 34;
        var _tuMgx = device_mouse_x_to_gui(0), _tuMgy = device_mouse_y_to_gui(0);
        var _tuRows = max(1, floor((_tuBarY - 12 - _tuLTop) / _tuRowH));
        var _tuMaxTop = max(0, array_length(_tuFlat) - _tuRows);
        if (_tuMgx >= _tuLX && _tuMgx <= _tuLX + _tuLW && _tuMgy >= _tuLTop && _tuMgy <= _tuLTop + _tuRows * _tuRowH) {
            if (mouse_wheel_up())   menuTutScroll -= 1;
            if (mouse_wheel_down()) menuTutScroll += 1;
        }
        menuTutScroll = clamp(menuTutScroll, 0, _tuMaxTop);

        draw_set_alpha(0.45); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_tuLX, _tuLTop, _tuLX + _tuLW, _tuLTop + _tuRows * _tuRowH, false); draw_set_alpha(1);
        for (var _r = 0; _r < _tuRows; _r++) {
            var _fi = menuTutScroll + _r;
            if (_fi >= array_length(_tuFlat)) break;
            var _fe = _tuFlat[_fi];
            var _ey = _tuLTop + _r * _tuRowH;
            draw_set_font(fntMaru);
            if (_fe.hdr) {
                draw_set_color(make_color_rgb(255, 224, 120));
                dtext(_tuLX + 8, _ey + 8, _fe.text);
                draw_set_color(c_white);
            } else {
                var _sel = (_fe.pick == menuTutIdx);
                var _hov = (_tuMgx >= _tuLX && _tuMgx < _tuLX + _tuLW && _tuMgy >= _ey && _tuMgy < _ey + _tuRowH);
                if (_hov) global.uiMouseConsumed = true;
                draw_set_alpha(_sel ? 0.9 : (_hov ? 0.7 : 0.4));
                draw_set_color(_sel ? make_color_rgb(58, 82, 66) : make_color_rgb(38, 46, 52));
                draw_rectangle(_tuLX + 20, _ey + 2, _tuLX + _tuLW - 4, _ey + _tuRowH - 2, false); draw_set_alpha(1);
                draw_set_color(_sel ? make_color_rgb(255, 224, 120) : make_color_rgb(200, 210, 215));
                dtext(_tuLX + 30, _ey + 8, _fe.scene.name);
                draw_set_color(c_white);
                if (_hov && mouse_check_button_pressed(mb_left)) menuTutIdx = _fe.pick;
            }
        }
        draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
        if (menuTutScroll > 0)         dtext(_tuLX + _tuLW * 0.5, _tuLTop + 1, "^");
        if (menuTutScroll < _tuMaxTop) dtext(_tuLX + _tuLW * 0.5, _tuLTop + _tuRows * _tuRowH - 15, "v");
        draw_set_halign(fa_left); draw_set_color(c_white);

        // ---- right: what this lesson teaches ----
        if (_selL != undefined) {
            var _tuPX = _tuLX + _tuLW + 40, _tuPW = _guiW - _tuPX - 30;
            draw_set_color(make_color_rgb(255, 224, 120));
            draw_text_transformed(_tuPX, _tuLTop + 4, _selL.scene.name, 1.6 * UI_TS, 1.6 * UI_TS, 0);
            draw_set_color(make_color_rgb(160, 168, 176));
            dtext(_tuPX, _tuLTop + 44, (variable_struct_exists(_selL.scene, "tier") ? string_upper(_selL.scene.tier) : "BASIC") + " LESSON");
            draw_set_color(make_color_rgb(215, 222, 228));
            var _tuDesc = variable_struct_exists(_selL.scene, "desc") ? _selL.scene.desc : "";
            dtext_ext(_tuPX, _tuLTop + 80, _tuDesc, 24, _tuPW);
            draw_set_color(c_white);
        }

        // ---- bottom bar: the two full runs, then the single selected lesson ----
        draw_set_alpha(0.5); draw_set_color(make_color_rgb(14, 18, 22));
        draw_rectangle(0, _tuBarY, _guiW, _guiH, false); draw_set_alpha(1);
        // one "Play <Tier> Tutorial" button per tier that ACTUALLY HAS lessons - the intermediate
        // (per-colour) and advanced (experimental-rule) tiers therefore show nothing at all until
        // their lessons are written, instead of offering a button that would launch an empty run.
        var _tuBw = 250, _tuBg = 14, _tuBx = _tuLX;
        for (var _ti = 0; _ti < array_length(_tiers); _ti++) {
            var _tierScenes = tutorial_scenes_of_tier(_tiers[_ti].id);
            if (array_length(_tierScenes) == 0) continue;
            if (ui_button(_tuBx, _tuBarY + 14, _tuBw, 44, "Play " + _tiers[_ti].word + " Tutorial", fntMaru)) {
                start_tutorial_set(_tierScenes); exit;
            }
            _tuBx += _tuBw + _tuBg;
        }
        // a single lesson is launched as a ONE-ENTRY scene list, so it ends after itself instead of
        // rolling on into the rest of the script
        if (_selL != undefined && ui_button(_guiW - _tuBw - 20, _tuBarY + 14, _tuBw, 44, "Start Lesson", fntMaru)) {
            start_tutorial_set([_selL.scene]); exit;
        }
        exit;
    }

    // ======================= LOBBY =======================
    // Sits between the connect screen and board-select. Everyone who is connected appears here -
    // the host, the one P2 player, and any number of spectators - and the HOST assigns who plays.
    // The host advances to board-select when ready; everyone else waits for the START broadcast.
    if (menuScreen == "lobby") {
        if (!net_online() || global.net.status == "disconnected" || global.net.status == "closed") { net_close(); menuScreen = "main"; exit; }
        // a client that connected MID-GAME is pushed a start + state by the host (Step_0) and drops
        // straight into the live game from here, without ever seeing board-select
        if (global.net.startBoard != "") { var _sb = global.net.startBoard; global.net.startBoard = ""; start_game_online(_sb, false); exit; }

        draw_set_halign(fa_center); draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 40, "LOBBY", 2.4 * UI_TS, 2.4 * UI_TS, 0);
        draw_set_halign(fa_left); draw_set_color(c_white);

        if (ui_button(20, 16, 120, 30, "< Leave")) { net_close(); menuScreen = "main"; exit; }

        var _lbX = _guiW * 0.5 - 300, _lbW = 600, _lbTop = 110, _lbRowH = 44;
        draw_set_color(make_color_rgb(190, 200, 210));
        dtext(_lbX, _lbTop - 26, net_is_host() ? "Connected (click a row's button to seat them):" : "Connected:");
        draw_set_color(c_white);

        // The HOST renders from its own authoritative client list (it needs each client's SOCKET to
        // reseat them); everyone else renders the roster the host broadcasts. Same visual either way.
        var _rows = [];
        if (net_is_host()) {
            array_push(_rows, { name: global.net.localName + "  (you)", role: "player", seat: 0, sock: -1 });
            var _cl = global.net.clients;
            for (var _i = 0; _i < array_length(_cl); _i++) array_push(_rows, { name: _cl[_i].name, role: _cl[_i].role, seat: _cl[_i].seat, sock: _cl[_i].sock });
        } else {
            var _ro = global.net.roster;
            for (var _i = 0; _i < array_length(_ro); _i++) {
                var _isMe = (_ro[_i].seat == global.net.localSeat && _ro[_i].role == global.net.role && _ro[_i].name == global.net.localName);
                array_push(_rows, { name: _ro[_i].name + (_isMe ? "  (you)" : ""), role: _ro[_i].role, seat: _ro[_i].seat, sock: -1 });
            }
        }

        var _lbVis = max(1, floor((_guiH - 150 - _lbTop) / _lbRowH));
        var _lbMax = max(0, array_length(_rows) - _lbVis);
        if (ui_mouse_in(_lbX, _lbTop, _lbW, _lbVis * _lbRowH)) {
            if (mouse_wheel_up())   menuLobbyScroll -= 1;
            if (mouse_wheel_down()) menuLobbyScroll += 1;
        }
        menuLobbyScroll = clamp(menuLobbyScroll, 0, _lbMax);

        draw_set_alpha(0.35); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_lbX, _lbTop, _lbX + _lbW, _lbTop + _lbVis * _lbRowH, false);
        draw_set_alpha(1);

        for (var _d = 0; _d < _lbVis; _d++) {
            var _ri = menuLobbyScroll + _d;
            if (_ri >= array_length(_rows)) break;
            var _row = _rows[_ri];
            var _ry = _lbTop + _d * _lbRowH;

            // seat badge: P1 / P2 for the two player seats, SPECTATOR for everyone else
            var _seatLbl = (_row.seat == 0) ? "P1" : ((_row.seat == 1) ? "P2" : "SPECTATOR");
            var _seatCol = (_row.seat == 0) ? make_color_rgb(120, 180, 255)
                         : ((_row.seat == 1) ? make_color_rgb(255, 140, 140) : make_color_rgb(150, 155, 162));
            draw_set_color(_seatCol);
            dtext(_lbX + 12, _ry + 14, _seatLbl);
            draw_set_color(c_white);
            dtext(_lbX + 130, _ry + 14, _row.name);

            // host-only reseat control. The host's OWN row has no button - the host is permanently P1;
            // letting it demote itself would leave the authoritative seat empty.
            if (net_is_host() && _row.sock >= 0) {
                var _mkPlayer = (_row.role != "player");
                if (ui_button(_lbX + _lbW - 170, _ry + 6, 160, 32, _mkPlayer ? "Make Player" : "Make Spectator", fntMaru)) {
                    net_assign_role(_row.sock, _mkPlayer ? "player" : "spectator");
                }
            }
        }

        // footer
        var _lbFy = _lbTop + _lbVis * _lbRowH + 18;
        draw_set_color(make_color_rgb(150, 160, 175));
        dtext(_lbX, _lbFy, "Spectators mirror the game and never take input. They can join at any time, including mid-game.");
        draw_set_color(c_white);
        if (net_is_host()) {
            if (array_length(global.net.clients) == 0) {
                draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
                dtext(_guiW * 0.5, _lbFy + 26, "Waiting for players to connect...");
                draw_set_halign(fa_left); draw_set_color(c_white);
            }
            // deliberately NOT gated on anyone having joined - the host may want to set up the board
            // first, and clients can still arrive later (including after the game has started)
            if (ui_button(_guiW * 0.5 - 130, _lbFy + 54, 260, 40, "Board Select >", fntMaru)) { menuScreen = "board"; exit; }
        } else {
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
            dtext(_guiW * 0.5, _lbFy + 44, "Waiting for " + ((global.net.remoteName != "") ? global.net.remoteName : "the host") + " to choose a board...");
            draw_set_halign(fa_left); draw_set_color(c_white);
        }
        exit;
    }

    if (menuScreen == "online") {
        // handshake complete -> LOBBY (seat assignment happens there; the host moves everyone on to
        // board-select). Was straight to board-select back when a session was strictly 1v1.
        // The HOST enters the lobby the moment its server is up ("listening"), rather than waiting on
        // a first connection - the lobby IS the waiting room now, and it shows the roster filling up.
        // A client still waits here until its handshake completes ("ready").
        if (net_online() && (global.net.status == "ready" || (global.net.mode == "host" && global.net.status == "listening"))) { menuScreen = "lobby"; menuLobbyScroll = 0; exit; }

        draw_set_halign(fa_center);
        draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 40, "ONLINE", 2.4 * UI_TS, 2.4 * UI_TS, 0);
        draw_set_halign(fa_left);
        draw_set_color(c_white);

        // also persist on the way out, so a name typed and then abandoned is still remembered next time
        if (ui_button(20, 16, 120, 30, "< Back")) { save_settings(); net_close(); menuScreen = "main"; }

        // --- editable text field helper (immediate mode, backed by keyboard_string) ---
        var _fx = _guiW * 0.5 - 210, _fw = 420, _fh = 40;
        var _drawField = function(_x, _y, _w, _h, _label, _val, _key) {
            var _focused = (menuNetField == _key);
            draw_set_color(make_color_rgb(200, 210, 220));
            dtext(_x, _y - 20, _label);
            draw_set_alpha(0.9); draw_set_color(_focused ? make_color_rgb(50, 62, 84) : make_color_rgb(34, 40, 52));
            draw_rectangle(_x, _y, _x + _w, _y + _h, false);
            draw_set_alpha(1); draw_set_color(_focused ? make_color_rgb(255, 224, 120) : make_color_rgb(90, 100, 120));
            draw_rectangle(_x, _y, _x + _w, _y + _h, true);
            draw_set_color(c_white);
            var _shown = _val + ((_focused && (current_time div 500) mod 2 == 0) ? "|" : "");
            dtext(_x + 10, _y + 11, _shown);
            return (ui_mouse_in(_x, _y, _w, _h) && mouse_check_button_pressed(mb_left)); // clicked -> focus
        };

        // resolve the chosen port up front - HOST needs it, and so does the manual-join fallback.
        var _netPort = (menuNetPort != "") ? clamp(real(menuNetPort), 1, 65535) : NET_PORT;

        if (net_online() && global.net.status == "connecting") {
            draw_set_halign(fa_center);
            draw_set_color(make_color_rgb(255, 224, 120));
            dtext(_guiW * 0.5, 300, "Connecting...");
            draw_set_halign(fa_left);
            draw_set_color(c_white);
            if (ui_button(_guiW * 0.5 - 90, 340, 180, 36, "Cancel", fntMaru)) net_close();
            draw_set_halign(fa_left); draw_set_color(c_white);
            exit;
        }

        // ---- BROWSER-FIRST. Games announce themselves over UDP (net_beacon_tick on the host), so
        // the list fills in by itself and nobody types an IP in the normal case. Manual entry stays
        // as a demoted fallback at the bottom, because broadcast legitimately fails on some networks
        // (different subnets, or Wi-Fi client isolation) and then it's the ONLY way in.
        net_discovery_listen();     // idempotent - opens the listen socket the first frame we're here
        net_discovery_prune();      // hosts that stopped announcing drop off on their own

        // NAME - shared by hosting and joining alike, so it stays at the top above everything.
        if (_drawField(_fx, 96, _fw, _fh, "Your name:", menuNetName, "name")) { menuNetField = "name"; keyboard_string = menuNetName; }
        if (menuNetField == "name") menuNetName = keyboard_string;

        if (ui_button(_guiW * 0.5 - 130, 152, 260, 42, "HOST A GAME", fntMaru)) { save_settings(); net_host(menuNetName, _netPort); menuNetField = ""; }

        // ---- discovered games ----
        var _glX = _guiW * 0.5 - 340, _glW = 680, _glTop = 236, _glRowH = 52;
        var _found = global.net.discFound;
        draw_set_color(make_color_rgb(200, 210, 220));
        dtext(_glX, _glTop - 26, "Games on your network:");
        draw_set_color(make_color_rgb(150, 160, 175));
        draw_set_halign(fa_right);
        dtext(_glX + _glW, _glTop - 26, "searching...");
        draw_set_halign(fa_left);
        draw_set_color(c_white);

        var _glVis = max(1, floor((_guiH - 190 - _glTop) / _glRowH));
        var _glMax = max(0, array_length(_found) - _glVis);
        if (ui_mouse_in(_glX, _glTop, _glW, _glVis * _glRowH)) {
            if (mouse_wheel_up())   menuNetBrowseScroll -= 1;
            if (mouse_wheel_down()) menuNetBrowseScroll += 1;
        }
        menuNetBrowseScroll = clamp(menuNetBrowseScroll, 0, _glMax);

        draw_set_alpha(0.35); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_glX, _glTop, _glX + _glW, _glTop + _glVis * _glRowH, false);
        draw_set_alpha(1);

        if (array_length(_found) == 0) {
            draw_set_color(make_color_rgb(150, 155, 162));
            dtext(_glX + 14, _glTop + 16, "No games found");
            draw_set_color(c_white);
        }
        for (var _d = 0; _d < _glVis; _d++) {
            var _fi = menuNetBrowseScroll + _d;
            if (_fi >= array_length(_found)) break;
            var _fe = _found[_fi];
            var _fy = _glTop + _d * _glRowH;
            var _fHov = ui_mouse_in(_glX, _fy, _glW - 130, _glRowH);
            if (_fHov) { draw_set_alpha(0.3); draw_set_color(make_color_rgb(50, 58, 66)); draw_rectangle(_glX, _fy, _glX + _glW, _fy + _glRowH, false); draw_set_alpha(1); }

            draw_set_color(c_white);
            dtext(_glX + 14, _fy + 10, _fe.name);
            // STATUS badge. SETUP = still in the lobby/board-select, so joining can actually get you
            // a seat; LIVE = a match is under way, where joining always makes you a spectator (the
            // seat's position is already committed - see the HELLO handler in scrNet).
            draw_set_color(_fe.inGame ? make_color_rgb(255, 150, 90) : make_color_rgb(130, 210, 140));
            dtext(_glX + 14 + dtext_width(_fe.name) + 14, _fy + 10, _fe.inGame ? "LIVE" : "SETUP");
            draw_set_color(make_color_rgb(160, 168, 176));
            var _sub = string(_fe.players) + " player" + ((_fe.players == 1) ? "" : "s");
            if (_fe.spectators > 0) _sub += ", " + string(_fe.spectators) + " watching";
            if (_fe.board != "") _sub += "  -  " + string(_fe.board);
            dtext(_glX + 14, _fy + 30, _sub);
            draw_set_color(make_color_rgb(120, 128, 136));
            draw_set_halign(fa_right);
            dtext(_glX + _glW - 140, _fy + 30, string(_fe.ip));
            draw_set_halign(fa_left);
            draw_set_color(c_white);

            if (ui_button(_glX + _glW - 126, _fy + 10, 116, 32, _fe.inGame ? "Watch" : "Join", fntMaru)) {
                save_settings();   // the name is genuinely "picked" at the moment it's used
                net_join(_fe.ip, menuNetName, _fe.port);
                menuNetField = "";
            }
        }

        // ---- manual fallback, deliberately small and last ----
        var _mfY = _glTop + _glVis * _glRowH + 16;
        draw_set_alpha(0.45); draw_set_color(make_color_rgb(90, 100, 120));
        draw_line(_glX, _mfY, _glX + _glW, _mfY);
        draw_set_alpha(1);
        draw_set_color(make_color_rgb(150, 160, 175));
        dtext(_glX, _mfY + 12, "Join by IP:");
        draw_set_color(c_white);
        var _mIpW = 260, _mPortW = 90;
        if (_drawField(_glX + 190, _mfY + 6, _mIpW, 32, "", menuNetIP, "ip")) { menuNetField = "ip"; keyboard_string = menuNetIP; }
        if (menuNetField == "ip") menuNetIP = keyboard_string;
        if (_drawField(_glX + 190 + _mIpW + 10, _mfY + 6, _mPortW, 32, "", menuNetPort, "port")) { menuNetField = "port"; keyboard_string = menuNetPort; }
        if (menuNetField == "port") {   // digits only, max 5
            menuNetPort = string_digits(keyboard_string);
            if (string_length(menuNetPort) > 5) menuNetPort = string_copy(menuNetPort, 1, 5);
            keyboard_string = menuNetPort;
        }
        if (ui_button(_glX + 190 + _mIpW + _mPortW + 24, _mfY + 6, 110, 32, "Connect", fntMaru)) { save_settings(); net_join(menuNetIP, menuNetName, _netPort); menuNetField = ""; }

        if (global.net.status == "failed" || global.net.status == "disconnected" || global.net.status == "kicked") {
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(230, 120, 110));
            var _errMsg = (global.net.status == "failed") ? "Connection failed - check the IP and port."
                        : ((global.net.status == "kicked") ? "The host removed you from the session." : "Disconnected from the host.");
            dtext(_guiW * 0.5, _mfY + 56, _errMsg);
            draw_set_halign(fa_left); draw_set_color(c_white);
        }

        draw_set_halign(fa_left);
        draw_set_color(c_white);
        exit;
    }

    // ============================== OPTIONS ==============================
    if (menuScreen == "options") {
        draw_set_halign(fa_center);
        draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 40, "OPTIONS", 2.4 * UI_TS, 2.4 * UI_TS, 0);
        draw_set_font(fntMaru);
        draw_set_halign(fa_left);

        if (ui_button(20, 16, 120, 30, "< Back")) menuScreen = "main";

        // big, comfortable buttons in fntMaru
        var _ow = 400, _og = 24, _obh = 46, _orh = 56;
        var _ox0 = _guiW * 0.5 - _ow - _og * 0.5, _ox1 = _guiW * 0.5 + _og * 0.5;

        // ---- SCROLL: the body (everything below the fixed OPTIONS header/Back button) is taller
        // than the screen once all the expRules rows exist, so it scrolls within a fixed viewport.
        // All Y coordinates below are BASE (unscrolled) values; ui_scroll_y() converts to screen
        // space, and rows are only drawn/clickable when ui_row_visible() says they fall inside the
        // viewport - this is what keeps a scrolled-past row from rendering over (and stealing clicks
        // from) the header. (Plain functions, not closures - see ui_scroll_y's doc comment in scrUI.)
        var _viewTop = 70, _viewBot = _guiH - 14;

        // --- Gameplay (2 columns x 4) ---
        if (ui_row_visible(96, 24, menuOptionsScroll, _viewTop, _viewBot)) {
            draw_set_halign(fa_center);
            draw_set_font(fntMaru);
            draw_set_color(make_color_rgb(200, 210, 205));
            draw_text_transformed(_guiW * 0.5, ui_scroll_y(96, menuOptionsScroll), "Gameplay", 1.5 * UI_TS, 1.5 * UI_TS, 0);
            draw_set_halign(fa_left);
        }

        var _oy = 128;
        if (ui_row_visible(_oy, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy, menuOptionsScroll),            _ow, _obh, "Reds Strike Twice: "     + (global.expRules.red       ? "ON" : "off"), fntMaru)) { global.expRules.red = !global.expRules.red;             save_settings(); } }
        if (ui_row_visible(_oy, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy, menuOptionsScroll),            _ow, _obh, "Blues Lifeguard: "       + (global.expRules.blue      ? "ON" : "off"), fntMaru)) { global.expRules.blue = !global.expRules.blue;           save_settings(); } }
        if (ui_row_visible(_oy + _orh, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy + _orh, menuOptionsScroll),     _ow, _obh, "Yellows Cross Chasms: "  + (global.expRules.yellow    ? "ON" : "off"), fntMaru)) { global.expRules.yellow = !global.expRules.yellow;       save_settings(); } }
        if (ui_row_visible(_oy + _orh, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy + _orh, menuOptionsScroll),     _ow, _obh, "2x Weight Rushes: "      + (global.expRules.rush      ? "ON" : "off"), fntMaru)) { global.expRules.rush = !global.expRules.rush;           save_settings(); } }
        if (ui_row_visible(_oy + _orh * 2, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy + _orh * 2, menuOptionsScroll), _ow, _obh, "Enemies Heal At Sunset: "+ (global.expRules.enemyHeal ? "ON" : "off"), fntMaru)) { global.expRules.enemyHeal = !global.expRules.enemyHeal; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 2, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy + _orh * 2, menuOptionsScroll), _ow, _obh, "Ice Pikmin Freeze Enemies: " + (global.expRules.iceFreeze ? "ON" : "off"), fntMaru)) { global.expRules.iceFreeze = !global.expRules.iceFreeze; save_settings(); } }
        var _capLbl = (global.expRules.bossCap == -1) ? "No Cap" : ((global.expRules.bossCap == 0) ? "No Bosses" : string(global.expRules.bossCap));
        if (ui_row_visible(_oy + _orh * 3, _obh, menuOptionsScroll, _viewTop, _viewBot)) {
            if (ui_button(_ox0, ui_scroll_y(_oy + _orh * 3, menuOptionsScroll), _ow, _obh, "Cap Boss Spawns: " + _capLbl, fntMaru)) {
                var _bc = global.expRules.bossCap;   // cycle 1..5 -> No Cap(-1) -> No Bosses(0) -> 1
                global.expRules.bossCap = (_bc >= 1 && _bc < 5) ? (_bc + 1) : ((_bc == 5) ? -1 : ((_bc == -1) ? 0 : 1));
                save_settings();
            }
        }
        if (ui_row_visible(_oy + _orh * 3, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy + _orh * 3, menuOptionsScroll), _ow, _obh, "Explosions Damage Enemies: " + (global.expRules.explodeEnemies ? "ON" : "off"), fntMaru)) { global.expRules.explodeEnemies = !global.expRules.explodeEnemies; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 4, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy + _orh * 4, menuOptionsScroll), _ow, _obh, "Two-Day Maps (7-phase track): " + (global.expRules.twoDayMode ? "ON" : "off"), fntMaru)) { global.expRules.twoDayMode = !global.expRules.twoDayMode; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 4, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy + _orh * 4, menuOptionsScroll), _ow, _obh, "Chaos Swaps (random tiles): " + (global.expRules.randomSwaps ? "ON" : "off"), fntMaru)) { global.expRules.randomSwaps = !global.expRules.randomSwaps; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 5, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy + _orh * 5, menuOptionsScroll), _ow, _obh, "Ice Is A Floor (not a wall): " + (global.expRules.iceFloor ? "ON" : "off"), fntMaru)) { global.expRules.iceFloor = !global.expRules.iceFloor; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 5, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_oy + _orh * 5, menuOptionsScroll), _ow, _obh, "Treasures Slide On Ice: " + (global.expRules.iceSlide ? "ON" : "off"), fntMaru)) { global.expRules.iceSlide = !global.expRules.iceSlide; save_settings(); } }
        if (ui_row_visible(_oy + _orh * 6, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_oy + _orh * 6, menuOptionsScroll), _ow, _obh, "Ice Pikmin Freeze Water (x3): " + (global.expRules.iceFreezeWater ? "ON" : "off"), fntMaru)) { global.expRules.iceFreezeWater = !global.expRules.iceFreezeWater; save_settings(); } }

        // --- Graphics ---
        var _gfxHeadY = _oy + _orh * 7 + 18;
        if (ui_row_visible(_gfxHeadY, 24, menuOptionsScroll, _viewTop, _viewBot)) {
            draw_set_halign(fa_center);
            draw_set_font(fntMaru);
            draw_set_color(make_color_rgb(200, 210, 205));
            draw_text_transformed(_guiW * 0.5, ui_scroll_y(_gfxHeadY, menuOptionsScroll), "Graphics", 1.5 * UI_TS, 1.5 * UI_TS, 0);
            draw_set_halign(fa_left);
        }
        var _gfxY = _gfxHeadY + 30;
        if (ui_row_visible(_gfxY, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_gfxY, menuOptionsScroll), _ow, _obh, "Animations: " + (global.expRules.anims ? "ON" : "off"), fntMaru)) { global.expRules.anims = !global.expRules.anims; save_settings(); } }
        if (ui_row_visible(_gfxY, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox1, ui_scroll_y(_gfxY, menuOptionsScroll), _ow, _obh, window_get_fullscreen() ? "Display: Fullscreen" : "Display: Windowed", fntMaru)) { window_set_fullscreen(!window_get_fullscreen()); save_settings(); } }

        // --- Interface ---
        var _ifHeadY = _gfxY + _obh + 18;
        if (ui_row_visible(_ifHeadY, 24, menuOptionsScroll, _viewTop, _viewBot)) {
            draw_set_halign(fa_center);
            draw_set_font(fntMaru);
            draw_set_color(make_color_rgb(200, 210, 205));
            draw_text_transformed(_guiW * 0.5, ui_scroll_y(_ifHeadY, menuOptionsScroll), "Interface", 1.5 * UI_TS, 1.5 * UI_TS, 0);
            draw_set_halign(fa_left);
        }
        var _iy = _ifHeadY + 30;
        if (ui_row_visible(_iy, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_iy, menuOptionsScroll), _ow, _obh, "New-pick Default: " + (defaultSelectAll ? "ALL" : "NONE"), fntMaru)) { defaultSelectAll = !defaultSelectAll; save_settings(); } }
        // which shared power-card set (ALL1/ALL2) is mixed into every board's treasure deck (or random)
        var _allLbl = (global.settings.allSet == 1) ? "ALL1" : ((global.settings.allSet == 2) ? "ALL2" : "Random");
        if (ui_row_visible(_iy, _obh, menuOptionsScroll, _viewTop, _viewBot)) {
            if (ui_button(_ox1, ui_scroll_y(_iy, menuOptionsScroll), _ow, _obh, "Power Card Set: " + _allLbl, fntMaru)) {
                var _a = global.settings.allSet;
                global.settings.allSet = (_a == 1) ? 2 : ((_a == 2) ? 0 : 1);   // ALL1 -> ALL2 -> Random -> ALL1
                save_settings();
            }
        }
        if (ui_row_visible(_iy + _obh + 6, _obh, menuOptionsScroll, _viewTop, _viewBot)) { if (ui_button(_ox0, ui_scroll_y(_iy + _obh + 6, menuOptionsScroll), _ow, _obh, "Dev/Debug Tools: " + (global.settings.devTools ? "ON" : "off"), fntMaru)) { global.settings.devTools = !global.settings.devTools; save_settings(); } }

        // --- Audio (Master / BGM / SFX sliders) ---
        var _auHeadY = _iy + (_obh + 6) + _obh + 20;
        if (ui_row_visible(_auHeadY, 36 + 3 * 40 + 12, menuOptionsScroll, _viewTop, _viewBot)) draw_audio_controls(_ox0, ui_scroll_y(_auHeadY, menuOptionsScroll), (_ox1 + _ow) - _ox0);

        var _noteY = _auHeadY + 36 + 3 * 40 + 12;
        if (ui_row_visible(_noteY, 20, menuOptionsScroll, _viewTop, _viewBot)) {
            draw_set_halign(fa_center);
            draw_set_font(fntMaru);
            draw_set_color(make_color_rgb(160, 170, 165));
            draw_text_transformed(_guiW * 0.5, ui_scroll_y(_noteY, menuOptionsScroll), "Changes are saved automatically", 1.2 * UI_TS, 1.2 * UI_TS, 0);
            draw_set_halign(fa_left);
            draw_set_color(c_white);
        }

        // ---- scroll input + scrollbar ----
        var _contentBot = _noteY + 20;                          // bottom edge of the last content row
        var _viewH = _viewBot - _viewTop;
        var _maxScroll = max(0, _contentBot - _viewBot);
        var _mgxO = device_mouse_x_to_gui(0), _mgyO = device_mouse_y_to_gui(0);
        var _overBody = (_mgxO >= _ox0 - 20 && _mgxO <= _ox1 + _ow + 20 && _mgyO >= _viewTop && _mgyO <= _viewBot);
        if (_overBody) {
            if (mouse_wheel_up())   menuOptionsScroll -= 60;
            if (mouse_wheel_down()) menuOptionsScroll += 60;
        }
        menuOptionsScroll = clamp(menuOptionsScroll, 0, _maxScroll);

        if (_maxScroll > 0) {
            var _barX = _ox1 + _ow + 16, _barW = 10;
            draw_set_alpha(0.4); draw_set_color(make_color_rgb(20, 24, 28));
            draw_roundrect(_barX, _viewTop, _barX + _barW, _viewBot, false);
            draw_set_alpha(1);
            var _thumbH = max(30, _viewH * (_viewH / (_contentBot - _viewTop)));
            var _thumbY = _viewTop + (menuOptionsScroll / _maxScroll) * (_viewH - _thumbH);
            var _overThumb = (_mgxO >= _barX - 4 && _mgxO <= _barX + _barW + 4 && _mgyO >= _thumbY && _mgyO <= _thumbY + _thumbH);
            if (!variable_global_exists("uiOptScrollDrag")) global.uiOptScrollDrag = false;
            if (global.uiOptScrollDrag && !mouse_check_button(mb_left)) global.uiOptScrollDrag = false;
            if (_overThumb && mouse_check_button_pressed(mb_left)) global.uiOptScrollDrag = true;
            if (global.uiOptScrollDrag) {
                menuOptionsScroll = clamp(round((_mgyO - _viewTop - _thumbH * 0.5) / max(1, _viewH - _thumbH) * _maxScroll), 0, _maxScroll);
                global.uiMouseConsumed = true;
            }
            draw_set_color(_overThumb || global.uiOptScrollDrag ? make_color_rgb(150, 175, 210) : make_color_rgb(110, 130, 160));
            draw_roundrect(_barX, _thumbY, _barX + _barW, _thumbY + _thumbH, false);
            draw_set_color(c_white);
        }
        exit;
    }

    // ============================== DEBUG ==============================
    // (menuScreen == "debug") - dev-only balance-data + quick-launch panel: trigger a tournament
    // (sim_tournament_* in scrSim) on any board or the whole roster, see the last completed
    // tournament's win-rate summary, and jump straight into any board/adventure-mission bypassing
    // seat-select. Not gated behind anything - remove/lock this whole screen pre-ship if desired.
    if (menuScreen == "debug") {
        if (!global.settings.devTools) { menuScreen = "main"; exit; }   // toggled off elsewhere mid-screen - bail out

        draw_set_halign(fa_center);
        draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 40, "DEBUG", 2.4 * UI_TS, 2.4 * UI_TS, 0);
        draw_set_halign(fa_left);

        if (ui_button(20, 16, 120, 30, "< Back")) menuScreen = "main";

        var _boards = global.boardData.boards;
        var _nB = array_length(_boards);

        // board ids currently highlighted in the list (multi-select; click a row to toggle it).
        // NOTE: use arr_has(_selIds, id) directly at call sites, not a closure - GML function
        // literals here don't capture enclosing `var` locals (they resolve through instance scope),
        // so a closure referencing _selIds throws "not set before reading it" the first time it runs.
        var _selIds = menuDebugSelected;
        var _selCount = array_length(_selIds);

        // ---- left: balance-data panel ----
        var _dbX = 20, _dbW = 360, _dbY = 90;
        draw_set_color(make_color_rgb(200, 210, 205));
        dtext(_dbX, _dbY, "Balance Data");
        draw_set_color(c_white);
        var _dby = _dbY + 30;

        // Tournament: selected board(s) - greyed out until at least one board is highlighted
        if (_selCount == 0) {
            ui_button_disabled(_dbX, _dby, _dbW, 40, "Tournament: Selected Board(s)");
        } else if (ui_button(_dbX, _dby, _dbW, 40, "Tournament: Selected Board(s) (" + string(_selCount) + ")", fntMaru)) {
            if (_selCount == 1) sim_tournament_begin(_selIds[0], 60);
            else sim_tournament_run_boards(_selIds, 30);
        }
        _dby += 48;

        if (ui_button(_dbX, _dby, _dbW, 40, "Tournament: ALL Boards (30/pair)", fntMaru)) {
            var _allIds = [];
            for (var _bi2 = 0; _bi2 < _nB; _bi2++) array_push(_allIds, _boards[_bi2].id);
            sim_tournament_run_boards(_allIds, 30);
        }
        _dby += 48;

        // Play Selected Scenario - only meaningful for exactly one board (a live human-vs-human game)
        if (_selCount != 1) {
            ui_button_disabled(_dbX, _dby, _dbW, 40, "Play Selected Scenario");
        } else if (ui_button(_dbX, _dby, _dbW, 40, "Play Selected Scenario", fntMaru)) {
            start_game(_selIds[0], ["human", "human"]); exit;
        }
        _dby += 48;

        // Probe Selected Map(s) - ONE verbose seeded game per selected board (sim_probe, scrSim.gml),
        // full AI decision log to ai_debug.txt - unlike a tournament, which silences that logging
        // entirely (sim_silence). v4-vs-v4 (the flagship brain) is the default probe pairing; a fast
        // synchronous call (one game per board), so no progress overlay/pump needed like tournaments.
        if (_selCount == 0) {
            ui_button_disabled(_dbX, _dby, _dbW, 40, "Probe Selected Map(s)");
        } else if (ui_button(_dbX, _dby, _dbW, 40, "Probe Selected Map(s) (" + string(_selCount) + ")", fntMaru)) {
            for (var _pi = 0; _pi < _selCount; _pi++) sim_probe(_selIds[_pi], "v4", "v4");
        }
        _dby += 60;

        // navigate to the dedicated Results screen (run list + report), rather than showing
        // anything about results here - keeps this screen to just the 4 action buttons
        if (ui_button(_dbX, _dby, _dbW, 40, "Results >", fntMaru)) {
            menuScreen = "debugResults";
            menuDebugBatches = sim_tourney_csv_parse();
            menuDebugExpanded = [];
            menuDebugOpenRun = undefined;
            menuDebugOpenBatch = undefined;
            menuDebugRunsScroll = 0;
        }

        var _mgxD = device_mouse_x_to_gui(0), _mgyD = device_mouse_y_to_gui(0);

        // ---- right: board list - click a row to highlight/unhighlight it (multi-select) ----
        var _lx = _dbX + _dbW + 40, _lw = _guiW - _lx - 20, _lTop = 90, _entH2 = 40;
        var _rows2 = max(1, floor((_guiH - 30 - _lTop) / _entH2));
        var _maxTop2 = max(0, _nB - _rows2);
        if (_mgxD >= _lx && _mgxD <= _lx + _lw && _mgyD >= _lTop && _mgyD <= _lTop + _rows2 * _entH2) {
            if (mouse_wheel_up())   menuDebugScroll -= 1;
            if (mouse_wheel_down()) menuDebugScroll += 1;
        }
        menuDebugScroll = clamp(menuDebugScroll, 0, _maxTop2);

        draw_set_alpha(0.45); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_lx, _lTop, _lx + _lw, _lTop + _rows2 * _entH2, false);
        draw_set_alpha(1);
        for (var _r2 = 0; _r2 < _rows2; _r2++) {
            var _bi3 = menuDebugScroll + _r2;
            if (_bi3 >= _nB) break;
            var _by3 = _lTop + _r2 * _entH2;
            var _bd3 = _boards[_bi3];
            var _rowSel = arr_has(_selIds, _bd3.id);
            // bottom edge EXCLUSIVE - inclusive on both edges let a pixel exactly on the border between
            // two rows satisfy both checks, so one click toggled two rows at once
            var _rowHov = (_mgxD >= _lx && _mgxD < _lx + _lw && _mgyD >= _by3 && _mgyD < _by3 + _entH2);
            if (_rowSel) { draw_set_alpha(0.55); draw_set_color(make_color_rgb(74, 96, 132)); draw_rectangle(_lx, _by3, _lx + _lw, _by3 + _entH2, false); draw_set_alpha(1); }
            else if (_rowHov) { draw_set_alpha(0.3); draw_set_color(make_color_rgb(60, 70, 80)); draw_rectangle(_lx, _by3, _lx + _lw, _by3 + _entH2, false); draw_set_alpha(1); }
            if (_rowHov) global.uiMouseConsumed = true;
            if (_rowHov && mouse_check_button_pressed(mb_left)) {
                if (_rowSel) {
                    for (var _ri = array_length(_selIds) - 1; _ri >= 0; _ri--) if (_selIds[_ri] == _bd3.id) { array_delete(_selIds, _ri, 1); break; }
                } else array_push(_selIds, _bd3.id);
            }
            draw_set_color(c_white);
            dtext(_lx + 8, _by3 + 20, _bd3.name + "  (" + _bd3.id + ")");
        }
        draw_set_color(c_white);
        exit;
    }

    // ============================ DEBUG RESULTS =============================
    // (menuScreen == "debugResults") - like a level-select screen: a scrolling list of parsed
    // sim_tourney.csv runs on the left (buttons), the rest of the screen holds the report for
    // whichever run is selected. Data comes straight off disk (sim_tourney_csv_parse /
    // sim_tourney_run_aggregate, scrSim.gml) - never an in-session tournament struct - so it's
    // always the source of truth and survives an engine restart.
    if (menuScreen == "debugResults") {
        if (!global.settings.devTools) { menuScreen = "main"; exit; }

        draw_set_halign(fa_center);
        draw_set_font(fntMaru);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 40, "RESULTS", 2.4 * UI_TS, 2.4 * UI_TS, 0);
        draw_set_halign(fa_left);
        draw_set_color(c_white);

        if (ui_button(20, 16, 120, 30, "< Back")) menuScreen = "debug";
        if (ui_button(_guiW - 150, 60, 130, 30, "Refresh", fntMaru)) { menuDebugBatches = sim_tourney_csv_parse(); menuDebugExpanded = []; menuDebugOpenRun = undefined; menuDebugOpenBatch = undefined; }

        var _mgxR = device_mouse_x_to_gui(0), _mgyR = device_mouse_y_to_gui(0);

        // ---- left: batch/run TREE - one collapsible "folder" per batch id (newest first; a batch
        // id is a "YYYYMMDD-HHMMSS" timestamp stamped by sim_new_batch_id at the moment the user
        // triggered the tournament, or "Unknown" for rows logged before this column existed - see
        // sim_tourney_csv_parse's doc comment). Clicking a folder toggles it open/closed; clicking a
        // run inside an open folder selects it for the report on the right. Built fresh into a flat
        // "visible rows" list every frame so scrolling/hit-testing stays a simple uniform-row loop
        // regardless of how many folders happen to be expanded right now.
        var _flat = [];
        for (var _bi = array_length(menuDebugBatches) - 1; _bi >= 0; _bi--) {
            var _bat = menuDebugBatches[_bi];
            array_push(_flat, { kind: "batch", batch: _bat });
            if (arr_has(menuDebugExpanded, _bat.id)) {
                for (var _ri = 0; _ri < array_length(_bat.runs); _ri++) array_push(_flat, { kind: "run", run: _bat.runs[_ri], batch: _bat });
            }
        }

        var _rlX = 20, _rlW = 340, _rlTop = 96, _rEntH = 44;
        var _nFlat = array_length(_flat);
        var _rRows = max(1, floor((_guiH - 20 - _rlTop) / _rEntH));
        var _rMaxTop = max(0, _nFlat - _rRows);
        if (_mgxR >= _rlX && _mgxR <= _rlX + _rlW && _mgyR >= _rlTop && _mgyR <= _rlTop + _rRows * _rEntH) {
            if (mouse_wheel_up())   menuDebugRunsScroll -= 1;
            if (mouse_wheel_down()) menuDebugRunsScroll += 1;
        }
        menuDebugRunsScroll = clamp(menuDebugRunsScroll, 0, _rMaxTop);

        draw_set_alpha(0.35); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_rlX, _rlTop, _rlX + _rlW, _rlTop + _rRows * _rEntH, false);
        draw_set_alpha(1);
        if (_nFlat == 0) {
            draw_set_color(make_color_rgb(150, 150, 158));
            dtext(_rlX + 8, _rlTop + 20, "(no runs logged yet)");
            draw_set_color(c_white);
        }
        for (var _fd = 0; _fd < _rRows; _fd++) {
            var _fi = menuDebugRunsScroll + _fd;
            if (_fi >= _nFlat) break;
            var _item = _flat[_fi];
            var _rY = _rlTop + _fd * _rEntH;
            var _rHov = (_mgxR >= _rlX && _mgxR < _rlX + _rlW && _mgyR >= _rY && _mgyR < _rY + _rEntH);   // bottom edge exclusive - see the debug board-list fix

            if (_item.kind == "batch") {
                var _bOpen = arr_has(menuDebugExpanded, _item.batch.id);
                if (_rHov) { draw_set_alpha(0.3); draw_set_color(make_color_rgb(60, 70, 80)); draw_rectangle(_rlX, _rY, _rlX + _rlW, _rY + _rEntH, false); draw_set_alpha(1); global.uiMouseConsumed = true; }
                if (_rHov && mouse_check_button_pressed(mb_left)) {
                    if (_bOpen) { for (var _ei = array_length(menuDebugExpanded) - 1; _ei >= 0; _ei--) if (menuDebugExpanded[_ei] == _item.batch.id) { array_delete(menuDebugExpanded, _ei, 1); break; } }
                    else array_push(menuDebugExpanded, _item.batch.id);
                }
                draw_set_color(make_color_rgb(230, 220, 180));
                var _totalGames = 0;
                for (var _ci = 0; _ci < array_length(_item.batch.runs); _ci++) _totalGames += array_length(_item.batch.runs[_ci].rows);
                dtext(_rlX + 10, _rY + 12, (_bOpen ? "[-] " : "[+] ") + _item.batch.id);
                // board COUNT comes from the batch's intended list, not from how many runs exist -
                // a cancelled batch's unstarted boards have no run, and showing only started boards
                // is exactly what made a half-finished batch look complete
                var _bBoards = sim_tourney_batch_board_list(_item.batch);
                var _bMissing = sim_tourney_batch_missing(_item.batch);
                var _bShort = (_bMissing != undefined && _bMissing > 0);
                draw_set_color(_bShort ? make_color_rgb(235, 170, 90) : make_color_rgb(170, 175, 180));
                dtext(_rlX + 10, _rY + 28, string(array_length(_item.batch.runs)) + "/" + string(array_length(_bBoards))
                    + " board(s), " + string(_totalGames) + " games" + (_bShort ? "  (incomplete)" : ""));
                draw_set_color(c_white);
            } else {
                var _rSel = (menuDebugOpenRun == _item.run);
                if (_rSel) { draw_set_alpha(0.55); draw_set_color(make_color_rgb(74, 96, 132)); draw_rectangle(_rlX, _rY, _rlX + _rlW, _rY + _rEntH, false); draw_set_alpha(1); }
                else if (_rHov) { draw_set_alpha(0.3); draw_set_color(make_color_rgb(50, 58, 66)); draw_rectangle(_rlX, _rY, _rlX + _rlW, _rY + _rEntH, false); draw_set_alpha(1); }
                if (_rHov) global.uiMouseConsumed = true;
                if (_rHov && mouse_check_button_pressed(mb_left)) { menuDebugOpenRun = _item.run; menuDebugOpenBatch = _item.batch; }
                draw_set_color(c_white);
                dtext(_rlX + 34, _rY + 12, string(_item.run.boardId));
                var _rExpected = sim_tourney_run_expected(_item.run);
                var _rIncomplete = (_rExpected != undefined) && (array_length(_item.run.rows) < _rExpected);
                draw_set_color(_rIncomplete ? make_color_rgb(235, 170, 90) : make_color_rgb(180, 186, 190));
                dtext(_rlX + 34, _rY + 28, string(array_length(_item.run.rows)) + (_rExpected != undefined ? ("/" + string(_rExpected)) : "") + " games" + (_rIncomplete ? "  (incomplete)" : ""));
                draw_set_color(c_white);
            }
        }

        // ---- right: the report for the selected run (win matrix + per-policy summary),
        // aggregated fresh from its CSV rows every frame (sim_tourney_run_aggregate) - cheap for
        // one run's rows, and means the table can never show stale numbers ----
        var _tx0 = _rlX + _rlW + 40, _titleY = 96, _ty0 = 156;
        if (menuDebugOpenRun == undefined) {
            draw_set_color(make_color_rgb(160, 165, 170));
            dtext(_tx0, _ty0, "Select a run on the left to view its report.");
            draw_set_color(c_white);
            exit;
        }

        var _agg = sim_tourney_run_aggregate(menuDebugOpenRun);
        draw_set_color(make_color_rgb(255, 224, 120));
        dtext(_tx0, _titleY, string(_agg.boardId) + "  -  " + string(_agg.gameCount) + " games");
        draw_set_color(c_white);

        // ---- RESUME buttons: parked in the BOTTOM-RIGHT corner, stacked, clear of the report.
        // They used to sit up beside the title (y = _titleY), where they overlapped the win-matrix
        // header controls - the report grows downward from the title, so the top-right strip is not
        // actually free space. Down here nothing else draws.
        // "Resume Board" finishes just the selected board's matrix; "Resume Batch" finishes EVERY
        // incomplete board in the batch, including ones the cancelled batch never started at all
        // (recoverable because the batch's whole board list is recorded in each run's CSV header).
        // Both are only shown when we can actually tell the run/batch is short of its target (the
        // perPair column is present), and both read "Tournament running..." (inert) while one is live.
        var _rrExpected = sim_tourney_run_expected(menuDebugOpenRun);
        var _rrIncomplete = (_rrExpected != undefined) && (_agg.gameCount < _rrExpected);
        var _rrBusy = variable_global_exists("simTourney") && global.simTourney != undefined;

        var _rbMissing = (menuDebugOpenBatch != undefined) ? sim_tourney_batch_missing(menuDebugOpenBatch) : undefined;
        // the batch button is only worth showing when it would do MORE than the per-board one (i.e.
        // other boards in the batch are short too); a 1-board batch is fully covered by "Resume Board"
        var _rbShow = (_rbMissing != undefined && _rbMissing > 0
            && (!_rrIncomplete || _rbMissing > (_rrExpected - _agg.gameCount)));

        // stack UPWARD from the bottom edge, so whichever buttons are visible sit flush in the
        // corner with no gap where a hidden one would have been
        var _rbW = 240, _rbH = 34, _rbX = _guiW - _rbW - 20, _rbY = _guiH - 20 - _rbH;
        if (_rbShow) {
            if (ui_button(_rbX, _rbY, _rbW, _rbH, _rrBusy ? "Tournament running..." : ("Resume Batch (missing " + string(_rbMissing) + ")"), fntMaru)) {
                if (!_rrBusy) sim_tournament_resume_batch(menuDebugOpenBatch);
            }
            _rbY -= _rbH + 8;
        }
        if (_rrIncomplete) {
            if (ui_button(_rbX, _rbY, _rbW, _rbH, _rrBusy ? "Tournament running..." : ("Resume Board (missing " + string(_rrExpected - _agg.gameCount) + ")"), fntMaru)) {
                if (!_rrBusy) sim_tournament_resume(menuDebugOpenRun);
            }
        }

        var _np = array_length(_agg.pols);
        var _labelW = 130, _colW = 84, _rowH = 34;

        // --- win matrix: COLUMN (top label) = P1 brain, ROW (side label) = P2 brain, cell = P1
        // wins (as a colour: red = 0 wins, bright green = 0 losses / all wins for that pairing, so
        // the balance reads at a glance without parsing numbers). P1-on-top/P2-on-side matches the
        // convention from before this screen existed (2026-08-18 - was accidentally built the other
        // way around: P1 as the row, P2 as the column). Underlying data (_agg.wins/pairPlayed) is
        // still indexed [p1idx][p2idx] unchanged - only the on-screen axes are swapped, via looking
        // up wins[_cw][_rw]/pairPlayed[_cw][_rw] instead of [_rw][_cw] below.
        draw_set_color(make_color_rgb(200, 210, 205));
        dtext(_tx0, _ty0 - 24, "WIN MATRIX (col = P1, cell = P1 wins vs row as P2)");
        draw_set_color(c_white);
        // pinned to the screen's right edge, NOT the matrix's own width - a small matrix (e.g. 3
        // participants) left it stranded near the middle of the screen when it followed _colW*_np
        if (ui_button(_guiW - 150, _ty0 - 32, 130, 26, menuDebugMatrixPct ? "Show: wins/played" : "Show: win %", fntMaru)) menuDebugMatrixPct = !menuDebugMatrixPct;
        draw_set_halign(fa_center);
        for (var _c = 0; _c < _np; _c++) dtext(_tx0 + _labelW + _colW * (_c + 0.5), _ty0 + 4, _agg.pols[_c]);   // top labels = P1
        draw_set_halign(fa_left);
        draw_set_valign(fa_middle);
        for (var _rw = 0; _rw < _np; _rw++) {   // _rw now indexes P2 (the side label)
            var _ry = _ty0 + 30 + _rowH * _rw;
            draw_set_halign(fa_right);
            dtext(_tx0 + _labelW - 10, _ry + _rowH * 0.5, _agg.pols[_rw]);
            draw_set_halign(fa_center);
            for (var _cw = 0; _cw < _np; _cw++) {   // _cw now indexes P1 (the top label)
                var _cx = _tx0 + _labelW + _colW * _cw;
                var _cWins = _agg.wins[_cw][_rw], _cPlayed = _agg.pairPlayed[_cw][_rw];
                var _cellCol = (_cPlayed > 0) ? merge_color(make_color_rgb(196, 64, 64), make_color_rgb(70, 196, 100), _cWins / _cPlayed) : make_color_rgb(40, 42, 46);
                draw_set_alpha(0.9); draw_set_color(_cellCol);
                draw_rectangle(_cx + 2, _ry + 2, _cx + _colW - 2, _ry + _rowH - 2, false);
                draw_set_alpha(1);
                draw_set_color(c_white);
                var _cellTxt = "-";
                if (_cPlayed > 0) _cellTxt = menuDebugMatrixPct ? (string(round(_cWins / _cPlayed * 1000) / 10) + "%") : (string(_cWins) + "/" + string(_cPlayed));
                dtext(_cx + _colW * 0.5, _ry + _rowH * 0.5, _cellTxt);
            }
            draw_set_halign(fa_left);
        }
        draw_set_valign(fa_top);

        // --- per-policy summary: win rate as P1 (as a %), avg score across all seats, plan churn -
        // alternating row backgrounds so a wide row of numbers stays readable across ---
        var _sy0 = _ty0 + 30 + _rowH * _np + 30;
        draw_set_color(make_color_rgb(200, 210, 205));
        dtext(_tx0, _sy0 - 4, "OVERALL  (winRate = wins as P1 / games as P1; avgScore across all seats)");
        draw_set_color(c_white);
        var _scols = [_tx0, _tx0 + 140, _tx0 + 260, _tx0 + 380, _tx0 + 490, _tx0 + 600];
        var _shead = ["Policy", "WinRate", "AvgScore", "Sw/g", "Rp/g", "Games"];
        var _sRowH = 28, _sTableW = _scols[5] + 70 - _tx0;
        for (var _sc = 0; _sc < 6; _sc++) dtext(_scols[_sc], _sy0 + 26, _shead[_sc]);
        for (var _sp = 0; _sp < array_length(_agg.summary); _sp++) {
            var _row = _agg.summary[_sp];
            var _sry = _sy0 + 26 + _sRowH * (_sp + 1);
            draw_set_alpha(0.4); draw_set_color((_sp % 2 == 0) ? make_color_rgb(30, 34, 40) : make_color_rgb(20, 22, 26));
            draw_rectangle(_tx0 - 6, _sry, _tx0 - 6 + _sTableW, _sry + _sRowH, false);
            draw_set_alpha(1); draw_set_color(c_white);
            var _sryText = _sry + _sRowH * 0.5;
            draw_set_valign(fa_middle);
            dtext(_scols[0], _sryText, _row.label);
            dtext(_scols[1], _sryText, string(round(_row.winRate * 1000) / 10) + "%");
            dtext(_scols[2], _sryText, string(round(_row.avgScore * 10) / 10));
            dtext(_scols[3], _sryText, string(round(_row.swPerGame * 100) / 100));
            dtext(_scols[4], _sryText, string(round(_row.rpPerGame * 100) / 100));
            dtext(_scols[5], _sryText, string(_row.played));
            draw_set_valign(fa_top);
        }
        exit;
    }

    // =========================== BETWEEN-MISSION DECK CULL ===========================
    // (menuScreen == "advCull") - after clearing a map, the player cuts <need> weak enemy cards from
    // the carried deck (those matching the map's cull rule) before its advanced cards are mixed in.
    // Left-click a card to mark a copy for removal, right-click to un-mark; the additions preview at
    // the bottom shows what's coming in. Confirm (enabled at exactly <need>) commits + launches next.
    if (menuScreen == "advCull") {
        if (advCull == undefined) { menuScreen = "adventure"; exit; }
        var _cu = advCull;
        var _removed = adventure_cull_removed();
        var _setNum = (boardDef != undefined) ? boardDef.setNumber : 1;
        draw_set_font(fntMaru);

        draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 22, "REINFORCE THE DECK", 1.8 * UI_TS, 1.8 * UI_TS, 0);
        var _statWord = (_cu.rule.type == "dmg") ? "attack" : "HP";
        draw_set_color(make_color_rgb(220, 228, 224));
        dtext(_guiW * 0.5, 64, "Remove " + string(_cu.need) + " weak enemies (" + _statWord + " <= " + string(_cu.rule.thr) + ") to make room for tougher cards.");
        draw_set_color((_removed == _cu.need) ? make_color_rgb(150, 220, 150) : make_color_rgb(240, 210, 120));
        dtext(_guiW * 0.5, 92, "Removed  " + string(_removed) + " / " + string(_cu.need));
        draw_set_halign(fa_left);

        // ---- removable cards: an overlapping down-right CASCADE so each card's bottom-left
        //      defensive chips stay exposed (a flush grid clipped them behind neighbours) ----
        var _ch = 138;                          // card height
        var _cw = round(_ch * 0.714);           // card width (standard aspect)
        var _stepX = round(_cw * 0.62);         // horizontal reveal (cards overlap ~38%)
        var _gx0 = 44;
        var _gy0 = 116;
        var _nRows = array_length(_cu.rows);
        var _perRow = clamp(1 + (_guiW - 88 - _cw) div _stepX, 1, 12);
        // vertical reveal: make it as tall as the space allows (so each card's TOP-RIGHT stat circles
        // show, not just a sliver), shrinking only when a row is crowded. Bounded so it stays on-screen
        // above the additions strip (~_guiH-184).
        var _inBand = min(_nRows, _perRow);
        var _availV = (_guiH - 210) - _gy0 - _ch;                       // room for the downward spread (clears the additions strip)
        var _stepY = (_inBand > 1) ? clamp(_availV div (_inBand - 1), 26, 50) : 40;
        var _rowSpan = _ch + (_perRow - 1) * _stepY + 30;   // height of one wrapped band
        // card positions (col within a row cascades right + down; wrap to a new band)
        var _cardX = array_create(_nRows);
        var _cardY = array_create(_nRows);
        for (var _i = 0; _i < _nRows; _i++) {
            var _col = _i mod _perRow, _band = _i div _perRow;
            _cardX[_i] = _gx0 + _col * _stepX;
            _cardY[_i] = _gy0 + _band * _rowSpan + _col * _stepY;
        }
        // hit test topmost-first (later cards draw on top, so they win the click)
        var _hit = -1;
        for (var _i = _nRows - 1; _i >= 0 && _hit < 0; _i--)
            if (ui_mouse_in(_cardX[_i], _cardY[_i], _cw, _ch)) _hit = _i;
        if (_hit >= 0) {
            global.uiMouseConsumed = true;
            var _hr = _cu.rows[_hit];
            if (mouse_check_button_pressed(mb_left)  && _hr.rm < _hr.avail && _removed < _cu.need) { _hr.rm += 1; _removed += 1; }
            if (mouse_check_button_pressed(mb_right) && _hr.rm > 0)                                 { _hr.rm -= 1; _removed -= 1; }
        }
        // draw first-to-last so each card overlaps the one before it
        for (var _i = 0; _i < _nRows; _i++) {
            var _row = _cu.rows[_i];
            var _cx = _cardX[_i], _cy = _cardY[_i];
            var _allGone = (_row.rm >= _row.avail);   // fully cut -> greyed out
            card_draw(card_enemy_alias(_row.id, _setNum), _cx, _cy, _ch, _allGone ? 0.32 : 1);
            if (_i == _hit) { draw_set_color(c_white); draw_rectangle(_cx - 2, _cy - 2, _cx + _cw + 2, _cy + _ch + 2, true); }
            // count badge on the exposed bottom-left: "x{copies left in the deck}", ticks DOWN as cut
            draw_set_halign(fa_left);
            draw_set_color((_row.rm > 0) ? make_color_rgb(240, 130, 120) : make_color_rgb(230, 236, 232));
            dtext(_cx + 5, _cy + _ch + 2, "x" + string(_row.avail - _row.rm));
            draw_set_halign(fa_left);
        }
        if (array_length(_cu.rows) == 0) { draw_set_halign(fa_center); draw_set_color(make_color_rgb(200, 200, 200)); dtext(_guiW * 0.5, _gy0 + 40, "(no matching cards in the deck)"); draw_set_halign(fa_left); }

        // ---- additions preview strip ----
        var _addH = 96;
        var _addW = round(_addH * 0.714);
        var _addStep = _addW + 10;
        var _addN = array_length(_cu.addRows);
        var _addY = _guiH - _addH - 66;
        draw_set_halign(fa_left); draw_set_color(make_color_rgb(160, 220, 255));
        dtext(30, _addY - 22, "Adding:");
        var _addX = 30 + 78;
        for (var _a = 0; _a < _addN; _a++) {
            var _ar = _cu.addRows[_a];
            card_draw(card_enemy_alias(_ar.id, _setNum), _addX + _a * _addStep, _addY, _addH);
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(160, 220, 255));
            dtext(_addX + _a * _addStep + _addW * 0.5, _addY + _addH + 2, "x" + string(_ar.n));
            draw_set_halign(fa_left);
        }

        // ---- action bar ----
        var _cbarY = _guiH - 52;
        if (ui_button(_guiW - 460, _cbarY, 200, 40, "Auto-pick strongest", fntMaru)) {
            // auto: mark the HIGHEST-stat matching copies until we've hit <need>. Culling is picking
            // which enemies you'd rather never fight again, so it should strip the nastiest cards out
            // and LEAVE the weak ones in the deck - sorting ascending (as this did) threw away the
            // pushovers and kept the monsters, which is backwards.
            for (var _z = 0; _z < array_length(_cu.rows); _z++) _cu.rows[_z].rm = 0;
            var _flat2 = [];   // {row, s} one entry per available copy
            for (var _r2 = 0; _r2 < array_length(_cu.rows); _r2++)
                repeat (_cu.rows[_r2].avail) array_push(_flat2, { row: _cu.rows[_r2], s: adventure_cull_stat(_cu.rows[_r2].id, _cu.rule) });
            array_sort(_flat2, function(_a, _b) { return _b.s - _a.s; });   // descending: strongest first
            for (var _p = 0; _p < array_length(_flat2) && _p < _cu.need; _p++) _flat2[_p].row.rm += 1;
        }
        var _canGo = (_removed == _cu.need);
        if (_canGo) {
            if (ui_button(_guiW - 240, _cbarY, 200, 40, "Confirm >", fntMaru)) { adventure_cull_confirm(); exit; }
        } else {
            draw_set_alpha(0.5); ui_button(_guiW - 240, _cbarY, 200, 40, "Confirm >", fntMaru); draw_set_alpha(1);
        }
        exit;
    }

    // =========================== ADVENTURE / CHAPTER SELECT ===========================
    // (menuScreen == "adventure") - a scrolling list of campaign scenarios + their boards on the
    // left, and a preview of the selected board (its actual lane LAYOUT) on the right. PLAY launches
    // the board as a solo home-anchored game. Data = data/adventure.json (extracted from the .xlsx).
    if (menuScreen == "adventure") {
        var _scens = global.adventureData.scenarios;
        // flatten to display rows: a header per scenario, then a row per board; _advB indexes boards.
        var _flat = [];
        var _advB = [];
        for (var _si = 0; _si < array_length(_scens); _si++) {
            array_push(_flat, { hdr: true, text: _scens[_si].name, scenIdx: _si });
            var _sb = _scens[_si].boards;
            for (var _bi = 0; _bi < array_length(_sb); _bi++) {
                array_push(_flat, { hdr: false, bidx: array_length(_advB), board: _sb[_bi] });
                array_push(_advB, _sb[_bi]);
            }
        }
        var _nAdv = array_length(_advB);
        menuAdvIdx = clamp(menuAdvIdx, 0, max(0, _nAdv - 1));
        var _selB = (_nAdv > 0) ? _advB[menuAdvIdx] : undefined;

        // background: the selected board's skybox theme, darkened (mirrors board-select)
        if (_selB != undefined) {
            var _skySpr = asset_get_index("_" + string(_selB.setNumber));
            if (_skySpr >= 0) {
                var _skW = sprite_get_width(_skySpr), _skH = sprite_get_height(_skySpr);
                var _skSc = max(_guiW / _skW, _guiH / _skH);
                draw_sprite_ext(_skySpr, 0, (_guiW - _skW * _skSc) * 0.5, (_guiH - _skH * _skSc) * 0.5, _skSc, _skSc, 0, c_white, 1);
            }
        }
        draw_set_alpha(0.62); draw_set_color(c_black); draw_rectangle(0, 0, _guiW, _guiH, false); draw_set_alpha(1);

        // --- SAVE-MANAGEMENT modal (erase / copy-to / confirm). Drawn over the dim; blocks the rest. ---
        if (advSaveConfirm != undefined) {
            var _sc = advSaveConfirm;
            draw_set_alpha(0.55); draw_set_color(c_black); draw_rectangle(0, 0, _guiW, _guiH, false); draw_set_alpha(1);
            var _mw = 620, _mh = 240, _mx = (_guiW - _mw) * 0.5, _my = (_guiH - _mh) * 0.5;
            draw_set_alpha(0.98); draw_set_color(make_color_rgb(26, 30, 36)); draw_rectangle(_mx, _my, _mx + _mw, _my + _mh, false);
            draw_set_alpha(1); draw_set_color(make_color_rgb(255, 224, 120)); draw_rectangle(_mx, _my, _mx + _mw, _my + _mh, true);
            draw_set_halign(fa_center); draw_set_font(fntMaru); draw_set_color(c_white);
            if (_sc.action == "copyPick") {
                draw_text_transformed(_guiW * 0.5, _my + 28, "Copy Log " + string(_sc.from + 1) + " onto which log?", 1.3 * UI_TS, 1.3 * UI_TS, 0);
                draw_set_halign(fa_left);
                var _bi = 0;
                for (var _t = 0; _t < array_length(global.advSaves); _t++) {
                    if (_t == _sc.from) continue;
                    if (ui_button(_mx + 70 + _bi * 250, _my + 92, 210, 48, "Overwrite Log " + string(_t + 1), fntMaru)) advSaveConfirm = { action: "copy", from: _sc.from, to: _t };
                    _bi++;
                }
                if (ui_button(_mx + (_mw - 170) * 0.5, _my + _mh - 58, 170, 42, "Cancel", fntMaru)) advSaveConfirm = undefined;
            } else {
                var _msg, _yes, _sub;
                if (_sc.action == "erase") {
                    _msg = "Erase ALL data in Log " + string(_sc.from + 1) + "?"; _yes = "Erase"; _sub = "This cannot be undone.";
                } else if (_sc.action == "newadv") {
                    // the existing save is NOT touched on disk here - adventure_campaign_reset is
                    // in-memory only, and the fresh run only overwrites it if the player Saves
                    _msg = "Start a new " + global.adventureData.scenarios[_sc.scen].name + "?"; _yes = "New Adventure";
                    _sub = "Log " + string(_sc.from + 1) + "'s progress is kept until you save over it.";
                } else {
                    _msg = "Overwrite Log " + string(_sc.to + 1) + " with Log " + string(_sc.from + 1) + "'s data?"; _yes = "Overwrite"; _sub = "This cannot be undone.";
                }
                draw_text_transformed(_guiW * 0.5, _my + 40, _msg, 1.3 * UI_TS, 1.3 * UI_TS, 0);
                draw_set_color(make_color_rgb(235, 150, 150));
                draw_text_transformed(_guiW * 0.5, _my + 84, _sub, 1.05 * UI_TS, 1.05 * UI_TS, 0);
                draw_set_halign(fa_left); draw_set_color(c_white);
                if (ui_button(_mx + 80, _my + _mh - 74, 200, 48, _yes, fntMaru)) {
                    if (_sc.action == "erase") { adventure_slot_reset(_sc.from); advSaveConfirm = undefined; }
                    else if (_sc.action == "newadv") { advSaveConfirm = undefined; adventure_new(_sc.scen); exit; }
                    else { adventure_slot_copy(_sc.from, _sc.to); advSaveConfirm = undefined; }
                }
                if (ui_button(_mx + _mw - 80 - 200, _my + _mh - 74, 200, 48, "Cancel", fntMaru)) advSaveConfirm = undefined;
            }
            draw_set_halign(fa_left); draw_set_color(c_white);
            exit;
        }

        draw_set_halign(fa_center); draw_set_font(fntMaru); draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, 16, "ADVENTURE", 2.0 * UI_TS, 2.0 * UI_TS, 0);
        draw_set_halign(fa_left); draw_set_color(c_white);
        if (ui_button(20, 12, 110, 30, "< Back")) { menuScreen = "main"; }
        // --- LOG (save-slot) tabs: 3 independent logs, each its own progress (above the list) ---
        for (var _lg = 0; _lg < array_length(global.advSaves); _lg++) {
            var _tabX = 20 + _lg * 100;
            var _tabSel = (advSlot == _lg);
            draw_set_alpha(_tabSel ? 0.95 : 0.5);
            draw_set_color(_tabSel ? make_color_rgb(58, 82, 66) : make_color_rgb(34, 40, 46));
            draw_rectangle(_tabX, 48, _tabX + 92, 74, false); draw_set_alpha(1);
            var _tabHov = (_mgx0 >= _tabX && _mgx0 <= _tabX + 92 && _mgy0 >= 48 && _mgy0 <= 74);
            if (_tabHov) { global.uiMouseConsumed = true; if (mouse_check_button_pressed(mb_left)) advSlot = _lg; }
            draw_set_halign(fa_center); draw_set_color(_tabSel ? make_color_rgb(255, 224, 120) : make_color_rgb(190, 200, 205));
            dtext(_tabX + 46, 52, "Log " + string(_lg + 1));
            draw_set_halign(fa_left); draw_set_color(c_white);
        }
        // save management for the SELECTED log: copy its data onto another, or erase it (both confirmed)
        var _mgX = 20 + array_length(global.advSaves) * 100 + 6;
        if (ui_button(_mgX,       48, 84, 26, "Copy",  fntMaru)) advSaveConfirm = { action: "copyPick", from: advSlot };
        if (ui_button(_mgX + 92,  48, 84, 26, "Erase", fntMaru)) advSaveConfirm = { action: "erase",    from: advSlot };

        if (_nAdv == 0) {
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(220, 180, 180));
            dtext(_guiW * 0.5, _guiH * 0.5, "No adventure data (data/adventure.json missing).");
            draw_set_halign(fa_left); draw_set_color(c_white);
            exit;
        }

        // space kind/hazard -> a preview swatch colour
        var _advSpCol = function(_sp) {
            if (_sp.kind == "plain")    return make_color_rgb(104, 142, 88);
            if (_sp.kind == "enemy")    return make_color_rgb(150, 150, 150);
            if (_sp.kind == "treasure") return make_color_rgb(232, 210, 66);
            switch (_sp.hazard) {
                case "fire":   return make_color_rgb(210, 70, 50);
                case "water":  return make_color_rgb(70, 120, 200);
                case "height": return make_color_rgb(226, 205, 170);
                case "ice":    return make_color_rgb(120, 220, 230);
                case "poison": return make_color_rgb(150, 110, 190);
                case "chasm":  return make_color_rgb(120, 80, 40);
            }
            return make_color_rgb(90, 90, 90);
        };
        // the bracket note = buildable structures (1=bridge, 2=climbing stick, 3=tunnel), not players
        var _advBuildStr = function(_b) {
            var _bs = variable_struct_exists(_b, "buildStructs") ? _b.buildStructs : [];
            if (array_length(_bs) == 0) return "none";
            var _s = "";
            for (var _i = 0; _i < array_length(_bs); _i++) _s += (_i > 0 ? ", " : "") + hazard_def_get(_bs[_i]).name;
            return _s;
        };

        var _barY = _guiH - 56;
        // ---- left: scrolling list (scenario headers + board rows) ----
        var _listX = 20, _listW = 300, _listTop = 84, _rowH = 34;   // 84 = below the Log tabs
        var _nF = array_length(_flat);
        var _rows = max(1, floor((_barY - 12 - _listTop) / _rowH));
        var _maxTop = max(0, _nF - _rows);
        if (_mgx0 >= _listX && _mgx0 <= _listX + _listW && _mgy0 >= _listTop && _mgy0 <= _listTop + _rows * _rowH) {
            if (mouse_wheel_up())   menuAdvScroll -= 1;
            if (mouse_wheel_down()) menuAdvScroll += 1;
        }
        menuAdvScroll = clamp(menuAdvScroll, 0, _maxTop);
        draw_set_alpha(0.45); draw_set_color(make_color_rgb(18, 22, 26));
        draw_rectangle(_listX, _listTop, _listX + _listW, _listTop + _rows * _rowH, false); draw_set_alpha(1);
        for (var _r = 0; _r < _rows; _r++) {
            var _fi = menuAdvScroll + _r;
            if (_fi >= _nF) break;
            var _fe = _flat[_fi];
            var _ey = _listTop + _r * _rowH;
            draw_set_font(fntMaru);
            if (_fe.hdr) {
                // all 3 campaigns are available (mission 1 open by default). Show (cleared) when beaten.
                var _campDone = (advSlot < array_length(global.advSaves) && _fe.scenIdx < array_length(global.advSaves[advSlot].done) && global.advSaves[advSlot].done[_fe.scenIdx]);
                draw_set_color(make_color_rgb(255, 224, 120));
                dtext(_listX + 8, _ey + 8, _fe.text + (_campDone ? "  (cleared)" : ""));
                draw_set_color(c_white);
            } else {
                var _mUnlocked = adventure_mission_unlocked(advSlot, _fe.board.scenarioIdx, _fe.board.boardIdx);
                var _sel = (_fe.bidx == menuAdvIdx);
                var _hov = _mUnlocked && (_mgx0 >= _listX && _mgx0 < _listX + _listW && _mgy0 >= _ey && _mgy0 < _ey + _rowH);
                if (_hov) global.uiMouseConsumed = true;
                draw_set_alpha(_mUnlocked ? (_sel ? 0.9 : (_hov ? 0.7 : 0.4)) : 0.25);
                draw_set_color(_sel ? make_color_rgb(58, 82, 66) : make_color_rgb(38, 46, 52));
                draw_rectangle(_listX + 20, _ey + 2, _listX + _listW - 4, _ey + _rowH - 2, false); draw_set_alpha(1);
                draw_set_color(!_mUnlocked ? make_color_rgb(110, 110, 118) : (_sel ? make_color_rgb(255, 224, 120) : make_color_rgb(200, 210, 215)));
                dtext(_listX + 30, _ey + 8, _fe.board.label + (_mUnlocked ? "" : "   (locked)"));
                draw_set_color(c_white);
                if (_hov && mouse_check_button_pressed(mb_left)) menuAdvIdx = _fe.bidx;
            }
        }
        draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
        if (menuAdvScroll > 0)       dtext(_listX + _listW * 0.5, _listTop + 1, "^");
        if (menuAdvScroll < _maxTop) dtext(_listX + _listW * 0.5, _listTop + _rows * _rowH - 15, "v");
        draw_set_halign(fa_left); draw_set_color(c_white);

        // ---- right: preview of the selected board (scenario name + its actual LANE LAYOUT + kit).
        // _pvTop keeps the scenario title flush with the left list top (below the Log tabs + Copy/Erase). ----
        var _pvX = _listX + _listW + 34;
        var _pvTop = _listTop;   // = 84, same as the left selector's top
        draw_set_font(fntMaru); draw_set_color(make_color_rgb(255, 236, 190));
        draw_text_transformed(_pvX, _pvTop, _scens[_selB.scenarioIdx].name, 1.7 * UI_TS, 1.7 * UI_TS, 0);
        draw_set_color(make_color_rgb(200, 210, 205));
        draw_text_transformed(_pvX, _pvTop + 40, "Map " + _selB.label + "     Buildable: " + _advBuildStr(_selB), 1.05 * UI_TS, 1.05 * UI_TS, 0);

        // mini lane layout: 5 lane columns x their spaces; treasure (far end) at TOP, home at bottom
        var _gx = _pvX, _gy = _pvTop + 80, _cw = 52, _ch = 34, _gp = 6;
        var _lanes = _selB.lanes;
        for (var _l = 0; _l < array_length(_lanes); _l++) {
            var _lspaces = _lanes[_l].spaces;
            var _n = array_length(_lspaces);
            for (var _i = 0; _i < _n; _i++) {
                var _cx = _gx + _l * (_cw + _gp);
                var _cy = _gy + (_n - 1 - _i) * (_ch + _gp);   // idx 0 (home) at the bottom
                draw_set_color(_advSpCol(_lspaces[_i]));
                draw_rectangle(_cx, _cy, _cx + _cw, _cy + _ch, false);
                draw_set_color(make_color_rgb(24, 28, 22));
                draw_rectangle(_cx, _cy, _cx + _cw, _cy + _ch, true);
            }
        }
        var _gridBot = _gy + 7 * (_ch + _gp);
        // fixture markers: pre-placed structures (white ring) + named enemies/bosses (red dot)
        var _cellXY = function(_gx, _gy, _cw, _ch, _gp, _n, _l, _i) {
            return [_gx + _l * (_cw + _gp) + _cw * 0.5, _gy + (_n - 1 - _i) * (_ch + _gp) + _ch * 0.5];
        };
        for (var _s2 = 0; _s2 < array_length(_selB.placedStructures); _s2++) {
            var _ps = _selB.placedStructures[_s2];
            var _pc = _cellXY(_gx, _gy, _cw, _ch, _gp, array_length(_lanes[_ps.lane].spaces), _ps.lane, _ps.idx);
            draw_set_color(make_color_rgb(240, 240, 245));
            draw_circle(_pc[0], _pc[1], 6, true);
        }
        for (var _e2 = 0; _e2 < array_length(_selB.placedEnemies); _e2++) {
            var _pe = _selB.placedEnemies[_e2];
            var _ec = _cellXY(_gx, _gy, _cw, _ch, _gp, array_length(_lanes[_pe.lane].spaces), _pe.lane, _pe.idx);
            draw_set_color(make_color_rgb(230, 70, 60));
            draw_circle(_ec[0], _ec[1], 5, false);
        }
        draw_set_color(make_color_rgb(180, 190, 185));
        dtext(_gx, _gy - 22, "far / treasures");
        draw_set_color(c_white);

        // starting pikmin types (coloured dots + label)
        var _kitY = _gridBot + 22;
        var _kitLbl = "Pikmin Types: ";
        draw_set_color(make_color_rgb(210, 220, 214));
        dtext(_gx, _kitY, _kitLbl);
        var _dotCY = _kitY + dtext_height(_kitLbl) * 0.5;   // centre the dots on the label's middle (was floating high)
        var _kx = _gx + dtext_width(_kitLbl) + 16;
        for (var _k = 0; _k < array_length(_selB.kit); _k++) {
            draw_set_color(pikmin_tint(_selB.kit[_k]));
            draw_circle(_kx + 8, _dotCY, 8, false);
            draw_set_color(make_color_rgb(20, 24, 20));
            draw_circle(_kx + 8, _dotCY, 8, true);
            _kx += 24;
        }
        draw_set_color(c_white);
        // legend for the fixture markers
        draw_set_color(make_color_rgb(160, 170, 165));
        dtext(_gx, _kitY + 34, "(white ring = structure, red dot = enemy/boss)");
        draw_set_color(c_white);

        // ---- save-file readout for the selected mission in this log ----
        var _selUnlocked = adventure_mission_unlocked(advSlot, _selB.scenarioIdx, _selB.boardIdx);
        var _selCp = adventure_mission_checkpoint(advSlot, _selB.scenarioIdx, _selB.boardIdx);
        var _infoY = _kitY + 62;
        if (_selCp != undefined) {
            draw_set_color(make_color_rgb(255, 236, 190));
            draw_text_transformed(_pvX, _infoY, string(_selCp.daysLeft) + " Days Remaining", 1.35 * UI_TS, 1.35 * UI_TS, 0);
            // extra log info: campaign clear-progress + days already spent on this run
            var _slot = global.advSaves[advSlot];
            var _totalBoards = array_length(_scens[_selB.scenarioIdx].boards);
            var _campDone = (_selB.scenarioIdx < array_length(_slot.done) && _slot.done[_selB.scenarioIdx]);
            var _clearedN = _campDone ? _totalBoards : (array_length(_slot.campaigns[_selB.scenarioIdx]) - 1);
            draw_set_color(make_color_rgb(190, 200, 205));
            draw_text_transformed(_pvX, _infoY + 30, "Log " + string(advSlot + 1) + " progress:  " + string(_clearedN) + " / " + string(_totalBoards) + " missions cleared" + (_campDone ? "   (campaign cleared)" : ""), 1.0 * UI_TS, 1.0 * UI_TS, 0);
            draw_text_transformed(_pvX, _infoY + 52, "Campaign days spent so far:  " + string(_selCp.daysUsed), 1.0 * UI_TS, 1.0 * UI_TS, 0);
        } else {
            draw_set_color(make_color_rgb(200, 210, 205));
            draw_text_transformed(_pvX, _infoY, "Locked - clear the previous mission in this log", 1.05 * UI_TS, 1.05 * UI_TS, 0);
        }
        draw_set_color(c_white);

        // ---- population graph of the LAST play of this mission (only if the save log stored one) ----
        var _pgHist = (_selCp != undefined && variable_struct_exists(_selCp, "popHistory")) ? _selCp.popHistory : undefined;
        if (is_array(_pgHist) && array_length(_pgHist) >= 2) {
            var _pgX = _pvX + 300;                 // just right of the mini lane map
            var _pgY = _pvTop + 66;                // aligns with the shifted preview grid
            var _pgW = _guiW - _pgX - 30;
            var _pgH = 240;
            if (_pgW >= 220) {
                draw_set_color(make_color_rgb(200, 210, 205));
                dtext(_pgX, _pgY - 24, "Pikmin population (last play)");
                var _pcols = pop_graph_draw({ popHistory: _pgHist }, 0, _pgX, _pgY, _pgW, _pgH);
                if (is_array(_pcols)) {
                    var _lx = _pgX, _ly = _pgY + _pgH + 20;
                    for (var _pc2 = 0; _pc2 < array_length(_pcols); _pc2++) {
                        var _lbl = _pcols[_pc2];
                        draw_set_color(pikmin_tint(_lbl)); draw_circle(_lx + 7, _ly + 8, 7, false);
                        draw_set_color(make_color_rgb(20, 24, 20)); draw_circle(_lx + 7, _ly + 8, 7, true);
                        draw_set_color(make_color_rgb(210, 218, 214)); dtext(_lx + 18, _ly, _lbl);
                        _lx += 18 + dtext_width(_lbl) + 20;
                    }
                    draw_set_color(c_white);
                }
            }
        }

        // ---- bottom bar: New Adventure (restart the selected campaign) + Continue (resume furthest) +
        //      Play from Here (the selected mission) ----
        var _abW = 214, _abG = 12;
        var _ab3 = _guiW - _abW - 20;                 // Play from Here (rightmost)
        var _ab2 = _ab3 - _abG - _abW;                // Continue Adventure
        var _ab1 = _ab2 - _abG - _abW;                // New Adventure
        // New Adventure: restart THIS campaign from board 0 with base stats (confirm if it has progress)
        if (ui_button(_ab1, _barY, _abW, 44, "New Adventure", fntMaru)) {
            if (adventure_campaign_started(advSlot, _selB.scenarioIdx)) advSaveConfirm = { action: "newadv", from: advSlot, scen: _selB.scenarioIdx };
            else { adventure_new(_selB.scenarioIdx); exit; }
        }
        if (ui_button(_ab2, _barY, _abW, 44, "Continue Adventure", fntMaru)) { adventure_continue(); exit; }
        if (_selUnlocked) {
            if (ui_button(_ab3, _barY, _abW, 44, "Play from Here", fntMaru)) { adventure_play_mission(_selB.scenarioIdx, _selB.boardIdx); exit; }
        } else {
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(150, 150, 158));
            dtext(_ab3 + _abW * 0.5, _barY + 12, "Locked");
            draw_set_halign(fa_left); draw_set_color(c_white);
        }
        exit;
    }

    // =========================== BOARD SELECT ===========================
    // (menuScreen == "board") - a scrolling board list on the left, a live data preview of the
    // highlighted board on the right, and a Play button that locks in the seats + board.
    var _boards = global.boardData.boards;
    var _nB = array_length(_boards);
    menuBoardIdx = clamp(menuBoardIdx, 0, _nB - 1);

    // online: the HOST browses + streams the previewed board id; the JOINER mirrors it (list hidden,
    // just the preview pane) and launches when START arrives. (Standard boards only for now - the
    // "random" board differs per client, so it isn't synced yet.)
    var _netHost = net_online() && global.net.mode == "host";
    var _netJoin = net_online() && global.net.mode == "join";
    if (_netJoin) {
        if (global.net.previewBoard != "") for (var _bi = 0; _bi < _nB; _bi++) if (_boards[_bi].id == global.net.previewBoard) { menuBoardIdx = _bi; break; }
        // consumed (cleared) so returning to board-select later can't re-trigger a stale launch;
        // start_game_online works out player-vs-spectator from our assigned seat, so this one call
        // covers the P2 client and every spectator alike
        if (global.net.startBoard != "") { var _sbB = global.net.startBoard; global.net.startBoard = ""; start_game_online(_sbB, false); exit; }
    } else if (_netHost) {
        var _hid = _boards[menuBoardIdx].id;
        if (_hid != global.net.previewBoard) { net_send_board(_hid); global.net.previewBoard = _hid; }
    }

    // background: the highlighted board's skybox (sprites _1.._16), cover-fit + darkened so
    // the light UI text stays readable on top of it
    var _skySpr = asset_get_index("_" + string(_boards[menuBoardIdx].setNumber));
    if (_skySpr >= 0) {
        var _skW = sprite_get_width(_skySpr), _skH = sprite_get_height(_skySpr);
        var _skSc = max(_guiW / _skW, _guiH / _skH);
        draw_sprite_ext(_skySpr, 0, (_guiW - _skW * _skSc) * 0.5, (_guiH - _skH * _skSc) * 0.5, _skSc, _skSc, 0, c_white, 1);
    }
    draw_set_alpha(0.6); draw_set_color(c_black);
    draw_rectangle(0, 0, _guiW, _guiH, false);
    draw_set_alpha(1);

    draw_set_halign(fa_center);
    draw_set_font(fntMaru);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, 16, "SELECT A BOARD", 2.0 * UI_TS, 2.0 * UI_TS, 0);
    draw_set_halign(fa_left);

    if (ui_button(20, 12, 110, 30, "< Back")) { if (net_online()) net_close(); menuScreen = "main"; batchArm = false; }

    // ---- bottom control bar: seat toggles + batch + Play (offline) OR opponent + PLAY/wait (online) ----
    var _barY = _guiH - 56;
    if (_netHost || _netJoin) {
        draw_set_color(make_color_rgb(200, 210, 220));
        dtext(20, _barY + 12, (_netHost ? "vs " : "hosted by ") + global.net.remoteName);
        draw_set_color(c_white);
        if (_netHost) {
            if (ui_button(_guiW - 250, _barY, 230, 44, "PLAY (online)", fntMaru)) {
                var _pbh = _boards[menuBoardIdx];
                net_send_start(_pbh.id);
                start_game_online(_pbh.id, true);
                exit;
            }
        } else {
            draw_set_halign(fa_center); draw_set_color(make_color_rgb(255, 224, 120));
            dtext(_guiW * 0.5, _barY + 12, "Waiting for " + global.net.remoteName + " to start...");
            draw_set_halign(fa_left); draw_set_color(c_white);
        }
    } else {
    var _bsCtlName = function(_c) {
        if (_c == "human")  return "Human";
        if (_c == "easy")   return "COM - EASY";
        if (_c == "medium") return "COM - MED";
        return "COM - HARD";
    };
    var _bsCycle = function(_c) {
        if (_c == "human")  return "easy";
        if (_c == "easy")   return "medium";
        if (_c == "medium") return "hard";
        return "human";
    };
    if (ui_button(20,  _barY, 188, 40, "P1: " + _bsCtlName(menuCtl[0]), fntMaru)) { menuCtl[0] = _bsCycle(menuCtl[0]); save_settings(); }
    if (ui_button(214, _barY, 188, 40, "P2: " + _bsCtlName(menuCtl[1]), fntMaru)) { menuCtl[1] = _bsCycle(menuCtl[1]); save_settings(); }
    if (ui_button(410, _barY, 200, 40, batchArm ? "BATCH x25 ARMED" : "Batch: 25 AI games", fntMaru)) batchArm = !batchArm;

    var _playW = 230;
    if (ui_button(_guiW - _playW - 20, _barY, _playW, 44, batchArm ? "PLAY (Batch x25)" : "PLAY", fntMaru)) {
        var _pb = _boards[menuBoardIdx];
        if (batchArm) {
            batchArm = false;
            batchRemaining = 25;
            batchSavedAnims = global.expRules.anims;
            global.expRules.anims = false;
            start_game(_pb.id, [ (menuCtl[0] == "human") ? "v1" : menuCtl[0], (menuCtl[1] == "human") ? "v1" : menuCtl[1] ]);
        } else {
            start_game(_pb.id);
        }
        exit;
    }
    } // end offline bottom bar (online/offline branch)

    // ---- left: scrolling board list (offline + host; the JOINER sees only the preview pane) ----
    var _listX = 20, _listW = 356, _listTop = 50, _entH = 76;   // geometry also used by the preview pane
    if (!_netJoin) {
    var _rows = max(1, floor((_barY - 12 - _listTop) / _entH));
    var _listBot = _listTop + _rows * _entH;
    var _maxTop = max(0, _nB - _rows);
    if (_mgx0 >= _listX && _mgx0 <= _listX + _listW && _mgy0 >= _listTop && _mgy0 <= _listBot) {
        if (mouse_wheel_up())   menuListScroll -= 1;
        if (mouse_wheel_down()) menuListScroll += 1;
    }
    menuListScroll = clamp(menuListScroll, 0, _maxTop);

    draw_set_alpha(0.45); draw_set_color(make_color_rgb(18, 22, 26));
    draw_rectangle(_listX, _listTop, _listX + _listW, _listBot, false);
    draw_set_alpha(1);

    for (var _r = 0; _r < _rows; _r++) {
        var _idx = menuListScroll + _r;
        if (_idx >= _nB) break;
        var _lbd = _boards[_idx];
        var _ey = _listTop + _r * _entH;
        var _sel = (_idx == menuBoardIdx);
        var _hov = (_mgx0 >= _listX && _mgx0 < _listX + _listW && _mgy0 >= _ey && _mgy0 < _ey + _entH);
        if (_hov) global.uiMouseConsumed = true;

        draw_set_alpha(_sel ? 0.95 : (_hov ? 0.8 : 0.5));
        draw_set_color(_sel ? make_color_rgb(58, 82, 66) : make_color_rgb(38, 46, 52));
        draw_rectangle(_listX + 4, _ey + 3, _listX + _listW - 4, _ey + _entH - 3, false);
        draw_set_alpha(1);
        draw_set_color(_sel ? make_color_rgb(255, 224, 120) : (_hov ? make_color_rgb(150, 165, 175) : make_color_rgb(66, 76, 84)));
        draw_rectangle(_listX + 4, _ey + 3, _listX + _listW - 4, _ey + _entH - 3, true);

        draw_set_font(fntMaru);
        draw_set_color(c_white);
        dtext(_listX + 16, _ey + 10, _lbd.name);
        draw_set_color(make_color_rgb(175, 185, 180));
        dtext(_listX + 16, _ey + 34, _lbd.difficulty);
        var _sw = _listX + 16;
        for (var _c = 0; _c < array_length(_lbd.basicColors); _c++) {
            draw_set_color(pikmin_tint(_lbd.basicColors[_c]));
            draw_circle(_sw + 7, _ey + _entH - 15, 6, false);
            draw_set_color(make_color_rgb(20, 24, 20));
            draw_circle(_sw + 7, _ey + _entH - 15, 6, true);
            _sw += 18;
        }
        draw_set_color(c_white);
        if (_hov && mouse_check_button_pressed(mb_left)) menuBoardIdx = _idx;
    }
    // scroll hints
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    if (menuListScroll > 0)       dtext(_listX + _listW * 0.5, _listTop + 1, "^");
    if (menuListScroll < _maxTop) dtext(_listX + _listW * 0.5, _listBot - 15, "v");
    draw_set_halign(fa_left);
    draw_set_color(c_white);
    } // end board list (if !_netJoin)

    // ---- right: live preview of the highlighted board ----
    // structures get their own tall column down the far right; the rest of the preview
    // (name / hazards / die / gather) fills the space between the list and that column.
    var _stColW = 200;
    var _stColX = _guiW - 20 - _stColW;
    var _pvX = _listX + _listW + 26;
    var _pvR = _stColX - 24;
    var _pbd = _boards[menuBoardIdx];

    draw_set_font(fntMaru);
    draw_set_color(make_color_rgb(255, 236, 190));
    draw_text_transformed(_pvX, 50, _pbd.name, 1.9 * UI_TS, 1.9 * UI_TS, 0);
    draw_set_color(make_color_rgb(180, 190, 185));
    draw_text_transformed(_pvX, 90, _pbd.difficulty, 1.1 * UI_TS, 1.1 * UI_TS, 0);
    var _bcx = _pvX + dtext_width(_pbd.difficulty) * 1.1 + 26;
    for (var _c = 0; _c < array_length(_pbd.basicColors); _c++) {
        draw_set_color(pikmin_tint(_pbd.basicColors[_c]));
        draw_circle(_bcx + 8, 99, 8, false);
        draw_set_color(make_color_rgb(20, 24, 20));
        draw_circle(_bcx + 8, 99, 8, true);
        _bcx += 22;
    }
    draw_set_color(c_white);

    // the procedural board gets a Regenerate button to re-roll its parameters
    if (_pbd.id == "random" && ui_button(_pvR - 170, 48, 170, 32, "Regenerate", fntMaru)) {
        regenerate_random_board();
        exit;   // def just changed under us - bail this frame; next frame previews the new roll
    }

    // HAZARDS - icon chips for each terrain hazard present on the board
    var _hazY = 138;
    draw_set_color(make_color_rgb(140, 200, 235));
    draw_text_transformed(_pvX, _hazY, "HAZARDS", 1.15 * UI_TS, 1.15 * UI_TS, 0);
    draw_set_color(c_white);
    var _haz = board_hazards(_pbd);
    var _hx = _pvX, _hy = _hazY + 26;
    for (var _i = 0; _i < array_length(_haz); _i++) {
        var _lbl = hazard_display_name(_haz[_i]);
        var _cw = 32 + dtext_width(_lbl) + 12;
        if (_hx + _cw > _pvR) { _hx = _pvX; _hy += 36; }
        draw_set_alpha(0.85); draw_set_color(make_color_rgb(34, 40, 46));
        draw_rectangle(_hx, _hy, _hx + _cw, _hy + 30, false);
        draw_set_alpha(1); draw_set_color(make_color_rgb(70, 80, 88));
        draw_rectangle(_hx, _hy, _hx + _cw, _hy + 30, true);
        var _spr = element_sprite(_haz[_i]);
        if (_spr != -1) {
            var _is = 22 / max(sprite_get_width(_spr), sprite_get_height(_spr));
            draw_sprite_ext(_spr, 0, _hx + 17 - sprite_get_width(_spr) * _is * 0.5, _hy + 15 - sprite_get_height(_spr) * _is * 0.5, _is, _is, 0, c_white, 1);
        } else {
            draw_set_color(make_color_rgb(96, 84, 60)); // chasm etc - no element icon
            draw_rectangle(_hx + 8, _hy + 8, _hx + 26, _hy + 22, false);
        }
        draw_set_color(c_white);
        dtext(_hx + 32, _hy + 8, _lbl);
        _hx += _cw + 8;
    }

    // PELLET DIE - the six faces (colour + value)
    var _dieY = _hy + 48;
    draw_set_color(make_color_rgb(245, 214, 120));
    draw_text_transformed(_pvX, _dieY, "PELLET DIE", 1.15 * UI_TS, 1.15 * UI_TS, 0);
    draw_set_color(c_white);
    var _dfy = _dieY + 50;      // extra breathing room between the header and the faces
    for (var _i = 0; _i < array_length(_pbd.pelletDie); _i++) {
        var _f = _pbd.pelletDie[_i];
        var _fcx = _pvX + 18 + _i * 48;
        var _fBlank = variable_struct_exists(_f, "blank") && _f.blank;
        draw_set_color(_fBlank ? make_color_rgb(70, 74, 80) : pikmin_tint(_f.color));
        draw_circle(_fcx, _dfy, 17, false);
        draw_set_color(make_color_rgb(20, 24, 20));
        draw_circle(_fcx, _dfy, 17, true);
        draw_set_halign(fa_center); draw_set_valign(fa_middle);
        var _dark = (!_fBlank && (_f.color == "white" || _f.color == "yellow" || _f.color == "ice"));
        draw_set_color(_fBlank ? make_color_rgb(150, 155, 160) : (_dark ? c_black : c_white));
        draw_text_transformed(_fcx, _dfy, _fBlank ? "-" : string(_f.value), 1.2 * UI_TS, 1.2 * UI_TS, 0);
        draw_set_halign(fa_left); draw_set_valign(fa_top);
    }
    draw_set_color(c_white);

    // GATHER CARDS - vertically-overlapping stack across the preview's full width (hover pops)
    var _gids = board_gather_types(_pbd);
    var _headY = _dfy + 42;
    var _cardsTop = _headY + 26;
    var _cardsBot = _barY - 12;
    draw_set_color(make_color_rgb(200, 235, 170));
    draw_text_transformed(_pvX, _headY, "GATHER CARDS (" + string(array_length(_gids)) + ")", 1.15 * UI_TS, 1.15 * UI_TS, 0);
    draw_set_color(c_white);
    var _hovCard = draw_card_stack(_gids, _pvX, _cardsTop, _pvR - _pvX, _cardsBot - _cardsTop, _mgx0, _mgy0);

    // STRUCTURES - a bottom-anchored pile down the far right (landscape cards); its bottom lines
    // up with the gather cards and it grows up as tall as it needs. The label rides the TOP of
    // the pile, so it moves with the pile's size. Sorted by class (hazards -> walls -> bridges).
    var _sids = board_structures(_pbd);
    var _ss = draw_structure_stack(_sids, _stColX, _stColW, _cardsBot, 78, _mgx0, _mgy0);
    var _hovStruct = _ss.hover;
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(235, 200, 170));
    draw_text_transformed(_stColX + _stColW * 0.5, _ss.top - 26, "STRUCTURES (" + string(array_length(_sids)) + ")", 1.15 * UI_TS, 1.15 * UI_TS, 0);
    draw_set_halign(fa_left);
    draw_set_color(c_white);

    // pop whichever card is hovered, enlarged, on top of everything - keeps the card's real
    // aspect (structures are landscape) and stays on screen
    var _pop = (_hovCard != undefined) ? _hovCard : _hovStruct;
    if (_pop != undefined) {
        global.uiMouseConsumed = true;
        var _aspP = _pop.cw / _pop.ch;
        var _pch = min(_pop.ch * 1.8, _guiH - 120, (_guiW - 40) / _aspP);
        var _pcw = _pch * _aspP;
        var _px = clamp(_pop.x + _pop.cw * 0.5 - _pcw * 0.5, 20, _guiW - 20 - _pcw);
        var _py = clamp(_pop.y + _pop.ch * 0.5 - _pch * 0.5, 40, _barY - _pch - 6);
        card_draw(_pop.id, _px, _py, _pch);
    }

    draw_set_halign(fa_left);
    draw_set_color(c_white);
    exit;
}

// ==================== PAUSE MENU ====================
// Esc opens this (Step freezes the game meanwhile); shows the current map's reference info.
if (paused) {
    draw_set_alpha(0.72); draw_set_color(c_black);
    draw_rectangle(0, 0, _guiW, _guiH, false);
    draw_set_alpha(1);

    var _pw = min(1020, _guiW - 80);
    var _ph = min(700, _guiH - 36);
    var _px = (_guiW - _pw) * 0.5;
    var _py = (_guiH - _ph) * 0.5;
    draw_set_alpha(0.97); draw_set_color(make_color_rgb(26, 30, 36));
    draw_rectangle(_px, _py, _px + _pw, _py + _ph, false);
    draw_set_alpha(1); draw_set_color(make_color_rgb(255, 224, 120));
    draw_rectangle(_px, _py, _px + _pw, _py + _ph, true);

    // A pause the player did NOT open themselves needs explaining, but it is a SYSTEM notice about
    // the session rather than part of the panel's content - so it sits in the screen's top-left,
    // clear of the panel, instead of inside it where it collided with the panel's own text.
    // `_hostPaused` also gates the Resume buttons below: only the host can lift a global pause.
    var _hostPaused = (pausedByNet && !net_is_host());
    if (_hostPaused) {
        draw_set_color(make_color_rgb(255, 150, 90));
        dtext(12, 12, "The host has paused the game for everyone.");
        draw_set_color(c_white);
    }

    draw_set_font(fntMaru);
    draw_set_halign(fa_center);
    draw_set_valign(fa_top);   // establish our own text baseline - don't inherit a leaked valign from the 3D pass
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text_transformed(_px + _pw * 0.5, _py + 14, "PAUSED", 2.2 * UI_TS, 2.2 * UI_TS, 0);
    draw_set_color(make_color_rgb(200, 210, 205));
    var _pHdr = boardDef.name + "    -    Day " + string(game.dayNumber) + " (" + string(game.dayTrack) + "/" + string(game.dayTrackLength) + ")";
    if (!game.solo) _pHdr += "    -    P1 " + string(game_realized_score(game, 0)) + "p  vs  P2 " + string(game_realized_score(game, 1)) + "p"; // solo/co-op has no opponent to compare
    draw_text_transformed(_px + _pw * 0.5, _py + 50, _pHdr, 1.1 * UI_TS, 1.1 * UI_TS, 0);
    draw_set_halign(fa_left);
    draw_set_color(c_white);

    // ---- pared-down in-game OPTIONS (audio + a couple of non-experimental toggles) ----
    if (pauseScreen == "options") {
        if (ui_button(_px + 20, _py + 12, 110, 32, "< Back", fntMaru)) pauseScreen = "";
        // option toggles: stacked + horizontally centred (non-experimental only - these don't affect
        // board generation or resolution, so they're safe to change mid-game)
        var _obw = 380, _obX = _px + (_pw - _obw) * 0.5, _oy0 = _py + 104, _ostep = 56;
        if (ui_button(_obX, _oy0,             _obw, 46, "Animations: " + (global.expRules.anims ? "ON" : "off"), fntMaru)) { global.expRules.anims = !global.expRules.anims; save_settings(); }
        if (ui_button(_obX, _oy0 + _ostep,    _obw, 46, window_get_fullscreen() ? "Display: Fullscreen" : "Display: Windowed", fntMaru)) { window_set_fullscreen(!window_get_fullscreen()); save_settings(); }
        if (ui_button(_obX, _oy0 + _ostep * 2, _obw, 46, "New-pick Default: " + (defaultSelectAll ? "ALL" : "NONE"), fntMaru)) { defaultSelectAll = !defaultSelectAll; save_settings(); }
        // audio settings at the BOTTOM (above the Resume button), centred like the toggles
        var _auW = min(560, _pw - 120), _auX = _px + (_pw - _auW) * 0.5;
        draw_audio_controls(_auX, _py + _ph - 210, _auW);
        // same host-pause gate as the main panel's Resume - the options sub-panel is otherwise a
        // second, unguarded way out of a global pause
        if (_hostPaused) ui_button_disabled(_px + (_pw - 200) * 0.5, _py + _ph - 52, 200, 40, "Paused by host", fntMaru);
        else if (ui_button(_px + (_pw - 200) * 0.5, _py + _ph - 52, 200, 40, "Resume", fntMaru)) { paused = false; pauseScreen = ""; }
        draw_set_halign(fa_left); draw_set_color(c_white);
        exit;
    }

    var _cTop = _py + 86;
    var _btnY = _py + _ph - 52;

    // ---- left column: PIKMIN (this map's colours + purple/white) ----
    var _lx = _px + 28;
    draw_set_color(make_color_rgb(150, 220, 150));
    draw_text_transformed(_lx, _cTop, "PIKMIN", 1.2 * UI_TS, 1.2 * UI_TS, 0);
    draw_set_color(c_white);
    var _shown = [];
    for (var _i = 0; _i < array_length(boardDef.basicColors); _i++) array_push(_shown, boardDef.basicColors[_i]);
    if (!arr_has(_shown, "purple")) array_push(_shown, "purple");
    if (!arr_has(_shown, "white"))  array_push(_shown, "white");
    var _lw = _pw * 0.5 - 44;   // left column width (immunity/trait tags wrap within it)
    var _ry = _cTop + 34;
    for (var _i = 0; _i < array_length(_shown); _i++) {
        var _pdef = pikmin_type_get(_shown[_i]);
        draw_set_color(pikmin_tint(_shown[_i]));
        draw_circle(_lx + 8, _ry + 8, 7, false);
        draw_set_color(make_color_rgb(20, 24, 20));
        draw_circle(_lx + 8, _ry + 8, 7, true);
        draw_set_color(c_white);
        dtext(_lx + 24, _ry, _pdef.name);
        var _info = pikmin_display_tags(_shown[_i]);
        var _yc = _ry + 18;
        // element/space tags as chips
        if (array_length(_info.chips) > 0) _yc = draw_tag_row(_info.chips, _lx + 24, _yc, _lx + _lw);
        // plain-text note (pikmin properties), if any
        if (_info.note != "") {
            draw_set_color(make_color_rgb(178, 188, 194));
            dtext(_lx + 24, _yc, _info.note);
            draw_set_color(c_white);
            _yc += 18;
        }
        _ry = (_yc > _ry + 18) ? (_yc + 6) : (_ry + 24);
    }

    // ---- right column: GATHER CARDS + HAZARDS + STRUCTURES ----
    var _rx = _px + _pw * 0.5 + 16;
    var _rw = _pw * 0.5 - 44;
    draw_set_color(make_color_rgb(200, 235, 170));
    draw_text_transformed(_rx, _cTop, "GATHER CARDS", 1.2 * UI_TS, 1.2 * UI_TS, 0);
    draw_set_color(c_white);
    var _gids = board_gather_types(boardDef);
    var _nGa = array_length(_gids);
    var _half = ceil(_nGa / 2);
    var _gy = _cTop + 34;
    for (var _i = 0; _i < _nGa; _i++) {
        var _cxx = (_i < _half) ? _rx : (_rx + _rw * 0.5);
        var _cyy = _gy + ((_i < _half) ? _i : (_i - _half)) * 19;
        dtext(_cxx, _cyy, "- " + gather_display_name(_gids[_i]));
    }

    var _hazY = _gy + _half * 19 + 22;
    draw_set_color(make_color_rgb(140, 200, 235));
    draw_text_transformed(_rx, _hazY, "HAZARDS", 1.2 * UI_TS, 1.2 * UI_TS, 0);
    draw_set_color(c_white);
    var _haz = board_hazards(boardDef);
    var _hx = _rx, _hy = _hazY + 28;
    for (var _i = 0; _i < array_length(_haz); _i++) {
        var _lbl = hazard_display_name(_haz[_i]);
        var _wchip = tag_chip_width(_haz[_i], _lbl);
        if (_hx > _rx && _hx + _wchip > _rx + _rw) { _hx = _rx; _hy += 32; }
        draw_tag_chip(_hx, _hy, _haz[_i], _lbl);
        _hx += _wchip + 8;
    }

    var _stY = _hy + 44;
    draw_set_color(make_color_rgb(235, 200, 170));
    draw_text_transformed(_rx, _stY, "STRUCTURES", 1.2 * UI_TS, 1.2 * UI_TS, 0);
    draw_set_color(c_white);
    var _st = boardDef.structures;
    var _stCats = [
        ["WALLS",   variable_struct_exists(_st, "walls")    ? _st.walls    : []],
        ["BRIDGES", variable_struct_exists(_st, "bridges")  ? _st.bridges  : []],
        ["HAZARDS", variable_struct_exists(_st, "emitters") ? _st.emitters : []]
    ];
    var _stCW = _rw / 3 - 16;   // pack the columns tighter so the last one clears the edge
    for (var _c = 0; _c < 3; _c++) {
        var _cx = _rx + _c * _stCW;
        draw_set_color(make_color_rgb(205, 213, 220));
        dtext(_cx, _stY + 28, _stCats[_c][0]);
        draw_set_color(c_white);   // bullets white, matching the gather-card list
        var _items = _stCats[_c][1];
        for (var _k = 0; _k < array_length(_items); _k++)
            dtext(_cx, _stY + 48 + _k * 18, "- " + hazard_def_get(_items[_k]).name);
    }

    // ---- HOST CONTROLS (host only, online only) ----
    // Lives in the pause menu because that's the one screen already reachable mid-game, and because
    // shuffling seats is exactly when you want play halted anyway. Note the whole pause panel is
    // drawn (and its clicks handled) in the Draw event, which keeps running while Step_0 is frozen by
    // `paused` - so these controls work fine even though the game itself is stopped.
    if (net_is_host() && net_online()) {
        var _hcX = _px + 24, _hcY = _btnY - 190, _hcW = _pw - 48;
        draw_set_color(make_color_rgb(255, 224, 120));
        dtext(_hcX, _hcY - 24, "HOST CONTROLS");
        draw_set_color(c_white);

        // global pause toggle
        if (ui_button(_hcX, _hcY, 250, 32, global.net.netPaused ? "Resume Everyone" : "Pause Everyone", fntMaru)) {
            net_set_pause(!global.net.netPaused);
        }
        if (global.net.netPaused) {
            draw_set_color(make_color_rgb(255, 150, 90));
            dtext(_hcX + 264, _hcY + 8, "Play is halted for everyone.");
            draw_set_color(c_white);
        }

        var _hcl = global.net.clients;
        if (array_length(_hcl) == 0) {
            draw_set_color(make_color_rgb(150, 155, 162));
            dtext(_hcX, _hcY + 46, "Nobody else is connected.");
            draw_set_color(c_white);
        }
        // one row per connected client: who they are, then Seat/Remove-from-seat, then Kick
        var _hcRows = min(array_length(_hcl), 3);   // the panel has room for a few; the lobby is the full list
        for (var _h = 0; _h < _hcRows; _h++) {
            var _hc = _hcl[_h];
            var _hy = _hcY + 44 + _h * 36;
            var _hSeatLbl = (_hc.seat == 1) ? "P2" : "SPECTATOR";
            draw_set_color((_hc.seat == 1) ? make_color_rgb(255, 140, 140) : make_color_rgb(150, 155, 162));
            dtext(_hcX, _hy + 8, _hSeatLbl);
            draw_set_color(c_white);
            dtext(_hcX + 130, _hy + 8, _hc.name);

            // Seating a spectator mid-game hands them the COMMITTED P2 position as it stands - board,
            // hand and army all inherited via the full-state sync (user's choice: seamless handover).
            if (_hc.role == "player") {
                if (ui_button(_hcX + _hcW - 300, _hy, 180, 30, "Make Spectator", fntMaru)) net_assign_role(_hc.sock, "spectator");
            } else {
                if (ui_button(_hcX + _hcW - 300, _hy, 180, 30, "Seat as P2", fntMaru)) net_assign_role(_hc.sock, "player");
            }
            if (ui_button(_hcX + _hcW - 110, _hy, 100, 30, "Kick", fntMaru)) net_kick(_hc.sock);
        }
        if (array_length(_hcl) > _hcRows) {
            draw_set_color(make_color_rgb(150, 155, 162));
            dtext(_hcX, _hcY + 44 + _hcRows * 36 + 6, "+" + string(array_length(_hcl) - _hcRows) + " more connected");
            draw_set_color(c_white);
        }
    }

    // ---- buttons ----
    var _bw2 = 190, _bg2 = 18;
    var _btot = 4 * _bw2 + 3 * _bg2;
    var _bx0 = _px + (_pw - _btot) * 0.5;
    // Resume is INERT for a client under a host-imposed global pause - only the host can lift it, and
    // a live-looking button that silently does nothing is worse than one that reads as unavailable.
    // A HOST leaving its own pause must also lift the global pause, or everyone else stays frozen.
    if (_hostPaused) {
        ui_button_disabled(_bx0, _btnY, _bw2, 40, "Paused by host", fntMaru);
    } else if (ui_button(_bx0, _btnY, _bw2, 40, "Resume", fntMaru)) {
        paused = false;
        if (net_is_host() && global.net.netPaused) net_set_pause(false);
    }
    if (ui_button(_bx0 + (_bw2 + _bg2), _btnY, _bw2, 40, "Options", fntMaru)) pauseScreen = "options";
    if (ui_button(_bx0 + (_bw2 + _bg2) * 2, _btnY, _bw2, 40, "Main Menu", fntMaru)) { paused = false; return_to_menu(); exit; }
    if (ui_button(_bx0 + (_bw2 + _bg2) * 3, _btnY, _bw2, 40, "Quit", fntMaru)) game_end();

    // controls readout - only shown while paused (same bottom-of-screen spot it used to occupy)
    draw_set_halign(fa_left);
    draw_set_color(make_color_rgb(200, 205, 215));
    dtext(8, _guiH - 20, "Left: Select   Middle: Send All   Right-drag: Orbit Camera   WASD: Pan   Wheel: Zoom/Scroll   Alt: Inspect   V: Treasure   F2: Return to Menu");
    draw_set_color(c_white);
    exit;
}

var _p = game.activePlayer;
var _pl = game.players[_p];
var _aiTurn = (ctl[_p] != "human" && game.phase != "gameover");
var _cine = (dayCine != undefined); // day cinematic playing - block all human input
var _locked = _cine || turnSettling || array_length(game.resolveQueue) > 0
    || game.pendingDiscard != undefined       // settling / staged resolution / hand-limit picker
    || game.pendingDaySwap != undefined        // day-track swap choice modal (resolved below)
    || game.pendingDayPlace != undefined       // day-track pod/storm placement modal (resolved below)
    || game.pendingEvent != undefined          // adventure event space pick modal (resolved below)
    || game.pendingTypePick != undefined       // adventure card-type chooser modal (resolved below)
    || game.pendingLose != undefined           // adventure lose-pikmin picker (resolved below)
    || game.pendingReveal != undefined         // Reveal power: opponent reorders a pile (resolved below)
    || game.pendingSpy != undefined;           // Spy peek modal (resolved below)
// boss bounty placements block ALL normal play until the queue is resolved
var _freePending = (array_length(game.pendingFree) > 0 && game.phase != "gameover");
var _freeHuman = _freePending && (ctl[game.pendingFree[0].playerIdx] == "human");
var _daySwapHuman = (game.pendingDaySwap != undefined && ctl[game.pendingDaySwap.playerIdx] == "human");
var _dayPlaceHuman = (game.pendingDayPlace != undefined && ctl[game.pendingDayPlace.playerIdx] == "human");
var _eventHuman = (game.pendingEvent != undefined && ctl[game.pendingEvent.playerIdx] == "human");
var _loseHuman = (game.pendingLose != undefined && ctl[game.pendingLose.playerIdx] == "human");
var _revealHuman = (game.pendingReveal != undefined && ctl[game.pendingReveal.chooser] == "human");

// ---------- hover picking: nearest space/home centre in screen space ----------
hoverKind = ""; hoverLane = -1; hoverIdx = -1;
var _vp = matrix_multiply(viewMat, projMat);
var _mgx = device_mouse_x_to_gui(0);
var _mgy = device_mouse_y_to_gui(0);
var _bestDist = 46;
for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
    for (var _spaceIdx = 0; _spaceIdx < array_length(board.lanes[_laneIdx].spaces); _spaceIdx++) {
        var _wPos = board_space_xy(board, _laneIdx, _spaceIdx);
        var _scr = world_to_gui(_vp, _wPos[0], _wPos[1], 1);
        if (_scr == undefined) continue;
        var _d = point_distance(_mgx, _mgy, _scr[0], _scr[1]);
        if (_d < _bestDist) { _bestDist = _d; hoverKind = "space"; hoverLane = _laneIdx; hoverIdx = _spaceIdx; }
    }
}
// the WHOLE home strip is clickable, not just points in line with the lanes: test the cursor against
// the strip's projected quad. A space picked above wins over the home row behind it.
if (hoverKind != "space") {
    var _stripHalfW = board.laneCount * (TILE_W + LANE_GAP) * 0.5;
    for (var _h = 0; _h < (game.solo ? 1 : 2); _h++) {   // solo/adventure: no far home to pick
        var _hy = board_home_y(board, _h);
        var _q0 = world_to_gui(_vp, -_stripHalfW, _hy - TILE_H * 0.5, 1);
        var _q1 = world_to_gui(_vp,  _stripHalfW, _hy - TILE_H * 0.5, 1);
        var _q2 = world_to_gui(_vp,  _stripHalfW, _hy + TILE_H * 0.5, 1);
        var _q3 = world_to_gui(_vp, -_stripHalfW, _hy + TILE_H * 0.5, 1);
        if (_q0 == undefined || _q1 == undefined || _q2 == undefined || _q3 == undefined) continue;
        if (point_in_convex_quad(_mgx, _mgy, _q0, _q1, _q2, _q3)) { hoverKind = "home"; hoverLane = -1; hoverIdx = _h; }
    }
}
// the active player's ONION discard zone (their left, mirror of the horde): a click
// target that dismisses the selected pikmin. Only the owner's zone is pickable.
if (!_aiTurn) {
    var _oScr = world_to_gui(_vp, (_p == 0) ? 440 : -440, board_home_y(board, _p) * 0.86, 1.66);
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
            draw_set_font(fntMaru);
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
            draw_set_font(fntMaru);
            draw_set_halign(fa_left);
            draw_set_valign(fa_top);
            draw_set_color(c_white);
        }
    }
}

// ---------- Onion hover hint ----------
if (hoverKind == "onion" && game.phase == "orders" && !_aiTurn && !_locked) {
    draw_set_font(fntMaru);
    var _otTxt = (selSrc != undefined)
        ? "Onion: Click to DISCARD the selected pikmin"
        : "Onion: Send Pikmin here to DISCARD them";
    var _otW = dtext_width(_otTxt);
    var _otH = dtext_height(_otTxt);
    var _otX = _mgx + 14;
    var _otY = _mgy - _otH * 0.5;
    draw_set_alpha(0.78);
    draw_set_color(c_black);
    draw_rectangle(_otX, _otY - 4, _otX + _otW + 16, _otY + _otH + 4, false);
    draw_set_alpha(1);
    draw_set_color(make_color_rgb(255, 224, 120));
    dtext(_otX + 8, _otY, _otTxt);
    draw_set_color(c_white);
}

// ---------- top bar ----------
var _barH = 36;
var _capMax = game_pikmin_cap(game, _p);   // active player's cap, including their FLARLIC boost
var _midY = _barH * 0.5;
draw_set_alpha(0.9);
draw_set_color(player_tint(_p));
draw_rectangle(0, 0, _guiW, _barH, false);
draw_set_alpha(1);
draw_set_font(fntMaru);
draw_set_valign(fa_middle);
draw_set_halign(fa_left);

// left: board + day
draw_set_color(c_white);
// ADVENTURE: the top-left day shows the CAMPAIGN day (cumulative across boards) out of the run's
// day budget, not just this board's day. daysUsed = completed days on prior boards.
var _leftHdr;
if (advRun != undefined) {
    var _campDay  = advRun.daysUsed + game.dayNumber;
    // use game.dayLimit (== daysLeft at mission start, but GROWS for Glutton's dayPerTreasure) so the
    // HUD total climbs as treasures are banked.
    var _campTotal = advRun.daysUsed + game.dayLimit;
    _leftHdr = advRun.name + "    Day " + string(_campDay) + " / " + string(_campTotal) + " (" + string(game.dayTrack) + "/" + string(game.dayTrackLength) + ")";
} else {
    _leftHdr = boardDef.name + "    Day " + string(game.dayNumber) + " (" + string(game.dayTrack) + "/" + string(game.dayTrackLength) + ")";
}
dtext(10, _midY, _leftHdr);
if (batchRemaining > 0) {
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    dtext(_guiW * 0.5, 44, "[BATCH: " + string(batchRemaining) + " games left]"); // below the top bar
    draw_set_color(c_white);
    draw_set_halign(fa_left);
}

// ---------- day tracker: the board's day-event symbols, evenly spaced down the LEFT edge.
// ---------- Phase 1 at the top, the last at the bottom; the current phase is enlarged and
// ---------- phases already passed are darkened. Driven by the board's dayTrackDef.spaces. ----------
if (variable_struct_exists(game, "dayTrackDef")) {
    var _dtSpaces = game.dayTrackDef.spaces;
    var _dtN = array_length(_dtSpaces);
    if (_dtN > 0) {
        var _dtCur = clamp(game.dayTrack, 1, _dtN) - 1;   // 0-based current segment
        var _dtPadTop = _barH + 110;                       // clear the top bar, with breathing room
        var _dtPadBot = 220;                               // pull the strip in so the icons sit closer together
        var _dtX = 42;                                     // centre of the icon column
        var _dtBase = 46;                                  // normal icon size
        var _dtCurSize = 64;                               // current phase, a bit larger + breathing (below)
        var _dtSpan = _guiH - _dtPadTop - _dtPadBot;
        for (var _d = 0; _d < _dtN; _d++) {
            var _dtY = (_dtN > 1) ? _dtPadTop + _dtSpan * _d / (_dtN - 1) : _dtPadTop + _dtSpan * 0.5;
            var _dtSpr = day_event_sprite(_dtSpaces[_d]);
            if (_dtSpr == -1) continue;
            // the current phase slowly "breathes" - grows and shrinks on a gentle sine
            var _dtSz = (_d == _dtCur) ? (_dtCurSize + dsin(frameTick * 1.4) * 5) : _dtBase;
            var _dtPast = (_d < _dtCur);
            var _dtCol = _dtPast ? make_color_rgb(96, 102, 110) : c_white;  // darken passed phases
            var _dtAl = _dtPast ? 0.65 : 1;
            var _sw2 = sprite_get_width(_dtSpr), _sh2 = sprite_get_height(_dtSpr);
            var _scl2 = _dtSz / max(_sw2, _sh2);
            // centre the sprite's bounding box on (_dtX,_dtY) regardless of its origin
            var _drawX = _dtX - (_sw2 * 0.5 - sprite_get_xoffset(_dtSpr)) * _scl2;
            var _drawY = _dtY - (_sh2 * 0.5 - sprite_get_yoffset(_dtSpr)) * _scl2;
            draw_sprite_ext(_dtSpr, 0, _drawX, _drawY, _scl2, _scl2, 0, _dtCol, _dtAl);
        }
        draw_set_color(c_white);
        draw_set_alpha(1);
    }
}

// middle: current player's detailed pikmin breakdown (token icons + counts + total). Start it AFTER
// the left day/name header's actual width (floored at 320 so short names keep the old layout), so a
// long map name + day can't overlap the score/pikmin readout. Plenty of room before the right readout.
var _bx = max(320, 10 + dtext_width(_leftHdr) + 24);
// difficulty word for an AI seat: prefer the saved menu tier (persisted in the ini via
// global.settings), falling back to the live brain id for F1/rematch/batch swaps where the
// menu tier no longer describes the seat.
var _seatAiWord = function(_seat) {
    var _tier = menuCtl[_seat];
    // use the tier's nice name only while the LIVE brain is still the one that tier resolves
    // to; F1/rematch/batch can swap ctl out from under the menu tier - then show the brain.
    if ((_tier == "easy" || _tier == "medium" || _tier == "hard")
        && ctl[_seat] == seat_brain(boardDef.id, _tier)) return seat_ai_label(_tier);
    return seat_ai_label(ctl[_seat]);
};
// the active seat's label: "YOU" for the local human, the opponent's name online, else "P<n> (<AI>)"
// SPECTATOR: neither seat is ours, so "YOU"/the single remoteName would be wrong (both seats would
// read as the host). Name both seats from the roster instead.
var _meLbl = net_is_spectator() ? net_seat_name(_p)
           : ((ctl[_p] == "human") ? "YOU" : ((ctl[_p] == "remote") ? global.net.remoteName : ("P" + string(_p + 1) + " (" + _seatAiWord(_p) + ")")));
var _youLbl = _meLbl + " " + string(game_realized_score(game, _p)) + "p";
draw_set_color(make_color_rgb(255, 236, 180));
dtext(_bx, _midY, _youLbl);
_bx += dtext_width(_youLbl) + 18;
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
        _bx += 24; // the round dot needs a touch more gap before its count than the sprites do
    }
    dtext(_bx, _midY, string(_typeCounts[$ _tid]));
    _bx += dtext_width(string(_typeCounts[$ _tid])) + 12;
}
var _youB = game_bulbmin_count(game, _p);
draw_set_color(make_color_rgb(200, 210, 222));
dtext(_bx + 2, _midY, "= " + string(game_capped_count(game, _p)) + "/" + string(_capMax) + ((_youB > 0) ? ("  +" + string(_youB) + "b") : ""));

// right: opponent compact ("player <poko> [x/25]") + phase. Solo/co-op has no opponent - just phase.
var _phaseName = game.phase == "gather" ? "GATHER" : (game.phase == "orders" ? "ORDERS" : (game.phase == "move" ? "MOVE" : "GAME OVER"));
draw_set_color(c_white);
draw_set_halign(fa_right);
if (game.solo) {
    dtext(_guiW - 10, _midY, _meLbl + " - " + _phaseName);
} else {
    var _opp = 1 - _p;
    var _oppB = game_bulbmin_count(game, _opp);
    var _oppCap = string(game_capped_count(game, _opp)) + "/" + string(_capMax) + ((_oppB > 0) ? ("+" + string(_oppB) + "b") : "");
    var _oppLbl = net_is_spectator() ? ("vs " + net_seat_name(_opp))
        : ((ctl[_opp] == "remote") ? ("vs " + global.net.remoteName)
        : ("vs P" + string(_opp + 1) + ((ctl[_opp] != "human") ? (" (" + _seatAiWord(_opp) + ")") : "")));
    dtext(_guiW - 10, _midY, _oppLbl + " " + string(game_realized_score(game, _opp)) + "p [" + _oppCap + "]        " + _meLbl + " - " + _phaseName);
}
draw_set_halign(fa_left);
draw_set_valign(fa_top);
ui_block_rect(0, 0, _guiW, _barH);
// (the full controls readout now lives on the pause screen only - see the paused block above)

// ---------- log panel (right) ----------
var _logX = _guiW - 330;
var _logH = 16 * 14 + 10;
draw_set_alpha(0.55);
draw_set_color(c_black);
draw_rectangle(_logX, 40, _guiW - 8, 40 + _logH, false);
draw_set_alpha(1);
draw_set_font(fntMaru);
draw_set_color(make_color_rgb(220, 220, 220));
var _logN = array_length(game.log);
var _logMaxW = (_guiW - 8) - (_logX + 8) - 4; // inner width
var _logTop = 40, _logBot = 40 + _logH;

// flatten every entry into its wrapped visual ROWS (oldest first, newest last) so layout
// and clipping happen per row - a 2-row entry no longer vanishes or overflows as one block.
var _rows = [];
for (var _i = 0; _i < _logN; _i++) {
    var _entry = game.log[_i];
    var _isChat = (string_char_at(_entry, 1) == chr(1));   // chat marker prefix
    if (_isChat) _entry = string_delete(_entry, 1, 1);
    // detect the treasure-power line ONCE per entry so ALL its wrapped rows get the brighter base
    var _isPower = (!_isChat) && (string_pos("[Good]", _entry) > 0 || string_pos("[Bad]", _entry) > 0);
    var _wrapped = dtext_wrap(_entry, _logMaxW);
    for (var _wj = 0; _wj < array_length(_wrapped); _wj++) {
        var _cat = _isChat ? (_wj == 0 ? "chat" : "chatcont") : (_isPower ? "power" : "game");
        array_push(_rows, { text: _wrapped[_wj], cat: _cat });
    }
}
var _rowN = array_length(_rows);
var _rowH = dtext_height("Ag") + 3;            // uniform per-row advance
var _contentH = _rowN * _rowH;
var _maxScroll = max(0, _contentH - (_logH - 8));
// if the reader has scrolled UP, new rows must NOT drag them to the bottom: bump logScroll by
// the added rows so the view stays anchored to the same content. At the bottom (logScroll==0)
// it stays 0 and keeps auto-following the newest. Scrolling back to 0 re-locks the auto-follow.
if (logScroll > 0 && _rowN > logRowsPrev) logScroll += (_rowN - logRowsPrev) * _rowH;
logRowsPrev = _rowN;
logScroll = clamp(logScroll, 0, _maxScroll);

// newest row anchored at the bottom, stacking upward. logScroll pushes the anchor DOWN
// (newest off the bottom) so older rows scroll in. Only FULLY-visible rows are drawn, so
// nothing ever spills past the top (into the bar) or below the panel.
var _ly = _logBot - 4 - _rowH + logScroll;
for (var _i = _rowN - 1; _i >= 0; _i--) {
    if (_ly + _rowH < _logTop) break;          // fully above the panel - older rows are higher still
    if (_ly >= _logTop + 2 && _ly + _rowH <= _logBot - 2) log_draw_line(_logX + 8, _ly, _rows[_i].text, _rows[_i].cat);
    _ly -= _rowH;
}
draw_set_color(c_white);
// scroll affordances: a hint when more log sits above (older) / below (newer)
if (logScroll < _maxScroll) {
    draw_set_color(make_color_rgb(255, 224, 120));
    dtext(_guiW - 22, _logTop + 2, "^");
}
if (logScroll > 0) {
    draw_set_color(make_color_rgb(255, 224, 120));
    dtext(_guiW - 22, _logBot - 16, "v");
}
draw_set_color(c_white);
ui_block_rect(_logX, 40, _guiW - 8 - _logX, _logH);

// ---------- chat box (below the log) - type + Enter injects "<name>: <msg>" into the log,
// ---------- synced to the peer online (usable in singleplayer too, for testing) ----------
var _chW = _guiW - 8 - _logX;
var _chH = 26;
var _chX = _logX;
var _chY = 40 + _logH + 6;   // a few px gap under the log, same width
draw_set_alpha(chatFocused ? 0.8 : 0.5);
draw_set_color(chatFocused ? make_color_rgb(28, 40, 56) : c_black);
draw_rectangle(_chX, _chY, _chX + _chW, _chY + _chH, false);
draw_set_alpha(1);
draw_set_color(chatFocused ? make_color_rgb(255, 224, 120) : make_color_rgb(110, 110, 120));
draw_rectangle(_chX, _chY, _chX + _chW, _chY + _chH, true);
draw_set_font(fntMaru);
draw_set_valign(fa_middle);
if (chatFocused) {
    draw_set_color(c_white);
    var _caret = ((frameTick div 16) mod 2 == 0) ? "|" : " ";
    dtext(_chX + 8, _chY + _chH * 0.5, chatText + _caret);
} else {
    draw_set_color((chatText == "") ? make_color_rgb(140, 140, 148) : make_color_rgb(210, 210, 210));
    dtext(_chX + 8, _chY + _chH * 0.5, (chatText == "") ? "Click to chat..." : chatText);
}
draw_set_valign(fa_top);
draw_set_color(c_white);
ui_block_rect(_chX, _chY, _chW, _chH);
// focus toggle: click inside focuses (and seeds keyboard_string with the current buffer); a
// click outside blurs.
if (mouse_check_button_pressed(mb_left)) {
    var _mcx = device_mouse_x_to_gui(0), _mcy = device_mouse_y_to_gui(0);
    var _inChat = (_mcx >= _chX && _mcx <= _chX + _chW && _mcy >= _chY && _mcy <= _chY + _chH);
    if (_inChat) { chatFocused = true; keyboard_string = chatText; }
    else if (chatFocused) chatFocused = false;
}
// while focused, keyboard_string IS the buffer (GM applies backspace); Enter sends, Esc blurs
if (chatFocused) {
    chatText = string_replace_all(string_replace_all(keyboard_string, "\n", ""), "\r", "");
    if (string_length(chatText) > 120) { chatText = string_copy(chatText, 1, 120); keyboard_string = chatText; }
    if (keyboard_check_pressed(vk_enter)) {
        if (chatText != "") chat_send(chatText);
        chatText = ""; keyboard_string = "";
        // NOTE: don't force logScroll=0 here - if you're at the bottom the log already follows
        // (sees your line); if you've scrolled up, the anti-autoscroll keeps your place.
    }
    if (keyboard_check_pressed(vk_escape)) chatFocused = false;
}


// (treasure on-bank power toasts are drawn later, AFTER the hand, so the hand sits BEHIND them)

// ---------- phase controls (left column) ----------
var _cy = 44;
if (_cine) {
    dtext_bg(12, _cy, "Sunset - Time to return home!", make_color_rgb(255, 224, 120));
} else if (_locked && game.pendingDaySwap == undefined && game.pendingDayPlace == undefined && game.pendingReveal == undefined) {   // day events / Reveal have their own prompts below
    dtext_bg(12, _cy, (game.pendingDiscard != undefined)
        ? ("P" + string(game.pendingDiscard.playerIdx + 1) + " discards to the hand limit...")
        : (turnSettling ? "..." : "Resolving..."), make_color_rgb(200, 210, 220));
} else if (_freePending) {
    var _fpEntry = game.pendingFree[0];
    dtext_bg(12, _cy, "BOSS BOUNTY: P" + string(_fpEntry.playerIdx + 1) + " places " + string(_fpEntry.count) + " free hazard(s)", c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _freeHuman ? "Pick a hazard type, then click an empty basic space." : "The AI is choosing its spot" + string_repeat(".", 1 + (frameTick div 20) mod 3));
} else if (game.pendingDaySwap != undefined) {
    var _ds = game.pendingDaySwap;
    dtext_bg(12, _cy, "DAY SWAP: P" + string(_ds.playerIdx + 1) + " changes a tile", c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _daySwapHuman ? "Click one of your highlighted spaces." : ("P" + string(_ds.playerIdx + 1) + " is choosing" + string_repeat(".", 1 + (frameTick div 20) mod 3)));
    _cy += 26;
    // two swatches: FROM tile -> TO tile, so the change is unmistakable
    var _sw = 46, _swY = _cy;
    tile_swatch_draw(12, _swY, _sw, _ds.from);
    draw_set_halign(fa_center); draw_set_valign(fa_middle); draw_set_font(fntMaru); draw_set_color(c_white);
    draw_text_transformed(12 + _sw + 22, _swY + _sw * 0.5, ">", 1.4 * UI_TS, 1.4 * UI_TS, 0);
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    tile_swatch_draw(12 + _sw + 44, _swY, _sw, _ds.to);
    _cy += _sw + 6;
} else if (game.pendingDayPlace != undefined) {
    var _pp = game.pendingDayPlace;
    var _ppLabel = (_pp.kind == "pod") ? ("POD: P" + string(_pp.playerIdx + 1) + " places enemies (" + string(_pp.count) + " left)")
                                       : ("STORM: P" + string(_pp.playerIdx + 1) + " drops a hazard");
    dtext_bg(12, _cy, _ppLabel, c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _dayPlaceHuman
        ? (_pp.kind == "pod" ? "Click a highlighted enemy space." : "Click one of your highlighted spaces.")
        : ("P" + string(_pp.playerIdx + 1) + " is choosing" + string_repeat(".", 1 + (frameTick div 20) mod 3)));
    _cy += 26;
} else if (game.pendingEvent != undefined) {
    var _pe = game.pendingEvent;
    var _peName = { soil: "SOIL: place a floor hazard", killwall: "Destroy a wall", killbridge: "Destroy a bridge",
                    killemitter: "Destroy an emitter", rerollwall: "Rebuild a wall", spicy: "Ultra-Spicy a space" };
    dtext_bg(12, _cy, "EVENT: " + (variable_struct_exists(_peName, _pe.effect) ? _peName[$ _pe.effect] : _pe.effect), c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _eventHuman ? "Click a highlighted space." : ("P" + string(_pe.playerIdx + 1) + " is choosing" + string_repeat(".", 1 + (frameTick div 20) mod 3)));
    _cy += 26;
} else if (game.pendingLose != undefined) {
    dtext_bg(12, _cy, "LOSE PIKMIN: " + string(game.pendingLose.need) + " to remove", c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _loseHuman ? "Click your pikmin (a highlighted space, or your Onion) to remove one."
                                 : ("P" + string(game.pendingLose.playerIdx + 1) + " is choosing" + string_repeat(".", 1 + (frameTick div 20) mod 3)));
    _cy += 26;
} else if (game.pendingReveal != undefined && game.pendingReveal.lane < 0) {
    // Reveal phase A: the chooser picks WHICH pile to reorder (card pick is a modal, below)
    dtext_bg(12, _cy, "REVEAL: P" + string(game.pendingReveal.chooser + 1) + " reorders a pile", c_yellow);
    _cy += 22;
    dtext_bg(12, _cy, _revealHuman ? "Click a highlighted treasure pile." : ("P" + string(game.pendingReveal.chooser + 1) + " is choosing" + string_repeat(".", 1 + (frameTick div 20) mod 3)));
    _cy += 26;
} else if (_aiTurn) {
    // SPECTATOR: `remoteName` is whoever we HANDSHOOK with - always the host - so using it here made
    // every turn read as P1's regardless of who was actually acting. A spectator has no "the other
    // player", so name the ACTIVE seat from the roster instead (same fix as _meLbl/_oppLbl).
    var _turnWho = net_is_spectator() ? (net_seat_name(_p) + "'s turn")
        : ((ctl[_p] == "remote") ? (global.net.remoteName + "'s turn") : "AI is taking its turn");
    dtext_bg(12, _cy, _turnWho + string_repeat(".", 1 + (frameTick div 20) mod 3));
} else if (game.phase == "gather") {
    dtext_bg(12, _cy, "Gather actions left: " + string(game.gatherActionsLeft));
    _cy += 22;
    // during the tutorial, hide Draw until a step opts in (showDraw:true) - gather cards aren't
    // taught until later, and the early lesson is about rolling for Pellets.
    if (tutorial_draw_shown()) {
        if (ui_button(12, _cy, 220, 34, "Draw Gather Card (" + string(array_length(game.decks.gather)) + ")")) game_gather_draw(game);
        _cy += 42;
    }
    if (tutorial_roll_shown()) {
        if (ui_button(12, _cy, 220, 34, "Roll Pellet Die")) game_gather_roll(game);
    }
} else if (game.phase == "orders") {
    if (ui_button(12, _cy, 220, 34, "End Orders")) { game_orders_done(game); selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; }
    _cy += 42;
    dtext_bg(12, _cy, "Send Pikmin to Onion to DISCARD", make_color_rgb(170, 180, 190));
    _cy += 24;
} else if (game.phase == "move") {
    if (pendingCard == undefined) {
        if (ui_button(12, _cy, 260, 40, "Resolve Moves & End Turn")) { game_resolve_moves(game); selSrc = undefined; pelletMenuIdx = -1; posyMenuIdx = -1; }
        _cy += 48;
        dtext_bg(12, _cy, "Play gather cards now by clicking them in your hand.");
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
        dtext_bg(12, _cy, _prompt);
        _cy += 26;
        if (ui_button(12, _cy, 150, 30, "Cancel")) pendingCard = undefined;
    }
} else if (game.phase == "gameover" && gameoverSettled && advRun == undefined) {
    // dim the raw 3D board behind the results so the text/buttons read clearly
    draw_set_alpha(0.62);
    draw_set_color(make_color_rgb(10, 12, 16));
    draw_rectangle(0, 0, _guiW, _guiH, false);
    draw_set_alpha(1);
    draw_set_color(c_white);
    var _goY = _guiH * 0.32;
    draw_set_halign(fa_center);
    draw_set_font(fntMaru);
    draw_set_color(c_yellow);
    // winner + score sit in the TOP THIRD, leaving the middle open for the population graph
    var _headY = _guiH * 0.12;
    var _msg = (game.winner == -1) ? "DRAW!" : ("PLAYER " + string(game.winner + 1) + " WINS!");
    draw_text_transformed(_guiW * 0.5, _headY, _msg, 4 * UI_TS, 4 * UI_TS, 0);
    draw_set_color(c_white);
    draw_text_transformed(_guiW * 0.5, _headY + 66, "P1 " + string(game_realized_score(game, 0)) + "p  vs  P2 " + string(game_realized_score(game, 1)) + "p", 2.6 * UI_TS, 2.6 * UI_TS, 0);
    draw_set_font(fntMaru);
    draw_set_halign(fa_left);
    // population graph (seat toggle for the two seats) - stays in the middle where it was
    var _ggW = min(640, _guiW - 200), _ggH = 200;
    draw_results_graph((_guiW - _ggW) * 0.5, _goY + 150, _ggW, _ggH);
    var _goBtnY = _goY + 150 + _ggH + 60;
    if (ui_button(_guiW * 0.5 - 210, _goBtnY, 200, 46, "Rematch (same board/players)")) {
        showCollection = false; // the auto-opened sidebars don't follow into the next game
        start_game(boardDef.id, ctl);
        exit;
    }
    if (ui_button(_guiW * 0.5 + 10, _goBtnY, 200, 46, "Main Menu")) {
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
            dtext(16, _rowY + 3, _colId + ": " + string(_cur) + "/" + string(_have));
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

// ---------- hand: ALWAYS show the human viewer's cards (the old "hide when it's not
// ---------- your turn" was a hotseat holdover); interactive only on the viewer's turn ----------
var _viewer = (ctl[0] == "human") ? 0 : ((ctl[1] == "human") ? 1 : -1); // the human seat (-1 = spectating, both AI)
var _vpl = (_viewer >= 0) ? game.players[_viewer] : _pl;
var _handEntries = [];
for (var _i = 0; _i < array_length(_vpl.hand); _i++) array_push(_handEntries, { kind: "gather", cardId: _vpl.hand[_i], pelletIdx: -1 });
for (var _i = 0; _i < array_length(_vpl.pellets); _i++) array_push(_handEntries, { kind: "pellet", cardId: _vpl.pellets[_i], pelletIdx: _i });
var _numCards = array_length(_handEntries);
var _handInteractive = (_viewer == _p && !_aiTurn && !_freePending && !_locked); // your own turn only
if (_numCards > 0 && game.phase != "gameover" && _viewer >= 0) {
    var _cardH = 170;
    var _cardW = _cardH * 0.714;
    var _step = (_numCards * (_cardW + 10) <= _guiW - 560) ? (_cardW + 10) : max(34, (_guiW - 560 - _cardW) / max(1, _numCards - 1));
    var _handW = _cardW + _step * (_numCards - 1);
    var _hx0 = (_guiW - _handW) * 0.5;   // centred on the window
    var _hy = _guiH - _cardH * 0.62;
    ui_block_rect(_hx0 - 10, _hy - 12, _handW + 20, _cardH);
    var _hovered = -1;
    for (var _i = 0; _i < _numCards; _i++) {
        // darkened (unplayable) cards don't zoom on hover - it looks awkward
        if (!hand_card_playable(_handEntries[_i], game.phase, _handInteractive)) continue;
        var _cx = _hx0 + _i * _step;
        var _cw = (_i == _numCards - 1) ? _cardW : _step;
        if (_mgx >= _cx && _mgx < _cx + _cw && _mgy >= _hy - 12) _hovered = _i;
    }
    for (var _i = 0; _i < _numCards; _i++) {
        if (_i == _hovered) continue;
        var _hcx = _hx0 + _i * _step;
        card_draw(_handEntries[_i].cardId, _hcx, _hy, _cardH);
        // darken cards that can't be played right now (wrong phase, or the opponent's turn)
        if (!hand_card_playable(_handEntries[_i], game.phase, _handInteractive)) {
            draw_set_alpha(0.5);
            draw_set_color(make_color_rgb(16, 18, 24));
            draw_rectangle(_hcx, _hy, _hcx + _cardW, _hy + _cardH, false);
            draw_set_alpha(1);
            draw_set_color(c_white);
        }
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
            dtext(_bigX + _bigW * 0.5, _guiH - _bigH - 26, _copyTxt);
            draw_set_color(c_white);
            draw_set_halign(fa_left);
        }
        if (_handInteractive && mouse_check_button_pressed(mb_left)) {
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
                    sfx("sfxError");   // clicked a gather card in a phase it can't be played
                    game_log(game, "Gather cards cannot be played now. (Wrong phase)");
                }
            }
        }
    }
}

// ---------- treasure on-bank power toasts ----------
// A min-height / half-width TITLE bubble stacked directly above (NO overlap) a fixed-width DESCRIPTION
// bubble that grows only in height to fit its wrapped fntDialog text. Both nine-slice (sprTextBox),
// outlined text. Cues arrive in a PENDING queue and pop in ONE AT A TIME (slight delay); each slides
// up from below and pushes the older ones up, fading in/out over its lifetime. (Bottom-left.) Drawn
// HERE, after the hand, so the centred hand renders behind these and never blocks a treasure effect.
for (var _bqi = 0; _bqi < array_length(game.bankCues); _bqi++) {
    var _bqc = game.bankCues[_bqi];
    array_push(toastQueue, { name: _bqc.name, effect: _bqc.effect, good: _bqc.good, outcome: variable_struct_exists(_bqc, "outcome") ? _bqc.outcome : undefined });
}
game.bankCues = [];
// release one queued toast every _toSpawnDelay frames (it slides in at the bottom)
var _toSpawnDelay = 14;
if (toastSpawnTimer > 0) toastSpawnTimer -= 1;
if (toastSpawnTimer <= 0 && array_length(toastQueue) > 0) {
    var _nq = toastQueue[0]; array_delete(toastQueue, 0, 1);
    array_push(toastList, { name: _nq.name, effect: _nq.effect, good: _nq.good, outcome: _nq.outcome, age: 0, y: _guiH + 70, targetY: _guiH, deH: 108 });
    toastSpawnTimer = _toSpawnDelay;
}
if (array_length(toastList) > 0) {
    // --- tuning knobs. The nine-slice is drawn at _nsScale so its CORNERS shrink too (small + crisp),
    // and the bubbles HUG their (bigger) text. min bubble = _nsScale * sprite-min (159x108). ---
    var _nsScale = 0.5, _nsMinW = 80, _nsMinH = 54;
    var _toX = 16, _deW = 396;                           // description: fixed on-screen width (~50% wider)
    var _toLife = 360, _toFadeIn = 12, _toFadeOut = 55;  // longer-lived; fade keyed off age
    var _tiSc = 2.3 * UI_TS, _deSc = 1.8 * UI_TS, _deSep = 30;   // bigger text than before
    var _tiPadX = 28, _tiPadY = 13;                      // title hugs its text (less vertical padding)
    var _dePadX = 28, _dePadTop = 13, _dePadBot = 18;
    var _gap = 4;
    var _bottomY = _guiH - 14;
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    draw_set_font(fntDialog);
    // age + cull
    for (var _ti = array_length(toastList) - 1; _ti >= 0; _ti--) {
        toastList[_ti].age += 1;
        if (toastList[_ti].age >= _toLife) array_delete(toastList, _ti, 1);
    }
    // layout from the BOTTOM up (newest = last = bottom); size each bubble to hug its text
    var _deTxtW = _deW - _dePadX * 2;
    var _cursorY = _bottomY;
    for (var _li = array_length(toastList) - 1; _li >= 0; _li--) {
        var _to = toastList[_li];
        _to.deH = max(_nsMinH, _dePadTop + string_height_ext(_to.effect, _deSep / _deSc, _deTxtW / _deSc) * _deSc + _dePadBot);
        _to.tiW = max(_nsMinW, string_width(_to.name) * _tiSc + _tiPadX * 2);
        _to.tiH = _nsMinH + 12;   // one-line title: min height + a little breathing room (fa_middle centres it). Bare min was too tight; string_height's full line-leading was too tall
        _cursorY -= (_to.tiH + _gap + _to.deH);          // title + gap + description (no overlap)
        _to.targetY = _cursorY;                           // y of the title bubble top
        _cursorY -= _gap;
    }
    // animate toward targetY (slide-in + push-up) and render
    for (var _ri = array_length(toastList) - 1; _ri >= 0; _ri--) {
        var _to = toastList[_ri];
        _to.y = lerp(_to.y, _to.targetY, 0.22);
        var _a = clamp(min(_to.age / _toFadeIn, (_toLife - _to.age) / _toFadeOut, 1), 0, 1);
        var _tiY = _to.y;
        var _deY = _to.y + _to.tiH + _gap;               // description BELOW the title, no overlap
        draw_nineslice_scaled(sprTextBox, _toX, _deY, _deW, _to.deH, _nsScale, c_white, _a);
        draw_nineslice_scaled(sprTextBox, _toX, _tiY, _to.tiW, _to.tiH, _nsScale, c_white, _a);
        draw_set_alpha(_a);
        dtext_outline_ext(_toX + _dePadX, _deY + _dePadTop - 4, _to.effect, _deSep / _deSc, _deTxtW / _deSc, _deSc, c_white);   // -4: same ascender-leading nudge as the title
        // title text, centred. fa_middle centres the whole line box incl. the descender space, so the
        // visible glyphs land a bit low - nudge up by _tiNudge to optically centre them.
        var _tiNudge = 5;
        draw_set_halign(fa_center); draw_set_valign(fa_middle);
        dtext_outline(_toX + _to.tiW * 0.5, _tiY + _to.tiH * 0.5 - _tiNudge, _to.name, _tiSc, _to.good ? make_color_rgb(140, 240, 140) : make_color_rgb(250, 140, 100));
        draw_set_halign(fa_left); draw_set_valign(fa_top);
        // mini OUTCOME bubble to the right of the title: the drawn/stolen card, the granted
        // treasure, or a coin-flip label - so the result is visible without reading the log
        if (_to.outcome != undefined) {
            var _obX = _toX + _to.tiW + 8;
            if (_to.outcome.kind == "card") {
                card_draw(_to.outcome.cardId, _obX, _tiY - 10, _to.tiH + 20, _a);   // a small card thumbnail (fades with the toast)
            } else if (_to.outcome.kind == "text") {
                var _obW = max(_nsMinW, string_width(_to.outcome.text) * _tiSc + _tiPadX * 2);
                draw_nineslice_scaled(sprTextBox, _obX, _tiY, _obW, _to.tiH, _nsScale, c_white, _a);
                draw_set_alpha(_a);
                draw_set_halign(fa_center); draw_set_valign(fa_middle);
                dtext_outline(_obX + _obW * 0.5, _tiY + _to.tiH * 0.5 - _tiNudge, _to.outcome.text, _tiSc, c_white);
                draw_set_halign(fa_left); draw_set_valign(fa_top);
            }
        }
        draw_set_alpha(1);
    }
    draw_set_font(fntMaru); draw_set_color(c_white); draw_set_halign(fa_left); draw_set_valign(fa_top);
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
        dtext(_menuX + _menuW * 0.5, _menuY + 8, _pDef.name);
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
        dtext(_menuX + _menuW * 0.5, _menuY + 8, "Color Changing Posy");
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
    dtext(_menuX + _menuW * 0.5, _menuY + 8, "Free hazard - Select a space");
    draw_set_halign(fa_left);
    var _by = _menuY + 30;
    for (var _e = 0; _e < array_length(_fEmits); _e++) {
        var _sel = (_fEmits[_e] == freeBuild) ? "> " : "";
        if (ui_button(_menuX + 12, _by, _menuW - 24, 30, _sel + hazard_def_get(_fEmits[_e]).name)) freeBuild = _fEmits[_e];
        _by += 38;
    }
    if (ui_button(_menuX + 12, _by, _menuW - 24, 26, "Pass")) game_skip_free_hazard(game);
}

// ---------- generic CARD-TYPE picker (Reconstruction's new wall, future pellet/hazard selectors) ----------
if (game.pendingTypePick != undefined && ctl[game.pendingTypePick.playerIdx] == "human") {
    var _tp = game.pendingTypePick;
    var _tpNeed = variable_struct_exists(_tp, "need") ? _tp.need : 1;
    var _tpTitle = { reconstruct: "Change the wall into:", pellet: "Take a pellet" + (_tpNeed > 1 ? (" (" + string(_tpNeed) + " left):") : ":") };
    var _tpOpts = _tp.options;
    var _tpW = 260;
    var _tpH = 44 + array_length(_tpOpts) * 38;
    var _tpX = _guiW * 0.5 - _tpW * 0.5;
    var _tpY = _guiH * 0.5 - _tpH * 0.5;
    draw_set_alpha(0.8); draw_set_color(c_black); draw_rectangle(_tpX, _tpY, _tpX + _tpW, _tpY + _tpH, false); draw_set_alpha(1);
    draw_set_color(c_white);
    ui_block_rect(_tpX, _tpY, _tpW, _tpH);
    draw_set_halign(fa_center);
    dtext(_tpX + _tpW * 0.5, _tpY + 8, variable_struct_exists(_tpTitle, _tp.purpose) ? _tpTitle[$ _tp.purpose] : "Choose:");
    draw_set_halign(fa_left);
    var _tpBy = _tpY + 32;
    for (var _to = 0; _to < array_length(_tpOpts); _to++) {
        if (ui_button(_tpX + 12, _tpBy, _tpW - 24, 30, game_type_pick_label(_tp.purpose, _tpOpts[_to]))) game_type_pick_choose(game, _tpOpts[_to]);
        _tpBy += 38;
    }
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
        dtext(_menuX + _menuW * 0.5, _menuY + 8, "Ship Signal: choose the new TOP card");
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
    dtext(_menuX + _menuW * 0.5, _menuY + 8, gather_def_get(pendingCard.effectId).name);
    draw_set_halign(fa_left);
    var _by = _menuY + 30;

    if (pendingCard.stage == "trade") {
        var _tradeLoc = pendingCard.atHome ? { kind: "home" } : { kind: "space", lane: pendingCard.lane, idx: pendingCard.idx };
        var _tCounts = game_counts_struct(game, _p, _tradeLoc);
        var _tCols = variable_struct_get_names(_tCounts);
        var _have = array_length(game_tokens_at(game, _p, _tradeLoc));
        var _cost = pendingCard.purples * 5 + pendingCard.whites * 2;
        dtext(_menuX + 12, _by, "Cost: " + string(_cost) + " / " + string(_have) + " pikmin there");
        _by += 24;
        dtext(_menuX + 12, _by + 4, "Purple x" + string(pendingCard.purples));
        if (ui_button(_menuX + 130, _by, 26, 24, "-")) pendingCard.purples = max(0, pendingCard.purples - 1);
        if (ui_button(_menuX + 162, _by, 26, 24, "+")) { if (_cost + 5 <= _have) pendingCard.purples += 1; }
        _by += 30;
        dtext(_menuX + 12, _by + 4, "White x" + string(pendingCard.whites));
        if (ui_button(_menuX + 130, _by, 26, 24, "-")) pendingCard.whites = max(0, pendingCard.whites - 1);
        if (ui_button(_menuX + 162, _by, 26, 24, "+")) { if (_cost + 2 <= _have) pendingCard.whites += 1; }
        _by += 30;
        // payment picker: WHICH pikmin get fed to the trade. Leave it blank to pay
        // cheapest-first; otherwise the mix must add up to the cost exactly.
        if (!variable_struct_exists(pendingCard, "pay")) pendingCard.pay = {};
        draw_set_color(make_color_rgb(180, 190, 200));
        dtext(_menuX + 12, _by, "Pay with (blank = cheapest first):");
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
            dtext(_menuX + 30, _by + 2, _colId + ": " + string(_curP) + "/" + string(_availC));
            if (ui_button(_menuX + 158, _by, 26, 22, "-")) pendingCard.pay[$ _colId] = max(0, _curP - 1);
            if (ui_button(_menuX + 190, _by, 26, 22, "+")) pendingCard.pay[$ _colId] = min(_availC, _curP + 1);
            _by += 26;
        }
        _by += 6;
        var _payOk = (_paySum == 0 || _paySum == _cost);
        if (!_payOk) {
            draw_set_color(make_color_rgb(255, 140, 120));
            dtext(_menuX + 12, _by + 6, "payment " + string(_paySum) + "/" + string(_cost) + " - match the cost");
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
    draw_set_font(fntMaru);
    draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(255, 224, 120));
    draw_text_transformed(_guiW * 0.5, _pdY - 60, "HAND LIMIT", 1.6 * UI_TS, 1.6 * UI_TS, 0);
    draw_set_font(fntMaru);
    draw_set_color(c_white);
    dtext(_guiW * 0.5, _pdY - 26, "Click " + string(game.pendingDiscard.need) + " card" + ((game.pendingDiscard.need > 1) ? "s" : "") + " to discard");
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

// ---------- Spy: a one-time READ-ONLY peek at the opponent's hand (Confirm to dismiss) ----------
if (game.pendingSpy != undefined && ctl[game.pendingSpy.viewer] == "human") {
    var _syO = 1 - game.pendingSpy.viewer;           // the opponent whose hand we're peeking
    var _syPl = game.players[_syO];
    var _syEntries = [];
    for (var _i = 0; _i < array_length(_syPl.hand); _i++) array_push(_syEntries, _syPl.hand[_i]);
    for (var _i = 0; _i < array_length(_syPl.pellets); _i++) array_push(_syEntries, _syPl.pellets[_i]);
    var _syN = array_length(_syEntries);
    var _syCardH = 170, _syCardW = _syCardH * 0.714;
    var _syStep = (max(1, _syN) * (_syCardW + 10) <= _guiW - 120) ? (_syCardW + 10) : max(40, (_guiW - 120 - _syCardW) / max(1, _syN - 1));
    var _syRowW = (_syN > 0) ? (_syCardW + _syStep * (_syN - 1)) : 0;
    var _syX0 = (_guiW - _syRowW) * 0.5;
    var _syY = _guiH * 0.5 - _syCardH * 0.5;
    draw_set_alpha(0.62); draw_set_color(c_black);
    draw_rectangle(0, _syY - 70, _guiW, _syY + _syCardH + 80, false);
    draw_set_alpha(1);
    draw_set_font(fntMaru); draw_set_halign(fa_center);
    draw_set_color(make_color_rgb(120, 220, 235));
    draw_text_transformed(_guiW * 0.5, _syY - 60, "SPY - P" + string(_syO + 1) + "'S HAND", 1.6 * UI_TS, 1.6 * UI_TS, 0);
    draw_set_color(c_white);
    dtext(_guiW * 0.5, _syY - 26, (_syN > 0) ? "A one-time look. Confirm to dismiss." : "Their hand is empty. Confirm to dismiss.");
    draw_set_halign(fa_left);
    ui_block_rect(0, _syY - 70, _guiW, _syCardH + 170);
    for (var _i = 0; _i < _syN; _i++) card_draw(_syEntries[_i], _syX0 + _i * _syStep, _syY, _syCardH);
    if (ui_button(_guiW * 0.5 - 80, _syY + _syCardH + 18, 160, 40, "Confirm", fntMaru)) game.pendingSpy = undefined;
}

// ---------- Reveal phase B: fan the chosen pile's cards; click one to make it the new TOP ----------
if (game.pendingReveal != undefined && game.pendingReveal.lane >= 0 && _revealHuman) {
    var _rvT = game_treasure_at(game, game.pendingReveal.lane, game.pendingReveal.idx);
    if (_rvT == undefined) {
        game.pendingReveal = undefined;   // pile vanished (shouldn't happen mid-choice) - bail
    } else {
        var _rvN = array_length(_rvT.cards);
        var _rvCardH = 170, _rvCardW = _rvCardH * 0.714;
        var _rvStep = (_rvN * (_rvCardW + 10) <= _guiW - 120) ? (_rvCardW + 10) : max(40, (_guiW - 120 - _rvCardW) / max(1, _rvN - 1));
        var _rvRowW = _rvCardW + _rvStep * (_rvN - 1);
        var _rvX0 = (_guiW - _rvRowW) * 0.5;
        var _rvY = _guiH * 0.5 - _rvCardH * 0.5;
        draw_set_alpha(0.62); draw_set_color(c_black);
        draw_rectangle(0, _rvY - 70, _guiW, _rvY + _rvCardH + 30, false);
        draw_set_alpha(1);
        draw_set_font(fntMaru); draw_set_halign(fa_center);
        draw_set_color(make_color_rgb(255, 224, 120));
        draw_text_transformed(_guiW * 0.5, _rvY - 60, "REVEAL - PICK THE NEW TOP CARD", 1.6 * UI_TS, 1.6 * UI_TS, 0);
        draw_set_color(c_white);
        dtext(_guiW * 0.5, _rvY - 26, "The current top is at the right. Click the card to surface.");
        draw_set_halign(fa_left);
        ui_block_rect(0, _rvY - 70, _guiW, _rvCardH + 100);
        var _rvHov = -1;
        for (var _i = 0; _i < _rvN; _i++) {
            var _cx = _rvX0 + _i * _rvStep;
            var _cw = (_i == _rvN - 1) ? _rvCardW : _rvStep;
            if (_mgx >= _cx && _mgx < _cx + _cw && _mgy >= _rvY - 16 && _mgy < _rvY + _rvCardH) _rvHov = _i;
        }
        for (var _i = 0; _i < _rvN; _i++) {
            if (_i == _rvHov) continue;
            card_draw(_rvT.cards[_i], _rvX0 + _i * _rvStep, _rvY, _rvCardH);
        }
        if (_rvHov != -1) {
            var _hcx = _rvX0 + _rvHov * _rvStep;
            card_draw(_rvT.cards[_rvHov], _hcx, _rvY - 14, _rvCardH);
            draw_set_color(make_color_rgb(255, 224, 120));
            draw_rectangle(_hcx - 2, _rvY - 16, _hcx + _rvCardW + 2, _rvY - 14 + _rvCardH + 2, true);
            draw_set_color(c_white);
            if (mouse_check_button_pressed(mb_left)) game_reveal_pick_card(game, _rvHov);
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
        dtext(16, _dbgY + _laneIdx * 20, _lineText);
    }
    // F-key / shortcut reference (only while the Tab debug overlay is up)
    var _keys = [
        "F1  cycle P2 brain (human / v1 / v2 / v3)",
        "F2  return to menu",
        "F3  sim diagnostics - this board",
        "F4  policy tournament - this board",
        "F5  probe: RANDOM seed - this board",
        "F6  lane audit - this board",
        "F7  probe: FIXED seed - this board",
        "F8  tournament batch (5 boards)",
        "F9  scenario tests (fast logic checks)",
        "F12 tournament: ALL 16 boards (long AFK run)",
        "F11 fullscreen    Tab debug    V collection    Space orbit"
    ];
    var _kx = 8, _ky = _barH + 10;
    draw_set_alpha(0.5); draw_set_color(c_black);
    draw_rectangle(_kx - 4, _ky - 4, _kx + 372, _ky + array_length(_keys) * 18 + 4, false);
    draw_set_alpha(1); draw_set_color(make_color_rgb(200, 220, 240));
    for (var _ki = 0; _ki < array_length(_keys); _ki++) dtext(_kx, _ky + _ki * 18, _keys[_ki]);
    draw_set_color(c_white);
}

// ---------- collected-treasure side panels (V toggles) ----------
if (showCollection) {
    var _mgxC = device_mouse_x_to_gui(0);
    var _mgyC = device_mouse_y_to_gui(0);
    var _panW = 336;
    var _panY = 40;
    var _panH = _guiH - 84;
    var _hovL = draw_collection_panel(game, 0, 8, _panY, _panW, _panH, _mgxC, _mgyC, (ctl[0] != "human") ? ctl[0] : "");
    var _hovR = draw_collection_panel(game, 1, _guiW - 8 - _panW, _panY, _panW, _panH, _mgxC, _mgyC, (ctl[1] != "human") ? ctl[1] : "");
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
        draw_set_font(fntMaru);
        draw_set_halign(fa_center);
        draw_set_valign(fa_top);
        draw_set_color(make_color_rgb(255, 224, 120));
        dtext(_guiW * 0.5, _ry0 - 34, _zoomCaption);
        draw_set_font(fntMaru);
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
            dtext(_cx + _pileW * 0.5, _ry0 + _pileH + 4, string(_tdef.value) + "p" + (_isTop ? " (top)" : ""));
            // series tag so buried set pieces are easy to spot
            if (_tdef.effectType == "Set") {
                draw_set_color(make_color_rgb(150, 200, 255));
                dtext(_cx + _pileW * 0.5, _ry0 + _pileH + 20, _tdef.effect);
            } else {
                draw_set_color(make_color_rgb(150, 155, 160));
                dtext(_cx + _pileW * 0.5, _ry0 + _pileH + 20, "loose");
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
                dtext(_zX + _zW * 0.5, _zY + _zH + 8, _zoomCaption);
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
            draw_set_font(fntMaru);
            draw_set_halign(fa_center);
            draw_set_color(make_color_rgb(255, 236, 170));
            dtext_ext(_zX2 + _zW2 * 0.5, _zY2 + 20, (_zoomTitle != "") ? _zoomTitle : _zoomAlias, 26, _zW2 - 28);
            draw_set_halign(fa_left);
            draw_set_font(fntMaru);
            draw_set_color(make_color_rgb(214, 220, 230));
            dtext_ext(_zX2 + 18, _zY2 + 96, (_zoomText != "") ? _zoomText : "(no card art exported)", 20, _zW2 - 36);
            draw_set_color(make_color_rgb(150, 160, 175));
            dtext(_zX2 + 18, _zY2 + _zH2 - 26, "art: CARD" + _zoomAlias + ".png (missing)");
            draw_set_color(c_white);
        }
    }

    // discard-pile list: Alt-hover the discard decal to read the pile (y = board midpoint, matching
    // the Draw_0 deck placement - 0 would miss it on a home-anchored solo board)
    var _ddBnd = board_bounds_y(board, game.solo);
    var _ddScr = world_to_gui(_vp, 380, (_ddBnd.minY + _ddBnd.maxY) * 0.5, 1.63);
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
        dtext(_dlX + 10, _dlY + 8, "DISCARD (" + string(_discNn) + ") - Newest first");
        draw_set_color(c_white);
        for (var _dli = 0; _dli < _dlShow; _dli++) {
            dtext(_dlX + 10, _dlY + 30 + _dli * 18, gather_def_get(_discList[_discNn - 1 - _dli]).name);
        }
        if (_discNn > _dlShow) dtext(_dlX + 10, _dlY + 30 + _dlShow * 18, "...and " + string(_discNn - _dlShow) + " more");
    }
}

// ---------- board clicks (only when the HUD didn't take the mouse) ----------
// boss bounty: while the queue is live, a space click IS the placement
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && !_locked && _freeHuman && hoverKind == "space" && freeBuild != "") {
    game_place_free_hazard(game, hoverLane, hoverIdx, freeBuild);
}
// day-track SWAP choice: click one of your highlighted from-type tiles to flip it (validated
// inside game_day_swap_choose, so clicking anywhere else is a harmless no-op). Runs despite
// _locked since the pending swap is what put us in the locked/modal state.
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && _daySwapHuman && hoverKind == "space") {
    game_day_swap_choose(game, hoverLane, hoverIdx);
}
// day-track POD / STORM choice: click a highlighted space to place (validated inside).
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && _dayPlaceHuman && hoverKind == "space") {
    game_day_place_choose(game, hoverLane, hoverIdx);
}
// adventure EVENT space pick: click a highlighted space to resolve (validated inside).
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && _eventHuman && hoverKind == "space") {
    game_event_choose(game, hoverLane, hoverIdx);
}
// adventure LOSE-pikmin pick: click a space with your pikmin, or your Onion/home, to shed one.
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && _loseHuman) {
    if (hoverKind == "space") game_lose_choose(game, { kind: "space", lane: hoverLane, idx: hoverIdx });
    else if (hoverKind == "home" && hoverIdx == game.pendingLose.playerIdx) game_lose_choose(game, { kind: "home" });
}
// Reveal phase A: click a highlighted treasure pile to reorder it (card pick happens in the modal).
if (mouse_check_button_pressed(mb_left) && !global.uiMouseConsumed && _revealHuman && game.pendingReveal.lane < 0 && hoverKind == "space") {
    game_reveal_pick_pile(game, hoverLane, hoverIdx);
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
            // error tone only when pikmin WERE selected but none could reach (not on an empty pick)
            if (!game_order_move(game, selSrc, _spaceLoc, selCounts) && array_length(variable_struct_get_names(selCounts)) > 0) sfx("sfxError");
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
            var _sendCnt = game_counts_struct(game, _p, _src);
            if (!game_order_move(game, _src, _dst, _sendCnt) && array_length(variable_struct_get_names(_sendCnt)) > 0) sfx("sfxError");
            selSrc = undefined;
        }
    }
}

// ---------- DEV: force an adventure board's outcome ----------
// Skips playing the map so the end-of-mission sequences can be iterated on (flash -> pop graph ->
// deck build -> log -> hub). Both buttons drive the NORMAL detection in Step_0 rather than jumping
// to the banner themselves, so what you see is the real path, not a shortcut past it.
// Bottom-RIGHT corner, stacked; gated on devTools (Options > Interface) + being in an adventure run.
if (global.settings.devTools && advRun != undefined && advBanner == "" && advResults == ""
    && game != undefined && game.phase != "gameover") {
    var _dvW = 168, _dvX = _guiW - _dvW - 14;
    // CLEAR: empty the board so Step_0's clear condition ("no treasures, nothing departing, nothing
    // moving") fires on its own. Removes the piles rather than banking them, so the results screen
    // honestly shows the score WITHOUT credit for them - fine for checking text, but don't read the
    // pop graph or day economy off a skipped board.
    if (ui_button(_dvX, _guiH - 84, _dvW, 30, "DEV: Clear Board", fntMaru)) {
        game.treasures = [];
        game.departing = [];
    }
    // FAIL: jump to the last day and end it. Resolving the limit the SAME way game_advance_day does
    // (adventure's shared dayLimit wins, else the board's day-track days, else the global rule) so
    // this can't drift out of sync with it; advancing from there rolls dayNumber past the limit and
    // sets phase "gameover", which Step_0 reads as the run FAIL once the board settles.
    if (ui_button(_dvX, _guiH - 48, _dvW, 30, "DEV: Fail (out of days)", fntMaru)) {
        var _dvLimit = variable_struct_exists(game, "dayLimit") ? game.dayLimit
                     : (variable_struct_exists(game, "dayTrackDef") ? game.dayTrackDef.days : global.rules.days);
        game.dayNumber = _dvLimit;
        game.dayTrack  = game.dayTrackLength;
        game_advance_day(game);
    }
}

// ---------- tutorial instruction banner (nine-sliced Pikmin text box) ----------
// DRAWN LAST ON PURPOSE (after the hand, the toasts and the rest of the HUD) so the bubble sits on
// top of everything - the intro-step layout deliberately overlaps the hand, and anything drawn after
// this would punch through it. Only the day-transition full-screen flash below is allowed to cover
// it. If you add new HUD drawing, put it ABOVE this block, not below.
// Drawn via draw_nineslice_scaled at a reduced _nsScale (like the treasure-power TOASTS) rather than
// a full-size stretch: sprTextBox's nine-slice CORNERS are big (61/71px), so at full scale the frame
// itself sets a chunky floor on how small the bubble can get. Scaling the whole nine-slice down
// shrinks the corners too, letting the bubble hug its text; its HEIGHT tracks the wrapped line count.
// Text streams in letter-by-letter (tutorial.revealChars, advanced in tutorial_tick, Create_0) with
// a talk blip every third character (game_sfx) - "the ship sending a message".
var _tStep = (tutorial != undefined) ? tutorial_step() : undefined;
if (_tStep != undefined) {
    var _isIntro = (_tStep.kind == "intro");   // intro = read + Continue; action = auto-advance
    // TUNING KNOBS: frame insets, line spacing, TEXT scale (leave at 1.45 - see above), nine-slice
    // draw scale, and a min height so the corners don't compress on a one-line message. Insets are
    // the original values scaled by ~_nsScale, since the frame they clear is now that much smaller.
    var _padX = 32, _padTop = 25, _padBot = 34, _sep = 30, _dsc = 1.7 * UI_TS, _nsScale = 0.62;
    var _cfSize = 40, _cfGap = 12;   // confirm-disc diameter + its gap from the text column
    // TWO HOMES, chosen by whether this step carries a Continue disc:
    //  - INTRO (has the disc): wide + centred at the BOTTOM of the screen, deliberately sitting OVER
    //    the hand. The player is only reading and acknowledging here, so covering the cards is free.
    //  - ACTION (no disc): the message parks at the TOP, squeezed between the left phase-control
    //    column (the Roll button occupies x 12..232) and the right log/chat panel (_logX), so the
    //    board and both HUD columns stay clickable and play continues unimpeded.
    var _tbW, _tbX;
    if (_isIntro) {
        _tbW = min(980, _guiW - 220);
        _tbX = (_guiW - _tbW) * 0.5;
    } else {
        var _tbLeft = 244;                                  // clear of the left phase-control column
        _tbW = max(320, (_logX - 12) - _tbLeft);            // ...and stop short of the log/chat panel
        _tbX = _tbLeft;
    }
    draw_set_font(fntDialog);
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    // the disc sits to the RIGHT of the text, so it costs WIDTH, not height - the bubble's height
    // tracks the wrapped text alone (it only floors at the disc's own size, which can bite on a
    // very short one-line intro where the disc is genuinely taller than the text)
    var _txtW = _tbW - _padX * 2 - (_isIntro ? _cfSize + _cfGap : 0);
    var _txtH = string_height_ext(_tStep.text, _sep / _dsc, _txtW / _dsc) * _dsc;   // full-text height, so the box doesn't resize mid-stream
    var _tbContentH = _isIntro ? max(_txtH, _cfSize) : _txtH;   // NB: not _contentH - the log panel already owns that name in this event
    var _tbH  = max(72, _padTop + _tbContentH + _padBot);   // min = ~_nsScale * the sprite's 108px nine-slice floor
    // Y: intro sits flush to the bottom (over the hand); action pins to the top. X/width were
    // already chosen per-mode above.
    var _tbY = _isIntro ? (_guiH - _tbH - 12) : 40;
    draw_nineslice_scaled(sprTextBox, _tbX, _tbY, _tbW, _tbH, _nsScale, c_white, 1);
    draw_set_color(c_white);   // white text - the bubble is mostly transparent
    var _tShown = string_copy(_tStep.text, 1, floor(tutorial.revealChars));
    draw_text_ext_transformed(_tbX + _padX, _tbY + _padTop, _tShown, _sep / _dsc, _txtW / _dsc, _dsc, _dsc, 0);
    draw_set_color(c_white);
    // wordless green confirm disc (hover lightens, hold darkens, fires on release) instead of a
    // labelled "Continue" - the message is the content, the button just acknowledges it.
    // Bottom-right of the content block: right of the text column, bottom-aligned with the text.
    // DOUBLE DUTY (same contract as the adventure log screen): while the text is still streaming the
    // disc dumps the rest instantly; only once fully revealed does it actually advance. Nobody
    // should have to sit through the crawl to re-read something they've already got.
    if (_isIntro && ui_icon_button(sprButtonConfirm, _tbX + _tbW - _padX - _cfSize, _tbY + _padTop + _tbContentH - _cfSize, _cfSize, "tutContinue")) {
        if (tutorial.revealChars < string_length(_tStep.text)) {
            tutorial.revealChars = string_length(_tStep.text);   // skip to the end of this message
        } else {
            tutorial_advance();   // steps within a scene, then scene-to-scene, then ends the tutorial
            if (tutorial == undefined) { return_to_menu(); exit; }   // Continue on the very last text box -> back to the menu
        }
    }
    ui_block_rect(_tbX, _tbY, _tbW, _tbH);
    draw_set_font(fntMaru);   // restore the body UI font - fntDialog would otherwise leak into later buttons/text
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
    draw_set_font(fntPikmin);        // the day-transition banner keeps the stylised Pikmin font
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
    draw_set_font(fntMaru);
}
