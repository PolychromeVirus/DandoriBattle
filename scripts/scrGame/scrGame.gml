// Core rules engine (M3). Pure game state + mutations - no rendering, no input.
// Everything the UI (and later the AI / network layer) does goes through game_*
// functions, and all randomness lives here.
//
// Locations: {kind:"home"} (owner implied by token) or {kind:"space", lane, idx}.
// Lane spaces run 0-6: 0-2 player A's side, 3 shared treasure space, 4-6 player B's.

// ---------- construction & setup ----------

/// _scenario (optional) IS a complete game struct (JSON-able) describing an EXACT starting state -
/// solo flag, day, per-player Pikmin, placed treasures, decks, etc. When given, it's variable_cloned
/// and the generative game_setup is skipped entirely. Built by scenario_* factories (scrBoard);
/// reused by the tutorial + a future challenge mode.
function game_new(_boardId, _scenario = undefined) {
    // a scenario IS a complete game struct (JSON-able; defined in the scenarios script). Clone it
    // so the template isn't mutated during play, init the turn, and skip all generative setup.
    if (_scenario != undefined) {
        var _g = variable_clone(_scenario);
        game_begin_turn(_g);
        return _g;
    }
    var _boardDef = board_def_get(_boardId);
    // start from the shared blank skeleton (scenario_base - the single source of truth for the _g
    // schema, in scrScenarios), then apply the generative overrides a normal game needs.
    var _g = scenario_base(_boardDef);
    // a generated board carries its own decks; clone them so shuffling/consuming during play
    // doesn't mutate the stored def (which persists on the board list)
    var _rand = variable_struct_exists(_boardDef, "randomDecks");
    _g.decks.gather   = _rand ? variable_clone(_boardDef.randomDecks.gather)   : deck_build_gather(_boardDef.setNumber);
    _g.decks.treasure = _rand ? variable_clone(_boardDef.randomDecks.treasure) : deck_build_treasure(_boardDef.treasureSet);
    _g.decks.enemy    = _rand ? variable_clone(_boardDef.randomDecks.enemy)    : enemy_deck_build(_boardDef.setNumber);
    deck_shuffle(_g.decks.gather);
    deck_shuffle(_g.decks.treasure);
    deck_shuffle(_g.decks.enemy);
    game_setup(_g);          // deals treasure piles, spawns enemies, grants starting Pikmin
    game_begin_turn(_g);
    return _g;
}

/// Build the gather deck for a board set (each set 1-16 has its own pool).
function deck_build_gather(_setNumber = 1) {
    var _deck = [];
    var _defs = global.gatherData.gather;
    var _key = string(_setNumber);
    for (var _i = 0; _i < array_length(_defs); _i++) {
        var _sc = _defs[_i].setsCopies;
        if (!variable_struct_exists(_sc, _key)) continue;
        repeat (_sc[$ _key]) array_push(_deck, _defs[_i].id);
    }
    if (array_length(_deck) == 0 && _setNumber != 1) return deck_build_gather(1);
    return _deck;
}

/// Which shared power-card set ("ALL1"/"ALL2") to mix in this game, honoring the options setting
/// (global.settings.allSet: 1, 2, or 0 = random each build).
function all_set_tag() {
    var _c = (variable_global_exists("settings") && variable_struct_exists(global.settings, "allSet"))
             ? global.settings.allSet : 1;
    if (_c != 1 && _c != 2) _c = irandom_range(1, 2);   // 0 / anything else = random each game
    return "ALL" + string(_c);
}

/// A board's treasure deck = its base numeric set PLUS the chosen shared ALL* power set (the Good/Bad
/// on-bank cards, which belong to every board). Adventure boards pass their own set (A1/A2/A3).
function deck_build_treasure(_treasureSet) {
    var _deck = [];
    var _defs = global.treasureData.treasures;
    var _allTag = all_set_tag();
    for (var _i = 0; _i < array_length(_defs); _i++) {
        var _s = _defs[_i].set;
        if (_treasureSet == "all" || _s == _treasureSet || _s == _allTag) {
            repeat (_defs[_i].copies) array_push(_deck, _defs[_i].id);
        }
    }
    return _deck;
}

function game_log(_g, _msg) {
    array_push(_g.log, _msg);
    if (array_length(_g.log) > 200) array_delete(_g.log, 0, 1);
    game_trace(_g, "· " + _msg); // human seats mirror the narrative into the debug file
}

/// Debug trace for HUMAN-controlled seats (the controller flags _g.trace per seat).
/// Writes to ai_debug.txt in the AI's own "P1| ..." format, so a human-vs-AI game
/// reads as one interleaved decision log and the autopsy tooling parses both sides.
function game_trace(_g, _str) {
    if (!variable_struct_exists(_g, "trace") || !_g.trace[_g.activePlayer]) return;
    var _f = file_text_open_append("ai_debug.txt");
    file_text_write_string(_f, "P" + string(_g.activePlayer + 1) + "| " + _str);
    file_text_writeln(_f);
    file_text_close(_f);
}

/// Emit a death FX event (drained by the controller into an animated spirit). Cosmetic
/// only - the rules never read _g.fx. A dying pikmin releases a type-coloured spirit;
/// a dying enemy squashes down + releases an enemy spirit, then its card fades.
function game_fx_pik(_g, _tok, _lane, _idx, _crush = false) {
    // carry the token's render position (vx/vy, if the renderer has set it) so the
    // soul rises from exactly where the pikmin was standing
    var _hasV = variable_struct_exists(_tok, "vx");
    var _ev = { kind: "pik", typeId: _tok.typeId, lane: _lane, idx: _idx,
        px: _hasV ? _tok.vx : undefined, py: _hasV ? _tok.vy : undefined, crush: _crush };
    // crush deaths get knocked off the beast: carry the token's last cling pose (set by
    // the renderer while it rode the foe) so the corpse drops from the body, flattens on
    // the dirt where it was crushed, THEN its soul pops - the visible tell the crush hit
    if (_crush && variable_struct_exists(_tok, "lclX")) {
        _ev.cx = _tok.lclX; _ev.cy = _tok.lclY; _ev.cz = _tok.lclZ;
    }
    array_push(_g.fx, _ev);
    game_sfx(_g, "sfxPikDeath", 3, _lane, _idx);
}
function game_fx_enemy(_g, _enemyDefId, _lane, _idx, _isBoss) {
    array_push(_g.fx, { kind: "enemy", enemyDefId: _enemyDefId, lane: _lane, idx: _idx, isBoss: _isBoss });
    game_sfx(_g, "sfxEnemyDeath", 3, _lane, _idx);
}
function game_fx_boom(_g, _lane, _idx) {
    array_push(_g.fx, { kind: "boom", lane: _lane, idx: _idx });
}
/// Energy pulse at player _p's Onion (home-anchored, no lane/idx) - fired when a manually-discarded
/// pikmin reaches the Onion and is dismissed. _typeId tints the ring to the pikmin's colour. Draw
/// resolves the world position from _p.
function game_fx_onion(_g, _p, _typeId) {
    array_push(_g.fx, { kind: "onionpop", playerIdx: _p, typeId: _typeId });
}
/// Apply a tile swap with the fade-to-white animation: with anims on, the renderer flips the
/// tile UNDER the white at the peak (old fades out -> white -> new fades in); anims off (sim/
/// batch, no Draw) flips it immediately. The `to` type rides the fx so Draw can apply it.
function game_apply_swap_animated(_g, _lane, _idx, _to) {
    if (global.expRules.anims) {
        array_push(_g.fx, { kind: "swap", lane: _lane, idx: _idx, to: _to }); // Draw flips + bumps tileVersion at the peak
    } else {
        game_space_set_type(_g.board.lanes[_lane].spaces[_idx], _to);
        _g.tileVersion += 1;   // anims off: flip now + mark the tile mesh stale for the renderer
    }
}
function game_fx_spicy(_g, _lane, _idx) {
    array_push(_g.fx, { kind: "spicy", lane: _lane, idx: _idx });
}

/// Queue a one-shot SFX (asset name) for the presentation to play (drained in Step_0). Cosmetic, like
/// game.fx. Up to _maxDup of the same name may queue - default 3 so a mass death lands as a FEW slightly-
/// offset hits (drain staggers + pitch-varies them). Pass 1 for sounds that fire in tight clusters and
/// would get LOUD stacked (banks, on-bank effects). Capped overall so headless sims don't grow it.
/// Queue a one-shot SFX for the presentation to play (headless-safe: just names + optional position).
/// Pass _lane/_idx to make it POSITIONAL - the drain plays it on that space's emitter so it pans.
/// _pitch (optional) sets a BASE playback pitch for this cue (the drain still adds a small
/// random wobble on top); undefined = the drain's default per-name pitch.
function game_sfx(_g, _name, _maxDup = 3, _lane = undefined, _idx = undefined, _pitch = undefined) {
    if (array_length(_g.sfxCue) >= 24) return;
    var _same = 0;
    for (var _i = 0; _i < array_length(_g.sfxCue); _i++) {
        var _e = _g.sfxCue[_i];
        if ((is_struct(_e) ? _e.n : _e) == _name) _same += 1;
    }
    if (_same >= _maxDup) return;
    var _positional = (_lane != undefined && _idx != undefined);
    if (_positional || _pitch != undefined) {
        var _cue = { n: _name };
        if (_positional) { _cue.l = _lane; _cue.i = _idx; }
        if (_pitch != undefined) _cue.p = _pitch;
        array_push(_g.sfxCue, _cue);
    } else {
        array_push(_g.sfxCue, _name);
    }
}

/// Index of a lane's treasure space, or -1 if it has none. Lanes vary in length (the tutorial's
/// short lanes, future adventure boards), so never assume the treasure sits at idx 3.
function game_lane_treasure_idx(_g, _laneIdx) {
    var _spaces = _g.board.lanes[_laneIdx].spaces;
    for (var _i = 0; _i < array_length(_spaces); _i++) {
        if (_spaces[_i].kind == "treasure") return _i;
    }
    return -1;
}

function game_setup(_g) {
    // treasure piles: deal face up until each pile is worth >= 500p
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _trIdx = game_lane_treasure_idx(_g, _laneIdx);   // boards vary in length - not always idx 3
        if (_trIdx < 0) continue;
        var _pile = [];
        var _pileVal = 0;
        while (_pileVal < global.rules.treasurePileMinValue && array_length(_g.decks.treasure) > 0) {
            var _cardId = array_pop(_g.decks.treasure);
            array_push(_pile, _cardId);
            _pileVal += treasure_def_get(_cardId).value;
        }
        array_push(_g.treasures, { cards: _pile, lane: _laneIdx, idx: _trIdx, boss: undefined });
    }
    if (game_day_day_spawns(_g)) game_fill_enemy_spaces(_g);   // POD-driven boards start bare (enemies placed via day events)
    // starting pikmin: 1 of each basic colour per HOME
    for (var _p = 0; _p < 2; _p++) {
        var _cols = _g.boardDef.basicColors;
        for (var _c = 0; _c < array_length(_cols); _c++) {
            array_push(_g.players[_p].tokens, { typeId: _cols[_c], loc: { kind: "home" } });
        }
    }
    game_log(_g, _g.boardDef.name + ": setup complete.");
}

function game_richest_bossless_pile(_g) {
    var _best = undefined;
    var _bestVal = -1;
    for (var _i = 0; _i < array_length(_g.treasures); _i++) {
        var _t = _g.treasures[_i];
        if (_t.idx != 3 || _t.boss != undefined || array_length(_t.cards) == 0) continue;
        var _topVal = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).value;
        if (_topVal > _bestVal) { _bestVal = _topVal; _best = _t; }
    }
    return _best;
}

/// When the enemy deck runs dry, shuffle the discard pile back in.
function game_enemy_deck_ensure(_g) {
    if (array_length(_g.decks.enemy) == 0 && array_length(_g.decks.enemyDiscard) > 0) {
        _g.decks.enemy = _g.decks.enemyDiscard;
        _g.decks.enemyDiscard = [];
        deck_shuffle(_g.decks.enemy);
        game_log(_g, "The defeated enemies shuffle back into the enemy deck.");
    }
}

/// Fill every empty, card-free enemy space from the enemy deck (setup / day respawn).
/// Bosses go on the richest bossless treasure pile; if none, they shuffle back in.
/// _markNew flags freshly-spawned LANE enemies (`justSpawned`) so the day cinematic
/// can pop in only the new arrivals, leaving survivors + bosses on screen.
function game_fill_enemy_spaces(_g, _markNew = false) {
    var _bossCap = global.expRules.bossCap;   // -1 no cap, 0 none, N = at most N this spawn
    var _bossesPlaced = 0;
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _space = _spaces[_spaceIdx];
            if (_space.kind != "enemy" || _space.enemy != undefined) continue;
            if (game_treasure_at(_g, _laneIdx, _spaceIdx) != undefined) continue; // treasure takes priority
            if (_space.structure != undefined) continue;
            game_enemy_deck_ensure(_g);
            var _hasNonBoss = false;
            for (var _d = 0; _d < array_length(_g.decks.enemy); _d++) {
                if (!enemy_def_get(_g.decks.enemy[_d]).boss) { _hasNonBoss = true; break; }
            }
            if (!_hasNonBoss) return;
            while (array_length(_g.decks.enemy) > 0) {
                var _enemyId = array_pop(_g.decks.enemy);
                var _enemyDef = enemy_def_get(_enemyId);
                if (_enemyDef.boss) {
                    // cap bosses per spawn instance: <0 no cap, 0 none, N = at most N
                    var _capOk = (_bossCap < 0) || (_bossesPlaced < _bossCap);
                    var _pile = _capOk ? game_richest_bossless_pile(_g) : undefined;
                    if (_pile != undefined) {
                        _pile.boss = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false };
                        _bossesPlaced += 1;
                        game_log(_g, "BOSS " + _enemyDef.name + " guards the " + treasure_def_get(_pile.cards[array_length(_pile.cards) - 1]).name + " pile!");
                    } else {
                        // no room (or capped): shuffle the boss back and keep drawing
                        array_insert(_g.decks.enemy, irandom(max(0, array_length(_g.decks.enemy) - 1)), _enemyId);
                    }
                    continue;
                }
                _space.enemy = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false, justSpawned: _markNew };
                break;
            }
        }
    }
}

// ---------- scoring: set-collection rules ----------
// Loose treasures always score face value. Series ("Set") treasures score only
// when you hold at least rules.setThreshold pieces of that series - then ALL
// held pieces of the series count.

/// _glowUp: sub-100p treasures score a flat +100 (90p -> 190p; still only count in a satisfied
/// set / as loose). _wildCount: each banked Wild is a wildcard set-member that can COMPLETE an
/// incomplete set - spent on the highest-value sets it can finish given the wilds available.
function game_treasures_realized(_cardIds, _wildCount = 0, _glowUp = false) {
    var _loose = 0;
    var _seriesCount = {};
    var _seriesVal = {};
    for (var _i = 0; _i < array_length(_cardIds); _i++) {
        var _def = treasure_def_get(_cardIds[_i]);
        var _v = _def.value;
        if (_glowUp && _v < 100) _v += 100;   // Glow Up: flat +100 to sub-100 treasures
        if (_def.effectType == "Set") {
            var _k = _def.effect;
            _seriesCount[$ _k] = (variable_struct_exists(_seriesCount, _k) ? _seriesCount[$ _k] : 0) + 1;
            _seriesVal[$ _k] = (variable_struct_exists(_seriesVal, _k) ? _seriesVal[$ _k] : 0) + _v;
        } else {
            _loose += _v;
        }
    }
    var _total = _loose;
    var _threshold = global.rules.setThreshold;
    var _names = variable_struct_get_names(_seriesCount);
    var _incomplete = [];   // sets short of the threshold: { val, need }
    for (var _i = 0; _i < array_length(_names); _i++) {
        var _c = _seriesCount[$ _names[_i]];
        if (_c >= _threshold) _total += _seriesVal[$ _names[_i]];
        else array_push(_incomplete, { val: _seriesVal[$ _names[_i]], need: _threshold - _c });
    }
    // Wild: spend wildcard members to finish incomplete sets, highest value first
    if (_wildCount > 0 && array_length(_incomplete) > 0) {
        array_sort(_incomplete, function(_a, _b) { return _b.val - _a.val; });
        var _wl = _wildCount;
        for (var _i = 0; _i < array_length(_incomplete) && _wl > 0; _i++) {
            if (_wl >= _incomplete[_i].need) { _wl -= _incomplete[_i].need; _total += _incomplete[_i].val; }
        }
    }
    return _total;
}

/// A player's realized score, applying their persistent Wild / Glow Up hoard passives.
function game_realized_score(_g, _p) {
    var _pl = _g.players[_p];
    var _wild = variable_struct_exists(_pl, "wildCount") ? _pl.wildCount : 0;
    var _glow = variable_struct_exists(_pl, "glowUp") ? _pl.glowUp : false;
    return game_treasures_realized(_pl.collected, _wild, _glow);
}

/// Group a player's collected treasures for display: loose group first, then each
/// series with its count, points, and whether it has hit the scoring threshold.
/// Returns { score, groups: [ { name, isLoose, ids, count, value, active } ] }.
function game_collection_summary(_g, _p) {
    var _coll = _g.players[_p].collected;
    var _pl = _g.players[_p];
    var _glow = variable_struct_exists(_pl, "glowUp") ? _pl.glowUp : false;
    var _loose = { name: "Loose Treasures", isLoose: true, ids: [], count: 0, value: 0, active: true };
    var _seriesMap = {};
    var _order = [];
    for (var _i = 0; _i < array_length(_coll); _i++) {
        var _def = treasure_def_get(_coll[_i]);
        // apply the persistent Glow Up passive so group subtotals match the realized score
        var _v = _def.value;
        if (_glow && _v < 100) _v += 100;
        if (_def.effectType == "Set") {
            var _k = _def.effect;
            if (!variable_struct_exists(_seriesMap, _k)) {
                var _grp = { name: _def.effect, isLoose: false, ids: [], count: 0, value: 0, active: false };
                _seriesMap[$ _k] = _grp;
                array_push(_order, _grp);
            }
            var _s = _seriesMap[$ _k];
            array_push(_s.ids, _coll[_i]);
            _s.count += 1;
            _s.value += _v;
        } else {
            array_push(_loose.ids, _coll[_i]);
            _loose.count += 1;
            _loose.value += _v;
        }
    }
    var _threshold = global.rules.setThreshold;
    var _groups = [];
    if (_loose.count > 0) array_push(_groups, _loose);
    for (var _i = 0; _i < array_length(_order); _i++) {
        _order[_i].active = (_order[_i].count >= _threshold);
        array_push(_groups, _order[_i]);
    }
    return { score: game_realized_score(_g, _p), groups: _groups };
}

// ---------- queries ----------

function game_loc_eq(_a, _b) {
    if (_a.kind != _b.kind) return false;
    if (_a.kind == "home") return true;
    return (_a.lane == _b.lane && _a.idx == _b.idx);
}

function game_treasure_at(_g, _lane, _idx) {
    for (var _i = 0; _i < array_length(_g.treasures); _i++) {
        var _t = _g.treasures[_i];
        if (_t.lane == _lane && _t.idx == _idx) return _t;
    }
    return undefined;
}

function game_tokens_at(_g, _p, _loc) {
    var _out = [];
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (game_loc_eq(_tokens[_i].loc, _loc)) array_push(_out, _tokens[_i]);
    }
    return _out;
}

/// Read-only: may player _p's pending gather card (_effectId) legally target space
/// (_lane,_idx)? Mirrors the space-stage validity checks in game_play_gather so the UI can
/// light up every eligible target. Cards that genuinely accept ANY space return true (the
/// whole board lights); the rest gate to their real footprint. Never mutates state.
function game_gather_target_eligible(_g, _p, _effectId, _lane, _idx) {
    if (_lane < 0 || _lane >= _g.board.laneCount) return false;
    var _spaces = _g.board.lanes[_lane].spaces;
    if (_idx < 0 || _idx >= array_length(_spaces)) return false;
    var _space = _spaces[_idx];
    var _hasCard = game_space_has_card(_g, _lane, _idx);
    var _tre = game_treasure_at(_g, _lane, _idx);
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    switch (_effectId) {
        case "phosbatpod":  // spawns an enemy on an empty enemy-kind space
            return (_space.kind == "enemy" && _space.enemy == undefined && _tre == undefined && _space.structure == undefined);
        case "rawmaterial": // builds a wall/bridge on an empty space
            return (!_hasCard && _space.structure == undefined);
        case "rockstorm":   // drops an emitter on a non-hazard empty space
            return (_space.kind != "hazard" && !_hasCard && _space.structure == undefined);
        case "candypopbud": case "queencandypopbud": case "candypopbud2": case "ivoryandviolet":
            return (array_length(game_tokens_at(_g, _p, _loc)) > 0); // needs your pikmin there
        case "bitterspray": // petrifies an enemy/boss on the space
            return (_space.enemy != undefined || (_tre != undefined && _tre.boss != undefined));
        case "surveydrone": // shuffles a pile of 2+
            return (_tre != undefined && array_length(_tre.cards) >= 2);
        case "icebomb":     // freezes any creatures standing on the space
            return (_space.enemy != undefined || (_tre != undefined && _tre.boss != undefined)
                    || array_length(game_tokens_at(_g, 0, _loc)) > 0 || array_length(game_tokens_at(_g, 1, _loc)) > 0);
        default:            // bomb rock / boulder / spicy spray / storm anchor / etc: any space
            return true;
    }
}

/// Is (lane) a legal Oatchi Rush target for player _p? A non-boss treasure on the OPPONENT'S side
/// with a clear path from your end to it. Mirrors the gate in game_play_gather's oatchirush case;
/// used by the UI to light the whole target lane.
function game_oatchirush_lane_ok(_g, _p, _lane) {
    if (_lane < 0 || _lane >= _g.board.laneCount) return false;
    var _t = undefined;
    for (var _i = 0; _i < array_length(_g.treasures); _i++) if (_g.treasures[_i].lane == _lane) { _t = _g.treasures[_i]; break; }
    if (_t == undefined || _t.boss != undefined) return false;
    if (_p == 0 && _t.idx <= 3) return false;
    if (_p == 1 && _t.idx >= 3) return false;
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    while (_s != _t.idx) { if (game_space_has_card(_g, _lane, _s)) return false; _s += _dir; }
    return true;
}

function token_is_frozen(_tok) {
    return variable_struct_exists(_tok, "frozen") && _tok.frozen > 0;
}

/// Incapacitated = frozen (ice/storm/bitter) OR stunned (snitchbug-buried). BOTH
/// block moving, fighting and carrying - no form of stun is movement-only (user
/// ruling); the fields differ only in source and visuals.
function token_is_disabled(_tok) {
    if (token_is_frozen(_tok)) return true;
    return variable_struct_exists(_tok, "stunned") && _tok.stunned > 0;
}

function game_strength_at(_g, _p, _lane, _idx) {
    var _sum = 0;
    var _here = game_tokens_at(_g, _p, { kind: "space", lane: _lane, idx: _idx });
    for (var _i = 0; _i < array_length(_here); _i++) {
        if (token_is_disabled(_here[_i])) continue; // frozen/buried pikmin don't act
        _sum += pikmin_type_get(_here[_i].typeId).carry;
    }
    return _sum;
}

function game_counts_struct(_g, _p, _loc) {
    var _counts = {};
    var _here = game_tokens_at(_g, _p, _loc);
    for (var _i = 0; _i < array_length(_here); _i++) {
        var _typeId = _here[_i].typeId;
        _counts[$ _typeId] = (variable_struct_exists(_counts, _typeId) ? _counts[$ _typeId] : 0) + 1;
    }
    return _counts;
}

function game_space_has_card(_g, _lane, _idx) {
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.enemy != undefined) return true;
    if (_space.structure != undefined && hazard_def_get(_space.structure.structId).type != "bridge") return true;
    return game_treasure_at(_g, _lane, _idx) != undefined;
}

/// Does the card/blocker on this tile stop THIS type from passing THROUGH it?
/// This is the "wall in the middle of the tile": a token latched on such a blocker
/// stands on the half it approached from and cannot cross to the far side while the
/// blocker lives (mirrors game_dest_legal's pass-through gates: enemies and carried
/// treasure hard-block everyone; walls block everyone; emitters/hazards only gate
/// non-immune). Bridges and cards this type walks over freely are NOT walls.
function game_tile_blocks_pass(_g, _typeDef, _lane, _idx, _waterOk = false) {
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.enemy != undefined) return true;
    if (game_treasure_at(_g, _lane, _idx) != undefined) return true;
    // _towardCenter is irrelevant for real cards (walls/emitters gate both ways); pass
    // false. Bare directional terrain (height) carries no card, so it isn't a wall here.
    if (_space.structure != undefined) return !game_type_can_enter(_typeDef, _space, false, false, _waterOk, game_no_imm(_g));
    return false;
}

/// The half of a blocker tile a token occupies: -1 = the low-index (idx-1) half,
/// +1 = the high-index (idx+1) half. Stored on the token when it latches. Absent /
/// 0 defaults to the type's HOME-facing half (the overwhelmingly common latch), so
/// legacy tokens and mid-game saves still can't cross a card they're stuck against.
function game_token_side(_tok, _p) {
    if (variable_struct_exists(_tok, "side") && _tok.side != 0) return _tok.side;
    return (_p == 0) ? -1 : 1;
}

/// Representative latch-side of the group standing at _loc (for reachability queries
/// that only have a location, e.g. the AI's move planning). Empty / non-space locs
/// give 0 = no confinement.
function game_loc_side(_g, _p, _loc) {
    if (_loc.kind != "space") return 0;
    var _here = game_tokens_at(_g, _p, _loc);
    if (array_length(_here) == 0) return 0;
    return game_token_side(_here[0], _p);
}

/// Can this pikmin type stand on / pass this space? Height is one-way (gated only
/// when heading toward the treasure space). Structures: bridges carry anyone over;
/// walls block passage but can be attacked as a destination; emitters behave as a
/// floor hazard of their element (immune pass free) but can be ATTACKED by anyone
/// (non-immune die doing so - handled in combat), so they're legal destinations.
/// _isDest: this is the final target square (attacking), not a pass-through.
/// _noImm (adventure "Rebooting..." event): elemental IMMUNITIES don't function this turn, so an
/// immune type is blocked by the hazard/emitter as if it weren't immune. TRAITS (winged flight,
/// rock climbing) are NOT immunities and still work.
function game_type_can_enter(_typeDef, _space, _towardCenter, _isDest = false, _waterOk = false, _noImm = false) {
    if (_space.structure != undefined) {
        var _sDef = hazard_def_get(_space.structure.structId);
        if (_sDef.type == "bridge") return true;
        if (_sDef.type == "wall") return _isDest; // attack it as a destination; never pass through
        // emitter: any pikmin may be assigned to attack it...
        if (_isDest) return true;
        // POISON never blocks - anyone walks over it (it damages on passing, not here)
        if (_sDef.element == "poison") return true;
        // ...other emitters block passage for non-immune (floor-hazard element gate)
        if (_sDef.element != "" && !(!_noImm && arr_has(_typeDef.immunities, _sDef.element))
            && !arr_has(_typeDef.traits, "flies_over_hazards")) return false;
        return true;
    }
    if (_space.kind != "hazard") return true;
    var _fly = arr_has(_typeDef.traits, "flies_over_hazards");   // winged: ignores GROUND hazards (a TRAIT, not a chip - Rebooting keeps it)
    switch (_space.hazard) {
        // HEIGHT is an ELEMENT/chip (yellow, winged): one-way - free downhill; uphill / toward-centre
        // needs the Height element (so Rebooting, which suppresses chips, blocks it).
        case "height": return !_towardCenter || (!_noImm && arr_has(_typeDef.immunities, "height"));
        // CHASM is only ever a GROUND hazard: winged flies over it; yellow's experimental throw crosses inward.
        case "chasm":  return _fly || (global.expRules.yellow && _typeDef.id == "yellow" && _towardCenter);
        // ground element (water/fire/electric/ice): the matching element (chip) OR winged flying over.
        // blue lifeguard (_waterOk) crosses a covered group over water.
        case "water":  return (!_noImm && arr_has(_typeDef.immunities, "water")) || _waterOk || _fly;
        case "poison": return true;         // non-blocking; damages on pass (game_poison_step / poison_resolve)
        // ICE FLOOR (experimental): ice is an ACCESSIBLE floor for everyone - any pikmin may enter/stand on
        // it. The catch (a non-ice pikmin can't step OFF ice toward centre onto non-ice) is a PATH property,
        // enforced in the reachability walks below; per-space, ice is just passable when the rule is on.
        case "ice":    if (global.expRules.iceFloor) return true;
                       return (!_noImm && arr_has(_typeDef.immunities, "ice")) || _fly;
        default:       return (!_noImm && arr_has(_typeDef.immunities, _space.hazard)) || _fly;
    }
}

