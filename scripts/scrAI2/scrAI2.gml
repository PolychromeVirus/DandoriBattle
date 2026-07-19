// EXPERIMENTAL AI v2 - swing-driven planner. Picked per-seat on the menu ("AI v2");
// v1 (scrAI) stays intact as the control group. Reuses v1's battle-tested plumbing
// (ai_send, ai_first_blocker, marginals, commit gates) - the DIFFERENCES are the
// brain: what gets valued, kept, grown and thrown.
//
// ---- DESIGN (hashed out with the user, 2026-07-16) ----
//
// MASTER METRIC: NET SWING. The game is decided by point DIFFERENTIAL, so banking
// our pile and denying theirs are near-equal priorities - both are swing. Every
// plan scores: swing = (points we bank) + (points we verifiably deny them),
// then gets divided by time and taxed by body losses.
//
// FACTORS: worth to ME / worth to OPPONENT (set-aware marginals), OPPONENT ACCESS
// (untouchable piles have zero urgency), TIME (bankable before end? combo-aware:
// spicy/rush compress it), SPEED, OPPORTUNITY COST (the sort), CHAINING (candypop
// carriers mid-haul once their colour is no longer needed for the remaining path).
//
// BODY ECONOMY: losses priced by RECOVERY CAPACITY. Prefer no-loss lines; willing
// to trade when the swing pays. If the pellet buffer covers a disaster, DRAW EVERY
// TURN - cards are the sharper weapon.
//
// THE CLOCK (day 3): can't-bank-in-time plans keep only their DENIAL value; late
// game = deny + hunt single-turn bank combos.
//
// POSITION IS AN ASSET: no reflexive recall-to-HOME. Far-side idle groups get
// locally reassigned within their lane instead of teleporting home.
// ------------------------------------------------------------------------

/// My remaining TURNS. Each track tick is a FULL ROUND (both players act in it),
/// so a seat gets days x dayTrackLength turns total - do NOT halve. (The halved
/// version made v2 play day-3 panic ball from day 2 and skip killable bosses.)
function ai2_my_turns_left(_g) {
    var _total = global.rules.days * global.rules.dayTrackLength;
    var _cur = (_g.dayNumber - 1) * global.rules.dayTrackLength + _g.dayTrack;
    return max(1, _total - _cur + 1);
}

/// Recovery-capacity insurance: with the buffer funded, draw every single turn.
function ai2_gather(_g) {
    var _pl = _g.players[_g.activePlayer];
    var _tok = array_length(_pl.tokens);
    var _pel = array_length(_pl.pellets);

    // sim policy "planner" v4: gather DEFERS to base's insurance economy (below) -
    // the v3 "draw every turn tb>=2" spammed cards while the roster was fine. The
    // only planner-specific nudge is a TARGETED roll when a road colour is scarce
    // (feeds the off-colour redemption in the orders preamble); everything else is
    // base's proven roll-when-thin / draw-when-fat.
    var _polG = sim_policy_get(_g, _g.activePlayer);
    if (_polG != undefined && _polG.kind == "planner") {
        var _ob = ai2_planner_objective(_g, _g.activePlayer);
        if (_ob.needRoll && _pel < 2) { game_gather_roll(_g); return; } // roll only if not already pellet-stocked
    }

    // sim policy "numbers": hold the roster AT the cap. The policy's real lever is
    // refusing to spend bodies (ai_orders_commit); this just tops back up - roll
    // while short of the cap, draw once it's full. Pellets redeem to the cap in the
    // orders preamble, so rolling is what actually restores the count.
    var _pol = sim_policy_get(_g, _g.activePlayer);
    if (_pol != undefined && _pol.kind == "numbers") {
        var _capped = game_capped_count(_g, _g.activePlayer);
        if (_capped + _pel * 2 < global.rules.pikminBoardCap) { game_gather_roll(_g); return; }
        if (array_length(_pl.hand) < global.rules.handLimit - 1) game_gather_draw(_g); else game_gather_roll(_g);
        return;
    }

    var _insured = (_pel >= 2) || (_tok >= 20); // pellets cover a disaster, or roster is fat
    if (!_insured && (_tok + _pel * 4) < 16) { game_gather_roll(_g); return; }
    if (array_length(_pl.hand) < global.rules.handLimit - 1) game_gather_draw(_g);
    else game_gather_roll(_g);
}

/// Estimated turns to BANK a pile we take control of now. Combo-aware-ish:
/// spicy in hand compresses a haul; the rush rule compresses light piles.
function ai2_turns_to_bank(_g, _p, _idx, _w, _hasSpicy) {
    var _dist = (_p == 0) ? (_idx + 1) : (7 - _idx); // carries to leave the board
    var _perTurn = 1;
    if (global.expRules.rush && _w <= 6) _perTurn = 2;      // light piles can be rushed
    var _t = ceil(_dist / _perTurn) + 1;                     // +1 to take control
    if (_hasSpicy) _t = max(1, _t - 1);                      // one spicy double-turn
    return _t;
}

