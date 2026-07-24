// ============================================================================
// v4 BRAIN — one valuation, three passes.  (spec: /v4-spec artifact, 2026-07-23)
//
// PRINCIPLE: enumerate every independent value-producing OUTCOME available this
// turn, value each off ITS lane's treasure, and pick the highest-value SUBSET the
// resources can jointly fund. No tiers, no gates, no filters — a useless outcome
// is simply worth ~0 and loses on its own. An outcome is one discrete result
// (move / kill / build / destroy); a requisite (the wall/freeze/overcommit that
// makes a carry responsible, the pellets it burns) folds into the outcome it
// enables and never scores on its own.
//
// THREE PASSES per turn:
//   1. PLAN -> gather. Run the optimizer on what I have; roll for bodies or draw
//      for cards depending on which raises the best-combination number; else draw.
//   2. SCORE. Replan from scratch. Optimize the best fundable subset of outcomes,
//      redeeming pellets as it commits. Pikmin + pellets execute in ORDERS, the
//      builds/items in MOVE (engine timing). This is where bodies go.
//   3. DENY. Card-first: for each LEFTOVER item, find its most damaging placement,
//      valued by opponent progress lost. No points, runs last.
//
// VALUE (everything is a fraction/multiple of the lane's pile value V):
//   move  = V x m(space it ends on)      m: 1.0 far half/center, +0.25/space toward
//                                        home, 2.0 banked. Requires a RESPONSIBLE
//                                        (secured) carry or it scores nothing.
//   remove= grab / (open tasks still in the lane)   grab = V x m(pile position).
//           Completed tasks stay done, so the divisor drops & persists: opening the
//           k-th task in an N-task lane is worth grab/(N-k+1). Boss = one removal
//           whose grab is the treasure underneath (the sanctioned cheat), + reward.
//
// This file is built as verified bricks (F9-tested). Brick 1: the value core.
// ============================================================================

// ---------------------------------------------------------------------------
// BRICK 2b — MOVE outcomes.  A lane offers a move only when it's OPEN (no hard
// road obstacle, no boss). One move outcome per lane, carrying payment/value
// VARIANTS (the optimiser picks one): plain/rush carry, a spicy double-carry, a
// freeze- or wall-secured carry, and the oatchi 2-space jump. Value = V x m(end
// space). SECURING is the folded requisite that makes the carry responsible:
//   banking this turn      -> out-muscle what's on the pile (they can't answer)
//   opponent can't contest -> min-win only (more is waste)
//   they can contest       -> min-win + affordable buffer (2x rush, else +4), OR
//                             min-win + a freeze/wall item (item buys the turn)
// Below "responsible" it isn't emitted -- a min-contest scores nothing, so it
// just never appears, no gate needed.
// ---------------------------------------------------------------------------

/// A copy of _arr with _extra appended (no mutation of _arr).
function ai4_with(_arr, _extra) {
    var _c = array_create(array_length(_arr) + 1);
    for (var _i = 0; _i < array_length(_arr); _i++) _c[_i] = _arr[_i];
    _c[array_length(_arr)] = _extra;
    return _c;
}

/// Where the pile lands after carrying _steps toward _p's home from _idx (off the
/// board edge -> the banked sentinel: -1 for p0, 7 for p1).
function ai4_carry_end(_p, _idx, _steps) {
    var _dir = (_p == 0) ? -1 : 1;
    var _e = _idx + _steps * _dir;
    if (_p == 0 && _e < 0) return -1;
    if (_p == 1 && _e > 6) return 7;
    return clamp(_e, 0, 6);
}
function ai4_end_banks(_p, _endIdx) { return (_p == 0) ? (_endIdx < 0) : (_endIdx > 6); }

/// Move outcomes for one OPEN treasure lane: { laneId, type:"move", lane, idx,
/// variants:[{value, str, need, items, endIdx}] }, or [] if it can't move responsibly.
function ai4_lane_moves(_g, _p, _t) {
    if (_t.boss != undefined) return [];
    // A MOVE lane = some colour can carry the WHOLE road. resolve_colors("carry") is that test.
    var _carryCols = ai4_resolve_colors(_g, _p, _t.lane, _t.idx, "carry", undefined);
    if (array_length(_carryCols) == 0) return [];

    var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
    var _V = ai4_pile_value(_g, _p, _t);
    var _myOn = game_strength_at(_g, _p, _t.lane, _t.idx);
    var _oppOn = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
    var _minWin = max(_w, _oppOn + 1);
    _minWin += ai3_explosive_threat(_g, _p, _t.lane, _t.idx);   // blast casualties are part of the control cost

    // opponent contest capacity: their in-lane reserve + what they can march from home
    var _oppLane = 0; var _ot = _g.players[1 - _p].tokens;
    for (var _k = 0; _k < array_length(_ot); _k++)
        if (_ot[_k].loc.kind == "space" && _ot[_k].loc.lane == _t.lane) _oppLane += pikmin_type_get(_ot[_k].typeId).carry;
    var _oppContest = _oppLane + ai_send(_g, 1 - _p, _t.lane, _t.idx, 99, undefined, true);

    var _hand = _g.players[_p].hand;
    // RESOURCE DESIGNATION (ruling): each variant BINDS the colours that fund it - the plan states
    // "how many of WHICH colour", not just how many. A rush is only a rush funded WITHOUT purple
    // (purple cancels it); an all-white 2-step only funded BY whites. Without the binding, merely
    // owning whites would "grant" 2-space carries the squad never actually performs.
    var _noPurple = [];
    for (var _c = 0; _c < array_length(_carryCols); _c++) if (_carryCols[_c] != "purple") array_push(_noPurple, _carryCols[_c]);
    var _stepSets = [{ steps: 1, cols: _carryCols, minStr: _minWin, item: "" }];              // plain carry: any colour
    if (global.expRules.rush && _w <= 8 && _oppOn < _w && array_length(_noPurple) > 0)
        array_push(_stepSets, { steps: 2, cols: _noPurple, minStr: max(_minWin, _w * 2), item: "" }); // rush: 2x weight, purple-free
    else if (arr_has(_carryCols, "white"))
        array_push(_stepSets, { steps: 2, cols: ["white"], minStr: _minWin, item: "" });      // all-white native 2-step
    var _nss = array_length(_stepSets);
    if (arr_has(_hand, "spicyspray")) for (var _s2 = 0; _s2 < _nss; _s2++)
        array_push(_stepSets, { steps: _stepSets[_s2].steps * 2, cols: _stepSets[_s2].cols, minStr: _stepSets[_s2].minStr, item: "spicyspray" });

    var _variants = [];
    for (var _s = 0; _s < array_length(_stepSets); _s++) {
        var _ss = _stepSets[_s];
        // MINE WIPE-GUARD: riders end turns on every carry-path space; a mine there that's armed -
        // or that THIS deploy's own passes would arm (dmg + marched bodies >= 10) - kills the whole
        // stack (killedIfThrownOut boards: permanently). Such a carry realizes nothing: not offered.
        var _dep0 = max(0, _ss.minStr - _myOn);
        var _mineWipe = false;
        for (var _mw = 0; _mw < array_length(_g.mines) && !_mineWipe; _mw++) {
            var _mn = _g.mines[_mw];
            if (_mn.lane != _t.lane) continue;
            if ((_p == 0) ? (_mn.idx > _t.idx) : (_mn.idx < _t.idx)) continue;   // beyond the pile: not on my carry path
            if (_mn.dmg + _dep0 >= 10) _mineWipe = true;
        }
        if (_mineWipe) continue;
        var _end = ai4_carry_end(_p, _t.idx, _ss.steps);
        var _banks = ai4_end_banks(_p, _end);
        var _val = _V * ai4_move_mult(_p, _end);
        var _items0 = (_ss.item == "") ? [] : [_ss.item];
        var _need = _ss.minStr;
        var _dep = max(0, _need - _myOn);
        if (_banks || _oppContest <= 0) {
            // out-muscle current only (bank) / min-win (free lane): no buffer
            array_push(_variants, { value: _val, str: _dep, cols: _ss.cols, need: "carry", items: _items0, endIdx: _end });
        } else {
            // contested multi-turn haul: an affordable securing buffer (a rush stack IS its own buffer)
            var _secReq = max(_need, _minWin + SECURE_BUFFER);
            array_push(_variants, { value: _val, str: max(0, _secReq - _myOn), cols: _ss.cols, need: "carry", items: _items0, endIdx: _end });
            if (_s == 0) {   // item-secured alternatives on the plain set only (min-win + the item)
                var _fc = ["bitterspray", "icebomb", "storm"];
                for (var _f = 0; _f < array_length(_fc); _f++) {
                    if (!arr_has(_hand, _fc[_f])) continue;
                    var _fa = ai3_card_play_args(_g, _p, _fc[_f]);
                    if (_fa != undefined && _fa.lane == _t.lane && _fa.idx == _t.idx) {
                        array_push(_variants, { value: _val, str: _dep, cols: _ss.cols, need: "carry", items: ai4_with(_items0, _fc[_f]), endIdx: _end });
                        break;
                    }
                }
                if (arr_has(_hand, "phosbatpod")) {
                    var _wt = ai3_wall_target(_g, _p);
                    if (_wt != undefined && _wt.lane == _t.lane && (_wt.idx - ((_p == 0) ? 1 : -1)) == _t.idx)
                        array_push(_variants, { value: _val, str: _dep, cols: _ss.cols, need: "carry", items: ai4_with(_items0, "phosbatpod"), endIdx: _end });
                }
            }
        }
    }

    // -- OATCHI RUSH: only a STRICTLY opponent-side pile (centre counts as mine), lane clear --
    if (arr_has(_hand, "oatchirush")) {
        var _oppSide = (_p == 0) ? (_t.idx > 3) : (_t.idx < 3);
        if (_oppSide) {
            var _oe = ai4_carry_end(_p, _t.idx, 2);
            array_push(_variants, { value: _V * ai4_move_mult(_p, _oe), str: 0, need: "any", items: ["oatchirush"], endIdx: _oe });
        }
    }

    if (array_length(_variants) == 0) return [];
    return [{ laneId: _t.lane, type: "move", lane: _t.lane, idx: _t.idx, variants: _variants }];
}

