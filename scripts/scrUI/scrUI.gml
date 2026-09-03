// Immediate-mode HUD helpers. Use only inside the Draw GUI event.
// Buttons and panels mark the mouse as "consumed" so clicks on the HUD never
// fall through to board selection.

// Font compensation: fntPikmin is authored at 36pt for crisp glyphs, but the GUI
// layout was built for a 12pt visual size. GUI-space text draws through dtext/
// dtext_ext at this scale so it stays the SAME on-screen size while rendering from
// the high-res atlas (no upscaling blur). Billboard/HUD text is unaffected - it
// self-normalizes via 16/string_height. Change only UI_TS if the font size changes.
#macro UI_TS (12 / 36)

/// GUI-space text at the compensated scale (drop-in replacement for draw_text).
function dtext(_x, _y, _str) {
    draw_text_transformed(_x, _y, _str, UI_TS, UI_TS, 0);
}

/// Draw one LOG row with inline colour (fntMaru, UI_TS scale). _cat: "chat" = cyan "name:" +
/// white message (first row of a chat line); "chatcont" = plain white (wrapped chat continuation);
/// "game" = muted-yellow base with highlighted chips for P1 / P2 (muted blue / red) and [Good] /
/// [Bad] (bright green / red). Chip text stays white.
function log_draw_line(_x, _y, _row, _cat) {
    draw_set_font(fntMaru);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
    var _rowH = string_height("Ag") * UI_TS;
    if (_cat == "chatcont") {
        draw_set_color(c_white);
        draw_text_transformed(_x, _y, _row, UI_TS, UI_TS, 0);
        return;
    }
    if (_cat == "chat") {
        var _cp = string_pos(":", _row);
        if (_cp > 0) {
            var _nm = string_copy(_row, 1, _cp);
            draw_set_color(make_color_rgb(80, 220, 235));   // cyan sender name
            draw_text_transformed(_x, _y, _nm, UI_TS, UI_TS, 0);
            draw_set_color(c_white);
            draw_text_transformed(_x + string_width(_nm) * UI_TS, _y, string_delete(_row, 1, _cp), UI_TS, UI_TS, 0);
        } else {
            draw_set_color(c_white);
            draw_text_transformed(_x, _y, _row, UI_TS, UI_TS, 0);
        }
        draw_set_color(c_white);
        return;
    }
    // treasure-power lines ("power", flagged per-entry so wrapped rows match) get a brighter base
    var _base = (_cat == "power") ? make_color_rgb(240, 230, 182) : make_color_rgb(206, 192, 116);
    var _cursor = _x, _seg = "", _i = 1;
    var _len = string_length(_row);
    while (_i <= _len) {
        // card-name span (wrapped in chr(2) markers by the logger) -> grey chip, white name
        if (string_char_at(_row, _i) == chr(2)) {
            var _j = _i + 1;
            while (_j <= _len && string_char_at(_row, _j) != chr(2)) _j += 1;
            var _nm = string_copy(_row, _i + 1, _j - _i - 1);
            if (_seg != "") { draw_set_color(_base); draw_text_transformed(_cursor, _y, _seg, UI_TS, UI_TS, 0); _cursor += string_width(_seg) * UI_TS; _seg = ""; }
            var _nw = string_width(_nm) * UI_TS;
            draw_set_color(make_color_rgb(72, 72, 80)); draw_rectangle(_cursor - 1, _y, _cursor + _nw + 1, _y + _rowH, false);
            draw_set_color(c_white); draw_text_transformed(_cursor, _y, _nm, UI_TS, UI_TS, 0);
            _cursor += _nw;
            _i = _j + 1;
            continue;
        }
        // token -> coloured TEXT (no coloured background). [Good]/[Bad] keep a neutral GREY chip so
        // the tag reads as a badge, but the meaning is in the text colour. P1/P2 are just tinted text.
        var _ts = "", _tcol = c_white, _chip = false;
        if      (string_copy(_row, _i, 6) == "[Good]") { _ts = "[Good]"; _tcol = make_color_rgb(0, 255, 0);   _chip = true; }
        else if (string_copy(_row, _i, 5) == "[Bad]")  { _ts = "[Bad]";  _tcol = make_color_rgb(255, 70, 70); _chip = true; }
        else if (string_copy(_row, _i, 2) == "P1")     { _ts = "P1";     _tcol = make_color_rgb(110, 150, 225); }
        else if (string_copy(_row, _i, 2) == "P2")     { _ts = "P2";     _tcol = make_color_rgb(225, 115, 115); }
        if (_ts != "") {
            if (_seg != "") { draw_set_color(_base); draw_text_transformed(_cursor, _y, _seg, UI_TS, UI_TS, 0); _cursor += string_width(_seg) * UI_TS; _seg = ""; }
            var _tw = string_width(_ts) * UI_TS;
            if (_chip) { draw_set_color(make_color_rgb(72, 72, 80)); draw_rectangle(_cursor - 1, _y, _cursor + _tw + 1, _y + _rowH, false); }
            draw_set_color(_tcol);
            draw_text_transformed(_cursor, _y, _ts, UI_TS, UI_TS, 0);
            _cursor += _tw;
            _i += string_length(_ts);
        } else {
            _seg += string_char_at(_row, _i);
            _i += 1;
        }
    }
    if (_seg != "") { draw_set_color(_base); draw_text_transformed(_cursor, _y, _seg, UI_TS, UI_TS, 0); }
    draw_set_color(c_white);
}

