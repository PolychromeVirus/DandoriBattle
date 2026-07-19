// Core rules engine (M3). Pure game state + mutations - no rendering, no input.
// Everything the UI (and later the AI / network layer) does goes through game_*
// functions, and all randomness lives here.
//
// Locations: {kind:"home"} (owner implied by token) or {kind:"space", lane, idx}.
// Lane spaces run 0-6: 0-2 player A's side, 3 shared treasure space, 4-6 player B's.

// ---------- construction & setup ----------

function game_new(_boardId) {
    var _boardDef = board_def_get(_boardId);
    var _g = {
        boardDef: _boardDef,
        board: board_create(_boardDef),
        treasures: [],       // {cards:[treasureIds], lane, idx, boss:undefined|{enemyDefId, curHp, dead}}
        players: [],
        firstPlayer: 0,
        activePlayer: 0,
        phase: "gather",     // gather | orders | move | gameover
        gatherActionsLeft: 0,
        dayNumber: 1,
        dayTrack: 1,
        decks: {
            gather: deck_build_gather(_boardDef.setNumber),
            gatherDiscard: [],
            treasure: deck_build_treasure(_boardDef.treasureSet),
            enemy: enemy_deck_build(_boardDef.setNumber),
            enemyDiscard: [],
        },
        sprays: [],          // {playerIdx, lane, idx} - ultra-spicy tokens
        mines: [],           // {lane, idx, dmg} - arm at 10 pass-damage, then kill enders
        decoys: [],          // {playerIdx, lane, idx, hp} - pikpik carrots soak enemy damage
        pendingFree: [],     // {playerIdx, count} - boss bounty free hazard placements, killer first
        pendingDiscard: undefined, // {playerIdx, need} - hand-limit overflow, owner picks; handoff waits
        departing: [],       // {cards, playerIdx, lane, fromIdx, total} - piles animating home, scored on arrival
        fx: [],              // presentation death events, drained by the controller (cosmetic; rules ignore it)
        resolveQueue: [],    // pending resolution beats (controller pumps game_resolve_step)
        jumpCue: "",         // "" | "pik" | "enemy" - renderer makes that side's fighters wind up
        bombCue: undefined,  // {lane, idx} - Bomb Rock/Boulder telegraph target (strobe + ring)
        sprayCue: false,     // spicy ignition beat - sprayed friendlies glow red
        trace: [false, false], // per-seat human decision tracing (controller sets from ctl)
        combatFights: undefined, // fights list persisted across staged combat beats
        log: [],
        winner: -1,
    };
    for (var _p = 0; _p < 2; _p++) {
        array_push(_g.players, {
            playerIdx: _p,
            hand: [],        // gather card ids
            pellets: [],     // pellet card ids
            tokens: [],      // {typeId, loc}
            score: 0,
            collected: [],
            turnsTaken: 0,
        });
    }
    deck_shuffle(_g.decks.gather);
    deck_shuffle(_g.decks.treasure);
    deck_shuffle(_g.decks.enemy);
    game_setup(_g);
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

function deck_build_treasure(_treasureSet) {
    var _deck = [];
    var _defs = global.treasureData.treasures;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_treasureSet == "all" || _defs[_i].set == _treasureSet) {
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
function game_fx_pik(_g, _tok, _lane, _idx) {
    // carry the token's render position (vx/vy, if the renderer has set it) so the
    // soul rises from exactly where the pikmin was standing
    var _hasV = variable_struct_exists(_tok, "vx");
    array_push(_g.fx, { kind: "pik", typeId: _tok.typeId, lane: _lane, idx: _idx,
        px: _hasV ? _tok.vx : undefined, py: _hasV ? _tok.vy : undefined });
}
function game_fx_enemy(_g, _enemyDefId, _lane, _idx, _isBoss) {
    array_push(_g.fx, { kind: "enemy", enemyDefId: _enemyDefId, lane: _lane, idx: _idx, isBoss: _isBoss });
}
function game_fx_boom(_g, _lane, _idx) {
    array_push(_g.fx, { kind: "boom", lane: _lane, idx: _idx });
}
function game_fx_spicy(_g, _lane, _idx) {
    array_push(_g.fx, { kind: "spicy", lane: _lane, idx: _idx });
}

function game_setup(_g) {
    // treasure piles: deal face up until each pile is worth >= 500p
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        if (_g.board.lanes[_laneIdx].spaces[3].kind != "treasure") continue;
        var _pile = [];
        var _pileVal = 0;
        while (_pileVal < global.rules.treasurePileMinValue && array_length(_g.decks.treasure) > 0) {
            var _cardId = array_pop(_g.decks.treasure);
            array_push(_pile, _cardId);
            _pileVal += treasure_def_get(_cardId).value;
        }
        array_push(_g.treasures, { cards: _pile, lane: _laneIdx, idx: 3, boss: undefined });
    }
    game_fill_enemy_spaces(_g);
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
                    var _pile = game_richest_bossless_pile(_g);
                    if (_pile != undefined) {
                        _pile.boss = { enemyDefId: _enemyId, curHp: _enemyDef.hp, dead: false };
                        game_log(_g, "BOSS " + _enemyDef.name + " guards the " + treasure_def_get(_pile.cards[array_length(_pile.cards) - 1]).name + " pile!");
                    } else {
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

function game_treasures_realized(_cardIds) {
    var _loose = 0;
    var _seriesCount = {};
    var _seriesVal = {};
    for (var _i = 0; _i < array_length(_cardIds); _i++) {
        var _def = treasure_def_get(_cardIds[_i]);
        if (_def.effectType == "Set") {
            var _k = _def.effect;
            _seriesCount[$ _k] = (variable_struct_exists(_seriesCount, _k) ? _seriesCount[$ _k] : 0) + 1;
            _seriesVal[$ _k] = (variable_struct_exists(_seriesVal, _k) ? _seriesVal[$ _k] : 0) + _def.value;
        } else {
            _loose += _def.value;
        }
    }
    var _total = _loose;
    var _names = variable_struct_get_names(_seriesCount);
    for (var _i = 0; _i < array_length(_names); _i++) {
        if (_seriesCount[$ _names[_i]] >= global.rules.setThreshold) _total += _seriesVal[$ _names[_i]];
    }
    return _total;
}

function game_realized_score(_g, _p) {
    return game_treasures_realized(_g.players[_p].collected);
}

/// Group a player's collected treasures for display: loose group first, then each
/// series with its count, points, and whether it has hit the scoring threshold.
/// Returns { score, groups: [ { name, isLoose, ids, count, value, active } ] }.
function game_collection_summary(_g, _p) {
    var _coll = _g.players[_p].collected;
    var _loose = { name: "Loose Treasures", isLoose: true, ids: [], count: 0, value: 0, active: true };
    var _seriesMap = {};
    var _order = [];
    for (var _i = 0; _i < array_length(_coll); _i++) {
        var _def = treasure_def_get(_coll[_i]);
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
            _s.value += _def.value;
        } else {
            array_push(_loose.ids, _coll[_i]);
            _loose.count += 1;
            _loose.value += _def.value;
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

/// Can this pikmin type stand on / pass this space? Height is one-way (gated only
/// when heading toward the treasure space). Structures: bridges carry anyone over;
/// walls block passage but can be attacked as a destination; emitters behave as a
/// floor hazard of their element (immune pass free) but can be ATTACKED by anyone
/// (non-immune die doing so - handled in combat), so they're legal destinations.
/// _isDest: this is the final target square (attacking), not a pass-through.
function game_type_can_enter(_typeDef, _space, _towardCenter, _isDest = false, _waterOk = false) {
    if (_space.structure != undefined) {
        var _sDef = hazard_def_get(_space.structure.structId);
        if (_sDef.type == "bridge") return true;
        if (_sDef.type == "wall") return _isDest; // attack it as a destination; never pass through
        // emitter: any pikmin may be assigned to attack it...
        if (_isDest) return true;
        // POISON never blocks - anyone walks over it (it damages on passing, not here)
        if (_sDef.element == "poison") return true;
        // ...other emitters block passage for non-immune (floor-hazard element gate)
        if (_sDef.element != "" && !arr_has(_typeDef.immunities, _sDef.element)
            && !arr_has(_typeDef.traits, "flies_over_hazards")) return false;
        return true;
    }
    if (_space.kind != "hazard") return true;
    if (arr_has(_typeDef.traits, "flies_over_hazards")) return (_space.hazard != "height") || !_towardCenter || arr_has(_typeDef.traits, "climbs_height");
    switch (_space.hazard) {
        case "height": return !_towardCenter || arr_has(_typeDef.traits, "climbs_height");
        // yellow (experimental): thrown across a chasm, but only heading toward the
        // centre - they can't climb back out the far side
        case "chasm":  return (global.expRules.yellow && _typeDef.id == "yellow" && _towardCenter);
        // blue (experimental): a lifeguard-covered group crosses water (_waterOk set
        // by game_lifeguard_ok for the whole move); otherwise only water-immune pass
        case "water":  return arr_has(_typeDef.immunities, "water") || _waterOk;
        case "poison": return true;         // non-blocking; damages on pass (game_poison_step)
        default:       return arr_has(_typeDef.immunities, _space.hazard);
    }
}

/// A space is poisonous if it's a poison map-hazard or holds a Poison Emitter.
function game_space_is_poison(_g, _lane, _idx) {
    var _sp = _g.board.lanes[_lane].spaces[_idx];
    if (_sp.kind == "hazard" && _sp.hazard == "poison") return true;
    if (_sp.structure != undefined) {
        var _d = hazard_def_get(_sp.structure.structId);
        if (_d.type == "hazard" && _d.element == "poison") return true;
    }
    return false;
}

/// Poison-immune = white/bulbmin (immunity) or winged (flies over).
function game_type_poison_immune(_typeId) {
    var _d = pikmin_type_get(_typeId);
    return arr_has(_d.immunities, "poison") || arr_has(_d.traits, "flies_over_hazards");
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
    var _step = (_to > _from) ? 1 : -1;
    var _s = _from;
    while (_s != _to) { // includes src (exited), excludes dst (entered, not exited)
        if (_s >= 0 && _s <= 6) array_push(_out, { lane: _lane, idx: _s, key: string(_lane) + "_" + string(_s) });
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
function game_dest_legal(_g, _p, _typeId, _lane, _idx, _waterOk = false) {
    var _typeDef = pikmin_type_get(_typeId);
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    var _prevDist = 4; // HOME sits beyond the outermost space
    while (_s != _idx) {
        var _toward = abs(_s - 3) < _prevDist;
        var _space = _g.board.lanes[_lane].spaces[_s];
        if (_space.enemy != undefined) return false;                 // fight it, or stop short of it
        if (game_treasure_at(_g, _lane, _s) != undefined) return false;
        if (!game_type_can_enter(_typeDef, _space, _toward, false, _waterOk)) return false; // wall / non-immune hazard
        _prevDist = abs(_s - 3);
        _s += _dir;
        if (_s < 0 || _s > 6) return false;
    }
    var _towardDest = abs(_idx - 3) < _prevDist;
    return game_type_can_enter(_typeDef, _g.board.lanes[_lane].spaces[_idx], _towardDest, true, _waterOk);
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
    var _dir = (_p == 0) ? -1 : 1;               // toward this player's home edge
    var _homeEdge = (_p == 0) ? 0 : 6;
    var _s = _srcIdx;
    var _prevDist = abs(_srcIdx - 3);
    while (_s != _homeEdge) {
        _s += _dir;
        var _toward = abs(_s - 3) < _prevDist;   // this step heads toward the centre?
        var _space = _g.board.lanes[_lane].spaces[_s];
        if (_space.enemy != undefined) return false;
        if (game_treasure_at(_g, _lane, _s) != undefined) return false;
        if (!game_type_can_enter(_typeDef, _space, _toward, false, _waterOk)) return false;
        _prevDist = abs(_s - 3);
    }
    return true;
}

/// Can a field token walk straight along its lane from src to dst (no home trip)?
/// Used for the "attach to a card behind/ahead of you" exception: intermediate
/// spaces must be standable and unblocked, and the destination enterable/attackable.
function game_direct_reachable(_g, _p, _typeId, _lane, _srcIdx, _dstIdx) {
    if (_srcIdx == _dstIdx) return true;
    var _typeDef = pikmin_type_get(_typeId);
    var _dir = (_dstIdx > _srcIdx) ? 1 : -1;
    var _s = _srcIdx;
    var _prevDist = abs(_srcIdx - 3);
    while (_s != _dstIdx) {
        _s += _dir;
        var _toward = abs(_s - 3) < _prevDist;
        var _space = _g.board.lanes[_lane].spaces[_s];
        var _isDest = (_s == _dstIdx);
        if (!_isDest) {
            if (_space.enemy != undefined) return false;
            if (game_treasure_at(_g, _lane, _s) != undefined) return false;
            if (!game_type_can_enter(_typeDef, _space, _toward, false)) return false;
        } else if (!game_type_can_enter(_typeDef, _space, _toward, true)) {
            return false;
        }
        _prevDist = abs(_s - 3);
    }
    return true;
}

/// Full move legality accounting for where the token currently IS, not just the
/// deploy path from home. From home: the usual deploy check. From the field: it
/// must be able to retreat home AND deploy, OR (if trapped) walk directly to a card
/// on its own lane. Moving TO home requires being able to reach home at all.
function game_move_legal(_g, _p, _typeId, _src, _dst, _waterOk = false) {
    if (_dst.kind == "home") {
        if (_src.kind == "home") return true;
        return game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk);
    }
    if (_src.kind == "home") {
        return game_dest_legal(_g, _p, _typeId, _dst.lane, _dst.idx, _waterOk);
    }
    // field -> space
    if (game_can_reach_home(_g, _p, _typeId, _src.lane, _src.idx, _waterOk)
        && game_dest_legal(_g, _p, _typeId, _dst.lane, _dst.idx, _waterOk)) return true;
    // trapped, but may still attach to a card it can walk to along this lane
    if (_src.lane == _dst.lane
        && game_space_has_card(_g, _dst.lane, _dst.idx)
        && game_direct_reachable(_g, _p, _typeId, _src.lane, _src.idx, _dst.idx)) return true;
    return false;
}

/// Target location from card args: {atHome:true} means the player's own HOME.
function game_args_loc(_args) {
    if (variable_struct_exists(_args, "atHome") && _args.atHome) return { kind: "home" };
    return { kind: "space", lane: _args.lane, idx: _args.idx };
}

// ---------- turn flow ----------

function game_begin_turn(_g) {
    _g.phase = "gather";
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
        + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength) + ")  score "
        + string(game_realized_score(_g, _g.activePlayer)) + " vs " + string(game_realized_score(_g, 1 - _g.activePlayer)) + " =====");
    game_log(_g, "== Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength) + ") - Player " + string(_g.activePlayer + 1) + "'s turn ==");
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

function game_gather_roll(_g) {
    if (_g.phase != "gather" || _g.gatherActionsLeft <= 0) return;
    var _die = _g.boardDef.pelletDie;
    var _face = _die[irandom(array_length(_die) - 1)];
    var _pelletId = _face.color + string(_face.value);
    array_push(_g.players[_g.activePlayer].pellets, _pelletId);
    game_log(_g, "P" + string(_g.activePlayer + 1) + " rolls " + string(_face.value) + string_upper(string_char_at(_face.color, 1)));
    game_spend_gather_action(_g);
}

function game_spend_gather_action(_g) {
    _g.gatherActionsLeft -= 1;
    if (_g.gatherActionsLeft <= 0) _g.phase = "orders"; // phase shown in the UI; no log line
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
        var _moved = 0;
        for (var _i = 0; _i < array_length(_tokens) && _moved < _want; _i++) {
            var _tok = _tokens[_i];
            if (_tok.typeId != _typeId || !game_loc_eq(_tok.loc, _src)) continue;
            if (variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) continue; // tossed by a snitchbug
            if (token_is_frozen(_tok)) continue;                                       // iced solid
            _tok.loc = (_dst.kind == "home") ? { kind: "home" } : { kind: "space", lane: _dst.lane, idx: _dst.idx };
            _tok.movedThisTurn = true;
            _moved += 1;
        }
        // mines take 1 damage per pikmin that passed them
        for (var _m = 0; _m < array_length(_mineRefs); _m++) game_mine_damage(_g, _mineRefs[_m], _moved);
        if (_moved > 0) {
            _movedAny = true;
            game_trace(_g, "MOVE " + string(_moved) + " " + _typeId + ": "
                + ((_src.kind == "home") ? "home" : "L" + string(_src.lane + 1) + "i" + string(_src.idx)) + " -> "
                + ((_dst.kind == "home") ? "home" : "L" + string(_dst.lane + 1) + "i" + string(_dst.idx)));
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
        var _n = 0;
        var _i = 0;
        while (_i < array_length(_tokens) && _n < _want) {
            var _tok = _tokens[_i];
            if (_tok.typeId == _typeId && game_loc_eq(_tok.loc, _src) && !token_is_disabled(_tok)) {
                array_delete(_tokens, _i, 1);
                _n += 1;
                continue;
            }
            _i += 1;
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

function game_play_pellet(_g, _handIdx, _chosenColor) {
    if (_g.phase != "orders") return;
    var _pl = _g.players[_g.activePlayer];
    if (_handIdx < 0 || _handIdx >= array_length(_pl.pellets)) return;
    if (!arr_has(_g.boardDef.basicColors, _chosenColor)) return;
    var _def = pellet_def_get(_pl.pellets[_handIdx]);
    var _amount = (_chosenColor == _def.color) ? _def.sameTypeAmount : _def.offTypeAmount;
    var _cap = global.rules.pikminBoardCap;
    var _room = _cap - game_capped_count(_g, _g.activePlayer);
    var _grant = min(_amount, max(0, _room));
    repeat (_grant) array_push(_pl.tokens, { typeId: _chosenColor, loc: { kind: "home" } });
    if (_grant < _amount) game_log(_g, string(_amount - _grant) + " pikmin wasted (25 token cap).");
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
    var _grant = (_typeId == "bulbmin") ? _n : min(_n, max(0, global.rules.pikminBoardCap - game_capped_count(_g, _p)));
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
    game_enemy_deck_ensure(_g);
    while (array_length(_g.decks.enemy) > 0) {
        var _enemyId = array_pop(_g.decks.enemy);
        var _enemyDef = enemy_def_get(_enemyId);
        if (_enemyDef.boss) {
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
        game_log(_g, "Gather cards are played in the Move phase, before resolving.");
        return false;
    }

    switch (_effectId) {

        case "colorchangingposy": {
            if (!arr_has(_g.boardDef.basicColors, _args.color)) return false;
            var _grant = game_grant_pikmin(_g, _p, _args.color, 5);
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "P" + string(_p + 1) + " plays Color Changing Posy: " + string(_grant) + " " + _args.color + " pikmin.");
            return true;
        }

        case "rawmaterial": {
            // needs a second copy in hand (a clone counts as one of the pair)
            var _copies = 0;
            for (var _i = 0; _i < array_length(_pl.hand); _i++) {
                if (_pl.hand[_i] == "rawmaterial") _copies += 1;
            }
            if (_copies < ((_cardId == "captainclone") ? 1 : 2)) {
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
            // burn the second raw material
            for (var _i = 0; _i < array_length(_pl.hand); _i++) {
                if (_pl.hand[_i] == "rawmaterial") { game_discard_gather_card(_g, _i); break; }
            }
            game_log(_g, "P" + string(_p + 1) + " builds a " + _bDef.name + "!");
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
            if (_t == undefined || _t.boss != undefined) return false;
            // treasure must not be on your side (the treasure space counts as yours)
            if (_p == 0 && _t.idx <= 3) { game_log(_g, "That treasure is already on your side."); return false; }
            if (_p == 1 && _t.idx >= 3) { game_log(_g, "That treasure is already on your side."); return false; }
            // lane must be clear between your end and the treasure (bridges don't block)
            var _dir = (_p == 0) ? 1 : -1;
            var _s = (_p == 0) ? 0 : 6;
            while (_s != _t.idx) {
                if (game_space_has_card(_g, _args.lane, _s)) { game_log(_g, "That lane isn't clear."); return false; }
                _s += _dir;
            }
            // rush: move two spaces toward you, riders and all, ignoring hazards ("not passed")
            repeat (2) {
                var _newIdx = _t.idx - _dir;
                for (var _q = 0; _q < 2; _q++) {
                    var _riders = game_tokens_at(_g, _q, { kind: "space", lane: _t.lane, idx: _t.idx });
                    for (var _r = 0; _r < array_length(_riders); _r++) _riders[_r].loc = { kind: "space", lane: _t.lane, idx: _newIdx };
                }
                _t.idx = _newIdx;
            }
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
            // "Enemies skip their next action" - and opposing pikmin COUNT as enemies
            // (confirmed by user; the card text predates multiplayer), so bitter also
            // cancels an opposing carry by freezing their group for a turn.
            var _space = _g.board.lanes[_args.lane].spaces[_args.idx];
            var _t = game_treasure_at(_g, _args.lane, _args.idx);
            var _hit = 0;
            if (_space.enemy != undefined) { _space.enemy.stunned = 1; _space.enemy.stunnedBy = "bitter"; _hit += 1; }
            if (_t != undefined && _t.boss != undefined) { _t.boss.stunned = 1; _t.boss.stunnedBy = "bitter"; _hit += 1; }
            var _oppToks = game_tokens_at(_g, 1 - _p, { kind: "space", lane: _args.lane, idx: _args.idx });
            for (var _i = 0; _i < array_length(_oppToks); _i++) { _oppToks[_i].frozen = 2; _oppToks[_i].frozenKind = "bitter"; _hit += 1; }
            if (_hit == 0) { game_log(_g, "Nothing there to embitter."); return false; }
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Ultra-Bitter Spray! Everything hostile there is petrified for its next action.");
            return true;
        }

        case "icebomb": {
            var _n = game_freeze_space(_g, _args.lane, _args.idx);
            if (_n == 0) { game_log(_g, "Ice Bomb would hit nothing there."); return false; }
            game_discard_gather_card(_g, _handIdx);
            game_log(_g, "Ice Bomb! " + string(_n) + " creatures on the space are frozen for a turn.");
            return true;
        }

        case "storm": {
            // 2x2 area anchored at the clicked space (clamped to the board)
            var _l0 = clamp(_args.lane, 0, _g.board.laneCount - 2);
            var _i0 = clamp(_args.idx, 0, 5);
            var _n = game_freeze_space(_g, _l0, _i0, "shock")
                   + game_freeze_space(_g, _l0 + 1, _i0, "shock")
                   + game_freeze_space(_g, _l0, _i0 + 1, "shock")
                   + game_freeze_space(_g, _l0 + 1, _i0 + 1, "shock");
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
        for (var _si2 = 0; _si2 <= 6 && !_hasSwift; _si2++) {
            var _se = _g.board.lanes[_li].spaces[_si2].enemy;
            if (_se != undefined && !_se.dead && enemy_def_get(_se.enemyDefId).attackElement == "swift"
                && array_length(game_tokens_at(_g, _p, { kind: "space", lane: _li, idx: _si2 })) > 0) _hasSwift = true;
        }
    }
    for (var _ti = 0; _ti < array_length(_g.treasures) && !_hasSwift; _ti++) {
        var _tb = _g.treasures[_ti].boss;
        if (_tb != undefined && !_tb.dead && enemy_def_get(_tb.enemyDefId).attackElement == "swift"
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
        _space.structure.curHp -= _dmg;
        game_log(_g, _bName + " damages the " + hazard_def_get(_space.structure.structId).name + "!");
        if (_space.structure.curHp <= 0) {
            game_log(_g, "The " + hazard_def_get(_space.structure.structId).name + " is destroyed!");
            _space.structure = undefined;
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
                && !game_type_poison_immune(_tok.typeId)
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
            // the spray's EXTRA action is what overcomes a stalemate: ties only
            // move during the sprayed bonus pass (so tied = 1 space, untied = 2)
            if (_own >= _topDef.weight && (_own > _opp || (_sprayedOnly && _spiced && _own == _opp && _own > 0))) {
                // 2 spaces if an all-white team hauls it, OR (experimental "rush")
                // when the carrying power is at least double the pile's weight. Rush is
                // denied if a purple anchors the stack (strong yet slow), OR the
                // opponent has enough presence to HOLD it (opp meets the weight): you
                // can't rush a treasure that's being pulled against, only inch it.
                var _steps = 1;
                if (game_carriers_all_white(_g, _p, _t)) _steps = 2;
                if (global.expRules.rush && _own >= _topDef.weight * 2 && _opp < _topDef.weight
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
            } else if (_own > 0 && _own == _opp && _own >= _topDef.weight) {
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
    game_log(_g, "The Bridge collapses as the treasure is hauled off it!");
}

function game_carry_one_space(_g, _p, _t) {
    var _dir = (_p == 0) ? -1 : 1;
    var _newIdx = _t.idx + _dir;
    var _oldIdx = _t.idx;
    var _hereLoc = { kind: "space", lane: _t.lane, idx: _t.idx };

    if (_newIdx < 0 || _newIdx > 6) {
        // carried off the board edge: it heads HOME to be banked. Scoring is DEFERRED
        // until the pile finishes animating home (game_finalize_departing), so it
        // doesn't blink out of existence at the edge. Mechanically it leaves play now.
        var _total = 0;
        for (var _c = 0; _c < array_length(_t.cards); _c++) _total += treasure_def_get(_t.cards[_c]).value;
        array_push(_g.departing, { cards: _t.cards, playerIdx: _p, lane: _t.lane, fromIdx: _oldIdx, total: _total });
        // no log here - the pile animates home and the bank line reports the score
        for (var _q = 0; _q < 2; _q++) {
            var _riders = game_tokens_at(_g, _q, _hereLoc);
            for (var _r = 0; _r < array_length(_riders); _r++) _riders[_r].loc = { kind: "home" };
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

/// Settle the score at game over: bank any pile still in flight, then decide the
/// winner. Called by the controller once the board has stopped moving (so the final
/// haul banks before the result shows). Idempotent-ish via the controller's flag.
function game_finalize_gameover(_g) {
    game_flush_departing(_g);
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
                if (_enemyDef.attackElement != "" && arr_has(_typeDef.immunities, _enemyDef.attackElement)) _immune = true;
                if (!_immune) {
                    if (_tok.typeId == "white") _whiteRevenge += 1;
                    game_fx_pik(_g, _tok, _lane, _idx);
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
function game_freeze_space(_g, _lane, _idx, _kind = "ice") {
    var _count = 0;
    for (var _q = 0; _q < 2; _q++) {
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

/// Blowhog family: its "kills" are blow-backs - the tokens survive but return HOME.
function game_toss_home_tokens(_g, _p, _lane, _idx, _n) {
    var _loc = { kind: "space", lane: _lane, idx: _idx };
    var _tokens = _g.players[_p].tokens;
    var _tossed = 0;
    for (var _i = 0; _i < array_length(_tokens) && _tossed < _n; _i++) {
        var _tok = _tokens[_i];
        if (!game_loc_eq(_tok.loc, _loc)) continue;
        _tok.loc = { kind: "home" };
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
            if (_g.boardDef.killedIfThrownOut) { array_delete(_tokens, _i, 1); _killed += 1; continue; }
            _i += 1; // clings to the edge, stays put
            continue;
        }
        var _destSpace = _g.board.lanes[_destLane].spaces[_idx];
        if (!game_type_can_enter(pikmin_type_get(_tok.typeId), _destSpace, false, true)) {
            array_delete(_tokens, _i, 1);
            _killed += 1;
            continue;
        }
        _tok.loc = { kind: "space", lane: _destLane, idx: _idx };
        _i += 1;
    }
    if (_tossed > 0) {
        if (_offBoard && _g.boardDef.killedIfThrownOut) game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown clean off the board - lost!");
        else if (_offBoard) game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown at the edge but cling on!");
        else game_log(_g, string(_tossed) + " of P" + string(_p + 1) + "'s pikmin are thrown a lane " + (_dir > 0 ? "right" : "left") + (_killed > 0 ? " - " + string(_killed) + " land on a hazard and perish!" : "!"));
    }
    return _tossed;
}

function game_enemy_attack(_g, _p, _f) {
    var _def = enemy_def_get(_f.enemy.enemyDefId);
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
            game_log(_g, _def.name + " explodes in a + pattern!");
            var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
            for (var _o = 0; _o < array_length(_offsets); _o++) {
                var _bl = _f.lane + _offsets[_o][0];
                var _bi = _f.idx + _offsets[_o][1];
                if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi > 6) continue;
                game_fx_boom(_g, _bl, _bi);
                for (var _q = 0; _q < 2; _q++) game_kill_tokens(_g, _q, _bl, _bi, game_decoy_absorb(_g, _q, _bl, _bi, _def.damage), _def, undefined);
            }
        } else {
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
                    array_delete(_toks, _i, 1);
                    _culled += 1;
                    continue;
                }
                _tk.loc = { kind: "space", lane: _t.lane, idx: _newIdx };
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
        var _die = _g.boardDef.pelletDie;
        var _face = _die[irandom(array_length(_die) - 1)];
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
            if (enemy_def_get(_f.enemy.enemyDefId).attackElement == "swift") game_enemy_attack(_g, _p, _f);
        }
    }

    // PASS A - PIKMIN DAMAGE: every engagement's damage resolves before any
    // (non-swift) enemy responds, so explosions can't pre-empt a neighbour's attack
    if (_phase == "all" || _phase == "pik")
    for (var _fi = 0; _fi < array_length(_fights); _fi++) {
        var _f = _fights[_fi];
        if (_f.enemy.dead) continue;
        var _def = enemy_def_get(_f.enemy.enemyDefId);

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
        if (_iceCount > 0 && !_alreadyStunned) {
            var _need = ceil(_f.enemy.curHp / 2);
            if (_iceCount >= _need) {
                _iceQuota = _need;
                _f.enemy.stunned = 1;
                _f.enemy.stunnedBy = "ice";
                game_log(_g, string(_need) + " ice pikmin freeze " + _def.name + " solid - it skips its turn!");
            }
        }

        var _dmg = 0;
        var _blockedGate = false;
        var _iceUsed = 0;
        for (var _a = 0; _a < array_length(_attackers); _a++) {
            if (_attackers[_a].typeId == "ice" && _iceUsed < _iceQuota) { _iceUsed += 1; continue; } // froze instead
            var _typeDef = pikmin_type_get(_attackers[_a].typeId);
            if (_def.defenseElement == "crush" && !arr_has(_typeDef.immunities, "crush")) { _blockedGate = true; continue; }
            if (_def.defenseElement == "height" && !arr_has(_typeDef.traits, "climbs_height") && !arr_has(_typeDef.traits, "flies_over_hazards")) { _blockedGate = true; continue; }
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
        if (_dmg > 0) {
            _f.enemy.curHp -= _dmg;
            game_log(_g, "P" + string(_p + 1) + "'s pikmin hit " + _def.name + " for " + string(_dmg) + " (" + string(max(0, _f.enemy.curHp)) + " hp left).");
        } else if (_blockedGate) {
            if (_req != undefined) game_log(_g, _def.name + " shrugs off the attack (needs at least " + string(_req.count) + " " + _req.typeId + ")!");
            else game_log(_g, _def.name + " shrugs off the attack (" + _def.defenseElement + " defence).");
        }

        // suicidal defence elements: non-immune attackers die after striking
        if (_def.defenseElement != "" && _def.defenseElement != "crush" && _def.defenseElement != "height") {
            var _lostWhites = 0;
            var _lost = 0;
            var _tokens = _g.players[_p].tokens;
            var _i = 0;
            while (_i < array_length(_tokens)) {
                var _tok = _tokens[_i];
                if (game_loc_eq(_tok.loc, { kind: "space", lane: _f.lane, idx: _f.idx })
                    && !token_is_disabled(_tok) // frozen/buried pikmin didn't strike, so don't melt
                    && !arr_has(pikmin_type_get(_tok.typeId).immunities, _def.defenseElement)) {
                    if (_tok.typeId == "white") _lostWhites += 1;
                    game_fx_pik(_g, _tok, _f.lane, _f.idx);
                    array_delete(_tokens, _i, 1);
                    _lost += 1;
                    continue;
                }
                _i += 1;
            }
            if (_lost > 0) game_log(_g, string(_lost) + " pikmin perish to " + _def.name + "'s " + _def.defenseElement + " defence!");
            if (_lostWhites > 0 && _f.enemy.curHp > 0) {
                _f.enemy.curHp -= _lostWhites;
                game_log(_g, "Dying whites poison it for " + string(_lostWhites) + "!");
            }
        }

        if (_f.enemy.curHp <= 0) game_enemy_die(_g, _p, _f); // rewards immediately, per the rules
    }

    // PASS B - ENEMY DAMAGE: all surviving enemies strike simultaneously (crush
    // enemies strike even while dying). Explosions land here, alongside everything
    // else - AFTER every pikmin group has already dealt its damage.
    if (!_attackOnly && (_phase == "all" || _phase == "enemy")) {
        for (var _fi = 0; _fi < array_length(_fights); _fi++) {
            var _f = _fights[_fi];
            if (_f.enemy.attacked) continue; // swift already struck
            var _def = enemy_def_get(_f.enemy.enemyDefId);
            if (!_f.enemy.dead) game_enemy_attack(_g, _p, _f);
            else if (_def.attackElement == "crush") game_enemy_attack(_g, _p, _f); // crushes even in death
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
            var _def = enemy_def_get(_f.enemy.enemyDefId);
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
                if (_gated) game_log(_g, "The " + _sDef.name + " shrugs off P" + string(_p + 1) + "'s pikmin - wrong type to destroy it.");
                continue;
            }
            _struct.curHp -= _str;
            if (_struct.curHp <= 0) {
                _spaces[_spaceIdx].structure = undefined;
                game_log(_g, "P" + string(_p + 1) + "'s pikmin tear down the " + _sDef.name + "!");
            } else {
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
                        && !arr_has(_td.immunities, _sDef.element)
                        && !arr_has(_td.traits, "flies_over_hazards")) {
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
            var _def = enemy_def_get(_enemy.enemyDefId);
            if (_def.attackElement != "explosive") continue;
            var _inRange = false;
            var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
            for (var _o = 0; _o < array_length(_offsets) && !_inRange; _o++) {
                var _bl = _laneIdx + _offsets[_o][0];
                var _bi = _spaceIdx + _offsets[_o][1];
                if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi > 6) continue;
                if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _bl, idx: _bi })) > 0) _inRange = true;
            }
            if (_inRange) game_enemy_attack(_g, _p, { enemy: _enemy, lane: _laneIdx, idx: _spaceIdx, isBoss: false, hostT: undefined });
        }
    }
    // explosive BOSSES splash too (e.g. Man-at-Legs on a treasure pile)
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (_t.boss == undefined || _t.boss.dead || _t.boss.attacked) continue;
        var _def = enemy_def_get(_t.boss.enemyDefId);
        if (_def.attackElement != "explosive") continue;
        var _inRange = false;
        var _offsets = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
        for (var _o = 0; _o < array_length(_offsets) && !_inRange; _o++) {
            var _bl = _t.lane + _offsets[_o][0];
            var _bi = _t.idx + _offsets[_o][1];
            if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi > 6) continue;
            if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _bl, idx: _bi })) > 0) _inRange = true;
        }
        if (_inRange) game_enemy_attack(_g, _p, { enemy: _t.boss, lane: _t.lane, idx: _t.idx, isBoss: true, hostT: _t });
    }
}

// ---------- end of turn / day / game ----------

function game_end_turn(_g) {
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
        if (_g.board.lanes[_laneIdx].spaces[3].kind != "treasure") continue;
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
        array_push(_g.treasures, { cards: _pile, lane: _laneIdx, idx: 3, boss: undefined });
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
        game_log(_g, "P" + string(_p + 1) + " discards " + gather_def_get(_discardId).name + " (hand limit).");
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
    _g.dayTrack += 1;
    if (_g.dayTrack <= global.rules.dayTrackLength) return;
    _g.dayTrack = 1;
    _g.dayNumber += 1;
    if (_g.dayNumber > global.rules.days) {
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
    game_fill_enemy_spaces(_g, true); // flag the fresh arrivals so the cinematic reveals only them
    game_log(_g, "*** Day " + string(_g.dayNumber) + " begins! Pikmin return home, enemies stir anew. ***");
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
