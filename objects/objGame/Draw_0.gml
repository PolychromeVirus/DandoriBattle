// menu mode: the main title screen shows a living 3D checker field (camera set in Step);
// every other menu screen keeps the plain backdrop. The menu GUI draws over both.
if (mode != "playing") {
    if (menuScreen == "main") {
        // sky: the board set's background sprite drawn full-screen behind the field, so the
        // checker recedes to a real horizon (same screen-space 2D pass the playing scene uses).
        draw_clear(make_color_rgb(150, 200, 235)); // fallback sky if the sprite is missing
        var _tbg = asset_get_index("_" + string(titleScene.setNumber));
        if (sprite_exists(_tbg)) {
            var _tsw = window_get_width(), _tsh = window_get_height();
            var _tiw = sprite_get_width(_tbg), _tih = sprite_get_height(_tbg);
            var _tcov = max(_tsw / _tiw, _tsh / _tih);        // COVER fit: fill, preserve aspect, crop overflow
            var _tdw = _tiw * _tcov, _tdh = _tih * _tcov;
            var _tdx = (_tsw - _tdw) * 0.5, _tdy = (_tsh - _tdh) * 0.5;
            gpu_set_ztestenable(false);
            gpu_set_zwriteenable(false);
            gpu_set_alphatestenable(false);
            matrix_set(matrix_world, matrix_build_identity());
            matrix_set(matrix_view, matrix_build_lookat(_tsw * 0.5, _tsh * 0.5, -10, _tsw * 0.5, _tsh * 0.5, 0, 0, 1, 0));
            matrix_set(matrix_projection, matrix_build_projection_ortho(_tsw, -_tsh, 1, 100)); // -h flips y to pixel space
            draw_sprite_stretched_ext(_tbg, 0, _tdx, _tdy, _tdw, _tdh, c_white, 1);
            camera_apply(camera); // restore the 3D title camera EXACTLY (matrix_set drops GM's surface y-flip)
        }
        title_scene_draw(titleScene, viewMat, frameTick);
    } else {
        draw_clear(make_color_rgb(38, 46, 40));
    }
    exit;
}

// --- backdrop: the board set's background image (sprite "_<boardNumber>") drawn as a
// --- flat full-screen sky behind the 3D scene. Screen-space 2D pass (own ortho matrices),
// --- then restore the 3D camera. Falls back to a plain clear if the sprite is missing. ---
draw_clear(make_color_rgb(18, 20, 26));
var _bgSpr = asset_get_index("_" + string(boardDef.setNumber));
if (sprite_exists(_bgSpr)) {
    var _sw = window_get_width(), _sh = window_get_height();
    // COVER fit: fill the screen, preserve aspect, crop the overflow (no stretching)
    var _iw = sprite_get_width(_bgSpr), _ih = sprite_get_height(_bgSpr);
    var _cov = max(_sw / _iw, _sh / _ih);
    var _dw = _iw * _cov, _dh = _ih * _cov;
    var _dx = (_sw - _dw) * 0.5, _dy = (_sh - _dh) * 0.5;
    gpu_set_ztestenable(false);
    gpu_set_zwriteenable(false);
    gpu_set_alphatestenable(false);
    matrix_set(matrix_world, matrix_build_identity());
    matrix_set(matrix_view, matrix_build_lookat(_sw * 0.5, _sh * 0.5, -10, _sw * 0.5, _sh * 0.5, 0, 0, 1, 0));
    matrix_set(matrix_projection, matrix_build_projection_ortho(_sw, -_sh, 1, 100)); // -h flips y to pixel space
    draw_sprite_stretched_ext(_bgSpr, 0, _dx, _dy, _dw, _dh, c_white, 1);
    camera_apply(camera); // restore the 3D camera EXACTLY (matrix_set drops GM's surface y-flip -> tilted board)
}

// the tutorial's clean lesson board strips ALL table dressing (onions, decks, hordes, hands). Keyed
// on the STABLE `compactBoard` flag - NOT (tutorial != undefined), which flips off the instant the
// tutorial ends and pops the dressing in. This is a tutorial-only clean view, NOT a solo thing:
// adventure/co-op keep their own onion + gather deck (only P2's onion is a real 2-player artifact).
var _stripDressing = compactBoard;
presMoving = false; // set true below while any pikmin or homing pile is still sliding
// enemies hold their feeding crouch through the bite, easing back up while ghosts fade
if (game.jumpCue == "enemy" || game.jumpCue == "swift") { biteT = 1; biteKind = game.jumpCue; }
else biteT = max(0, biteT - 0.022);

// --- combat "attack scene" ------------------------------------------------------------
// The whole strike run (swift wind-up -> pikmin damage -> enemy bite -> red 2nd strike)
// reads as ONE scene: the active player's attackers LEAP onto their foe at a random spot
// and cling there through every beat, dropping straight off at the end or the instant the
// foe dies. Derived from the beat queue so it spans the silent damage beats too. The enemy
// loop stashes each foe's live body position into _enemyVis (keyed lane_idx) so the
// clinging pikmin ride its dip (or its crush-leap). Purely cosmetic - vx/vy never move, so
// the beat pump never mistakes a clinger for a walker (which would softlock resolution).
var _combatBeats = ["jumpSwift", "swift", "jumpPik", "pik", "jumpEnemy", "enemy", "jumpRed", "post"];
var _frontBeat = (array_length(game.resolveQueue) > 0) ? game.resolveQueue[0] : "";
var _atkSection = ((is_string(_frontBeat) && arr_has(_combatBeats, _frontBeat)) || arr_has(_combatBeats, game.jumpCue)) && global.expRules.anims;
var _enemyVis = {};
var _latchCount = 0;     // clinging attackers this frame
var _structForce = 0;    // pikmin smashing a wall/emitter this frame - both feed the attack-SFX layers
var _atkSpaceSet = {};   // "lane_idx" -> {lane,idx} of spaces with live combat, so swipes emit from there

gpu_set_ztestenable(true);
gpu_set_zwriteenable(true);
gpu_set_alphatestenable(true);
gpu_set_alphatestref(128);

matrix_set(matrix_world, matrix_build_identity());

// --- grass + board tiles ---
vertex_submit(groundVB, pr_trianglelist, -1);
vertex_submit(tileVB, pr_trianglelist, -1);

// camera axes straight out of the view matrix
var _camRight = [viewMat[0], viewMat[4], viewMat[8]];
var _camUp    = [viewMat[1], viewMat[5], viewMat[9]];
var _camFwd   = [viewMat[2], viewMat[6], viewMat[10]];
if (_camUp[2] < 0) { _camUp[0] = -_camUp[0]; _camUp[1] = -_camUp[1]; _camUp[2] = -_camUp[2]; }

var _spriteBatches = sprite_batches_create();
var _fxBatches = sprite_batches_create();   // death FX - flushed with alpha BLENDING (fades), not cutout
var _overlayVB = vertex_create_buffer();   // rings, bars, highlights (drawn without alpha-test)
vertex_begin(_overlayVB, vformat_3d());
var _labels = [];

// --- hover / selection highlights ---
if (hoverKind == "space") {
    if (pendingCard != undefined && pendingCard.effectId == "storm" && pendingCard.stage == "space") {
        // Lightning Storm strikes a 2x2 block anchored here (clamped like the engine):
        // preview all four tiles so the click isn't a guess
        var _stL = clamp(hoverLane, 0, board.laneCount - 2);
        var _stI = clamp(hoverIdx, 0, 5);
        for (var _so = 0; _so < 4; _so++) {
            var _hp2 = board_space_xy(board, _stL + (_so mod 2), _stI + (_so div 2));
            vb_tile(_overlayVB, _hp2[0], _hp2[1], 1.72, TILE_W + 8, TILE_H + 8, make_color_rgb(255, 232, 90), 0.3);
        }
    } else {
        var _hp2 = board_space_xy(board, hoverLane, hoverIdx);
        vb_tile(_overlayVB, _hp2[0], _hp2[1], 1.72, TILE_W + 8, TILE_H + 8, c_white, 0.28);
    }
} else if (hoverKind == "home") {
    vb_tile(_overlayVB, 0, board_home_y(board, hoverIdx), 1.72, board.laneCount * (TILE_W + LANE_GAP), TILE_H, c_white, 0.2);
}
if (selSrc != undefined) {
    if (selSrc.kind == "space") {
        var _sp2 = board_space_xy(board, selSrc.lane, selSrc.idx);
        vb_tile(_overlayVB, _sp2[0], _sp2[1], 1.74, TILE_W + 8, TILE_H + 8, make_color_rgb(255, 215, 90), 0.35);
    } else {
        vb_tile(_overlayVB, 0, board_home_y(board, game.activePlayer), 1.74, board.laneCount * (TILE_W + LANE_GAP), TILE_H, make_color_rgb(255, 215, 90), 0.25);
    }
}