/// GUI-space wrapped text at the compensated scale (drop-in for draw_text_ext).
/// _sep (line spacing) and _w (wrap width) are given in on-screen pixels.
function dtext_ext(_x, _y, _str, _sep, _w) {
    draw_text_ext_transformed(_x, _y, _str, _sep / UI_TS, _w / UI_TS, UI_TS, UI_TS, 0);
}

/// On-screen width of GUI-space text drawn via dtext (string_width is in atlas px).
function dtext_width(_str) {
    return string_width(_str) * UI_TS;
}

/// On-screen height of GUI-space text drawn via dtext (string_height is in atlas px).
function dtext_height(_str) {
    return string_height(_str) * UI_TS;
}

/// dtext with a dark semi-transparent backing strip, so a bare HUD hint stays legible over the
/// busy 3D board (buttons already have a background; these loose lines did not). _col = text colour.
/// Draw a nine-slice sprite whose CORNERS are scaled by _scale too. draw_sprite_stretched keeps the
/// nine-slice corners at native pixel size (chunky/soft when the source is big); wrapping it in a
/// world-matrix scale shrinks the ENTIRE frame - corners included - so a big soft bubble renders small
/// and crisp. _x,_y,_w,_h are the ON-SCREEN rect. GUI-event safe (matrix restored after).
function draw_nineslice_scaled(_spr, _x, _y, _w, _h, _scale, _col, _alpha) {
    matrix_set(matrix_world, matrix_build(_x, _y, 0, 0, 0, 0, _scale, _scale, 1));
    draw_sprite_stretched_ext(_spr, 0, 0, 0, _w / _scale, _h / _scale, _col, _alpha);
    matrix_set(matrix_world, matrix_build_identity());
}

/// Scaled text with a dark 1px outline (8 offset passes) for readability over busy/transparent art.
/// Uses the current font + alpha; sets colour internally. _sc = the draw_text_transformed scale.
/// Can this hand entry be played RIGHT NOW? Gates the hand's dim + hover-zoom so a card
/// only lights up when it's actually usable: the viewer's own actionable turn (_interactive),
/// AND the right phase for that card - gather cards in MOVE, pellets in ORDERS, and Color
/// Changing Posy uniquely in EITHER move OR orders (it can play as a gather or as a pellet).
function hand_card_playable(_entry, _phase, _interactive) {
    if (!_interactive) return false;   // opponent's turn / resolving / locked: whole hand is dead
    if (_entry.kind == "gather") {
        if (_entry.cardId == "colorchangingposy") return (_phase == "move" || _phase == "orders");
        return (_phase == "move");
    }
    return (_phase == "orders");   // pellets
}

/// Map a day-track space event {ev, ...} to its DAY* symbol sprite. Blank turns show
/// DAYNothing; SPAWN = DAYRespawn; POD{n} = DAYSpawn_n; SWAP{from,to,all} builds the
/// "DAY<From>To<To>[ALL]" name (e.g. DAYFireToEnemy, DAYWaterToFireALL). Falls back to
/// DAYNothing for anything unmapped so the strip always renders something.
function day_event_sprite(_ev) {
    var _name;
    switch (_ev.ev) {
        case "spawn":   _name = "DAYRespawn"; break;
        case "pod":     _name = "DAYSpawn_" + string(clamp(variable_struct_exists(_ev, "n") ? _ev.n : 3, 2, 5)); break;
        case "storm":   _name = "DAYHazard"; break;
        case "roll":    _name = "DAYRoll"; break;
        case "draw":    _name = "DAYGather"; break;
        case "raw":     _name = "DAYRaw"; break;
        case "pellet":  _name = "DAYPellets"; break;
        case "flarlic": _name = "DAYFlarlic"; break;
        case "swap":
            // "DAY<From>To<To>" with an optional ALL suffix. Some swaps only ship as the ALL
            // art (the total-conversion board), so try both variants regardless of the flag.
            var _cf = string_upper(string_char_at(_ev.from, 1)) + string_delete(_ev.from, 1, 1);
            var _ct = string_upper(string_char_at(_ev.to, 1)) + string_delete(_ev.to, 1, 1);
            var _base = "DAY" + _cf + "To" + _ct;
            var _isAll = (variable_struct_exists(_ev, "all") && _ev.all);
            var _first = _isAll ? (_base + "ALL") : _base;
            var _second = _isAll ? _base : (_base + "ALL");
            if (asset_get_index(_first) != -1) return asset_get_index(_first);
            if (asset_get_index(_second) != -1) return asset_get_index(_second);
            _name = "DAYNothing";
            break;
        default:        _name = "DAYNothing"; break;
    }
    var _spr = asset_get_index(_name);
    return (_spr != -1) ? _spr : asset_get_index("DAYNothing");
}

