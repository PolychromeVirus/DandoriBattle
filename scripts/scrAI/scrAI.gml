// M5/M8: heuristic AI opponent. Drives the exact same game_* API as the UI, so it
// can never cheat. ai_step() performs one visible chunk of the AI's turn.
//
// Objective: maximise the expected final DIFFERENTIAL (ai_score - opp_score), not
// the AI's own score. Orders are a candidate allocator: every pile becomes a place
// to spend strength, scored by its differential swing (advance mine + deny theirs
// from ONE positional formula), and the AI greedily fills its reserve by value-per-
// strength. A dynamic risk preference (from the current lead) makes it turtle when
// ahead, brawl when tied, and gamble+deny when behind. Combat is a gate check
// (one-shot / immune / crush) plus the enemy's reward economy - losses are ~free
// unless the AI is card-starved, because pikmin are cheap and enemies refund pellets.

function ai_step(_g) {
    global.aiDbgP = _g.activePlayer;
    switch (_g.phase) {
        case "gather": ai_gather_action(_g); break;
        case "orders": ai_do_orders(_g); break;
        case "move":   ai_do_move(_g); break;
    }
}

// ---------- gather ----------

function ai_gather_action(_g) {
    var _pl = _g.players[_g.activePlayer];
    // bodies only when genuinely thin - CARDS are the sharper weapon (the old
    // tokens<8 gate kept it pellet-locked all game and it never held disruption)
    if (array_length(_pl.tokens) < 6 && array_length(_pl.pellets) < 3) { game_gather_roll(_g); return; }
    if (array_length(_pl.hand) < 6 && irandom(3) > 0) game_gather_draw(_g);
    else game_gather_roll(_g);
}

// ---------- diagnostics ----------
// Every decision the allocator makes (and every skip, with its reason) is appended
// to ai_debug.txt in the game's save directory, so bad play can be audited.

function ai_dbg(_str) {
    // headless rollouts silence this: it opens/writes/closes the file per line,
    // which costs more than the decision it's reporting (sim_silence in scrSim)
    if (variable_global_exists("aiSilent") && global.aiSilent) return;
    // prefix which player's brain is talking (set by the ai entry points) so
    // AI-vs-AI logs stay readable
    if (_str != "" && variable_global_exists("aiDbgP")) _str = "P" + string(global.aiDbgP + 1) + "| " + _str;
    show_debug_message("[AI] " + _str);
    var _f = file_text_open_append("ai_debug.txt");
    file_text_write_string(_f, _str);
    file_text_writeln(_f);
    file_text_close(_f);
}

/// Hand-limit overflow: pick ONE discard and resolve it via game_discard_choice
/// (the controller calls this once per tick until the hand fits). Preference:
/// the weakest pellet roll first (cheapest to lose), then surplus 3rd+ copies of
/// a gather card (even Raw Material only needs a pair), then the least generally
/// useful card by a static junk ranking. Shared by v1 and v2.
function ai_resolve_discard(_g) {
    if (_g.pendingDiscard == undefined) return;
    var _p = _g.pendingDiscard.playerIdx;
    global.aiDbgP = _p;
    var _pl = _g.players[_p];
    if (array_length(_pl.pellets) > 0) {
        var _worst = 0;
        for (var _i = 1; _i < array_length(_pl.pellets); _i++) {
            if (pellet_def_get(_pl.pellets[_i]).sameTypeAmount < pellet_def_get(_pl.pellets[_worst]).sameTypeAmount) _worst = _i;
        }
        ai_dbg("HAND LIMIT: discard pellet " + _pl.pellets[_worst]);
        game_discard_choice(_g, "pellet", _worst);
        return;
    }
    var _copies = {};
    for (var _i = 0; _i < array_length(_pl.hand); _i++) {
        var _cid = _pl.hand[_i];
        _copies[$ _cid] = (variable_struct_exists(_copies, _cid) ? _copies[$ _cid] : 0) + 1;
        if (_copies[$ _cid] >= 3) {
            ai_dbg("HAND LIMIT: discard surplus copy of " + _cid);
            game_discard_choice(_g, "gather", _i);
            return;
        }
    }
    // least useful first; anything unlisted ranks as precious (keep)
    static _junkRank = ["surveydrone", "shipsignal", "warp", "phosbatpod", "captainclone",
        "oatchirush", "rockstorm", "mine", "boulder", "pikpikbundle", "icebomb", "storm",
        "bitterspray", "bombrock", "rawmaterial", "spicyspray", "candypopbud",
        "queencandypopbud", "candypopbud2", "colorchangingposy", "ivoryandviolet", "pikminextinction"];
    var _best = 0, _bestRank = 999;
    for (var _i = 0; _i < array_length(_pl.hand); _i++) {
        for (var _j = 0; _j < array_length(_junkRank); _j++) {
            if (_junkRank[_j] == _pl.hand[_i]) { if (_j < _bestRank) { _bestRank = _j; _best = _i; } break; }
        }
    }
    ai_dbg("HAND LIMIT: discard " + _pl.hand[_best]);
    game_discard_choice(_g, "gather", _best);
}

/// Onion cull: at the token cap with pellets waiting to be redeemed, home tokens of
/// DEAD-WEIGHT colours (no pile / boss / first-blocker on the whole board is a legal
/// destination for them) are dismissed to free cap space for better bodies. Purples,
/// whites and bulbmin never count as dead weight (always-useful / cap-free), and the
/// caller skips the cull entirely while Ivory & Violet is in hand (chaff = purple
/// fodder). Shared by v1 and v2.
function ai_cull_deadweight(_g, _p) {
    var _home = game_counts_struct(_g, _p, { kind: "home" });
    var _cols = variable_struct_get_names(_home);
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _typeId = _cols[_c];
        if (_home[$ _typeId] <= 0) continue;
        if (_typeId == "purple" || _typeId == "white" || _typeId == "bulbmin") continue;
        var _useful = false;
        for (var _ti = 0; _ti < array_length(_g.treasures) && !_useful; _ti++) {
            var _t = _g.treasures[_ti];
            if (array_length(_t.cards) == 0) continue;
            var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
            var _idx = (_blk != undefined) ? _blk.idx : _t.idx;
            if (game_dest_legal(_g, _p, _typeId, _t.lane, _idx)) _useful = true;
        }
        if (_useful) continue;
        var _cull = {};
        _cull[$ _typeId] = _home[$ _typeId];
        var _n = game_order_discard(_g, { kind: "home" }, _cull);
        if (_n > 0) ai_dbg("ONION: dismissed " + string(_n) + " dead-weight " + _typeId + " (no reachable target on the board)");
    }
}

// ---------- helpers ----------

function ai_pile_raw(_t) {
    var _v = 0;
    for (var _c = 0; _c < array_length(_t.cards); _c++) _v += treasure_def_get(_t.cards[_c]).value;
    return _v;
}

function ai_hand_has(_g, _p, _cardId) {
    var _hand = _g.players[_p].hand;
    for (var _i = 0; _i < array_length(_hand); _i++) {
        if (_hand[_i] == _cardId) return true;
    }
    return false;
}

function ai_home_strength(_g, _p) {
    var _sum = 0;
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (_tokens[_i].loc.kind == "home") _sum += pikmin_type_get(_tokens[_i].typeId).carry;
    }
    return _sum;
}

/// What this pile is actually WORTH to player _p under set-collection scoring:
/// realized score with the pile minus realized score without it. A pile of set
/// pieces from a series _p has 2 of is worth far more than one full of strangers.
function ai_pile_marginal(_g, _p, _t) {
    var _base = game_realized_score(_g, _p);
    var _hypo = [];
    var _coll = _g.players[_p].collected;
    for (var _i = 0; _i < array_length(_coll); _i++) array_push(_hypo, _coll[_i]);
    for (var _i = 0; _i < array_length(_t.cards); _i++) array_push(_hypo, _t.cards[_i]);
    // account for this player's persistent Wild / Glow Up hoard passives in the hypothetical too
    var _pl = _g.players[_p];
    var _wild = variable_struct_exists(_pl, "wildCount") ? _pl.wildCount : 0;
    var _glow = variable_struct_exists(_pl, "glowUp") ? _pl.glowUp : false;
    return game_treasures_realized(_hypo, _wild, _glow) - _base;
}

