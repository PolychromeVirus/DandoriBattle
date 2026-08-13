// Runtime loading of card images from included files (datafiles/cardimages/CARD<alias>.png).
// Cards are large PNGs kept out of the asset browser on purpose: they load lazily via
// sprite_add, are cached by alias, and can be swapped on disk without touching the project.

/// Load + cache a card image by prefix ("CARD" faces, "BACK" backs). Returns -1 if
/// the file is missing (callers draw a placeholder). Cache key includes the prefix.
function card_image_get(_prefix, _alias) {
    if (!variable_global_exists("cardSpriteCache")) global.cardSpriteCache = {};
    var _key = _prefix + _alias;
    if (variable_struct_exists(global.cardSpriteCache, _key)) return global.cardSpriteCache[$ _key];
    var _path = "cardimages/" + _prefix + _alias + ".png";
    var _sprIdx = -1;
    if (file_exists(_path)) {
        _sprIdx = sprite_add(_path, 1, false, false, 0, 0);
        if (_sprIdx == -1) show_debug_message("[cards] sprite_add FAILED (bad/oversized image?): " + _path);
    }
    global.cardSpriteCache[$ _key] = _sprIdx;
    return _sprIdx;
}

/// Sprite for a card FACE alias (CARD<alias>.png). -1 if missing.
function card_sprite_get(_alias) {
    return card_image_get("CARD", _alias);
}

/// Sprite for a card BACK by type (BACK<type>.png), for showing an opponent's hand /
/// a deck's back without revealing faces. -1 if missing.
function card_back_sprite_get(_type) {
    return card_image_get("BACK", _type);
}

/// Back-image CATEGORY for a card (this game uses generic per-category backs, not
/// per-card): BACKenemy / BACKtreasure / BACKpellet / BACKgather. Pass the card kind.
function card_back_type(_kind) {
    return _kind; // "gather" | "pellet" | "treasure" | "enemy"
}

/// Monster cards have per-board art: CARD<alias><boardNumber>.png. Resolve to the board-specific
/// file when it exists; else the plain CARD<alias>.png; else ANY board's art for this enemy
/// (the procedural "random" board rolls a set that won't have every enemy's per-board export,
/// so without this those cards showed no art). Result cached per (alias, boardNum) - the file
/// scan would otherwise run on every card render. (Checks file_exists so misses don't spam logs.)
function card_enemy_alias(_alias, _boardNum) {
    if (!variable_global_exists("cardEnemyAliasCache")) global.cardEnemyAliasCache = {};
    var _key = _alias + "#" + string(_boardNum);
    if (variable_struct_exists(global.cardEnemyAliasCache, _key)) return global.cardEnemyAliasCache[$ _key];

    var _res = _alias;                                   // last resort: text placeholder
    var _suffixed = _alias + string(_boardNum);
    if (file_exists("cardimages/CARD" + _suffixed + ".png")) {
        _res = _suffixed;
    } else if (file_exists("cardimages/CARD" + _alias + ".png")) {
        _res = _alias;
    } else {
        for (var _n = 1; _n <= 16; _n++) {
            if (file_exists("cardimages/CARD" + _alias + string(_n) + ".png")) { _res = _alias + string(_n); break; }
        }
    }
    global.cardEnemyAliasCache[$ _key] = _res;
    return _res;
}

/// Free every runtime-loaded card sprite (game end, or after swapping art on disk).
function card_sprites_free() {
    if (!variable_global_exists("cardSpriteCache")) return;
    var _aliases = variable_struct_get_names(global.cardSpriteCache);
    for (var _i = 0; _i < array_length(_aliases); _i++) {
        var _sprIdx = global.cardSpriteCache[$ _aliases[_i]];
        if (_sprIdx != -1) sprite_delete(_sprIdx);
    }
    global.cardSpriteCache = {};
    global.cardEnemyAliasCache = {};   // alias->file resolution is also disk-dependent
}

/// Draw one card image fitted to a target height at (_x, _y) = top-left, preserving
/// aspect. Returns the drawn width so callers can lay out a hand. Missing images draw
/// a dark placeholder with the alias printed on it.
function card_draw(_alias, _x, _y, _height, _alpha = 1) {
    var _sprIdx = card_sprite_get(_alias);
    if (_sprIdx == -1) {
        var _w = _height * 0.714; // standard card aspect
        draw_set_alpha(_alpha);
        draw_set_color(make_color_rgb(40, 40, 48));
        draw_rectangle(_x, _y, _x + _w, _y + _height, false);
        draw_set_color(c_white);
        draw_set_halign(fa_center);
        var _pf = draw_get_font();
        draw_set_font(fntMaru);
        dtext(_x + _w * 0.5, _y + _height * 0.5, _alias);
        draw_set_font(_pf);
        draw_set_halign(fa_left);
        draw_set_alpha(1);
        return _w;
    }
    var _scale = _height / sprite_get_height(_sprIdx);
    draw_sprite_ext(_sprIdx, 0, _x, _y, _scale, _scale, 0, c_white, _alpha);
    return sprite_get_width(_sprIdx) * _scale;
}
