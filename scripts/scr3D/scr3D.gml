// 3D rendering helpers for the mode-7 style renderer (M0).
// World convention: x = right, y = across the board, z = up. Ground is the z=0 plane.

/// Shared vertex format: 3D position + colour + UV. Created once, reused everywhere.
function vformat_3d() {
    static fmt = undefined;
    if (fmt == undefined) {
        vertex_format_begin();
        vertex_format_add_position_3d();
        vertex_format_add_color();
        vertex_format_add_texcoord();
        fmt = vertex_format_end();
    }
    return fmt;
}

/// Push one vertex into an open vertex buffer.
function vb_vertex(_vb, _x, _y, _z, _col, _alpha, _u, _v) {
    vertex_position_3d(_vb, _x, _y, _z);
    vertex_color(_vb, _col, _alpha);
    vertex_texcoord(_vb, _u, _v);
}

/// Build a frozen checkerboard ground plane centred on the world origin.
/// _palette: 2 colours = classic checker; 4 colours = repeating 2x2 block (disco).
/// Returns the vertex buffer; submit with texture -1 (vertex colours only).
/// Optional distance fade: when _fadeEnd > _fadeStart, vertex ALPHA ramps 1->0
/// across that world-y band, so far rows dissolve into whatever's drawn behind
/// (used by the title screen so the checker melts into the sky, no hard edge).
/// Fading planes must be submitted with alpha-test OFF and alpha blending ON.
function build_ground(_cols, _rows, _tile, _palette, _cx = 0, _cy = 0, _fadeStart = 0, _fadeEnd = 0) {
    var vb = vertex_create_buffer();
    vertex_begin(vb, vformat_3d());
    var x0 = -(_cols * _tile) * 0.5 + _cx;   // _cx/_cy recentre the slab (compact solo boards sit off-origin)
    var y0 = -(_rows * _tile) * 0.5 + _cy;
    var _n = array_length(_palette);
    var _fade = (_fadeEnd > _fadeStart);
    for (var i = 0; i < _cols; i++) {
        for (var j = 0; j < _rows; j++) {
            var c = (_n >= 4) ? _palette[(i mod 2) + (j mod 2) * 2] : _palette[(i + j) mod _n];
            var xa = x0 + i * _tile;
            var ya = y0 + j * _tile;
            var xb = xa + _tile;
            var yb = ya + _tile;
            // per-row alpha (constant within a tile's near/far edge) for the distance fade
            var aa = _fade ? (1 - clamp((ya - _fadeStart) / (_fadeEnd - _fadeStart), 0, 1)) : 1;
            var ab = _fade ? (1 - clamp((yb - _fadeStart) / (_fadeEnd - _fadeStart), 0, 1)) : 1;
            vb_vertex(vb, xa, ya, 0, c, aa, 0, 0);
            vb_vertex(vb, xb, ya, 0, c, aa, 1, 0);
            vb_vertex(vb, xb, yb, 0, c, ab, 1, 1);
            vb_vertex(vb, xa, ya, 0, c, aa, 0, 0);
            vb_vertex(vb, xb, yb, 0, c, ab, 1, 1);
            vb_vertex(vb, xa, yb, 0, c, ab, 0, 1);
        }
    }
    vertex_end(vb);
    vertex_freeze(vb);
    return vb;
}

/// Append one flat (ground-plane) coloured quad centred on _x,_y at height _z.
function vb_tile(_vb, _x, _y, _z, _w, _h, _col, _alpha = 1) {
    var xa = _x - _w * 0.5, ya = _y - _h * 0.5;
    var xb = _x + _w * 0.5, yb = _y + _h * 0.5;
    vb_vertex(_vb, xa, ya, _z, _col, _alpha, 0, 0);
    vb_vertex(_vb, xb, ya, _z, _col, _alpha, 1, 0);
    vb_vertex(_vb, xb, yb, _z, _col, _alpha, 1, 1);
    vb_vertex(_vb, xa, ya, _z, _col, _alpha, 0, 0);
    vb_vertex(_vb, xb, yb, _z, _col, _alpha, 1, 1);
    vb_vertex(_vb, xa, yb, _z, _col, _alpha, 0, 1);
}