/// True while the "Rebooting..." event is suppressing elemental immunities this turn.
function game_no_imm(_g) {
    return variable_struct_exists(_g, "advNoImmunities") && _g.advNoImmunities;
}

/// A space is poisonous if it's a poison map-hazard or holds a Poison Emitter.
function game_space_is_poison(_g, _lane, _idx) {
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    // a bridge laid over the space carries pikmin ABOVE the poison floor - safe for everyone,
    // immunity or not (bridging a hazard is exactly what neutralizes it). This is immunity-
    // independent, so it still protects under the "Rebooting..." (immunities-off) event.
    if (_sp.structure != undefined && hazard_def_get(_sp.structure.structId).type == "bridge") return false;
    if (_sp.kind == "hazard" && _sp.hazard == "poison") return true;
    if (_sp.structure != undefined) {
        var _d = hazard_def_get(_sp.structure.structId);
        if (_d.type == "hazard" && _d.element == "poison") return true;
    }
    return false;
}

/// Poison-immune = white/bulbmin (immunity) or winged (flies over). _noImm ("Rebooting...")
/// suppresses the poison IMMUNITY, but winged flight is a TRAIT and still avoids it.
function game_type_poison_immune(_typeId, _noImm = false) {
    var _d = pikmin_type_get(_typeId);
    return (!_noImm && arr_has(_d.immunities, "poison")) || arr_has(_d.traits, "flies_over_hazards");
}

/// Every space an orders move from _src to _dst makes the group EXIT
/// (source + intermediates, but not the destination it stops on).
function game_path_exited_spaces(_g, _p, _src, _dst) {
    var _out = [];
    var _lane, _from, _to;
    if (_src.kind == "space" && _dst.kind == "space") {
        if (_src.lane != _dst.lane) return _out;
        _lane = _src.lane; _from = _src.idx; _to = _dst.idx;
    } else if (_src.kind == "home" && _dst.kind == "space") {
        _lane = _dst.lane; _from = (_p == 0) ? -1 : 7; _to = _dst.idx; // home lies beyond the edge
    } else if (_src.kind == "space" && _dst.kind == "home") {
        _lane = _src.lane; _from = _src.idx; _to = (_p == 0) ? -1 : 7;
    } else {
        return _out; // home -> home
    }
    var _laneLen = array_length(_g.board.lanes[_lane].spaces);
    var _step = (_to > _from) ? 1 : -1;
    var _s = _from;
    while (_s != _to) { // includes src (exited), excludes dst (entered, not exited)
        if (_s >= 0 && _s < _laneLen) array_push(_out, { lane: _lane, idx: _s, key: string(_lane) + "_" + string(_s) });
        _s += _step;
    }
    return _out;
}

function game_mine_at(_g, _lane, _idx) {
    for (var _i = 0; _i < array_length(_g.mines); _i++) {
        if (_g.mines[_i].lane == _lane && _g.mines[_i].idx == _idx) return _g.mines[_i];
    }
    return undefined;
}

function game_mine_damage(_g, _mine, _n) {
    if (_n <= 0) return;
    var _was = _mine.dmg;
    _mine.dmg += _n;
    if (_was < 10 && _mine.dmg >= 10) game_log(_g, "The Mine in lane " + string(_mine.lane + 1) + " ARMS - anything ending there dies!");
}

/// Append a poison-space key to a token's exposure list (init if needed).
function token_poison_add(_tok, _key) {
    if (!variable_struct_exists(_tok, "poisonSpaces")) _tok.poisonSpaces = [];
    if (!arr_has(_tok.poisonSpaces, _key)) array_push(_tok.poisonSpaces, _key);
}

/// Orders-phase legality: can a token of this type be assigned to (lane, idx)?
/// Walks the whole lane from the player's end - crossing onto the opponent's side
/// is allowed. Enemies, walls and carried treasure hard-block passing beyond them;
/// emitters and floor hazards only block non-immune pikmin. The target square
/// itself is legal if the type can enter/attack it. Height is one-way relative to
/// the treasure space.
/// A plain ICE FLOOR tile (not a wall/structure). Used by the iceFloor movement rule.
function game_space_is_ice(_sp) {
    return _sp.kind == "hazard" && _sp.hazard == "ice";
}
/// # of non-disabled ICE pikmin (either player) standing on (lane,idx).
function game_ice_freezers_at(_g, _lane, _idx) {
    var _n = 0;
    for (var _q = 0; _q < 2; _q++) {
        var _toks = _g.players[_q].tokens;
        for (var _t = 0; _t < array_length(_toks); _t++) {
            var _tk = _toks[_t];
            if (_tk.typeId == "ice" && _tk.loc.kind == "space" && _tk.loc.lane == _lane && _tk.loc.idx == _idx && !token_is_disabled(_tk)) _n += 1;
        }
    }
    return _n;
}
/// FREEZE WATER (experimental iceFreezeWater): a WATER tile held by >=3 ICE pikmin (and with NO treasure
/// on it - freezers can't also be carrying) turns to ICE while they hold it, and reverts to water when
/// they leave. `frozenWater` marks a tile WE converted, so we only ever thaw our own conversions (never a
/// real ice tile). Recomputed at turn start + each resolve beat, so rules 1 (floor) + 2 (slide) then apply
/// to the frozen run. Bumps tileVersion so the tile re-colours. No-op unless the rule is on.
function game_freeze_update(_g) {
    if (!global.expRules.iceFreezeWater) return;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sps = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sps); _i++) {
            var _sp = _sps[_i];
            var _frozen = variable_struct_exists(_sp, "frozenWater") && _sp.frozenWater;
            var _hold = (game_treasure_at(_g, _l, _i) == undefined) && (game_ice_freezers_at(_g, _l, _i) >= 3);
            if (_frozen && !_hold) { _sp.hazard = "water"; _sp.frozenWater = false; _g.tileVersion += 1; }   // freezers gone / a pile arrived -> thaw
            else if (!_frozen && _sp.kind == "hazard" && _sp.hazard == "water" && _hold) { _sp.hazard = "ice"; _sp.frozenWater = true; _g.tileVersion += 1; }
        }
    }
}
function game_dest_legal(_g, _p, _typeId, _lane, _idx, _waterOk = false) {
    var _typeDef = pikmin_type_get(_typeId);
    var _laneLen = array_length(_g.board.lanes[_lane].spaces);
    var _peak = _g.board.peakRow;
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : _laneLen - 1;
    var _prevDist = abs(((_p == 0) ? -1 : _laneLen) - _peak); // HOME sits beyond the outermost space
    // ICE FLOOR rule for a NON-ice pikmin: it may stand anywhere on a run of ice, but it can't step OFF
    // the ice TOWARD CENTRE onto a non-ice tile - it entered the ice from the HOME side, so it can only
    // leave that way (retreat) or onto more ice. Directional (toward-centre = _toward); applies whether
    // it's crossing into the ice this move OR already standing on it.
    var _iceRule = global.expRules.iceFloor && !arr_has(_typeDef.immunities, "ice");
    var _prevIce = false;       // HOME (beyond the edge) is not ice
    while (_s != _idx) {
        var _toward = abs(_s - _peak) < _prevDist;
        var _space = _g.board.lanes[_lane].spaces[_s];
        if (_space.enemy != undefined) return false;                 // fight it, or stop short of it
        if (game_treasure_at(_g, _lane, _s) != undefined) return false;
        if (_iceRule && _prevIce && _toward && !game_space_is_ice(_space)) return false;   // no forward exit off the ice
        if (!game_type_can_enter(_typeDef, _space, _toward, false, _waterOk, game_no_imm(_g))) return false; // wall / non-immune hazard
        _prevIce = game_space_is_ice(_space);
        _prevDist = abs(_s - _peak);
        _s += _dir;
        if (_s < 0 || _s >= _laneLen) return false;
    }
    var _towardDest = abs(_idx - _peak) < _prevDist;
    if (_iceRule && _prevIce && _towardDest && !game_space_is_ice(_g.board.lanes[_lane].spaces[_idx])) return false;
    return game_type_can_enter(_typeDef, _g.board.lanes[_lane].spaces[_idx], _towardDest, true, _waterOk, game_no_imm(_g));
}

/// Blue lifeguard (experimental): may this move's group cross water? True when the
/// group has at least one water-immune "lifeguard" per non-immune, non-flying
/// pikmin that needs carrying. Counts the tokens moving together; if the landing
/// space is itself water, the pikmin already standing there count too (they must
/// keep being covered). Off entirely unless the blue rule is toggled on.
function game_lifeguard_ok(_g, _p, _dst, _counts) {
    if (!global.expRules.blue) return false;
    var _lifeguards = 0;
    var _needCarry = 0;
    var _cols = variable_struct_get_names(_counts);
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _n = _counts[$ _cols[_c]];
        if (_n <= 0) continue;
        var _td = pikmin_type_get(_cols[_c]);
        if (arr_has(_td.immunities, "water")) _lifeguards += _n;
        else if (!arr_has(_td.traits, "flies_over_hazards")) _needCarry += _n;
    }
    // landing ON a water space? the pikmin already standing there must stay covered
    // too. (Returning HOME across water only needs the moving group to self-cover.)
    if (_dst.kind == "space") {
        var _destSp = _g.board.lanes[_dst.lane].spaces[_dst.idx];
        if (_destSp.kind == "hazard" && _destSp.hazard == "water") {
            var _here = game_tokens_at(_g, _p, _dst);
            for (var _i = 0; _i < array_length(_here); _i++) {
                var _td2 = pikmin_type_get(_here[_i].typeId);
                if (arr_has(_td2.immunities, "water")) _lifeguards += 1;
                else if (!arr_has(_td2.traits, "flies_over_hazards")) _needCarry += 1;
            }
        }
    }
    return _lifeguards >= _needCarry;
}

/// Can a field token trace its lane back to HOME? Pikmin reposition by retreating
/// to home and redeploying, so a move is only real if they can actually get home.
/// Walks src -> home edge (moving away from the centre), honouring the SAME hazard
/// gates as deploying - but direction matters: height is one-way, a chasm a yellow
/// crossed inward can't be recrossed, etc. Enemies/piles between it and home block
/// the retreat just as they'd block a deploy. A token that can't reach home is
/// trapped and may only attach to a card it can still walk to (see game_move_legal).
function game_can_reach_home(_g, _p, _typeId, _lane, _srcIdx, _waterOk = false) {
    var _typeDef = pikmin_type_get(_typeId);
    var _peak = _g.board.peakRow;
    var _dir = (_p == 0) ? -1 : 1;               // toward this player's home edge
    var _homeEdge = (_p == 0) ? 0 : array_length(_g.board.lanes[_lane].spaces) - 1;
    var _s = _srcIdx;
    var _prevDist = abs(_srcIdx - _peak);
    // ICE FLOOR: retreating toward HOME needs no ice check at all - a lane can only ever be entered from
    // its own home edge, so heading home is always "the way you came" and never blocked by the rule
    // (only the toward-centre exit off ice is restricted; see game_dest_legal / game_direct_reachable).
    while (_s != _homeEdge) {
        _s += _dir;
        var _toward = abs(_s - _peak) < _prevDist;   // this step heads toward the centre / uphill?
        var _space = _g.board.lanes[_lane].spaces[_s];
        if (_space.enemy != undefined) return false;
        if (game_treasure_at(_g, _lane, _s) != undefined) return false;
        if (!game_type_can_enter(_typeDef, _space, _toward, false, _waterOk, game_no_imm(_g))) return false;
        _prevDist = abs(_s - _peak);
    }
    return true;
}

/// Can a field token walk straight along its lane from src to dst (no home trip)?
/// Used for the "attach to a card behind/ahead of you" exception: intermediate
/// spaces must be standable and unblocked, and the destination enterable/attackable.
function game_direct_reachable(_g, _p, _typeId, _lane, _srcIdx, _dstIdx, _srcSide = 0) {
    if (_srcIdx == _dstIdx) return true;
    var _typeDef = pikmin_type_get(_typeId);
    // MID-TILE WALL: when the caller knows which half of the src blocker this token
    // sits on (_srcSide != 0), it can't cross to the far side. Callers that don't
    // track a side (the human group gate) pass 0 and enforce per-token in the mover.
    if (_srcSide != 0 && game_tile_blocks_pass(_g, _typeDef, _lane, _srcIdx)
        && sign(_dstIdx - _srcIdx) != _srcSide) return false;
    var _peak = _g.board.peakRow;
    var _dir = (_dstIdx > _srcIdx) ? 1 : -1;
    var _s = _srcIdx;
    var _prevDist = abs(_srcIdx - _peak);
    // ICE FLOOR: same directional rule as game_dest_legal - can't step off ice TOWARD CENTRE onto non-ice
    // (this function can walk either direction, so gate on the per-step _toward flag, not an assumed
    // direction). Retreat-direction steps off ice are never blocked.
    var _iceRule = global.expRules.iceFloor && !arr_has(_typeDef.immunities, "ice");
    var _prevIce = game_space_is_ice(_g.board.lanes[_lane].spaces[_srcIdx]);   // the tile it's standing on
    while (_s != _dstIdx) {
        _s += _dir;
        var _toward = abs(_s - _peak) < _prevDist;
        var _space = _g.board.lanes[_lane].spaces[_s];
        var _isDest = (_s == _dstIdx);
        if (_iceRule && _prevIce && _toward && !game_space_is_ice(_space)) return false;   // no forward exit off the ice
        if (!_isDest) {
            if (_space.enemy != undefined) return false;
            if (game_treasure_at(_g, _lane, _s) != undefined) return false;
            if (!game_type_can_enter(_typeDef, _space, _toward, false, false, game_no_imm(_g))) return false;
        } else if (!game_type_can_enter(_typeDef, _space, _toward, true, false, game_no_imm(_g))) {
            return false;
        }
        _prevIce = game_space_is_ice(_space);
        _prevDist = abs(_s - _peak);
    }
    return true;
}

/// Full move legality accounting for where the token currently IS, not just the
/// deploy path from home. From home: the usual deploy check. From the field: it
/// must be able to retreat home AND deploy, OR (if trapped) walk directly to a card
/// on its own lane. Moving TO home requires being able to reach home at all.
function game_move_legal(_g, _p, _typeId, _src, _dst, _waterOk = false, _srcSide = 0) {
    if (_dst.kind == "home") {
        if (_src.kind == "home") return true;
        // a token pinned to the far (centre) half of a blocker can't retreat across it
        if (_srcSide != 0 && game_tile_blocks_pass(_g, pikmin_type_get(_typeId), _src.lane, _src.idx)
            && ((_p == 0) ? -1 : 1) != _srcSide) return false;
        return game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk);
    }
    if (_src.kind == "home") {
        return game_dest_legal(_g, _p, _typeId, _dst.lane, _dst.idx, _waterOk);
    }
    // field -> space
    if (game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk)
        && game_dest_legal(_g, _p, _typeId, _dst.lane, _dst.idx, _waterOk)) return true;
    // trapped, but may still walk to any space it can reach along this lane - a card
    // to attach to, OR an empty space to reposition onto (game_direct_reachable already
    // proves the destination is standable and nothing blocks the path). _srcSide (when
    // the caller tracks it) keeps a latched token on its own half of a blocker.
    if (_src.lane == _dst.lane
        && game_direct_reachable(_g, _p, _typeId, _src.lane, _src.idx, _dst.idx, _srcSide)) return true;
    return false;
}

/// Target location from card args: {atHome:true} means the player's own HOME.
function game_args_loc(_args) {
    if (variable_struct_exists(_args, "atHome") && _args.atHome) return { kind: "home" };
    return { kind: "space", lane: _args.lane, idx: _args.idx };
}

// ---------- population history (end-of-run graph) ----------

/// Total population by pikmin type for one seat (home reserves + field, the whole colour count).
function game_pop_counts(_g, _p) {
    var _c = {};
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) {
        var _t = _toks[_i].typeId;
        _c[$ _t] = (variable_struct_exists(_c, _t) ? _c[$ _t] : 0) + 1;
    }
    return _c;
}

/// Append a phase snapshot of every seat's colour counts (skips a no-op duplicate of the last one
/// with the same label, so repeated gather rolls don't spam points). Guarded for old/partial states.
function game_pop_snapshot(_g, _label) {
    if (!variable_struct_exists(_g, "popHistory") || !is_array(_g.popHistory)) _g.popHistory = [];
    var _seats = [];
    for (var _p = 0; _p < array_length(_g.players); _p++) array_push(_seats, game_pop_counts(_g, _p));
    array_push(_g.popHistory, { label: _label, day: _g.dayNumber, seats: _seats });
}

// ---------- turn flow ----------

function game_begin_turn(_g) {
    game_freeze_update(_g);   // ice pikmin stationed on water tiles freeze them (rule iceFreezeWater); reflect it before this turn's planning
    // baseline point at the very start of the game, so every colour's line begins at its kit count
    if (!variable_struct_exists(_g, "popHistory") || array_length(_g.popHistory) == 0) game_pop_snapshot(_g, "Start");
    _g.phase = "gather";
    _g.soothed = false;   // a Soothe power only lasts the turn it was banked
    _g.dayRawFree = false; _g.dayPelletBonus = false;   // per-turn day-event modifiers (flarlicBonus persists)
    var _pl = _g.players[_g.activePlayer];
    _g.gatherActionsLeft = (_pl.turnsTaken == 0) ? 3 : 2;
    // snitchbug stuns / ice freezes wear off over the owner's turn starts; reset per-turn flags
    for (var _i = 0; _i < array_length(_pl.tokens); _i++) {
        var _tok = _pl.tokens[_i];
        if (variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) _tok.stunned -= 1;
        if (variable_struct_exists(_tok, "frozen") && _tok.frozen > 0) _tok.frozen -= 1;
        _tok.movedThisTurn = false;
        _tok.poisonSpaces = [];
        // committed-route anchor: poison exposure is judged from HERE to wherever the
        // token ends the orders phase (re-planning mid-orders doesn't count)
        _tok.turnStartLoc = (_tok.loc.kind == "home") ? { kind: "home" } : { kind: "space", lane: _tok.loc.lane, idx: _tok.loc.idx };
        // idle poison: starting the turn on poison while HOLDING NOTHING (no enemy /
        // pile / structure on the space) counts as re-entering it - metaphysically
        // you walked back in from the other player's turn. Carrying/fighting groups
        // are braced on their card and exempt, so a hauled pile never pays twice.
        if (_tok.loc.kind == "space" && game_space_is_poison(_g, _tok.loc.lane, _tok.loc.idx)
            && !game_space_has_card(_g, _tok.loc.lane, _tok.loc.idx)) {
            token_poison_add(_tok, string(_tok.loc.lane) + "_" + string(_tok.loc.idx));
        }
    }
    game_trace(_g, "");
    game_trace(_g, "===== HUMAN TURN P" + string(_g.activePlayer + 1) + "  Day " + string(_g.dayNumber)
        + " (" + string(_g.dayTrack) + "/" + string(_g.dayTrackLength) + ")  score "
        + string(game_realized_score(_g, _g.activePlayer)) + " vs " + string(game_realized_score(_g, 1 - _g.activePlayer)) + " =====");
    game_log(_g, "== Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(_g.dayTrackLength) + ") - Player " + string(_g.activePlayer + 1) + "'s turn ==");
    // AFTER the turn header, fire + log this segment's day-track event (if any). _phaseStart
    // (round's first player) gates the AUTOMATIC/global events so they land + log once.
    game_day_track_fire(_g, _g.activePlayer == _g.firstPlayer);
    // ADVENTURE: draw + apply this turn's random event (replaces the blanked day-track events)
    game_adv_event_step(_g);
    // remove this player's leftover spray tokens from a previous turn
    var _si = 0;
    while (_si < array_length(_g.sprays)) {
        if (_g.sprays[_si].playerIdx == _g.activePlayer) { array_delete(_g.sprays, _si, 1); continue; }
        _si += 1;
    }
}

function game_gather_draw(_g) {
    if (_g.phase != "gather" || _g.gatherActionsLeft <= 0) return;
    if (array_length(_g.decks.gather) == 0 && array_length(_g.decks.gatherDiscard) > 0) {
        _g.decks.gather = _g.decks.gatherDiscard;
        _g.decks.gatherDiscard = [];
        deck_shuffle(_g.decks.gather);
        game_log(_g, "Gather discard shuffled back into the deck.");
    }
    if (array_length(_g.decks.gather) == 0) { game_log(_g, "Gather deck is empty!"); return; }
    array_push(_g.players[_g.activePlayer].hand, array_pop(_g.decks.gather));
    game_log(_g, "P" + string(_g.activePlayer + 1) + " draws a gather card."); // never the name - hidden info
    game_spend_gather_action(_g);
}

/// Roll the board's pellet die. Returns a face {color, value}, or undefined for a BLANK face
/// (a face with `blank:true`) or an EMPTY die - a barren roll grants nothing. Lets a board ship a
/// fully-barren die (pelletDie: []) or a partial one (mix blank faces with real ones).
function game_die_roll(_g) {
    var _die = _g.boardDef.pelletDie;
    if (array_length(_die) == 0) return undefined;
    var _face = _die[irandom(array_length(_die) - 1)];
    if (variable_struct_exists(_face, "blank") && _face.blank) return undefined;
    return _face;
}

function game_gather_roll(_g) {
    if (_g.phase != "gather" || _g.gatherActionsLeft <= 0) return;
    var _face = game_die_roll(_g);
    if (_face != undefined) {
        array_push(_g.players[_g.activePlayer].pellets, _face.color + string(_face.value));
        game_log(_g, "P" + string(_g.activePlayer + 1) + " rolls " + string(_face.value) + string_upper(string_char_at(_face.color, 1)));
    } else {
        game_log(_g, "P" + string(_g.activePlayer + 1) + " rolls a blank - nothing gained.");
    }
    game_spend_gather_action(_g);
}

function game_spend_gather_action(_g) {
    _g.gatherActionsLeft -= 1;
    if (_g.gatherActionsLeft <= 0) { _g.phase = "orders"; game_pop_snapshot(_g, "Gather"); } // phase shown in the UI; no log line
}

/// Spaces a token ENTERS along its committed net route (src exclusive, dst inclusive).
/// Lane changes route via HOME: an out-leg down the old lane, an in-leg up the new one.
function game_route_entered_spaces(_p, _src, _dst) {
    var _out = [];
    if (_src.kind == "space" && _dst.kind == "space" && _src.lane == _dst.lane) {
        var _step = (_dst.idx > _src.idx) ? 1 : -1;
        for (var _s = _src.idx + _step; ; _s += _step) { array_push(_out, { lane: _src.lane, idx: _s }); if (_s == _dst.idx) break; }
        return _out;
    }
    var _edgeOut = (_p == 0) ? 0 : 6;
    if (_src.kind == "space" && _src.idx != _edgeOut) {
        var _stepO = (_edgeOut > _src.idx) ? 1 : -1;
        for (var _s = _src.idx + _stepO; ; _s += _stepO) { array_push(_out, { lane: _src.lane, idx: _s }); if (_s == _edgeOut) break; }
    }
    if (_dst.kind == "space") {
        var _from = (_p == 0) ? -1 : 7;
        var _stepI = (_dst.idx > _from) ? 1 : -1;
        for (var _s = _from + _stepI; ; _s += _stepI) { array_push(_out, { lane: _dst.lane, idx: _s }); if (_s == _dst.idx) break; }
    }
    return _out;
}

/// Poison exposure ticks the moment orders LOCK IN - before any combat or carry.
/// Each poison space claims 1 pikmin per colour among those whose committed net
/// route (turn start -> final position) ENTERED it. Re-planning away doesn't count.
function game_orders_done(_g) {
    if (_g.phase != "orders") return;
    var _p = _g.activePlayer;
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        if (!variable_struct_exists(_tok, "turnStartLoc")) continue;
        if (game_loc_eq(_tok.turnStartLoc, _tok.loc)) continue;
        var _ent = game_route_entered_spaces(_p, _tok.turnStartLoc, _tok.loc);
        for (var _e = 0; _e < array_length(_ent); _e++) {
            if (game_space_is_poison(_g, _ent[_e].lane, _ent[_e].idx)) {
                token_poison_add(_tok, string(_ent[_e].lane) + "_" + string(_ent[_e].idx));
            }
        }
    }
    game_poison_resolve(_g, _p);
    // trace the lock-in with what stayed home (parallels the AI's "remaining homeStr")
    if (variable_struct_exists(_g, "trace") && _g.trace[_p]) {
        var _homeStr = 0;
        var _htoks = _g.players[_p].tokens;
        for (var _hi = 0; _hi < array_length(_htoks); _hi++) {
            if (_htoks[_hi].loc.kind == "home") _homeStr += pikmin_type_get(_htoks[_hi].typeId).carry;
        }
        game_trace(_g, "ORDERS LOCKED (homeStr left=" + string(_homeStr) + ")");
    }
    _g.phase = "move";
    game_pop_snapshot(_g, "Orders");
}