// ---------------------------------------------------------------------------
// BRICK 3 — FUNDING.  Can a chosen subset be paid for JOINTLY from the shared pool:
// home pikmin BY COLOUR (strength = count x carry; all 1 except purple 5) + PELLETS
// (each -> sameTypeAmount of its own colour at full, or offTypeAmount of any other
// colour) + ITEM cards. A demand is {str, colors:[acceptable]} (colours resolved
// from the outcome's need); items are a {cardId:count} multiset. Greedy, most-
// constrained demand first so a forced-colour demand claims its colour before a
// fungible one takes it. Board-cap on redemption is left to execution (usually room).
// ---------------------------------------------------------------------------

/// AVAILABLE deployable strength by colour: { colour: strength }. Counts ALL my pikmin the orders
/// phase can put to work - home AND idle bodies standing on the board (they route via home) - but
/// NOT ones already committed (carrying a treasure, or fighting on an enemy space). This is the
/// "all available pikmin on the board" the strength evaluation must see; funding then adds the
/// pellet range on top (same-colour = efficient/full, off-colour = inefficient/half).
function ai4_available_by_color(_g, _p) {
    var _out = {};
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) {
        var _tok = _toks[_i];
        if (token_is_disabled(_tok)) continue;
        var _loc = _tok.loc;
        // DEPLOY-TRUTH: the shared pool is what ai_send can actually field THIS turn - home + idle
        // recallable bodies. COMMITTED bodies (on a pile carrying, or on an enemy fighting) fund
        // ONLY their own outcome via myOn/net demands; counting them here let them phantom-fund
        // OTHER lanes' plans that deploy then delivered 0/N on.
        if (_loc.kind == "space") {
            if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue;   // stranded
            var _csp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
            if (_csp.enemy != undefined || game_treasure_at(_g, _loc.lane, _loc.idx) != undefined) continue;  // committed
        }
        var _c = _tok.typeId;
        _out[$ _c] = (variable_struct_exists(_out, _c) ? _out[$ _c] : 0) + pikmin_type_get(_c).carry;
    }
    return _out;
}

/// Total available strength (the whole army with a path home) - what the optimiser actually funds
/// against, unlike ai_home_strength which only counts pikmin literally standing at home.
function ai4_available_total(_g, _p) {
    var _by = ai4_available_by_color(_g, _p);
    var _n = variable_struct_get_names(_by), _s = 0;
    for (var _i = 0; _i < array_length(_n); _i++) _s += _by[$ _n[_i]];
    return _s;
}

/// The colours that satisfy a demand's constraint (before availability): "any" = every
/// non-bulbmin type; "hurt"+enemyDef = colours that can hurt it; "carry"/"struct" =
/// colours whose road to (lane,idx) is legal. Funding then checks which I can field.
function ai4_resolve_colors(_g, _p, _lane, _idx, _need, _enemyDef) {
    // FIELDABLE colours only: ones I own, or board basics a pellet can redeem into. A colour I can
    // never field (yellow on a red/white/rock board) must not create phantom outcomes the funding
    // then "pays" with conversions the engine rejects (the minefield str1 forever-loop).
    var _field = [];
    var _tk = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tk); _i++) if (_tk[_i].typeId != "bulbmin" && !arr_has(_field, _tk[_i].typeId)) array_push(_field, _tk[_i].typeId);
    var _bas = _g.boardDef.basicColors;
    for (var _i = 0; _i < array_length(_bas); _i++) if (!arr_has(_field, _bas[_i])) array_push(_field, _bas[_i]);
    var _out = [];
    for (var _i = 0; _i < array_length(_field); _i++) {
        var _c = _field[_i];
        var _ok = false;
        if (_need == "any") _ok = true;
        else if (_need == "hurt") _ok = (_enemyDef != undefined) && ai_type_can_hurt(_c, _enemyDef) && game_dest_legal(_g, _p, _c, _lane, _idx);
        else if (_need == "carry" || _need == "struct") _ok = game_dest_legal(_g, _p, _c, _lane, _idx);
        if (_ok) array_push(_out, _c);
    }
    return _out;
}