/// PLANNER turn objective (scrSim policy, user design 2026-07-17). TWO PHASES
/// (user prediction, confirmed by run 4: binding a specific pile BEFORE the
/// dice resolve lost ~70/game to stock v2):
///   INTENT (gather, _bind=false): abstract - mode + preferred target + which
///   RESOURCE is the binding constraint ("what needs to increase"), steering
///   roll vs draw. Held loosely.
///   BINDING (orders, _bind=true): recomputed AFTER pellets are redeemed and
///   cards drawn - a target must be VIABLE with the roster we actually have;
///   the preferred lane wins only if it survived the dice.
/// Primary selection (user rule, fixed from run 4's min-tb mistake): an INSTANT
/// bank (tb<=1) is a no-brainer; else the richest pile if it clears valueBar;
/// else the fewest-effective-turns pile. Oatchi Rush's END position is priced in.
/// mode "stop": the opponent's moving pile nears an unacceptable score.
/// mode "farm": nothing bankable/stoppable - convert idle bodies into future
/// economy (enemy rewards = pellets + cards, user 2026-07-17).
function ai2_planner_objective(_g, _p, _bind = false) {
    if (!variable_struct_exists(_g, "simPlanObj")) _g.simPlanObj = [undefined, undefined];
    var _stamp = string(_g.dayNumber) + "-" + string(_g.dayTrack) + "-" + string(_g.players[_p].turnsTaken);
    var _o = _g.simPlanObj[_p];
    if (_o != undefined && _o.stamp == _stamp && (!_bind || _o.bound)) return _o;

    var _pl = _g.players[_p];
    var _pol = sim_policy_get(_g, _p);
    var _threatBar = (_pol != undefined && variable_struct_exists(_pol, "threatBar")) ? _pol.threatBar : 200;
    var _hasOatchi = arr_has(_pl.hand, "oatchirush");
    var _hasSpicy = arr_has(_pl.hand, "spicyspray");
    var _myTurns = ai2_my_turns_left(_g);
    var _dirP = (_p == 0) ? 1 : -1;

    // threat: the opponent's most valuable MOVING pile (they hold the tug at weight)
    var _thVal = 0, _thLane = -1, _thIdx = -1, _thTb = 99;
    for (var _ti3 = 0; _ti3 < array_length(_g.treasures); _ti3++) {
        var _t3 = _g.treasures[_ti3];
        if (array_length(_t3.cards) == 0 || _t3.boss != undefined) continue; // bossed piles don't move
        var _w3 = treasure_def_get(_t3.cards[array_length(_t3.cards) - 1]).weight;
        var _oS3 = game_strength_at(_g, 1 - _p, _t3.lane, _t3.idx);
        var _mS3 = game_strength_at(_g, _p, _t3.lane, _t3.idx);
        if (_oS3 < _w3 || _oS3 <= _mS3) continue; // not actually moving
        var _v3 = max(ai_pile_marginal(_g, 1 - _p, _t3), ai_pile_raw(_t3) * 0.3);
        if (_v3 > _thVal) {
            _thVal = _v3; _thLane = _t3.lane; _thIdx = _t3.idx;
            _thTb = ai2_turns_to_bank(_g, 1 - _p, _t3.idx, _w3, false);
        }
    }
    // coverage: a held answer card can stop a carry without spending bodies
    var _covered = arr_has(_pl.hand, "bombrock") || arr_has(_pl.hand, "boulder")
        || (arr_has(_pl.hand, "rawmaterial") && array_length(_g.boardDef.structures.walls) > 0);

    // bank candidates: effective turns-to-bank (Oatchi end position priced in);
    // at BINDING time a target must also be VIABLE with the actual roster
    var _valueBar = (_pol != undefined && variable_struct_exists(_pol, "valueBar")) ? _pol.valueBar : 600;
    var _bLane = -1, _bIdx = -1, _bTb = 99, _bVal = -1, _bOat = false, _bW = 0;
    var _instLane = -1, _instIdx = -1, _instVal = -1, _instTb = 99, _instOat = false, _instW = 0;
    var _richLane = -1, _richIdx = -1, _richVal = -1, _richTb = 99, _richOat = false, _richW = 0;
    for (var _ti4 = 0; _ti4 < array_length(_g.treasures); _ti4++) {
        var _t4 = _g.treasures[_ti4];
        if (array_length(_t4.cards) == 0 || _t4.boss != undefined) continue; // sieges stay auction business
        var _w4 = treasure_def_get(_t4.cards[array_length(_t4.cards) - 1]).weight;
        var _blk4 = ai_first_blocker(_g, _p, _t4.lane, _t4.idx);
        var _tb4 = ai2_turns_to_bank(_g, _p, _t4.idx, _w4, _hasSpicy);
        if (_blk4 != undefined && _blk4.kind != "treasure") _tb4 += 1; // clear the road first
        var _oat4 = false;
        if (_hasOatchi) {
            var _onTheirs = (_p == 0) ? (_t4.idx > 3) : (_t4.idx < 3);
            if (_onTheirs) {
                var _clear4 = true;
                var _s4 = (_p == 0) ? 0 : 6;
                while (_s4 != _t4.idx) { if (game_space_has_card(_g, _t4.lane, _s4)) { _clear4 = false; break; } _s4 += _dirP; }
                if (_clear4) {
                    var _tbO = ai2_turns_to_bank(_g, _p, clamp(_t4.idx - _dirP * 2, 0, 6), _w4, _hasSpicy);
                    if (_tbO < _tb4) { _tb4 = _tbO; _oat4 = true; }
                }
            }
        }
        if (_tb4 > _myTurns) continue; // can't bank in time
        // BINDING viability: can the roster we ACTUALLY have make progress here?
        // Bodies ALREADY on the target count first - probe bug 2026-07-17: a
        // LATCHED carry flunked viability because HOME couldn't re-reach the pile
        // (water gate, no blues in reserve), and the binding abandoned a winning tug.
        if (_bind) {
            var _via4 = false;
            var _isPile4 = (_blk4 == undefined || _blk4.kind == "treasure");
            var _tgt4 = _isPile4 ? _t4.idx : _blk4.idx;
            var _myAt4 = game_strength_at(_g, _p, _t4.lane, _tgt4);
            if (_myAt4 > 0) {
                // squad already deployed there - no reach needed. EXCEPT a
                // STALLED TUG (probe 0:1040, 2026-07-17): latched but tied/losing
                // at the pile with home unable to reinforce = the carry cannot
                // move, ever. The bodies keep holding automatically (busy tokens
                // are never recalled) - that's the user's "keep just enough to
                // contest" - but the OBJECTIVE must move on, not re-bind the
                // stalemate every turn until the game ends.
                var _oppAt4 = game_strength_at(_g, 1 - _p, _t4.lane, _tgt4);
                if (_isPile4 && _oppAt4 >= _myAt4
                    && ai_send(_g, _p, _t4.lane, _t4.idx, 99, undefined, true) <= 0) {
                    _via4 = false; // held, not winnable - next target please
                } else {
                    _via4 = true;
                }
            } else if (_isPile4) {
                _via4 = ai_send(_g, _p, _t4.lane, _t4.idx, 99, undefined, true) > 0;
            } else if (_blk4.kind == "enemy") {
                var _bd4 = enemy_def_get(_blk4.enemy.enemyDefId);
                _via4 = ai_can_group_hurt(_g, _p, _bd4)
                    && ai_send(_g, _p, _t4.lane, _blk4.idx, ai_enemy_req(_g, _p, _bd4, _blk4.enemy.curHp), _bd4, true) > 0;
            } else {
                _via4 = ai_can_damage_struct(_g, _p, _g.board.lanes[_t4.lane].spaces[_blk4.idx].structure.structId);
            }
            if (!_via4) continue;
        }
        var _v4 = max(ai_pile_marginal(_g, _p, _t4), ai_pile_raw(_t4) * 0.3);
        if (_tb4 <= 1 && _v4 > _instVal) { _instVal = _v4; _instLane = _t4.lane; _instIdx = _t4.idx; _instTb = _tb4; _instOat = _oat4; _instW = _w4; }
        // rich rule considers ONLY reasonably-FAST piles (probe 0:1010, 2026-07-17:
        // "richest regardless of tb" tunnel-visioned a tb6 fat pile for 15 turns
        // with a full roster and banked ZERO - base's swing/TIME auction avoids
        // exactly this). A fat-but-slow pile falls through to the fastest-pile
        // pick: banking SOMETHING beats inching toward the unreachable.
        if (_tb4 <= 3 && _v4 > _richVal) { _richVal = _v4; _richLane = _t4.lane; _richIdx = _t4.idx; _richTb = _tb4; _richOat = _oat4; _richW = _w4; }
        if (_tb4 < _bTb || (_tb4 == _bTb && _v4 > _bVal)) { _bTb = _tb4; _bVal = _v4; _bLane = _t4.lane; _bIdx = _t4.idx; _bOat = _oat4; _bW = _w4; }
    }
    // primary selection (user rule): INSTANT no-brainer > rich-AND-fast > cheapest
    if (_instLane >= 0) { _bLane = _instLane; _bIdx = _instIdx; _bTb = _instTb; _bVal = _instVal; _bOat = _instOat; _bW = _instW; }
    else if (_richLane >= 0 && _richVal > _valueBar) { _bLane = _richLane; _bIdx = _richIdx; _bTb = _richTb; _bVal = _richVal; _bOat = _richOat; _bW = _richW; }

    var _mode = "none";
    if (_thLane >= 0 && _thVal >= _threatBar && _thTb <= 2) _mode = "stop";
    else if (_bLane >= 0) _mode = "bank";
    // farming is an EARLY move (user): rewards need runway to convert (kill ->
    // pellets -> bodies -> carry). Probe bug 2026-07-17: ungated farm burned the
    // entire last 5 turns fighting for rewards that could never become points
    // while the opponent's lead sat uncontested. Too late to farm -> "none":
    // the plain auction runs the turn (deny-weighted piles + stalls, no boost).
    else if (_myTurns >= 4) _mode = "farm";

    // latched: we already hold the primary tug - gather stops serving the primary
    var _latched = (_mode == "bank" && game_strength_at(_g, _p, _bLane, _bIdx) >= _bW && _bW > 0);

    // gather steering: WHICH RESOURCE is the binding constraint?
    //  - colours the primary road lacks -> ROLL (a wrong-colour pellet still
    //    redeems as the needed colour at offTypeAmount - rolls have a worst-case
    //    floor, so this is arithmetic, not prayer)
    //  - a missing answer/combo card -> DRAW
    //  - LATCHED (already holding the primary tug): the carry needs nothing -
    //    buffer only if the opponent can actually reach it, else flexibility
    //    (draws for options, rolls to keep the pellet reserve stocked)
    var _needRoll = false;
    var _wantColor = "";
    if (_bLane >= 0) {
        var _rn2 = ai2_road_needs(_g, _p, _bLane, _bIdx);
        for (var _gi2 = 0; _gi2 < array_length(_rn2.gates) && !_needRoll; _gi2++) {
            var _ans2 = ai2_gate_answers(_rn2.gates[_gi2]);
            var _own2 = 0, _buyCol2 = "";
            for (var _ai2 = 0; _ai2 < array_length(_ans2); _ai2++) {
                if (arr_has(_g.boardDef.basicColors, _ans2[_ai2]) && _buyCol2 == "") _buyCol2 = _ans2[_ai2];
                for (var _tk2 = 0; _tk2 < array_length(_pl.tokens); _tk2++) if (_pl.tokens[_tk2].typeId == _ans2[_ai2]) _own2 += 1;
            }
            if (_own2 < 2 && _buyCol2 != "") { _needRoll = true; _wantColor = _buyCol2; }
        }
    }
    var _needDraw = (_thLane >= 0 && !_covered) || (_mode == "bank" && _bTb >= 2 && !_hasSpicy);
    if (_latched) {
        var _oppLane5 = 0;
        for (var _si5 = 0; _si5 <= 6; _si5++) _oppLane5 += game_strength_at(_g, 1 - _p, _bLane, _si5);
        // buffer the carry only if it's interceptable; and cap the flexibility
        // draws at ~7 cards (probe: hands of 9-10 hoarded cards while homeStr hit
        // 0 - past the useful hand size, options rot and the reserve starves)
        _needRoll = (_oppLane5 >= 2) || (array_length(_pl.hand) >= 7);
        _wantColor = "";
        _needDraw = !_needRoll;       // otherwise: flexibility
    }
    if (_mode == "farm") _needRoll = true; // farming turns also want dice for the reserve

    _o = { stamp: _stamp, bound: _bind, mode: _mode, bankLane: _bLane, bankIdx: _bIdx, bankTb: _bTb, useOatchi: _bOat,
        latched: _latched, wantColor: _wantColor,
        thLane: _thLane, thIdx: _thIdx, thVal: _thVal, thTb: _thTb, covered: _covered,
        needRoll: _needRoll, needDraw: _needDraw };
    _g.simPlanObj[_p] = _o;
    ai_dbg("PLANNER " + (_bind ? "binding" : "intent") + ": " + _mode
        + (_mode == "bank" ? " lane" + string(_bLane + 1) + " tb" + string(_bTb) + (_bOat ? " via OATCHI" : "") + (_latched ? " LATCHED" : "") : "")
        + (_mode == "stop" ? " lane" + string(_thLane + 1) + " (" + string(round(_thVal)) + "p tb" + string(_thTb) + ")" : "")
        + (_wantColor != "" ? " want:" + _wantColor : "")
        + (_needRoll ? " [ROLL]" : "") + (_needDraw ? " [DRAW]" : ""));
    return _o;
}