/// Reassign tokens (per-colour counts struct) from _src to _dst. Illegal colours
/// stay put and are logged. Returns true if anything moved.
function game_order_move(_g, _src, _dst, _counts) {
    if (_g.phase != "orders") return false;
    var _p = _g.activePlayer;
    var _movedAny = false;
    // blue lifeguard: decide once for the whole group whether it can ford water
    var _waterOk = game_lifeguard_ok(_g, _p, _dst, _counts);
    var _colors = variable_struct_get_names(_counts);
    // order-reaction "ah" budget: cap the whole order at ~5 sounds, but GUARANTEE one per type
    // present (that guarantee can push past 5). Extras beyond the per-type guarantee share what's
    // left up to 5, spent first-come across the type loop below.
    var _ahTypes = 0;
    for (var _c = 0; _c < array_length(_colors); _c++) if (_counts[$ _colors[_c]] > 0) _ahTypes += 1;
    var _ahExtra = max(0, 5 - _ahTypes);
    for (var _c = 0; _c < array_length(_colors); _c++) {
        var _typeId = _colors[_c];
        var _want = _counts[$ _typeId];
        if (_want <= 0) continue;
        if (!game_move_legal(_g, _p, _typeId, _src, _dst, _waterOk)) {
            var _tName = string_upper(string_char_at(_typeId, 1)) + string_delete(_typeId, 1, 1);
            var _trapped = (_src.kind == "space") && !game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk);
            game_log(_g, _tName + " pikmin " + (_trapped ? "are trapped and can't get there." : "can't reach that space."));
            continue;
        }
        // (poison exposure is NOT marked here - it's judged from the committed net
        // route at orders lock-in, so re-planning mid-orders doesn't count)
        var _exited = game_path_exited_spaces(_g, _p, _src, _dst);
        var _mineRefs = [];
        for (var _e = 0; _e < array_length(_exited); _e++) {
            var _mn = game_mine_at(_g, _exited[_e].lane, _exited[_e].idx);
            if (_mn != undefined) array_push(_mineRefs, _mn);
        }
        var _tokens = _g.players[_p].tokens;
        var _typeDef = pikmin_type_get(_typeId);
        var _srcBlocks = (_src.kind == "space") && game_tile_blocks_pass(_g, _typeDef, _src.lane, _src.idx, _waterOk);
        var _homeDir = (_p == 0) ? -1 : 1;   // step direction toward this player's home edge
        var _moved = 0;
        var _wallBlocked = 0;
        for (var _i = 0; _i < array_length(_tokens) && _moved < _want; _i++) {
            var _tok = _tokens[_i];
            if (_tok.typeId != _typeId || !game_loc_eq(_tok.loc, _src)) continue;
            if (variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) continue; // tossed by a snitchbug
            if (token_is_frozen(_tok)) continue;                                       // iced solid
            // MID-TILE WALL: a token latched on a blocking card sits on the half it
            // approached from; it may exit only toward that half. Crossing to the far
            // side (e.g. past the card it's stuck against) is illegal while the card lives.
            if (_srcBlocks) {
                // a move HOME or to ANOTHER LANE routes through the home edge, so it exits toward
                // home; only a straight in-lane move exits along the lane. (Comparing idx across
                // different lanes is meaningless - that let a back-side token escape to a forward space.)
                var _exitDir = (_dst.kind == "home" || _dst.lane != _src.lane) ? _homeDir : sign(_dst.idx - _src.idx);
                // A TREASURE is CARRIED, not an impassable wall: it only blocks going DEEPER (past it,
                // toward centre). Retreating toward home is always allowed - the pikmin haul it home or
                // drop it and leave. A wall/enemy uses the latched half (a token trapped BEHIND it can't
                // cross back).
                var _blocked;
                if (game_treasure_at(_g, _src.lane, _src.idx) != undefined) _blocked = (_exitDir != _homeDir && _dst.kind == "space");
                else _blocked = (_exitDir != game_token_side(_tok, _p));
                if (_blocked) { _wallBlocked += 1; continue; }
            }
            _tok.loc = (_dst.kind == "home") ? { kind: "home" } : { kind: "space", lane: _dst.lane, idx: _dst.idx };
            _tok.movedThisTurn = true;
            // record which half of a destination card this token now clings to (else clear).
            // A straight IN-LANE move approaches from where it stood (_src.idx); a HOME deploy OR a
            // LANE CHANGE routes through home, so it approaches the card from the HOME edge - use that,
            // not the old lane's idx (which put a cross-lane attacker on the wrong/back half).
            if (_dst.kind == "space" && game_space_has_card(_g, _dst.lane, _dst.idx)) {
                var _sameLane = (_src.kind == "space" && _src.lane == _dst.lane);
                var _fromIdx = _sameLane ? _src.idx : ((_p == 0) ? -1 : array_length(_g.board.lanes[_dst.lane].spaces));
                _tok.side = sign(_fromIdx - _dst.idx);
            } else {
                _tok.side = 0;
            }
            _moved += 1;
        }
        if (_moved == 0 && _wallBlocked > 0) {
            var _wName = string_upper(string_char_at(_typeId, 1)) + string_delete(_typeId, 1, 1);
            game_log(_g, _wName + " pikmin can't reach that space.");
        }
        // mines take 1 damage per pikmin that passed them
        for (var _m = 0; _m < array_length(_mineRefs); _m++) game_mine_damage(_g, _mineRefs[_m], _moved);
        if (_moved > 0) {
            _movedAny = true;
            game_trace(_g, "MOVE " + string(_moved) + " " + _typeId + ": "
                + ((_src.kind == "home") ? "home" : "L" + string(_src.lane + 1) + "i" + string(_src.idx)) + " -> "
                + ((_dst.kind == "home") ? "home" : "L" + string(_dst.lane + 1) + "i" + string(_dst.idx)));
            // pikmin REACT to being ordered to a space: a few random "ah"s (capped + offset +
            // wobbled like combat sfx), pitched by type - winged a touch higher, purple lower.
            if (_dst.kind == "space") {
                var _ahP = (_typeId == "winged") ? 1.12 : ((_typeId == "purple") ? 0.88 : ((_typeId == "white") ? 0.94 : 1.0));
                game_sfx(_g, "ah" + string(irandom_range(1, 13)), 5, _dst.lane, _dst.idx, _ahP); // guaranteed one for this type
                var _ahMore = min(_moved - 1, _ahExtra);   // extras from the shared budget (total capped ~5)
                _ahExtra -= _ahMore;
                repeat (_ahMore) game_sfx(_g, "ah" + string(irandom_range(1, 13)), 5, _dst.lane, _dst.idx, _ahP);
            }
        }
    }
    return _movedAny;
}

/// Orders-phase: send pikmin to the ONION - they walk back and are dismissed
/// (deleted, freeing token-cap space). Legality mirrors an ordered retreat to
/// HOME: the group must actually be able to get there, so trapped tokens can't
/// go, and frozen/buried tokens stay put. Mines take pass damage from the walk
/// like any retreat. Returns how many pikmin were dismissed.
function game_order_discard(_g, _src, _counts) {
    if (_g.phase != "orders") return 0;
    var _p = _g.activePlayer;
    // blue lifeguard: the departing group self-covers on the way back, like a move home
    var _waterOk = game_lifeguard_ok(_g, _p, { kind: "home" }, _counts);
    var _removed = 0;
    var _colors = variable_struct_get_names(_counts);
    for (var _c = 0; _c < array_length(_colors); _c++) {
        var _typeId = _colors[_c];
        var _want = _counts[$ _typeId];
        if (_want <= 0) continue;
        if (_src.kind == "space" && !game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk)) {
            var _tName = string_upper(string_char_at(_typeId, 1)) + string_delete(_typeId, 1, 1);
            game_log(_g, _tName + " pikmin can't get back to the Onion from there.");
            continue;
        }
        var _exited = game_path_exited_spaces(_g, _p, _src, { kind: "home" });
        var _mineRefs = [];
        for (var _e = 0; _e < array_length(_exited); _e++) {
            var _mn = game_mine_at(_g, _exited[_e].lane, _exited[_e].idx);
            if (_mn != undefined) array_push(_mineRefs, _mn);
        }
        var _tokens = _g.players[_p].tokens;
        // MID-TILE WALL: reaching the Onion is a retreat HOME - a token latched on the far
        // (centre) half of a blocker can't cross it to get there. (game_can_reach_home skips
        // the src tile's own card, so the group gate above passes; enforce per-token here.)
        var _srcBlocks = (_src.kind == "space") && game_tile_blocks_pass(_g, pikmin_type_get(_typeId), _src.lane, _src.idx, _waterOk);
        var _homeDir = (_p == 0) ? -1 : 1;
        var _n = 0;
        var _i = 0;
        while (_i < array_length(_tokens) && _n < _want) {
            var _tok = _tokens[_i];
            var _match = (_tok.typeId == _typeId && game_loc_eq(_tok.loc, _src) && !token_is_disabled(_tok)
                && !(_srcBlocks && game_token_side(_tok, _p) != _homeDir));
            if (_match && global.expRules.anims) {
                // animated game: retarget its loc to the Onion so the presentation WALKS it home (reusing
                // the normal per-token walk) and poofs it on arrival (Draw shrink -> Step sweep fires
                // game_fx_onion + sfxPikDiscard + delete). loc "onion" matches no home/space query, so it's
                // auto-excluded from re-selection/move; it still counts toward the pikmin cap until it
                // disappears at the Onion (so the tally drops on arrival, not at click time).
                _tok.loc = { kind: "onion" };
                _tok.onionShrink = 0;
                _n += 1;
                _i += 1;
            } else if (_match) {
                array_delete(_tokens, _i, 1);   // headless (batch/sim/tournament AI): remove now, no walk
                _n += 1;
            } else {
                _i += 1;
            }
        }
        for (var _m = 0; _m < array_length(_mineRefs); _m++) game_mine_damage(_g, _mineRefs[_m], _n);
        if (_n > 0) {
            _removed += _n;
            game_trace(_g, "ONION " + string(_n) + " " + _typeId + ": "
                + ((_src.kind == "home") ? "home" : "L" + string(_src.lane + 1) + "i" + string(_src.idx)));
        }
    }
    if (_removed > 0) game_log(_g, "P" + string(_p + 1) + " returns " + string(_removed) + " pikmin to the Onion.");
    return _removed;
}

/// Redeem a pellet card (by hand index) for pikmin of _chosenColor at HOME.
/// Count of tokens that count against the 25 cap. Bulbmin exist separately and
/// are excluded (they're recruited from the Bulbmin enemy, not the pellet economy).
function game_capped_count(_g, _p) {
    var _n = 0;
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (_tokens[_i].typeId != "bulbmin") _n += 1;
    }
    return _n;
}

function game_bulbmin_count(_g, _p) {
    var _n = 0;
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (_tokens[_i].typeId == "bulbmin") _n += 1;
    }
    return _n;
}

/// Player _p's current pikmin board cap: the base rule cap plus any FLARLIC day-event boosts
/// that player has banked over the match (persistent, per-player).
function game_pikmin_cap(_g, _p) {
    var _fb = variable_struct_exists(_g.players[_p], "flarlicBonus") ? _g.players[_p].flarlicBonus : 0;
    return global.rules.pikminBoardCap + _fb;
}

function game_play_pellet(_g, _handIdx, _chosenColor) {
    if (_g.phase != "orders") return;
    // ADVENTURE "Weak Soil" event: pellet cards can't be redeemed this turn
    if (variable_struct_exists(_g, "advNoPellets") && _g.advNoPellets) { game_log(_g, "Weak Soil: you can't redeem pellets this turn."); return; }
    var _pl = _g.players[_g.activePlayer];
    if (_handIdx < 0 || _handIdx >= array_length(_pl.pellets)) return;
    if (!arr_has(_g.boardDef.basicColors, _chosenColor)) return;
    var _def = pellet_def_get(_pl.pellets[_handIdx]);
    var _amount = (_chosenColor == _def.color) ? _def.sameTypeAmount : _def.offTypeAmount;
    if (_g.dayPelletBonus) _amount += 1;   // PELLET day event: pellets give 1 more pikmin this turn
    var _cap = game_pikmin_cap(_g, _g.activePlayer);
    var _room = _cap - game_capped_count(_g, _g.activePlayer);
    var _grant = min(_amount, max(0, _room));
    repeat (_grant) array_push(_pl.tokens, { typeId: _chosenColor, loc: { kind: "home" } });
    if (_grant < _amount) game_log(_g, string(_amount - _grant) + " pikmin wasted (cap " + string(_cap) + ").");
    array_delete(_pl.pellets, _handIdx, 1);
    game_log(_g, "P" + string(_g.activePlayer + 1) + " redeems " + _def.name + " for " + string(_grant) + " " + _chosenColor + " pikmin.");
}

// ---------- gather card play ----------

function game_discard_gather_card(_g, _handIdx) {
    var _pl = _g.players[_g.activePlayer];
    var _cardId = _pl.hand[_handIdx];
    array_delete(_pl.hand, _handIdx, 1);
    array_push(_g.decks.gatherDiscard, _cardId);
    return _cardId;
}

/// Grant pikmin at _loc (default HOME), respecting the board cap. Bulbmin ignore
/// the cap (they exist separately). Returns how many were granted.
function game_grant_pikmin(_g, _p, _typeId, _n, _loc = undefined) {
    var _pl = _g.players[_p];
    var _grant = (_typeId == "bulbmin") ? _n : min(_n, max(0, game_pikmin_cap(_g, _p) - game_capped_count(_g, _p)));
    repeat (_grant) {
        var _where = (_loc == undefined || _loc.kind == "home") ? { kind: "home" } : { kind: "space", lane: _loc.lane, idx: _loc.idx };
        var _startAt = (_where.kind == "home") ? { kind: "home" } : { kind: "space", lane: _where.lane, idx: _where.idx };
        array_push(_pl.tokens, { typeId: _typeId, loc: _where, turnStartLoc: _startAt });
    }
    if (_grant < _n) game_log(_g, string(_n - _grant) + " pikmin wasted (25 token cap).");
    return _grant;
}

/// Discard up to _n of player _p's tokens at a location, cheapest first (no combat side effects).
function game_discard_tokens_loc(_g, _p, _loc, _n) {
    var _removed = 0;
    for (var _prio = 0; _prio <= 2 && _removed < _n; _prio++) {
        var _tokens = _g.players[_p].tokens;
        var _i = 0;
        while (_i < array_length(_tokens) && _removed < _n) {
            if (game_loc_eq(_tokens[_i].loc, _loc) && pikmin_kill_priority(_tokens[_i].typeId) == _prio) {
                if (_loc.kind == "space") game_fx_pik(_g, _tokens[_i], _loc.lane, _loc.idx);
                array_delete(_tokens, _i, 1);
                _removed += 1;
                continue;
            }
            _i += 1;
        }
    }
    return _removed;
}

/// Convenience wrapper for space targets.
function game_discard_tokens_at(_g, _p, _lane, _idx, _n) {
    return game_discard_tokens_loc(_g, _p, { kind: "space", lane: _lane, idx: _idx }, _n);
}

/// Discard an EXACT colour mix of player _p's tokens at a location - the player's
/// chosen payment (cards that trade pikmin; cheapest-first is the default above).
/// _pay is a {typeId: count} struct. Returns how many were removed.
function game_discard_tokens_pay(_g, _p, _loc, _pay) {
    var _removed = 0;
    var _colors = variable_struct_get_names(_pay);
    for (var _c = 0; _c < array_length(_colors); _c++) {
        var _typeId = _colors[_c];
        var _want = _pay[$ _typeId];
        var _tokens = _g.players[_p].tokens;
        var _i = 0;
        while (_i < array_length(_tokens) && _want > 0) {
            if (_tokens[_i].typeId == _typeId && game_loc_eq(_tokens[_i].loc, _loc)) {
                if (_loc.kind == "space") game_fx_pik(_g, _tokens[_i], _loc.lane, _loc.idx);
                array_delete(_tokens, _i, 1);
                _want -= 1;
                _removed += 1;
                continue;
            }
            _i += 1;
        }
    }
    return _removed;
}

/// Spawn an enemy from the deck onto a space (Phosbat Pod / respawn effects).
/// Drawn bosses go to the richest bossless pile as usual.
function game_spawn_enemy_at(_g, _lane, _idx) {
    var _space = _g.board.lanes[_lane].spaces[_idx];
    // never spawn onto a space already occupied by a CARD - an enemy, a structure (wall/bridge/
    // emitter), or a treasure pile. An emitter on an enemy space keeps it from spawning.
    if (_space.enemy != undefined || _space.structure != undefined || game_treasure_at(_g, _lane, _idx) != undefined) return false;
    game_enemy_deck_ensure(_g);
    var _noBosses = (global.expRules.bossCap == 0);
    if (_noBosses) {   // guard: if bosses are disabled and only bosses remain, don't loop forever
        var _anyNon = false;
        for (var _d = 0; _d < array_length(_g.decks.enemy); _d++) if (!enemy_def_get(_g.decks.enemy[_d]).boss) { _anyNon = true; break; }
        if (!_anyNon) return false;
    }
    while (array_length(_g.decks.enemy) > 0) {
        var _enemyId = array_pop(_g.decks.enemy);
        var _enemyDef = enemy_def_get(_enemyId);
        if (_enemyDef.boss) {
            if (_noBosses) { array_insert(_g.decks.enemy, irandom(max(0, array_length(_g.decks.enemy) - 1)), _enemyId); continue; }
            var _pile = game_richest_bossless_pile(_g);
            if (_pile != undefined) {
                _pile.boss = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false };
                game_log(_g, "BOSS " + _enemyDef.name + " emerges onto a treasure pile!");
            } else {
                array_insert(_g.decks.enemy, irandom(max(0, array_length(_g.decks.enemy) - 1)), _enemyId);
                return false;
            }
            game_enemy_deck_ensure(_g);
            continue;
        }
        _space.enemy = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false };
        game_log(_g, _enemyDef.name + " appears!");
        return true;
    }
    return false;
}

/// Play a gather card from the active player's hand. _args is card-specific:
/// {lane, idx} target space; plus {color} (posy/candypop), {build} (raw material /
/// rock storm), {purples, whites} (ivory & violet), {mode, lane2, idx2} (warp).
/// Returns true if the card was played (and discarded), false if the play was invalid.
function game_play_gather(_g, _handIdx, _args) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    if (_handIdx < 0 || _handIdx >= array_length(_pl.hand)) return false;
    var _cardId = _pl.hand[_handIdx];

    // Captain Clone copies the top of the gather discard pile
    var _effectId = _cardId;
    if (_cardId == "captainclone") {
        var _dn = array_length(_g.decks.gatherDiscard);
        if (_dn == 0) { game_log(_g, "Captain Clone: the discard pile is empty."); return false; }
        _effectId = _g.decks.gatherDiscard[_dn - 1];
        if (_effectId == "captainclone") {
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Captain Clone copies Captain Clone... nothing happens.");
            return true;
        }
        game_log(_g, "Captain Clone copies " + gather_def_get(_effectId).name + "!");
    }

    if (array_length(_g.resolveQueue) > 0) return false; // resolution underway - too late for cards
    // timing: posy plays as a pellet (orders); everything else in the move phase window
    if (_effectId == "colorchangingposy") {
        if (_g.phase != "orders" && _g.phase != "move") return false;
    } else if (_g.phase != "move") {
        game_sfx(_g, "sfxError");   // a card played in the wrong phase (only a human ever hits this)
        game_log(_g, "Gather cards are played in the Move phase, before resolving.");
        return false;
    }

    // track the play in the log with a chipped card name - easy to follow what the opponent does
    // even if you miss the board animation. (chr(2) markers = the log renderer's card-name chip.)
    game_log(_g, "P" + string(_p + 1) + " plays " + chr(2) + gather_display_name(_cardId) + chr(2) + ".");

    switch (_effectId) {

        case "colorchangingposy": {
            if (!arr_has(_g.boardDef.basicColors, _args.color)) return false;
            var _grant = game_grant_pikmin(_g, _p, _args.color, 5);
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " plays Color Changing Posy: " + string(_grant) + " " + _args.color + " pikmin.");
            return true;
        }

        case "rawmaterial": {
            // needs a second copy in hand (a clone counts as one of the pair) - UNLESS the RAW
            // day event is active, which drops the cost to a single Raw Material this turn.
            var _copies = 0;
            for (var _i = 0; _i < array_length(_pl.hand); _i++) {
                if (_pl.hand[_i] == "rawmaterial") _copies += 1;
            }
            var _needRaw = (_cardId == "captainclone") ? 1 : 2;
            if (_g.dayRawFree) _needRaw -= 1;   // RAW day event: build for one fewer Raw Material
            if (_copies < _needRaw) {
                game_log(_g, "Raw Material needs a second copy to build with.");
                return false;
            }
            if (game_space_has_card(_g, _args.lane, _args.idx)) return false;
            var _space = _g.board.lanes[_args.lane].spaces[_args.idx];
            if (_space.structure != undefined) return false;
            var _bDef = hazard_def_get(_args.build);
            var _allowed = arr_has(_g.boardDef.structures.walls, _args.build) || arr_has(_g.boardDef.structures.bridges, _args.build);
            if (!_allowed) return false;
            if (_bDef.type == "bridge" && _space.kind != "hazard") { game_log(_g, "Bridges go on hazard spaces."); return false; }
            if (_args.build == "climbingstick" && _space.hazard != "height") { game_log(_g, "Climbing Sticks only go on height spaces."); return false; }
            if (_args.build == "tunnel" && _space.hazard != "chasm") { game_log(_g, "Tunnels only go on chasm spaces."); return false; }
            _space.structure = { structId: _args.build, curHp: _bDef.hp };
            game_discard_gather_card(_g, _handIdx);
            // burn the second raw material (skipped when the RAW day event halves the cost)
            if (!_g.dayRawFree) {
                for (var _i = 0; _i < array_length(_pl.hand); _i++) {
                    if (_pl.hand[_i] == "rawmaterial") { game_discard_gather_card(_g, _i); break; }
                }
            }
            game_log(_g, "P" + string(_p + 1) + " builds a " + _bDef.name + (_g.dayRawFree ? " (RAW: half cost)!" : "!"));
            return true;
        }

        case "ivoryandviolet": {
            var _wantP = variable_struct_exists(_args, "purples") ? _args.purples : 0;
            var _wantW = variable_struct_exists(_args, "whites") ? _args.whites : 0;
            if (_wantP + _wantW <= 0) return false;
            var _loc = game_args_loc(_args);
            var _need = _wantP * 5 + _wantW * 2;
            var _have = array_length(game_tokens_at(_g, _p, _loc));
            if (_need > _have) { game_log(_g, "Not enough pikmin there to trade."); return false; }
            // the player may name the exact colour mix fed to the trade ({pay}
            // struct); no mix given = the old cheapest-first default (AI path)
            if (variable_struct_exists(_args, "pay") && _args.pay != undefined) {
                var _paySum = 0;
                var _counts = game_counts_struct(_g, _p, _loc);
                var _pcols = variable_struct_get_names(_args.pay);
                for (var _i = 0; _i < array_length(_pcols); _i++) {
                    var _cnt = _args.pay[$ _pcols[_i]];
                    var _avail = variable_struct_exists(_counts, _pcols[_i]) ? _counts[$ _pcols[_i]] : 0;
                    if (_cnt < 0 || _cnt > _avail) { game_log(_g, "Not enough " + _pcols[_i] + " pikmin there to pay with."); return false; }
                    _paySum += _cnt;
                }
                if (_paySum != _need) { game_log(_g, "The payment must be exactly " + string(_need) + " pikmin."); return false; }
                game_discard_tokens_pay(_g, _p, _loc, _args.pay);
            } else {
                game_discard_tokens_loc(_g, _p, _loc, _need);
            }
            // the new pikmin appear IN PLACE, where the trade happened
            var _gotP = game_grant_pikmin(_g, _p, "purple", _wantP, _loc);
            var _gotW = game_grant_pikmin(_g, _p, "white", _wantW, _loc);
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " trades " + string(_need) + " pikmin for " + string(_gotP) + " purple + " + string(_gotW) + " white.");
            return true;
        }

        case "phosbatpod": {
            var _space = _g.board.lanes[_args.lane].spaces[_args.idx];
            if (_space.kind != "enemy" || _space.enemy != undefined) return false;
            if (game_treasure_at(_g, _args.lane, _args.idx) != undefined || _space.structure != undefined) return false;
            if (!game_spawn_enemy_at(_g, _args.lane, _args.idx)) { game_log(_g, "No enemies left to spawn."); return false; }
            game_discard_gather_card(_g, _handIdx);
            return true;
        }

        case "bombrock":
        case "boulder": {
            // STAGED: the target telegraphs (strobe + ring) for a wind-up beat, then
            // the blast lands - same feel as the explosive enemies, no instant hit
            var _dmg = (_effectId == "boulder") ? 5 : 10;
            var _bName = gather_def_get(_effectId).name;
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " hurls a " + _bName + " at lane " + string(_args.lane + 1) + "!");
            array_push(_g.resolveQueue, { beat: "bombCue", lane: _args.lane, idx: _args.idx });
            array_push(_g.resolveQueue, { beat: "bombHit", lane: _args.lane, idx: _args.idx, dmg: _dmg, bname: _bName, p: _p });
            return true;
        }

        case "spicyspray": {
            array_push(_g.sprays, { playerIdx: _p, lane: _args.lane, idx: _args.idx });
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " sprays lane " + string(_args.lane + 1) + " - those pikmin will act twice!");
            return true;
        }

        case "warp": {
            if (_args.mode == "swap") {
                var _t1 = game_treasure_at(_g, _args.lane, _args.idx);
                var _t2 = game_treasure_at(_g, _args.lane2, _args.idx2);
                if (_t1 == undefined || _t2 == undefined || _t1.boss == undefined || _t2.boss == undefined || _t1 == _t2) return false;
                var _tmp = _t1.boss;
                _t1.boss = _t2.boss;
                _t2.boss = _tmp;
                game_log(_g, "Warp! The two bosses trade places.");
            } else {
                var _from = _g.board.lanes[_args.lane].spaces[_args.idx];
                var _to = _g.board.lanes[_args.lane2].spaces[_args.idx2];
                if (_from.enemy == undefined || _to.kind != "enemy" || _to.enemy != undefined) return false;
                if (game_treasure_at(_g, _args.lane2, _args.idx2) != undefined || _to.structure != undefined) return false;
                _to.enemy = _from.enemy;
                _from.enemy = undefined;
                game_log(_g, "Warp! " + enemy_def_get(_to.enemy.enemyDefId).name + " is teleported.");
            }
            game_discard_gather_card(_g, _handIdx);
            return true;
        }

        case "candypopbud": {
            // the classic bud is ALWAYS Red, Blue, or Yellow - regardless of the
            // board's starting colours (that's its utility on exotic boards)
            if (!arr_has(["red", "blue", "yellow"], _args.color)) return false;
            var _mine = game_tokens_at(_g, _p, game_args_loc(_args));
            if (array_length(_mine) == 0) return false;
            for (var _i = 0; _i < array_length(_mine); _i++) _mine[_i].typeId = _args.color;
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Candypop Bud turns " + string(array_length(_mine)) + " pikmin " + _args.color + "!");
            return true;
        }

        case "queencandypopbud": {
            // the QUEEN creates the board's starting colours
            if (!arr_has(_g.boardDef.basicColors, _args.color)) return false;
            var _mine = game_tokens_at(_g, _p, game_args_loc(_args));
            if (array_length(_mine) == 0) return false;
            for (var _i = 0; _i < array_length(_mine); _i++) _mine[_i].typeId = _args.color;
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Queen Candypop Bud turns " + string(array_length(_mine)) + " pikmin " + _args.color + "!");
            return true;
        }

        case "candypopbud2": {
            // the off-board colours: Rock, Winged, or Ice (regardless of basic colours)
            if (!arr_has(["rock", "winged", "ice"], _args.color)) return false;
            var _mine = game_tokens_at(_g, _p, game_args_loc(_args));
            if (array_length(_mine) == 0) return false;
            for (var _i = 0; _i < array_length(_mine); _i++) _mine[_i].typeId = _args.color;
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Candypop Bud turns " + string(array_length(_mine)) + " pikmin " + _args.color + "!");
            return true;
        }

        case "oatchirush": {
            var _t = undefined;
            for (var _i = 0; _i < array_length(_g.treasures); _i++) {
                if (_g.treasures[_i].lane == _args.lane) { _t = _g.treasures[_i]; break; }
            }
            if (_t == undefined || _t.boss != undefined) { game_sfx(_g, "sfxError"); return false; }
            // treasure must not be on your side (the treasure space counts as yours)
            if (_p == 0 && _t.idx <= 3) { game_sfx(_g, "sfxError"); game_log(_g, "That treasure is already on your side."); return false; }
            if (_p == 1 && _t.idx >= 3) { game_sfx(_g, "sfxError"); game_log(_g, "That treasure is already on your side."); return false; }
            // lane must be clear between your end and the treasure (bridges don't block)
            var _dir = (_p == 0) ? 1 : -1;
            var _s = (_p == 0) ? 0 : 6;
            while (_s != _t.idx) {
                if (game_space_has_card(_g, _args.lane, _s)) { game_sfx(_g, "sfxError"); game_log(_g, "That lane isn't clear."); return false; }
                _s += _dir;
            }
            // rush: move two spaces toward you, riders and all, ignoring hazards ("not passed")
            repeat (2) {
                var _newIdx = _t.idx - _dir;
                for (var _q = 0; _q < 2; _q++) {
                    var _riders = game_tokens_at(_g, _q, { kind: "space", lane: _t.lane, idx: _t.idx });
                    for (var _r = 0; _r < array_length(_riders); _r++) {
                        _riders[_r].loc = { kind: "space", lane: _t.lane, idx: _newIdx };
                        game_token_blown(_g, _riders[_r], _t.lane, _newIdx); // the charge drags them - slide, don't walk
                    }
                }
                _t.idx = _newIdx;
            }
            _t.rushSlide = true;   // render hint: the pile slides fast (BLOWN_SLIDE) to keep up with the shoved pikmin
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Oatchi Rush! The treasure charges two spaces toward P" + string(_p + 1) + "!");
            return true;
        }

        case "rockstorm": {
            var _space = _g.board.lanes[_args.lane].spaces[_args.idx];
            if (_space.kind == "hazard" || game_space_has_card(_g, _args.lane, _args.idx) || _space.structure != undefined) return false;
            if (!arr_has(_g.boardDef.structures.emitters, _args.build)) return false;
            var _eDef = hazard_def_get(_args.build);
            _space.structure = { structId: _args.build, curHp: _eDef.hp };
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Rock Storm! A " + _eDef.name + " crashes down!");
            return true;
        }

        case "surveydrone": {
            var _t = game_treasure_at(_g, _args.lane, _args.idx);
            if (_t == undefined || array_length(_t.cards) < 2) return false;
            deck_shuffle(_t.cards);
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Survey Drone shuffles the pile - now showing " + treasure_def_get(_t.cards[array_length(_t.cards) - 1]).name + ".");
            return true;
        }

        case "pikminextinction": {
            // STAGED: every pikmin on the board and at HOME visibly dies (a soul for
            // each; play pauses while they all fade), THEN the fresh starters appear
            // at HOME as the turn ends. The respawn rides a queued beat.
            for (var _q = 0; _q < 2; _q++) {
                var _toks = _g.players[_q].tokens;
                for (var _i = 0; _i < array_length(_toks); _i++) {
                    var _tk = _toks[_i];
                    var _fl = (_tk.loc.kind == "space") ? _tk.loc.lane : 2;
                    var _fi2 = (_tk.loc.kind == "space") ? _tk.loc.idx : 3;
                    game_fx_pik(_g, _tk, _fl, _fi2); // souls rise from render positions (home strip incl.)
                }
                _g.players[_q].tokens = [];
            }
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "PIKMIN EXTINCTION! Every pikmin is lost...");
            array_push(_g.resolveQueue, { beat: "extRespawn", p: _p });
            return true;
        }

        case "bitterspray": {
            // "Enemies skip their next action" - petrifies the enemy (or boss) on the space for a
            // turn. It does NOT affect pikmin at all - not even an opponent's; it's an anti-enemy tool.
            var _space = _g.board.lanes[_args.lane].spaces[_args.idx];
            var _t = game_treasure_at(_g, _args.lane, _args.idx);
            var _hit = 0;
            if (_space.enemy != undefined) { _space.enemy.stunned = 1; _space.enemy.stunnedBy = "bitter"; _hit += 1; }
            if (_t != undefined && _t.boss != undefined) { _t.boss.stunned = 1; _t.boss.stunnedBy = "bitter"; _hit += 1; }
            if (_hit == 0) { game_log(_g, "No enemy there to embitter."); return false; }
            game_sfx(_g, "sfxFreeze");   // bitter spray = the crackling-ice SFX
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Ultra-Bitter Spray! The enemy there is petrified for its next action.");
            return true;
        }

        case "icebomb": {
            var _n = game_freeze_space(_g, _args.lane, _args.idx, "ice", _p);
            if (_n == 0) { game_log(_g, "Ice Bomb would hit nothing there."); return false; }
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Ice Bomb! " + string(_n) + " creatures on the space are frozen for a turn.");
            return true;
        }

        case "storm": {
            // 2x2 area anchored at the clicked space (clamped to the board)
            var _l0 = clamp(_args.lane, 0, _g.board.laneCount - 2);
            var _i0 = clamp(_args.idx, 0, 5);
            var _n = game_freeze_space(_g, _l0, _i0, "shock", _p)
                   + game_freeze_space(_g, _l0 + 1, _i0, "shock", _p)
                   + game_freeze_space(_g, _l0, _i0 + 1, "shock", _p)
                   + game_freeze_space(_g, _l0 + 1, _i0 + 1, "shock", _p);
            if (_n == 0) { game_log(_g, "Lightning Storm would hit nothing there."); return false; }
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Lightning Storm! " + string(_n) + " creatures are paralyzed for a turn.");
            return true;
        }

        case "shipsignal": {
            var _t = game_treasure_at(_g, _args.lane, _args.idx);
            if (_t == undefined || array_length(_t.cards) < 2) return false;
            var _pick = clamp(_args.topCard, 0, array_length(_t.cards) - 1);
            var _chosen = _t.cards[_pick];
            array_delete(_t.cards, _pick, 1);
            array_push(_t.cards, _chosen);
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Ship Signal rearranges the pile - " + treasure_def_get(_chosen).name + " is now on top.");
            return true;
        }

        case "pikpikbundle": {
            // must sit on an actual enemy card - a lane enemy OR a treasure boss
            var _pbSpace = _g.board.lanes[_args.lane].spaces[_args.idx];
            var _pbT = game_treasure_at(_g, _args.lane, _args.idx);
            var _pbHasEnemy = (_pbSpace.enemy != undefined) || (_pbT != undefined && _pbT.boss != undefined);
            if (!_pbHasEnemy) { game_log(_g, "Pikpik carrots go on an enemy card."); return false; }
            array_push(_g.decoys, { playerIdx: _p, lane: _args.lane, idx: _args.idx, hp: 5 });
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " lays out a Pikpik Carrot Bundle (5 hp decoy).");
            return true;
        }

        case "mine": {
            if (game_mine_at(_g, _args.lane, _args.idx) != undefined) return false;
            array_push(_g.mines, { lane: _args.lane, idx: _args.idx, dmg: 0 });
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "A Mine is buried! It arms after 10 pikmin pass over it.");
            return true;
        }

        default:
            game_log(_g, gather_def_get(_effectId).name + " isn't implemented yet.");
            return false;
    }
}