// spaces past the board's midpoint (centerRow) are on the OPPONENT's half - fixture decals there
// rotate 180deg to face that player. Solo/adventure boards have no opponent, so nothing flips.
var _oppHalf = game.solo ? 100000 : board.centerRow;

// --- flat element decals on hazard spaces ---
for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
    var _spaces = board.lanes[_laneIdx].spaces;
    for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
        var _space = _spaces[_spaceIdx];
        if (_space.kind != "hazard" || _space.hazard == "chasm") continue;
        var _spacePos = board_space_xy(board, _laneIdx, _spaceIdx);
        var _hazSpr = element_sprite(_space.hazard);
        if (_hazSpr != -1) {
            vb_tile_sprite(sprite_batches_vb(_spriteBatches, _hazSpr), _hazSpr, 0, _spacePos[0], _spacePos[1], 1.6, 52, c_white, 1, _spaceIdx > _oppHalf);
        }
    }
}

// carry-loop SFX: piles moving THIS frame want a looping carry sound (started/stopped in the reconcile below)
var _carryNow = {};
var _carryPos = {};   // same keys -> [wx,wy] of the pile, so the loop's emitter follows it across the board
// departing-pile positions keyed "d"+lane, so the pikmin that banked them can escort them home
var _departVis = {};
// --- treasures (top card sprite + value/weight label; hidden while a boss guards the pile) ---
for (var _ti = 0; _ti < array_length(game.treasures); _ti++) {
    var _t = game.treasures[_ti];
    if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
    var _topDef = treasure_def_get(_t.cards[array_length(_t.cards) - 1]);
    var _tPos = board_space_xy(board, _t.lane, _t.idx);
    // the pile slides between spaces at a constant speed as it's carried (render-only).
    // A normal haul lumbers (heavy); an overpowering RUSH (engine sets _t.rushMove)
    // zips along near pikmin walking pace. The hint clears once the pile arrives.
    if (!variable_struct_exists(_t, "vx")) { _t.vx = _tPos[0]; _t.vy = _tPos[1]; }
    var _pd = point_distance(_t.vx, _t.vy, _tPos[0], _tPos[1]);
    var _pileSpd = (variable_struct_exists(_t, "rushMove") && _t.rushMove) ? 3.8 : 2.6;
    _t.vmoving = (_pd > 0.5);   // riders read this to move locked to the pile
    _t.vspdCur = _pileSpd;
    if (_t.vmoving) { _carryNow[$ "t" + string(_t.lane)] = carry_asset_for(_t.lane, _t.idx); _carryPos[$ "t" + string(_t.lane)] = [_t.vx, _t.vy - 6]; }
    if (_pd > 0) {
        var _ps = min(_pd, _pileSpd);
        _t.vx += (_tPos[0] - _t.vx) / _pd * _ps;
        _t.vy += (_tPos[1] - _t.vy) / _pd * _ps;
        if (_pd <= _pileSpd) _t.rushMove = false; // arrived - drop the rush hint
    } else {
        _t.rushMove = false;
    }
    var _tSpr = data_sprite(_topDef, sprFRIEND);
    vb_billboard(sprite_batches_vb(_spriteBatches, _tSpr), _tSpr, 0, _t.vx, _t.vy - 6, 1, 40, _camRight, _camUp, c_white, 1);
    var _pileVal = 0;
    for (var _c = 0; _c < array_length(_t.cards); _c++) _pileVal += treasure_def_get(_t.cards[_c]).value;
    array_push(_labels, { labelX: _t.vx, labelY: _t.vy - 6, labelZ: 46, labelText: string(_pileVal) + "p (w" + string(_topDef.weight) + ")" });
    if (_pd > 1) presMoving = true;
}

// --- departing piles: a collected pile slides from the board edge all the way to its
// --- owner's HOME strip, then banks + scores (game_finalize_departing) on arrival ---
for (var _di = array_length(game.departing) - 1; _di >= 0; _di--) {
    var _dp = game.departing[_di];
    if (!global.expRules.anims) { game_finalize_departing(game, _dp); continue; } // instant bank
    var _dFrom = board_space_xy(board, _dp.lane, _dp.fromIdx);
    var _dHomeY = board_home_y(board, _dp.playerIdx);
    if (!variable_struct_exists(_dp, "vx")) { _dp.vx = _dFrom[0]; _dp.vy = _dFrom[1]; }
    var _dpd = point_distance(_dp.vx, _dp.vy, _dFrom[0], _dHomeY);
    var _dSpr = data_sprite(treasure_def_get(_dp.cards[array_length(_dp.cards) - 1]), sprFRIEND);
    if (_dpd > 2.6) {
        var _dps = min(_dpd, 2.6);
        _dp.vx += (_dFrom[0] - _dp.vx) / _dpd * _dps;
        _dp.vy += (_dHomeY - _dp.vy) / _dpd * _dps;
        presMoving = true;
        _carryNow[$ "d" + string(_dp.lane)] = asset_get_index("carry1");   // hauling home
        _carryPos[$ "d" + string(_dp.lane)] = [_dp.vx, _dp.vy - 6];
        _departVis[$ "d" + string(_dp.lane)] = { x: _dp.vx, y: _dp.vy, arrived: false }; // escorts follow this
        vb_billboard(sprite_batches_vb(_spriteBatches, _dSpr), _dSpr, 0, _dp.vx, _dp.vy - 6, 1, 40, _camRight, _camUp, c_white, 1);
        array_push(_labels, { labelX: _dp.vx, labelY: _dp.vy - 6, labelZ: 46, labelText: string(_dp.total) + "p" });
    } else {
        // arrived home: ease the pile out with a fade instead of blinking, then bank. The
        // escorting pikmin peel off to their home slots the moment it lands (arrived:true).
        _departVis[$ "d" + string(_dp.lane)] = { x: _dp.vx, y: _dp.vy, arrived: true };
        var _fade = variable_struct_exists(_dp, "fadeT") ? _dp.fadeT : 1;
        _fade = max(0, _fade - 0.012); // slow, clearly-visible dissolve into the onion (~1.4s)
        _dp.fadeT = _fade;
        if (_fade > 0) {
            presMoving = true; // hold the turn until it finishes fading (the bank applies only then)
            // MUST draw in the alpha-BLENDING batch - the cutout batch would just snap it out at ~50%
            vb_billboard(sprite_batches_vb(_fxBatches, _dSpr), _dSpr, 0, _dp.vx, _dp.vy - 6, 1, 40, _camRight, _camUp, c_white, _fade);
        } else {
            // fully absorbed: the onion "picks it up" (import a sound named sfxOnionCollect), THEN it banks
            var _os = asset_get_index("sfxOnionCollect");
            if (_os != -1) audio_play_sound_on(emitter_home(_dp.playerIdx), _os, false, 10, 1, 0, random_range(0.97, 1.03));
            game_finalize_departing(game, _dp); // score ticks up now, as it vanishes
        }
    }
}
// reconcile carry loops: start one for each pile now moving, stop any whose pile stopped/arrived
if (batchRemaining <= 0) {
    var _cKeys = variable_struct_get_names(_carryNow);
    for (var _ck = 0; _ck < array_length(_cKeys); _ck++) {
        var _k = _cKeys[_ck];
        var _cpos = variable_struct_exists(_carryPos, _k) ? _carryPos[$ _k] : [0, 0];
        var _cem = emitter_moving(_k, _cpos[0], _cpos[1]); // follow the pile across the board each frame
        if (!variable_struct_exists(carrySnds, _k) || carrySnds[$ _k] == -1 || !audio_is_playing(carrySnds[$ _k])) {
            var _cAsset = _carryNow[$ _k];
            carrySnds[$ _k] = (_cAsset != -1) ? audio_play_sound_on(_cem, _cAsset, true, 5, 1, 0, random_range(0.92, 1.08)) : -1;
        }
    }
    var _cHeld = variable_struct_get_names(carrySnds);
    for (var _hk = 0; _hk < array_length(_cHeld); _hk++) {
        var _k2 = _cHeld[_hk];
        if (!variable_struct_exists(_carryNow, _k2)) {
            if (carrySnds[$ _k2] != -1 && audio_is_playing(carrySnds[$ _k2])) audio_stop_sound(carrySnds[$ _k2]);
            variable_struct_remove(carrySnds, _k2);
        }
    }
} else if (variable_struct_names_count(carrySnds) > 0) {
    carry_stop_all();
}