/// Append a flat filled circle (on the ground z-plane) as a triangle-fan of _segs
/// triangles. Used for soft player-tinted shadow discs under tokens.
function vb_disc(_vb, _x, _y, _z, _r, _col, _alpha, _segs = 14) {
    var _px = _x + _r, _py = _y;
    for (var _i = 1; _i <= _segs; _i++) {
        var _a = (_i / _segs) * 2 * pi;
        var _nx = _x + cos(_a) * _r;
        var _ny = _y + sin(_a) * _r;
        vb_vertex(_vb, _x, _y, _z, _col, _alpha, 0.5, 0.5);
        vb_vertex(_vb, _px, _py, _z, _col, _alpha, 0.5, 0.5);
        vb_vertex(_vb, _nx, _ny, _z, _col, _alpha, 0.5, 0.5);
        _px = _nx; _py = _ny;
    }
}

/// A low standing wall across a tile: a lane-blocking box of three faces (front,
/// back, top) spanning _w along x, _t thick along y, _h tall. Untextured.
function vb_wall(_vb, _x, _y, _w, _h, _t, _colFront, _alpha = 1) {
    var _hw = _w * 0.5;
    var _ht = _t * 0.5;
    var _colBack = merge_color(_colFront, c_black, 0.35);
    var _colTop  = merge_color(_colFront, c_white, 0.25);
    // front face (toward -y / player A side)
    vb_vertex(_vb, _x - _hw, _y - _ht, 0,  _colFront, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y - _ht, 0,  _colFront, _alpha, 1, 0);
    vb_vertex(_vb, _x + _hw, _y - _ht, _h, _colFront, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y - _ht, 0,  _colFront, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y - _ht, _h, _colFront, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y - _ht, _h, _colFront, _alpha, 0, 1);
    // back face (toward +y / player B side)
    vb_vertex(_vb, _x - _hw, _y + _ht, 0,  _colBack, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y + _ht, 0,  _colBack, _alpha, 1, 0);
    vb_vertex(_vb, _x + _hw, _y + _ht, _h, _colBack, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y + _ht, 0,  _colBack, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y + _ht, _h, _colBack, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y + _ht, _h, _colBack, _alpha, 0, 1);
    // top cap
    vb_vertex(_vb, _x - _hw, _y - _ht, _h, _colTop, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y - _ht, _h, _colTop, _alpha, 1, 0);
    vb_vertex(_vb, _x + _hw, _y + _ht, _h, _colTop, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y - _ht, _h, _colTop, _alpha, 0, 0);
    vb_vertex(_vb, _x + _hw, _y + _ht, _h, _colTop, _alpha, 1, 1);
    vb_vertex(_vb, _x - _hw, _y + _ht, _h, _colTop, _alpha, 0, 1);
}

/// Append one camera-facing untextured rectangle, centred on _x,_y,_z (health bars etc).
function vb_billboard_rect(_vb, _x, _y, _z, _w, _h, _right, _up, _col, _alpha) {
    var _hw = _w * 0.5;
    var _hh = _h * 0.5;
    var _blx = _x - _right[0] * _hw - _up[0] * _hh, _bly = _y - _right[1] * _hw - _up[1] * _hh, _blz = _z - _right[2] * _hw - _up[2] * _hh;
    var _brx = _x + _right[0] * _hw - _up[0] * _hh, _bry = _y + _right[1] * _hw - _up[1] * _hh, _brz = _z + _right[2] * _hw - _up[2] * _hh;
    var _trx = _x + _right[0] * _hw + _up[0] * _hh, _try = _y + _right[1] * _hw + _up[1] * _hh, _trz = _z + _right[2] * _hw + _up[2] * _hh;
    var _tlx = _x - _right[0] * _hw + _up[0] * _hh, _tly = _y - _right[1] * _hw + _up[1] * _hh, _tlz = _z - _right[2] * _hw + _up[2] * _hh;
    vb_vertex(_vb, _blx, _bly, _blz, _col, _alpha, 0, 0);
    vb_vertex(_vb, _brx, _bry, _brz, _col, _alpha, 1, 0);
    vb_vertex(_vb, _trx, _try, _trz, _col, _alpha, 1, 1);
    vb_vertex(_vb, _blx, _bly, _blz, _col, _alpha, 0, 0);
    vb_vertex(_vb, _trx, _try, _trz, _col, _alpha, 1, 1);
    vb_vertex(_vb, _tlx, _tly, _tlz, _col, _alpha, 0, 1);
}