// ---------- move phase resolution ----------

function game_has_own_spray(_g, _p, _lane, _idx) {
    for (var _i = 0; _i < array_length(_g.sprays); _i++) {
        var _s = _g.sprays[_i];
        if (_s.playerIdx == _p && _s.lane == _lane && _s.idx == _idx) return true;
    }
    return false;
}

/// Queue the move-phase resolution as BEATS. The controller pumps game_resolve_step
/// one beat at a time, pausing for animations (walks, spirits) between - so each
/// step (carry, pikmin strike, enemy strike...) reads as its own mini-scene.
function game_resolve_moves(_g) {
    if (_g.phase != "move" || array_length(_g.resolveQueue) > 0) return;
    var _p = _g.activePlayer;
    var _hasSpray = false;
    for (var _si = 0; _si < array_length(_g.sprays); _si++) {
        if (_g.sprays[_si].playerIdx == _p) { _hasSpray = true; break; }
    }
    var _q = [];
    if (_hasSpray) { array_push(_q, "sprayPop"); array_push(_q, "spicyCarry"); array_push(_q, "spicyPik"); }
    array_push(_q, "carry");
    // swift enemies get their OWN combat section before the pikmin - but only spend
    // the beats when an engaged swift actually exists
    var _hasSwift = false;
    for (var _li = 0; _li < _g.board.laneCount && !_hasSwift; _li++) {
        for (var _si2 = 0; _si2 < array_length(_g.board.lanes[_li].spaces) && !_hasSwift; _si2++) {
            var _se = _g.board.lanes[_li].spaces[_si2].enemy;
            if (_se != undefined && !_se.dead && game_enemy_def_eff(_g, _se.enemyDefId).attackElement == "swift"
                && array_length(game_tokens_at(_g, _p, { kind: "space", lane: _li, idx: _si2 })) > 0) _hasSwift = true;
        }
    }
    for (var _ti = 0; _ti < array_length(_g.treasures) && !_hasSwift; _ti++) {
        var _tb = _g.treasures[_ti].boss;
        if (_tb != undefined && !_tb.dead && game_enemy_def_eff(_g, _tb.enemyDefId).attackElement == "swift"
            && array_length(game_tokens_at(_g, _p, { kind: "space", lane: _g.treasures[_ti].lane, idx: _g.treasures[_ti].idx })) > 0) _hasSwift = true;
    }
    if (_hasSwift) { array_push(_q, "jumpSwift"); }
    array_push(_q, "swift");     // collects the fights + swift strikes (own section)
    array_push(_q, "jumpPik");   // attackers wind up (big hop) before their damage lands
    array_push(_q, "pik");
    array_push(_q, "jumpEnemy"); // surviving enemies wind up before retaliating
    array_push(_q, "enemy");
    // red second strike (experimental) gets its own visible pounce - no invisible damage
    if (global.expRules.red) {
        var _hasRed = false;
        var _rtoks = _g.players[_p].tokens;
        for (var _ri = 0; _ri < array_length(_rtoks) && !_hasRed; _ri++) {
            var _rt = _rtoks[_ri];
            if (_rt.typeId != "red" || _rt.loc.kind != "space") continue;
            if (_g.board.lanes[_rt.loc.lane].spaces[_rt.loc.idx].enemy != undefined) _hasRed = true;
            else {
                var _rtt = game_treasure_at(_g, _rt.loc.lane, _rt.loc.idx);
                if (_rtt != undefined && _rtt.boss != undefined) _hasRed = true;
            }
        }
        if (_hasRed) array_push(_q, "jumpRed");
    }
    array_push(_q, "post");      // red second strike lands here
    array_push(_q, "finish");
    _g.resolveQueue = _q;
}

/// Deferred Bomb Rock / Boulder impact (fired by the bombHit beat after the telegraph).
function game_bomb_hit(_g, _p, _lane, _idx, _dmg, _bName) {
    game_sfx(_g, "sfxBombRock");   // the Bomb Rock / Boulder ITEM going off (enemy explosions use sfxGunshot)
    var _space = _g.board.lanes[_lane].spaces[_idx];
    var _boom = false;
    // one blast, one impact: a hazard dropped by the dying enemy (dweevil)
    // spawns AFTER the hit and must not soak the same damage
    var _hadStructure = (_space.structure != undefined);
    game_fx_boom(_g, _lane, _idx);
    for (var _q = 0; _q < 2; _q++) {
        var _n = game_discard_tokens_at(_g, _q, _lane, _idx, 999);
        if (_n > 0) { game_log(_g, _bName + " wipes out " + string(_n) + " of P" + string(_q + 1) + "'s pikmin!"); _boom = true; }
    }
    if (_space.enemy != undefined) {
        _space.enemy.curHp -= _dmg;
        game_log(_g, _bName + " hits " + enemy_def_get(_space.enemy.enemyDefId).name + " for " + string(_dmg) + "!");
        if (_space.enemy.curHp <= 0) game_enemy_die(_g, _p, { enemy: _space.enemy, lane: _lane, idx: _idx, isBoss: false, hostT: undefined });
        _boom = true;
    }
    var _t = game_treasure_at(_g, _lane, _idx);
    if (_t != undefined && _t.boss != undefined) {
        _t.boss.curHp -= _dmg;
        game_log(_g, _bName + " hits " + enemy_def_get(_t.boss.enemyDefId).name + " for " + string(_dmg) + "!");
        if (_t.boss.curHp <= 0) game_enemy_die(_g, _p, { enemy: _t.boss, lane: _t.lane, idx: _t.idx, isBoss: true, hostT: _t });
        _boom = true;
    }
    if (_hadStructure && _space.structure != undefined) {
        var _bStructDef = hazard_def_get(_space.structure.structId);
        _space.structure.curHp -= _dmg;
        game_log(_g, _bName + " damages the " + _bStructDef.name + "!");
        if (_space.structure.curHp <= 0) {
            game_log(_g, "The " + _bStructDef.name + " is destroyed!");
            _space.structure = undefined;
            // walls + bridges get the heavy destruction crash on top of the blast; emitters don't
            if (_bStructDef.type == "wall" || _bStructDef.type == "bridge") game_sfx(_g, "sfxDestroyStructure");
        }
        _boom = true;
    }
    if (!_boom) game_log(_g, _bName + " lands on an empty space. Well then.");
}

/// Execute ONE resolution beat (controller-pumped). Order preserves the old
/// single-tick semantics: spicy bonus -> carry -> pikmin damage (incl. structures)
/// -> enemy damage (incl. explosive splash) -> red 2nd strike -> upkeep/end turn.
function game_resolve_step(_g) {
    if (array_length(_g.resolveQueue) == 0) return;
    game_freeze_update(_g);   // pikmin move between beats - keep frozen water tiles current before this beat's carries
    var _p = _g.activePlayer;
    var _beat = _g.resolveQueue[0];
    array_delete(_g.resolveQueue, 0, 1);
    _g.jumpCue = "";
    _g.bombCue = undefined;
    _g.sprayCue = false;
    if (is_struct(_beat)) {
        if (_beat.beat == "bombCue") { _g.bombCue = { lane: _beat.lane, idx: _beat.idx }; return; }
        if (_beat.beat == "bombHit") { game_bomb_hit(_g, _beat.p, _beat.lane, _beat.idx, _beat.dmg, _beat.bname); return; }
        if (_beat.beat == "extRespawn") {
            // the souls have faded - fresh starters sprout at HOME and the turn ends
            for (var _q = 0; _q < 2; _q++) {
                var _cols = _g.boardDef.basicColors;
                for (var _c = 0; _c < array_length(_cols); _c++) {
                    array_push(_g.players[_q].tokens, { typeId: _cols[_c], loc: { kind: "home" }, turnStartLoc: { kind: "home" } });
                }
            }
            game_log(_g, "Each player restarts with one of each colour. The chaos ends P" + string(_beat.p + 1) + "'s turn!");
            game_end_turn(_g);
            return;
        }
        return;
    }
    switch (_beat) {
        case "sprayPop": {
            game_sfx(_g, "sfxSpicySpray");
            // the spray ignites: red pop at each sprayed space, affected pikmin glow,
            // and the ground tag vanishes (marked popped - the effect entries persist
            // for the spicy beats, they just stop rendering / riding along visibly)
            _g.sprayCue = true;
            game_log(_g, "Ultra-Spicy Spray: sprayed pikmin act first and act twice!");
            for (var _si = 0; _si < array_length(_g.sprays); _si++) {
                var _spr = _g.sprays[_si];
                if (_spr.playerIdx != _p) continue;
                _spr.popped = true;
                game_fx_spicy(_g, _spr.lane, _spr.idx);
            }
            break;
        }
        case "spicyCarry":
            game_carry_step(_g, _p, true);
            break;
        case "spicyPik":  game_combat_step(_g, _p, true, true); break; // bonus hit, no response
        case "carry":     game_carry_step(_g, _p, false); break;
        case "jumpSwift": _g.jumpCue = "swift"; break;
        case "swift":     game_combat_step(_g, _p, false, false, "swift"); break;
        case "jumpPik":   _g.jumpCue = "pik"; break;
        case "pik":       game_combat_step(_g, _p, false, false, "pik"); break;
        case "jumpEnemy": _g.jumpCue = "enemy"; break;
        case "enemy":     game_combat_step(_g, _p, false, false, "enemy"); break;
        case "jumpRed":   _g.jumpCue = "red"; break;
        case "post":
            game_combat_step(_g, _p, false, false, "post");
            _g.combatFights = undefined;
            break;
        case "finish": {
            var _si = 0;
            while (_si < array_length(_g.sprays)) {
                if (_g.sprays[_si].playerIdx == _p) { array_delete(_g.sprays, _si, 1); continue; }
                _si += 1;
            }
            game_poison_step(_g, _p);
            game_mines_step(_g);
            game_end_turn(_g);
            break;
        }
    }
}

/// Armed mines (10+ pass-damage) discard every pikmin that ends the turn on them.
/// A mine that goes off (claims at least one pikmin) is spent and removed rather
/// than lingering as a permanent kill-zone; an armed-but-untriggered mine waits.
function game_mines_step(_g) {
    for (var _mi = array_length(_g.mines) - 1; _mi >= 0; _mi--) {
        var _mn = _g.mines[_mi];
        if (_mn.dmg < 10) continue;
        var _killed = 0;
        for (var _q = 0; _q < 2; _q++) _killed += game_discard_tokens_at(_g, _q, _mn.lane, _mn.idx, 999);
        if (_killed > 0) {
            game_log(_g, "The armed Mine goes off and claims " + string(_killed) + " pikmin, then is spent!");
            game_fx_boom(_g, _mn.lane, _mn.idx);
            array_delete(_g.mines, _mi, 1);
        }
    }
}

/// Pikpik Carrot Bundle: player _q's decoy on this space soaks enemy damage first.
/// Returns the damage left over after the carrots.
function game_decoy_absorb(_g, _q, _lane, _idx, _n) {
    if (_n <= 0) return _n;
    for (var _di = 0; _di < array_length(_g.decoys); _di++) {
        var _d = _g.decoys[_di];
        if (_d.playerIdx != _q || _d.lane != _lane || _d.idx != _idx) continue;
        var _abs = min(_n, _d.hp);
        _d.hp -= _abs;
        _n -= _abs;
        if (_d.hp <= 0) {
            game_log(_g, "P" + string(_q + 1) + "'s Pikpik carrots are devoured!");
            array_delete(_g.decoys, _di, 1);
        } else {
            game_log(_g, "The Pikpik carrots soak " + string(_abs) + " damage (" + string(_d.hp) + " left).");
        }
        break;
    }
    return _n;
}

/// Kill 1 non-immune pikmin PER COLOUR per poison space among the currently-exposed
/// tokens (poisonSpaces keys), then clear all exposure. White/bulbmin/winged immune.
/// Called at orders lock-in (route entries) and at turn finish (carry-dragged entries).
function game_poison_resolve(_g, _p) {
    var _tokens = _g.players[_p].tokens;
    // gather the distinct poison-space keys with any exposure
    var _keys = [];
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        if (!variable_struct_exists(_tok, "poisonSpaces")) continue;
        for (var _k = 0; _k < array_length(_tok.poisonSpaces); _k++) {
            if (!arr_has(_keys, _tok.poisonSpaces[_k])) array_push(_keys, _tok.poisonSpaces[_k]);
        }
    }
    // each space kills 1 non-immune token per colour exposed to THAT space
    var _killed = 0;
    for (var _sk = 0; _sk < array_length(_keys); _sk++) {
        var _key = _keys[_sk];
        var _colourDone = {};
        var _i = 0;
        while (_i < array_length(_tokens)) {
            var _tok = _tokens[_i];
            if (variable_struct_exists(_tok, "poisonSpaces") && arr_has(_tok.poisonSpaces, _key)
                && !game_type_poison_immune(_tok.typeId, game_no_imm(_g))
                && !variable_struct_exists(_colourDone, _tok.typeId)) {
                _colourDone[$ _tok.typeId] = true;
                if (_tok.loc.kind == "space") game_fx_pik(_g, _tok, _tok.loc.lane, _tok.loc.idx);
                array_delete(_tokens, _i, 1);
                _killed += 1;
                continue;
            }
            _i += 1;
        }
    }
    if (_killed > 0) game_log(_g, "Poison claims " + string(_killed) + " of P" + string(_p + 1) + "'s pikmin (1 per colour per space).");
    for (var _i = 0; _i < array_length(_tokens); _i++) _tokens[_i].poisonSpaces = [];
}

/// Finish-beat poison pass: resolves exposure picked up DURING resolution
/// (riders dragged onto poison by a carry). Route-entry tolls already ticked
/// at orders lock-in via game_orders_done.
function game_poison_step(_g, _p) {
    game_poison_resolve(_g, _p);
}

function game_carriers_all_white(_g, _p, _t) {
    var _here = game_tokens_at(_g, _p, { kind: "space", lane: _t.lane, idx: _t.idx });
    if (array_length(_here) == 0) return false;
    for (var _i = 0; _i < array_length(_here); _i++) {
        if (_here[_i].typeId != "white") return false;
    }
    return true;
}

/// Is any purple among the carriers? Purples are strong but slow - one on a stack
/// anchors it, so the group can't get the 2x-weight rush (experimental).
function game_carriers_have_purple(_g, _p, _t) {
    var _here = game_tokens_at(_g, _p, { kind: "space", lane: _t.lane, idx: _t.idx });
    for (var _i = 0; _i < array_length(_here); _i++) {
        if (_here[_i].typeId == "purple") return true;
    }
    return false;
}

/// Does this pile hold a HEAVY treasure? Such a pile needs a purple pikmin among its carriers to move.
function game_pile_has_heavy(_g, _t) {
    for (var _c = 0; _c < array_length(_t.cards); _c++)
        if (treasure_def_get(_t.cards[_c]).effectName == "Heavy") return true;
    return false;
}

function game_carry_step(_g, _p, _sprayedOnly = false) {
    var _i = 0;
    while (_i < array_length(_g.treasures)) {
        var _t = _g.treasures[_i];
        var _removed = false;
        var _spiced = game_has_own_spray(_g, _p, _t.lane, _t.idx);
        if ((_t.boss == undefined) && array_length(_t.cards) > 0 && (!_sprayedOnly || _spiced)) {
            var _topDef = treasure_def_get(_t.cards[array_length(_t.cards) - 1]);
            var _own = game_strength_at(_g, _p, _t.lane, _t.idx);
            var _opp = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
            // ADVENTURE "What's This Made Of?!?" event: piles weigh +3 more THIS turn.
            var _wgt = _topDef.weight + (variable_struct_exists(_g, "advTreasureHeavier") ? _g.advTreasureHeavier : 0);
            // the spray's EXTRA action is what overcomes a stalemate: ties only
            // move during the sprayed bonus pass (so tied = 1 space, untied = 2)
            // HEAVY treasure power: a pile holding a Heavy piece won't budge without a purple
            // pikmin among the carriers, no matter how much other power is on it.
            if (_own >= _wgt && game_pile_has_heavy(_g, _t) && !game_carriers_have_purple(_g, _p, _t)) {
                if (!_sprayedOnly) game_log(_g, _topDef.name + " is too heavy - it needs a purple pikmin to move!");
            } else
            if (_own >= _wgt && (_own > _opp || (_sprayedOnly && _spiced && _own == _opp && _own > 0))) {
                // 2 spaces if an all-white team hauls it, OR (experimental "rush")
                // when the carrying power is at least double the pile's weight. Rush is
                // denied if a purple anchors the stack (strong yet slow), OR the
                // opponent has enough presence to HOLD it (opp meets the weight): you
                // can't rush a treasure that's being pulled against, only inch it.
                var _steps = 1;
                if (game_carriers_all_white(_g, _p, _t)) _steps = 2;
                if (global.expRules.rush && _own >= _wgt * 2 && _opp < _wgt
                    && !game_carriers_have_purple(_g, _p, _t)) {
                    _steps = 2;
                    _t.rushMove = true; // render hint: animate this haul at walking pace, not a heavy lumber
                    game_log(_g, "P" + string(_p + 1) + " overpowers the " + _topDef.name + " - it rushes an extra space!");
                }
                repeat (_steps) {
                    var _result = game_carry_one_space(_g, _p, _t);
                    if (_result == "collected") { _removed = true; break; }
                    if (_result == "stalled") break;
                }
            } else if (_own > 0 && _own == _opp && _own >= _wgt) {
                game_log(_g, _topDef.name + ": carry stalemate!");
            }
        }
        if (!_removed) _i += 1;
    }
}

/// Only the plain Bridge breaks when a treasure pile is hauled off it (climbing
/// sticks don't mind, and tunnels never let a treasure on in the first place).
function game_bridge_break_check(_g, _lane, _idx) {
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.structure == undefined) return;
    if (_space.structure.structId != "bridge") return;
    _space.structure = undefined;
    game_sfx(_g, "sfxDestroyStructure");   // a bridge collapsing suits the heavy destruction SFX (walls + bridges)
    game_log(_g, "The Bridge collapses as the treasure is hauled off it!");
}

function game_carry_one_space(_g, _p, _t, _sliding = false) {
    var _dir = (_p == 0) ? -1 : 1;
    var _newIdx = _t.idx + _dir;
    var _oldIdx = _t.idx;
    var _hereLoc = { kind: "space", lane: _t.lane, idx: _t.idx };

    // banked once carried off THIS player's home edge: player 0 past index 0, player 1 past the
    // lane's last index. (Hardcoding >6 banked a treasure the instant it reached index 7 on a long
    // lane - the far edge is the lane's own length, not a fixed 6.)
    if (_newIdx < 0 || _newIdx >= array_length(_g.board.lanes[_t.lane].spaces)) {
        // carried off the board edge: it heads HOME to be banked. Scoring is DEFERRED
        // until the pile finishes animating home (game_finalize_departing), so it
        // doesn't blink out of existence at the edge. Mechanically it leaves play now.
        var _total = 0;
        for (var _c = 0; _c < array_length(_t.cards); _c++) _total += treasure_def_get(_t.cards[_c]).value;
        array_push(_g.departing, { cards: _t.cards, playerIdx: _p, lane: _t.lane, fromIdx: _oldIdx, total: _total });
        game_sfx(_g, "sfxBank", 1, _t.lane, _oldIdx);   // multiple piles bank together - don't stack, it's loud
        // on-bank powers fire NOW (deterministic, before the enemy beat) - see game_treasure_bank_effects
        game_treasure_bank_effects(_g, _p, _t.cards);
        // adventure "1 day per treasure gathered" economy (Glutton's): banking a pile buys +1 day of
        // budget for THIS mission - extends the day limit as you collect (leftover carries at clear).
        if (variable_struct_exists(_g, "advDayPerTreasure") && _g.advDayPerTreasure) {
            _g.dayLimit += 1;
            game_log(_g, "A treasure is banked - +1 day! (" + string(_g.dayLimit) + " total)");
        }
        // no log here - the pile animates home and the bank line reports the score
        for (var _q = 0; _q < 2; _q++) {
            var _riders = game_tokens_at(_g, _q, _hereLoc);
            for (var _r = 0; _r < array_length(_riders); _r++) {
                if (token_is_disabled(_riders[_r])) continue; // frozen/buried: not attached, stays put as the pile banks
                _riders[_r].loc = { kind: "home" };
                // the owner's carriers escort the pile home before returning to their slot (cosmetic)
                if (_q == _p) _riders[_r].escort = { lane: _t.lane };
            }
        }
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            if (_g.treasures[_ti] == _t) { array_delete(_g.treasures, _ti, 1); break; }
        }
        // clear any spray tokens left on the vacated space
        var _si = 0;
        while (_si < array_length(_g.sprays)) {
            if (_g.sprays[_si].lane == _t.lane && _g.sprays[_si].idx == _t.idx) { array_delete(_g.sprays, _si, 1); continue; }
            _si += 1;
        }
        game_bridge_break_check(_g, _t.lane, _oldIdx);
        return "collected";
    }

    var _destSpace = _g.board.lanes[_t.lane].spaces[_newIdx];
    // Enemies and another treasure pile hard-block a carry. Hazards, emitters and
    // walls are "tile modifications" the treasure passes OVER - they only stall the
    // carry if a CARRYING pikmin can't cross them (a wall/non-immune hazard is a
    // wall to that pikmin). Immune carriers glide the treasure across freely.
    if (_destSpace.enemy != undefined || game_treasure_at(_g, _t.lane, _newIdx) != undefined) {
        game_log(_g, "Treasure carry blocked at lane " + string(_t.lane + 1) + ".");
        return "stalled";
    }
    // tunnels carry pikmin, not piles: "Treasures cannot pass this."
    if (_destSpace.structure != undefined && _destSpace.structure.structId == "tunnel") {
        game_log(_g, "The treasure won't fit through the Tunnel!");
        return "stalled";
    }
    var _carriers = game_tokens_at(_g, _p, _hereLoc);
    for (var _r = 0; _r < array_length(_carriers); _r++) {
        if (token_is_disabled(_carriers[_r])) continue; // frozen/buried: it let go, so it can't stall the haul either
        if (!game_type_can_enter(pikmin_type_get(_carriers[_r].typeId), _destSpace, false)) {
            game_log(_g, "Carry stalled: " + _carriers[_r].typeId + " pikmin can't cross into the next space.");
            return "stalled";
        }
    }
    // the pile moves, and everyone on it (both players') rides along. A NORMAL carry
    // counts as "passing" - carriers dragged INTO a poison space are exposed
    // (resolved at the finish beat; card effects like Oatchi Rush skip this).
    var _enteredPoison = game_space_is_poison(_g, _t.lane, _newIdx);
    var _newKey = string(_t.lane) + "_" + string(_newIdx);
    var _riderTotal = 0;
    for (var _q = 0; _q < 2; _q++) {
        var _riders = game_tokens_at(_g, _q, _hereLoc);
        for (var _r = 0; _r < array_length(_riders); _r++) {
            if (token_is_disabled(_riders[_r])) continue; // frozen (let go) or buried (stuck to the tile) - they stay put
            _riders[_r].loc = { kind: "space", lane: _t.lane, idx: _newIdx };
            _riders[_r].movedThisTurn = true;
            if (_enteredPoison && _q == _p) token_poison_add(_riders[_r], _newKey);
            _riderTotal += 1;
        }
    }
    // a mine under the departing group takes 1 damage per pikmin that passed it
    var _oldMine = game_mine_at(_g, _t.lane, _oldIdx);
    if (_oldMine != undefined) game_mine_damage(_g, _oldMine, _riderTotal);
    // a rider dragged onto a blocking hazard it can't survive is lost (the carrying
    // side already passed the entry check; this catches the opponent's contesting
    // pikmin that got hauled onto fire/water/etc.)
    var _culled = 0;
    for (var _q = 0; _q < 2; _q++) {
        var _toks = _g.players[_q].tokens;
        var _i = 0;
        while (_i < array_length(_toks)) {
            var _tk = _toks[_i];
            if (_tk.loc.kind == "space" && _tk.loc.lane == _t.lane && _tk.loc.idx == _newIdx
                && !game_type_can_enter(pikmin_type_get(_tk.typeId), _destSpace, false)) {
                game_fx_pik(_g, _tk, _t.lane, _newIdx);
                array_delete(_toks, _i, 1);
                _culled += 1;
                continue;
            }
            _i += 1;
        }
    }
    if (_culled > 0) game_log(_g, string(_culled) + " pikmin can't survive the hazard and are lost as the treasure moves over it!");
    // spray tokens ride along with the carrying group
    for (var _si = 0; _si < array_length(_g.sprays); _si++) {
        var _spr = _g.sprays[_si];
        if (_spr.lane == _t.lane && _spr.idx == _t.idx) _spr.idx = _newIdx;
    }
    _t.idx = _newIdx;
    // no per-space carry log - the treasure visibly slides on the board
    game_bridge_break_check(_g, _t.lane, _oldIdx);
    // ICE SLIDE (experimental): a pile carried ONTO ice keeps gliding in the carry direction across the
    // whole ice run, coming to rest on the first non-ice tile on the far side ("great coming back"). If the
    // run edges up to the home edge it stops on the LAST ice tile (no auto-bank); a blocked tile stops it
    // too. Re-uses this same one-space carry per glide tile (_sliding guards against re-triggering).
    if (!_sliding && global.expRules.iceSlide && game_space_is_ice(_destSpace)) {
        var _sguard = 0;
        while (game_space_is_ice(_g.board.lanes[_t.lane].spaces[_t.idx]) && _sguard < 40) {
            _sguard += 1;
            var _snext = _t.idx + _dir;
            if (_snext < 0 || _snext >= array_length(_g.board.lanes[_t.lane].spaces)) break;   // ice runs to home -> rest on the last ice tile
            if (game_carry_one_space(_g, _p, _t, true) != "moved") break;                       // glide one tile; stalled/blocked -> stop
        }
    }
    return "moved";
}