// --- built structures: wall = standing plane, bridge = plank, emitter = element
// --- decal. No name labels; HP shows as a green circle (drawn in the HUD pass).
var _displayStructs = [];
for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
    var _spaces = board.lanes[_laneIdx].spaces;
    for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
        var _struct = _spaces[_spaceIdx].structure;
        if (_struct == undefined) continue;
        var _sDef = hazard_def_get(_struct.structId);
        var _sPos = board_space_xy(board, _laneIdx, _spaceIdx);
        if (_sDef.type == "wall") {
            // variant colours: stone / silk web / translucent crystal / electric / ice
            var _wCol = make_color_rgb(142, 136, 126);
            var _wAlpha = 1;
            switch (_struct.structId) {
                case "arachnodeweb": _wCol = make_color_rgb(228, 224, 205); _wAlpha = 0.85; break;
                case "crystalwall":  _wCol = make_color_rgb(190, 235, 245); _wAlpha = 0.65; break;
                case "electricwall": _wCol = make_color_rgb(235, 212, 74);  break;
                case "icewall":      _wCol = make_color_rgb(150, 205, 240); break;
            }
            vb_wall(_overlayVB, _sPos[0], _sPos[1], TILE_W - 10, 24, 14, _wCol, _wAlpha);
            array_push(_displayStructs, { sx: _sPos[0], sy: _sPos[1], sz: 40, hp: _struct.curHp });
        } else if (_sDef.type == "bridge") {
            if (_struct.structId == "climbingstick") {
                // a thin plank along the travel direction - a narrow bridge, not a pole
                vb_tile(_overlayVB, _sPos[0], _sPos[1], 1.66, 10, TILE_H - 8, make_color_rgb(168, 126, 70), 1);
                array_push(_displayStructs, { sx: _sPos[0], sy: _sPos[1], sz: 24, hp: _struct.curHp });
            } else if (_struct.structId == "tunnel") {
                // dark slab with a black mouth (pikmin-only passage)
                vb_tile(_overlayVB, _sPos[0], _sPos[1], 1.66, TILE_W - 12, TILE_H - 12, make_color_rgb(84, 78, 74), 1);
                vb_disc(_overlayVB, _sPos[0], _sPos[1], 1.68, 16, make_color_rgb(18, 16, 15), 1);
                array_push(_displayStructs, { sx: _sPos[0], sy: _sPos[1], sz: 24, hp: _struct.curHp });
            } else {
                vb_tile(_overlayVB, _sPos[0], _sPos[1], 1.66, TILE_W - 12, TILE_H - 12, make_color_rgb(152, 106, 58), 1);
                array_push(_displayStructs, { sx: _sPos[0], sy: _sPos[1], sz: 24, hp: _struct.curHp });
            }
        } else { // emitter: its element decal IS the visual
            if (_sDef.element != "") {
                var _eSpr = element_sprite(_sDef.element);
                if (_eSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _eSpr), _eSpr, 0, _sPos[0], _sPos[1], 1.62, 44, c_white, 1, _spaceIdx > _oppHalf);
            }
            array_push(_displayStructs, { sx: _sPos[0], sy: _sPos[1], sz: 28, hp: _struct.curHp });
        }
    }
}

// --- Bomb Rock / Boulder telegraph: pulsing white-hot ring on the target space ---
if (game.bombCue != undefined) {
    var _bcPos = board_space_xy(board, game.bombCue.lane, game.bombCue.idx);
    var _bcp = abs(dsin(resolveHold * 32));
    vb_disc(_overlayVB, _bcPos[0], _bcPos[1], 1.78, 20 + _bcp * 14, c_white, 0.3 + 0.45 * _bcp);
}

// --- mines: dark disc decal, red once armed, with pass-damage counter ---
for (var _mi = 0; _mi < array_length(game.mines); _mi++) {
    var _mn = game.mines[_mi];
    var _mPos = board_space_xy(board, _mn.lane, _mn.idx);
    var _armed = (_mn.dmg >= 10);
    vb_disc(_overlayVB, _mPos[0] - TILE_W * 0.5 + 14, _mPos[1] - TILE_H * 0.5 + 14, 1.77, 9, _armed ? make_color_rgb(220, 40, 30) : make_color_rgb(40, 36, 34), 0.95);
    array_push(_labels, { labelX: _mPos[0] - TILE_W * 0.5 + 14, labelY: _mPos[1] - TILE_H * 0.5 + 14, labelZ: 14, labelText: _armed ? "ARMED" : string(_mn.dmg) + "/10" });
}

// --- pikpik carrot decoys: stand on the space like a pikmin (owner-side offset,
// --- shadow disc), with a small hp label ---
for (var _di = 0; _di < array_length(game.decoys); _di++) {
    var _dc = game.decoys[_di];
    var _dPos = board_space_xy(board, _dc.lane, _dc.idx);
    var _dx2 = _dPos[0] + TILE_W * 0.5 - 18;
    var _dy2 = _dPos[1] + ((_dc.playerIdx == 0) ? -16 : 16);
    vb_disc(_overlayVB, _dx2, _dy2, 1.68, 9, player_shadow(_dc.playerIdx), 0.5);
    vb_billboard(sprite_batches_vb(_spriteBatches, sprPikpikBundle), sprPikpikBundle, 0, _dx2, _dy2, 1, 34, _camRight, _camUp, c_white, 1);
    array_push(_labels, { labelX: _dx2, labelY: _dy2, labelZ: 38, labelText: string(_dc.hp) });
}

// --- spray markers: the item token printed as a flat decal on the space ---
for (var _si = 0; _si < array_length(game.sprays); _si++) {
    var _spray = game.sprays[_si];
    if (variable_struct_exists(_spray, "popped") && _spray.popped) continue; // ignited - tag gone
    var _spPos = board_space_xy(board, _spray.lane, _spray.idx);
    // spicy for now; bitter once that card exists (_spray.sprayType)
    var _sprayTok = (variable_struct_exists(_spray, "sprayType") && _spray.sprayType == "bitter") ? TokBitter : TokSpicy;
    vb_tile_sprite(sprite_batches_vb(_spriteBatches, _sprayTok), _sprayTok, 0, _spPos[0] + TILE_W * 0.5 - 11, _spPos[1] - TILE_H * 0.5 + 11, 1.78, 19, c_white, 1);
}