function ai_type_can_hurt(_typeId, _enemyDef) {
    // "must be attacked by at least N <type>": approximate as only that type hurts it
    // (a group with the quota all counts, but this steers the right pikmin there)
    var _req = game_attack_requirement(_enemyDef);
    if (_req != undefined) return (_typeId == _req.typeId);
    var _typeDef = pikmin_type_get(_typeId);
    if (_enemyDef.defenseElement == "crush") return arr_has(_typeDef.immunities, "crush");
    if (_enemyDef.defenseElement == "height") return arr_has(_typeDef.immunities, "height");
    return true;
}

function ai_type_survives_defense(_typeId, _enemyDef) {
    var _d = _enemyDef.defenseElement;
    if (_d == "" || _d == "crush" || _d == "height") return true;
    return arr_has(pikmin_type_get(_typeId).immunities, _d);
}

function ai_type_immune_attack(_typeId, _enemyDef) {
    var _a = _enemyDef.attackElement;
    if (_a == "" || _a == "swift" || _a == "explosive" || _a == "crush") return false;
    return arr_has(pikmin_type_get(_typeId).immunities, _a);
}

/// Which colour to grow: roster scarcity, plus how much THIS board wants the
/// colour - immunities matching the map's hazard/emitter elements keep lanes
/// reachable (the #1 cause of "no reachable strength"), carry breaks ties.
function ai_pick_growth_color(_g, _p) {
    var _cols = _g.boardDef.basicColors;
    // how often each element gates a space right now (map hazards + live emitters)
    var _elemCounts = {};
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        var _spaces = _g.board.lanes[_laneIdx].spaces;
        for (var _si = 0; _si < array_length(_spaces); _si++) {
            var _sp = _spaces[_si];
            var _el = "";
            if (_sp.kind == "hazard" && _sp.hazard != "" && _sp.hazard != "height" && _sp.hazard != "chasm" && _sp.hazard != "poison") _el = _sp.hazard;
            if (_sp.structure != undefined) {
                var _sd = hazard_def_get(_sp.structure.structId);
                if (_sd.type == "hazard" && _sd.element != "" && _sd.element != "poison") _el = _sd.element;
            }
            if (_el != "") _elemCounts[$ _el] = (variable_struct_exists(_elemCounts, _el) ? _elemCounts[$ _el] : 0) + 1;
        }
    }
    // combat demands: requirement enemies (need N of a type) and crush/height gates
    // standing on the board lock lanes until we OWN the answer - weight those types
    var _demand = {};
    var _addDemand = function(_d, _k, _v) { _d[$ _k] = (variable_struct_exists(_d, _k) ? _d[$ _k] : 0) + _v; };
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        for (var _si = 0; _si <= 6; _si++) {
            var _en = _g.board.lanes[_laneIdx].spaces[_si].enemy;
            if (_en == undefined || _en.dead) continue;
            var _ed = enemy_def_get(_en.enemyDefId);
            // height is the ONLY hit-gate (all kill damage must be yellow/winged).
            // crush/stab are ATTACK elements: anyone can hurt those enemies, but
            // non-rocks are guaranteed losses (crush strikes even in death) - rocks
            // no-sell it, so they're the economical answer, not a requirement.
            var _rq = game_attack_requirement(_ed);
            if (_rq != undefined) _addDemand(_demand, _rq.typeId, 4);
            if (_ed.defenseElement == "height") { _addDemand(_demand, "yellow", 4); _addDemand(_demand, "winged", 4); }
            if (_ed.attackElement == "crush") _addDemand(_demand, "rock", 3);
            else if (_ed.attackElement == "stab") _addDemand(_demand, "rock", 2);
        }
    }
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _tb = _g.treasures[_ti].boss;
        if (_tb == undefined || _tb.dead) continue;
        var _bd = enemy_def_get(_tb.enemyDefId);
        var _brq = game_attack_requirement(_bd);
        if (_brq != undefined) _addDemand(_demand, _brq.typeId, 4);
        if (_bd.defenseElement == "height") { _addDemand(_demand, "yellow", 4); _addDemand(_demand, "winged", 4); }
        if (_bd.attackElement == "crush") _addDemand(_demand, "rock", 3);
        else if (_bd.attackElement == "stab") _addDemand(_demand, "rock", 2);
    }
    var _best = _cols[0];
    var _bestScore = -99999;
    var _tokens = _g.players[_p].tokens;
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _colId = _cols[_c];
        var _n = 0;
        for (var _i = 0; _i < array_length(_tokens); _i++) {
            if (_tokens[_i].typeId == _colId) _n += 1;
        }
        var _td = pikmin_type_get(_colId);
        var _score = -_n * 2 + _td.carry; // scarcity first, heavy lifters as tiebreak
        for (var _im = 0; _im < array_length(_td.immunities); _im++) {
            if (variable_struct_exists(_elemCounts, _td.immunities[_im])) _score += 2 * _elemCounts[$ _td.immunities[_im]];
        }
        if (variable_struct_exists(_demand, _colId)) _score += _demand[$ _colId];
        if (_score > _bestScore) { _bestScore = _score; _best = _colId; }
    }
    return _best;
}

/// Strength needed to actually KILL an enemy. Swift strikes FIRST (its combat
/// section runs before the pikmin section), so its damage eats attackers before
/// they ever swing - a kill needs hp worth of SURVIVORS, not just hp worth of
/// bodies. (This is the opposite of crush, which strikes even while dying but
/// AFTER your damage lands.)
function ai_enemy_req(_g, _p, _def, _curHp) {
    if (_def.attackElement != "swift") return _curHp;
    // whites eaten by the first strike poison it back (1 revenge each) - they count
    // as damage WHILE being the meal, so each white at home discounts the soak.
    // (1 white kills a 1/1 larva outright: eaten -> revenge -> dead.)
    var _whites = 0;
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) {
        if (_toks[_i].loc.kind == "home" && _toks[_i].typeId == "white") _whites += 1;
    }
    return _curHp + max(0, _def.damage - min(_whites, _def.damage));
}

/// Move up to _needStrength of carry strength from HOME to a space, choosing
/// colours by matchup quality. _dryRun just reports what could be sent.
/// _surviveDefense: only send colours that survive striking the target's
/// suicide-defence element (for clean kills on Goolix-likes and emitters).
/// _noRedDouble: don't credit red's 2nd-strike (for a CLEAN, no-loss kill the hit must land in the
/// first pass, so red-2x - which needs the red to survive to swing again - can't be relied on).
/// _allowedCols: restrict the squad to these colours (v4 resource designation - a rush plan must
/// not be funded with purple, an all-white plan only with whites).
function ai_send(_g, _p, _lane, _idx, _needStrength, _enemyDef, _dryRun = false, _surviveDefense = false, _noRedDouble = false, _allowedCols = undefined) {
    if (_needStrength <= 0) return 0;
    var _homeLoc = { kind: "home" };
    var _homeCounts = game_counts_struct(_g, _p, _homeLoc);
    var _cols = variable_struct_get_names(_homeCounts);
    var _cands = [];
    // "must be attacked by at least N <type>": once the quota is met the WHOLE group
    // counts - so send the quota of the required colour and fill with anything (the
    // old per-colour filter demanded an all-required squad and paralysed those lanes)
    var _reqm = (_enemyDef != undefined) ? game_attack_requirement(_enemyDef) : undefined;
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _colId = _cols[_c];
        if (_allowedCols != undefined && !arr_has(_allowedCols, _colId)) continue;
        if (!game_dest_legal(_g, _p, _colId, _lane, _idx)) continue;
        if (_enemyDef != undefined && _reqm == undefined && !ai_type_can_hurt(_colId, _enemyDef)) continue;
        if (_surviveDefense && _enemyDef != undefined && !ai_type_survives_defense(_colId, _enemyDef)) continue;
        var _score = pikmin_type_get(_colId).carry; // prefer heavy lifters for tugs
        var _eff = pikmin_type_get(_colId).carry;   // strength toward the requirement
        if (_reqm != undefined && _colId == _reqm.typeId) _score += 99; // quota colour goes first
        if (_enemyDef != undefined) {
            if (ai_type_immune_attack(_colId, _enemyDef)) _score += 4;
            if (ai_type_survives_defense(_colId, _enemyDef)) _score += 3;
            // red 2nd strike: vs real enemies a red deals damage twice per combat
            if (global.expRules.red && _colId == "red" && _enemyDef.id != "emitterstruct" && !_noRedDouble) { _eff *= 2; _score += 3; }
            // whites vs swift: the first strike eats them and eats poison - the meal
            // fights back, so whites are the cheapest possible swift answer
            if (_enemyDef.attackElement == "swift" && _colId == "white") _score += 5;
        }
        array_push(_cands, { colId: _colId, score: _score, carry: _eff, count: _homeCounts[$ _colId] });
    }
    for (var _a = 1; _a < array_length(_cands); _a++) {
        var _tmp = _cands[_a];
        var _b = _a - 1;
        while (_b >= 0 && _cands[_b].score < _tmp.score) { _cands[_b + 1] = _cands[_b]; _b -= 1; }
        _cands[_b + 1] = _tmp;
    }
    // requirement targets: without the quota of the required colour AT HOME and able
    // to path there, nothing the group does will land - report zero reach
    if (_reqm != undefined) {
        var _reqOk = false;
        for (var _c = 0; _c < array_length(_cands); _c++) {
            if (_cands[_c].colId == _reqm.typeId && _cands[_c].count >= _reqm.count) { _reqOk = true; break; }
        }
        if (!_reqOk) return 0;
    }
    var _counts = {};
    var _sent = 0;
    for (var _c = 0; _c < array_length(_cands) && _sent < _needStrength; _c++) {
        var _take = min(_cands[_c].count, ceil((_needStrength - _sent) / _cands[_c].carry));
        if (_take <= 0) continue;
        _counts[$ _cands[_c].colId] = _take;
        _sent += _take * _cands[_c].carry;
    }
    if (_sent > 0 && !_dryRun) {
        game_order_move(_g, _homeLoc, { kind: "space", lane: _lane, idx: _idx }, _counts);
    }
    return _sent;
}