/// ONE funding solver, two uses. _record=false: boolean feasibility (the optimizer's inner loop).
/// _record=true: build the DEPLOYMENT LEDGER - per demand, exactly which colour-strengths from the
/// pool and which pellets (redeemed into which colour) pay it. Execution plays the ledger back
/// VERBATIM, so "funded but undeliverable" is structurally impossible: one planning layer.
function ai4_fund(_g, _p, _demands, _items, _record = false) {
    return ai4_fund_impl(_g, _p, _demands, _items, _record);
}
function ai4_can_fund(_g, _p, _demands, _items) {
    return ai4_fund_impl(_g, _p, _demands, _items, false) != undefined;
}
function ai4_fund_impl(_g, _p, _demands, _items, _record) {
    var _hand = _g.players[_p].hand;
    var _names = variable_struct_get_names(_items);
    for (var _i = 0; _i < array_length(_names); _i++) {
        var _have = 0;
        for (var _h = 0; _h < array_length(_hand); _h++) if (_hand[_h] == _names[_i]) _have += 1;
        if (_have < _items[$ _names[_i]]) return undefined;
    }

    var _home = ai4_available_by_color(_g, _p);
    // BOARD-CAP headroom: at the 25-token cap a redemption grants NOTHING - pellets can only fund
    // up to the remaining room, or funding approves plans whose deploy under-delivers into min-contests.
    var _capRoom = max(0, global.rules.pikminBoardCap - game_capped_count(_g, _p));
    var _pel = []; var _pl = _g.players[_p].pellets;
    for (var _i = 0; _i < array_length(_pl); _i++) {
        var _d = pellet_def_get(_pl[_i]);
        array_push(_pel, { color: _d.color, same: _d.sameTypeAmount, off: _d.offTypeAmount, used: false });
    }

    var _ledger = _record ? array_create(array_length(_demands), undefined) : undefined;
    var _dem = array_create(array_length(_demands));
    for (var _i = 0; _i < array_length(_demands); _i++) { _dem[_i] = _demands[_i]; _dem[_i].demIdx = _i; }
    for (var _a = 1; _a < array_length(_dem); _a++) {                          // insertion sort: fewest acceptable colours first
        var _tmp = _dem[_a], _b = _a - 1;
        while (_b >= 0 && array_length(_dem[_b].colors) > array_length(_tmp.colors)) { _dem[_b + 1] = _dem[_b]; _b -= 1; }
        _dem[_b + 1] = _tmp;
    }

    for (var _i = 0; _i < array_length(_dem); _i++) {
        var _need = _dem[_i].str;
        var _entry = _record ? { tokens: {}, pellets: [] } : undefined;
        if (_record) _ledger[_dem[_i].demIdx] = _entry;
        if (_need <= 0) continue;
        var _cols = _dem[_i].colors;
        if (array_length(_cols) == 0) return undefined;
        for (var _c = 0; _c < array_length(_cols) && _need > 0; _c++) {        // home of acceptable colours
            var _cc = _cols[_c];
            if (!variable_struct_exists(_home, _cc)) continue;
            var _u = min(_need, _home[$ _cc]); _home[$ _cc] -= _u; _need -= _u;
            if (_record && _u > 0) _entry.tokens[$ _cc] = (variable_struct_exists(_entry.tokens, _cc) ? _entry.tokens[$ _cc] : 0) + _u;
        }
        if (_need <= 0) continue;
        var _bestCarry = 0;                                                    // off-conversion: pellets redeem into BASICS only
        var _basF = _g.boardDef.basicColors;
        for (var _c = 0; _c < array_length(_cols); _c++)
            if (arr_has(_basF, _cols[_c])) _bestCarry = max(_bestCarry, pikmin_type_get(_cols[_c]).carry);
        for (var _pp = 0; _pp < array_length(_pel) && _need > 0 && _capRoom > 0; _pp++) {   // same-colour pellets (full value), cap-limited
            if (_pel[_pp].used || !arr_has(_cols, _pel[_pp].color)) continue;
            _pel[_pp].used = true;
            var _grantS = min(_pel[_pp].same, _capRoom); _capRoom -= _grantS;
            _need -= _grantS * pikmin_type_get(_pel[_pp].color).carry;
            if (_record) array_push(_entry.pellets, { id: _pl[_pp], color: _pel[_pp].color });
        }
        var _bestCol = "";
        if (_bestCarry > 0) {
            for (var _c = 0; _c < array_length(_cols); _c++)
                if (arr_has(_basF, _cols[_c]) && pikmin_type_get(_cols[_c]).carry == _bestCarry) { _bestCol = _cols[_c]; break; }
        }
        if (_bestCarry > 0)                                                    // no basic accepted -> pellets can't off-fund this demand
        for (var _pp = 0; _pp < array_length(_pel) && _need > 0 && _capRoom > 0; _pp++) {   // off-convert, cap-limited
            if (_pel[_pp].used) continue;
            _pel[_pp].used = true;
            var _grantO = min(_pel[_pp].off, _capRoom); _capRoom -= _grantO;
            _need -= _grantO * _bestCarry;
            if (_record) array_push(_entry.pellets, { id: _pl[_pp], color: _bestCol });
        }
        if (_need > 0) return undefined;
    }
    return _record ? _ledger : true;
}

// ---------------------------------------------------------------------------
// BRICK 4 — THE OPTIMIZER.  Enumerate every lane's fundable outcomes, then brute-
// force the choice space: each outcome is SKIPPED or taken via ONE of its payment
// variants. Score each full combination — removals escalate per lane by how many of
// that lane's removals the combination includes, moves add their variant value — and
// keep the highest-value combination the pool can JOINTLY fund. Exact over selection
// AND variant. The fundable list is small (unpayable outcomes never enumerate); a
// safety cap drops the lowest-value outcomes if the product ever gets silly.
// ---------------------------------------------------------------------------
#macro AI4_COMBO_CAP 200000

/// Every fundable outcome across all treasure lanes (removals + moves).
function ai4_enumerate(_g, _p) {
    var _out = [];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _rem = ai4_lane_removals(_g, _p, _t);
        for (var _r = 0; _r < array_length(_rem); _r++) array_push(_out, _rem[_r]);
        var _mov = ai4_lane_moves(_g, _p, _t);
        for (var _m = 0; _m < array_length(_mov); _m++) array_push(_out, _mov[_m]);
    }
    return _out;
}

/// A rough standalone value for an outcome (for the safety-cap pruning only).
function ai4_outcome_rank(_o) {
    if (_o.type == "move") {
        var _best = 0;
        for (var _v = 0; _v < array_length(_o.variants); _v++) _best = max(_best, _o.variants[_v].value);
        return _best;
    }
    return _o.grab / max(1, _o.nOpen);
}

/// Value of a full selection (sel[i] = 0 skip, else variant sel[i]-1). Removals escalate
/// per lane; moves add their chosen variant's value.
function ai4_combo_value(_g, _p, _outcomes, _sel) {
    var _val = 0;
    var _laneCount = {};                                   // remove-count per laneId
    for (var _i = 0; _i < array_length(_outcomes); _i++) {
        if (_sel[_i] == 0) continue;
        var _o = _outcomes[_i];
        if (_o.type == "move") _val += _o.variants[_sel[_i] - 1].value;
        else if (variable_struct_exists(_o, "stale") && _o.stale) _val += 20;   // respawns immediately: salvage only
        else { var _k = string(_o.laneId); _laneCount[$ _k] = (variable_struct_exists(_laneCount, _k) ? _laneCount[$ _k] : 0) + 1; }
    }
    // one representative remove per lane carries grab/nOpen; escalate by the lane's count
    var _seen = {};
    for (var _i = 0; _i < array_length(_outcomes); _i++) {
        if (_sel[_i] == 0 || _outcomes[_i].type != "remove") continue;
        if (variable_struct_exists(_outcomes[_i], "stale") && _outcomes[_i].stale) continue;
        var _o = _outcomes[_i]; var _k = string(_o.laneId);
        if (variable_struct_exists(_seen, _k)) continue;
        _seen[$ _k] = true;
        _val += ai4_removal_stack(_o.grab, _o.nOpen, _laneCount[$ _k]);
    }
    return _val;
}