/// Flat ground decal for a sprite, centred on _x,_y at height _z, fitted into a
/// _size x _size box keeping the sprite's aspect. The sprite's top faces +y.
/// Compensates for texture-page auto-cropping like vb_billboard does.
function vb_tile_sprite(_vb, _spr, _img, _x, _y, _z, _size, _col, _alpha, _flip = false) {
    var _sw = sprite_get_width(_spr);
    var _sh = sprite_get_height(_spr);
    var _fit = _size / max(_sw, _sh);
    var _w = _sw * _fit;
    var _h = _sh * _fit;
    var _uvs = sprite_get_uvs(_spr, _img);
    var _lx = -_w * 0.5 + (_uvs[4] / _sw) * _w;
    var _rx = _lx + _uvs[6] * _w;
    var _ty = _h * 0.5 - (_uvs[5] / _sh) * _h;
    var _by = _ty - _uvs[7] * _h;
    var _u0 = _uvs[0], _v0 = _uvs[1], _u1 = _uvs[2], _v1 = _uvs[3];
    // _flip = rotate the decal 180deg (swap both UV axes) so a hazard on the opponent's half
    // faces them instead of the player
    if (_flip) { var _tu = _u0; _u0 = _u1; _u1 = _tu; var _tv = _v0; _v0 = _v1; _v1 = _tv; }
    // x is negated: the y-flipped projection mirrors world x on screen, so the
    // geometry is reflected here to keep card text reading left-to-right.
    vb_vertex(_vb, _x - _lx, _y + _by, _z, _col, _alpha, _u0, _v1);
    vb_vertex(_vb, _x - _rx, _y + _by, _z, _col, _alpha, _u1, _v1);
    vb_vertex(_vb, _x - _rx, _y + _ty, _z, _col, _alpha, _u1, _v0);
    vb_vertex(_vb, _x - _lx, _y + _by, _z, _col, _alpha, _u0, _v1);
    vb_vertex(_vb, _x - _rx, _y + _ty, _z, _col, _alpha, _u1, _v0);
    vb_vertex(_vb, _x - _lx, _y + _ty, _z, _col, _alpha, _u0, _v0);
}

/// World matrix for drawing 2D primitives (text, circles, sprites) as a
/// camera-facing plane anchored at a world position. Local +x is screen right,
/// local +y is screen DOWN (matching 2D drawing conventions); _scale converts
/// local pixels to world units.
function billboard_matrix(_x, _y, _z, _scale, _right, _up, _fwd) {
    return [
        _right[0] * _scale, _right[1] * _scale, _right[2] * _scale, 0,
        -_up[0] * _scale, -_up[1] * _scale, -_up[2] * _scale, 0,
        _fwd[0], _fwd[1], _fwd[2], 0,
        _x, _y, _z, 1
    ];
}

/// Draw text as a camera-facing 3D label (uses the current font/colour/align state).
/// _scale converts font pixels to world units. Resets the world matrix afterwards.
function draw_text_billboard(_x, _y, _z, _text, _scale, _right, _up, _fwd) {
    matrix_set(matrix_world, billboard_matrix(_x, _y, _z, _scale, _right, _up, _fwd));
    draw_text(0, 0, _text);
    matrix_set(matrix_world, matrix_build_identity());
}

/// Per-frame batching for quads that use different sprites (and so possibly
/// different texture pages). Get a buffer per sprite, then flush submits and
/// frees them all.
function sprite_batches_create() {
    return { spriteIds: [], buffers: [] };
}