// ---------- orders: differential-swing candidate allocator ----------

function ai_progress_to_me(_p, _idx) {
    return (_p == 0) ? (6 - _idx) / 6 : _idx / 6;
}

/// Value of an enemy's death rewards as economy (pellets -> pikmin, gather cards).
function ai_reward_value(_enemyDef) {
    return _enemyDef.reward.pellets * 6 + _enemyDef.reward.gather * 4;
}

/// Replacement capacity -> scarcity [0,1]. 0 = flush (losses are free), 1 = starved.
function ai_scarcity(_g, _p) {
    var _pl = _g.players[_p];
    var _cap = array_length(_pl.pellets) * 3 + array_length(_pl.hand) * 2 + 4; // +4 expected gather income
    return clamp(1 - _cap / 12, 0, 1);
}

/// Dynamic risk from the score differential + time. <0 turtle (protect lead),
/// ~0 aggressive, >0 gamble (behind -> seek variance).
function ai_risk_pref(_g, _p) {
    var _lead = game_realized_score(_g, _p) - game_realized_score(_g, 1 - _p);
    var _inPlay = 0;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        _inPlay += max(ai_pile_marginal(_g, _p, _g.treasures[_ti]), ai_pile_marginal(_g, 1 - _p, _g.treasures[_ti]));
    }
    _inPlay = max(_inPlay, 150);
    var _totalRounds = global.rules.days * global.rules.dayTrackLength;
    var _curRound = (_g.dayNumber - 1) * global.rules.dayTrackLength + _g.dayTrack;
    var _timeUrg = clamp(_curRound / max(1, _totalRounds), 0, 1);
    return clamp(-(_lead / _inPlay) * (0.8 + _timeUrg), -1, 1);
}

function ai_can_group_hurt(_g, _p, _enemyDef) {
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (ai_type_can_hurt(_tokens[_i].typeId, _enemyDef)) return true;
    }
    return false;
}

function ai_can_free_chip(_g, _p, _enemyDef) {
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tid = _tokens[_i].typeId;
        if (ai_type_can_hurt(_tid, _enemyDef) && ai_type_immune_attack(_tid, _enemyDef)) return true;
    }
    return false;
}

/// Can anything the AI owns damage this structure (crystal wall needs rock, etc.)?
function ai_can_damage_struct(_g, _p, _structId) {
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        if (struct_type_can_damage(_tokens[_i].typeId, _structId)) return true;
    }
    return false;
}

/// Can any AI-owned colour pass this emitter (poison is free; others need immunity)?
function ai_emitter_passable(_g, _p, _sDef) {
    if (_sDef.element == "poison") return true;
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _td = pikmin_type_get(_tokens[_i].typeId);
        if (arr_has(_td.immunities, _sDef.element) || arr_has(_td.traits, "flies_over_hazards")) return true;
    }
    return false;
}

/// First HARD blocker between the AI's home edge and _targetIdx (skips passable
/// poison/immune emitters and bridges). Returns {kind, idx, enemy?, hp?} or undefined.
function ai_first_blocker(_g, _p, _lane, _targetIdx) {
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    while (_s != _targetIdx) {
        var _space = _g.board.lanes[_lane].spaces[_s];
        if (_space.enemy != undefined) return { kind: "enemy", idx: _s, enemy: _space.enemy };
        if (_space.structure != undefined) {
            var _sDef = hazard_def_get(_space.structure.structId);
            if (_sDef.type == "wall") return { kind: "structure", idx: _s, hp: _space.structure.curHp };
            if (_sDef.type == "hazard" && !ai_emitter_passable(_g, _p, _sDef)) return { kind: "structure", idx: _s, hp: _space.structure.curHp };
        }
        if (game_treasure_at(_g, _lane, _s) != undefined) return { kind: "treasure", idx: _s };
        _s += _dir;
    }
    return undefined;
}