/// Draw a small swatch for a board TILE TYPE ("empty"/"plain"/"enemy"/"treasure" or a hazard
/// element) at (_x,_y), size _sz: a colour block + the hazard's element decal + a name label.
/// Used by the day-swap prompt to show the FROM and TO tiles.
function tile_swatch_draw(_x, _y, _sz, _type) {
    var _col;
    switch (_type) {
        case "empty": case "plain": _col = make_color_rgb(104, 142, 88); break;
        case "enemy":    _col = make_color_rgb(150, 150, 150); break;
        case "treasure": _col = make_color_rgb(232, 210, 66); break;
        case "fire":     _col = make_color_rgb(210, 70, 50);  break;
        case "water":    _col = make_color_rgb(70, 120, 200); break;
        case "height":   _col = make_color_rgb(226, 205, 170); break;
        case "ice":      _col = make_color_rgb(120, 220, 230); break;
        case "poison":   _col = make_color_rgb(150, 110, 190); break;
        case "chasm":    _col = make_color_rgb(120, 80, 40);  break;
        default:         _col = make_color_rgb(90, 90, 90);   break;
    }
    draw_set_alpha(1);
    draw_set_color(_col);
    draw_rectangle(_x, _y, _x + _sz, _y + _sz, false);
    var _spr = element_sprite(_type);   // hazards have an element decal; other kinds return -1
    if (_spr != -1) {
        var _s = _sz / max(sprite_get_width(_spr), sprite_get_height(_spr));
        draw_sprite_ext(_spr, 0, _x + _sz * 0.5 - (sprite_get_width(_spr) * 0.5 - sprite_get_xoffset(_spr)) * _s,
            _y + _sz * 0.5 - (sprite_get_height(_spr) * 0.5 - sprite_get_yoffset(_spr)) * _s, _s, _s, 0, c_white, 1);
    }
    draw_set_color(c_black);
    draw_rectangle(_x, _y, _x + _sz, _y + _sz, true);
    draw_set_color(c_white);
    draw_set_halign(fa_center); draw_set_font(fntMaru);
    dtext_outline(_x + _sz * 0.5, _y + _sz + 2, string_upper(string_char_at(_type, 1)) + string_delete(_type, 1, 1), 0.5, c_white);
    draw_set_halign(fa_left);
}

function dtext_outline(_x, _y, _str, _sc, _col, _oCol = make_color_rgb(18, 14, 10)) {
    var _o = max(2, round(_sc * 2.5));
    draw_set_color(_oCol);
    for (var _dx = -1; _dx <= 1; _dx++) for (var _dy = -1; _dy <= 1; _dy++)
        if (_dx != 0 || _dy != 0) draw_text_transformed(_x + _dx * _o, _y + _dy * _o, _str, _sc, _sc, 0);
    draw_set_color(_col);
    draw_text_transformed(_x, _y, _str, _sc, _sc, 0);
}
/// Wrapped variant of dtext_outline (_sep line-spacing + _w wrap width in FONT units, like the raw call).
function dtext_outline_ext(_x, _y, _str, _sep, _w, _sc, _col, _oCol = make_color_rgb(18, 14, 10)) {
    var _o = max(2, round(_sc * 2.5));
    draw_set_color(_oCol);
    for (var _dx = -1; _dx <= 1; _dx++) for (var _dy = -1; _dy <= 1; _dy++)
        if (_dx != 0 || _dy != 0) draw_text_ext_transformed(_x + _dx * _o, _y + _dy * _o, _str, _sep, _w, _sc, _sc, 0);
    draw_set_color(_col);
    draw_text_ext_transformed(_x, _y, _str, _sep, _w, _sc, _sc, 0);
}

function dtext_bg(_x, _y, _str, _col = c_white) {
    var _w = dtext_width(_str), _h = dtext_height(_str), _pad = 5;
    draw_set_alpha(0.6);
    draw_set_color(make_color_rgb(14, 18, 24));
    draw_rectangle(_x - _pad, _y - 2, _x + _w + _pad, _y + _h + 2, false);
    draw_set_alpha(1);
    draw_set_color(_col);
    dtext(_x, _y, _str);
    draw_set_color(c_white);
}

/// On-screen height of wrapped GUI-space text drawn via dtext_ext (_sep, _w in on-screen px).
function dtext_height_ext(_str, _sep, _w) {
    return string_height_ext(_str, _sep / UI_TS, _w / UI_TS) * UI_TS;
}

/// Greedily word-wrap _str into an array of visual lines, each <= _w on-screen px at the
/// dtext scale (wrapping on spaces; honours embedded newlines). The intended font must
/// already be set. Always returns at least one line. Lets us lay out multi-line log
/// entries row-by-row instead of as atomic blocks.
function dtext_wrap(_str, _w) {
    var _lines = [];
    var _cur = "";
    var _word = "";
    var _n = string_length(_str);
    for (var _i = 1; _i <= _n + 1; _i++) {
        var _ch = (_i <= _n) ? string_char_at(_str, _i) : " "; // trailing sentinel flushes the last word
        if (_ch == " " || _ch == "\n" || _ch == "#") {
            if (_word != "") {
                var _try = (_cur == "") ? _word : (_cur + " " + _word);
                if (_cur != "" && dtext_width(_try) > _w) {
                    array_push(_lines, _cur);
                    _cur = _word;
                } else {
                    _cur = _try;
                }
                _word = "";
            }
            if (_ch == "\n" || _ch == "#") { array_push(_lines, _cur); _cur = ""; }
        } else {
            _word += _ch;
        }
    }
    if (_cur != "") array_push(_lines, _cur);
    if (array_length(_lines) == 0) array_push(_lines, "");
    return _lines;
}

function ui_frame_begin() {
    global.uiMouseConsumed = false;
}

function ui_mouse_in(_x, _y, _w, _h) {
    var _mx = device_mouse_x_to_gui(0);
    var _my = device_mouse_y_to_gui(0);
    return (_mx >= _x && _mx < _x + _w && _my >= _y && _my < _y + _h);
}

/// Panels call this so clicks on their background don't reach the board.
function ui_block_rect(_x, _y, _w, _h) {
    if (ui_mouse_in(_x, _y, _w, _h)) global.uiMouseConsumed = true;
}

