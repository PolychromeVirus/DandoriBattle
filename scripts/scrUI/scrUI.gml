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