/// Plan the AI's orders phase: economy (pellets/posy), recall idle tokens, then
/// build + sort the deployment candidates. Returns {cands, risk, scarce, idx} which
/// the paced driver (ai_do_orders) then commits one at a time, one per tick.
function ai_orders_plan(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];

    // --- economy preamble: redeem pellets, play posy ---
    // capped with pellets in hand: dismiss dead-weight colours to the Onion first
    // (skip while Ivory & Violet is held - chaff there is purple fodder instead)
    if (game_capped_count(_g, _p) >= global.rules.pikminBoardCap
        && array_length(_pl.pellets) > 0 && !arr_has(_pl.hand, "ivoryandviolet")) {
        ai_cull_deadweight(_g, _p);
    }
    var _guard = 0;
    while (array_length(_pl.pellets) > 0 && game_capped_count(_g, _p) < global.rules.pikminBoardCap && _guard < 40) {
        _guard += 1;
        var _pDef = pellet_def_get(_pl.pellets[0]);
        var _col = arr_has(_g.boardDef.basicColors, _pDef.color) ? _pDef.color : ai_pick_growth_color(_g, _p);
        game_play_pellet(_g, 0, _col);
    }
    var _hi = 0;
    while (_hi < array_length(_pl.hand)) {
        if (_pl.hand[_hi] == "colorchangingposy" && game_capped_count(_g, _p) <= global.rules.pikminBoardCap - 3) {
            if (game_play_gather(_g, _hi, { color: ai_pick_growth_color(_g, _p) })) continue;
        }
        _hi += 1;
    }

    // recall idle tokens (on a space with nothing to do) back to HOME. Frozen or
    // snitchbug-stunned tokens can't move, so they stay put (same lock the human
    // move API enforces).
    var _tokens = _pl.tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        var _loc = _tok.loc;
        if (_loc.kind != "space") continue;
        if (token_is_frozen(_tok)) continue;
        if (variable_struct_exists(_tok, "stunned") && _tok.stunned > 0) continue;
        if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue; // trapped, can't retreat
        var _sp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
        if (_sp.enemy == undefined && _sp.structure == undefined && game_treasure_at(_g, _loc.lane, _loc.idx) == undefined) {
            _tok.loc = { kind: "home" };
        }
    }

    // --- dynamic risk from the differential ---
    var _risk = ai_risk_pref(_g, _p);
    var _scarce = ai_scarcity(_g, _p);
    ai_dbg("");
    ai_dbg("===== TURN P" + string(_p + 1) + "  Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength)
        + ")  score " + string(game_realized_score(_g, _p)) + " vs " + string(game_realized_score(_g, 1 - _p))
        + "  risk=" + string(_risk) + "  scarcity=" + string(_scarce) + "  homeStr=" + string(ai_home_strength(_g, _p)) + " =====");

    // --- build candidates ---
    var _cands = [];
    var _seen = {}; // "lane_idx" -> true, so cleaning doesn't duplicate lane targets

    // (A) pile-driven: each treasure contributes its pile, its boss, or its first hard blocker
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        // option value: dead set pieces still progress a series, so a pile is never
        // worth less than a fraction of its raw poko
        var _raw = ai_pile_raw(_t);
        var _wAi = max(ai_pile_marginal(_g, _p, _t), _raw * 0.30);
        var _wOpp = max(ai_pile_marginal(_g, 1 - _p, _t), _raw * 0.30);
        var _progMe = ai_progress_to_me(_p, _t.idx);
        var _ctrl = _wAi * _progMe + _wOpp * (1 - _progMe);   // value of controlling this pile
        var _varf = 1 - _progMe;                              // deeper toward opp = higher variance
        var _adj = _ctrl * clamp(1 + _risk * _varf, 0.15, 2.2);

        // path check FIRST: a bossed pile behind a blocker means the BLOCKER is the
        // real target this turn - otherwise the lane paralyses ("no reachable strength")
        var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
        if (_t.boss != undefined && _blk == undefined) {
            var _bDef = enemy_def_get(_t.boss.enemyDefId);
            if (ai_can_group_hurt(_g, _p, _bDef)) {
                _seen[$ string(_t.lane) + "_" + string(_t.idx)] = true;
                array_push(_cands, { lane: _t.lane, idx: _t.idx, req: ai_enemy_req(_g, _p, _bDef, _t.boss.curHp), value: _adj + ai_reward_value(_bDef), enemyDef: _bDef, kind: "boss", oppS: 0, myS: 0, why: "boss " + _bDef.name + " over " + string(_raw) + "p pile" });
            } else {
                ai_dbg("cand SKIP lane" + string(_t.lane + 1) + " boss " + _bDef.name + ": nothing we own can hurt it");
            }
            continue;
        }

        if (_blk == undefined) {
            var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
            var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
            var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
            // win NOW needs oppS+1 - but a bare-minimum grab is flipped back for free,
            // so always hold a small margin against their reachable reinforcements
            // (bigger cushion when turtling; their full reserve is a risk term, not a req)
            // their possible response = home reserve THAT can path here, plus their
            // tokens already standing in this lane (they can re-order onto the pile
            // next turn) - during our turn their reserve is usually deployed, so the
            // old home-only check read 0 and every grab was left flippable
            var _oppReach = ai_send(_g, 1 - _p, _t.lane, _t.idx, 99, undefined, true);
            var _oppLane = 0;
            var _otoks = _g.players[1 - _p].tokens;
            for (var _oi = 0; _oi < array_length(_otoks); _oi++) {
                if (_otoks[_oi].loc.kind == "space" && _otoks[_oi].loc.lane == _t.lane) _oppLane += pikmin_type_get(_otoks[_oi].typeId).carry;
            }
            _oppLane = max(0, _oppLane - _oppS); // those already at the pile are counted in oppS
            var _margin = min(max(_oppReach, _oppLane), (_risk < -0.1) ? 3 : 2);
            // SPEED value: a light pile is fast income (fewer bodies committed for
            // fewer turns); heavy piles eat the reserve and haul slowly. Many light
            // treasures usually beat one long war over a big one.
            _adj *= clamp(8 / (4 + _w), 0.65, 1.5);
            var _req = max(_w, _oppS + 1 + _margin) - _myS;
            if (_req > 0) {
                _seen[$ string(_t.lane) + "_" + string(_t.idx)] = true;
                array_push(_cands, { lane: _t.lane, idx: _t.idx, req: _req, value: _adj, enemyDef: undefined, kind: "pile", oppS: _oppS, myS: _myS, w: _w, why: string(_raw) + "p pile idx" + string(_t.idx) + " oppS=" + string(_oppS) + " margin=" + string(_margin) });
            }
        } else if (_blk.kind == "enemy") {
            var _eDef = enemy_def_get(_blk.enemy.enemyDefId);
            if (ai_can_group_hurt(_g, _p, _eDef)) {
                _seen[$ string(_t.lane) + "_" + string(_blk.idx)] = true;
                array_push(_cands, { lane: _t.lane, idx: _blk.idx, req: ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp), value: _adj * 0.7 + ai_reward_value(_eDef), enemyDef: _eDef, kind: "enemy", oppS: 0, myS: 0, why: "blocker " + _eDef.name + " (" + string(_eDef.damage) + "/" + string(_blk.enemy.curHp) + ") guards " + string(_raw) + "p" });
            } else {
                ai_dbg("cand SKIP lane" + string(_t.lane + 1) + " blocker " + _eDef.name + ": can't hurt it");
            }
        } else if (_blk.kind == "structure") {
            _seen[$ string(_t.lane) + "_" + string(_blk.idx)] = true;
            var _sSp = _g.board.lanes[_t.lane].spaces[_blk.idx];
            var _sD = hazard_def_get(_sSp.structure.structId);
            if (!ai_can_damage_struct(_g, _p, _sSp.structure.structId)) {
                ai_dbg("cand SKIP lane" + string(_t.lane + 1) + " " + _sD.name + ": nothing we own can damage it");
            } else {
                // emitters bite back via their element: model them as a 0-damage enemy
                // with that defence so colour selection & free-kill logic apply
                var _pseudo = (_sD.type == "hazard" && _sD.element != "")
                    ? { id: "emitterstruct", attackElement: "", defenseElement: _sD.element, damage: 0, reward: { pellets: 0, gather: 0 } }
                    : undefined;
                array_push(_cands, { lane: _t.lane, idx: _blk.idx, req: _blk.hp, value: _adj * 0.55, enemyDef: _pseudo, kind: "structure", oppS: 0, myS: 0, why: "structure " + _sD.name + " blocks " + string(_raw) + "p lane" });
            }
        }
    }

    // (B) CLEANING: everything cluttering OUR side is a target on its own merits -
    // rewards now, decision space later. Never fully off (paralysed lanes are worse
    // than "wasted" cleanup), just discounted when the game is lopsided.
    {
        var _sideLo = (_p == 0) ? 0 : 4;
        var _sideHi = (_p == 0) ? 2 : 6;
        var _clutter = 0;
        for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
            for (var _si = _sideLo; _si <= _sideHi; _si++) {
                var _sp = _g.board.lanes[_laneIdx].spaces[_si];
                if (_sp.enemy != undefined) _clutter += 1;
                else if (_sp.structure != undefined && hazard_def_get(_sp.structure.structId).type != "bridge") _clutter += 1;
            }
        }
        var _cleanBonus = (6 + _clutter * 3) * (1 - 0.5 * min(abs(_risk), 1));
        for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
            for (var _si = _sideLo; _si <= _sideHi; _si++) {
                var _key = string(_laneIdx) + "_" + string(_si);
                if (variable_struct_exists(_seen, _key)) continue;
                var _sp = _g.board.lanes[_laneIdx].spaces[_si];
                if (_sp.enemy != undefined) {
                    var _eDef = enemy_def_get(_sp.enemy.enemyDefId);
                    if (!ai_can_group_hurt(_g, _p, _eDef)) continue;
                    array_push(_cands, { lane: _laneIdx, idx: _si, req: ai_enemy_req(_g, _p, _eDef, _sp.enemy.curHp), value: ai_reward_value(_eDef) + _cleanBonus, enemyDef: _eDef, kind: "clean", oppS: 0, myS: 0, why: "clean " + _eDef.name + " (" + string(_eDef.damage) + "/" + string(_sp.enemy.curHp) + ") off our side" });
                } else if (_sp.structure != undefined && hazard_def_get(_sp.structure.structId).type != "bridge") {
                    if (!ai_can_damage_struct(_g, _p, _sp.structure.structId)) continue;
                    var _sD2 = hazard_def_get(_sp.structure.structId);
                    var _pseudo2 = (_sD2.type == "hazard" && _sD2.element != "")
                        ? { id: "emitterstruct", attackElement: "", defenseElement: _sD2.element, damage: 0, reward: { pellets: 0, gather: 0 } }
                        : undefined;
                    array_push(_cands, { lane: _laneIdx, idx: _si, req: _sp.structure.curHp, value: _cleanBonus * 0.7, enemyDef: _pseudo2, kind: "clean", oppS: 0, myS: 0, why: "clean " + _sD2.name + " off our side" });
                }
            }
        }
    }

    // FOCUS: concentrate on the couple of most EFFICIENT pile campaigns (value per
    // effort = value / (bodies needed + haul weight)) instead of spreading thin or
    // fixating on the biggest number. Leftovers still roll to the other lanes.
    var _f1 = -1, _f2 = -1, _e1 = 0, _e2 = 0;
    for (var _a = 0; _a < array_length(_cands); _a++) {
        if (_cands[_a].kind != "pile") continue;
        var _effv = _cands[_a].value / max(1, _cands[_a].req + _cands[_a].w);
        if (_effv > _e1) { _f2 = _f1; _e2 = _e1; _f1 = _a; _e1 = _effv; }
        else if (_effv > _e2) { _f2 = _a; _e2 = _effv; }
    }
    if (_f1 >= 0) { _cands[_f1].value *= 1.35; _cands[_f1].why += " [FOCUS]"; }
    if (_f2 >= 0) { _cands[_f2].value *= 1.2; _cands[_f2].why += " [focus2]"; }

    // PILES FIRST (by value), then combat targets by value-per-strength. Piles win
    // the game; kills only enable them - the old pure-ratio order burned the whole
    // reserve on cheap blockers and left every actual tug "insufficient".
    for (var _a = 0; _a < array_length(_cands); _a++) {
        _cands[_a].ratio = _cands[_a].value / max(1, _cands[_a].req);
        _cands[_a].sortKey = (_cands[_a].kind == "pile") ? 1000000 + _cands[_a].value : _cands[_a].ratio;
    }
    for (var _a = 1; _a < array_length(_cands); _a++) {
        var _tmp = _cands[_a];
        var _b = _a - 1;
        while (_b >= 0 && _cands[_b].sortKey < _tmp.sortKey) { _cands[_b + 1] = _cands[_b]; _b -= 1; }
        _cands[_b + 1] = _tmp;
    }

    return { cands: _cands, risk: _risk, scarce: _scarce, idx: 0 };
}