// _font: optional. undefined = draw the label in whatever font the caller has set (default
// behaviour, unchanged). Pass fntPikmin (or any font) to render the label in it; the font is
// saved/restored so callers aren't affected. The label auto-fits inside the button either way.
/// Scroll helpers for a vertically-scrolling panel of fixed-position rows (e.g. the Options screen
/// body). Plain top-level functions, NOT closures - GML function literals defined inline don't
/// capture enclosing `var` locals (they resolve through instance scope instead), so a closure that
/// reads an outer local throws "not set before reading it" the first time it runs. Pass the scroll
/// offset / viewport bounds explicitly instead.
function ui_scroll_y(_baseY, _scroll) { return _baseY - _scroll; }
function ui_row_visible(_baseY, _h, _scroll, _viewTop, _viewBot) {
    var _y = _baseY - _scroll;
    return (_y + _h > _viewTop) && (_y < _viewBot);
}

function ui_button(_x, _y, _w, _h, _label, _font = undefined) {
    var _hover = ui_mouse_in(_x, _y, _w, _h);
    if (_hover) global.uiMouseConsumed = true;
    draw_set_alpha(_hover ? 0.95 : 0.75);
    draw_set_color(_hover ? make_color_rgb(74, 96, 132) : make_color_rgb(42, 52, 74));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false);
    draw_set_alpha(1);
    draw_set_color(make_color_rgb(180, 195, 220));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);
    draw_set_color(c_white);
    var _prevFont = draw_get_font();
    if (_font != undefined) draw_set_font(_font);
    draw_set_halign(fa_center);
    draw_set_valign(fa_middle);
    // draw the label at a comfortable target size (a touch above body text), and ONLY
    // shrink below that if it would overflow the button - so labels don't balloon to fill
    // big buttons. The font is ~36pt, so the cap keeps it sane; UI_TS is the body scale.
    var _target = 1.4 * UI_TS;
    var _fit = min(_target, (_w - 12) / max(1, string_width(_label)), (_h - 4) / max(1, string_height(_label)));
    draw_text_transformed(_x + _w * 0.5, _y + _h * 0.5, _label, _fit, _fit, 0);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
    if (_font != undefined) draw_set_font(_prevFont);
    return (_hover && mouse_check_button_pressed(mb_left));
}

/// A ui_button that is present but INERT - same footprint and label, drawn dimmed, never returns
/// true. For actions that exist but aren't available right now (nothing selected, already done),
/// where hiding the button entirely would make the layout jump or read as broken.
function ui_button_disabled(_x, _y, _w, _h, _label, _font = undefined) {
    draw_set_alpha(0.75); draw_set_color(make_color_rgb(30, 32, 36));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false);
    draw_set_alpha(1);
    draw_set_color(make_color_rgb(70, 74, 80));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);
    draw_set_color(make_color_rgb(120, 124, 130));
    var _prevFont = draw_get_font();
    if (_font != undefined) draw_set_font(_font);
    draw_set_halign(fa_center); draw_set_valign(fa_middle);
    var _fit = min(1.4 * UI_TS, (_w - 12) / max(1, string_width(_label)), (_h - 4) / max(1, string_height(_label)));
    draw_text_transformed(_x + _w * 0.5, _y + _h * 0.5, _label, _fit, _fit, 0);
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    if (_font != undefined) draw_set_font(_prevFont);
    draw_set_color(c_white);
}

/// Chrome-less MENU-ITEM button: no frame or fill at all until hovered, and then only a faint
/// translucent panel behind it while the label warms to orange. Several stacked together read as one
/// cohesive menu list rather than a row of separate chunky buttons (which is what ui_button gives).
/// _enabled=false draws it dimmed and inert - never highlights, never returns true.
function ui_button_text(_x, _y, _w, _h, _label, _font = undefined, _enabled = true) {
    var _hover = _enabled && ui_mouse_in(_x, _y, _w, _h);
    if (_hover) {
        global.uiMouseConsumed = true;
        draw_set_alpha(0.22);
        draw_set_color(make_color_rgb(235, 226, 205));
        draw_rectangle(_x, _y, _x + _w, _y + _h, false);
        draw_set_alpha(1);
    }
    var _prevFont = draw_get_font();
    if (_font != undefined) draw_set_font(_font);
    draw_set_color(!_enabled ? make_color_rgb(122, 126, 132)
                             : (_hover ? make_color_rgb(255, 186, 90) : c_white));
    draw_set_halign(fa_center); draw_set_valign(fa_middle);
    var _fit = min(1.4 * UI_TS, (_w - 12) / max(1, string_width(_label)), (_h - 4) / max(1, string_height(_label)));
    draw_text_transformed(_x + _w * 0.5, _y + _h * 0.5, _label, _fit, _fit, 0);
    draw_set_halign(fa_left); draw_set_valign(fa_top);
    draw_set_color(c_white);
    if (_font != undefined) draw_set_font(_prevFont);
    return (_hover && mouse_check_button_pressed(mb_left));
}