/// The pikmin demands + item multiset a selection asks of the pool.
function ai4_combo_demands(_g, _p, _outcomes, _sel) {
    var _demands = []; var _items = {};
    for (var _i = 0; _i < array_length(_outcomes); _i++) {
        if (_sel[_i] == 0) continue;
        var _o = _outcomes[_i]; var _var = _o.variants[_sel[_i] - 1];
        var _srcOutcome = _i;
        // fund the GROSS requirement (a controlled pile's own on-board strength pays for ITS control,
        // so it can't double-fund another lane); deploy still sends only the NET (str).
        var _fund = variable_struct_exists(_var, "fund") ? _var.fund : _var.str;
        if (_fund > 0) {
            var _ed = variable_struct_exists(_var, "enemyDef") ? _var.enemyDef : undefined;
            var _dcols = variable_struct_exists(_var, "cols") ? _var.cols : ai4_resolve_colors(_g, _p, _o.lane, _o.idx, _var.need, _ed);
            array_push(_demands, { str: _fund, colors: _dcols, srcOutcome: _srcOutcome });
        }
        for (var _c = 0; _c < array_length(_var.items); _c++) {
            var _cid = _var.items[_c];
            _items[$ _cid] = (variable_struct_exists(_items, _cid) ? _items[$ _cid] : 0) + 1;
        }
    }
    return { demands: _demands, items: _items };
}

/// THE OPTIMIZER: best fundable combination of outcomes for player _p this turn.
/// Returns { value, chosen:[{outcome, varIdx}] }.
function ai4_optimize(_g, _p) {
    var _outcomes = ai4_enumerate(_g, _p);
    // safety cap: drop the lowest-ranked outcomes until the choice product is sane
    var _prod = 1;
    for (var _i = 0; _i < array_length(_outcomes); _i++) _prod *= (1 + array_length(_outcomes[_i].variants));
    while (_prod > AI4_COMBO_CAP && array_length(_outcomes) > 0) {
        var _lowI = 0, _lowV = ai4_outcome_rank(_outcomes[0]);
        for (var _i = 1; _i < array_length(_outcomes); _i++) { var _rv = ai4_outcome_rank(_outcomes[_i]); if (_rv < _lowV) { _lowV = _rv; _lowI = _i; } }
        _prod = _prod div (1 + array_length(_outcomes[_lowI].variants));
        array_delete(_outcomes, _lowI, 1);
    }

    var _n = array_length(_outcomes);
    if (_n == 0) return { value: 0, chosen: [] };
    var _radix = array_create(_n); var _total = 1;
    for (var _i = 0; _i < _n; _i++) { _radix[_i] = 1 + array_length(_outcomes[_i].variants); _total *= _radix[_i]; }

    var _bestVal = 0; var _bestSel = array_create(_n, 0);
    var _sel = array_create(_n, 0);
    for (var _combo = 0; _combo < _total; _combo++) {
        var _rem = _combo;
        for (var _i = 0; _i < _n; _i++) { _sel[_i] = _rem mod _radix[_i]; _rem = _rem div _radix[_i]; }
        var _val = ai4_combo_value(_g, _p, _outcomes, _sel);
        if (_val <= _bestVal) continue;                    // only fund a combo that could win
        var _d = ai4_combo_demands(_g, _p, _outcomes, _sel);
        if (!ai4_can_fund(_g, _p, _d.demands, _d.items)) continue;
        _bestVal = _val;
        for (var _i = 0; _i < _n; _i++) _bestSel[_i] = _sel[_i];
    }

    // ONE PLANNING LAYER: rebuild the winner's demands and record the deployment ledger; each
    // chosen outcome carries its exact assignment (colour-strengths + pellet redemptions).
    var _assignByOutcome = array_create(_n, undefined);
    if (_bestVal > 0) {
        var _bd = ai4_combo_demands(_g, _p, _outcomes, _bestSel);
        var _ledger = ai4_fund(_g, _p, _bd.demands, _bd.items, true);
        if (_ledger != undefined)
            for (var _i = 0; _i < array_length(_bd.demands); _i++)
                _assignByOutcome[_bd.demands[_i].srcOutcome] = _ledger[_i];
    }
    var _chosen = [];
    for (var _i = 0; _i < _n; _i++) if (_bestSel[_i] > 0) array_push(_chosen, { outcome: _outcomes[_i], varIdx: _bestSel[_i] - 1, assign: _assignByOutcome[_i] });
    return { value: _bestVal, chosen: _chosen };
}

// ---------------------------------------------------------------------------
// BRICK 5 — THE THREE-PASS DRIVER + policy wiring.
//   gather -> PLAN pass: roll if more bodies raise the plan more than a card would, else draw.
//   orders -> SCORE pass (bodies): compute the plan once, then deploy each chosen outcome's
//             pikmin (redeeming pellets into the needed colour as it goes), one per tick.
//   move   -> the shared card layer (ai3_move) plays builds/items/deny for now; a plan-driven
//             card execution + card-first deny is the next refinement (brick 5b).
// Pellets stay flexible until a deploy commits them (game_play_pellet, orders-phase only).
// ---------------------------------------------------------------------------

/// Highest-carry colour in a set (purple if present) - the efficient off-conversion target.
function ai4_best_carry_color(_cols) {
    var _best = _cols[0], _bc = pikmin_type_get(_cols[0]).carry;
    for (var _i = 1; _i < array_length(_cols); _i++) {
        var _cy = pikmin_type_get(_cols[_i]).carry;
        if (_cy > _bc) { _bc = _cy; _best = _cols[_i]; }
    }
    return _best;
}

/// RECALL idle own-side bodies home so they can be redeployed. A pikmin that cleared an enemy
/// is left standing on that (now empty) space, out of play; without this it strands there and
/// home starves. Only idle own-half bodies on empty spaces that can path home (never a carrier
/// on a treasure, never one still fighting). Pellets are NOT touched - superposition holds.
function ai4_recall(_g, _p) {
    var _tokens = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i], _loc = _tok.loc;
        if (_loc.kind != "space" || token_is_disabled(_tok)) continue;
        if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue;
        var _rsp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
        if (_rsp.enemy != undefined || _rsp.structure != undefined || game_treasure_at(_g, _loc.lane, _loc.idx) != undefined) continue;
        _tok.loc = { kind: "home" };                                    // any idle body that can path home, either side
    }
}