// ---- THE MIND: one persistent long-term plan per seat ----
// Formed by looking at the whole board, then KEPT - re-evaluated only when the
// game state MEANINGFULLY changes (a treasure banked by either side, the boss
// population changes, a new day). Growth, building and item use all execute in
// service of the plan; leftovers hedge.

/// Fingerprint of "meaningful change" - plan survives until this string moves.
function ai2_state_epoch(_g) {
    var _bosses = 0;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) if (_g.treasures[_ti].boss != undefined) _bosses += 1;
    return string(array_length(_g.players[0].collected)) + "_" + string(array_length(_g.players[1].collected))
         + "_" + string(_bosses) + "_" + string(_g.dayNumber);
}

/// Walk MY road (home edge -> _toIdx) in a lane: gates we can't cross, blocker hp.
function ai2_road_needs(_g, _p, _lane, _toIdx) {
    var _out = { gates: [], needBridge: false, blockerHp: 0, gateIdx: -1 };
    var _cols = [];
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) if (!arr_has(_cols, _toks[_i].typeId)) array_push(_cols, _toks[_i].typeId);
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    while (_s != _toIdx) {
        var _sp = _g.board.lanes[_lane].spaces[_s];
        if (_sp.enemy != undefined) _out.blockerHp += _sp.enemy.curHp;
        if (_sp.structure == undefined && _sp.kind == "hazard" && _sp.hazard != "poison") {
            // record the element as a colour need even if we CAN currently cross:
            // "passable because we own one blue" is one death away from a sealed
            // lane - the plan must keep the answer squad DEEP, not merely extant
            if (!arr_has(_out.gates, _sp.hazard)) array_push(_out.gates, _sp.hazard);
            var _passable = false;
            for (var _c = 0; _c < array_length(_cols) && !_passable; _c++) {
                if (game_type_can_enter(pikmin_type_get(_cols[_c]), _sp, true, false)) _passable = true;
            }
            if (!_passable) {
                if (_sp.hazard == "chasm") _out.needBridge = true;
                if (_out.gateIdx < 0) _out.gateIdx = _s;
            }
        }
        _s += _dir;
    }
    return _out;
}

/// Which colours answer a gate element (cross it on their own)?
function ai2_gate_answers(_elem) {
    var _ids = ["red", "yellow", "blue", "purple", "white", "rock", "winged", "ice", "bulbmin"];
    var _out = [];
    for (var _i = 0; _i < array_length(_ids); _i++) {
        var _td = pikmin_type_get(_ids[_i]);
        var _ok = false;
        if (arr_has(_td.traits, "flies_over_hazards")) _ok = true;
        else if (_elem == "height") _ok = arr_has(_td.traits, "climbs_height");
        else if (_elem != "chasm") _ok = arr_has(_td.immunities, _elem);
        if (_ok) array_push(_out, _ids[_i]);
    }
    return _out;
}