/// Circular ICON button, no label - drawn straight from a sprite. Intended sprites: sprButtonConfirm
/// (green), sprButtonCancel (red), sprButtonDisabled (dark grey); all 1000x1000, top-left origin.
/// Use these for wordless affirm/deny affordances (a text box's "confirm", etc), NOT as a general
/// replacement for ui_button - anything that needs to say what it does still wants a labelled button.
///
/// Behaviour differs from ui_button on purpose: hover LIGHTENS, holding DARKENS, and it activates on
/// RELEASE rather than press, with a press-latch so the release only counts if it happens over the
/// same button the press started on (drag off to cancel - the standard OS button contract).
///
/// _size = on-screen diameter. _id disambiguates two buttons sharing an x/y across screens (same
/// role as ui_slider's _id); defaults to sprite+position. _enabled=false draws it dimmed and inert.
function ui_icon_button(_spr, _x, _y, _size, _id = undefined, _enabled = true) {
    if (!variable_global_exists("uiIconBtnDown")) global.uiIconBtnDown = undefined;
    var _key = (_id != undefined) ? _id : (string(_spr) + "_" + string(_x) + "_" + string(_y));
    var _sc  = _size / sprite_get_width(_spr);
    var _cx  = _x + _size * 0.5, _cy = _y + _size * 0.5;
    var _mx  = device_mouse_x_to_gui(0), _my = device_mouse_y_to_gui(0);
    // ROUND hit test - these are discs, so a rect test would also catch the empty corners
    var _hover = _enabled && (point_distance(_mx, _my, _cx, _cy) <= _size * 0.5);

    // drop a stale latch (the button that was pressed stopped being drawn, e.g. the screen changed
    // mid-click) so it can't fire a phantom activation when a same-keyed button comes back
    if (global.uiIconBtnDown == _key && !mouse_check_button(mb_left) && !mouse_check_button_released(mb_left)) global.uiIconBtnDown = undefined;

    if (!_enabled) {
        if (global.uiIconBtnDown == _key) global.uiIconBtnDown = undefined;
        draw_sprite_ext(_spr, 0, _x, _y, _sc, _sc, 0, merge_color(c_white, c_black, 0.45), 0.7);
        return false;
    }

    if (_hover) global.uiMouseConsumed = true;
    if (_hover && mouse_check_button_pressed(mb_left)) global.uiIconBtnDown = _key;
    var _down = (global.uiIconBtnDown == _key);

    // held -> multiply toward black (darken). hover -> base sprite + a soft ADDITIVE pass (a colour
    // blend can only darken, so lightening needs the extra additive draw).
    draw_sprite_ext(_spr, 0, _x, _y, _sc, _sc, 0, _down ? merge_color(c_white, c_black, 0.3) : c_white, 1);
    if (_hover && !_down) {
        gpu_set_blendmode(bm_add);
        draw_sprite_ext(_spr, 0, _x, _y, _sc, _sc, 0, c_white, 0.22);
        gpu_set_blendmode(bm_normal);
    }

    if (_down && mouse_check_button_released(mb_left)) {
        global.uiIconBtnDown = undefined;
        return _hover;   // released off the button = cancelled, not a click
    }
    return false;
}

/// Horizontal 0..1 slider. Click or drag anywhere on the track sets the value; returns the (possibly
/// updated) value so the caller can detect a change and persist. Caller sets the font for any label.
function ui_slider(_x, _y, _w, _h, _value, _id = undefined) {
    if (!variable_global_exists("uiSliderDrag")) global.uiSliderDrag = undefined;
    var _key = (_id != undefined) ? _id : (string(_x) + "_" + string(_y));
    var _mx = device_mouse_x_to_gui(0), _my = device_mouse_y_to_gui(0);
    var _cy = _y + _h * 0.5;
    var _over = (_mx >= _x - 8 && _mx <= _x + _w + 8 && _my >= _y - 4 && _my <= _y + _h + 6);
    // DRAG LATCH: grab the slider on a press that starts over it, then keep tracking until the button
    // releases - even when the cursor wanders off the track (the old code only moved while over it).
    if (global.uiSliderDrag == _key && !mouse_check_button(mb_left)) global.uiSliderDrag = undefined;
    if (_over && mouse_check_button_pressed(mb_left)) global.uiSliderDrag = _key;
    var _active = (global.uiSliderDrag == _key);
    if (_over || _active) global.uiMouseConsumed = true;
    var _v = clamp(_value, 0, 1);
    if (_active) _v = clamp((_mx - _x) / max(1, _w), 0, 1);
    draw_set_alpha(0.9); draw_set_color(make_color_rgb(40, 48, 66));
    draw_roundrect(_x, _cy - 4, _x + _w, _cy + 4, false);
    draw_set_color(make_color_rgb(120, 200, 140));
    if (_v > 0) draw_roundrect(_x, _cy - 4, _x + _w * _v, _cy + 4, false);
    draw_set_color(c_white);
    draw_circle(_x + _w * _v, _cy, 8, false);
    draw_set_color(make_color_rgb(60, 70, 90));
    draw_circle(_x + _w * _v, _cy, 8, true);
    draw_set_alpha(1);
    return _v;
}