/// GATHER (pass 1): roll if ONE more roll (a pellet) raises the best-combination number more
/// than ONE more draw (the single most useful card) would; else draw. The comparison must be
/// symmetric - a roll vs a draw, not a pellet vs a whole hand of cards - or it over-draws into
/// body starvation (cards to open lanes, no pikmin to carry them).
function ai4_gather(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    // RESERVE RULE: keep a body reserve on hand - roll while thin (fewer than 4 pellets AND no single
    // "5" pellet), else draw for cards. A ~10-strength army one-shots almost anything without chipping,
    // so building the reserve is near-always the efficient play; once it's stocked, spend gather on cards.
    var _pel = _pl.pellets;
    var _has5 = false;
    for (var _i = 0; _i < array_length(_pel); _i++) if (pellet_def_get(_pel[_i]).sameTypeAmount >= 5) { _has5 = true; break; }
    // reserve is satisfied only with BOTH a 5-pellet AND >= 4 pellets; keep rolling until then.
    var _roll = !(_has5 && array_length(_pel) >= 4);
    ai_dbg("v4 gather: pel=" + string(array_length(_pel)) + " has5=" + string(_has5) + " army=" + string(ai4_available_total(_g, _p)) + " -> " + (_roll ? "ROLL" : "DRAW"));
    if (_roll) game_gather_roll(_g); else game_gather_draw(_g);
}

/// Deploy one chosen outcome's pikmin, redeeming pellets into a needed colour first. Returns
/// true if it deployed (a visible commit). Item-only / already-controlling outcomes deploy nothing.
function ai4_deploy_one(_g, _p, _c) {
    var _o = _c.outcome; var _v = _o.variants[_c.varIdx];
    if (_v.str <= 0) return false;
    var _ed = (_v.need == "hurt") ? _v.enemyDef : undefined;
    var _clean = (_v.need == "hurt");

    // ONE PLANNING LAYER: execute the funding LEDGER verbatim - redeem exactly the listed pellets
    // into exactly the listed colours, then send exactly the listed colour-strengths. No re-deriving.
    if (variable_struct_exists(_c, "assign") && _c.assign != undefined) {
        var _a = _c.assign;
        for (var _i = 0; _i < array_length(_a.pellets); _i++) {
            var _pe = _a.pellets[_i];
            var _pls = _g.players[_p].pellets;
            for (var _j = 0; _j < array_length(_pls); _j++) {
                if (_pls[_j] != _pe.id) continue;
                ai_dbg("v4 redeem " + _pe.id + " -> " + _pe.color + " (ledger)");
                game_play_pellet(_g, 0 + _j, _pe.color);
                break;
            }
        }
        var _sent = 0;
        var _tcols = variable_struct_get_names(_a.tokens);
        for (var _i = 0; _i < array_length(_tcols); _i++)
            _sent += ai_send(_g, _p, _o.lane, _o.idx, _a.tokens[$ _tcols[_i]], _ed, false, false, _clean, [_tcols[_i]]);
        // pellet-granted bodies land at home in their redeemed colour - send those too
        var _pcols = {};
        for (var _i = 0; _i < array_length(_a.pellets); _i++) _pcols[$ _a.pellets[_i].color] = true;
        var _pcn = variable_struct_get_names(_pcols);
        for (var _i = 0; _i < array_length(_pcn) && _sent < _v.str; _i++)
            _sent += ai_send(_g, _p, _o.lane, _o.idx, _v.str - _sent, _ed, false, false, _clean, [_pcn[_i]]);
        if (_sent < _v.str) ai_dbg("v4 deploy lane" + string(_o.lane + 1) + " idx" + string(_o.idx) + ": UNDER-DELIVERED " + string(_sent) + "/" + string(_v.str) + " (" + _v.need + ") [ledger]");
        else ai_dbg("v4 deploy lane" + string(_o.lane + 1) + " idx" + string(_o.idx) + ": sent " + string(_sent) + "/" + string(_v.str) + " (" + _v.need + ") [ledger]");
        return _sent > 0;
    }

    // fallback (no ledger recorded): the old re-derive path
    var _allowed = variable_struct_exists(_v, "cols") ? _v.cols : undefined;
    var _guard = 0;
    while (ai_send(_g, _p, _o.lane, _o.idx, _v.str, _ed, true, false, _clean, _allowed) < _v.str && array_length(_g.players[_p].pellets) > 0 && _guard < 25) {
        var _cols = (_allowed != undefined) ? _allowed : ai4_resolve_colors(_g, _p, _o.lane, _o.idx, _v.need, _ed);
        var _colsB = [];
        for (var _cb = 0; _cb < array_length(_cols); _cb++) if (arr_has(_g.boardDef.basicColors, _cols[_cb])) array_push(_colsB, _cols[_cb]);
        var _pd = pellet_def_get(_g.players[_p].pellets[0]);
        var _col = arr_has(_colsB, _pd.color) ? _pd.color : (array_length(_colsB) > 0 ? ai4_best_carry_color(_colsB) : _pd.color);
        ai_dbg("v4 redeem " + _g.players[_p].pellets[0] + " -> " + _col);
        game_play_pellet(_g, 0, _col);
        _guard += 1;
    }
    var _sent2 = ai_send(_g, _p, _o.lane, _o.idx, _v.str, _ed, false, false, _clean, _allowed);
    if (_sent2 < _v.str) ai_dbg("v4 deploy lane" + string(_o.lane + 1) + " idx" + string(_o.idx) + ": UNDER-DELIVERED " + string(_sent2) + "/" + string(_v.str) + " (" + _v.need + ")");
    else ai_dbg("v4 deploy lane" + string(_o.lane + 1) + " idx" + string(_o.idx) + ": sent " + string(_sent2) + "/" + string(_v.str) + " (" + _v.need + ")");
    return _sent2 > 0;
}

/// ORDERS (pass 2, bodies): plan once, then deploy one chosen outcome per tick, then finish.
function ai4_orders(_g) {
    var _p = _g.activePlayer;
    if (!variable_struct_exists(_g, "ai4Plan") || _g.ai4Plan == undefined) {
        ai4_recall(_g, _p);                                          // bring idle own-side bodies home before planning
        var _plan = ai4_optimize(_g, _p);
        ai_dbg("");
        ai_dbg("===== v4 TURN P" + string(_p + 1) + "  Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength)
            + ")  score " + string(game_realized_score(_g, _p)) + " vs " + string(game_realized_score(_g, 1 - _p))
            + "  army " + string(ai4_available_total(_g, _p)) + "  pel " + string(array_length(_g.players[_p].pellets))
            + "  planVal " + string(round(_plan.value)) + "  outcomes " + string(array_length(_plan.chosen)) + " =====");
        for (var _i = 0; _i < array_length(_plan.chosen); _i++) {
            var _c = _plan.chosen[_i]; var _o = _c.outcome; var _v = _o.variants[_c.varIdx];
            var _its = ""; for (var _j = 0; _j < array_length(_v.items); _j++) _its += (_j > 0 ? "+" : "") + _v.items[_j];
            ai_dbg("v4 " + _o.type + " lane" + string(_o.lane + 1) + " idx" + string(_o.idx) + " str" + string(_v.str) + (_its != "" ? " [" + _its + "]" : ""));
        }
        _g.ai4Plan = { chosen: _plan.chosen, idx: 0 };
        _g.ai4Cards = { list: ai4_card_plays(_g, _p, _plan.chosen), idx: 0 };   // for the move phase (brick 5b)
        return;
    }
    var _plan = _g.ai4Plan;
    while (_plan.idx < array_length(_plan.chosen)) {
        var _c = _plan.chosen[_plan.idx];
        _plan.idx += 1;
        if (ai4_deploy_one(_g, _p, _c)) return;
    }
    game_orders_done(_g);
    _g.ai4Plan = undefined;
}