/// Commit ONE orders candidate (the value-per-strength greedy fill, split out so the
/// controller can pace deployments one per tick). Returns true if it actually sent
/// pikmin, so the pacing consumes a visible tick only on a real move.
function ai_orders_commit(_g, _c, _risk, _scarce) {
    var _p = _g.activePlayer;
    {
        var _tag = "cand[" + _c.kind + " lane" + string(_c.lane + 1) + " idx" + string(_c.idx) + " v=" + string(round(_c.value)) + " req=" + string(_c.req) + " ratio=" + string(_c.ratio) + "] " + _c.why + " -> ";
        if (_c.value <= 0) { ai_dbg(_tag + "SKIP value<=0"); return false; }
        var _reach = ai_send(_g, _p, _c.lane, _c.idx, _c.req, _c.enemyDef, true);
        if (_reach <= 0) { ai_dbg(_tag + "SKIP no reachable strength"); return false; }
        var _commit = false;
        var _sendReq = _c.req;
        var _reason = "";
        var _safeOnly = false;
        if (_c.kind == "pile") {
            if (_reach >= _c.req) {
                _commit = true; _reason = "take/hold control";
                // rush rule: overstack to 2x the pile's weight for the double-speed
                // carry (engine denies it if a purple tags along - still holds harder)
                // v3 candidates carry `presized` - ai3_advance_commit already decided the
                // stack (breadth min-win vs depth 2x), so don't re-apply the overstack here.
                if (global.expRules.rush && variable_struct_exists(_c, "w") && _c.oppS < _c.w
                    && !(variable_struct_exists(_c, "presized") && _c.presized)) {
                    var _rushReq = _c.w * 2 - _c.myS;
                    if (_rushReq > _sendReq && _reach >= _rushReq) { _sendReq = _rushReq; _reason = "take + RUSH overstack"; }
                }
            }
            else if (_risk > -0.1 && _c.oppS > _c.myS && _reach >= (_c.oppS - _c.myS)) {
                // can't win the tug, but TYING stalls their carry - worth it whenever
                // we're not comfortably ahead
                _sendReq = _c.oppS - _c.myS; _commit = true; _reason = "stall their carry";
            } else _reason = "insufficient (reach " + string(_reach) + "/" + string(_c.req) + ")";
        } else {
            // combat. "Dies first" is only FREE when nothing bites back anyway:
            //  - swift hits before our damage, crush hits even while dying
            //  - suicide-defence (incl. emitters) kills non-immune attackers even on a kill
            var _eDef = _c.enemyDef;
            var _atk = (_eDef != undefined) ? _eDef.attackElement : "";
            var _defEl = (_eDef != undefined) ? _eDef.defenseElement : "";
            var _suicidal = (_defEl != "" && _defEl != "crush" && _defEl != "height");
            if (_suicidal) {
                // can a defence-immune squad do the job on its own?
                var _safeReach = ai_send(_g, _p, _c.lane, _c.idx, _c.req, _eDef, true, true);
                if (_safeReach >= min(_c.req, _reach)) { _safeOnly = true; _reach = _safeReach; }
            }
            var _paysEntry = (_atk == "swift") || (_atk == "crush");   // unavoidable hit even on a kill
            var _paysDef = _suicidal && !_safeOnly;                     // attackers melt to its defence
            // sim policy "numbers": preserve the roster - take ONLY the free kills
            // (dies-before-it-strikes / 0-damage whittle / immune chip) and refuse
            // every branch below that spends bodies, however good the price. The
            // three gated branches are exactly the ones that trade pikmin for value.
            var _polC = sim_policy_get(_g, _p);
            var _noLoss = (_polC != undefined && _polC.kind == "numbers");
            if (_atk == "swift" && _reach <= _eDef.damage) {
                // SWIFT strikes FIRST: a squad no bigger than its damage is eaten
                // whole before it ever swings - zero progress, pure feed. Never.
                _reason = "swift eats the whole squad (reach " + string(_reach) + " <= dmg " + string(_eDef.damage) + ")";
            } else if (_reach >= _c.req && !_paysEntry && !_paysDef) {
                _commit = true; _reason = _safeOnly ? "clean one-shot (defence-immune squad)" : "one-shot, dies before it strikes (free)";
            } else if (_eDef != undefined && _eDef.damage == 0 && !_paysDef) {
                _commit = true; _reason = "0-damage target, whittle for free";
            } else if (_eDef != undefined && !_paysDef && !_paysEntry && ai_can_free_chip(_g, _p, _eDef)) {
                _commit = true; _reason = "immune chip";
            } else if (_noLoss) {
                _reason = "[numbers] won't spend bodies on it";
            } else if (_polC != undefined && _polC.kind == "planner" && _c.kind == "enemy"
                && _reach < _c.req && !_paysDef && _reach > 0
                && (_c.req - _reach) <= max(0, _reach - ((_eDef != undefined) ? _eDef.damage : 0)) * 2) {
                // INVESTMENT DENT (planner, user rule 2026-07-17; auction-native in
                // v4): a partial hit on a ROAD-BLOCKER (kind "enemy" candidates
                // exist only when clearing them opens a valuable pile - "opens
                // swing X") commits when the REMAINDER is predicted killable within
                // ~2 turns (survivors swing again). A 1-dmg chip qualifies if 1 is
                // all that stands between the enemy and next-turn kill range. Blind
                // dribble stays banned: cleanup ("clean"), unpayable remainders,
                // and suicide-defence targets all fall through to PASS.
                _commit = true; _reason = "investment dent (rem " + string(_c.req - _reach) + " killable in ~2t)";
            } else if (_reach >= _c.req && (_scarce < 0.75 || _risk > 0.2)) {
                _commit = true; _reason = "one-shot but pays " + (_paysEntry ? _atk + " hit" : _defEl + " defence") + " (replaceable)";
            } else if (_reach >= _c.req && _c.req <= 4 && _scarce < 0.9) {
                _commit = true; _reason = "cheap kill";
            } else if (_c.kind == "boss" && _reach >= _c.req * 0.6 && (_scarce < 0.75 || _risk > 0.2)) {
                // bosses usually can't be one-shot; a siege share must still be big
                // enough to finish within ~2 rounds or it's a pikmin shredder
                _commit = true; _reason = "boss siege (meaningful share)";
            } else {
                // CONCENTRATE: never wound a damaging enemy we can't FINISH. Normal
                // enemies that die in the pikmin pass never strike back, so a full
                // one-shot is FREE while a chip war pays retaliation every round -
                // spreading small squads across lanes is how the early economy dies.
                // The reserve rolls to the next candidate instead of feeding this one.
                _reason = "won't wound what it can't kill (reach " + string(_reach) + "/" + string(_c.req) + ")";
            }
        }
        if (_commit) {
            var _sent = ai_send(_g, _p, _c.lane, _c.idx, _sendReq, _c.enemyDef, false, _safeOnly);
            ai_dbg(_tag + "COMMIT (" + _reason + ") sent=" + string(_sent) + "/" + string(_sendReq) + (_safeOnly ? " [defence-immune only]" : ""));
            return _sent > 0;
        } else {
            ai_dbg(_tag + "PASS (" + _reason + ")");
            return false;
        }
    }
}