function sprite_batches_vb(_batches, _sprite) {
    var _count = array_length(_batches.spriteIds);
    for (var _i = 0; _i < _count; _i++) {
        if (_batches.spriteIds[_i] == _sprite) return _batches.buffers[_i];
    }
    var _vb = vertex_create_buffer();
    vertex_begin(_vb, vformat_3d());
    array_push(_batches.spriteIds, _sprite);
    array_push(_batches.buffers, _vb);
    return _vb;
}

function sprite_batches_flush(_batches) {
    var _count = array_length(_batches.spriteIds);
    for (var _i = 0; _i < _count; _i++) {
        vertex_end(_batches.buffers[_i]);
        vertex_submit(_batches.buffers[_i], pr_trianglelist, sprite_get_texture(_batches.spriteIds[_i], 0));
        vertex_delete_buffer(_batches.buffers[_i]);
    }
    _batches.spriteIds = [];
    _batches.buffers = [];
}

/// Append one camera-facing sprite quad to an open vertex buffer.
/// Anchored at bottom-centre (the "feet" sit at _x,_y,_z). _h is world-space height;
/// width follows the sprite's aspect ratio. _right/_up are the camera's world-space
/// right and up axes, taken from the view matrix. _col/_alpha tint the sprite.
/// The texture page auto-crops transparent borders, so the quad is shrunk to the
/// trimmed sub-rectangle (uvs[4..7]) to keep proportions exact.
/// _wStretch widens the quad without changing height (death-splat squash).
/// _flipX mirrors the sprite horizontally (swaps the left/right texture edges) -
/// used to turn a left-facing sprite to face the other way when it walks right.
function vb_billboard(_vb, _spr, _img, _x, _y, _z, _h, _right, _up, _col = c_white, _alpha = 1, _wStretch = 1, _flipX = false) {
    var sw  = sprite_get_width(_spr);
    var sh  = sprite_get_height(_spr);
    var w   = _h * sw / sh * _wStretch;
    var uvs = sprite_get_uvs(_spr, _img);
    var lx  = -w * 0.5 + (uvs[4] / sw) * w; // left edge of trimmed image, relative to centre
    var rx  = lx + uvs[6] * w;              // uvs[6] = trimmed width / original width
    var ty  = _h - (uvs[5] / sh) * _h;      // top edge, height above the feet
    var by  = ty - uvs[7] * _h;             // uvs[7] = trimmed height / original height
    var u0  = uvs[0], v0 = uvs[1], u1 = uvs[2], v1 = uvs[3];
    var ua  = _flipX ? u1 : u0;             // left geometry edge samples this u...
    var ub  = _flipX ? u0 : u1;             // ...right edge this one (swapped = mirror)

    // Two triangles: bottom-left, bottom-right, top-right / bottom-left, top-right, top-left.
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * by, _y + _right[1] * lx + _up[1] * by, _z + _right[2] * lx + _up[2] * by, _col, _alpha, ua, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * by, _y + _right[1] * rx + _up[1] * by, _z + _right[2] * rx + _up[2] * by, _col, _alpha, ub, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * ty, _y + _right[1] * rx + _up[1] * ty, _z + _right[2] * rx + _up[2] * ty, _col, _alpha, ub, v0);
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * by, _y + _right[1] * lx + _up[1] * by, _z + _right[2] * lx + _up[2] * by, _col, _alpha, ua, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * ty, _y + _right[1] * rx + _up[1] * ty, _z + _right[2] * rx + _up[2] * ty, _col, _alpha, ub, v0);
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * ty, _y + _right[1] * lx + _up[1] * ty, _z + _right[2] * lx + _up[2] * ty, _col, _alpha, ua, v0);
}

// ============================================================================
// Living title screen: an idle 3D checker plane (no spaces) that extends off
// camera, with Pikmin wandering across it and the occasional treasure convoy.
// Purely decorative - it never touches the rules engine (`game`); the menu GUI
// draws over it as normal. Built once (title_scene_create) and pumped each menu
// frame (title_scene_update) + drawn each menu frame (title_scene_draw).
// ============================================================================