// --- enemies: lane enemies + treasure bosses, one display path.
// --- Each enemy's CARD becomes its tile face (so no name labels needed).
// During the day cinematic ONLY the newly-spawned enemies (justSpawned) are hidden
// through the flash + walk, then revealed one at a time (_cineReveal); survivors and
// bosses stay on screen the whole time.
var _cineActive = (dayCine != undefined);
var _cineReveal = (_cineActive && dayCine.phase == "reveal") ? dayCine.revealN : 0;
var _newOrder = 0;
var _displayEnemies = [];
for (var _laneIdx = 0; _laneIdx < board.laneCount; _laneIdx++) {
    var _spaces = board.lanes[_laneIdx].spaces;
    for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
        var _enemy = _spaces[_spaceIdx].enemy;
        if (_enemy == undefined) continue;
        if (_cineActive && variable_struct_exists(_enemy, "justSpawned") && _enemy.justSpawned) {
            var _eShown = (_newOrder < _cineReveal); _newOrder += 1;
            if (!_eShown) continue; // fresh arrival still hidden this frame
        }
        var _ePos = board_space_xy(board, _laneIdx, _spaceIdx);
        var _cardSpr = card_sprite_get(card_enemy_alias(_enemy.enemyDefId, boardDef.setNumber));
        if (_cardSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _cardSpr), _cardSpr, 0, _ePos[0], _ePos[1], 1.55, TILE_W, enemy_card_tint(_enemy), 1, _spaceIdx > _oppHalf);
        array_push(_displayEnemies, { inst: _enemy, ex: _ePos[0], ey: _ePos[1], el: _laneIdx, eidx: _spaceIdx, hasCard: (_cardSpr != -1) });
    }
}
for (var _ti = 0; _ti < array_length(game.treasures); _ti++) {
    var _t = game.treasures[_ti];
    if (_t.boss == undefined) continue;
    var _bPos = board_space_xy(board, _t.lane, _t.idx);
    var _cardSpr = card_sprite_get(card_enemy_alias(_t.boss.enemyDefId, boardDef.setNumber));
    if (_cardSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _cardSpr), _cardSpr, 0, _bPos[0], _bPos[1], 1.55, TILE_W, enemy_card_tint(_t.boss), 1, _t.idx > _oppHalf);
    array_push(_displayEnemies, { inst: _t.boss, ex: _bPos[0], ey: _bPos[1] + 16, el: _t.lane, eidx: _t.idx, hasCard: (_cardSpr != -1) });
}
for (var _ei = 0; _ei < array_length(_displayEnemies); _ei++) {
    var _de = _displayEnemies[_ei];
    var _enemyDef = enemy_def_get(_de.inst.enemyDefId);
    var _bbHeight = clamp(36 + _enemyDef.hp * 1.6, 36, 90);
    _de.hudZ = 1 + _bbHeight + 12;
    var _bodySpr = data_sprite(_enemyDef, sprFRIEND);
    var _bodyTint = (_bodySpr == sprFRIEND) ? make_color_rgb(150, 84, 72) : c_white;
    // ground shadow so the body reads as standing ON the board
    vb_disc(_overlayVB, _de.ex, _de.ey, 1.67, _bbHeight * 0.30, make_color_rgb(24, 20, 16), 0.35);
    // enemy attack beat: the retaliators (engaged, alive, not stunned, not an
    // already-struck swift, packing damage) SINK into the ground and shake - leaning
    // down to eat - with the bite landing while they're down
    var _jz = 1;
    var _jsx = 0;
    var _sink = 0;
    var _isSwift = (_enemyDef.attackElement == "swift");
    var _isCrush = (_enemyDef.attackElement == "crush");
    var _canBite = !_de.inst.dead && _enemyDef.damage > 0
        && !(variable_struct_exists(_de.inst, "stunned") && _de.inst.stunned > 0);
    var _hasBitten = (variable_struct_exists(_de.inst, "attacked") && _de.inst.attacked);
    var _isBoom = (_enemyDef.attackElement == "explosive");
    var _engaged = (array_length(game_tokens_at(game, game.activePlayer, { kind: "space", lane: _de.el, idx: _de.eidx })) > 0);
    // wind-up: swift enemies crouch in THEIR section, everyone else in the enemy
    // section - EXCEPT explosives (strobe instead) and crush foes (they LEAP, below)
    if (_canBite && !_hasBitten && !_isBoom && !_isCrush
        && ((game.jumpCue == "swift" && _isSwift) || (game.jumpCue == "enemy" && !_isSwift))
        && _engaged) {
        _sink = min(clamp(resolveHold / 34, 0, 1) * 2, 1); // lean down over the first half, stay down
    } else if (biteT > 0 && _canBite && !_isCrush && _hasBitten && !_isBoom && (_isSwift == (biteKind == "swift"))) {
        _sink = biteT; // bite landed - keep chewing/shaking, easing back up as the ghosts fade
    }
    // explosive telegraph: anything about to blow (engaged OR merely in + range of the
    // active player's pikmin) strobes white through the enemy wind-up
    if (_isBoom && game.jumpCue == "enemy" && _canBite && !_hasBitten) {
        var _bInRange = false;
        var _boffs = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
        for (var _bo = 0; _bo < 5 && !_bInRange; _bo++) {
            var _bl2 = _de.el + _boffs[_bo][0];
            var _bi2 = _de.eidx + _boffs[_bo][1];
            if (_bl2 < 0 || _bl2 >= board.laneCount || _bi2 < 0 || _bi2 > 6) continue;
            if (array_length(game_tokens_at(game, game.activePlayer, { kind: "space", lane: _bl2, idx: _bi2 })) > 0) _bInRange = true;
        }
        if (_bInRange) {
            // tint is multiplicative (can't whiten past the texture), so strobe toward
            // danger-red and pulse a white-hot ring at its feet
            var _bp = abs(dsin(resolveHold * 32));
            _bodyTint = merge_color(_bodyTint, make_color_rgb(255, 84, 42), 0.25 + 0.6 * _bp);
            vb_disc(_overlayVB, _de.ex, _de.ey, 1.78, 16 + _bp * 10, c_white, 0.3 + 0.45 * _bp);
        }
    }
    // Bomb Rock / Boulder incoming on this space: same danger strobe as explosives
    if (game.bombCue != undefined && game.bombCue.lane == _de.el && game.bombCue.idx == _de.eidx && !_de.inst.dead) {
        _bodyTint = merge_color(_bodyTint, make_color_rgb(255, 84, 42), 0.25 + 0.6 * abs(dsin(resolveHold * 32)));
    }
    // fresh blast on this space: flash as the damage lands
    for (var _hf = 0; _hf < array_length(fxList); _hf++) {
        var _hfx = fxList[_hf];
        if (_hfx.kind == "boom" && _hfx.age < 14 && point_distance(_hfx.x, _hfx.y, _de.ex, _de.ey) < 26) {
            _bodyTint = merge_color(_bodyTint, make_color_rgb(255, 70, 40), 0.7 * (1 - _hfx.age / 14));
            break;
        }
    }
    if (_isCrush && _atkSection && _canBite && _engaged) {
        // crush foe: instead of leaning in to eat, it LEAPS skyward with the pikmin still
        // clinging, then slams back down - it deals its crush damage and takes the pikmin's
        // at the same instant (the flavour of it landing on you as it dies).
        var _cf = clamp(resolveHold / 34, 0, 1);
        var _rise = 0;
        if (game.jumpCue == "pik") _rise = _cf;                                       // gathering for the leap
        else if (game.jumpCue == "enemy") _rise = 1 - _cf;                            // slamming back down
        else if (_hasBitten) _rise = biteT * 0.12;                                    // slammed home: grounded, tiny residual jitter
        else if (game.jumpCue == "") _rise = 1;                                       // hang at apex while the pikmin bite
        _jz = 1 + dsin(_rise * 90) * (_bbHeight * 0.55);
        _jsx = dsin(frameTick * 14) * 2.5 * _rise;
    } else if (_sink > 0) {
        _jz = 1 - _sink * (_bbHeight * 0.22);
        _jsx = dsin(frameTick * 11) * 3.5 * _sink; // continuous tremble phase (no snap at the beat)
    }
    vb_billboard(sprite_batches_vb(_spriteBatches, _bodySpr), _bodySpr, 0, _de.ex + _jsx, _de.ey, _jz, _bbHeight, _camRight, _camUp, _bodyTint, 1);
    // stash the live body pose so clinging pikmin ride it (dip, leap, tremble all included)
    _enemyVis[$ string(_de.el) + "_" + string(_de.eidx)] = {
        x: _de.ex + _jsx, y: _de.ey, z0: _jz, h: _bbHeight,
        dead: _de.inst.dead, heightGated: (_enemyDef.defenseElement == "height")
    };
}