/// Look at the board, pick the lane to weight heavier, derive what executing it
/// NEEDS (bridge? which colours?). Jittered so seats develop different opinions.
/// Score ONE lane for the mind, WITHOUT the personality jitter (the caller applies
/// that). Split out of ai2_form_plan so the sim's lane audit can read the
/// evaluator's actual components against tournament ground truth - if this logic
/// changes, the audit automatically audits the new version.
function ai2_lane_score(_g, _p, _lane) {
    var _swing = 0, _toIdx = 3, _hasPile = false, _bossed = false;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (_t.lane != _lane || array_length(_t.cards) == 0) continue;
        _hasPile = true; _toIdx = _t.idx;
        var _raw = ai_pile_raw(_t);
        _swing += max(ai_pile_marginal(_g, _p, _t), _raw * 0.3) + max(ai_pile_marginal(_g, 1 - _p, _t), _raw * 0.3) * 0.5;
        if (_t.boss != undefined) _bossed = true;
    }
    if (!_hasPile) return { hasPile: false, swing: 0, bossed: false, toIdx: _toIdx,
        needs: undefined, gates: 0, blockerHp: 0, difficulty: 1, score: -1 };
    if (_bossed) _swing *= 0.55; // bossed lane = slower, uncertain
    var _needs = ai2_road_needs(_g, _p, _lane, _toIdx);
    var _difficulty = 1 + array_length(_needs.gates) * 0.8 + _needs.blockerHp * 0.06;
    return { hasPile: true, swing: _swing, bossed: _bossed, toIdx: _toIdx, needs: _needs,
        gates: array_length(_needs.gates), blockerHp: _needs.blockerHp,
        difficulty: _difficulty, score: _swing / _difficulty };
}

function ai2_form_plan(_g, _p) {
    var _bestLane = 0, _bestScore = -1, _bestNeeds = undefined;
    var _laneScores = array_create(_g.board.laneCount, -1); // for the sim's spread policy
    var _laneToIdx  = array_create(_g.board.laneCount, 3);
    for (var _lane = 0; _lane < _g.board.laneCount; _lane++) {
        var _ls = ai2_lane_score(_g, _p, _lane);
        _laneToIdx[_lane] = _ls.toIdx;
        if (!_ls.hasPile) continue;
        var _score = _ls.score * random_range(0.85, 1.15); // personality jitter
        _laneScores[_lane] = _score;
        if (_score > _bestScore) { _bestScore = _score; _bestLane = _lane; _bestNeeds = _ls.needs; }
    }

    // --- sim policy override: the tournament forces the plan rather than deriving
    // --- it, so a whole-game strategy can be held and measured (scrSim). Outside
    // --- the tournament sim_policy_get answers undefined and nothing below runs.
    var _lanes = [_bestLane];
    var _pol = sim_policy_get(_g, _p);
    if (_pol != undefined) {
        if (_pol.kind == "lane") {
            _bestLane = clamp(_pol.lane, 0, _g.board.laneCount - 1);
            _bestNeeds = ai2_road_needs(_g, _p, _bestLane, _laneToIdx[_bestLane]);
            _lanes = [_bestLane];
        } else if (_pol.kind == "spread") {
            // work the best TWO lanes at once: keep the winner, add the runner-up
            var _second = -1, _secondScore = -1;
            for (var _l2 = 0; _l2 < _g.board.laneCount; _l2++) {
                if (_l2 == _bestLane) continue;
                if (_laneScores[_l2] > _secondScore) { _secondScore = _laneScores[_l2]; _second = _l2; }
            }
            if (_second >= 0 && _secondScore > 0) _lanes = [_bestLane, _second];
        } else if (_pol.kind == "contestN" || _pol.kind == "contestR") {
            // contest-aware refocus: discount lanes by where the opponent is, then
            // re-pick. contestN PREDICTS via their evaluator (deterministic, shared
            // -> mirrors may just collide one level up - that's what the tournament
            // tests); contestR OBSERVES their deployed bodies (turn 1 = no discount
            // = base behaviour, then mirrors decorrelate off the real board).
            var _adj = array_create(_g.board.laneCount, 0);
            for (var _l3 = 0; _l3 < _g.board.laneCount; _l3++) {
                if (_laneScores[_l3] < 0) continue;
                if (_pol.kind == "contestN") {
                    var _os = ai2_lane_score(_g, 1 - _p, _l3);
                    if (_os.hasPile) _adj[_l3] = _os.score * 0.6; // subtract 60% of their want
                } else {
                    var _ostr = 0; // their bodies standing anywhere in the lane
                    for (var _si2 = 0; _si2 <= 6; _si2++) _ostr += game_strength_at(_g, 1 - _p, _l3, _si2);
                    _adj[_l3] = _laneScores[_l3] * min(1, _ostr * 0.10); // -10% per body, capped
                }
            }
            var _cBest = -1, _cScore = -1;
            for (var _l3 = 0; _l3 < _g.board.laneCount; _l3++) {
                if (_laneScores[_l3] < 0) continue;
                var _s3 = _laneScores[_l3] - _adj[_l3];
                if (_s3 > _cScore) { _cScore = _s3; _cBest = _l3; }
            }
            if (_cBest >= 0) {
                _bestLane = _cBest;
                _bestNeeds = ai2_road_needs(_g, _p, _bestLane, _laneToIdx[_bestLane]);
                _lanes = [_bestLane];
            }
        } else if (_pol.kind == "tiered") {
            // user-designed tiered heuristic (2026-07-17). Vacuum rule: take the
            // highest-VALUE pile if it's rich (> valueBar), else the free-est
            // (lowest road difficulty). On CONTEST of the focus lane (opponent
            // bodies >= contestMin standing in it): demote and refocus by the same
            // rule - the shared orders logic still leaves a stall on the old pile
            // (piles keep full value off-plan). Transitions are STICKY: state lives
            // on _g.simTier across replans and only moves on a contest event. The
            // contest probes failed exactly by re-deriving every epoch and flapping
            // (2.1-2.4 switches/g vs base 1.4); this one holds until pushed.
            // NOT implemented yet: wall-off-to-keep-it-free (v2 DISRUPT partially
            // covers), stall budget sizing, the effect-value currency.
            if (!variable_struct_exists(_g, "simTier")) _g.simTier = [undefined, undefined];
            var _vBar = variable_struct_exists(_pol, "valueBar") ? _pol.valueBar : 600;
            var _cMin = variable_struct_exists(_pol, "contestMin") ? _pol.contestMin : 2;
            var _lcT = _g.board.laneCount;
            var _valT = array_create(_lcT, 0);
            var _effT = array_create(_lcT, 99999);
            var _conT = array_create(_lcT, false);
            for (var _l4 = 0; _l4 < _lcT; _l4++) {
                for (var _ti2 = 0; _ti2 < array_length(_g.treasures); _ti2++) {
                    var _t2 = _g.treasures[_ti2];
                    if (_t2.lane == _l4 && array_length(_t2.cards) > 0) _valT[_l4] += ai_pile_raw(_t2);
                }
                if (_valT[_l4] <= 0) continue;
                _effT[_l4] = ai2_lane_score(_g, _p, _l4).difficulty;
                var _osT = 0;
                for (var _si3 = 0; _si3 <= 6; _si3++) _osT += game_strength_at(_g, 1 - _p, _l4, _si3);
                _conT[_l4] = (_osT >= _cMin);
            }
            var _stT = _g.simTier[_p];
            var _pickT = -1;
            // stay while the focus lane is alive and free - the sticky default
            if (_stT != undefined && _valT[_stT.lane] > 0 && !_conT[_stT.lane]) _pickT = _stT.lane;
            if (_pickT < 0) {
                var _bV = -1, _bVL = -1, _bE = 99999, _bEL = -1;
                for (var _l4 = 0; _l4 < _lcT; _l4++) {
                    if (_valT[_l4] <= 0 || _conT[_l4]) continue;
                    if (_valT[_l4] > _bV) { _bV = _valT[_l4]; _bVL = _l4; }
                    if (_effT[_l4] < _bE) { _bE = _effT[_l4]; _bEL = _l4; }
                }
                if (_bVL >= 0) _pickT = (_bV > _vBar) ? _bVL : _bEL;
                if (_pickT < 0) _pickT = _bestLane; // everything contested: fight for the mind's best
            }
            _g.simTier[_p] = { lane: _pickT };
            _bestLane = _pickT;
            _bestNeeds = ai2_road_needs(_g, _p, _bestLane, _laneToIdx[_bestLane]);
            _lanes = [_bestLane];
        }
    }

    // colours the plan needs: gate answers, then the lane's enemy demands
    var _needCols = [];
    if (_bestNeeds != undefined) {
        for (var _gi = 0; _gi < array_length(_bestNeeds.gates); _gi++) {
            var _ans = ai2_gate_answers(_bestNeeds.gates[_gi]);
            for (var _ai = 0; _ai < array_length(_ans); _ai++) if (!arr_has(_needCols, _ans[_ai])) array_push(_needCols, _ans[_ai]);
        }
    }
    // every focus lane's enemies make demands (normally that's just the one lane;
    // the sim's spread policy carries two)
    for (var _li = 0; _li < array_length(_lanes); _li++) {
        for (var _si = 0; _si <= 6; _si++) {
            var _en = _g.board.lanes[_lanes[_li]].spaces[_si].enemy;
            if (_en == undefined) continue;
            var _ed = enemy_def_get(_en.enemyDefId);
            var _rq = game_attack_requirement(_ed);
            if (_rq != undefined && !arr_has(_needCols, _rq.typeId)) array_push(_needCols, _rq.typeId);
            if (_ed.defenseElement == "height") {
                if (!arr_has(_needCols, "yellow")) array_push(_needCols, "yellow");
                if (!arr_has(_needCols, "winged")) array_push(_needCols, "winged");
            }
        }
    }
    var _colStr = "";
    for (var _ci = 0; _ci < array_length(_needCols); _ci++) _colStr += (_ci > 0 ? "," : "") + _needCols[_ci];
    var _laneStr = "";
    for (var _li = 0; _li < array_length(_lanes); _li++) _laneStr += (_li > 0 ? "+" : "") + string(_lanes[_li] + 1);
    ai_dbg("v2 PLAN: focus lane " + _laneStr
        + ((_bestNeeds != undefined && _bestNeeds.needBridge) ? " (needs BRIDGE)" : "")
        + (_colStr != "" ? " needs [" + _colStr + "]" : ""));
    // lane = the primary (bridge/candypop execution targets it); lanes = every
    // lane the candidate bias treats as hot
    return { lane: _bestLane, lanes: _lanes, needBridge: (_bestNeeds != undefined && _bestNeeds.needBridge), needColors: _needCols, epoch: ai2_state_epoch(_g) };
}