/// Pick a random board set for the title backdrop, skipping the two boards whose
/// sky art is too dark/busy to sit behind the menu: 14 (Hills with Eyes and Teeth)
/// and 15 (Disco Dancefloor).
function title_random_set() {
    var _allowed = [];
    for (var _s = 1; _s <= 16; _s++) if (_s != 14 && _s != 15) array_push(_allowed, _s);
    return _allowed[irandom(array_length(_allowed) - 1)];
}

/// The treasure ids a given board set actually uses, so title convoys carry the
/// same loot the picked board would. Resolves the board's treasureSet (which is NOT
/// the same as its setNumber, and may be "all") via the board record, then collects
/// matching ids. Falls back to the whole catalogue if nothing matches.
function title_treasure_pool(_setNumber) {
    var _tset = "all";
    var _boards = global.boardData.boards;
    for (var _i = 0; _i < array_length(_boards); _i++) {
        if (_boards[_i].setNumber == _setNumber) { _tset = _boards[_i].treasureSet; break; }
    }
    var _pool = [];
    var _defs = global.treasureData.treasures;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_tset == "all" || _defs[_i].set == _tset) array_push(_pool, _defs[_i].id);
    }
    if (array_length(_pool) == 0) for (var _i = 0; _i < array_length(_defs); _i++) array_push(_pool, _defs[_i].id);
    return _pool;
}

/// Build the persistent title scene for one board set (_setNumber). Owns one frozen
/// checker plane, wider than the frame (side edges off-screen) and distance-faded so
/// the checker dissolves into the sky well before the horizon instead of stretching
/// to it. Themed to the set's ground palette, and its convoys carry that board's own
/// treasure set. Call ONCE - the buffer is never freed.
function title_scene_create(_setNumber = 1) {
    return {
        setNumber: _setNumber,               // drives the sky sprite ("_<n>"), ground palette AND treasure pool
        treasurePool: title_treasure_pool(_setNumber), // ids matching this board's treasureSet
        actors: [],                          // {kind:"wander"|"convoy", ...} crossing along world x
        spawnTimer: 20,                      // frames until the next lone wanderer
        convoyTimer: irandom_range(240, 480),// frames until the next treasure convoy (rare)
        bandTimer: irandom_range(700, 1400), // frames until the next bulbmin band (rarer still)
        // ~10560 wide, faded out between y=500..2600 so the checker dissolves just under the
        // (now low) horizon, leaving sky reaching well down the frame - past the title
        groundVB: build_ground(110, 84, 96, board_ground_palette(_setNumber), 0, 0, 500, 2600),
    };
}

/// Which way a Pikmin type's dedicated sprite faces (true = right, false = left), so
/// title billboards can be mirrored to face their travel direction. The two camera-
/// facing types are keyed off their flower bend: pink/winged bends right, white bends
/// left. Everything unlisted defaults to left (red, yellow, purple, rock, bulbmin).
function title_pik_faces_right(_typeId) {
    switch (_typeId) {
        case "blue": case "ice": case "winged": return true; // winged = the pink one
        default: return false;
    }
}

/// Pick a random Pikmin type id for the general crowd. Bulbmin are excluded here -
/// they only ever appear as their own dedicated travelling band (title_spawn_band).
function title_random_pik_type() {
    var _types = global.pikminData.types;
    var _id;
    do { _id = _types[irandom(array_length(_types) - 1)].id; } until (_id != "bulbmin");
    return _id;
}

/// The |world-x| at which an actor at depth _y is just past the frame's side edge,
/// so it spawns (and later exits) off-screen. Derived from the title camera: it
/// sits ~520 units behind the target and the horizontal half-FOV spans ~ x1.03 of
/// the ground distance; _pad adds a little slack (bigger for wide convoys).
function title_actor_edge(_y, _pad) {
    return (_y + 520) * 1.10 + _pad;
}

/// Spawn one lone Pikmin walking straight across the view (off one side to the
/// other) at a random depth, speed, and colour.
function title_spawn_wanderer(_ts) {
    var _dir = choose(-1, 1);
    var _y = random_range(-300, 380);        // close depth band: right up near the camera
    var _edge = title_actor_edge(_y, 90);    // spawn/exit x for this depth: just off the frame side
    array_push(_ts.actors, {
        kind: "wander",
        typeId: title_random_pik_type(),
        x: -_dir * _edge,
        y: _y,
        dir: _dir,
        edge: _edge,
        spd: random_range(1.3, 3.3),         // varied paces
        phase: random(6.283),                // bob offset so they don't hop in sync
    });
}