/// Bank a departing pile once it has reached HOME (called by the presentation when
/// the homing animation lands, or forced at game over). Credits cards + score here,
/// so the score ticks up exactly when the pile arrives - not when it left the board.
function game_finalize_departing(_g, _entry) {
    var _pl = _g.players[_entry.playerIdx];
    for (var _c = 0; _c < array_length(_entry.cards); _c++) array_push(_pl.collected, _entry.cards[_c]);
    _pl.score += _entry.total;
    game_log(_g, "P" + string(_entry.playerIdx + 1) + " banks " + string(_entry.total) + "p (score now " + string(game_realized_score(_g, _entry.playerIdx)) + "p).");
    for (var _i = 0; _i < array_length(_g.departing); _i++) {
        if (_g.departing[_i] == _entry) { array_delete(_g.departing, _i, 1); break; }
    }
}

/// Force-bank every pile still animating home (game over needs final scores now).
function game_flush_departing(_g) {
    while (array_length(_g.departing) > 0) game_finalize_departing(_g, _g.departing[0]);
}

/// Remove any pikmin still walking to the Onion (loc "onion") that hasn't poofed yet - used
/// at game over / whenever presentation may stop mid-walk, so a discard can't strand a token.
function game_flush_onion(_g) {
    for (var _p = 0; _p < array_length(_g.players); _p++) {
        var _toks = _g.players[_p].tokens;
        for (var _i = array_length(_toks) - 1; _i >= 0; _i--)
            if (_toks[_i].loc.kind == "onion") array_delete(_toks, _i, 1);
    }
}

// ========================= TREASURE ON-BANK POWERS =========================
// A subset of treasures carry a Good/Bad power (effectType/effectName/effect in treasures.json - the
// shared ALL1/ALL2 sets). When a pile is banked, each such card in it fires its power for the banking
// player: Good helps the banker, Bad hurts them. Fired from game_carry_one_space's bank branch (so it
// runs DETERMINISTICALLY before the enemy beat - Soothe can suppress that turn's attacks). Effects
// that target the OPPONENT no-op in solo. A few rich effects are first-pass auto-resolved (no target
// picker yet - sensible auto-choice); Spy/Reveal/Wild/Glow Up/Heavy are stubbed + logged for now.

/// The opponent seat, or -1 in solo (no opponent).
function game_opp(_g, _p) { return _g.solo ? -1 : (1 - _p); }

/// Which player's half a space index sits on (symmetric 2-player board); -1 = the neutral centre row.
function game_idx_side(_g, _idx) {
    var _c = _g.board.centerRow;
    if (_idx < _c) return 0;
    if (_idx > _c) return 1;
    return -1;
}
/// Is space _idx on player _p's side? Solo = the near (home) half, since idx_side has no 2nd player.
function game_side_match(_g, _p, _idx) {
    if (_g.solo) return _idx <= floor((_g.board.maxSpaces - 1) / 2);
    return game_idx_side(_g, _idx) == _p;
}

function game_power_draw_gather(_g, _p) {
    if (array_length(_g.decks.gather) == 0 && array_length(_g.decks.gatherDiscard) > 0) {
        _g.decks.gather = _g.decks.gatherDiscard; _g.decks.gatherDiscard = []; deck_shuffle(_g.decks.gather);
    }
    if (array_length(_g.decks.gather) == 0) return false;
    array_push(_g.players[_p].hand, array_pop(_g.decks.gather));
    return true;
}
function game_power_draw_pellet(_g, _p) {
    var _face = game_die_roll(_g);
    if (_face == undefined) return false;
    array_push(_g.players[_p].pellets, _face.color + string(_face.value));
    return true;
}
function game_power_grant_treasure(_g, _p) {
    if (array_length(_g.decks.treasure) == 0) return false;
    var _tid = array_pop(_g.decks.treasure);
    array_push(_g.players[_p].collected, _tid);
    _g.players[_p].score += treasure_def_get(_tid).value;
    return true;
}
function game_power_discard_a(_g, _tid, _lane, _idx) {   // FX + discard-deck bookkeeping for a removal
    game_fx_enemy(_g, _tid, _lane, _idx, false);
    array_push(_g.decks.enemyDiscard, _tid);
}
/// Discard the strongest enemy (mode "field") or boss (mode "boss") on the board. Returns true if one.
function game_power_discard_enemy(_g, _mode) {
    var _target = undefined, _bestHp = -1;
    if (_mode == "field") {
        for (var _l = 0; _l < _g.board.laneCount; _l++) {
            var _sp = _g.board.lanes[_l].spaces;
            for (var _i = 0; _i < array_length(_sp); _i++) {
                var _e = _sp[_i].enemy;
                if (_e != undefined && !_e.dead && _e.curHp > _bestHp) { _bestHp = _e.curHp; _target = { id: _e.enemyDefId, lane: _l, idx: _i, boss: false }; }
            }
        }
    } else {
        for (var _t = 0; _t < array_length(_g.treasures); _t++) {
            var _b = _g.treasures[_t].boss;
            if (_b != undefined && !_b.dead && _b.curHp > _bestHp) { _bestHp = _b.curHp; _target = { id: _b.enemyDefId, tre: _t, boss: true }; }
        }
    }
    if (_target == undefined) return "";
    if (_target.boss) { var _tt = _g.treasures[_target.tre]; game_fx_enemy(_g, _target.id, _tt.lane, _tt.idx, true); array_push(_g.decks.enemyDiscard, _target.id); _tt.boss = undefined; }
    else { game_power_discard_a(_g, _target.id, _target.lane, _target.idx); _g.board.lanes[_target.lane].spaces[_target.idx].enemy = undefined; }
    return _target.id;   // the discarded enemy's defId ("" = none), so the toast can show its card
}
/// Discard every field enemy in the lane with the most of them. Returns the lane idx, or -1.
function game_power_clear_lane(_g) {
    var _bestLane = -1, _bestN = 0;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces, _n = 0;
        for (var _i = 0; _i < array_length(_sp); _i++) if (_sp[_i].enemy != undefined && !_sp[_i].enemy.dead) _n += 1;
        if (_n > _bestN) { _bestN = _n; _bestLane = _l; }
    }
    if (_bestLane < 0) return -1;
    var _sp2 = _g.board.lanes[_bestLane].spaces;
    for (var _i2 = 0; _i2 < array_length(_sp2); _i2++) {
        var _e = _sp2[_i2].enemy;
        if (_e != undefined && !_e.dead) { game_power_discard_a(_g, _e.enemyDefId, _bestLane, _i2); _sp2[_i2].enemy = undefined; }
    }
    return _bestLane;
}
/// Discard every enemy (field + boss) on the given board side.
function game_power_discard_side_enemies(_g, _side) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (game_idx_side(_g, _i) != _side) continue;
            var _e = _sp[_i].enemy;
            if (_e != undefined && !_e.dead) { game_power_discard_a(_g, _e.enemyDefId, _l, _i); _sp[_i].enemy = undefined; }
        }
    }
    for (var _t = 0; _t < array_length(_g.treasures); _t++) {
        var _tr = _g.treasures[_t];
        if (game_idx_side(_g, _tr.idx) != _side) continue;
        var _b = _tr.boss;
        if (_b != undefined && !_b.dead) { game_fx_enemy(_g, _b.enemyDefId, _tr.lane, _tr.idx, true); array_push(_g.decks.enemyDiscard, _b.enemyDefId); _tr.boss = undefined; }
    }
}
/// Respawn enemies on every bare enemy space on player _p's side (from the enemy deck).
function game_power_respawn_side(_g, _p) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (game_side_match(_g, _p, _i) && _sp[_i].kind == "enemy" && _sp[_i].enemy == undefined) game_spawn_enemy_at(_g, _l, _i);
        }
    }
}
/// Place up to _count emitters/structures on empty spaces on player _p's side. Returns how many.
function game_power_place_emitters(_g, _p, _structId, _count) {
    var _placed = 0, _hp = hazard_def_get(_structId).hp;
    for (var _l = 0; _l < _g.board.laneCount && _placed < _count; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp) && _placed < _count; _i++) {
            if (!game_side_match(_g, _p, _i)) continue;
            if (_sp[_i].kind == "treasure" || _sp[_i].structure != undefined || _sp[_i].enemy != undefined) continue;
            _sp[_i].structure = { structId: _structId, curHp: _hp };
            _placed += 1;
        }
    }
    return _placed;
}
/// Remove one hazard (structure or terrain) on the given side. Returns true if one was removed.
function game_power_erase_hazard(_g, _side) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (game_idx_side(_g, _i) != _side) continue;
            if (_sp[_i].structure != undefined) { _sp[_i].structure = undefined; return true; }
            if (_sp[_i].kind == "hazard") { _sp[_i].kind = "plain"; _sp[_i].hazard = ""; return true; }
        }
    }
    return false;
}

/// Fire every Good/Bad on-bank power carried by a just-banked pile, for the banking player _p.
function game_treasure_bank_effects(_g, _p, _cards) {
    for (var _c = 0; _c < array_length(_cards); _c++) {
        var _def = treasure_def_get(_cards[_c]);
        if (_def.effectType == "Good" || _def.effectType == "Bad") game_treasure_power_apply(_g, _p, _def);
    }
}

// ---- Reveal power: the opponent picks a pile on the board + which card sits on top ----
/// Any reorderable pile? (2+ cards, not boss-guarded).
function game_reveal_any_pile(_g) {
    for (var _i = 0; _i < array_length(_g.treasures); _i++)
        if (_g.treasures[_i].boss == undefined && array_length(_g.treasures[_i].cards) >= 2) return true;
    return false;
}
/// Is (lane,idx) a legal pile to reorder RIGHT NOW (pile-pick phase of a pending Reveal)?
function game_reveal_pile_ok(_g, _lane, _idx) {
    if (_g.pendingReveal == undefined || _g.pendingReveal.lane >= 0) return false;
    var _t = game_treasure_at(_g, _lane, _idx);
    return (_t != undefined && _t.boss == undefined && array_length(_t.cards) >= 2);
}
/// Commit the chosen pile (advance to the card-pick phase).
function game_reveal_pick_pile(_g, _lane, _idx) {
    if (!game_reveal_pile_ok(_g, _lane, _idx)) return false;
    _g.pendingReveal.lane = _lane; _g.pendingReveal.idx = _idx;
    return true;
}
/// Move the chosen card to the TOP of the picked pile, then clear the pending Reveal.
function game_reveal_pick_card(_g, _cardIdx) {
    if (_g.pendingReveal == undefined || _g.pendingReveal.lane < 0) return false;
    var _t = game_treasure_at(_g, _g.pendingReveal.lane, _g.pendingReveal.idx);
    if (_t == undefined || _cardIdx < 0 || _cardIdx >= array_length(_t.cards)) return false;
    var _card = _t.cards[_cardIdx];
    array_delete(_t.cards, _cardIdx, 1);
    array_push(_t.cards, _card);   // top = last
    game_log(_g, "P" + string(_g.pendingReveal.chooser + 1) + " surfaces " + treasure_def_get(_card).name + " atop the pile.");
    _g.pendingReveal = undefined;
    return true;
}
/// AI / sim auto-resolve: pick the pile with the heaviest card and surface that card (hurts the carrier).
function game_reveal_auto(_g) {
    if (_g.pendingReveal == undefined) return;
    var _bestI = -1, _bestW = -1, _bestC = 0;
    for (var _i = 0; _i < array_length(_g.treasures); _i++) {
        var _t = _g.treasures[_i];
        if (_t.boss != undefined || array_length(_t.cards) < 2) continue;
        for (var _c = 0; _c < array_length(_t.cards); _c++) {
            var _w = treasure_def_get(_t.cards[_c]).weight;
            if (_w > _bestW) { _bestW = _w; _bestI = _i; _bestC = _c; }
        }
    }
    if (_bestI < 0) { _g.pendingReveal = undefined; return; }
    _g.pendingReveal.lane = _g.treasures[_bestI].lane; _g.pendingReveal.idx = _g.treasures[_bestI].idx;
    game_reveal_pick_card(_g, _bestC);
}

function game_treasure_power_apply(_g, _p, _def) {
    var _opp = game_opp(_g, _p);
    var _tag = "[" + _def.effectType + "] " + _def.name + " (" + _def.effectName + "): ";   // [Good]/[Bad] badge, coloured by the log renderer
    // cosmetic cue -> the renderer pops a toast (title = power name, body = effect text). Cases
    // below fill _cue.outcome for the mini bubble: {kind:"card", cardId} shows a card thumbnail,
    // {kind:"text", text} shows a small label (e.g. a coin flip). undefined = no bubble.
    var _cue = { name: _def.effectName, effect: _def.effect, good: (_def.effectType == "Good"), outcome: undefined };
    array_push(_g.bankCues, _cue);
    game_sfx(_g, "sfxBankEffect", 1);   // several effects can fire at once - don't stack
    switch (_def.effectName) {
        case "Reverse":
            _g.dayTrack = max(1, _g.dayTrack - 1);
            game_log(_g, _tag + "day track moves back to " + string(_g.dayTrack) + ".");
            break;
        case "Glutton": case "Scatter": {
            var _wtoks = _g.players[_p].tokens;
            var _n = array_length(_wtoks);
            for (var _wi = 0; _wi < _n; _wi++) {
                var _wtk = _wtoks[_wi];
                if (_wtk.loc.kind == "space") game_fx_pik(_g, _wtk, _wtk.loc.lane, _wtk.loc.idx); // souls rise from the field
            }
            _g.players[_p].tokens = [];
            game_log(_g, _tag + "P" + string(_p + 1) + " loses all " + string(_n) + " of their pikmin!");
            break;
        }
        case "Soothe":
            _g.soothed = true;
            game_log(_g, _tag + "enemies won't attack this turn.");
            break;
        case "Deafen": {
            var _dbid = game_power_discard_enemy(_g, "boss");
            if (_dbid != "") _cue.outcome = { kind: "card", cardId: card_enemy_alias(_dbid, _g.boardDef.setNumber) };
            game_log(_g, _tag + (_dbid != "" ? "a boss is discarded." : "no boss to discard."));
            break;
        }
        case "Spook": {
            var _sbid = game_power_discard_enemy(_g, "field");
            if (_sbid != "") _cue.outcome = { kind: "card", cardId: card_enemy_alias(_sbid, _g.boardDef.setNumber) };
            game_log(_g, _tag + (_sbid != "" ? "an enemy is discarded." : "no enemy to discard."));
            break;
        }
        case "Clear": {
            var _ln = game_power_clear_lane(_g);
            if (_ln >= 0) _cue.outcome = { kind: "text", text: "Lane " + string(_ln + 1) };
            game_log(_g, _tag + (_ln >= 0 ? ("all enemies in lane " + string(_ln + 1) + " discarded.") : "no enemies to clear."));
            break;
        }
        case "Draw":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            if (array_length(_g.players[_opp].hand) > 0) {
                var _ri = irandom(array_length(_g.players[_opp].hand) - 1);
                var _took = _g.players[_opp].hand[_ri];
                array_push(_g.players[_p].hand, _took);
                array_delete(_g.players[_opp].hand, _ri, 1);
                _cue.outcome = { kind: "card", cardId: _took };   // toast shows the stolen card
                game_log(_g, _tag + "P" + string(_p + 1) + " takes a card from P" + string(_opp + 1) + "'s hand.");
            } else game_log(_g, _tag + "opponent's hand is empty.");
            break;
        case "Gamble": {
            if (irandom(1) == 0) { _cue.outcome = { kind: "text", text: "Tails" }; game_log(_g, _tag + "coin flip: tails - nothing."); break; }
            var _txt = _def.effect;
            var _cnt = (string_pos("2 ", _txt) > 0) ? 2 : 1;
            var _kind = (string_pos("pellet", _txt) > 0) ? "pellet" : ((string_pos("treasure", _txt) > 0) ? "treasure" : "gather");
            var _lastCard = "";
            repeat (_cnt) {
                if (_kind == "pellet") game_power_draw_pellet(_g, _p);
                else if (_kind == "treasure") { if (game_power_grant_treasure(_g, _p)) _lastCard = _g.players[_p].collected[array_length(_g.players[_p].collected) - 1]; }
                else { if (game_power_draw_gather(_g, _p)) _lastCard = _g.players[_p].hand[array_length(_g.players[_p].hand) - 1]; }
            }
            // heads: show the drawn card (gather/treasure); pellets have no card art, so just the flip
            _cue.outcome = (_lastCard != "") ? { kind: "card", cardId: _lastCard } : { kind: "text", text: "Heads!" };
            game_log(_g, _tag + "coin flip: heads - P" + string(_p + 1) + " draws " + string(_cnt) + " " + _kind + " card(s).");
            break;
        }
        case "Man's Best Friend": {
            var _found = false;
            for (var _i = 0; _i < array_length(_g.decks.gather); _i++) {
                if (_g.decks.gather[_i] == "oatchirush") { array_delete(_g.decks.gather, _i, 1); array_push(_g.players[_p].hand, "oatchirush"); _found = true; break; }
            }
            if (_found) _cue.outcome = { kind: "card", cardId: "oatchirush" };
            game_log(_g, _tag + (_found ? "found an Oatchi Rush in the deck." : "no Oatchi Rush in the deck."));
            break;
        }
        case "Respawn":
            game_power_respawn_side(_g, _p);
            game_log(_g, _tag + "enemies respawn on P" + string(_p + 1) + "'s side.");
            break;
        case "Justice":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            game_power_discard_side_enemies(_g, _opp);
            game_log(_g, _tag + "all enemies on P" + string(_opp + 1) + "'s side discarded.");
            break;
        case "Storm": case "Wildfire": case "Noxious": case "Flood": {
            var _sid = (_def.effectName == "Storm") ? "electricitygenerator"
                     : ((_def.effectName == "Wildfire") ? "firegeyser"
                     : ((_def.effectName == "Noxious") ? "poisonemitter" : "waterspout"));
            var _placed = game_power_place_emitters(_g, _p, _sid, 2);
            game_log(_g, _tag + string(_placed) + " placed on P" + string(_p + 1) + "'s side.");
            break;
        }
        case "Erase":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            game_log(_g, _tag + (game_power_erase_hazard(_g, _opp) ? "a hazard on the opponent's side is destroyed." : "no hazard to destroy."));
            break;
        case "Find":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            if (game_power_grant_treasure(_g, _opp)) _cue.outcome = { kind: "card", cardId: _g.players[_opp].collected[array_length(_g.players[_opp].collected) - 1] };
            game_log(_g, _tag + "opponent draws a free treasure.");
            break;
        // --- first-pass stubs (need a target picker / set-scoring / carry rules); logged, no state change ---
        case "Spy":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            _g.pendingSpy = { viewer: _p };   // controller shows the viewer a one-time modal of the opponent's hand
            game_log(_g, _tag + "P" + string(_p + 1) + " peeks at P" + string(_opp + 1) + "'s hand.");
            break;
        case "Reveal":
            if (_opp < 0) { game_log(_g, _tag + "no opponent (solo) - no effect."); break; }
            _g.pendingReveal = { chooser: _opp, lane: -1, idx: -1 };   // opponent picks a pile + its new top card
            if (!game_reveal_any_pile(_g)) { _g.pendingReveal = undefined; game_log(_g, _tag + "no reorderable pile on the board."); }
            else game_log(_g, _tag + "P" + string(_opp + 1) + " picks a new top card for a pile.");
            break;
        case "Wild":
            _g.players[_p].wildCount += 1;   // a wildcard set-member (persists); completes an incomplete set at scoring
            game_log(_g, _tag + "counts as any set - completes your highest incomplete set.");
            break;
        case "Glow Up":
            _g.players[_p].glowUp = true;    // persistent: your sub-100p treasures score +100
            game_log(_g, _tag + "your treasures under 100p now score +100.");
            break;
        case "Heavy":   break;   // a CARRY restriction (needs a purple to move), not an on-bank effect
        default:        game_log(_g, _tag + "(unrecognized power)"); break;
    }
}

/// Settle the score at game over: bank any pile still in flight, then decide the
/// winner. Called by the controller once the board has stopped moving (so the final
/// haul banks before the result shows). Idempotent-ish via the controller's flag.
function game_finalize_gameover(_g) {
    game_flush_departing(_g);
    game_flush_onion(_g);
    var _s0 = game_realized_score(_g, 0);
    var _s1 = game_realized_score(_g, 1);
    _g.winner = (_s0 == _s1) ? -1 : ((_s0 > _s1) ? 0 : 1);
    game_log(_g, "GAME OVER! P1: " + string(_s0) + "p vs P2: " + string(_s1) + "p (sets need " + string(global.rules.setThreshold) + "+ pieces to score).");
}

// ---------- combat ----------

function pikmin_kill_priority(_typeId) {
    if (_typeId == "purple") return 2;
    if (_typeId == "white") return 1;
    return 0;
}

/// Kill up to _n of player _p's tokens on a space, respecting attack-element
/// immunities. Killed whites strike back at _f's enemy for 1 each.
function game_kill_tokens(_g, _p, _lane, _idx, _n, _enemyDef, _f) {
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    var _killed = 0;
    var _whiteRevenge = 0;
    for (var _prio = 0; _prio <= 2 && _killed < _n; _prio++) {
        var _tokens = _g.players[_p].tokens;
        var _i = 0;
        while (_i < array_length(_tokens) && _killed < _n) {
            var _tok = _tokens[_i];
            if (game_loc_eq(_tok.loc, _loc) && pikmin_kill_priority(_tok.typeId) == _prio) {
                var _typeDef = pikmin_type_get(_tok.typeId);
                var _immune = false;
                var _immOff = variable_struct_exists(_g, "advNoImmunities") && _g.advNoImmunities;   // "Rebooting..." event
                if (!_immOff && _enemyDef.attackElement != "" && arr_has(_typeDef.immunities, _enemyDef.attackElement)) _immune = true;
                if (!_immune) {
                    if (_tok.typeId == "white") _whiteRevenge += 1;
                    game_fx_pik(_g, _tok, _lane, _idx, _enemyDef.attackElement == "crush");
                    array_delete(_tokens, _i, 1);
                    _killed += 1;
                    continue;
                }
            }
            _i += 1;
        }
    }
    if (_killed > 0) game_log(_g, _enemyDef.name + " defeats " + string(_killed) + " of P" + string(_p + 1) + "'s pikmin!");
    if (_whiteRevenge > 0 && _f != undefined && !_f.enemy.dead) {
        _f.enemy.curHp -= _whiteRevenge;
        game_log(_g, "Dying white pikmin poison the enemy for " + string(_whiteRevenge) + "!");
        if (_f.enemy.curHp <= 0) game_enemy_die(_g, _p, _f);
    }
    return _killed;
}

/// Parse "Must be attacked by at least N <type>" abilities (Waterwraith's purple,
/// the rock-requirement beasts, Vehemoth's 3 yellows). Returns {count, typeId} or undefined.
function game_attack_requirement(_def) {
    if (!variable_struct_exists(_def, "ability") || _def.ability == "") return undefined;
    var _ab = string_lower(_def.ability);
    var _pre = "must be attacked by at least ";
    if (string_pos(_pre, _ab) != 1) return undefined;
    var _rest = string_delete(_ab, 1, string_length(_pre));
    var _sp = string_pos(" ", _rest);
    if (_sp <= 0) return undefined;
    var _count = real(string_copy(_rest, 1, _sp - 1));
    var _typeWord = string_delete(_rest, 1, _sp);
    if (string_char_at(_typeWord, string_length(_typeWord)) == "s") _typeWord = string_copy(_typeWord, 1, string_length(_typeWord) - 1);
    return { count: _count, typeId: _typeWord };
}

/// Which pikmin types can damage a given structure (wall variants gate their
/// destroyers; emitters are handled by their suicide-defence element instead).
function struct_type_can_damage(_typeId, _structId) {
    switch (_structId) {
        case "arachnodeweb": return _typeId != "winged";                                    // webbed: winged can't destroy
        case "crystalwall":  return arr_has(pikmin_type_get(_typeId).immunities, "crush");  // rock only
        case "electricwall": return arr_has(pikmin_type_get(_typeId).immunities, "electric"); // yellow (and bulbmin)
        case "icewall":      return arr_has(pikmin_type_get(_typeId).immunities, "ice");    // ice (and bulbmin)
        default: return true;
    }
}

/// Boss bounty: the player at the head of the pendingFree queue places one free
/// emitter, under Rock Storm rules (empty basic space, board's emitter list).
function game_place_free_hazard(_g, _lane, _idx, _build) {
    if (array_length(_g.pendingFree) == 0) return false;
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.kind == "hazard" || game_space_has_card(_g, _lane, _idx) || _space.structure != undefined) return false;
    if (!arr_has(_g.boardDef.structures.emitters, _build)) return false;
    var _entry = _g.pendingFree[0];
    var _eDef = hazard_def_get(_build);
    _space.structure = { structId: _build, curHp: _eDef.hp };
    game_log(_g, "P" + string(_entry.playerIdx + 1) + " places a free " + _eDef.name + "!");
    _entry.count -= 1;
    if (_entry.count <= 0) array_delete(_g.pendingFree, 0, 1);
    return true;
}

/// Decline (or no legal spot): forfeit ONE queued free placement.
function game_skip_free_hazard(_g) {
    if (array_length(_g.pendingFree) == 0) return;
    var _entry = _g.pendingFree[0];
    game_log(_g, "P" + string(_entry.playerIdx + 1) + " passes on a free hazard.");
    _entry.count -= 1;
    if (_entry.count <= 0) array_delete(_g.pendingFree, 0, 1);
}

/// Ice Bomb / Lightning Storm: everything on the space is incapacitated for a turn.
/// Frozen pikmin can't move, fight, or carry; stunned enemies skip their next action.
/// _kind tags the source ("ice" / "shock" / "bitter") so the renderer can tint.
/// _caster (if given) is the player casting it - their OWN pikmin are never frozen.
function game_freeze_space(_g, _lane, _idx, _kind = "ice", _caster = undefined) {
    var _count = 0;
    for (var _q = 0; _q < 2; _q++) {
        if (_q == _caster) continue; // your own pikmin don't get caught in your Ice Bomb / Lightning Storm
        var _toks = game_tokens_at(_g, _q, { kind: "space", lane: _lane, idx: _idx });
        for (var _i = 0; _i < array_length(_toks); _i++) { _toks[_i].frozen = 2; _toks[_i].frozenKind = _kind; _count += 1; }
    }
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.enemy != undefined) { _space.enemy.stunned = 1; _space.enemy.stunnedBy = _kind; _count += 1; }
    var _t = game_treasure_at(_g, _lane, _idx);
    if (_t != undefined && _t.boss != undefined) { _t.boss.stunned = 1; _t.boss.stunnedBy = _kind; _count += 1; }
    return _count;
}