/// The plan accessor: keep working the stored plan until the epoch moves.
function ai2_mind(_g, _p) {
    if (!variable_struct_exists(_g, "ai2MindArr")) _g.ai2MindArr = [undefined, undefined];
    if (_g.ai2MindArr[_p] == undefined || _g.ai2MindArr[_p].epoch != ai2_state_epoch(_g)) {
        var _prevMind = _g.ai2MindArr[_p];
        _g.ai2MindArr[_p] = ai2_form_plan(_g, _p);
        sim_note_replan(_g, _p, _prevMind, _g.ai2MindArr[_p]); // churn instrumentation (inert outside the sim)
    }
    return _g.ai2MindArr[_p];
}

/// Growth IN SERVICE OF THE PLAN: buy the purchasable needed colour we own least
/// of; once the key squad exists (6+), hedge with the board-wide heuristic.
function ai2_pick_growth_color(_g, _p) {
    var _mind = ai2_mind(_g, _p);
    var _best = "", _bestN = 9999;
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_mind.needColors); _i++) {
        var _c = _mind.needColors[_i];
        if (!arr_has(_g.boardDef.basicColors, _c)) continue;
        var _n = 0;
        for (var _t = 0; _t < array_length(_toks); _t++) if (_toks[_t].typeId == _c) _n += 1;
        if (_n < _bestN) { _bestN = _n; _best = _c; }
    }
    if (_best != "" && _bestN < 6) return _best;
    return ai_pick_growth_color(_g, _p);
}

/// Orders phase, paced like v1 (plan once, commit one visible move per tick).
function ai2_step(_g) {
    global.aiDbgP = _g.activePlayer;
    switch (_g.phase) {
        case "gather": ai2_gather(_g); break;
        case "orders": ai2_orders(_g); break;
        case "move":   ai2_move(_g); break;
    }
}

function ai2_orders(_g) {
    if (!variable_struct_exists(_g, "ai2Plan") || _g.ai2Plan == undefined) {
        _g.ai2Plan = ai2_orders_plan(_g);
        return;
    }
    var _plan = _g.ai2Plan;
    while (_plan.idx < array_length(_plan.cands)) {
        var _moved = ai_orders_commit(_g, _plan.cands[_plan.idx], _plan.risk, _plan.scarce);
        _plan.idx += 1;
        if (_moved) return; // one visible deployment per tick
    }
    ai_orders_finish(_g, _plan); // leftover dump (with can't-tie guard) + orders done
    _g.ai2Plan = undefined;
}