/// Spawn a treasure being hauled across by a little cluster of Pikmin. Normally a
/// slow mixed-colour haul; when _allWhite, it's the special set group - all white
/// Pikmin sprinting the pile across MUCH faster than an ordinary convoy.
function title_spawn_convoy(_ts, _allWhite = false) {
    var _dir = choose(-1, 1);
    var _n = irandom_range(4, 7);
    var _carriers = [];
    for (var _i = 0; _i < _n; _i++) {
        array_push(_carriers, {
            typeId: _allWhite ? "white" : title_random_pik_type(),
            ox: random_range(-36, 36),       // scattered around the pile
            oy: random_range(-24, 24),
            phase: random(6.283),
        });
    }
    var _y = random_range(-250, 300);
    var _edge = title_actor_edge(_y, 150);   // extra slack for the pile's spread
    array_push(_ts.actors, {
        kind: "convoy",
        treasureId: _ts.treasurePool[irandom(array_length(_ts.treasurePool) - 1)],
        x: -_dir * _edge,
        y: _y,
        dir: _dir,
        edge: _edge,
        spd: _allWhite ? random_range(2.6, 3.2) : random_range(0.7, 1.1), // whites haul at a sprint
        carriers: _carriers,
    });
}

/// Spawn the special bulbmin set group: exactly 5 bulbmin ambling across together,
/// carrying nothing. Same cluster structure as a convoy's carriers (field `carriers`),
/// but kind "band" so the draw pass skips the treasure pile.
function title_spawn_band(_ts) {
    var _dir = choose(-1, 1);
    var _carriers = [];
    repeat (5) {
        array_push(_carriers, {
            typeId: "bulbmin",
            ox: random_range(-42, 42),
            oy: random_range(-22, 22),
            phase: random(6.283),
        });
    }
    var _y = random_range(-250, 320);
    var _edge = title_actor_edge(_y, 130);
    array_push(_ts.actors, {
        kind: "band",
        x: -_dir * _edge,
        y: _y,
        dir: _dir,
        edge: _edge,
        spd: random_range(1.1, 1.6),         // a purposeful little pack
        carriers: _carriers,
    });
}

/// Advance the title scene one menu frame: spawn on cadence (capped), walk every
/// actor along its lane, and cull once it's fully off the far side.
function title_scene_update(_ts) {
    _ts.spawnTimer -= 1;
    if (_ts.spawnTimer <= 0 && array_length(_ts.actors) < 12) {
        title_spawn_wanderer(_ts);
        _ts.spawnTimer = irandom_range(35, 85);
    }
    _ts.convoyTimer -= 1;
    if (_ts.convoyTimer <= 0) {
        title_spawn_convoy(_ts, random(1) < 0.22); // ~1 in 5 convoys is the all-white sprint
        _ts.convoyTimer = irandom_range(520, 900);
    }
    _ts.bandTimer -= 1;
    if (_ts.bandTimer <= 0) {
        title_spawn_band(_ts);
        _ts.bandTimer = irandom_range(900, 1700);
    }
    for (var _i = array_length(_ts.actors) - 1; _i >= 0; _i--) {
        var _a = _ts.actors[_i];
        _a.x += _a.dir * _a.spd;
        // cull once it has crossed to the exit side and passed its own off-screen edge
        if (_a.x * _a.dir > 0 && abs(_a.x) > _a.edge) array_delete(_ts.actors, _i, 1);
    }
}