/// Swooping Snitchbug: its "kills" are tosses - the tokens survive but can't be
/// ordered on their owner's next turn.
function game_stun_tokens(_g, _p, _lane, _idx, _n) {
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    var _tokens = _g.players[_p].tokens;
    var _stunned = 0;
    for (var _i = 0; _i < array_length(_tokens) && _stunned < _n; _i++) {
        var _tok = _tokens[_i];
        if (!game_loc_eq(_tok.loc, _loc)) continue;
        if (variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) continue;
        _tok.stunned = 2; // ticks down at the owner's next two turn-starts
        _tok.stunKind = "buried"; // snitchbug plants them headfirst; future stuns may differ
        _stunned += 1;
    }
    if (_stunned > 0) game_log(_g, string(_stunned) + " of P" + string(_p + 1) + "'s pikmin are snatched and tossed - they can't move next turn!");
    return _stunned;
}

/// Mark a token BLOWN - shoved by an enemy (tossed / dragged) or an Oatchi Rush, not
/// walking under its own power. The renderer freezes its walk bob and SLIDES it to the
/// new spot, and it yelps a panicked, pitched-up scream. Cosmetic only - the engine never
/// reads `.blown` (the loc has already been set by the caller); it clears itself on arrival.
function game_token_blown(_g, _tok, _lane, _idx) {
    _tok.blown = true;
    game_sfx(_g, "fall1", 4, _lane, _idx); // the scream/tumble - capped ~4 voices, the drain staggers + pitch-spreads them
}

/// Blowhog family: its "kills" are blow-backs - the tokens survive but return HOME.
function game_toss_home_tokens(_g, _p, _lane, _idx, _n) {
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    var _tokens = _g.players[_p].tokens;
    var _tossed = 0;
    for (var _i = 0; _i < array_length(_tokens) && _tossed < _n; _i++) {
        var _tok = _tokens[_i];
        if (!game_loc_eq(_tok.loc, _loc)) continue;
        _tok.loc = { kind: "home" };
        game_token_blown(_g, _tok, _lane, _idx); // freeze-and-slide + scream (fall1), sells the blow-back
        _tossed += 1;
    }
    if (_tossed > 0) game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are blown all the way back HOME!");
    return _tossed;
}

/// Antenna Beetle / Groovy Long Legs family: tokens are thrown a lane sideways.
/// Off the board's edge: killed on boards flagged killedIfThrownOut, else they cling on.
/// Landing on a lethal hazard kills non-immune pikmin, same as being dragged there.
function game_toss_lane_tokens(_g, _p, _lane, _idx, _n, _dir) {
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    var _destLane = _lane + _dir;
    var _offBoard = (_destLane < 0 || _destLane >= _g.board.laneCount);
    var _tokens = _g.players[_p].tokens;
    var _tossed = 0;
    var _killed = 0;
    var _i = 0;
    while (_i < array_length(_tokens) && _tossed < _n) {
        var _tok = _tokens[_i];
        if (!game_loc_eq(_tok.loc, _loc)) { _i += 1; continue; }
        _tossed += 1;
        if (_offBoard) {
            if (_g.boardDef.killedIfThrownOut) { game_sfx(_g, "fall1", 4, _lane, _idx); game_fx_pik(_g, _tok, _lane, _idx); array_delete(_tokens, _i, 1); _killed += 1; continue; }
            _i += 1; // clings to the edge, stays put - NO fall sound (it didn't actually move)
            continue;
        }
        var _destSpace = _g.board.lanes[_destLane].spaces[_idx];
        if (!game_type_can_enter(pikmin_type_get(_tok.typeId), _destSpace, false, true)) {
            game_sfx(_g, "fall1", 4, _lane, _idx);          // the tumble...
            game_fx_pik(_g, _tok, _destLane, _idx);         // ...then it perishes on the hazard (soul rises there)
            array_delete(_tokens, _i, 1);
            _killed += 1;
            continue;
        }
        _tok.loc = { kind: "space", lane: _destLane, idx: _idx };
        game_token_blown(_g, _tok, _lane, _idx); // freeze-and-slide + scream (fall1) into the next lane
        _i += 1;
    }
    if (_tossed > 0) {
        if (_offBoard && _g.boardDef.killedIfThrownOut) game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown clean off the board - lost!");
        else if (_offBoard) game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown at the edge but cling on!");
        else game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown a lane " + (_dir > 0 ? "right" : "left") + (_killed > 0 ? " - " + string(_killed) + " land on a hazard and perish!" : "!"));
    }
    return _tossed;
}

/// Explosive-enemy blast (option: explodeEnemies) damaging OTHER enemies on a space: the lane
/// enemy + any boss there, minus the source. Killed enemies die WITHOUT reward or death
/// abilities - the blast is the enemy's ATTACK, so there's no chain reaction.
function game_blast_hit_enemies(_g, _lane, _idx, _dmg, _src) {
    if (_lane < 0 || _lane >= _g.board.laneCount || _idx < 0 || _idx >= array_length(_g.board.lanes[_lane].spaces)) return;
    var _hits = [];
    var _space = _g.board.lanes[_lane].spaces[_idx];
    if (_space.enemy != undefined && _space.enemy != _src && !_space.enemy.dead) array_push(_hits, { e: _space.enemy, boss: false, host: undefined });
    var _t = game_treasure_at(_g, _lane, _idx);
    if (_t != undefined && _t.boss != undefined && _t.boss != _src && !_t.boss.dead) array_push(_hits, { e: _t.boss, boss: true, host: _t });
    for (var _i = 0; _i < array_length(_hits); _i++) {
        var _e = _hits[_i].e;
        _e.curHp -= _dmg;
        if (_e.curHp <= 0 && !_e.dead) {
            _e.dead = true;
            game_fx_enemy(_g, _e.enemyDefId, _lane, _idx, _hits[_i].boss);
            array_push(_g.decks.enemyDiscard, _e.enemyDefId);
            // still remove the corpse from the board (no reward/abilities - it's the enemy's
            // own attack) - without this the dead enemy lingers, showing negative HP
            game_clear_enemy(_g, { enemy: _e, lane: _lane, idx: _idx, isBoss: _hits[_i].boss, hostT: _hits[_i].host });
            game_log(_g, enemy_def_get(_e.enemyDefId).name + " is caught in the blast!");
        } else {
            game_log(_g, enemy_def_get(_e.enemyDefId).name + " takes " + string(_dmg) + " blast damage (" + string(max(0, _e.curHp)) + " hp left).");
        }
    }
}

function game_enemy_attack(_g, _p, _f) {
    // a Soothe treasure power banked this turn: no enemy attacks at all
    if (variable_struct_exists(_g, "soothed") && _g.soothed) return;
    var _def = game_enemy_def_eff(_g, _f.enemy.enemyDefId);   // adventure events may override element/damage
    // bittered / frozen enemies skip their next action entirely
    if (variable_struct_exists(_f.enemy, "stunned") && _f.enemy.stunned > 0) {
        _f.enemy.stunned -= 1;
        _f.enemy.attacked = true;
        game_log(_g, _def.name + " is incapacitated and skips its action!");
        return;
    }
    _f.enemy.attacked = true;
    // "Any Pikmin attacked this turn..." abilities replace the kill with an effect;
    // the attack stat is just how many pikmin get targeted. A Pikpik decoy distracts
    // these attacks too, soaking targets before any pikmin is affected.
    if (_def.ability != "") {
        var _ab = string_lower(_def.ability);
        if (string_pos("attacked this turn", _ab) > 0) {
            var _nEff = game_decoy_absorb(_g, _p, _f.lane, _f.idx, _def.damage);
            if (string_pos("can't move next turn", _ab) > 0) { game_stun_tokens(_g, _p, _f.lane, _f.idx, _nEff); return; }
            if (string_pos("return home", _ab) > 0) { game_toss_home_tokens(_g, _p, _f.lane, _f.idx, _nEff); return; }
            if (string_pos("thrown one lane to the right", _ab) > 0) { game_toss_lane_tokens(_g, _p, _f.lane, _f.idx, _nEff, 1); return; }
            if (string_pos("thrown one lane to the left", _ab) > 0) { game_toss_lane_tokens(_g, _p, _f.lane, _f.idx, _nEff, -1); return; }
        }
    }
    if (_def.damage > 0) {
        if (_def.attackElement == "explosive") {
            game_sfx(_g, "sfxGunshot", 3, _f.lane, _f.idx);   // groink / man-at-legs / explosive enemy blast
            game_log(_g, _def.name + " explodes in a + pattern!");
            var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
            for (var _o = 0; _o < array_length(_offsets); _o++) {
                var _bl = _f.lane + _offsets[_o][0];
                var _bi = _f.idx + _offsets[_o][1];
                if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi >= array_length(_g.board.lanes[_bl].spaces)) continue;
                game_fx_boom(_g, _bl, _bi);
                for (var _q = 0; _q < 2; _q++) game_kill_tokens(_g, _q, _bl, _bi, game_decoy_absorb(_g, _q, _bl, _bi, _def.damage), _def, undefined);
                if (global.expRules.explodeEnemies) game_blast_hit_enemies(_g, _bl, _bi, _def.damage, _f.enemy);
            }
        } else {
            // only sound if there are actually pikmin here to hit (an enemy "attacks" every turn even
            // with nothing in range - that shouldn't make noise)
            if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _f.lane, idx: _f.idx })) > 0)
                game_sfx(_g, (_def.attackElement == "crush") ? "sfxCrush" : "sfxEnemyAttack", 3, _f.lane, _f.idx);
            game_kill_tokens(_g, _p, _f.lane, _f.idx, game_decoy_absorb(_g, _p, _f.lane, _f.idx, _def.damage), _def, _f);
        }
    }
    // Volatile Dweevil dies after attacking and drops nothing (card still discards)
    if (_f.enemy.enemyDefId == "volatiledweevil" && !_f.enemy.dead) {
        _f.enemy.dead = true;
        array_push(_g.decks.enemyDiscard, "volatiledweevil");
        game_clear_enemy(_g, _f);
        game_log(_g, "The Volatile Dweevil blows itself up. No reward.");
    }
}

function game_clear_enemy(_g, _f) {
    if (_f.isBoss) _f.hostT.boss = undefined;
    else _g.board.lanes[_f.lane].spaces[_f.idx].enemy = undefined;
}

/// Giant Breadbug: a PROGRESS-LOSS clock. It spawns on a pile that has been moved
/// and, every turn end, drags the pile one space back toward the centre treasure
/// space (never past it) until it's killed. Riders (both players' pikmin on the
/// pile) are dragged along, carry-style - non-immune riders dragged onto a blocking
/// hazard die. Sprays ride too; hauling off a plain Bridge snaps it.
function game_breadbug_drag(_g, _t) {
    if (_t.idx == 3) return; // already home at the treasure space
    var _def = enemy_def_get(_t.boss.enemyDefId);
    var _newIdx = _t.idx + sign(3 - _t.idx);
    if (game_space_has_card(_g, _t.lane, _newIdx)) {
        game_log(_g, _def.name + "'s path to the centre is blocked - the treasure stays put.");
        return;
    }
    var _destSpace = _g.board.lanes[_t.lane].spaces[_newIdx];
    var _culled = 0;
    for (var _q = 0; _q < 2; _q++) {
        var _toks = _g.players[_q].tokens;
        var _i = 0;
        while (_i < array_length(_toks)) {
            var _tk = _toks[_i];
            if (_tk.loc.kind == "space" && _tk.loc.lane == _t.lane && _tk.loc.idx == _t.idx) {
                if (!game_type_can_enter(pikmin_type_get(_tk.typeId), _destSpace, false, true)) {
                    game_fx_pik(_g, _tk, _t.lane, _newIdx); // dragged onto a lethal hazard - release a soul
                    array_delete(_toks, _i, 1);
                    _culled += 1;
                    continue;
                }
                _tk.loc = { kind: "space", lane: _t.lane, idx: _newIdx };
                game_token_blown(_g, _tk, _t.lane, _newIdx); // dragged by the Breadbug - slide, don't walk
            }
            _i += 1;
        }
    }
    for (var _si = 0; _si < array_length(_g.sprays); _si++) {
        var _spr = _g.sprays[_si];
        if (_spr.lane == _t.lane && _spr.idx == _t.idx) _spr.idx = _newIdx;
    }
    game_bridge_break_check(_g, _t.lane, _t.idx);
    _t.idx = _newIdx;
    game_log(_g, _def.name + " drags the treasure one space back toward the centre!"
        + (_culled > 0 ? " " + string(_culled) + " clinging pikmin perish on the way!" : ""));
}

/// Dweevil death-drop: leave the matching hazard structure on the space.
/// "fresh" shields it from the rest of THIS turn's resolution (the pikmin that
/// killed the dweevil don't also chew the thing it spawned) - cleared at turn end.
function game_ability_drop_hazard(_g, _f, _structId) {
    if (_f.isBoss) return;
    var _space = _g.board.lanes[_f.lane].spaces[_f.idx];
    if (_space.structure != undefined) return;
    var _sDef = hazard_def_get(_structId);
    _space.structure = { structId: _structId, curHp: _sDef.hp, fresh: true };
    game_log(_g, "It leaves a " + _sDef.name + " behind!");
}

function game_enemy_die(_g, _p, _f) {
    if (_f.enemy.dead) return;
    _f.enemy.dead = true;
    game_fx_enemy(_g, _f.enemy.enemyDefId, _f.lane, _f.idx, _f.isBoss); // squash + spirit + card fade
    var _def = enemy_def_get(_f.enemy.enemyDefId);
    array_push(_g.decks.enemyDiscard, _f.enemy.enemyDefId);
    // consolidate the reward into ONE line: pellets as <value><ColorInitial>, gather
    // cards as "G" (never the card name - that's hidden info). e.g. "Reward: 1B 5B 1R G"
    var _rw = "";
    repeat (_def.reward.pellets) {
        var _face = game_die_roll(_g);
        if (_face == undefined) continue;   // blank / barren die - this reward pellet is nothing
        array_push(_g.players[_p].pellets, _face.color + string(_face.value));
        _rw += (_rw == "" ? "" : " ") + string(_face.value) + string_upper(string_char_at(_face.color, 1));
    }
    repeat (_def.reward.gather) {
        if (array_length(_g.decks.gather) == 0 && array_length(_g.decks.gatherDiscard) > 0) {
            _g.decks.gather = _g.decks.gatherDiscard;
            _g.decks.gatherDiscard = [];
            deck_shuffle(_g.decks.gather);
        }
        if (array_length(_g.decks.gather) > 0) {
            array_push(_g.players[_p].hand, array_pop(_g.decks.gather));
            _rw += (_rw == "" ? "" : " ") + "G";
        }
    }
    game_log(_g, _def.name + " is defeated by P" + string(_p + 1) + (_rw == "" ? "!" : "! Reward: " + _rw));
    // death abilities - matched on the ability text so every set's variants work
    if (_f.enemy.enemyDefId == "bulbmin") {
        var _got = game_grant_pikmin(_g, _p, "bulbmin", 5, { kind: "space", lane: _f.lane, idx: _f.idx });
        game_log(_g, "The Bulbmin's " + string(_got) + " young join P" + string(_p + 1) + "!");
    } else if (_def.ability != "") {
        var _ab = string_lower(_def.ability);
        var _handled = false;
        // "Creates a <Hazard> when it dies" (the whole dweevil family) - find the
        // named hazard in the hazard defs and drop it on the space
        if (string_pos("when it dies", _ab) > 0 && string_pos("creates", _ab) > 0) {
            var _hz = global.hazardData.hazards;
            for (var _hi = 0; _hi < array_length(_hz); _hi++) {
                if (string_pos(string_lower(_hz[_hi].name), _ab) > 0) {
                    game_ability_drop_hazard(_g, _f, _hz[_hi].id);
                    _handled = true;
                    break;
                }
            }
        }
        // "Each player places N free hazards when it dies" (Titan Dweevil / Plasm
        // Wraith / Ancient Sirehound): queue the placements, killer first. The
        // controllers resolve the queue interactively before normal play resumes.
        if (string_pos("each player places", _ab) > 0 && string_pos("free hazard", _ab) > 0) {
            if (array_length(_g.boardDef.structures.emitters) > 0) {
                var _nFree = max(1, real(string_digits(_ab)));
                array_push(_g.pendingFree, { playerIdx: _p, count: _nFree });
                array_push(_g.pendingFree, { playerIdx: 1 - _p, count: _nFree });
                game_log(_g, "Bounty: each player places " + string(_nFree) + " free hazard(s) - killer first!");
            }
            _handled = true;
        }
        // requirement gates and attack-time effects resolve during combat, not here
        if (string_pos("must be attacked", _ab) > 0 || string_pos("attacked this turn", _ab) > 0
            || string_pos("move boss and treasure back", _ab) > 0
            || _f.enemy.enemyDefId == "volatiledweevil") _handled = true;
        if (!_handled) game_log(_g, "(Ability not yet implemented: " + _def.ability + ")");
    }
    if (_f.isBoss) game_log(_g, "The treasure pile below is free to carry!");
    game_clear_enemy(_g, _f);
}

/// _attackOnly: the spray's bonus strike - pikmin deal damage (and still suffer
/// suicide-defence losses) but the enemy gives no response of any kind.
/// _phase: "all" = the whole combat in one tick (spicy bonus pass, legacy callers);
/// staged beats split it - "pik" (collect + swift + pikmin damage + structures),
/// "enemy" (retaliation + explosive splash, on the SAME fights list persisted via
/// _g.combatFights so crush-in-death still works), "post" (red second strike).
function game_combat_step(_g, _p, _sprayedOnly = false, _attackOnly = false, _phase = "all") {
    // collect engagements: lane enemies + bosses with the active player's pikmin present
    var _fights;
    if (_phase == "all" || _phase == "swift") {
        _fights = [];
        for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
            var _spaces = _g.board.lanes[_laneIdx].spaces;
            for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
                var _enemy = _spaces[_spaceIdx].enemy;
                if (_enemy == undefined) continue;
                _enemy.attacked = false;
                if (_sprayedOnly && !game_has_own_spray(_g, _p, _laneIdx, _spaceIdx)) continue;
                if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _laneIdx, idx: _spaceIdx })) > 0) {
                    array_push(_fights, { enemy: _enemy, lane: _laneIdx, idx: _spaceIdx, isBoss: false, hostT: undefined });
                }
            }
        }
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            var _t = _g.treasures[_ti];
            if (_t.boss == undefined) continue;
            _t.boss.attacked = false;
            if (_sprayedOnly && !game_has_own_spray(_g, _p, _t.lane, _t.idx)) continue;
            if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _t.lane, idx: _t.idx })) > 0) {
                array_push(_fights, { enemy: _t.boss, lane: _t.lane, idx: _t.idx, isBoss: true, hostT: _t });
            }
        }
        if (_phase == "swift") _g.combatFights = _fights;
    } else {
        _fights = (_g.combatFights != undefined) ? _g.combatFights : [];
    }

    // PASS 0 - SWIFT: speed enemies strike before any pikmin damage lands
    if (!_attackOnly && (_phase == "all" || _phase == "swift")) {
        for (var _fi = 0; _fi < array_length(_fights); _fi++) {
            var _f = _fights[_fi];
            if (_f.enemy.dead) continue;
            if (game_enemy_def_eff(_g, _f.enemy.enemyDefId).attackElement == "swift") game_enemy_attack(_g, _p, _f);
        }
    }

    // PASS A - PIKMIN DAMAGE: every engagement's damage resolves before any
    // (non-swift) enemy responds, so explosions can't pre-empt a neighbour's attack
    if (_phase == "all" || _phase == "pik")
    for (var _fi = 0; _fi < array_length(_fights); _fi++) {
        var _f = _fights[_fi];
        if (_f.enemy.dead) continue;
        var _def = game_enemy_def_eff(_g, _f.enemy.enemyDefId);   // adventure event overrides

        // eligible attackers (crush/height defence gates who can hurt it at all;
        // frozen pikmin don't act at all)
        var _attackersAll = game_tokens_at(_g, _p, { kind: "space", lane: _f.lane, idx: _f.idx });
        var _attackers = [];
        for (var _a = 0; _a < array_length(_attackersAll); _a++) {
            if (!token_is_disabled(_attackersAll[_a])) array_push(_attackers, _attackersAll[_a]);
        }

        // ICE FREEZE-SWARM: with ice pikmin >= ceil(remaining hp / 2) on it, that
        // quota of ice FREEZES the enemy instead of damaging (it skips its turn);
        // ice above the quota fight normally. No double-freezing.
        var _iceQuota = 0;
        var _iceCount = 0;
        for (var _a = 0; _a < array_length(_attackers); _a++) {
            if (_attackers[_a].typeId == "ice") _iceCount += 1;
        }
        var _alreadyStunned = variable_struct_exists(_f.enemy, "stunned") && _f.enemy.stunned > 0;
        if (_iceCount > 0 && !_alreadyStunned && global.expRules.iceFreeze) {
            var _need = ceil(_f.enemy.curHp / 2);
            if (_iceCount >= _need) {
                _iceQuota = _need;
                // freeze takes hold AFTER this combat: the enemy still retaliates now, then
                // skips its NEXT action (stunned is applied at the end of the enemy pass below)
                _f.enemy.iceFreezeNext = true;
                game_log(_g, string(_need) + " ice pikmin freeze " + _def.name + " solid - it'll skip its next turn!");
            }
        }

        var _dmg = 0;
        var _blockedGate = false;
        var _iceUsed = 0;
        for (var _a = 0; _a < array_length(_attackers); _a++) {
            if (_attackers[_a].typeId == "ice" && _iceUsed < _iceQuota) { _iceUsed += 1; continue; } // froze instead
            var _typeDef = pikmin_type_get(_attackers[_a].typeId);
            if (_def.defenseElement == "crush" && !arr_has(_typeDef.immunities, "crush")) { _blockedGate = true; continue; }
            if (_def.defenseElement == "height" && !(!game_no_imm(_g) && arr_has(_typeDef.immunities, "height"))) { _blockedGate = true; continue; }
            _dmg += _typeDef.carry;
        }
        // "Must be attacked by at least N <type>" (Waterwraith's purple, rock
        // requirements, Vehemoth's 3 yellows): without the quota nothing lands,
        // but with it met the whole group's strength counts
        var _req = game_attack_requirement(_def);
        if (_req != undefined) {
            var _reqHave = 0;
            for (var _a = 0; _a < array_length(_attackers); _a++) {
                if (_attackers[_a].typeId == _req.typeId) _reqHave += 1;
            }
            if (_reqHave >= _req.count) {
                _dmg = 0;
                _iceUsed = 0;
                for (var _a = 0; _a < array_length(_attackers); _a++) {
                    if (_attackers[_a].typeId == "ice" && _iceUsed < _iceQuota) { _iceUsed += 1; continue; }
                    _dmg += pikmin_type_get(_attackers[_a].typeId).carry;
                }
                _blockedGate = false;
            } else {
                _dmg = 0;
                _blockedGate = true;
            }
        }
        if (_dmg > 0 && _def.attackElement == "crush") {
            // CRUSH: the beast deals its damage regardless of dying, and the flavour is
            // that BOTH hits land at the instant it slams down. So don't apply the pikmin
            // damage here at the leap's apex - stash it for PASS B, where it lands on the
            // same beat as the crush kill (and the beast's death, if this finishes it).
            _f.crushPikDmg = _dmg;
            _f.crushAttackers = array_length(_attackers);
        } else if (_dmg > 0) {
            _f.enemy.curHp -= _dmg;
            // with anims on, the cling-scene plays ONE continuous attack loop (Draw), so skip
            // these discrete swipes to avoid doubling; anims-off still needs the punctuation
            if (!global.expRules.anims) repeat (min(array_length(_attackers), 3)) game_sfx(_g, "sfxPikAttack"); // only on a real hit; a few offset for a swarm
            game_log(_g, "P" + string(_p + 1) + "'s pikmin hit " + _def.name + " for " + string(_dmg) + " (" + string(max(0, _f.enemy.curHp)) + " hp left).");
        } else if (_blockedGate) {
            if (_req != undefined) game_log(_g, _def.name + " shrugs off the attack (needs at least " + string(_req.count) + " " + _req.typeId + ")!");
            else game_log(_g, _def.name + " shrugs off the attack (" + _def.defenseElement + " defence).");
        }

        // suicidal defence elements: only the pikmin that actually STRIKE die - and the
        // group commits just enough carry to kill it, so at most the enemy's pre-hit HP
        // worth of pikmin are exposed. Immune bodies strike for FREE (sent in first), sparing
        // the rest; extras beyond the lethal count hang back untouched. (Hazards/emitters are
        // different - you're standing IN them - so those still melt everyone; see below.)
        if (_def.defenseElement != "" && _def.defenseElement != "crush" && _def.defenseElement != "height") {
            var _preHp = _f.enemy.curHp + _dmg;   // HP before this beat's damage was applied above
            // immune strikers cover part of the kill for free; non-immune strikers (in order)
            // are exposed and die only until the remaining HP is covered.
            var _immCover = 0;
            var _exposed = [];
            var _iceSkip = _iceUsed;              // ice that froze instead of striking aren't exposed
            for (var _a = 0; _a < array_length(_attackers); _a++) {
                var _atk = _attackers[_a];
                if (_atk.typeId == "ice" && _iceSkip > 0) { _iceSkip -= 1; continue; }
                var _atd = pikmin_type_get(_atk.typeId);
                if (!game_no_imm(_g) && arr_has(_atd.immunities, _def.defenseElement)) _immCover += _atd.carry;
                else array_push(_exposed, _atk);
            }
            var _need = _preHp - _immCover;       // carry the exposed strikers must still cover
            var _lostWhites = 0;
            var _lost = 0;
            var _acc = 0;
            for (var _e = 0; _e < array_length(_exposed) && _acc < _need; _e++) {
                var _kt = _exposed[_e];
                _acc += pikmin_type_get(_kt.typeId).carry;
                if (_kt.typeId == "white") _lostWhites += 1;
                game_fx_pik(_g, _kt, _f.lane, _f.idx);
                var _toks2 = _g.players[_p].tokens;
                for (var _ti = 0; _ti < array_length(_toks2); _ti++) {
                    if (_toks2[_ti] == _kt) { array_delete(_toks2, _ti, 1); break; }
                }
                _lost += 1;
            }
            if (_lost > 0) game_log(_g, string(_lost) + " pikmin perish to " + _def.name + "'s " + _def.defenseElement + " defence!");
            if (_lostWhites > 0 && _f.enemy.curHp > 0) {
                _f.enemy.curHp -= _lostWhites;
                game_log(_g, "Dying whites poison it for " + string(_lostWhites) + "!");
            }
        }

        // crush enemies defer their death to PASS B so it lands with the slam (see above)
        if (_def.attackElement != "crush" && _f.enemy.curHp <= 0) game_enemy_die(_g, _p, _f); // rewards immediately, per the rules
    }

    // PASS B - ENEMY DAMAGE: all surviving enemies strike simultaneously (crush
    // enemies strike even while dying). Explosions land here, alongside everything
    // else - AFTER every pikmin group has already dealt its damage.
    if (!_attackOnly && (_phase == "all" || _phase == "enemy")) {
        for (var _fi = 0; _fi < array_length(_fights); _fi++) {
            var _f = _fights[_fi];
            if (_f.enemy.attacked) continue; // swift already struck
            var _def = game_enemy_def_eff(_g, _f.enemy.enemyDefId);   // adventure event overrides
            if (_def.attackElement == "crush") {
                // THE SLAM: the pikmin's stashed damage and the crush kill land together on
                // this one beat, so the beast and the pikmin visibly take their hits at the
                // same instant. The beast crushes even if this damage is what finishes it.
                if (variable_struct_exists(_f, "crushPikDmg") && _f.crushPikDmg > 0 && !_f.enemy.dead) {
                    _f.enemy.curHp -= _f.crushPikDmg;
                    if (!global.expRules.anims) repeat (min(_f.crushAttackers, 3)) game_sfx(_g, "sfxPikAttack");
                    game_log(_g, "P" + string(_p + 1) + "'s pikmin hit " + _def.name + " for " + string(_f.crushPikDmg) + " (" + string(max(0, _f.enemy.curHp)) + " hp left).");
                }
                game_enemy_attack(_g, _p, _f);                              // crushes even in death (sound handled inside, gated on hits)
                if (!_f.enemy.dead && _f.enemy.curHp <= 0) game_enemy_die(_g, _p, _f); // now the deferred death lands, with the slam
            } else if (!_f.enemy.dead) game_enemy_attack(_g, _p, _f);
        }
        // ice freeze now takes hold: iced enemies retaliated above, and are now frozen so they
        // skip their NEXT action (rendered light-blue meanwhile)
        for (var _fi = 0; _fi < array_length(_fights); _fi++) {
            var _f = _fights[_fi];
            if (!_f.enemy.dead && variable_struct_exists(_f.enemy, "iceFreezeNext") && _f.enemy.iceFreezeNext) {
                _f.enemy.stunned = 1;
                _f.enemy.stunnedBy = "ice";
                _f.enemy.iceFreezeNext = false;
                game_sfx(_g, "sfxFreeze");
            }
        }
    }

    // PASS C - RED SECOND STRIKE (experimental): after the enemy turn, red pikmin
    // attack once more (their "more damage" identity). Reds still alive on the space
    // are, by construction, ones the enemy couldn't melt - so no re-gating for
    // suicide defence is needed; crush/height/attack-requirement gates still apply.
    if (!_attackOnly && global.expRules.red && (_phase == "all" || _phase == "post")) {
        for (var _fi = 0; _fi < array_length(_fights); _fi++) {
            var _f = _fights[_fi];
            if (_f.enemy.dead) continue;
            var _def = game_enemy_def_eff(_g, _f.enemy.enemyDefId);   // adventure event overrides (red strike)
            if (_def.defenseElement == "crush" || _def.defenseElement == "height") continue; // reds can't hurt it
            if (game_attack_requirement(_def) != undefined) continue; // reds alone never satisfy these
            var _redDmg = 0;
            var _redToks = game_tokens_at(_g, _p, { kind: "space", lane: _f.lane, idx: _f.idx });
            for (var _a = 0; _a < array_length(_redToks); _a++) {
                if (_redToks[_a].typeId == "red" && !token_is_disabled(_redToks[_a])) _redDmg += pikmin_type_get("red").carry;
            }
            if (_redDmg <= 0) continue;
            _f.enemy.curHp -= _redDmg;
            game_log(_g, "P" + string(_p + 1) + "'s reds strike again for " + string(_redDmg) + " (" + string(max(0, _f.enemy.curHp)) + " hp left)!");
            if (_f.enemy.curHp <= 0) game_enemy_die(_g, _p, _f);
        }
    }

    // structures: pikmin on walls/emitters chew through them like 0-damage enemies.
    // Emitters carry a defensive element - non-immune attackers die after striking.
    if (_phase == "all" || _phase == "pik")
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _struct = _spaces[_spaceIdx].structure;
            if (_struct == undefined) continue;
            // a hazard dropped by an enemy dying THIS turn is untouchable until next turn
            if (variable_struct_exists(_struct, "fresh") && _struct.fresh) continue;
            var _sDef = hazard_def_get(_struct.structId);
            if (_sDef.type == "bridge") continue;
            if (_sprayedOnly && !game_has_own_spray(_g, _p, _laneIdx, _spaceIdx)) continue;
            // wall variants gate who can damage them (webbed vs winged, crystal = rock only, etc.)
            var _toksHere = game_tokens_at(_g, _p, { kind: "space", lane: _laneIdx, idx: _spaceIdx });
            var _str = 0;
            var _gated = false;
            for (var _a = 0; _a < array_length(_toksHere); _a++) {
                if (token_is_disabled(_toksHere[_a])) continue;
                if (!struct_type_can_damage(_toksHere[_a].typeId, _struct.structId)) { _gated = true; continue; }
                _str += pikmin_type_get(_toksHere[_a].typeId).carry;
            }
            if (_str <= 0) {
                if (_gated) { game_sfx(_g, "sfxStructureNoDamage"); game_log(_g, "The " + _sDef.name + " shrugs off P" + string(_p + 1) + "'s pikmin - wrong type to destroy it."); }
                continue;
            }
            _struct.curHp -= _str;
            if (_struct.curHp <= 0) {
                _spaces[_spaceIdx].structure = undefined;
                // the heavy destruction SFX suits WALLS only; an emitter breaking is just the final whack
                // (with anims on, the Draw-side repeated whacks cover the emitter's final hit)
                if (_sDef.type == "wall") game_sfx(_g, "sfxDestroyStructure");
                else if (!global.expRules.anims) repeat (min(array_length(_toksHere), 3)) game_sfx(_g, "sfxPikAttack");
                game_log(_g, "P" + string(_p + 1) + "'s pikmin tear down the " + _sDef.name + "!");
            } else {
                // pikmin whacking it (not destroyed) - anims-on plays these as randomised swipes in Draw
                if (!global.expRules.anims) repeat (min(array_length(_toksHere), 3)) game_sfx(_g, "sfxPikAttack");
                game_log(_g, "P" + string(_p + 1) + "'s pikmin damage the " + _sDef.name + " (" + string(_struct.curHp) + " hp left).");
            }
            // emitter's element kills the non-immune attackers (they still dealt damage)
            if (_sDef.type == "hazard" && _sDef.element != "") {
                var _lost = 0;
                var _tokens = _g.players[_p].tokens;
                var _ti = 0;
                while (_ti < array_length(_tokens)) {
                    var _tok = _tokens[_ti];
                    var _td = pikmin_type_get(_tok.typeId);
                    if (game_loc_eq(_tok.loc, { kind: "space", lane: _laneIdx, idx: _spaceIdx })
                        && !(!game_no_imm(_g) && arr_has(_td.immunities, _sDef.element))
                        && !arr_has(_td.traits, "flies_over_hazards")) {
                        game_fx_pik(_g, _tok, _laneIdx, _spaceIdx); // release a spirit, like enemy suicide-defence
                        array_delete(_tokens, _ti, 1);
                        _lost += 1;
                        continue;
                    }
                    _ti += 1;
                }
                if (_lost > 0) game_log(_g, string(_lost) + " of P" + string(_p + 1) + "'s pikmin perish to the " + _sDef.name + "'s " + _sDef.element + "!");
            }
        }
    }

    // explosive enemies strike anything in reach even when not engaged directly
    if (_sprayedOnly || _attackOnly || (_phase != "all" && _phase != "enemy")) return;
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _enemy = _spaces[_spaceIdx].enemy;
            if (_enemy == undefined || _enemy.dead || _enemy.attacked) continue;
            var _def = game_enemy_def_eff(_g, _enemy.enemyDefId);   // adventure event overrides (explosive splash)
            if (_def.attackElement != "explosive") continue;
            var _inRange = false;
            var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
            for (var _o = 0; _o < array_length(_offsets) && !_inRange; _o++) {
                var _bl = _laneIdx + _offsets[_o][0];
                var _bi = _spaceIdx + _offsets[_o][1];
                if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi >= array_length(_g.board.lanes[_bl].spaces)) continue;
                if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _bl, idx: _bi })) > 0) _inRange = true;
            }
            if (_inRange) game_enemy_attack(_g, _p, { enemy: _enemy, lane: _laneIdx, idx: _spaceIdx, isBoss: false, hostT: undefined });
        }
    }
    // explosive BOSSES splash too (e.g. Man-at-Legs on a treasure pile)
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (_t.boss == undefined || _t.boss.dead || _t.boss.attacked) continue;
        var _def = game_enemy_def_eff(_g, _t.boss.enemyDefId);   // adventure event overrides (boss explosive splash)
        if (_def.attackElement != "explosive") continue;
        var _inRange = false;
        var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
        for (var _o = 0; _o < array_length(_offsets) && !_inRange; _o++) {
            var _bl = _t.lane + _offsets[_o][0];
            var _bi = _t.idx + _offsets[_o][1];
            if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi >= array_length(_g.board.lanes[_bl].spaces)) continue;
            if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _bl, idx: _bi })) > 0) _inRange = true;
        }
        if (_inRange) game_enemy_attack(_g, _p, { enemy: _t.boss, lane: _t.lane, idx: _t.idx, isBoss: true, hostT: _t });
    }
}