function ai2_orders_plan(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];

    // --- economy preamble: redeem pellets, play posy (colour = board demand) ---
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
        var _col = arr_has(_g.boardDef.basicColors, _pDef.color) ? _pDef.color : ai2_pick_growth_color(_g, _p);
        // planner: OFF-COLOUR redemption (engine mechanic no AI ever used - user
        // clarified 2026-07-17): a wrong-colour pellet redeems as the colour the
        // plan actually needs at offTypeAmount (~half rate). Worth the tax while
        // the needed squad is thin; reads the INTENT (binding happens after this).
        var _polR = sim_policy_get(_g, _p);
        if (_polR != undefined && _polR.kind == "planner") {
            var _obR = ai2_planner_objective(_g, _p);
            if (_obR.wantColor != "" && _obR.wantColor != _pDef.color) {
                var _ownW = 0;
                for (var _tw = 0; _tw < array_length(_pl.tokens); _tw++) if (_pl.tokens[_tw].typeId == _obR.wantColor) _ownW += 1;
                if (_ownW < 4) _col = _obR.wantColor;
            }
        }
        game_play_pellet(_g, 0, _col);
    }
    var _hi = 0;
    while (_hi < array_length(_pl.hand)) {
        if (_pl.hand[_hi] == "colorchangingposy" && game_capped_count(_g, _p) <= global.rules.pikminBoardCap - 3) {
            if (game_play_gather(_g, _hi, { color: ai2_pick_growth_color(_g, _p) })) continue;
        }
        _hi += 1;
    }

    // --- POSITION-PRESERVING recall: idle tokens on OUR side come home (reserve
    // --- refill); idle far-side groups are ASSETS and get reassigned locally ---
    var _tokens = _pl.tokens;
    var _mySideLo = (_p == 0) ? 0 : 4;
    var _mySideHi = (_p == 0) ? 2 : 6;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        var _loc = _tok.loc;
        if (_loc.kind != "space") continue;
        if (token_is_disabled(_tok)) continue;
        if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue; // trapped
        var _sp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
        if (_sp.enemy != undefined || _sp.structure != undefined || game_treasure_at(_g, _loc.lane, _loc.idx) != undefined) continue; // busy
        if (_loc.idx >= _mySideLo && _loc.idx <= _mySideHi) _tok.loc = { kind: "home" }; // own side: refill the reserve
        // far side / centre: stay put - position past one-way terrain can't be rebought
    }
    // local reassignment: idle far-side groups walk to the best target in THEIR lane
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        for (var _si = 0; _si <= 6; _si++) {
            if (_si >= _mySideLo && _si <= _mySideHi) continue;
            var _grpLoc = { kind: "space", lane: _laneIdx, idx: _si };
            var _grp = game_tokens_at(_g, _p, _grpLoc);
            if (array_length(_grp) == 0) continue;
            var _gsp = _g.board.lanes[_laneIdx].spaces[_si];
            if (_gsp.enemy != undefined || _gsp.structure != undefined || game_treasure_at(_g, _laneIdx, _si) != undefined) continue; // already engaged
            // nearest card in this lane they can legally walk to
            var _bestD = 99, _bestIdx = -1;
            for (var _ti2 = 0; _ti2 <= 6; _ti2++) {
                if (_ti2 == _si || !game_space_has_card(_g, _laneIdx, _ti2)) continue;
                var _d = abs(_ti2 - _si);
                if (_d < _bestD && game_move_legal(_g, _p, _grp[0].typeId, _grpLoc, { kind: "space", lane: _laneIdx, idx: _ti2 })) {
                    _bestD = _d; _bestIdx = _ti2;
                }
            }
            if (_bestIdx >= 0) {
                game_order_move(_g, _grpLoc, { kind: "space", lane: _laneIdx, idx: _bestIdx }, game_counts_struct(_g, _p, _grpLoc));
                ai_dbg("local reassign: lane" + string(_laneIdx + 1) + " idx" + string(_si) + " -> idx" + string(_bestIdx));
            }
        }
    }

    var _risk = ai_risk_pref(_g, _p);
    var _scarce = ai_scarcity(_g, _p);
    var _myTurns = ai2_my_turns_left(_g);
    var _hasSpicy = false;
    for (var _h = 0; _h < array_length(_pl.hand); _h++) if (_pl.hand[_h] == "spicyspray") _hasSpicy = true;
    ai_dbg("");
    ai_dbg("===== v2 TURN P" + string(_p + 1) + "  Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength)
        + ")  score " + string(game_realized_score(_g, _p)) + " vs " + string(game_realized_score(_g, 1 - _p))
        + "  myTurns=" + string(_myTurns) + "  homeStr=" + string(ai_home_strength(_g, _p)) + " =====");

    // --- SWING-scored candidates ---
    var _cands = [];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _raw = ai_pile_raw(_t);
        var _wMe = max(ai_pile_marginal(_g, _p, _t), _raw * 0.30);
        var _wOpp = max(ai_pile_marginal(_g, 1 - _p, _t), _raw * 0.30);
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        // OPPONENT ACCESS: can they plausibly take this? (bodies in the lane, or the
        // pile sits at/beyond the centre where their reserve can reach it)
        var _oppLaneStr = 0;
        var _otoks = _g.players[1 - _p].tokens;
        for (var _oi = 0; _oi < array_length(_otoks); _oi++) {
            if (_otoks[_oi].loc.kind == "space" && _otoks[_oi].loc.lane == _t.lane) _oppLaneStr += pikmin_type_get(_otoks[_oi].typeId).carry;
        }
        var _onTheirHalf = (_p == 0) ? (_t.idx >= 3) : (_t.idx <= 3);
        var _oppAccess = (_oppLaneStr > 0) || _onTheirHalf;

        var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
        var _tBank = ai2_turns_to_bank(_g, _p, _t.idx, _w, _hasSpicy);
        if (_blk != undefined && _blk.kind != "treasure") _tBank += 1; // clear the road first

        var _canBank = (_tBank <= _myTurns);
        var _swing = (_canBank ? _wMe : 0) + (_oppAccess ? _wOpp : 0);
        if (_swing <= 0) continue;
        var _score = _swing / max(1, _tBank);

        if (_t.boss != undefined && _blk == undefined) {
            var _bDef = enemy_def_get(_t.boss.enemyDefId);
            if (!ai_can_group_hurt(_g, _p, _bDef)) { ai_dbg("v2 SKIP boss " + _bDef.name + ": can't hurt it"); continue; }
            // killable in time? crude dps = current dry reach
            var _dps = max(1, ai_send(_g, _p, _t.lane, _t.idx, _t.boss.curHp, _bDef, true));
            var _tKill = ceil(_t.boss.curHp / _dps);
            // a boss we can't kill AND bank in time is worth NOTHING - killing it
            // just opens the pile for the opponent. No oppAccess exception (that was
            // backwards) - fighting a boss never denies anything.
            if (_tKill + _tBank > _myTurns) { ai_dbg("v2 SKIP boss " + _bDef.name + ": t" + string(_tKill + _tBank) + " > " + string(_myTurns) + " turns left"); continue; }
            _score = (_swing + ai_reward_value(_bDef)) / max(1, _tKill + _tBank);
            array_push(_cands, { lane: _t.lane, idx: _t.idx, req: ai_enemy_req(_g, _p, _bDef, _t.boss.curHp), value: _score * 10, enemyDef: _bDef, kind: "boss", oppS: 0, myS: 0, w: _w, why: "v2 boss " + _bDef.name + " swing" + string(round(_swing)) + " t" + string(_tKill + _tBank) });
            continue;
        }
        if (_blk == undefined) {
            var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
            var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
            var _margin = min(max(0, _oppLaneStr - _oppS), 2);
            var _req = max(_w, _oppS + 1 + _margin) - _myS;
            if (_req > 0) {
                array_push(_cands, { lane: _t.lane, idx: _t.idx, req: _req, value: _score * 10, enemyDef: undefined, kind: "pile", oppS: _oppS, myS: _myS, w: _w, tb: _tBank, canBank: _canBank, why: "v2 pile " + string(_raw) + "p swing" + string(round(_swing)) + " t" + string(_tBank) + (_canBank ? "" : " DENY-ONLY") });
            }
        } else if (_blk.kind == "enemy") {
            var _eDef = enemy_def_get(_blk.enemy.enemyDefId);
            if (ai_can_group_hurt(_g, _p, _eDef)) {
                array_push(_cands, { lane: _t.lane, idx: _blk.idx, req: ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp), value: _score * 8.5 + ai_reward_value(_eDef), enemyDef: _eDef, kind: "enemy", oppS: 0, myS: 0, why: "v2 road: " + _eDef.name + " opens swing" + string(round(_swing)) });
            }
        } else if (_blk.kind == "structure") {
            var _sSp = _g.board.lanes[_t.lane].spaces[_blk.idx];
            if (ai_can_damage_struct(_g, _p, _sSp.structure.structId)) {
                var _sD = hazard_def_get(_sSp.structure.structId);
                var _pseudo = (_sD.type == "hazard" && _sD.element != "")
                    ? { id: "emitterstruct", attackElement: "", defenseElement: _sD.element, damage: 0, reward: { pellets: 0, gather: 0 } }
                    : undefined;
                array_push(_cands, { lane: _t.lane, idx: _blk.idx, req: _blk.hp, value: _score * 7, enemyDef: _pseudo, kind: "structure", oppS: 0, myS: 0, why: "v2 road: " + _sD.name + " opens swing" + string(round(_swing)) });
            }
        }
    }
    // own-side cleanup (small constant value - decision space, rewards)
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        for (var _si = _mySideLo; _si <= _mySideHi; _si++) {
            var _sp2 = _g.board.lanes[_laneIdx].spaces[_si];
            if (_sp2.enemy != undefined) {
                var _eD2 = enemy_def_get(_sp2.enemy.enemyDefId);
                if (ai_can_group_hurt(_g, _p, _eD2)) array_push(_cands, { lane: _laneIdx, idx: _si, req: ai_enemy_req(_g, _p, _eD2, _sp2.enemy.curHp), value: ai_reward_value(_eD2) + 12, enemyDef: _eD2, kind: "clean", oppS: 0, myS: 0, why: "v2 clean " + _eD2.name });
            }
        }
    }

    // PLAN bias: the focus lane burns HOT; road-clearing and cleanup OUTSIDE the
    // plan lane is dampened - clearing lanes we don't want just drains the army
    // that the plan needs. (Piles keep full value everywhere: a takeable pile is
    // swing wherever it sits, and DENY-ONLY interception stays live.)
    var _mind = ai2_mind(_g, _p);
    var _hot = variable_struct_exists(_mind, "lanes") ? _mind.lanes : [_mind.lane];
    for (var _a = 0; _a < array_length(_cands); _a++) {
        if (arr_has(_hot, _cands[_a].lane)) _cands[_a].value *= 1.6;
        else if (_cands[_a].kind == "enemy" || _cands[_a].kind == "structure" || _cands[_a].kind == "clean") _cands[_a].value *= 0.7;
    }
    // --- PLANNER v4: AUGMENT THE AUCTION, DON'T OVERRIDE IT (user directive
    // --- 2026-07-17, after v1-v3 overrides all LOST to plain base: forcing a
    // --- primary to 1e6 discarded base's balanced swing/time allocation and
    // --- tunnel-visioned one pile). Base's target selection is UNTOUCHED. We add
    // --- only the ideas base structurally lacks, as GENTLE NUDGES (small
    // --- multipliers, never hammers):
    // ---   COVERAGE: holding an answer card (bomb/boulder/wall) means a threat
    // ---     is handled by the card in the move phase - so DON'T also spend
    // ---     bodies denying it; damp that pile's denial-driven value so the
    // ---     reserve flows to offence instead.
    // ---   (investment dent lives in ai_orders_commit; off-colour redemption in
    // ---    the preamble above - both additive, neither touches selection.)
    var _polP = sim_policy_get(_g, _p);
    if (_polP != undefined && _polP.kind == "planner") {
        var _covered = arr_has(_pl.hand, "bombrock") || arr_has(_pl.hand, "boulder")
            || (arr_has(_pl.hand, "rawmaterial") && array_length(_g.boardDef.structures.walls) > 0);
        if (_covered) {
            // an opponent pile we'd only be chasing to DENY (can't bank it
            // ourselves - it's past centre on their half) is covered by the card;
            // damp it so bodies don't pile into a stall the bomb will handle
            for (var _ci2 = 0; _ci2 < array_length(_cands); _ci2++) {
                var _c2 = _cands[_ci2];
                if (_c2.kind != "pile") continue;
                var _theirHalf = (_p == 0) ? (_c2.idx >= 4) : (_c2.idx <= 2);
                var _oppHolds = (_c2.oppS >= _c2.myS && _c2.oppS > 0);
                if (_theirHalf && _oppHolds) { _c2.value *= 0.5; _c2.why = "[cov] " + _c2.why; }
            }
            ai_dbg("PLANNER: covered by hand - damping deny-only chases");
        }
    }

    // sort by value (swing/time is comparable across kinds - no kind bonuses)
    for (var _a = 0; _a < array_length(_cands); _a++) _cands[_a].ratio = _cands[_a].value / max(1, _cands[_a].req);
    for (var _a = 1; _a < array_length(_cands); _a++) {
        var _tmp = _cands[_a];
        var _b = _a - 1;
        while (_b >= 0 && _cands[_b].value < _tmp.value) { _cands[_b + 1] = _cands[_b]; _b -= 1; }
        _cands[_b + 1] = _tmp;
    }
    return { cands: _cands, risk: _risk, scarce: _scarce, idx: 0 };
}