/// Close out the orders phase: dump any leftover reserve, then advance to move.
function ai_orders_finish(_g, _plan) {
    var _p = _g.activePlayer;
    var _cands = _plan.cands;
    // never hoard: dump leftover reserve onto the best remaining target - but never
    // feed pikmin into a tug we can't even TIE (they'd just ride along, helping nobody)
    var _leftover = ai_home_strength(_g, _p);
    // sim policy "numbers": without this the dump would feed leftovers straight into
    // the fight the commit ladder just refused, and the policy would leak bodies out
    // the back. Leftovers reinforce piles only.
    var _polF = sim_policy_get(_g, _p);
    var _noLossF = (_polF != undefined && _polF.kind == "numbers");
    if (_leftover >= 6) {
        for (var _ci = 0; _ci < array_length(_cands); _ci++) {
            var _dc = _cands[_ci];
            if (_dc.value <= 0) continue;
            if (_noLossF && _dc.kind != "pile") continue;
            if (_dc.kind == "pile") {
                var _dryReach = ai_send(_g, _p, _dc.lane, _dc.idx, 99, _dc.enemyDef, true);
                var _nowMy = game_strength_at(_g, _p, _dc.lane, _dc.idx);
                var _nowOpp = game_strength_at(_g, 1 - _p, _dc.lane, _dc.idx);
                if (_nowMy + _dryReach < _nowOpp) { ai_dbg("dump skip lane" + string(_dc.lane + 1) + ": can't tie the tug"); continue; }
            }
            if (_dc.kind == "boss") {
                // don't chip-feed a boss with scraps - dump there only if it FINISHES the kill
                var _bReach = ai_send(_g, _p, _dc.lane, _dc.idx, 99, _dc.enemyDef, true);
                var _bMy = game_strength_at(_g, _p, _dc.lane, _dc.idx);
                if (_bMy + _bReach < _dc.req) { ai_dbg("dump skip lane" + string(_dc.lane + 1) + ": scraps won't finish the boss"); continue; }
            }
            var _dumped = ai_send(_g, _p, _dc.lane, _dc.idx, 99, _dc.enemyDef);
            if (_dumped > 0) { ai_dbg("leftover dump: " + string(_dumped) + " str -> lane" + string(_dc.lane + 1) + " idx" + string(_dc.idx)); break; }
        }
    }
    var _handStr = "";
    var _hand2 = _g.players[_p].hand;
    for (var _hj = 0; _hj < array_length(_hand2); _hj++) _handStr += (_hj > 0 ? "," : "") + _hand2[_hj];
    ai_dbg("orders done. remaining homeStr=" + string(ai_home_strength(_g, _p)) + "  hand=[" + _handStr + "]");
    game_orders_done(_g);
}

/// Paced orders driver (one ai_step tick per call): plan on the first call, then
/// commit ONE visible deployment per call so you can watch the AI march groups out,
/// then finish. State lives on _g.aiPlan (scratch, cleared when the phase ends).
function ai_do_orders(_g) {
    if (!variable_struct_exists(_g, "aiPlan") || _g.aiPlan == undefined) {
        _g.aiPlan = ai_orders_plan(_g);
        return; // first tick just plans (economy/recall/build) - a natural beat before deploying
    }
    var _plan = _g.aiPlan;
    while (_plan.idx < array_length(_plan.cands)) {
        var _moved = ai_orders_commit(_g, _plan.cands[_plan.idx], _plan.risk, _plan.scarce);
        _plan.idx += 1;
        if (_moved) return; // one visible deployment this tick
    }
    ai_orders_finish(_g, _plan);
    _g.aiPlan = undefined;
}

// ---------- move phase: cards, then resolve ----------

function ai_do_move(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    var _passes = 0;
    while (_passes < 12) {
        _passes += 1;
        if (_g.activePlayer != _p) return; // a card (Pikmin Extinction) already ended the turn
        var _played = false;
        for (var _hi = 0; _hi < array_length(_pl.hand); _hi++) {
            if (ai_try_card(_g, _p, _hi)) { _played = true; break; }
        }
        if (!_played) break;
    }
    if (_g.activePlayer != _p) return; // turn already ended mid-cards
    // hand about to overflow: burn a situational card instead of discarding blind
    if (array_length(_pl.hand) + array_length(_pl.pellets) >= global.rules.handLimit - 1) {
        for (var _hi = 0; _hi < array_length(_pl.hand); _hi++) {
            var _cid = _pl.hand[_hi];
            if (_cid == "surveydrone") {
                var _done = false;
                for (var _ti = 0; _ti < array_length(_g.treasures) && !_done; _ti++) {
                    var _t = _g.treasures[_ti];
                    if (_t.idx == 3 && _t.boss == undefined && array_length(_t.cards) >= 2
                        && ai_pile_marginal(_g, _p, _t) < 100) {
                        _done = game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx });
                    }
                }
                if (_done) break;
            } else if (_cid == "spicyspray") {
                // spray wherever we're already engaged - free extra actions
                var _done = false;
                for (var _laneIdx = 0; _laneIdx < _g.board.laneCount && !_done; _laneIdx++) {
                    for (var _spaceIdx = 0; _spaceIdx <= 6 && !_done; _spaceIdx++) {
                        if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _laneIdx, idx: _spaceIdx })) == 0) continue;
                        if (_g.board.lanes[_laneIdx].spaces[_spaceIdx].enemy != undefined
                            || game_treasure_at(_g, _laneIdx, _spaceIdx) != undefined) {
                            _done = game_play_gather(_g, _hi, { lane: _laneIdx, idx: _spaceIdx });
                        }
                    }
                }
                if (_done) break;
            }
        }
    }
    game_resolve_moves(_g);
}

