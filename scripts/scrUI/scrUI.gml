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

function ui_button(_x, _y, _w, _h, _label) {
    var _hover = ui_mouse_in(_x, _y, _w, _h);
    if (_hover) global.uiMouseConsumed = true;
    draw_set_alpha(_hover ? 0.95 : 0.75);
    draw_set_color(_hover ? make_color_rgb(74, 96, 132) : make_color_rgb(42, 52, 74));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false);
    draw_set_alpha(1);
    draw_set_color(make_color_rgb(180, 195, 220));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);
    draw_set_color(c_white);
    draw_set_halign(fa_center);
    draw_set_valign(fa_middle);
    // fit the label inside the button - shrink it if it would overflow (font-agnostic)
    var _fit = min(1, (_w - 12) / max(1, string_width(_label)), (_h - 4) / max(1, string_height(_label)));
    draw_text_transformed(_x + _w * 0.5, _y + _h * 0.5, _label, _fit, _fit, 0);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
    return (_hover && mouse_check_button_pressed(mb_left));
}

/// Draw one player's collected-treasure panel. Returns the alias of the card the
/// mouse is over (for Alt-zoom), or "". Blocks board clicks under itself.
function draw_collection_panel(_g, _p, _x, _y, _w, _h, _mgx, _mgy) {
    var _sum = game_collection_summary(_g, _p);
    ui_block_rect(_x, _y, _w, _h);

    draw_set_alpha(0.92);
    draw_set_color(make_color_rgb(22, 26, 32));
    draw_rectangle(_x, _y, _x + _w, _y + _h, false);
    draw_set_alpha(1);
    draw_set_color(player_tint(_p));
    draw_rectangle(_x, _y, _x + _w, _y + _h, true);

    draw_set_font(fntPikmin);
    draw_set_color(player_marker(_p));
    dtext(_x + 12, _y + 8, (_p == 0) ? "YOUR TREASURE" : "ENEMY TREASURE");
    draw_set_color(c_white);
    dtext(_x + 12, _y + 30, string(_sum.score) + "p scored");
    draw_set_font(-1);

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
        draw_text(_x + 12, _cy, _grp.name);
        draw_set_halign(fa_right);
        draw_text(_x + _w - 12, _cy, _status);
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