/// Move phase: plan cards first (bridge/wall/candypop in service of the mind),
/// chain-candypop mid-haul, then the shared situational logic, then resolve.
function ai2_move(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    ai2_try_chain_candypop(_g, _p);
    var _passes = 0;
    while (_passes < 12) {
        _passes += 1;
        if (_g.activePlayer != _p) return; // a card ended the turn
        var _played = ai2_try_plan_cards(_g, _p);
        if (!_played) {
            for (var _hi2 = 0; _hi2 < array_length(_pl.hand); _hi2++) {
                if (ai_try_card(_g, _p, _hi2)) { _played = true; break; }
            }
        }
        if (!_played) break;
    }
    if (_g.activePlayer != _p) return;
    game_resolve_moves(_g);
}

/// Wall choice: fewest opponent tokens that can DEMOLISH it. "A type that isn't
/// out" on their board is a zero-demolisher hard lock; otherwise least-answered.
function ai2_pick_wall(_g, _p) {
    var _walls = _g.boardDef.structures.walls;
    var _best = _walls[0], _bestN = 9999;
    for (var _w = 0; _w < array_length(_walls); _w++) {
        var _n = 0;
        var _toks = _g.players[1 - _p].tokens;
        for (var _i = 0; _i < array_length(_toks); _i++) {
            if (struct_type_can_damage(_toks[_i].typeId, _walls[_w])) _n += 1;
        }
        if (_n < _bestN) { _bestN = _n; _best = _walls[_w]; }
    }
    return _best;
}

