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
function build_ground(_cols, _rows, _tile, _palette) {
    var vb = vertex_create_buffer();
    vertex_begin(vb, vformat_3d());
    var x0 = -(_cols * _tile) * 0.5;
    var y0 = -(_rows * _tile) * 0.5;
    var _n = array_length(_palette);
    for (var i = 0; i < _cols; i++) {
        for (var j = 0; j < _rows; j++) {
            var c = (_n >= 4) ? _palette[(i mod 2) + (j mod 2) * 2] : _palette[(i + j) mod _n];
            var xa = x0 + i * _tile;
            var ya = y0 + j * _tile;
            var xb = xa + _tile;
            var yb = ya + _tile;
            vb_vertex(vb, xa, ya, 0, c, 1, 0, 0);
            vb_vertex(vb, xb, ya, 0, c, 1, 1, 0);
            vb_vertex(vb, xb, yb, 0, c, 1, 1, 1);
            vb_vertex(vb, xa, ya, 0, c, 1, 0, 0);
            vb_vertex(vb, xb, yb, 0, c, 1, 1, 1);
            vb_vertex(vb, xa, yb, 0, c, 1, 0, 1);
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
function vb_tile_sprite(_vb, _spr, _img, _x, _y, _z, _size, _col, _alpha) {
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
function vb_billboard(_vb, _spr, _img, _x, _y, _z, _h, _right, _up, _col = c_white, _alpha = 1, _wStretch = 1) {
    var sw  = sprite_get_width(_spr);
    var sh  = sprite_get_height(_spr);
    var w   = _h * sw / sh * _wStretch;
    var uvs = sprite_get_uvs(_spr, _img);
    var lx  = -w * 0.5 + (uvs[4] / sw) * w; // left edge of trimmed image, relative to centre
    var rx  = lx + uvs[6] * w;              // uvs[6] = trimmed width / original width
    var ty  = _h - (uvs[5] / sh) * _h;      // top edge, height above the feet
    var by  = ty - uvs[7] * _h;             // uvs[7] = trimmed height / original height
    var u0  = uvs[0], v0 = uvs[1], u1 = uvs[2], v1 = uvs[3];

    // Two triangles: bottom-left, bottom-right, top-right / bottom-left, top-right, top-left.
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * by, _y + _right[1] * lx + _up[1] * by, _z + _right[2] * lx + _up[2] * by, _col, _alpha, u0, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * by, _y + _right[1] * rx + _up[1] * by, _z + _right[2] * rx + _up[2] * by, _col, _alpha, u1, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * ty, _y + _right[1] * rx + _up[1] * ty, _z + _right[2] * rx + _up[2] * ty, _col, _alpha, u1, v0);
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * by, _y + _right[1] * lx + _up[1] * by, _z + _right[2] * lx + _up[2] * by, _col, _alpha, u0, v1);
    vb_vertex(_vb, _x + _right[0] * rx + _up[0] * ty, _y + _right[1] * rx + _up[1] * ty, _z + _right[2] * rx + _up[2] * ty, _col, _alpha, u1, v0);
    vb_vertex(_vb, _x + _right[0] * lx + _up[0] * ty, _y + _right[1] * lx + _up[1] * ty, _z + _right[2] * lx + _up[2] * ty, _col, _alpha, u0, v0);
}