// --- BRICK 5b: authoritative plan-driven card execution (move phase) ---
// The plan's CHOSEN items get played by v4 itself, not reactively by the shared layer -
// each removal's bomb/bridge on ITS space, each move's securing freeze/wall/spicy/oatchi
// on the pile. Then the shared ai3_move plays any leftovers (deny) and ends the phase.

/// The concrete card plays a plan implies: {cardId, args}. A raw-material pair -> one bridge.
function ai4_card_plays(_g, _p, _chosen) {
    var _out = [];
    var _bridgeId = (array_length(_g.boardDef.structures.bridges) > 0) ? _g.boardDef.structures.bridges[0] : "bridge";
    for (var _i = 0; _i < array_length(_chosen); _i++) {
        var _o = _chosen[_i].outcome; var _v = _o.variants[_chosen[_i].varIdx];
        var _didRaw = false;
        for (var _j = 0; _j < array_length(_v.items); _j++) {
            var _c = _v.items[_j];
            if (_c == "rawmaterial") {
                if (_didRaw) continue; _didRaw = true;
                array_push(_out, { cardId: "rawmaterial", args: { lane: _o.lane, idx: _o.idx, build: _bridgeId } });
            } else if (_c == "bombrock" || _c == "boulder" || _c == "spicyspray") {
                array_push(_out, { cardId: _c, args: { lane: _o.lane, idx: _o.idx } });
            } else if (_c == "oatchirush") {
                array_push(_out, { cardId: "oatchirush", args: { lane: _o.lane } });
            } else if (_c == "phosbatpod") {
                var _wt = ai3_wall_target(_g, _p);
                if (_wt != undefined) array_push(_out, { cardId: "phosbatpod", args: { lane: _wt.lane, idx: _wt.idx } });
            } else if (_c == "bitterspray" || _c == "icebomb" || _c == "storm") {
                var _fa = ai3_card_play_args(_g, _p, _c);
                if (_fa != undefined) array_push(_out, { cardId: _c, args: _fa });
            }
        }
    }
    return _out;
}

/// Play the first hand copy of _cardId with _args. Logs card, target, purpose, and result.
function ai4_play_card(_g, _p, _cardId, _args, _why = "plan") {
    var _tgt = "";
    if (variable_struct_exists(_args, "lane")) _tgt = " -> lane" + string(_args.lane + 1) + (variable_struct_exists(_args, "idx") ? " idx" + string(_args.idx) : "");
    if (variable_struct_exists(_args, "build")) _tgt += " build " + string(_args.build);
    var _hand = _g.players[_p].hand;
    for (var _i = 0; _i < array_length(_hand); _i++) {
        if (_hand[_i] != _cardId) continue;
        var _ok = game_play_gather(_g, _i, _args);
        ai_dbg("v4 card [" + _why + "] " + _cardId + _tgt + (_ok ? " OK" : " REFUSED"));
        return _ok;
    }
    ai_dbg("v4 card [" + _why + "] " + _cardId + _tgt + " NOT IN HAND");
    return false;
}

// --- PASS 3: DENY (card-first). For each LEFTOVER item, its most damaging placement, valued by
// the opponent progress it costs. No points, runs after scoring; only spare items (the plan's
// cards are already spent by the time this builds). ---

/// Opponent progress a disruption at this pile would cost: their pile value scaled by how far
/// their carry is toward THEIR home (near-bank hurts most). 0 unless they control it.
function ai4_opp_progress(_g, _p, _t) {
    var _opp = 1 - _p;
    if (array_length(_t.cards) == 0 || _t.boss != undefined) return 0;
    var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
    if (game_strength_at(_g, _opp, _t.lane, _t.idx) < _w) return 0;
    return ai4_pile_value(_g, _opp, _t) * ai4_move_mult(_opp, _t.idx);
}

/// The disruptive plays my leftover items afford, best (most opponent-progress denied) first.
function ai4_deny_plays(_g, _p) {
    var _out = [];
    var _hand = _g.players[_p].hand;

    var _fc = ["bitterspray", "icebomb", "storm"];                   // FREEZE their best controlled carry
    for (var _f = 0; _f < array_length(_fc); _f++) {
        if (!arr_has(_hand, _fc[_f])) continue;
        var _fa = ai3_card_play_args(_g, _p, _fc[_f]);
        if (_fa == undefined) continue;
        var _t = game_treasure_at(_g, _fa.lane, _fa.idx);
        var _dv = (_t != undefined) ? ai4_opp_progress(_g, _p, _t) : 0;
        if (_dv > 0) array_push(_out, { cardId: _fc[_f], args: _fa, denyVal: _dv });
    }
    if (arr_has(_hand, "phosbatpod")) {                              // WALL their road to a carry
        var _wt = ai3_wall_target(_g, _p);
        if (_wt != undefined) {
            var _dv = 0;
            for (var _ti = 0; _ti < array_length(_g.treasures); _ti++)
                if (_g.treasures[_ti].lane == _wt.lane) _dv = max(_dv, ai4_opp_progress(_g, _p, _g.treasures[_ti]));
            if (_dv > 0) array_push(_out, { cardId: "phosbatpod", args: { lane: _wt.lane, idx: _wt.idx }, denyVal: _dv });
        }
    }
    var _bc = ["bombrock", "boulder"];                               // BOMB their biggest carry clump (never my own pikmin)
    for (var _b = 0; _b < array_length(_bc); _b++) {
        if (!arr_has(_hand, _bc[_b])) continue;
        var _bt = undefined, _bv = 0;
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            var _t = _g.treasures[_ti];
            if (game_strength_at(_g, _p, _t.lane, _t.idx) > 0) continue;
            var _dv = ai4_opp_progress(_g, _p, _t);
            if (_dv > _bv) { _bv = _dv; _bt = _t; }
        }
        if (_bt != undefined) array_push(_out, { cardId: _bc[_b], args: { lane: _bt.lane, idx: _bt.idx }, denyVal: _bv });
    }

    for (var _a = 1; _a < array_length(_out); _a++) {                // sort by denyVal desc
        var _tmp = _out[_a], _bb = _a - 1;
        while (_bb >= 0 && _out[_bb].denyVal < _tmp.denyVal) { _out[_bb + 1] = _out[_bb]; _bb -= 1; }
        _out[_bb + 1] = _tmp;
    }
    return _out;
}