/// Do we need this card for the PLAN? If not, can it disrupt the opponent?
/// Priority: plan bridge > plan candypop2 > wall their winning haul road.
function ai2_try_plan_cards(_g, _p) {
    var _pl = _g.players[_p];
    var _mind = ai2_mind(_g, _p);
    var _rawCopies = 0, _hiRaw = -1;
    for (var _i = 0; _i < array_length(_pl.hand); _i++) {
        if (_pl.hand[_i] == "rawmaterial") { _rawCopies += 1; if (_hiRaw < 0) _hiRaw = _i; }
    }

    // 1) PLAN BRIDGE: the focus lane is gated and we hold the materials
    if (_mind.needBridge && _rawCopies >= 2 && arr_has(_g.boardDef.structures.bridges, "bridge")) {
        var _toIdx = 3;
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            if (_g.treasures[_ti].lane == _mind.lane) _toIdx = _g.treasures[_ti].idx;
        }
        var _rn = ai2_road_needs(_g, _p, _mind.lane, _toIdx);
        if (_rn.gateIdx >= 0 && game_play_gather(_g, _hiRaw, { lane: _mind.lane, idx: _rn.gateIdx, build: "bridge" })) {
            ai_dbg("v2 PLAN bridge: lane " + string(_mind.lane + 1) + " idx " + string(_rn.gateIdx));
            return true;
        }
    }

    // 2) PLAN CANDYPOP2: the plan needs a colour pellets can't buy (winged/rock/ice)
    for (var _i = 0; _i < array_length(_pl.hand); _i++) {
        if (_pl.hand[_i] != "candypopbud2") continue;
        var _want = "";
        var _exotics = ["winged", "rock", "ice"];
        for (var _e = 0; _e < array_length(_exotics) && _want == ""; _e++) {
            if (!arr_has(_mind.needColors, _exotics[_e]) || arr_has(_g.boardDef.basicColors, _exotics[_e])) continue;
            var _own = 0;
            for (var _t2 = 0; _t2 < array_length(_pl.tokens); _t2++) if (_pl.tokens[_t2].typeId == _exotics[_e]) _own += 1;
            if (_own < 5) _want = _exotics[_e];
        }
        if (_want == "") break;
        var _home = game_tokens_at(_g, _p, { kind: "home" });
        if (array_length(_home) < 4) break;
        // purple judgment: melting a purple is fine ONLY if ground strength is
        // useless anyway (no pile reachable by purples = they're stranded value)
        var _stranded = true;
        for (var _ti2 = 0; _ti2 < array_length(_g.treasures) && _stranded; _ti2++) {
            if (game_dest_legal(_g, _p, "purple", _g.treasures[_ti2].lane, _g.treasures[_ti2].idx)) _stranded = false;
        }
        var _hasPurple = false;
        for (var _h2 = 0; _h2 < array_length(_home); _h2++) if (pikmin_type_get(_home[_h2].typeId).carry > 1) _hasPurple = true;
        if (_hasPurple && !_stranded) break; // purples still have ground work - wait
        if (game_play_gather(_g, _i, { atHome: true, color: _want })) {
            ai_dbg("v2 PLAN candypop: home squad -> " + _want + (_hasPurple ? " (purples were stranded anyway)" : ""));
            return true;
        }
        break;
    }

    // 3) DISRUPT: their winning haul we're not contesting -> wall the road home
    if (_rawCopies >= 2 && array_length(_g.boardDef.structures.walls) > 0) {
        for (var _ti3 = 0; _ti3 < array_length(_g.treasures); _ti3++) {
            var _t3 = _g.treasures[_ti3];
            if (_t3.boss != undefined || array_length(_t3.cards) == 0) continue;
            var _oppS = game_strength_at(_g, 1 - _p, _t3.lane, _t3.idx);
            var _myS = game_strength_at(_g, _p, _t3.lane, _t3.idx);
            var _w3 = treasure_def_get(_t3.cards[array_length(_t3.cards) - 1]).weight;
            if (_oppS < _w3 || _oppS <= _myS) continue;           // not their winning haul
            if (ai_pile_marginal(_g, 1 - _p, _t3) < 150) continue; // not worth a card pair
            var _dir3 = (_p == 0) ? 1 : -1; // their carry direction
            var _s3 = _t3.idx + _dir3;
            while (_s3 >= 0 && _s3 <= 6) {
                var _sp3 = _g.board.lanes[_t3.lane].spaces[_s3];
                if (_sp3.kind != "hazard" && _sp3.structure == undefined && !game_space_has_card(_g, _t3.lane, _s3)) {
                    var _wall = ai2_pick_wall(_g, _p);
                    if (game_play_gather(_g, _hiRaw, { lane: _t3.lane, idx: _s3, build: _wall })) {
                        ai_dbg("v2 DISRUPT: " + _wall + " walls their haul road (lane " + string(_t3.lane + 1) + " idx " + string(_s3) + ")");
                        return true;
                    }
                }
                _s3 += _dir3;
            }
        }
    }
    return false;
}

/// CHAINING: while hauling a pile home, if the carriers' colour is no longer needed
/// for the REMAINING path, candypop them into the colour the board demands - the
/// group arrives at HOME already converted for its next job.
function ai2_try_chain_candypop(_g, _p) {
    var _pl = _g.players[_p];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (_t.boss != undefined || array_length(_t.cards) == 0) continue;
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
        var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        if (_myS < _w || _myS <= _oppS) continue; // not our winning haul
        var _carriers = game_tokens_at(_g, _p, { kind: "space", lane: _t.lane, idx: _t.idx });
        var _want = ai2_pick_growth_color(_g, _p);
        // already that colour? converting purples would drop tug strength - guard it
        var _nWant = 0;
        for (var _c = 0; _c < array_length(_carriers); _c++) if (_carriers[_c].typeId == _want) _nWant += 1;
        if (_nWant >= array_length(_carriers) * 0.7) continue;
        var _newStr = array_length(_carriers) * pikmin_type_get(_want).carry;
        if (_newStr < _w || _newStr <= _oppS) continue; // conversion would lose the tug
        // remaining path must be walkable by the NEW colour (downhill legs etc.)
        var _dir = (_p == 0) ? -1 : 1;
        var _ok = true;
        var _s = _t.idx + _dir;
        while (_s >= 0 && _s <= 6) {
            if (!game_type_can_enter(pikmin_type_get(_want), _g.board.lanes[_t.lane].spaces[_s], false)) { _ok = false; break; }
            _s += _dir;
        }
        if (!_ok) continue;
        // a candypop in hand that can produce the wanted colour?
        for (var _hi3 = 0; _hi3 < array_length(_pl.hand); _hi3++) {
            var _cid = _pl.hand[_hi3];
            var _can = (_cid == "candypopbud" && arr_has(["red", "blue", "yellow"], _want))
                    || (_cid == "queencandypopbud" && arr_has(_g.boardDef.basicColors, _want))
                    || (_cid == "candypopbud2" && arr_has(["rock", "winged", "ice"], _want));
            if (_can && game_play_gather(_g, _hi3, { lane: _t.lane, idx: _t.idx, color: _want })) {
                ai_dbg("v2 CHAIN: candypop carriers -> " + _want + " mid-haul (lane " + string(_t.lane + 1) + ")");
                return;
            }
        }
    }
}

/// v2 boss-bounty placement - v1's is fine.
function ai2_place_free_hazard(_g) {
    if (array_length(_g.pendingFree) > 0) global.aiDbgP = _g.pendingFree[0].playerIdx;
    ai_place_free_hazard(_g);
}