// --- pikmin tokens from game state (team ring + sprite, small hop) ---
var _clusterSlots = {};
// home cluster stays INSIDE the home strip: as many columns as fit its width (36px each),
// but never more than the count present, so a small group (e.g. the tutorial's 3) sits centred
// rather than spread to a full-board width.
var _homeStripW = board.laneCount * (TILE_W + LANE_GAP);
var _homeMaxCols = max(1, floor(_homeStripW / 36));
for (var _p = 0; _p < 2; _p++) {
    // player-tinted shadow disc under each token (dark, semi-transparent)
    var _shadowCol = player_shadow(_p);
    var _tokens = game.players[_p].tokens;
    var _homeN = 0;
    for (var _hc = 0; _hc < array_length(_tokens); _hc++) if (_tokens[_hc].loc.kind == "home") _homeN += 1;
    var _homeCols = clamp(_homeN, 1, _homeMaxCols);
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        var _key, _baseX, _baseY, _dx, _dy, _slot;
        if (_tok.loc.kind == "home") {
            _key = string(_p) + "_home";
            _slot = variable_struct_exists(_clusterSlots, _key) ? _clusterSlots[$ _key] : 0;
            _clusterSlots[$ _key] = _slot + 1;
            _baseX = ((_slot mod _homeCols) - (_homeCols - 1) * 0.5) * 36;
            _baseY = board_home_y(board, _p) + ((_slot div _homeCols) * 22 - 11);
            _dx = 0; _dy = 0;
        } else {
            _key = string(_p) + "_" + string(_tok.loc.lane) + "_" + string(_tok.loc.idx);
            _slot = variable_struct_exists(_clusterSlots, _key) ? _clusterSlots[$ _key] : 0;
            _clusterSlots[$ _key] = _slot + 1;
            var _sPos = board_space_xy(board, _tok.loc.lane, _tok.loc.idx);
            _baseX = _sPos[0];
            _baseY = _sPos[1] + ((_p == 0) ? -16 : 16);
            _dx = ((_slot mod 4) - 1.5) * 15;
            _dy = (_slot div 4) * 13 - 6;
        }
        var _tx = _baseX + _dx;
        var _ty = _baseY + _dy;
        // escorting a banked pile home: a carrier that just sent its treasure off walks WITH it
        // (offset a touch so the group fans around the pile) until it lands, then heads to its
        // home slot. Purely visual - the token is already "home" to the engine.
        if (variable_struct_exists(_tok, "escort")) {
            var _eKey = "d" + string(_tok.escort.lane);
            if (variable_struct_exists(_departVis, _eKey) && !_departVis[$ _eKey].arrived) {
                if (!variable_struct_exists(_tok, "escOffX")) { _tok.escOffX = random_range(-16, 16); _tok.escOffY = random_range(-6, 10); }
                _tx = _departVis[$ _eKey].x + _tok.escOffX;
                _ty = _departVis[$ _eKey].y + _tok.escOffY;
            } else {
                variable_struct_remove(_tok, "escort"); // pile landed (or gone) - peel off to the home slot
            }
        }
        // movement animation: each token keeps a visual position (_tok.vx/_tok.vy)
        // that chases its logical target at a CONSTANT speed (world-units/frame), so
        // travel time scales with distance - a 2-space move takes twice as long as a
        // 1-space one. Render-only fields the engine never touches; new tokens snap in.
        // Each token gets its own slightly different speed (assigned once) so a group
        // trickles into place at varied paces instead of arriving in lockstep.
        if (!variable_struct_exists(_tok, "vx")) { _tok.vx = _tx; _tok.vy = _ty; _tok.vspd = random_range(3.0, 4.2); _tok.born = irandom_range(-8, 0); } // stagger the sprouting a touch
        // carrying/riding a pile that's on the move? lock to the pile's speed so the
        // group travels WITH the object instead of drifting at its own walking pace
        var _mySpd = _tok.vspd;
        if (_tok.loc.kind == "space") {
            var _rideT = game_treasure_at(game, _tok.loc.lane, _tok.loc.idx);
            if (_rideT != undefined && variable_struct_exists(_rideT, "vmoving") && _rideT.vmoving) _mySpd = _rideT.vspdCur;
        }
        var _travel = point_distance(_tok.vx, _tok.vy, _tx, _ty);
        // while clinging to a foe, FREEZE the ground position (vx/vy) so any deaths this beat
        // don't quietly re-slot the survivors mid-air - they should still be spread the OLD way
        // when they drop, then visibly reorganise after the land-hold. Clingers are excluded
        // from the presMoving check below so a frozen-but-distant target can't stall the pump.
        var _clinging = (variable_struct_exists(_tok, "latchT") && _tok.latchT > 0);
        // land-hold: after dropping off a foe, pikmin plant on the ground for a beat before
        // walking off to re-spread on the space (set below when the cling releases). Freezes
        // the walk and holds the resolution so the reorganise doesn't snap the instant they land.
        var _landHold = variable_struct_exists(_tok, "landHold") ? _tok.landHold : 0;
        if (_landHold > 0) { _tok.landHold = _landHold - 1; presMoving = true; }
        // jump-cue flights write vx/vy themselves - don't count them as "walking" or
        // the pump resets the arc every frame (vibrating softlock)
        if (_travel > 1 && game.jumpCue == "" && !_clinging) presMoving = true;
        // hold tokens in place during the sunset flash so the walk-home reads AFTER it
        var _cineFreeze = (dayCine != undefined && dayCine.phase == "flash");
        if (_travel > 0 && !_cineFreeze && _landHold <= 0 && !_clinging) {
            var _stepD = min(_travel, _mySpd);
            _tok.vx += (_tx - _tok.vx) / _travel * _stepD;
            _tok.vy += (_ty - _tok.vy) / _travel * _stepD;
        }
        var _rx = _tok.vx;
        var _ry = _tok.vy;
        var _typeDef = pikmin_type_get(_tok.typeId);
        var _tokSpr = data_sprite(_typeDef, sprFRIEND);
        var _tokTint = (_tokSpr == sprFRIEND) ? pikmin_tint(_tok.typeId) : c_white;
        // idle bob; while travelling a distance, a livelier hop scaled by how far it has to go
        var _hopZ = abs(sin(frameTick * 0.09 + _i * 1.31 + _p * 2.2)) * 3;
        var _moveF = clamp(_travel / 30, 0, 1);
        if (_moveF > 0.05) _hopZ = max(_hopZ, abs(sin(frameTick * 0.3 + _i)) * 11 * _moveF);
        // --- combat cling: an attacking pikmin LEAPS onto its foe at a random spot on the
        // sprite and rides there for the whole strike scene (swift -> pik -> enemy -> red),
        // dropping straight off at the end or the instant the foe dies - then the walk
        // system reorganises it on the space. Render-only: vx/vy stay parked on the space so
        // the beat pump never mistakes a clinger for a walker (which would softlock resolve).
        var _latchZ = 0;
        var _lt = variable_struct_exists(_tok, "latchT") ? _tok.latchT : 0;
        var _wantLatch = false;
        if (_atkSection && _p == game.activePlayer && _tok.loc.kind == "space" && !token_is_disabled(_tok)) {
            var _lKey = string(_tok.loc.lane) + "_" + string(_tok.loc.idx);
            var _foeVis = variable_struct_exists(_enemyVis, _lKey) ? _enemyVis[$ _lKey] : undefined;
            // can this token reach what's there? (height foes can't be climbed; type-locked
            // ones still get clung to at 0 damage - matches the damage step's own gate)
            if (_foeVis != undefined && !_foeVis.dead) {
                _wantLatch = true;
                if (_foeVis.heightGated) {
                    var _jtr = pikmin_type_get(_tok.typeId).traits;
                    if (!arr_has(_jtr, "climbs_height") && !arr_has(_jtr, "flies_over_hazards")) _wantLatch = false;
                }
            }
            if (_wantLatch) {
                if (_lt <= 0) { _tok.latchU = random_range(-0.34, 0.34); _tok.latchV = random_range(0.24, 0.9); } // pick a cling spot once
                // refresh the cling target each frame so it rides the body's dip / crush-leap
                _tok.lclX = _foeVis.x + _tok.latchU * (TILE_W * 0.34);
                _tok.lclY = _foeVis.y;
                _tok.lclZ = _foeVis.z0 + _tok.latchV * (_foeVis.h * 0.82);
            }
        }
        var _prevLt = _lt;
        if (_wantLatch) _lt = min(1, _lt + 0.18); else _lt = max(0, _lt - 0.11); // quick leap on, slower gravity drop
        if (_prevLt > 0 && _lt <= 0 && variable_struct_exists(_tok, "lclX")) {
            // just hit the dirt directly under where it clung: plant there (scattered off the foe),
            // hold a beat to get its bearings, THEN the walk carries it back to its slot on the space
            _tok.landHold = 18;
            _tok.vx = _tok.lclX;
            _tok.vy = _tok.lclY + random_range(-3, 12); // slight forward scatter so they don't land in a line
        }
        _tok.latchT = _lt;
        if (_lt > 0 && variable_struct_exists(_tok, "lclX")) {
            _hopZ = 0;
            if (_wantLatch) {
                // leaping on / riding the foe: arc up from the ground slot onto the body
                _rx = _tok.vx + (_tok.lclX - _tok.vx) * _lt;
                _ry = _tok.vy + (_tok.lclY - _tok.vy) * _lt;
                _latchZ = _tok.lclZ * _lt;
                _latchCount += 1;
                _atkSpaceSet[$ string(_tok.loc.lane) + "_" + string(_tok.loc.idx)] = { lane: _tok.loc.lane, idx: _tok.loc.idx };
            } else {
                // dropping off: fall STRAIGHT DOWN from the cling spot - x/y hold, only z falls,
                // eased so it accelerates like gravity (slow off the body, quick into the ground)
                _rx = _tok.lclX;
                _ry = _tok.lclY;
                _latchZ = _tok.lclZ * (1 - sqr(1 - _lt));
            }
        } else if (_atkSection && (_frontBeat == "pik" || game.jumpCue == "pik")
            && _p == game.activePlayer && _tok.loc.kind == "space" && !token_is_disabled(_tok)) {
            // no body to cling to, but there's a structure here to smash: keep the old
            // lunge-hop so hitting a wall/emitter still animates (0 damage animates too)
            var _ssp = game.board.lanes[_tok.loc.lane].spaces[_tok.loc.idx];
            if (_ssp.structure != undefined && hazard_def_get(_ssp.structure.structId).type != "bridge") {
                _hopZ = max(_hopZ, dsin(clamp(resolveHold / 34, 0, 1) * 180) * 20);
                _structForce += 1; // walls/emitters get the same repeated-whack SFX layers as enemies
                _atkSpaceSet[$ string(_tok.loc.lane) + "_" + string(_tok.loc.idx)] = { lane: _tok.loc.lane, idx: _tok.loc.idx };
            }
        }
        // newly-sprouted pikmin GROW up through the board (spawn below, rise through
        // the floor - the underground part is depth-clipped, so they emerge like plants)
        var _bornZ = 0;
        if (variable_struct_exists(_tok, "born") && _tok.born < 30) {
            _tok.born += 1;
            if (_tok.born < 30) {
                _bornZ = -26 * (1 - max(_tok.born, 0) / 30);
                _hopZ = 0; // no hopping until they're out of the ground
            }
        }
        // stunned pikmin: dead still, and the "buried" kind (snitchbug) sinks halfway
        // into the ground. stunKind exists for future stuns that present differently.
        var _sunk = 0;
        if (!token_is_frozen(_tok) && variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) {
            _hopZ = 0;
            if (!variable_struct_exists(_tok, "stunKind") || _tok.stunKind == "buried") _sunk = 15;
        }
        // frozen/shocked/petrified pikmin: tinted by the source, dead still, and
        // badged with the element token at their feet
        var _fk = "";
        if (token_is_frozen(_tok)) {
            _hopZ = 0;
            _fk = variable_struct_exists(_tok, "frozenKind") ? _tok.frozenKind : "ice";
            switch (_fk) {
                case "shock":  _tokTint = make_color_rgb(255, 232, 90);  break; // electric yellow
                case "bitter": _tokTint = make_color_rgb(205, 200, 215); break; // petrified stone
                default:       _tokTint = make_color_rgb(170, 235, 255); break; // iced light cyan
            }
        }
        // spicy ignition: the sprayed player's able pikmin on a sprayed space glow red
        if (game.sprayCue && _p == game.activePlayer && _tok.loc.kind == "space" && !token_is_disabled(_tok)) {
            for (var _sg = 0; _sg < array_length(game.sprays); _sg++) {
                var _sgs = game.sprays[_sg];
                if (_sgs.playerIdx == _p && _sgs.lane == _tok.loc.lane && _sgs.idx == _tok.loc.idx) {
                    _tokTint = merge_color(_tokTint, make_color_rgb(255, 60, 40), 0.35 + 0.5 * abs(dsin(resolveHold * 24)));
                    break;
                }
            }
        }
        // shadow stays on the ground and shrinks a touch as the token hops; while clinging
        // to a foe it lifts off the floor, so fade the shadow out as it climbs
        vb_disc(_overlayVB, _rx, _ry, 1.68, 7 - _hopZ * 0.4, _shadowCol, 0.5 * (1 - _lt));
        vb_billboard(sprite_batches_vb(_spriteBatches, _tokSpr), _tokSpr, 0, _rx, _ry, 1 + _hopZ - _sunk + _bornZ + _latchZ, 30, _camRight, _camUp, _tokTint, 1);
        if (_fk != "") {
            // flat decal on the floor at the token's feet (over the shadow), not on the sprite
            var _fSpr = (_fk == "shock") ? TokElectric : ((_fk == "bitter") ? TokBitter : TokIce);
            vb_tile_sprite(sprite_batches_vb(_spriteBatches, _fSpr), _fSpr, 0, _rx, _ry, 1.70, 16, c_white, 1);
        }
    }
}