/// MOVE phase, fully v4-owned: play the plan's chosen cards, then pass-3 deny with leftovers,
/// then resolve. One play per tick (so a bomb resolves between); no cascade delegation.
function ai4_move(_g) {
    var _p = _g.activePlayer;
    if (variable_struct_exists(_g, "ai4Cards") && _g.ai4Cards != undefined) {   // pass 2 cards (scoring)
        var _cs = _g.ai4Cards;
        while (_cs.idx < array_length(_cs.list)) {
            var _cp = _cs.list[_cs.idx]; _cs.idx += 1;
            if (ai4_play_card(_g, _p, _cp.cardId, _cp.args)) return;
        }
        _g.ai4Cards = undefined; _g.ai4Deny = undefined;
    }
    if (!variable_struct_exists(_g, "ai4Deny") || _g.ai4Deny == undefined)      // pass 3 deny (leftovers)
        _g.ai4Deny = { list: ai4_deny_plays(_g, _p), idx: 0 };
    var _ds = _g.ai4Deny;
    while (_ds.idx < array_length(_ds.list)) {
        var _dp = _ds.list[_ds.idx]; _ds.idx += 1;
        if (_dp.denyVal > 0 && ai4_play_card(_g, _p, _dp.cardId, _dp.args, "deny ~" + string(round(_dp.denyVal)) + "p")) return;
    }
    _g.ai4Deny = undefined;
    game_resolve_moves(_g);                                                     // end the move phase
}

/// v4 hand-limit discard: protect the pellet RESERVE (the 6:4 split only works if the discard
/// policy defends the pellet side - the shared v1 resolver dumps pellets first and bled the
/// reserve every turn). Order: surplus copies -> junkiest card -> only then pellets (1s before 5s).
function ai4_resolve_discard(_g) {
    if (_g.pendingDiscard == undefined) return;
    var _p = _g.pendingDiscard.playerIdx;
    global.aiDbgP = _p;
    var _pl = _g.players[_p];
    var _copies = {};
    for (var _i = 0; _i < array_length(_pl.hand); _i++) {
        var _cid = _pl.hand[_i];
        _copies[$ _cid] = (variable_struct_exists(_copies, _cid) ? _copies[$ _cid] : 0) + 1;
        if (_copies[$ _cid] >= 3) {
            ai_dbg("v4 HAND LIMIT: discard surplus copy of " + _cid);
            game_discard_choice(_g, "gather", _i);
            return;
        }
    }
    static _junkRank = ["surveydrone", "shipsignal", "warp", "phosbatpod", "captainclone",
        "oatchirush", "rockstorm", "mine", "boulder", "pikpikbundle", "icebomb", "storm",
        "bitterspray", "bombrock", "rawmaterial", "spicyspray", "candypopbud",
        "queencandypopbud", "candypopbud2", "colorchangingposy", "ivoryandviolet", "pikminextinction"];
    if (array_length(_pl.hand) > 0) {
        var _best = 0, _bestRank = 999;
        for (var _i = 0; _i < array_length(_pl.hand); _i++) {
            var _r = 999;
            for (var _j = 0; _j < array_length(_junkRank); _j++) if (_junkRank[_j] == _pl.hand[_i]) { _r = _j; break; }
            if (_r < _bestRank) { _bestRank = _r; _best = _i; }
        }
        ai_dbg("v4 HAND LIMIT: discard card " + _pl.hand[_best]);
        game_discard_choice(_g, "gather", _best);
        return;
    }
    // pellets only as a last resort: smallest first (never the 5 while a 1 exists)
    var _worst = 0;
    for (var _i = 1; _i < array_length(_pl.pellets); _i++)
        if (pellet_def_get(_pl.pellets[_i]).sameTypeAmount < pellet_def_get(_pl.pellets[_worst]).sameTypeAmount) _worst = _i;
    ai_dbg("v4 HAND LIMIT: discard pellet " + _pl.pellets[_worst]);
    game_discard_choice(_g, "pellet", _worst);
}

/// The v4 BRAIN. gather = v4 plan/roll/draw; orders = v4 score (bodies); move = v4 cards then leftovers.
function ai4_step(_g) {
    global.aiDbgP = _g.activePlayer;
    switch (_g.phase) {
        case "gather": ai4_gather(_g); break;
        case "orders": ai4_orders(_g); break;
        case "move":   ai4_move(_g);   break;
    }
}

/// V — the lane's pile value to me: marginal points for banking it, floored so a
/// pile whose cards I already hold copies of still reads as worth pursuing.
function ai4_pile_value(_g, _p, _t) {
    return max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
}

/// m(endSpace) — the move multiplier for a treasure that ENDS on _endIdx this turn,
/// for player _p. Linear +25% per space closer to home from the centre (idx 3),
/// floored at 1.0 on the centre + far half, peaking at 2.0 when it banks (carried
/// off the board edge: _endIdx = -1 for p0 / 7 for p1). This is why a big jump
/// (oatchi rush to my doorstep) scores the high-m space it lands on in one action.
function ai4_move_mult(_p, _endIdx) {
    var _toward = (_p == 0) ? (3 - _endIdx) : (_endIdx - 3);   // spaces past centre toward my home
    return 1.0 + 0.25 * max(0, _toward);
}

/// grab — the value a lane's removals are unlocking: the move value of the pile
/// FROM WHERE IT SITS (V at centre, more if it's already advanced onto my side).
function ai4_grab_value(_g, _p, _t) {
    return ai4_pile_value(_g, _p, _t) * ai4_move_mult(_p, _t.idx);
}

// ---------------------------------------------------------------------------
// BRICK 2a — REMOVAL outcome enumeration.
// Each MY-ROAD obstacle (and a boss on the pile) is a removal task. An outcome is
// emitted only if I can pay for it AT ALL; its value is left to the optimiser, which
// escalates by how many of the lane's removals a subset includes. nOpen counts EVERY
// hard task in the lane (even ones I can't remove) so a lane with an un-openable
// blocker keeps a high divisor and correctly reads as low-value. Pikmin can only pay
// the FIRST blocker (ai_send returns 0 for anything behind it); items (bomb 10 /
// boulder 5 dmg, or 2x raw material to bridge) need no path, so they open deep tasks.
// ---------------------------------------------------------------------------
/// Can any colour I can FIELD (owned, or a board basic a pellet can redeem into) cross this hazard
/// space? A crossable hazard is a USELESS task: it doesn't count in the lane divisor and never
/// deserves a bridge - walking over it is free.
function ai4_hazard_crossable(_g, _p, _sp) {
    var _cols = [];
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) if (!arr_has(_cols, _toks[_i].typeId)) array_push(_cols, _toks[_i].typeId);
    var _basics = _g.boardDef.basicColors;
    for (var _i = 0; _i < array_length(_basics); _i++) if (!arr_has(_cols, _basics[_i])) array_push(_cols, _basics[_i]);
    for (var _i = 0; _i < array_length(_cols); _i++) {
        var _td = pikmin_type_get(_cols[_i]);
        // ROUND TRIP: useless only if passable BOTH ways - pikmin walk in toward the pile AND the
        // carry comes back out. (Exp-yellow crosses a chasm toward centre only - the carry home
        // still stalls on it, so a chasm stays a REAL task even with yellows fieldable.)
        if (game_type_can_enter(_td, _sp, true, false) && game_type_can_enter(_td, _sp, false, false)) return true;
    }
    return false;
}

function ai4_raw_count(_g, _p) {
    var _n = 0, _h = _g.players[_p].hand;
    for (var _i = 0; _i < array_length(_h); _i++) if (_h[_i] == "rawmaterial") _n += 1;
    return _n;
}