function ai_try_card(_g, _p, _hi) {
    var _cardId = _g.players[_p].hand[_hi];
    switch (_cardId) {

        case "ivoryandviolet": {
            // trade idle HOME chaff into purples (5 carry strength per token)
            var _homeCount = array_length(game_tokens_at(_g, _p, { kind: "home" }));
            if (_homeCount >= 5) {
                return game_play_gather(_g, _hi, { atHome: true, purples: min(_homeCount div 5, 3), whites: 0 });
            }
            return false;
        }

        case "oatchirush": {
            // planner seats rush their PRIMARY first - the objective priced the
            // rush's end position into its turns-to-bank, so the play must land on
            // that lane, not whichever eligible lane the generic loop hits first
            var _polO = sim_policy_get(_g, _p);
            if (_polO != undefined && _polO.kind == "planner"
                && variable_struct_exists(_g, "simPlanObj") && _g.simPlanObj[_p] != undefined) {
                var _obO = _g.simPlanObj[_p];
                if (_obO.mode == "bank" && _obO.useOatchi && game_play_gather(_g, _hi, { lane: _obO.bankLane })) return true;
            }
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                var _t = undefined;
                for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                    if (_g.treasures[_ti].lane == _laneIdx) { _t = _g.treasures[_ti]; break; }
                }
                if (_t == undefined || _t.boss != undefined) continue;
                if (_p == 0 && _t.idx <= 3) continue;
                if (_p == 1 && _t.idx >= 3) continue;
                var _clear = true;
                var _dir = (_p == 0) ? 1 : -1;
                var _s = (_p == 0) ? 0 : 6;
                while (_s != _t.idx) {
                    if (game_space_has_card(_g, _laneIdx, _s)) { _clear = false; break; }
                    _s += _dir;
                }
                if (_clear && game_play_gather(_g, _hi, { lane: _laneIdx })) return true;
            }
            return false;
        }

        case "spicyspray": {
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                var _mine = game_strength_at(_g, _p, _t.lane, _t.idx);
                if (_mine <= 0) continue;
                var _opp = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
                var _stalemate = (_t.boss == undefined && array_length(_t.cards) > 0
                    && _mine == _opp && _mine >= treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight);
                var _bossFight = (_t.boss != undefined && _mine >= 4);
                if (_stalemate || _bossFight) {
                    return game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx });
                }
            }
            return false;
        }

        case "bombrock":
        case "boulder": {
            var _bestLane = -1, _bestIdx = -1, _bestScore = 0;
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                for (var _spaceIdx = 0; _spaceIdx <= 6; _spaceIdx++) {
                    if (array_length(game_tokens_at(_g, _p, { kind: "space", lane: _laneIdx, idx: _spaceIdx })) > 0) continue;
                    var _score = 0;
                    var _space = _g.board.lanes[_laneIdx].spaces[_spaceIdx];
                    var _t = game_treasure_at(_g, _laneIdx, _spaceIdx);
                    var _oppTokens = array_length(game_tokens_at(_g, 1 - _p, { kind: "space", lane: _laneIdx, idx: _spaceIdx }));
                    if (_t != undefined && _t.boss != undefined) {
                        var _bDef = enemy_def_get(_t.boss.enemyDefId);
                        if (!ai_type_can_hurt("red", _bDef) && !ai_type_can_hurt("yellow", _bDef) && !ai_type_can_hurt("blue", _bDef)) _score = 60;
                        else if (_t.boss.curHp <= 10) _score = 50;
                    } else if (_t != undefined && _oppTokens >= 4) {
                        _score = 20 + _oppTokens * 4; // vaporise their carrying crew
                    } else if (_space.enemy != undefined) {
                        var _onOurSide = (_p == 0) ? (_spaceIdx < 3) : (_spaceIdx > 3);
                        var _eDef = enemy_def_get(_space.enemy.enemyDefId);
                        if (_onOurSide && (_space.enemy.curHp <= 10 || !ai_type_can_hurt("red", _eDef))) _score = 30 + _eDef.damage;
                    }
                    _score += _oppTokens * 2;
                    if (_score > _bestScore) { _bestScore = _score; _bestLane = _laneIdx; _bestIdx = _spaceIdx; }
                }
            }
            if (_bestScore >= 30) return game_play_gather(_g, _hi, { lane: _bestLane, idx: _bestIdx });
            return false;
        }

        case "phosbatpod": {
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                var _lo = (_p == 0) ? 4 : 0;
                var _hi2 = (_p == 0) ? 6 : 2;
                for (var _spaceIdx = _lo; _spaceIdx <= _hi2; _spaceIdx++) {
                    var _space = _g.board.lanes[_laneIdx].spaces[_spaceIdx];
                    if (_space.kind == "enemy" && _space.enemy == undefined
                        && game_treasure_at(_g, _laneIdx, _spaceIdx) == undefined && _space.structure == undefined) {
                        return game_play_gather(_g, _hi, { lane: _laneIdx, idx: _spaceIdx });
                    }
                }
            }
            return false;
        }

        case "rawmaterial": {
            var _pl = _g.players[_p];
            var _copies = 0;
            for (var _i = 0; _i < array_length(_pl.hand); _i++) {
                if (_pl.hand[_i] == "rawmaterial") _copies += 1;
            }
            if (_copies < 2) return false;

            // 1) BRIDGE the first hazard gate on the road to the most valuable pile.
            //    Boards like The Minefield are pure bridge puzzles - without this the
            //    AI can never reach (let alone haul) a single treasure there.
            if (arr_has(_g.boardDef.structures.bridges, "bridge")) {
                // distinct roster colours (what could possibly cross on its own)
                var _cols2 = [];
                for (var _i = 0; _i < array_length(_pl.tokens); _i++) {
                    if (!arr_has(_cols2, _pl.tokens[_i].typeId)) array_push(_cols2, _pl.tokens[_i].typeId);
                }
                var _bgVal = 0, _bgLane = -1, _bgIdx = -1;
                for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                    var _t = _g.treasures[_ti];
                    if (array_length(_t.cards) == 0) continue;
                    var _val = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
                    if (_val <= _bgVal) continue;
                    // walk home edge -> pile: first hazard space NO owned colour can cross
                    var _dir = (_p == 0) ? 1 : -1;
                    var _s = (_p == 0) ? 0 : 6;
                    var _gate = -1;
                    while (_s != _t.idx) {
                        var _sp = _g.board.lanes[_t.lane].spaces[_s];
                        if (_sp.enemy != undefined || game_treasure_at(_g, _t.lane, _s) != undefined) { _gate = -1; break; } // enemy road: handled by combat plans first
                        if (_sp.kind == "hazard" && _sp.structure == undefined) {
                            var _passable = false;
                            for (var _c2 = 0; _c2 < array_length(_cols2) && !_passable; _c2++) {
                                if (game_type_can_enter(pikmin_type_get(_cols2[_c2]), _sp, true, false)) _passable = true;
                            }
                            if (!_passable) { _gate = _s; break; }
                        }
                        _s += _dir;
                    }
                    if (_gate >= 0) { _bgVal = _val; _bgLane = _t.lane; _bgIdx = _gate; }
                }
                if (_bgLane >= 0 && game_play_gather(_g, _hi, { lane: _bgLane, idx: _bgIdx, build: "bridge" })) {
                    ai_dbg("BRIDGE the gate: lane " + string(_bgLane + 1) + " idx " + string(_bgIdx) + " (opens " + string(round(_bgVal)) + "p road)");
                    return true;
                }
            }

            // 2) otherwise wall off the lane whose pile the OPPONENT most wants
            if (array_length(_g.boardDef.structures.walls) == 0) return false;
            var _buildWall = _g.boardDef.structures.walls[0]; // whatever wall this board allows
            var _bestLane = -1, _bestVal = 0;
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.idx != 3) continue;
                var _val = ai_pile_marginal(_g, 1 - _p, _t);
                if (_val > _bestVal) { _bestVal = _val; _bestLane = _t.lane; }
            }
            if (_bestLane == -1) return false;
            var _oppMid = (_p == 0) ? 5 : 1;
            if (_g.board.lanes[_bestLane].spaces[_oppMid].structure != undefined || game_space_has_card(_g, _bestLane, _oppMid)) return false;
            return game_play_gather(_g, _hi, { lane: _bestLane, idx: _oppMid, build: _buildWall });
        }

        case "candypopbud2": {
            // WINGED UNLOCK: on chasm-gated boards an all-winged squad flies over the
            // gaps AND carries piles straight across them - no bridge needed, nothing
            // breaks. The intended solve for boards like The Minefield.
            var _chasms = 0;
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                for (var _si = 0; _si <= 6; _si++) {
                    var _sp3 = _g.board.lanes[_laneIdx].spaces[_si];
                    if (_sp3.kind == "hazard" && _sp3.hazard == "chasm" && _sp3.structure == undefined) _chasms += 1;
                }
            }
            if (_chasms < 2) return false; // no gaps worth wings
            var _home = game_tokens_at(_g, _p, { kind: "home" });
            if (array_length(_home) < 5) return false; // convert a real squad, not stragglers
            // purple judgment: melting a purple into a wing is a strength downgrade,
            // but a purple that can't REACH anything is doing nothing - if no pile is
            // ground-accessible to purples, 25 in the air beats 25 behind a gap
            var _purpleUseful = false;
            for (var _ti2 = 0; _ti2 < array_length(_g.treasures) && !_purpleUseful; _ti2++) {
                if (game_dest_legal(_g, _p, "purple", _g.treasures[_ti2].lane, _g.treasures[_ti2].idx)) _purpleUseful = true;
            }
            if (_purpleUseful) {
                for (var _i = 0; _i < array_length(_home); _i++) {
                    if (pikmin_type_get(_home[_i].typeId).carry > 1) return false; // purples still have ground work
                }
            }
            if (game_play_gather(_g, _hi, { atHome: true, color: "winged" })) {
                ai_dbg("WINGED unlock: " + string(array_length(_home)) + " home pikmin take flight (" + string(_chasms) + " chasms on board)");
                return true;
            }
            return false;
        }

        case "pikminextinction": {
            var _own = array_length(_g.players[_p].tokens);
            var _opp = array_length(_g.players[1 - _p].tokens);
            if (_opp - _own >= 8) return game_play_gather(_g, _hi, {});
            return false;
        }

        case "bitterspray": {
            // best use: petrify the opponent's WINNING carry group (they count as enemies)
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.boss != undefined || array_length(_t.cards) == 0) continue;
                var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
                var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
                var _topW = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
                if (_oppS >= _topW && _oppS > _myS) {
                    return game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx });
                }
            }
            // otherwise petrify only a genuinely NASTY engaged enemy (dmg >= 5) - the
            // old dmg>=3 fallback burned every bitter on chaff bulborbs, so it was
            // never in hand when the opponent's carry needed stopping
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                for (var _si = 0; _si <= 6; _si++) {
                    var _sp = _g.board.lanes[_laneIdx].spaces[_si];
                    if (_sp.enemy == undefined) continue;
                    if ((variable_struct_exists(_sp.enemy, "stunned") && _sp.enemy.stunned > 0)) continue;
                    var _eD = enemy_def_get(_sp.enemy.enemyDefId);
                    if (_eD.damage >= 5 && game_strength_at(_g, _p, _laneIdx, _si) > 0 && _sp.enemy.curHp > game_strength_at(_g, _p, _laneIdx, _si)) {
                        return game_play_gather(_g, _hi, { lane: _laneIdx, idx: _si });
                    }
                }
            }
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.boss == undefined) continue;
                if (variable_struct_exists(_t.boss, "stunned") && _t.boss.stunned > 0) continue;
                if (game_strength_at(_g, _p, _t.lane, _t.idx) >= 5) return game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx }); // real assault only
            }
            return false;
        }

        case "icebomb":
        case "storm": {
            // freeze the opponent's winning carry group (their strength stops counting)
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.boss != undefined || array_length(_t.cards) == 0) continue;
                var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
                var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
                var _topW = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
                if (_oppS >= _topW && _oppS > _myS) {
                    return game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx });
                }
            }
            return false;
        }

        case "shipsignal": {
            // lighten the top of a pile we're on but can't lift
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.boss != undefined || array_length(_t.cards) < 2) continue;
                var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
                if (_myS <= 0) continue;
                var _topW = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
                if (_myS >= _topW) continue; // already liftable
                var _bestIdx = -1, _bestW = _topW;
                for (var _pc = 0; _pc < array_length(_t.cards) - 1; _pc++) {
                    var _w2 = treasure_def_get(_t.cards[_pc]).weight;
                    if (_w2 <= _myS && _w2 < _bestW) { _bestW = _w2; _bestIdx = _pc; }
                }
                if (_bestIdx >= 0) return game_play_gather(_g, _hi, { lane: _t.lane, idx: _t.idx, topCard: _bestIdx });
            }
            return false;
        }

        case "pikpikbundle": {
            // shield an ongoing fight that will bite back (lane enemy or treasure boss)
            for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
                for (var _si = 0; _si <= 6; _si++) {
                    var _sp = _g.board.lanes[_laneIdx].spaces[_si];
                    var _foe = _sp.enemy;
                    if (_foe == undefined) {
                        var _bt = game_treasure_at(_g, _laneIdx, _si);
                        if (_bt != undefined && _bt.boss != undefined) _foe = _bt.boss;
                    }
                    if (_foe == undefined) continue;
                    var _eD = enemy_def_get(_foe.enemyDefId);
                    if (_eD.damage <= 0) continue;
                    if (game_strength_at(_g, _p, _laneIdx, _si) <= 0) continue;
                    var _hasDecoy = false;
                    for (var _di = 0; _di < array_length(_g.decoys); _di++) {
                        if (_g.decoys[_di].playerIdx == _p && _g.decoys[_di].lane == _laneIdx && _g.decoys[_di].idx == _si) { _hasDecoy = true; break; }
                    }
                    if (!_hasDecoy) return game_play_gather(_g, _hi, { lane: _laneIdx, idx: _si });
                }
            }
            return false;
        }

        case "mine": {
            // bury it in the middle of the opponent's busiest approach
            var _bestLane2 = -1, _bestVal2 = 0;
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
                var _t = _g.treasures[_ti];
                if (_t.idx != 3) continue;
                var _v = ai_pile_marginal(_g, 1 - _p, _t);
                if (_v > _bestVal2) { _bestVal2 = _v; _bestLane2 = _t.lane; }
            }
            if (_bestLane2 == -1) return false;
            var _mineIdx = (_p == 0) ? 5 : 1;
            if (game_mine_at(_g, _bestLane2, _mineIdx) != undefined) return false;
            return game_play_gather(_g, _hi, { lane: _bestLane2, idx: _mineIdx });
        }

        default:
            return false;
    }
}