// repeated attack swipes: while the strike scene is live and pikmin are actually hitting
// something (clinging to a foe or smashing a wall/emitter), fire single sfxPikAttack swipes
// on SEVERAL independent schedules so it reads like a crowd whacking away out of phase - not
// a drone, not a metronome. More pikmin committed -> more overlapping layers (up to 3). Low
// priority (3) so a bank or death sound always outranks them; anims-off keeps the engine hits.
var _atkForce = _latchCount + _structForce;
var _atkPik = asset_get_index("sfxPikAttack");
var _atkSpaces = [];
var _asKeys = variable_struct_get_names(_atkSpaceSet);
for (var _ak = 0; _ak < array_length(_asKeys); _ak++) array_push(_atkSpaces, _atkSpaceSet[$ _asKeys[_ak]]);
if (_atkSection && _atkForce > 0 && _atkPik != -1 && array_length(_atkSpaces) > 0) {
    var _layers = (_atkForce >= 4) ? 3 : ((_atkForce >= 2) ? 2 : 1);
    for (var _al = 0; _al < _layers; _al++) {
        atkTimers[_al] -= 1;
        if (atkTimers[_al] <= 0) {
            // each swipe comes from a random space that's actually fighting, so multiple
            // lanes in combat pan apart instead of piling up in the centre
            var _asp = _atkSpaces[irandom(array_length(_atkSpaces) - 1)];
            audio_play_sound_on(emitter_at(_asp.lane, _asp.idx), _atkPik, false, 3, 1, 0, random_range(0.8, 1.2));
            atkTimers[_al] = irandom_range(16, 34); // each layer drifts on its own gap -> overlapping offset hits
        }
    }
} else {
    atkTimers = [0, irandom_range(5, 11), irandom_range(10, 18)]; // stagger the layers' first hits for the next scene
}

// deck/onion count labels, filled by the dressing blocks below (empty -> no labels drawn)
var _deckCounts = [];
// --- table dressing: hordes, opponent hand, the two deck stacks, and the onion discard zones.
// --- The tutorial strips ALL of it (just spaces + pikmin) - so this whole region is gated. ---
if (!_stripDressing) {
// --- banked-treasure hordes: each player's collected piles heaped off to THEIR RIGHT,
// --- near their home. Deliberately uneven - a stable per-item pseudo-random scatter
// --- (hash of its index) makes a rough mound, as if shoved together. Grows as piles
// --- bank (game_finalize_departing appends to players[p].collected). ---
for (var _hp = 0; _hp < 2; _hp++) {
    var _collected = game.players[_hp].collected;
    var _hn = array_length(_collected);
    if (_hn == 0) continue;
    // Own horde sits to the player's RIGHT (opponent's on their left). The y-flipped
    // projection mirrors world-x on screen, so P0's right = world -x, P1's = world +x.
    var _hAnchorX = (_hp == 0) ? -440 : 440;
    var _hAnchorY = board_home_y(board, _hp) * 0.86;
    var _baseRad = 82;   // ground-layer spread
    var _perLayer = 12;  // items per layer before stacking on top
    var _layerH = 12;    // vertical step per layer (billboard base rests on the one below)
    // soft ground shadow so the heap reads as sitting ON the floor, not floating
    vb_disc(_overlayVB, _hAnchorX, _hAnchorY, 1.66, _baseRad + 6, make_color_rgb(24, 20, 16), 0.22);
    for (var _hi = 0; _hi < _hn; _hi++) {
        var _layer = _hi div _perLayer;
        var _slot = _hi mod _perLayer;
        var _layerCount = min(_perLayer, _hn - _layer * _perLayer); // this layer's actual item count
        // stable [0,1) hash jitter per item - GML frac() keeps the sign, so use x-floor(x)
        var _j1 = sin(_hi * 12.9898 + _hp * 7.13) * 43758.5453; _j1 -= floor(_j1);
        var _j2 = sin(_hi * 78.233 + _hp * 3.71) * 12543.877;   _j2 -= floor(_j2);
        var _j3 = sin(_hi * 41.17 + _hp * 5.9) * 9871.3;        _j3 -= floor(_j3);
        // narrows going up (mound); a sparse top layer clusters toward the centre
        var _layerRad = _baseRad * max(0.28, 1 - _layer * 0.22) * sqrt(_layerCount / _perLayer);
        // sunflower / golden-angle placement fills the disc EVENLY; per-layer rotation
        // stops layers stacking in columns; small jitter keeps it an organic heap
        var _rFrac = clamp(sqrt((_slot + 0.5) / _layerCount) + (_j2 - 0.5) * 0.14, 0, 1);
        var _hAng = _slot * 137.50776 + _layer * 57 + (_j1 - 0.5) * 20;
        var _hRad = _rFrac * _layerRad;
        var _hx = _hAnchorX + dcos(_hAng) * _hRad;
        var _hy = _hAnchorY + dsin(_hAng) * _hRad;
        var _hz = _layer * _layerH + _j3 * 4; // base layer on the ground; higher layers stack
        var _hSpr = data_sprite(treasure_def_get(_collected[_hi]), sprFRIEND);
        vb_billboard(sprite_batches_vb(_spriteBatches, _hSpr), _hSpr, 0, _hx, _hy, _hz, 40, _camRight, _camUp, c_white, 1);
    }
}

// --- hands laid flat behind each home. Normally only the OPPONENT (the seat we're NOT
// --- viewing from) is shown, as cardbacks - a count preview, no faces. When SPECTATING
// --- (neither seat is human) BOTH hands are shown FACE-UP so an AI-vs-AI game can be
// --- watched card-by-card. Each hand is rotated to face the seat it belongs to (like the
// --- board fixtures), so from either player's camera the far hand reads as the enemy's. ---
var _spectating = (ctl[0] != "human" && ctl[1] != "human");
var _handPlayers = _spectating ? [0, 1] : [1 - view_seat()]; // spectate: both; else the OTHER player
for (var _hpI = 0; _hpI < array_length(_handPlayers); _hpI++) {
    var _hpN = _handPlayers[_hpI];
    var _hHand = game.players[_hpN].hand;
    var _hPel = game.players[_hpN].pellets;
    var _handN = array_length(_hHand) + array_length(_hPel);
    if (_handN == 0) continue;
    var _cbPitch = min(50, 520 / _handN); // spread, but keep the row on the board for big hands
    var _cbRowW = _cbPitch * (_handN - 1);
    var _cbY = board_home_y(board, _hpN) + (_hpN == 1 ? 36 : -36); // just beyond (behind) each home
    for (var _hb = 0; _hb < _handN; _hb++) {
        var _cbGather = (_hb < array_length(_hHand));
        var _cbId = _cbGather ? _hHand[_hb] : _hPel[_hb - array_length(_hHand)];
        var _cbX = -_cbRowW * 0.5 + _hb * _cbPitch;
        var _cbSpr = _spectating ? card_sprite_get(_cbId) : -1; // face only when spectating
        if (_cbSpr == -1) _cbSpr = card_back_sprite_get(_cbGather ? "gather" : "pellet"); // else the back
        if (_cbSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _cbSpr), _cbSpr, 0, _cbX, _cbY, 1.63, 56, c_white, 1, (_hpN == 1));
        else vb_tile(_overlayVB, _cbX, _cbY, 1.62, 38, 54, _cbGather ? make_color_rgb(58, 50, 74) : make_color_rgb(74, 62, 40), 0.95);
    }
}