/// Removal outcomes for one treasure's my-road obstacles + a boss on its pile.
/// Each: { laneId, type:"remove", lane, idx, grab, nOpen, variants:[{str,need,enemyDef,items}] }.
function ai4_lane_removals(_g, _p, _t) {
    var _out = [];
    // NOTE: a hazard lane offers BOTH a move (carry with a crossing colour) AND bridge removals (for
    // when I can't field that colour) - the optimiser picks, so "don't bridge when a colour crosses"
    // falls out of value, not suppression. Enemy lanes have no move (carryReach false), only kills.
    var _obs = ai3_road_obstacles(_g, _p, _t.lane, _t.idx);
    var _tasks = [];
    for (var _i = 0; _i < array_length(_obs); _i++) {
        if (_obs[_i].soft) continue;
        if (_obs[_i].kind == "hazard"
            && ai4_hazard_crossable(_g, _p, _g.board.lanes[_t.lane].spaces[_obs[_i].idx])) continue; // useless task
        array_push(_tasks, _obs[_i]);
    }
    // MINES on my road (incl. under the pile - riders end turns there) are TASKS: they count in
    // the divisor, and an ARMED one (10+ pass-damage) is removed by DETONATING it - end 1
    // sacrificial pikmin on it, it goes off and is spent, the road is safe again.
    var _mines = [];
    for (var _mi = 0; _mi < array_length(_g.mines); _mi++) {
        var _mn = _g.mines[_mi];
        if (_mn.lane != _t.lane) continue;
        if ((_p == 0) ? (_mn.idx <= _t.idx) : (_mn.idx >= _t.idx)) array_push(_mines, _mn);
    }
    var _hasBoss = (_t.boss != undefined);
    var _nOpen = array_length(_tasks) + array_length(_mines) + (_hasBoss ? 1 : 0);
    if (_nOpen == 0) return _out;
    var _grab = ai4_grab_value(_g, _p, _t);
    var _hand = _g.players[_p].hand;
    var _raw = ai4_raw_count(_g, _p);

    for (var _i = 0; _i < array_length(_tasks); _i++) {
        var _o = _tasks[_i];
        var _variants = [];
        if (_o.kind == "enemy") {
            var _eDef = enemy_def_get(_o.enemyDefId);
            {   // NO token-based gate (death-spiral fix): an army wiped to 0 must still enumerate kills
                // pellets can fund; resolve_colors below is the correct FIELDABLE hurt+path test.
                var _req = ai_enemy_req(_g, _p, _eDef, _o.curHp);
                // REACHABILITY, not home quantity: a hurting colour can PATH here (0 if a blocker is
                // in front). Whether I have the STRENGTH is funding's job (home + pellets).
                // CLEAN kill only. A partial is never a TARGET (it only scores a flat 20 - not worth
                // draining a body from a carry); the AI commits enough to kill outright or leaves it.
                if (array_length(ai4_resolve_colors(_g, _p, _t.lane, _o.idx, "hurt", _eDef)) > 0) {
                    // EXPLOSIVE cost: pikmin sent into a surviving explosive's blast are casualties -
                    // budget them (fund+deploy). The target itself counts as killed (pass-A = no boom).
                    var _boomK = ai3_explosive_threat(_g, _p, _t.lane, _o.idx, [{ lane: _t.lane, idx: _o.idx }]);
                    array_push(_variants, { str: _req + _boomK, fund: _req + _boomK, need: "hurt", enemyDef: _eDef, items: [] });
                }
            }
            if (_o.curHp <= 10 && arr_has(_hand, "bombrock")) array_push(_variants, { str: 0, need: "any", enemyDef: undefined, items: ["bombrock"] });
            if (_o.curHp <= 5  && arr_has(_hand, "boulder"))  array_push(_variants, { str: 0, need: "any", enemyDef: undefined, items: ["boulder"] });
        } else if (_o.kind == "hazard") {
            if (_raw >= 2 && array_length(_g.boardDef.structures.bridges) > 0) array_push(_variants, { str: 0, need: "any", enemyDef: undefined, items: ["rawmaterial", "rawmaterial"] });
        } else if (_o.kind == "wall" || _o.kind == "emitter") {
            if (_o.hp <= 10 && arr_has(_hand, "bombrock")) array_push(_variants, { str: 0, need: "any", enemyDef: undefined, items: ["bombrock"] });
            if (_o.hp <= 5  && arr_has(_hand, "boulder"))  array_push(_variants, { str: 0, need: "any", enemyDef: undefined, items: ["boulder"] });
            if (ai_can_damage_struct(_g, _p, _o.structId)
                && array_length(ai4_resolve_colors(_g, _p, _t.lane, _o.idx, "struct", undefined)) > 0)
                array_push(_variants, { str: _o.hp, need: "struct", structId: _o.structId, items: [] });
        }
        if (array_length(_variants) > 0)
            // RESPAWN ruling: an enemy killed on the LAST turn of the day respawns before the opening
            // can be used - salvage value only (flat 20). Any other turn: full value (days are 5 turns).
            array_push(_out, { laneId: _t.lane, type: "remove", lane: _t.lane, idx: _o.idx, grab: _grab, nOpen: _nOpen, variants: _variants,
                stale: (_o.kind == "enemy" && _g.dayTrack >= global.rules.dayTrackLength) });
    }

    for (var _mi = 0; _mi < array_length(_mines); _mi++) {
        if (_mines[_mi].dmg < 10) continue;                        // unarmed: nothing to detonate yet
        array_push(_out, { laneId: _t.lane, type: "remove", lane: _t.lane, idx: _mines[_mi].idx, grab: _grab, nOpen: _nOpen,
            variants: [{ str: 1, need: "any", enemyDef: undefined, items: [] }] });   // 1 body ends on it -> boom -> spent
    }

    if (_hasBoss) {
        var _bDef = enemy_def_get(_t.boss.enemyDefId);
        var _bv = [];
        {   // no token-based gate (death-spiral fix) - resolve_colors is the fieldable test
            var _breq = ai_enemy_req(_g, _p, _bDef, _t.boss.curHp);
            if (array_length(ai4_resolve_colors(_g, _p, _t.lane, _t.idx, "hurt", _bDef)) > 0)   // reachable once the road is clear
                array_push(_bv, { str: _breq, need: "hurt", enemyDef: _bDef, items: [] });
        }
        if (_t.boss.curHp <= 10 && arr_has(_hand, "bombrock")) array_push(_bv, { str: 0, need: "any", enemyDef: undefined, items: ["bombrock"] });
        if (array_length(_bv) > 0)
            array_push(_out, { laneId: _t.lane, type: "remove", lane: _t.lane, idx: _t.idx, grab: _grab, nOpen: _nOpen, variants: _bv, boss: true });
    }
    return _out;
}

/// The escalating value of completing _k of a lane's _nOpen open removal-tasks.
/// Because a finished task STAYS finished, the open count drops and persists, so
/// each successive task is worth more: the terms are grab/nOpen, grab/(nOpen-1), …,
/// grab/(nOpen-k+1). Cracking a crowded lane is thus worth MORE than the flat grab
/// (3 tasks -> grab x (1/3+1/2+1) = 1.83·grab), which is the pull to spend items and
/// take the free, uncontested treasure; a lane I can only part-open stays cheap.
function ai4_removal_stack(_grab, _nOpen, _k) {
    var _v = 0;
    for (var _j = 0; _j < _k; _j++) {
        var _den = _nOpen - _j;
        if (_den <= 0) break;
        _v += _grab / _den;
    }
    return _v;
}