// ---------- end of turn / day / game ----------

function game_end_turn(_g) {
    game_pop_snapshot(_g, "Combat");   // population after this turn's move/combat resolved
    var _pl = _g.players[_g.activePlayer];
    _pl.turnsTaken += 1;
    // Giant Breadbug drags its displaced pile back toward the centre every turn
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _bt = _g.treasures[_ti];
        if (_bt.boss == undefined || _bt.boss.dead) continue;
        if (string_pos("move boss and treasure back", string_lower(enemy_def_get(_bt.boss.enemyDefId).ability)) > 0) {
            game_breadbug_drag(_g, _bt);
        }
    }
    // structure upkeep: newly-dropped hazards become attackable next turn, and
    // poison emitters decay on their own ("It loses one health every turn.")
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            var _struct = _spaces[_spaceIdx].structure;
            if (_struct == undefined) continue;
            if (variable_struct_exists(_struct, "fresh")) _struct.fresh = false;
            if (_struct.structId != "poisonemitter") continue;
            _struct.curHp -= 1;
            if (_struct.curHp <= 0) {
                _spaces[_spaceIdx].structure = undefined;
                game_log(_g, "The Poison Emitter in lane " + string(_laneIdx + 1) + " sputters out.");
            }
        }
    }
    // refill claimed treasure spaces - a lane should never sit empty
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _trIdx = game_lane_treasure_idx(_g, _laneIdx);   // boards vary in length - not always idx 3
        if (_trIdx < 0) continue;
        var _laneHasTreasure = false;
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            if (_g.treasures[_ti].lane == _laneIdx) { _laneHasTreasure = true; break; }
        }
        if (_laneHasTreasure) continue;
        if (array_length(_g.decks.treasure) == 0) { game_log(_g, "The treasure deck is exhausted - lane " + string(_laneIdx + 1) + " stays bare."); continue; }
        var _pile = [];
        var _pileVal = 0;
        while (_pileVal < global.rules.treasurePileMinValue && array_length(_g.decks.treasure) > 0) {
            var _cardId = array_pop(_g.decks.treasure);
            array_push(_pile, _cardId);
            _pileVal += treasure_def_get(_cardId).value;
        }
        array_push(_g.treasures, { cards: _pile, lane: _laneIdx, idx: _trIdx, boss: undefined });
        game_log(_g, "A new treasure pile surfaces in lane " + string(_laneIdx + 1) + " (" + string(_pileVal) + "p).");
    }
    // hand limit: the OWNER chooses what to toss (tabletop rule). The turn is
    // otherwise over - the handoff waits on pendingDiscard (human picker in the
    // HUD, AI via ai_resolve_discard), then game_discard_choice finishes it.
    var _over = array_length(_pl.hand) + array_length(_pl.pellets) - global.rules.handLimit;
    if (_over > 0) {
        _g.pendingDiscard = { playerIdx: _g.activePlayer, need: _over };
        game_log(_g, "P" + string(_g.activePlayer + 1) + " is over the hand limit - must discard " + string(_over) + ".");
        return;
    }
    game_end_turn_finish(_g);
}

/// The deferred tail of game_end_turn: hand the turn over (runs immediately when
/// the hand fits, or once the owner has discarded down to the limit).
function game_end_turn_finish(_g) {
    // solo mode (tutorial / adventure): no opposing seat, so each of the lone player's turns is a
    // full round - advance the day track (rollover spawns enemies / ends the game) but never flip seats.
    if (variable_struct_exists(_g, "solo") && _g.solo) {
        game_advance_day(_g);
        if (_g.phase != "gameover") game_begin_turn(_g);
        return;
    }
    _g.activePlayer = 1 - _g.activePlayer;
    if (_g.activePlayer == _g.firstPlayer) game_advance_day(_g);
    if (_g.phase != "gameover") game_begin_turn(_g);
}

/// Resolve ONE hand-limit discard chosen by the owner: _kind "pellet" (idx into
/// pellets) or "gather" (idx into hand). Finishes the deferred turn handoff once
/// the hand fits again. Returns whether a discard happened.
function game_discard_choice(_g, _kind, _idx) {
    if (_g.pendingDiscard == undefined) return false;
    var _p = _g.pendingDiscard.playerIdx;
    var _pl = _g.players[_p];
    if (_kind == "pellet") {
        if (_idx < 0 || _idx >= array_length(_pl.pellets)) return false;
        array_delete(_pl.pellets, _idx, 1);
        game_log(_g, "P" + string(_p + 1) + " discards a pellet (hand limit).");
    } else {
        if (_idx < 0 || _idx >= array_length(_pl.hand)) return false;
        var _discardId = _pl.hand[_idx];
        array_delete(_pl.hand, _idx, 1);
        array_push(_g.decks.gatherDiscard, _discardId);
        game_log(_g, "P" + string(_p + 1) + " discards " + chr(2) + gather_def_get(_discardId).name + chr(2) + " (hand limit).");
    }
    var _over = array_length(_pl.hand) + array_length(_pl.pellets) - global.rules.handLimit;
    if (_over <= 0) {
        _g.pendingDiscard = undefined;
        game_end_turn_finish(_g);
    } else {
        _g.pendingDiscard.need = _over;
    }
    return true;
}

function game_advance_day(_g) {
    // ADVENTURE runs share a day budget across all their boards, passed in as _g.dayLimit;
    // a normal versus match uses the global rule. When the budget is spent the board ends
    // (the controller reads it as a run FAIL - out of days before clearing the board).
    // day count: adventure's shared budget (dayLimit) wins; else the board's day-track days (2 in
    // 2-day mode, 3 normally); else the global rule. Keeps 2-day maps ending after day 2.
    var _dayLimit = variable_struct_exists(_g, "dayLimit") ? _g.dayLimit
                  : (variable_struct_exists(_g, "dayTrackDef") ? _g.dayTrackDef.days : global.rules.days);
    _g.dayTrack += 1;
    // final day's final turn is about to begin: sound the alarm, once
    if (_g.dayNumber == _dayLimit && _g.dayTrack == _g.dayTrackLength) game_sfx(_g, "sfxTimeAlert");
    if (_g.dayTrack <= _g.dayTrackLength) return;
    _g.dayTrack = 1;
    _g.dayNumber += 1;
    if (_g.dayNumber > _dayLimit) {
        // the game ends as day 4 would begin - but let the board SETTLE first (last
        // pile hauls home, pikmin still). The winner + final score are computed in
        // game_finalize_gameover, called by the controller once motion stops.
        _g.phase = "gameover";
        game_log(_g, "The final whistle blows as the last day closes...");
        return;
    }
    // sunset: pikmin fly home; new enemies spawn. Survivors stay HURT by default -
    // healing between days is an optional difficulty setting (global.expRules.enemyHeal).
    for (var _p = 0; _p < 2; _p++) {
        var _tokens = _g.players[_p].tokens;
        for (var _i = 0; _i < array_length(_tokens); _i++) _tokens[_i].loc = { kind: "home" };
    }
    if (global.expRules.enemyHeal) {
        for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
            var _spaces = _g.board.lanes[_laneIdx].spaces;
            for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
                var _enemy = _spaces[_spaceIdx].enemy;
                if (_enemy != undefined) _enemy.curHp = enemy_def_get(_enemy.enemyDefId).hp;
            }
        }
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            var _boss = _g.treasures[_ti].boss;
            if (_boss != undefined) _boss.curHp = enemy_def_get(_boss.enemyDefId).hp;
        }
    }
    if (game_day_day_spawns(_g)) game_fill_enemy_spaces(_g, true); // SPAWN day-event: flag fresh arrivals for the cinematic (POD boards stay bare)
}

// ========================= DAY-TRACK STEP EVENTS (GROUNDWORK 2026-08-01) =========================
// New day system (Zak + user): each board's day tracker is a series of SPACES, each carrying a step
// event that fires at the start of a turn when the marker sits on it. A board has either a 5-space /
// 3-day track or a 7-space / 2-day track (both defined in the .xlsx "Board Layouts" boards area).
// Data model (board def / _g): dayTrack = { days, spaces:[ {ev, ...} x N ] }. Event `ev`:
//   "spawn"  refill all enemy spaces + bosses (the current behaviour)
//   "pod"    {n}         fill N enemy spaces on YOUR OWN side (no bosses; bosses shuffled back)
//   "storm"              place an available hazard on YOUR OWN side
//   "roll" / "draw"      free pellet roll / gather draw before the turn
//   "raw"                building costs only 1 raw material THIS turn        (flag)
//   "pellet"             pellets give +1 pikmin THIS turn                    (flag)
//   "flarlic"            +5 pikmin cap for the REST of the match            (persistent)
//   "swap"   {from,to,all}  swap one (or all) `from`-type space(s) to `to` on YOUR OWN side
//   "none"               a regular turn
// DESIGN (user 2026-08-01): the placement events (pod/storm/swap) all mess with the ACTING PLAYER'S
// OWN board, and the player should DECIDE WHERE - reuse the boss-bounty `pendingFree` placement flow
// (a pending choice the human/AI resolves) rather than the auto-placement stubbed below.
// STATUS: dispatch + helpers below reuse the treasure-power helpers; auto-place for now; NOT yet hooked.
// STILL TODO: (1) extract per-board dayTrackDef data from the .xlsx (2 rows/board, cols=spaces, SWAP as
// "FROM\nTO"); (2) call game_day_space_apply at turn start off _g.dayTrackDef.spaces[dayTrack-1] (dayTrack
// = the within-day counter); (3) make the
// 5/7-space length drive dayTrackLength + days; (4) WIRE the raw/pellet/flarlic flags into the build-
// cost, pellet->pikmin, and pikmin-cap checks; (5) the 3 revised layouts (Flooded Garden / Frigid
// Wasteland / Minefield) now lean on these events. (POD/STORM/SWAP all target the acting player's own
// side, resolved 2026-08-01 - the .xlsx legend's "opponent's side" wording is superseded.)

/// Default track: 5 spaces / 3 days, SPAWN on space 1, rest regular - reproduces today's behaviour.
function game_day_track_default() {
    return { days: global.rules.days, spaces: [ {ev:"spawn"}, {ev:"none"}, {ev:"none"}, {ev:"none"}, {ev:"none"} ] };
}

/// The real per-board day tracker (from datafiles/data/daytracks.json, keyed by set number).
/// _twoDay picks the 7-space / 2-day variant; default is the 5-space / 3-day one. Boards without
/// a set number (tutorial, random) or a data entry fall back to the default track above.
function game_day_track_for_board(_boardDef, _twoDay = false) {
    if (!variable_struct_exists(global, "dayTrackData") || !variable_struct_exists(_boardDef, "setNumber")) return game_day_track_default();
    var _key = string(_boardDef.setNumber);
    var _all = global.dayTrackData.tracks;
    if (!variable_struct_exists(_all, _key)) return game_day_track_default();
    var _spaces = _twoDay ? _all[$ _key].twoDay : _all[$ _key].threeDay;
    return { days: (_twoDay ? 2 : 3), spaces: _spaces };
}

/// Does the current day OPEN on a SPAWN segment? SPAWN is a day-level, board-wide event
/// (all boards put it on space 1, or not at all - POD-driven boards like The Burrow start
/// bare). Drives the setup + day-rollover fill; boards without it populate via POD instead.
function game_day_day_spawns(_g) {
    if (!variable_struct_exists(_g, "dayTrackDef")) return true;   // legacy safety: spawn as before
    var _spaces = _g.dayTrackDef.spaces;
    return (array_length(_spaces) > 0 && _spaces[0].ev == "spawn");
}

/// Fire the current day-track SEGMENT's event. Called from game_begin_turn at the start of
/// every turn. _phaseStart is true only for the round's FIRST player (a new segment just
/// began) - the AUTOMATIC/global events (SWAP ALL) fire then, exactly once. PLAYER-DRIVEN
/// events (own-tile swap, pod, roll, draw) fire for the acting player on each of their turns;
/// the PASSIVE flags (raw/pellet/flarlic) set each turn the marker sits on the segment.
/// SPAWN is day-level and handled at the rollover (game_day_day_spawns), not here.
function game_day_track_fire(_g, _phaseStart) {
    if (!variable_struct_exists(_g, "dayTrackDef")) return;
    var _spaces = _g.dayTrackDef.spaces;
    if (array_length(_spaces) == 0) return;
    var _p = _g.activePlayer;
    var _ev = _spaces[clamp(_g.dayTrack, 1, array_length(_spaces)) - 1];
    switch (_ev.ev) {
        case "spawn": if (_phaseStart) game_log(_g, "Day event: SPAWN - enemies fill the board."); break; // the fill itself is done at the rollover

        case "swap":
            if (variable_struct_exists(_ev, "all") && _ev.all) {
                // AUTOMATIC: every matching tile flips on BOTH sides, once, at the segment's start
                if (_phaseStart) {
                    game_day_swap(_g, 0, _ev.from, _ev.to, true);
                    game_day_swap(_g, 1, _ev.from, _ev.to, true);
                    game_log(_g, "Day event: every " + string_upper(_ev.from) + " space becomes " + string_upper(_ev.to) + "!");
                }
            } else {
                // PLAYER-DRIVEN: the acting player picks WHICH of their own from-type tiles to
                // flip. Queue the choice (human picks via the targeter; AI/sim auto-resolve).
                // Skip silently if they have none of that type on their side.
                _g.pendingDaySwap = { playerIdx: _p, from: _ev.from, to: _ev.to };
                if (!game_day_swap_any_target(_g)) _g.pendingDaySwap = undefined;
                else if (variable_struct_exists(global.expRules, "randomSwaps") && global.expRules.randomSwaps) {
                    game_log(_g, "Chaos Swaps (P" + string(_p + 1) + "): a RANDOM " + string_upper(_ev.from) + " space warps to " + string_upper(_ev.to) + "!");
                    game_day_swap_random(_g);   // resolve now on a random legal tile - no choice for human or AI
                } else game_log(_g, "Day event (P" + string(_p + 1) + "): choose a " + string_upper(_ev.from) + " space to swap to " + string_upper(_ev.to) + ".");
            }
            break;

        case "pod":
            // PLAYER-DRIVEN: place N enemies ANYWHERE (empty enemy spaces). Human picks the
            // spaces via the targeter; AI/sim auto-resolve. Skip if no legal space at all.
            _g.pendingDayPlace = { playerIdx: _p, kind: "pod", count: _ev.n };
            if (!game_day_place_any_target(_g)) _g.pendingDayPlace = undefined;
            else game_log(_g, "Day event (P" + string(_p + 1) + "): place " + string(_ev.n) + " POD enemies.");
            break;

        case "storm":
            // PLAYER-DRIVEN: drop a hazard on one of your OWN empty basic spaces (player's pick).
            _g.pendingDayPlace = { playerIdx: _p, kind: "storm", count: 1 };
            if (!game_day_place_any_target(_g)) _g.pendingDayPlace = undefined;
            else game_log(_g, "Day event (P" + string(_p + 1) + "): choose a space for your STORM hazard.");
            break;

        case "roll":    game_power_draw_pellet(_g, _p); game_log(_g, "Day event (P" + string(_p + 1) + "): a free pellet ROLL."); break;
        case "draw":    game_power_draw_gather(_g, _p); game_log(_g, "Day event (P" + string(_p + 1) + "): a free gather DRAW."); break;

        // PASSIVE (per-turn) modifiers
        case "raw":     _g.dayRawFree = true;     game_log(_g, "Day event (P" + string(_p + 1) + "): RAW - building costs 1 less Raw Material this turn."); break;
        case "pellet":  _g.dayPelletBonus = true; game_log(_g, "Day event (P" + string(_p + 1) + "): PELLET - pellets give +1 pikmin this turn."); break;
        case "flarlic": _g.players[_p].flarlicBonus += 5; game_log(_g, "Day event (P" + string(_p + 1) + "): FLARLIC - max pikmin +5."); break;
        case "none": default: break;
    }
}

// ===================== ADVENTURE EVENT CARDS =====================
// One random event is drawn at the START of each turn (game_begin_turn), replacing the standard
// day-track events (adventure blanks those). Effects auto-resolve for the solo campaign - anything
// "of your choice" picks a sensible target. Per-turn modifiers are reset each turn in _step.

/// Draw the next event from the pile (reshuffle the discard back in when empty). undefined = no deck.
function game_adv_event_next(_g) {
    if (array_length(_g.advEventPile) == 0) {
        _g.advEventPile = _g.advEventDiscard;
        _g.advEventDiscard = [];
        deck_shuffle(_g.advEventPile);
    }
    if (array_length(_g.advEventPile) == 0) return undefined;
    var _card = array_pop(_g.advEventPile);
    array_push(_g.advEventDiscard, _card);
    return _card;
}

/// Adventure turn start: reset per-turn modifiers, draw one event, run it. No-op elsewhere.
function game_adv_event_step(_g) {
    if (!variable_struct_exists(_g, "advEventPile")) return;
    _g.advForceAttack = ""; _g.advForceDefense = ""; _g.advEnemyDmgMult = 1;
    _g.advNoImmunities = false; _g.advNoPellets = false; _g.advTreasureHeavier = 0;
    _g.advSkipTurn = false;
    _g.eventPending = [];   // clear any stale leftover from a previous turn before drawing
    var _card = game_adv_event_next(_g);
    if (_card == undefined) return;
    var _cdesc = variable_struct_exists(_card, "desc") ? _card.desc : "";
    _g.eventPending = [ { name: _card.name, good: _card.good, desc: _cdesc } ];
    game_adv_event_pump(_g);
}

/// Apply queued event effects ONE AT A TIME: the next only fires once the current event's picker(s)
/// are fully resolved (no space/type/lose modal live). Picker resolutions call this again to continue,
/// so a Double Event's two effects (and any pickers they open) resolve strictly in sequence.
function game_adv_event_pump(_g) {
    if (!variable_struct_exists(_g, "eventPending")) return;
    while (array_length(_g.eventPending) > 0
        && _g.pendingEvent == undefined && _g.pendingTypePick == undefined
        && (!variable_struct_exists(_g, "pendingLose") || _g.pendingLose == undefined)) {
        var _e = _g.eventPending[0];
        array_delete(_g.eventPending, 0, 1);
        game_adv_event_apply(_g, _e.name, _e.good, variable_struct_exists(_e, "desc") ? _e.desc : "",
            variable_struct_exists(_e, "allowGood") ? _e.allowGood : true);
    }
}