// --- gather deck + discard: a flat decal off to the side at the board's MIDPOINT. Shows the
// --- LAST discarded card (face), with deck/discard counts; Alt-hover lists the pile. (y=board
// --- midpoint, not 0 - on a home-anchored solo board 0 is the near home, where the onion sits.) ---
var _deckBnd = board_bounds_y(board, game.solo);
var _deckMidY = (_deckBnd.minY + _deckBnd.maxY) * 0.5;
var _ddX = 380, _ddY = _deckMidY;
var _discN = array_length(game.decks.gatherDiscard);
var _deckN = array_length(game.decks.gather);
if (_discN > 0) {
    var _ddSpr = card_sprite_get(game.decks.gatherDiscard[_discN - 1]);
    if (_ddSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _ddSpr), _ddSpr, 0, _ddX, _ddY, 1.63, 84, c_white, 1);
    else vb_tile(_overlayVB, _ddX, _ddY, 1.62, 58, 84, make_color_rgb(40, 38, 48), 0.95);
}
// deck stack = the gather back (face-down undrawn cards)
var _deckBackSpr = card_back_sprite_get("gather");
if (_deckBackSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _deckBackSpr), _deckBackSpr, 0, _ddX, _ddY - 96, 1.63, 84, c_white, 1);
else vb_tile(_overlayVB, _ddX, _ddY - 96, 1.62, 58, 84, make_color_rgb(30, 42, 58), 0.9);
// counts printed flat ON the stacks (no billboarded labels) - drawn in a pass below
array_push(_deckCounts, { cx: _ddX, cy: _ddY - 96, n: _deckN });
if (_discN > 0) array_push(_deckCounts, { cx: _ddX, cy: _ddY, n: _discN });

// --- treasure deck: face-down stack showing how many treasures remain to be dealt
// --- (mirrors the gather deck on the opposite side of centre) ---
var _tdX = -380, _tdY = _deckMidY;
var _tdN = array_length(game.decks.treasure);
var _tdBackSpr = card_back_sprite_get("treasure");
if (_tdBackSpr != -1) vb_tile_sprite(sprite_batches_vb(_spriteBatches, _tdBackSpr), _tdBackSpr, 0, _tdX, _tdY, 1.63, 84, c_white, 1);
else vb_tile(_overlayVB, _tdX, _tdY, 1.62, 58, 84, make_color_rgb(44, 40, 30), 0.9);
array_push(_deckCounts, { cx: _tdX, cy: _tdY, n: _tdN });

// --- Onion discard zones: a circle to each player's LEFT (mirror of their treasure
// --- horde), the horde-shadow footprint. Orders-phase pikmin sent here walk home
// --- and are dismissed (game_order_discard) - a way to free token-cap space. ---
for (var _op = 0; _op < (game.solo ? 1 : 2); _op++) {   // solo/adventure: no far player's onion
    var _oX = (_op == 0) ? 440 : -440;   // opposite side from the horde anchor
    var _oY = board_home_y(board, _op) * 0.86;
    var _oHover = (hoverKind == "onion" && hoverIdx == _op && _op == game.activePlayer);
    // lifted a hair off the ground plane so the tinted disc doesn't z-fight the floor
    vb_disc(_overlayVB, _oX, _oY, 2.2, 88, make_color_rgb(24, 20, 16), _oHover ? 0.45 : 0.26, 22);
    vb_disc(_overlayVB, _oX, _oY, 2.4, 76, player_tint(_op), _oHover ? 0.42 : 0.16, 22);
    array_push(_deckCounts, { cx: _oX, cy: _oY, n: "ONION", flip: (_op == 1) }); // seat 1's label faces the red side
}
} // end table-dressing (if !_stripDressing)

// --- death FX: drain new death events (game.fx) into animated instances, then play
// --- them all in parallel. Pikmin release a type-coloured spirit that floats up and
// --- wiggles; enemies squash + fade while an enemy spirit rises, then the card fades. ---
for (var _fi = 0; _fi < array_length(game.fx); _fi++) {
    var _ev = game.fx[_fi];
    var _fpos = board_space_xy(board, _ev.lane, _ev.idx);
    if (_ev.kind == "pik") {
        // rise from EXACTLY where the pikmin stood (its render pos, carried on the
        // event); fall back to a jittered cell spot for tokens never rendered
        var _sx = (_ev.px != undefined) ? _ev.px : _fpos[0] + random_range(-9, 9);
        var _sy = (_ev.py != undefined) ? _ev.py : _fpos[1] + random_range(-5, 5);
        // per-soul rise speed so a batch staggers apart in mid-air (like the walk trickle)
        array_push(fxList, { kind: "pik", x: _sx, y: _sy, col: pikmin_tint(_ev.typeId), rspd: random_range(0.35, 0.6), age: 0 });
    } else if (_ev.kind == "boom") {
        array_push(fxList, { kind: "boom", x: _fpos[0], y: _fpos[1], age: 0 });
    } else if (_ev.kind == "spicy") {
        array_push(fxList, { kind: "spicy", x: _fpos[0], y: _fpos[1], age: 0 });
    } else {
        array_push(fxList, { kind: "enemy", x: _fpos[0], y: _fpos[1] + (_ev.isBoss ? 16 : 0), enemyDefId: _ev.enemyDefId, age: 0 });
    }
}
game.fx = [];
var _fj = 0;
while (_fj < array_length(fxList)) {
    var _fx = fxList[_fj];
    _fx.age += 1;
    if (_fx.kind == "spicy") {
        // spicy ignition: small RED pop - quick flash + expanding crimson ring
        var _slife = 26;
        if (_fx.age >= _slife) { array_delete(fxList, _fj, 1); continue; }
        var _st = _fx.age / _slife;
        if (_fx.age < 6) vb_disc(_overlayVB, _fx.x, _fx.y, 1.80, 18 * (1 - _fx.age / 6) + 6, make_color_rgb(255, 96, 72), 0.8);
        vb_disc(_overlayVB, _fx.x, _fx.y, 1.79, 8 + _st * 26, merge_color(make_color_rgb(255, 70, 50), make_color_rgb(150, 22, 16), _st), 0.65 * (1 - _st));
        _fj += 1;
        continue;
    }
    if (_fx.kind == "boom") {
        // procedural blast: white core flash, then an expanding fiery ring on the ground
        var _blife = 32;
        if (_fx.age >= _blife) { array_delete(fxList, _fj, 1); continue; }
        var _bt = _fx.age / _blife;
        if (_fx.age < 8) vb_disc(_overlayVB, _fx.x, _fx.y, 1.80, 30 * (1 - _fx.age / 8) + 8, c_white, 0.85);
        vb_disc(_overlayVB, _fx.x, _fx.y, 1.79, 12 + _bt * 46, merge_color(make_color_rgb(255, 186, 64), make_color_rgb(198, 44, 22), _bt), 0.7 * (1 - _bt));
        _fj += 1;
        continue;
    }
    if (_fx.kind == "pik") {
        var _plife = 100;
        if (_fx.age >= _plife) { array_delete(fxList, _fj, 1); continue; }
        var _pt = _fx.age / _plife;
        var _pz = 4 + _fx.age * _fx.rspd;                   // float up at this soul's own speed (staggered)
        var _pwig = dsin(_fx.age * 9) * 5 * (1 - _pt);      // gentle wiggle, settling as it fades
        var _pin = clamp(_fx.age / 16, 0, 1);               // materialize - fade AND grow in
        vb_billboard(sprite_batches_vb(_fxBatches, spirPik), spirPik, 0, _fx.x + _pwig, _fx.y, _pz, 24 * (0.5 + 0.5 * _pin), _camRight, _camUp, _fx.col, _pin * (1 - _pt * _pt));
    } else {
        var _elife = 92;
        if (_fx.age >= _elife) { array_delete(fxList, _fj, 1); continue; }
        var _edef = enemy_def_get(_fx.enemyDefId);
        // card below: solid until the spirit is gone (~62), then fades away over the rest
        var _cardA = (_fx.age < 62) ? 1 : clamp(1 - (_fx.age - 62) / 30, 0, 1);
        var _cardSpr = card_sprite_get(card_enemy_alias(_fx.enemyDefId, boardDef.setNumber));
        if (_cardSpr != -1 && _cardA > 0) vb_tile_sprite(sprite_batches_vb(_fxBatches, _cardSpr), _cardSpr, 0, _fx.x, _fx.y, 1.55, TILE_W, c_white, _cardA);
        // standing body squashes down slowly (shrinks) + fades while the spirit rises
        if (_fx.age < 58) {
            var _sq = _fx.age / 58;
            var _bodySpr = data_sprite(_edef, sprFRIEND);
            var _bodyTint = (_bodySpr == sprFRIEND) ? make_color_rgb(150, 84, 72) : c_white;
            var _bh = clamp(36 + _edef.hp * 1.6, 36, 90) * (1 - _sq * 0.85);
            // splat: widen as it flattens, like it's being squashed underfoot
            vb_billboard(sprite_batches_vb(_fxBatches, _bodySpr), _bodySpr, 0, _fx.x, _fx.y, 1, _bh, _camRight, _camUp, _bodyTint, 1 - _sq * _sq, 1 + _sq * 1.1);
        }
        // enemy spirit rises + wiggles + fades (always the same colour)
        var _et = _fx.age / 62;
        if (_et < 1) {
            var _ewig = dsin(_fx.age * 8) * 6 * (1 - _et);
            var _ein = clamp(_fx.age / 12, 0, 1); // materialize - fade AND grow in
            vb_billboard(sprite_batches_vb(_fxBatches, spirEnemy), spirEnemy, 0, _fx.x + _ewig, _fx.y, 8 + _fx.age * 1.5, 34 * (0.5 + 0.5 * _ein), _camRight, _camUp, c_white, _ein * (1 - _et * _et)); // rises MUCH faster than pikmin souls, clears out quick
        }
    }
    _fj += 1;
}