/// Pikmin-POPULATION line graph (Pikmin-3-style results): one coloured line per pikmin type showing
/// that colour's count across _g.popHistory's phase snapshots, for one seat, drawn into (_x,_y,_w,_h).
/// Vertical day-boundary gridlines + a 0..peak y-axis. Returns the array of colour ids plotted (for a
/// legend), or undefined when there aren't yet 2 points. Caller sets the font.
function pop_graph_draw(_g, _seat, _x, _y, _w, _h) {
    var _hist = (variable_struct_exists(_g, "popHistory") && is_array(_g.popHistory)) ? _g.popHistory : [];
    var _n = array_length(_hist);
    draw_set_alpha(0.5); draw_set_color(make_color_rgb(14, 18, 22));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false); draw_set_alpha(1);
    draw_set_color(make_color_rgb(70, 80, 90));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);
    draw_set_color(c_white);
    if (_n < 2 || _seat < 0 || _seat >= array_length(_hist[0].seats)) {
        draw_set_halign(fa_center); draw_set_color(make_color_rgb(170, 175, 180));
        dtext(_x + _w * 0.5, _y + _h * 0.5 - 8, "Not enough data yet.");
        draw_set_halign(fa_left); draw_set_color(c_white);
        return undefined;
    }
    // colours ever present for this seat. y-axis is fixed at 25 (a stable reference across boards);
    // only stretches beyond that in the rare case a colour somehow exceeds 25, so lines never clip.
    var _cols = []; var _maxV = 25;
    for (var _i = 0; _i < _n; _i++) {
        var _s = _hist[_i].seats[_seat];
        var _names = variable_struct_get_names(_s);
        for (var _k = 0; _k < array_length(_names); _k++) {
            if (!arr_has(_cols, _names[_k])) array_push(_cols, _names[_k]);
            _maxV = max(_maxV, _s[$ _names[_k]]);
        }
    }
    var _padL = 30, _padB = 22, _padT = 8, _padR = 8;
    var _px = _x + _padL, _py = _y + _padT;
    var _pw = _w - _padL - _padR, _ph = _h - _padT - _padB;
    var _xat = function(_i, _px, _pw, _n) { return _px + ((_n <= 1) ? 0 : _pw * _i / (_n - 1)); };
    // horizontal gridlines (0 / mid / peak) + y labels
    draw_set_color(make_color_rgb(44, 52, 60));
    for (var _gyi = 0; _gyi <= 2; _gyi++) { var _yy = _py + _ph * _gyi / 2; draw_line(_px, _yy, _px + _pw, _yy); }
    draw_set_color(make_color_rgb(150, 160, 168)); draw_set_halign(fa_right);
    dtext(_px - 4, _py - 6, string(_maxV));
    dtext(_px - 4, _py + _ph - 12, "0");
    draw_set_halign(fa_left);
    // faint vertical slice at EVERY snapshot (each phase point) - unlabeled, for reading off when
    // each gather/orders/combat step happened
    draw_set_color(make_color_rgb(22, 27, 32));
    for (var _i = 0; _i < _n; _i++) { var _sx = _xat(_i, _px, _pw, _n); draw_line(_sx, _py, _sx, _py + _ph); }
    // vertical day-boundary lines + "D<n>" labels (brighter, over the slices)
    var _prevDay = -999;
    for (var _i = 0; _i < _n; _i++) {
        if (_hist[_i].day != _prevDay) {
            _prevDay = _hist[_i].day;
            var _xx = _xat(_i, _px, _pw, _n);
            draw_set_color(make_color_rgb(90, 104, 120)); draw_line(_xx, _py, _xx, _py + _ph);
            draw_set_color(make_color_rgb(150, 160, 168)); draw_set_halign(fa_center);
            dtext(_xx, _py + _ph + 3, "D" + string(_prevDay));
            draw_set_halign(fa_left);
        }
    }
    // one polyline per colour (draw thick; identical stacks overlap harmlessly)
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _id = _cols[_c];
        var _tint = pikmin_tint(_id);
        for (var _i = 1; _i < _n; _i++) {
            var _sa = _hist[_i - 1].seats[_seat], _sb = _hist[_i].seats[_seat];
            var _v0 = variable_struct_exists(_sa, _id) ? _sa[$ _id] : 0;
            var _v1 = variable_struct_exists(_sb, _id) ? _sb[$ _id] : 0;
            var _x0 = _xat(_i - 1, _px, _pw, _n), _x1 = _xat(_i, _px, _pw, _n);
            var _y0 = _py + _ph - _ph * _v0 / _maxV, _y1 = _py + _ph - _ph * _v1 / _maxV;
            draw_set_color(_tint);
            draw_line_width(_x0, _y0, _x1, _y1, 3);
        }
    }
    draw_set_color(c_white);
    return _cols;
}

/// On-screen width of a tag chip for _label. _el = an element key for a leading icon, or ""
/// for a text-only chip. (An element with no sprite - e.g. "chasm" - still reserves icon room.)
function tag_chip_width(_el, _label) {
    return (_el != "" ? 28 : 10) + dtext_width(_label) + 12;
}

/// Draw a small "tag" chip (box + optional icon + label) at (_x,_y), 26px tall. _el = an
/// element key: draws its element sprite if it has one, else a brownish fallback square (like
/// "chasm" on the board-select screen); "" = text-only chip. Returns width. Assumes fntMaru set.
function draw_tag_chip(_x, _y, _el, _label) {
    var _hasIcon = (_el != "");
    var _cw = tag_chip_width(_el, _label);
    draw_set_alpha(0.85); draw_set_color(make_color_rgb(34, 40, 46));
    draw_rectangle(_x, _y, _x + _cw, _y + 26, false);
    draw_set_alpha(1); draw_set_color(make_color_rgb(70, 80, 88));
    draw_rectangle(_x, _y, _x + _cw, _y + 26, true);
    if (_hasIcon) {
        var _spr = element_sprite(_el);
        if (_spr != -1) {
            var _is = 19 / max(sprite_get_width(_spr), sprite_get_height(_spr));
            draw_sprite_ext(_spr, 0, _x + 15 - sprite_get_width(_spr) * _is * 0.5, _y + 13 - sprite_get_height(_spr) * _is * 0.5, _is, _is, 0, c_white, 1);
        } else {
            draw_set_color(make_color_rgb(96, 84, 60)); // no element sprite (chasm) - brownish square
            draw_rectangle(_x + 7, _y + 6, _x + 22, _y + 20, false);
            draw_set_color(c_white);
        }
    }
    draw_set_color(c_white);
    dtext(_x + (_hasIcon ? 28 : 10), _y + 6, _label);
    return _cw;
}

/// Draw a wrapping row of tag chips starting at (_x0,_y), wrapping within right edge _xRight.
/// _tags is an array of {label, el}; el "" (or one with no element sprite) draws a text chip.
/// Returns the Y just below the last chip row, or _y unchanged if _tags is empty.
function draw_tag_row(_tags, _x0, _y, _xRight) {
    if (array_length(_tags) == 0) return _y;
    var _tx = _x0, _ty = _y;
    for (var _i = 0; _i < array_length(_tags); _i++) {
        var _t = _tags[_i];
        var _w = tag_chip_width(_t.el, _t.label);
        if (_tx > _x0 && _tx + _w > _xRight) { _tx = _x0; _ty += 30; }
        draw_tag_chip(_tx, _ty, _t.el, _t.label);
        _tx += _w + 6;
    }
    return _ty + 30;
}