/// Boss bounty: the AI's turn at the pendingFree queue. Picks the emitter whose
/// element most of its own roster shrugs off, and drops it on the opponent's
/// side of their most valuable approach. One placement per call (watchable pace).
function ai_place_free_hazard(_g) {
    if (array_length(_g.pendingFree) == 0) return;
    var _p = _g.pendingFree[0].playerIdx;
    global.aiDbgP = _p;

    // emitter choice: maximize (our immune types) - (their immune types)
    var _emits = _g.boardDef.structures.emitters;
    var _build = _emits[0];
    var _bestElemScore = -99;
    for (var _e = 0; _e < array_length(_emits); _e++) {
        var _elem = hazard_def_get(_emits[_e]).element;
        var _score = 0;
        for (var _q = 0; _q < 2; _q++) {
            var _seen = [];
            var _toks = _g.players[_q].tokens;
            for (var _i = 0; _i < array_length(_toks); _i++) {
                if (arr_has(_seen, _toks[_i].typeId)) continue;
                array_push(_seen, _toks[_i].typeId);
                if (arr_has(pikmin_type_get(_toks[_i].typeId).immunities, _elem)) _score += (_q == _p) ? 1 : -1;
            }
        }
        if (_score > _bestElemScore) { _bestElemScore = _score; _build = _emits[_e]; }
    }

    // spot: opponent's half of their busiest pile lane, nearest the centre first
    var _oppSide = (_p == 0) ? [4, 5, 6] : [2, 1, 0];
    var _lanesByVal = [];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        array_push(_lanesByVal, { lane: _g.treasures[_ti].lane, v: ai_pile_marginal(_g, 1 - _p, _g.treasures[_ti]) });
    }
    array_sort(_lanesByVal, function(_a, _b) { return _b.v - _a.v; });
    for (var _li = 0; _li < array_length(_lanesByVal); _li++) {
        var _lane = _lanesByVal[_li].lane;
        for (var _si = 0; _si < array_length(_oppSide); _si++) {
            var _idx = _oppSide[_si];
            var _sp = _g.board.lanes[_lane].spaces[_idx];
            if (_sp.kind == "hazard" || game_space_has_card(_g, _lane, _idx) || _sp.structure != undefined) continue;
            ai_dbg("free hazard: " + _build + " at lane " + string(_lane) + " idx " + string(_idx));
            game_place_free_hazard(_g, _lane, _idx, _build);
            return;
        }
    }
    ai_dbg("free hazard: no legal spot, passing");
    game_skip_free_hazard(_g);
}