/// Apply ONE event by name. _allowGood=false (a Double Event's extra draws) suppresses Good effects.
function game_adv_event_apply(_g, _name, _good, _desc, _allowGood) {
    var _p = _g.activePlayer;
    if (_good && !_allowGood) {
        // Double Event: a Good event's effect DOESN'T happen - still POP the toast (with a "nothing
        // happens" desc) so the draw is visible instead of looking dropped.
        array_push(_g.bankCues, { name: _name, effect: "Nothing happens (Double Event).", good: _good, outcome: undefined });
        game_log(_g, "EVENT: " + _name + " - nothing happens (Double Event).");
        return;
    }
    array_push(_g.bankCues, { name: _name, effect: _desc, good: _good, outcome: undefined });   // toast (name + description)
    game_log(_g, "EVENT: " + _name + " - " + _desc);
    switch (_name) {
        // economy / passive (this turn)
        case "Flower Frenzy":          game_power_draw_pellet(_g, _p); break;   // +1 pellet roll (free, immediate)
        case "Liquidation Sale":       game_power_draw_gather(_g, _p); break;   // +1 gather draw (free, immediate)
        case "Photosynthesis":         _g.dayPelletBonus = true; break;
        case "Hibernation":            _g.soothed = true; break;
        case "Weak Soil":              _g.advNoPellets = true; break;
        case "What's This Made Of?!?": _g.advTreasureHeavier = 3; break;
        case "Quick Feet":             _g.dayTrack = max(1, _g.dayTrack - 1); break;
        case "Status: Normal":         break;
        // enemy combat overrides (this turn)
        case "Swift Chompers":            _g.advForceAttack = "swift"; break;
        case "Heavy Hitters":             _g.advForceAttack = "crush"; break;
        case "Hot Headed!":               _g.advForceAttack = "explosive"; break;
        case "Jump, Fly, Climb, Attack!": _g.advForceDefense = "height"; break;
        case "Strong and Wild":           _g.advEnemyDmgMult = 2; break;
        case "Rebooting...":              _g.advNoImmunities = true; break;
        // lose pikmin: the PLAYER picks which (home reserves or field bodies), one per click
        case "Misplaced Troops":  game_lose_set_pending(_g, _p, 5); break;
        case "Sudden Explosion!": game_lose_set_pending(_g, _p, 10); break;
        // board edits: pick a space (the player's choice) - highlighted, same targeter as day POD/STORM
        case "Free Refills":           game_event_set_pending(_g, _p, "spicy", "", ""); break;
        case "Unsteady Construction":  game_event_set_pending(_g, _p, "killwall", "", ""); break;
        case "Sabotaged Construction": game_event_set_pending(_g, _p, "killbridge", "", ""); break;
        case "Faulty Wiring":          game_event_set_pending(_g, _p, "killemitter", "", ""); break;
        case "Reconstruction":         game_event_set_pending(_g, _p, "rerollwall", "", ""); break;
        case "Nap Time...":            // skip the turn (controller ends it) + take 2 pellets OF YOUR CHOICE
            _g.advSkipTurn = true;
            var _die = _g.boardDef.pelletDie; var _pop = [];
            for (var _f = 0; _f < array_length(_die); _f++) {
                if (variable_struct_exists(_die[_f], "blank") && _die[_f].blank) continue;
                var _pid = _die[_f].color + string(_die[_f].value);
                if (!arr_has(_pop, _pid)) array_push(_pop, _pid);
            }
            if (array_length(_pop) > 0) _g.pendingTypePick = { playerIdx: _p, purpose: "pellet", options: _pop, need: 2 };
            break;
        case "Reinforcements":                                                    // "Fill Nth row enemy spaces" -> lane N (1-5)
            var _rlane = -1;
            for (var _ci = 1; _ci <= string_length(_desc); _ci++) { var _rc = string_char_at(_desc, _ci); if (_rc >= "1" && _rc <= "9") { _rlane = real(_rc) - 1; break; } }
            game_adv_reinforce_lane(_g, _rlane);
            break;
        // soil: pick an empty space (in a treasure lane) to turn into a hazard / enemy
        case "Volcanic Soil": game_event_set_pending(_g, _p, "soil", "hazard", "fire");   break;
        case "Flooded Soil":  game_event_set_pending(_g, _p, "soil", "hazard", "water");  break;
        case "Shifting Soil": game_event_set_pending(_g, _p, "soil", "hazard", "height"); break;
        case "Fissured Soil": game_event_set_pending(_g, _p, "soil", "hazard", "chasm");  break;
        case "Infected Soil": game_event_set_pending(_g, _p, "soil", "hazard", "poison"); break;
        case "Frozen Soil":   game_event_set_pending(_g, _p, "soil", "hazard", "ice");    break;
        case "Hostile Soil":  game_event_set_pending(_g, _p, "soil", "enemy", "");        break;
        // meta: draw 2 more and queue them with allowGood=false, so a Good draw still POPS a toast
        // ("nothing happens") but has no effect, and Bad draws resolve normally. The pump runs them
        // one at a time after this, so their pickers never overlap.
        case "Double Event!":
            for (var _d = 0; _d < 2; _d++) {
                var _c2 = game_adv_event_next(_g);
                if (_c2 != undefined) array_insert(_g.eventPending, _d, { name: _c2.name, good: _c2.good,
                    desc: variable_struct_exists(_c2, "desc") ? _c2.desc : "", allowGood: false });
            }
            break;
        default: break;
    }
}

/// The enemy def as combat should see it THIS turn: the real def, or a shallow copy with the
/// active adventure event overrides (all-swift/crush/explosive, all-height-defence, 2x damage).
function game_enemy_def_eff(_g, _enemyDefId) {
    var _d = enemy_def_get(_enemyDefId);
    if (!variable_struct_exists(_g, "advForceAttack")) return _d;
    if (_g.advForceAttack == "" && _g.advForceDefense == "" && _g.advEnemyDmgMult == 1) return _d;
    var _c = {}; var _ns = variable_struct_get_names(_d);
    for (var _i = 0; _i < array_length(_ns); _i++) _c[$ _ns[_i]] = _d[$ _ns[_i]];
    if (_g.advForceAttack != "")   _c.attackElement = _g.advForceAttack;
    if (_g.advForceDefense != "")  _c.defenseElement = _g.advForceDefense;
    if (_g.advEnemyDmgMult != 1)   _c.damage = _d.damage * _g.advEnemyDmgMult;
    return _c;
}

/// Event helper (Reinforcements): fill EVERY bare enemy space in lane _lane from the enemy deck.
function game_adv_reinforce_lane(_g, _lane) {
    if (_lane < 0 || _lane >= _g.board.laneCount) return;
    var _sp = _g.board.lanes[_lane].spaces;
    var _n = 0;
    for (var _i = 0; _i < array_length(_sp); _i++)
        if (_sp[_i].kind == "enemy" && _sp[_i].enemy == undefined && game_spawn_enemy_at(_g, _lane, _i)) _n += 1;
    if (_n > 0) game_log(_g, "Reinforcements fill lane " + string(_lane + 1) + " (" + string(_n) + " enemies)!");
}

/// Event helper: lose up to _n pikmin - home reserves first (silent), then field bodies (with a soul).
function game_adv_lose_pikmin(_g, _p, _n) {
    var _toks = _g.players[_p].tokens;
    var _lost = 0; var _i = 0;
    while (_i < array_length(_toks) && _lost < _n) {
        if (_toks[_i].loc.kind == "home") { array_delete(_toks, _i, 1); _lost += 1; continue; }
        _i += 1;
    }
    _i = 0;
    while (_i < array_length(_toks) && _lost < _n) {
        var _tk = _toks[_i];
        if (_tk.loc.kind == "space") game_fx_pik(_g, _tk, _tk.loc.lane, _tk.loc.idx);
        array_delete(_toks, _i, 1); _lost += 1;
    }
    if (_lost > 0) game_log(_g, "Lost " + string(_lost) + " pikmin!");
}

/// Event helper: apply Ultra-Spicy to a space - prefer an enemy space where _p has pikmin.
function game_adv_spicy_a_space(_g, _p) {
    var _best = undefined;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].enemy == undefined) continue;
            if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _l, idx: _i })) > 0) {
                array_push(_g.sprays, { playerIdx: _p, lane: _l, idx: _i }); return;
            }
            if (_best == undefined) _best = { lane: _l, idx: _i };
        }
    }
    if (_best != undefined) array_push(_g.sprays, { playerIdx: _p, lane: _best.lane, idx: _best.idx });
}

/// Event helper: destroy the first structure of _type ("wall" / "bridge").
function game_adv_kill_structure(_g, _type) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].structure != undefined && hazard_def_get(_sp[_i].structure.structId).type == _type) {
                _sp[_i].structure = undefined; game_log(_g, "A " + _type + " is destroyed!"); return;
            }
        }
    }
}

/// Event helper: clear the first hazard found (an emitter structure, or a floor-hazard tile).
function game_adv_clear_a_hazard(_g) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].structure != undefined && hazard_def_get(_sp[_i].structure.structId).type == "hazard") {
                _sp[_i].structure = undefined; game_log(_g, "A hazard emitter is cleared!"); return;
            }
            if (_sp[_i].structure == undefined && _sp[_i].kind == "hazard") {
                _sp[_i].kind = "plain"; _sp[_i].hazard = ""; _g.tileVersion += 1; game_log(_g, "A hazard is cleared!"); return;
            }
        }
    }
}

/// Event helper: rebuild the first wall as a different wall type from the board's buildable set.
function game_adv_reroll_wall(_g) {
    var _walls = _g.boardDef.structures.walls;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].structure != undefined && hazard_def_get(_sp[_i].structure.structId).type == "wall") {
                var _cur = _sp[_i].structure.structId; var _pick = _cur;
                for (var _w = 0; _w < array_length(_walls); _w++) if (_walls[_w] != _cur) { _pick = _walls[_w]; break; }
                _sp[_i].structure = { structId: _pick, curHp: hazard_def_get(_pick).hp };
                game_log(_g, "A wall is rebuilt as a " + hazard_def_get(_pick).name + "!"); return;
            }
        }
    }
}

/// Event helper: turn an empty space in a lane that HAS a treasure into a hazard / enemy space.
function game_adv_soil(_g, _kind, _hazard) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _hasT = false;
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) if (_g.treasures[_ti].lane == _l) { _hasT = true; break; }
        if (!_hasT) continue;
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (_sp[_i].kind == "plain" && _sp[_i].structure == undefined && _sp[_i].enemy == undefined
                && game_treasure_at(_g, _l, _i) == undefined) {
                if (_kind == "enemy") { _sp[_i].kind = "enemy"; game_spawn_enemy_at(_g, _l, _i); }
                else { _sp[_i].kind = "hazard"; _sp[_i].hazard = _hazard; }
                _g.tileVersion += 1;
                game_log(_g, "The soil shifts!"); return;
            }
        }
    }
}

/// Fill up to _n bare enemy spaces (game_spawn_enemy_at shuffles bosses back). _anywhere
/// = the whole board (POD enemies may go anywhere); otherwise only player _p's own side.
function game_day_pod(_g, _p, _n, _anywhere = false) {
    var _placed = 0;
    for (var _l = 0; _l < _g.board.laneCount && _placed < _n; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp) && _placed < _n; _i++) {
            if ((_anywhere || game_side_match(_g, _p, _i)) && _sp[_i].kind == "enemy" && _sp[_i].enemy == undefined && game_spawn_enemy_at(_g, _l, _i)) _placed += 1;
        }
    }
}

/// An emitter hazard the board can produce (for STORM). Falls back to a fire geyser.
function game_day_storm_hazard(_g) {
    var _em = _g.boardDef.structures.emitters;
    return (array_length(_em) > 0) ? _em[irandom(array_length(_em) - 1)] : "firegeyser";
}

/// Does a space match a swap type token ("empty"/"enemy"/"treasure" or a hazard element)?
function game_space_type_matches(_sp, _type) {
    switch (_type) {
        case "empty": case "plain": return _sp.kind == "plain";
        case "enemy":    return _sp.kind == "enemy";
        case "treasure": return _sp.kind == "treasure";
        default:         return _sp.kind == "hazard" && _sp.hazard == _type;
    }
}
/// Rewrite a space to a swap type token (clears enemy/structure).
function game_space_set_type(_sp, _type) {
    _sp.enemy = undefined; _sp.structure = undefined;
    switch (_type) {
        case "empty": case "plain": _sp.kind = "plain"; _sp.hazard = ""; break;
        case "enemy":    _sp.kind = "enemy";    _sp.hazard = ""; break;
        case "treasure": _sp.kind = "treasure"; _sp.hazard = ""; break;
        default:         _sp.kind = "hazard";   _sp.hazard = _type; break;
    }
}
/// Is (lane,idx) a legal target for the pending day swap - the pending player's OWN side and a
/// space of the swap's FROM type? Drives the targeter highlight and the click validation.
function game_day_swap_target_ok(_g, _lane, _idx) {
    if (_g.pendingDaySwap == undefined) return false;
    var _pi = _g.pendingDaySwap.playerIdx;
    if (!game_side_match(_g, _pi, _idx)) return false;
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    if (!game_space_type_matches(_sp, _g.pendingDaySwap.from)) return false;
    // ENEMY-FROM protection (provisional, pending Zak): you can't swap AWAY an OCCUPIED enemy tile while
    // an EMPTY enemy space still exists on your side to swap instead - only convert an occupied one when
    // all your enemy spaces are filled (the swap is then forced). Stops the swap being a free enemy-kill.
    if (_g.pendingDaySwap.from == "enemy" && _sp.enemy != undefined && game_day_swap_has_empty_enemy(_g, _pi)) return false;
    return true;
}
/// Does the swap player's OWN side have an EMPTY enemy space (enemy-kind, no enemy on it)?
function game_day_swap_has_empty_enemy(_g, _p) {
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++) {
            var _s = _g.board.lanes[_l].spaces[_i];
            if (_s.kind == "enemy" && _s.enemy == undefined && game_side_match(_g, _p, _i)) return true;
        }
    return false;
}

/// Does the pending day-swap player have any legal target? (auto-skip a swap with nothing to hit)
function game_day_swap_any_target(_g) {
    if (_g.pendingDaySwap == undefined) return false;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_day_swap_target_ok(_g, _l, _i)) return true;
    return false;
}

/// Resolve the pending day swap at the chosen (validated) space: animated flip + clear pending.
function game_day_swap_choose(_g, _lane, _idx) {
    if (!game_day_swap_target_ok(_g, _lane, _idx)) return false;
    var _ps = _g.pendingDaySwap;
    game_apply_swap_animated(_g, _lane, _idx, _ps.to);
    game_log(_g, "P" + string(_ps.playerIdx + 1) + " swaps a " + string_upper(_ps.from) + " space to " + string_upper(_ps.to) + ".");
    _g.pendingDaySwap = undefined;
    return true;
}

/// AI / sim auto-resolution: flip the first legal own-side tile (or clear if none).
function game_day_swap_auto(_g) {
    if (_g.pendingDaySwap == undefined) return;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_day_swap_target_ok(_g, _l, _i)) { game_day_swap_choose(_g, _l, _i); return; }
    _g.pendingDaySwap = undefined;
}
/// EXPERIMENTAL "Chaos Swaps" rule: resolve the pending swap on a RANDOM legal tile (respects
/// game_day_swap_target_ok, so still own-side + from-type + the enemy protection). Nondeterministic
/// on purpose - a digital-only bit of fun. Applied at fire time for BOTH human and AI when the rule is on.
function game_day_swap_random(_g) {
    if (_g.pendingDaySwap == undefined) return;
    var _cands = [];
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_day_swap_target_ok(_g, _l, _i)) array_push(_cands, { lane: _l, idx: _i });
    if (array_length(_cands) == 0) { _g.pendingDaySwap = undefined; return; }
    var _pick = _cands[irandom(array_length(_cands) - 1)];
    game_day_swap_choose(_g, _pick.lane, _pick.idx);
}

// ---- day POD / STORM placement (player-driven) -------------------------------------------
/// The emitter STORM drops - the board's first available one (deterministic; net-safe).
function game_day_storm_build(_g) {
    var _em = _g.boardDef.structures.emitters;
    return (array_length(_em) > 0) ? _em[0] : "firegeyser";
}
/// Is (lane,idx) a legal target for the pending POD/STORM? POD = any empty enemy space (bare,
/// no treasure/structure); STORM = the pending player's OWN empty basic space (no hazard/card/structure).
function game_day_place_target_ok(_g, _lane, _idx) {
    if (_g.pendingDayPlace == undefined) return false;
    var _pp = _g.pendingDayPlace;
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    if (_pp.kind == "pod") {
        return (_sp.kind == "enemy" && _sp.enemy == undefined && game_treasure_at(_g, _lane, _idx) == undefined && _sp.structure == undefined);
    }
    // storm
    if (!game_side_match(_g, _pp.playerIdx, _idx)) return false;
    return (_sp.kind != "hazard" && !game_space_has_card(_g, _lane, _idx) && _sp.structure == undefined);
}
/// Any legal target for the pending POD/STORM?
function game_day_place_any_target(_g) {
    if (_g.pendingDayPlace == undefined) return false;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_day_place_target_ok(_g, _l, _i)) return true;
    return false;
}
/// Resolve one POD/STORM placement at the chosen (validated) space. Decrements the count and
/// clears the pending state when it (or the supply of legal spaces) runs out.
function game_day_place_choose(_g, _lane, _idx) {
    if (!game_day_place_target_ok(_g, _lane, _idx)) return false;
    var _pp = _g.pendingDayPlace;
    if (_pp.kind == "pod") {
        game_spawn_enemy_at(_g, _lane, _idx);
        game_log(_g, "P" + string(_pp.playerIdx + 1) + " deploys a POD enemy.");
    } else {
        var _b = game_day_storm_build(_g);
        var _eDef = hazard_def_get(_b);
        _g.board.lanes[_lane].spaces[_idx].structure = { structId: _b, curHp: _eDef.hp };
        game_log(_g, "P" + string(_pp.playerIdx + 1) + " drops a " + _eDef.name + " (STORM).");
    }
    _pp.count -= 1;
    if (_pp.count <= 0 || !game_day_place_any_target(_g)) _g.pendingDayPlace = undefined;
    return true;
}
/// AI / sim auto-resolution: fill the first legal space(s) until the count/legal-spaces run out.
function game_day_place_auto(_g) {
    if (_g.pendingDayPlace == undefined) return;
    var _guard = 0;
    while (_g.pendingDayPlace != undefined && _guard < 64) {
        _guard += 1;
        var _did = false;
        for (var _l = 0; _l < _g.board.laneCount && !_did; _l++)
            for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces) && !_did; _i++)
                if (game_day_place_target_ok(_g, _l, _i)) { game_day_place_choose(_g, _l, _i); _did = true; }
        if (!_did) { _g.pendingDayPlace = undefined; break; }
    }
}

// ============ ADVENTURE EVENT SPACE PICKERS ============
// Space-target events ("of your choice") use the SAME targeter as the day POD/STORM: set
// _g.pendingEvent, highlight eligible spaces, the human clicks one (AI/sim auto-resolve).
// effect: "soil" | "killwall" | "killbridge" | "killhazard" | "rerollwall" | "spicy".

function game_event_target_ok(_g, _lane, _idx) {
    if (!variable_struct_exists(_g, "pendingEvent") || _g.pendingEvent == undefined) return false;
    var _pe = _g.pendingEvent;
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    switch (_pe.effect) {
        case "soil":   // an EMPTY space in a lane that HAS a treasure
            if (!(_sp.kind == "plain" && _sp.structure == undefined && _sp.enemy == undefined
                  && game_treasure_at(_g, _lane, _idx) == undefined)) return false;
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) if (_g.treasures[_ti].lane == _lane) return true;
            return false;
        case "killwall": case "rerollwall":
            return _sp.structure != undefined && hazard_def_get(_sp.structure.structId).type == "wall";
        case "killbridge":
            return _sp.structure != undefined && hazard_def_get(_sp.structure.structId).type == "bridge";
        case "killemitter":   // Faulty Wiring destroys an EMITTER only (not floor hazards)
            return _sp.structure != undefined && hazard_def_get(_sp.structure.structId).type == "hazard";
        case "spicy":  return true;   // any space - the player's choice
    }
    return false;
}
function game_event_any_target(_g) {
    if (!variable_struct_exists(_g, "pendingEvent") || _g.pendingEvent == undefined) return false;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_event_target_ok(_g, _l, _i)) return true;
    return false;
}
function game_event_choose(_g, _lane, _idx) {
    if (!game_event_target_ok(_g, _lane, _idx)) return false;
    var _pe = _g.pendingEvent;
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    switch (_pe.effect) {
        case "soil":
            if (_pe.kind == "enemy") { _sp.kind = "enemy"; game_spawn_enemy_at(_g, _lane, _idx); }
            else { _sp.kind = "hazard"; _sp.hazard = _pe.hazard; }
            _g.tileVersion += 1; game_log(_g, "The soil shifts!");
            break;
        case "killwall":    _sp.structure = undefined; game_log(_g, "A wall is destroyed!"); break;
        case "killbridge":  _sp.structure = undefined; game_log(_g, "A bridge is destroyed!"); break;
        case "killemitter": _sp.structure = undefined; game_log(_g, "An emitter is destroyed!"); break;
        case "rerollwall":
            // pick which wall it BECOMES via the generic type picker - ANY wall in the game (not just the
            // map's buildable set), since a Reconstruction event can turn it into anything wall-like
            var _allHaz = global.hazardData.hazards;
            var _cur = _sp.structure.structId; var _opts = [];
            for (var _w = 0; _w < array_length(_allHaz); _w++)
                if (_allHaz[_w].type == "wall" && _allHaz[_w].id != _cur) array_push(_opts, _allHaz[_w].id);
            if (array_length(_opts) == 0) { game_log(_g, "No other wall type to change into."); break; }
            _g.pendingTypePick = { playerIdx: _pe.playerIdx, purpose: "reconstruct", options: _opts, lane: _lane, idx: _idx };
            game_log(_g, "Choose the new wall type.");
            break;
        case "spicy":
            array_push(_g.sprays, { playerIdx: _pe.playerIdx, lane: _lane, idx: _idx });
            game_log(_g, "That space is Ultra-Spicy!");
            break;
    }
    // This space-pick is done. If it opened a follow-up TYPE picker (Reconstruction), that stays the sole
    // live modal (it resumes the pump when it resolves). Otherwise clear the slot and pump the next event.
    if (variable_struct_exists(_g, "pendingTypePick") && _g.pendingTypePick != undefined) { _g.pendingEvent = undefined; }
    else { _g.pendingEvent = undefined; game_adv_event_pump(_g); }
    return true;
}
/// AI / sim: resolve the active space-pick by taking the first legal space, then let the pump continue.
function game_event_auto(_g) {
    if (!variable_struct_exists(_g, "pendingEvent") || _g.pendingEvent == undefined) return;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_event_target_ok(_g, _l, _i)) { game_event_choose(_g, _l, _i); return; }
    _g.pendingEvent = undefined; game_adv_event_pump(_g);   // active pick lost its target -> skip on
}
/// Open a space-target event pick. The pump guarantees the slot is free; fizzles (no-op) if no legal space.
function game_event_set_pending(_g, _p, _effect, _kind, _hazard) {
    _g.pendingEvent = { playerIdx: _p, effect: _effect, kind: _kind, hazard: _hazard };
    if (!game_event_any_target(_g)) _g.pendingEvent = undefined;   // nothing to pick -> fizzle (pump continues)
}

// ============ GENERIC CARD-TYPE PICKER ============
// A modal that offers a SUBSET of card types available on the map (wall types, pellet colours, ...)
// and applies the pick per `purpose`. Reusable across effects. Human clicks a button (Draw_64),
// AI/sim auto-pick the first option.

/// The display label for a type-pick option (purpose-aware).
function game_type_pick_label(_purpose, _optId) {
    switch (_purpose) {
        case "reconstruct": return hazard_def_get(_optId).name;
        case "pellet":      return pellet_label(_optId);   // "red5" -> "Red 5"
        default:            return string(_optId);
    }
}
/// Apply a chosen type. A pick with a `need` count stays live until the count runs out (e.g. Nap
/// Time's 2 pellets); the last pick clears the modal + resumes the event pump.
function game_type_pick_choose(_g, _optId) {
    if (!variable_struct_exists(_g, "pendingTypePick") || _g.pendingTypePick == undefined) return false;
    var _tp = _g.pendingTypePick;
    if (!arr_has(_tp.options, _optId)) return false;
    switch (_tp.purpose) {
        case "reconstruct":
            _g.board.lanes[_tp.lane].spaces[_tp.idx].structure = { structId: _optId, curHp: hazard_def_get(_optId).hp };
            game_log(_g, "The wall becomes a " + hazard_def_get(_optId).name + "!");
            break;
        case "pellet":
            array_push(_g.players[_tp.playerIdx].pellets, _optId);
            game_log(_g, "Took a " + pellet_label(_optId) + " pellet.");
            break;
    }
    _tp.need = (variable_struct_exists(_tp, "need") ? _tp.need : 1) - 1;
    if (_tp.need > 0) return true;   // more to pick - keep the modal up (options don't deplete)
    _g.pendingTypePick = undefined;
    game_adv_event_pump(_g);         // finished - continue with the next queued event effect
    return true;
}
/// AI / sim: take the first offered type, draining any pick count.
function game_type_pick_auto(_g) {
    var _guard = 0;
    while (variable_struct_exists(_g, "pendingTypePick") && _g.pendingTypePick != undefined && _guard < 64) {
        _guard += 1;
        if (array_length(_g.pendingTypePick.options) > 0) game_type_pick_choose(_g, _g.pendingTypePick.options[0]);
        else { _g.pendingTypePick = undefined; game_adv_event_pump(_g); break; }
    }
}

/// Format a pellet id ("red5") as a label ("Red 5").
function pellet_label(_pid) {
    var _digits = "";
    for (var _k = string_length(_pid); _k >= 1; _k--) {
        var _ch = string_char_at(_pid, _k);
        if (_ch >= "0" && _ch <= "9") _digits = _ch + _digits; else break;
    }
    var _col = string_copy(_pid, 1, string_length(_pid) - string_length(_digits));
    return string_upper(string_char_at(_col, 1)) + string_delete(_col, 1, 1) + (_digits != "" ? (" " + _digits) : "");
}

// ============ LOSE-PIKMIN PICKER ============
// "Lose N Pikmin of your choice" (Misplaced Troops / Sudden Explosion): the player removes one of
// their pikmin per click, from any SPACE or HOME that holds them, until N are gone. AI/sim auto-pick
// home reserves first, then the field. Serialized with the event pump like the other pickers.

function game_lose_target_ok(_g, _loc) {
    if (!variable_struct_exists(_g, "pendingLose") || _g.pendingLose == undefined) return false;
    return array_length(game_tokens_at(_g, _g.pendingLose.playerIdx, _loc)) > 0;
}
function game_lose_any_target(_g) {
    if (!variable_struct_exists(_g, "pendingLose") || _g.pendingLose == undefined) return false;
    if (game_lose_target_ok(_g, { kind: "home" })) return true;
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces); _i++)
            if (game_lose_target_ok(_g, { kind: "space", lane: _l, idx: _i })) return true;
    return false;
}
/// Shed priority for the lose-pikmin event: LOWER = sacrificed first. Commons (red/blue/yellow) go
/// first, then the specialists in ascending value, so a −N never eats your best pikmin while lesser
/// ones are standing right there: rby < ice < rock < winged < white < purple (worth 5).
function pik_shed_rank(_typeId) {
    switch (_typeId) {
        case "purple": return 5;
        case "white":  return 4;
        case "winged": return 3;
        case "rock":   return 2;
        case "ice":    return 1;
        default:       return 0;   // red / blue / yellow
    }
}
/// Remove ONE pikmin at _loc; count down. Clears (and pumps) when the quota is met or nothing's left.
/// When several colours share _loc, the least-valuable (lowest shed rank) is the one sacrificed.
function game_lose_choose(_g, _loc) {
    if (!game_lose_target_ok(_g, _loc)) return false;
    var _toks = _g.players[_g.pendingLose.playerIdx].tokens;
    var _pick = -1;
    for (var _i = 0; _i < array_length(_toks); _i++) {
        if (!game_loc_eq(_toks[_i].loc, _loc)) continue;
        if (_pick == -1 || pik_shed_rank(_toks[_i].typeId) < pik_shed_rank(_toks[_pick].typeId)) _pick = _i;
    }
    if (_pick != -1) {
        if (_loc.kind == "space") game_fx_pik(_g, _toks[_pick], _loc.lane, _loc.idx);   // a soul on the field
        array_delete(_toks, _pick, 1);
    }
    _g.pendingLose.need -= 1;
    if (_g.pendingLose.need <= 0 || !game_lose_any_target(_g)) { _g.pendingLose = undefined; game_adv_event_pump(_g); }
    return true;
}
/// AI / sim: shed the quota - home reserves first (silent), then field bodies.
function game_lose_auto(_g) {
    var _guard = 0;
    while (variable_struct_exists(_g, "pendingLose") && _g.pendingLose != undefined && _guard < 256) {
        _guard += 1;
        if (game_lose_target_ok(_g, { kind: "home" })) { game_lose_choose(_g, { kind: "home" }); continue; }
        var _did = false;
        for (var _l = 0; _l < _g.board.laneCount && !_did; _l++)
            for (var _i = 0; _i < array_length(_g.board.lanes[_l].spaces) && !_did; _i++)
                if (game_lose_target_ok(_g, { kind: "space", lane: _l, idx: _i })) { game_lose_choose(_g, { kind: "space", lane: _l, idx: _i }); _did = true; }
        if (!_did) { _g.pendingLose = undefined; game_adv_event_pump(_g); break; }
    }
}
/// Open the lose-pikmin picker; fizzles (no-op) if the player has no pikmin at all.
function game_lose_set_pending(_g, _p, _n) {
    _g.pendingLose = { playerIdx: _p, need: _n };
    if (!game_lose_any_target(_g)) _g.pendingLose = undefined;
}

/// SWAP: turn one (or ALL) `_from`-type space(s) on player _p's side into `_to`.
function game_day_swap(_g, _p, _from, _to, _all) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _sp = _g.board.lanes[_l].spaces;
        for (var _i = 0; _i < array_length(_sp); _i++) {
            if (!game_side_match(_g, _p, _i)) continue;
            if (game_space_type_matches(_sp[_i], _from)) {
                game_apply_swap_animated(_g, _l, _i, _to);   // fade to white -> flip -> fade back
                if (!_all) return;
            }
        }
    }
}

/// Clear the `justSpawned` flags once the day cinematic has revealed the new enemies -
/// next sunset they count as existing survivors, not fresh pop-ins.
function game_clear_spawn_marks(_g) {
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _spaceIdx = 0; _spaceIdx < array_length(_spaces); _spaceIdx++) {
            if (_spaces[_spaceIdx].enemy != undefined) _spaces[_spaceIdx].enemy.justSpawned = false;
        }
    }
}