/// Draw cards (by alias) as vertically-overlapping columns in the box [_x,_y,_w,_h]: each card
/// is offset down just enough to reveal the title of the one above, wrapping to a new column
/// when a column fills. Cards keep a consistent size (shrunk only if the whole set won't fit
/// the width). Returns {i,id,x,y,cw,ch} for the topmost card under (_mx,_my), or undefined -
/// the caller pops that one enlarged on top ("brings it to the front"). Draw order = index
/// order, so later cards sit on top; the highest index under the mouse is the visible one.
function draw_card_stack(_ids, _x, _y, _w, _h, _mx, _my) {
    var _n = array_length(_ids);
    if (_n == 0) return undefined;
    var _colGap = 14;
    var _ch = clamp(_h * 0.56, 96, 200);             // consistent target height
    var _cw, _off, _perCol, _cols;
    while (true) {                                    // shrink until all columns fit the width
        _cw = _ch * 0.714;
        _off = _ch * 0.26;                           // vertical reveal ~= a card's title strip
        _perCol = max(1, floor((_h - _ch) / _off) + 1);
        _cols = ceil(_n / _perCol);
        if (_cols * _cw + (_cols - 1) * _colGap <= _w || _ch <= 96) break;
        _ch -= 6;
    }
    var _hover = undefined;
    for (var _i = 0; _i < _n; _i++) {
        var _cx = _x + (_i div _perCol) * (_cw + _colGap);
        var _cy = _y + (_i mod _perCol) * _off;
        card_draw(_ids[_i], _cx, _cy, _ch);
        if (_mx >= _cx && _mx < _cx + _cw && _my >= _cy && _my < _cy + _ch)
            _hover = { i: _i, id: _ids[_i], x: _cx, y: _cy, cw: _cw, ch: _ch };
    }
    return _hover;
}

/// Draw structure cards as a BOTTOM-anchored, vertically-overlapping pile centered in the
/// column [_x .. _x+_w]: the pile's bottom sits at _bottom and it grows upward only as tall as
/// needed (shrinking cards if it would pass _topLimit). Structure cards are LANDSCAPE, so size
/// fits the column WIDTH (using the widest card's aspect). Cards are pre-sorted by class.
/// Returns {top, hover}: `top` is the pile's top Y (so the caller can put the label there),
/// `hover` is {id,x,y,cw,ch} for the topmost card under (_mx,_my) or undefined.
function draw_structure_stack(_ids, _x, _w, _bottom, _topLimit, _mx, _my) {
    var _n = array_length(_ids);
    if (_n == 0) return { top: _bottom, hover: undefined };
    var _usableW = _w - 12;
    var _maxAsp = 1.0;                                // widest card drives the height so none overflow
    for (var _i = 0; _i < _n; _i++) {
        var _s = card_sprite_get(_ids[_i]);
        if (_s != -1) _maxAsp = max(_maxAsp, sprite_get_width(_s) / sprite_get_height(_s));
    }
    var _offRatio = 0.42;                             // vertical reveal as a fraction of card height
    var _ch = _usableW / _maxAsp;                     // fit the column width
    var _availH = _bottom - _topLimit;
    if ((_n - 1) * (_ch * _offRatio) + _ch > _availH) // shrink so the whole pile fits the height
        _ch = _availH / ((_n - 1) * _offRatio + 1);
    var _off = _ch * _offRatio;
    var _top = _bottom - ((_n - 1) * _off + _ch);     // start at the bottom, grow up
    var _cxMid = _x + _w * 0.5;
    var _hover = undefined;
    for (var _i = 0; _i < _n; _i++) {
        var _cy = _top + _i * _off;
        var _s = card_sprite_get(_ids[_i]);
        var _cw = (_s != -1) ? (_ch * sprite_get_width(_s) / sprite_get_height(_s)) : (_ch * 0.714);
        var _dx = _cxMid - _cw * 0.5;
        card_draw(_ids[_i], _dx, _cy, _ch);
        if (_mx >= _dx && _mx < _dx + _cw && _my >= _cy && _my < _cy + _ch)
            _hover = { id: _ids[_i], x: _dx, y: _cy, cw: _cw, ch: _ch };
    }
    return { top: _top, hover: _hover };
}