// --- submit sprites (alpha-tested cutouts) ---
sprite_batches_flush(_spriteBatches);
// death FX: alpha BLEND (fades) with depth-test ON but write OFF - the scene's depth
// is already in the buffer, so the fading card sits correctly UNDER pikmin standing
// on it instead of rendering over everything
gpu_set_alphatestenable(false);
gpu_set_zwriteenable(false);
sprite_batches_flush(_fxBatches);
gpu_set_zwriteenable(true);
gpu_set_alphatestenable(true);

// --- enemy HUDs: card-style stat circles (damage red, HP green / gold for bosses),
// --- element icons flanking them, name above. Drawn as billboarded 2D primitives.
if (array_length(_displayEnemies) > 0 || array_length(_displayStructs) > 0) {
    draw_set_font(fntPikmin); // enemy damage/HP numbers stay stylised (Pikmin font)
    // Fixed LAYOUT scale for the circles/offsets (was 16/string_height back when the
    // font was 12pt ~= 0.89). The TEXT gets its OWN scale so the 36pt font still lands
    // at ~16 world units instead of shrinking the whole matrix (and the circles with it).
    var _hudScale = 0.89;
    var _hudTextScale = 16 / max(1, string_height("Ag") * _hudScale);
    draw_set_halign(fa_center);

    // structures: just a green HP circle (the geometry/decal identifies them)
    draw_set_valign(fa_middle);
    for (var _si2 = 0; _si2 < array_length(_displayStructs); _si2++) {
        var _ds = _displayStructs[_si2];
        matrix_set(matrix_world, billboard_matrix(_ds.sx, _ds.sy, _ds.sz, _hudScale, _camRight, _camUp, _camFwd));
        draw_set_color(make_color_rgb(74, 164, 74));
        draw_circle(0, 0, 13, false);
        draw_set_color(c_white);
        draw_text_transformed(0, 0, string(_ds.hp), _hudTextScale, _hudTextScale, 0);
    }
    for (var _ei = 0; _ei < array_length(_displayEnemies); _ei++) {
        var _de = _displayEnemies[_ei];
        var _enemyDef = enemy_def_get(_de.inst.enemyDefId);
        matrix_set(matrix_world, billboard_matrix(_de.ex, _de.ey, _de.hudZ, _hudScale, _camRight, _camUp, _camFwd));

        var _hpFrac = clamp(_de.inst.curHp / _enemyDef.hp, 0, 1);
        var _hpCol = _enemyDef.boss
            ? merge_color(make_color_rgb(190, 60, 40), make_color_rgb(214, 170, 56), _hpFrac)
            : merge_color(make_color_rgb(190, 60, 40), make_color_rgb(74, 164, 74), _hpFrac);
        draw_set_color(make_color_rgb(168, 42, 42));
        draw_circle(-16, 0, 14, false);
        draw_set_color(_hpCol);
        draw_circle(16, 0, 14, false);
        draw_set_valign(fa_middle);
        draw_set_color(c_white);
        draw_text_transformed(-16, 0, string(_enemyDef.damage), _hudTextScale, _hudTextScale, 0);
        draw_text_transformed(16, 0, string(_de.inst.curHp), _hudTextScale, _hudTextScale, 0);

        if (_enemyDef.attackElement != "") {
            var _atkSpr = element_sprite(_enemyDef.attackElement);
            if (_atkSpr != -1) {
                var _is = 26 / max(sprite_get_width(_atkSpr), sprite_get_height(_atkSpr));
                draw_sprite_ext(_atkSpr, 0, -48 - sprite_get_width(_atkSpr) * _is * 0.5, -sprite_get_height(_atkSpr) * _is * 0.5, _is, _is, 0, c_white, 1);
            }
        }
        if (_enemyDef.defenseElement != "") {
            var _defSpr = element_sprite(_enemyDef.defenseElement);
            if (_defSpr != -1) {
                var _is = 26 / max(sprite_get_width(_defSpr), sprite_get_height(_defSpr));
                draw_sprite_ext(_defSpr, 0, 48 - sprite_get_width(_defSpr) * _is * 0.5, -sprite_get_height(_defSpr) * _is * 0.5, _is, _is, 0, c_white, 1);
            }
        }

        // incapacitated (bitter / frozen / shocked): show the source token below the stats
        if (variable_struct_exists(_de.inst, "stunned") && _de.inst.stunned > 0) {
            var _stKind = variable_struct_exists(_de.inst, "stunnedBy") ? _de.inst.stunnedBy : "bitter";
            var _stSpr = (_stKind == "shock") ? TokElectric : ((_stKind == "ice") ? TokIce : TokBitter);
            var _is3 = 24 / max(sprite_get_width(_stSpr), sprite_get_height(_stSpr));
            draw_sprite_ext(_stSpr, 0, -sprite_get_width(_stSpr) * _is3 * 0.5, 20 - sprite_get_height(_stSpr) * _is3 * 0.5, _is3, _is3, 0, c_white, 1);
        }

        // the card on the tile carries the name; label only as a fallback
        if (!_de.hasCard) {
            draw_set_valign(fa_bottom);
            draw_text_transformed(0, -20, _enemyDef.name, _hudTextScale, _hudTextScale, 0);
        }
    }
    matrix_set(matrix_world, matrix_build_identity());
    draw_set_font(fntMaru);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
}

// --- name/value labels (in-game text uses fntPikmin) ---
var _numLabels = array_length(_labels);
if (_numLabels > 0) {
    draw_set_font(fntMaru);
    draw_set_halign(fa_center);
    draw_set_valign(fa_bottom);
    draw_set_color(c_white);
    var _labelScale = 16 / max(1, string_height("Ag"));
    for (var _i = 0; _i < _numLabels; _i++) {
        var _lbl = _labels[_i];
        draw_text_billboard(_lbl.labelX, _lbl.labelY, _lbl.labelZ, _lbl.labelText, _labelScale, _camRight, _camUp, _camFwd);
    }
    draw_set_valign(fa_top);   // labels draw fa_bottom - reset so it can't leak into a later pass (e.g. the pause menu when deck counts are gated off)
    draw_set_font(fntMaru);
}

// --- deck counts: printed FLAT on the deck/discard stacks like part of the texture
// --- (negative x scale compensates the projection's x-mirror, like vb_tile_sprite) ---
if (array_length(_deckCounts) > 0) {
    draw_set_font(fntMaru);
    draw_set_halign(fa_center);
    draw_set_valign(fa_middle);
    var _dcScale = 0.55;
    for (var _i = 0; _i < array_length(_deckCounts); _i++) {
        var _dc = _deckCounts[_i];
        // default (-,-) scale = a 180deg rotation that faces seat 0; a flipped label (owned by
        // seat 1) uses (+,+) so it reads upright from the red side / seat-2 camera instead.
        var _dcS = (variable_struct_exists(_dc, "flip") && _dc.flip) ? _dcScale : -_dcScale;
        matrix_set(matrix_world, matrix_build(_dc.cx, _dc.cy, 3.4, 0, 0, 0, _dcS, _dcS, _dcScale));
        draw_set_color(c_white);
        draw_text(0, 0, string(_dc.n));
    }
    matrix_set(matrix_world, matrix_build_identity());
    draw_set_font(fntMaru);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
    draw_set_halign(fa_left);
    draw_set_valign(fa_top);
}

// --- overlay quads last: no alpha test so translucent highlights blend ---
gpu_set_alphatestenable(false);
vertex_end(_overlayVB);
vertex_submit(_overlayVB, pr_trianglelist, -1);
vertex_delete_buffer(_overlayVB);

gpu_set_ztestenable(false);
gpu_set_zwriteenable(false);