/// Draw the title scene: submit the checker plane, then billboard every actor
/// (with a soft ground shadow + idle bob). Mirrors the game's Draw_0 pass order
/// - cutout sprites depth-tested, translucent shadows last. `_viewMat` supplies
/// the camera's right/up axes for the billboards. `_frameTick` drives the bob.
function title_scene_draw(_ts, _viewMat, _frameTick) {
    gpu_set_ztestenable(true);
    gpu_set_zwriteenable(true);
    matrix_set(matrix_world, matrix_build_identity());

    // ground: distance-faded, so alpha-BLEND it into the sky (no cutout alpha-test,
    // which would hard-clip the fade). Sky sprite is already in the framebuffer behind.
    gpu_set_alphatestenable(false);
    vertex_submit(_ts.groundVB, pr_trianglelist, -1);

    // actors: alpha-tested cutout billboards
    gpu_set_alphatestenable(true);
    gpu_set_alphatestref(128);

    var _camRight = [_viewMat[0], _viewMat[4], _viewMat[8]];
    var _camUp    = [_viewMat[1], _viewMat[5], _viewMat[9]];
    if (_camUp[2] < 0) { _camUp[0] = -_camUp[0]; _camUp[1] = -_camUp[1]; _camUp[2] = -_camUp[2]; }

    var _batches = sprite_batches_create();
    var _overlayVB = vertex_create_buffer();   // shadow discs (translucent, no alpha-test)
    vertex_begin(_overlayVB, vformat_3d());

    for (var _i = 0; _i < array_length(_ts.actors); _i++) {
        var _a = _ts.actors[_i];
        // this projection mirrors world x, so dir < 0 means the actor crosses to
        // screen-right. Flip a sprite whenever its authored facing disagrees with travel.
        var _travelRight = (_a.dir < 0);
        if (_a.kind == "wander") {
            var _bob = abs(sin(_frameTick * 0.12 + _a.phase)) * 5;
            vb_disc(_overlayVB, _a.x, _a.y, 0.5, 7 - _bob * 0.4, make_color_rgb(24, 20, 16), 0.4);
            var _spr = data_sprite(pikmin_type_get(_a.typeId), sprFRIEND);
            var _tint = (_spr == sprFRIEND) ? pikmin_tint(_a.typeId) : c_white;
            var _wflip = (title_pik_faces_right(_a.typeId) != _travelRight);
            vb_billboard(sprite_batches_vb(_batches, _spr), _spr, 0, _a.x, _a.y, _bob, 34, _camRight, _camUp, _tint, 1, 1, _wflip);
        } else {
            // a convoy hauls a treasure pile; a bulbmin band travels empty
            if (_a.kind == "convoy") {
                var _tspr = data_sprite(treasure_def_get(_a.treasureId), sprFRIEND);
                vb_disc(_overlayVB, _a.x, _a.y, 0.5, 22, make_color_rgb(24, 20, 16), 0.28);
                vb_billboard(sprite_batches_vb(_batches, _tspr), _tspr, 0, _a.x, _a.y - 4, 1, 46, _camRight, _camUp, c_white, 1);
            }
            for (var _c = 0; _c < array_length(_a.carriers); _c++) {
                var _cr = _a.carriers[_c];
                var _cbob = abs(sin(_frameTick * 0.14 + _cr.phase)) * 4;
                var _cx2 = _a.x + _cr.ox, _cy2 = _a.y + _cr.oy;
                vb_disc(_overlayVB, _cx2, _cy2, 0.5, 6, make_color_rgb(24, 20, 16), 0.4);
                var _cspr = data_sprite(pikmin_type_get(_cr.typeId), sprFRIEND);
                var _ctint = (_cspr == sprFRIEND) ? pikmin_tint(_cr.typeId) : c_white;
                var _cflip = (title_pik_faces_right(_cr.typeId) != _travelRight);
                vb_billboard(sprite_batches_vb(_batches, _cspr), _cspr, 0, _cx2, _cy2, _cbob, 30, _camRight, _camUp, _ctint, 1, 1, _cflip);
            }
        }
    }

    sprite_batches_flush(_batches);

    gpu_set_alphatestenable(false);
    vertex_end(_overlayVB);
    vertex_submit(_overlayVB, pr_trianglelist, -1);
    vertex_delete_buffer(_overlayVB);

    gpu_set_ztestenable(false);
    gpu_set_zwriteenable(false);
    matrix_set(matrix_world, matrix_build_identity());
}