/// Draw one player's collected-treasure panel. Returns the alias of the card the
/// mouse is over (for Alt-zoom), or "". Blocks board clicks under itself.
/// _brain: brain id to print top-right (across from the label), or "" for a human seat.
function draw_collection_panel(_g, _p, _x, _y, _w, _h, _mgx, _mgy, _brain = "") {
    var _sum = game_collection_summary(_g, _p);
    ui_block_rect(_x, _y, _w, _h);

    draw_set_alpha(0.92);
    draw_set_color(make_color_rgb(22, 26, 32));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false);
    draw_set_alpha(1);
    draw_set_color(player_tint(_p));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);

    draw_set_font(fntMaru);
    draw_set_color(player_marker(_p));
    dtext(_x + 12, _y + 8, "P" + string(_p + 1) + " TREASURE");
    if (_brain != "") {
        draw_set_halign(fa_right);
        draw_set_color(make_color_rgb(170, 180, 195));
        dtext(_x + _w - 12, _y + 8, _brain);
        draw_set_halign(fa_left);
    }
    draw_set_color(c_white);
    dtext(_x + 12, _y + 30, string(_sum.score) + "p scored");

    var _cy = _y + 58;
    var _hoverAlias = "";
    var _thumbH = 38;
    var _thumbW = 58;
    var _threshold = global.rules.setThreshold;
    var _perRow = max(1, floor((_w - 24) / (_thumbW + 4)));

    for (var _gi = 0; _gi < array_length(_sum.groups); _gi++) {
        if (_cy > _y + _h - 30) break;
        var _grp = _sum.groups[_gi];

        // group header line: name + status/points
        var _status;
        if (_grp.isLoose)      _status = string(_grp.value) + "p";
        else if (_grp.active)  _status = "ACTIVE  " + string(_grp.value) + "p";
        else                   _status = string(_grp.count) + "/" + string(_threshold) + "  need " + string(_threshold - _grp.count);
        draw_set_color(_grp.active ? make_color_rgb(120, 220, 120) : make_color_rgb(178, 182, 190));
        dtext(_x + 12, _cy, _grp.name);
        draw_set_halign(fa_right);
        dtext(_x + _w - 12, _cy, _status);
        draw_set_halign(fa_left);
        draw_set_color(c_white);
        _cy += 20;

        // wrapped card thumbnails
        var _tx = _x + 12;
        for (var _ci = 0; _ci < array_length(_grp.ids); _ci++) {
            if (_ci > 0 && (_ci mod _perRow) == 0) { _cy += _thumbH + 4; _tx = _x + 12; }
            if (_cy > _y + _h - _thumbH - 4) break;
            card_draw(_grp.ids[_ci], _tx, _cy, _thumbH);
            // dim pieces of a series that isn't scoring yet
            if (!_grp.active && !_grp.isLoose) {
                draw_set_alpha(0.5);
                draw_set_color(make_color_rgb(16, 18, 24));
                draw_rectangle(_tx, _cy, _tx + _thumbW, _cy + _thumbH, false);
                draw_set_alpha(1);
                draw_set_color(c_white);
            }
            // poko value stamped over the card in the pikmin font (white, black outline).
            // _base is the card's printed worth; _val is what it'll actually score. They match
            // today, but once banked powers like Glow Up are wired to bump a collected piece's
            // worth, set _val from that and the number tints YELLOW when the price is raised.
            var _tdefV = treasure_def_get(_grp.ids[_ci]);
            var _base = _tdefV.value;
            var _val = _base;
            // Glow Up passive: this player's sub-100p treasures score a flat +100
            if (variable_struct_exists(_g.players[_p], "glowUp") && _g.players[_p].glowUp && _base < 100) _val = _base + 100;
            var _valCol = (_val > _base) ? make_color_rgb(255, 224, 90)   // raised price -> yellow
                        : ((_val < _base) ? make_color_rgb(250, 120, 110) : c_white);
            draw_set_font(fntPikmin);
            draw_set_halign(fa_center);
            draw_set_valign(fa_middle);
            dtext_outline(_tx + _thumbW * 0.5 - 3, _cy + _thumbH * 0.5, string(_val), 0.55, _valCol);
            // good/bad on-bank power badge: a small green (Good) or red (Bad) dot, top-right
            if (_tdefV.effectType == "Good" || _tdefV.effectType == "Bad") {
                var _dotCol = (_tdefV.effectType == "Good") ? make_color_rgb(90, 220, 90) : make_color_rgb(230, 70, 60);
                var _dcx = _tx + _thumbW - 7, _dcy = _cy + 7;
                draw_set_color(make_color_rgb(12, 12, 12));
                draw_circle(_dcx, _dcy, 5.5, false);   // dark rim for contrast on any art
                draw_set_color(_dotCol);
                draw_circle(_dcx, _dcy, 4, false);
            }
            draw_set_halign(fa_left);
            draw_set_valign(fa_top);
            draw_set_font(fntMaru);
            draw_set_color(c_white);
            if (_mgx >= _tx && _mgx < _tx + _thumbW && _mgy >= _cy && _mgy < _cy + _thumbH) _hoverAlias = _grp.ids[_ci];
            _tx += _thumbW + 4;
        }
        _cy += _thumbH + 12;
    }
    return _hoverAlias;
}

/// Project a world point to GUI coordinates via a combined view*projection matrix.
/// Returns [gx, gy] or undefined when behind the camera.
function world_to_gui(_viewProj, _x, _y, _z) {
    var _v = matrix_transform_vertex(_viewProj, _x, _y, _z, 1);
    if (_v[3] <= 0) return undefined;
    var _nx = _v[0] / _v[3];
    var _ny = _v[1] / _v[3];
    return [(_nx * 0.5 + 0.5) * display_get_gui_width(), (_ny * 0.5 + 0.5) * display_get_gui_height()];
}

/// Is gui point (_px,_py) inside the convex quad a->b->c->d (each a [x,y])? A world rectangle projects
/// to a convex quad, so the same-side-of-every-edge test works for either winding. Used to make a
/// whole projected strip (e.g. a home row) clickable, not just sampled points along it.
function point_in_convex_quad(_px, _py, _a, _b, _c, _d) {
    var _pts = [_a, _b, _c, _d];
    var _side = 0;
    for (var _i = 0; _i < 4; _i++) {
        var _p0 = _pts[_i];
        var _p1 = _pts[(_i + 1) mod 4];
        var _cross = (_p1[0] - _p0[0]) * (_py - _p0[1]) - (_p1[1] - _p0[1]) * (_px - _p0[0]);
        var _s = sign(_cross);
        if (_s != 0) { if (_side == 0) _side = _s; else if (_side != _s) return false; }
    }
    return true;
}
