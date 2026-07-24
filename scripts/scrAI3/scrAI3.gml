// ============================================================================
// scrAI3 - the CASCADE brain (v3)
//
// A sibling to v1 (scrAI) and v2 (scrAI2), NOT a mutation of either - v2 stays
// pristine as the control/opponent the cascade must beat. v3 reuses every proven
// primitive (ai_send, ai_orders_commit, ai2_road_needs, ai2_turns_to_bank, the
// game_* API) and replaces only the DECISION FLOW: v2's flat greedy value-auction
// becomes a PRIORITY CASCADE of goals (user design, 2026-07-17).
//
// The model (spec agreed 2026-07-17 - see memory dandori-battle-project):
//   GATHER  - a priority LADDER per action (ai3_gather_decision): body-emergency
//             (roster below half + reserve can't refill -> roll) > card-floor
//             (too few actionable cards -> draw) > a 6:4 gather:pellet hand mix.
//   ORDERS  - priority cascade; each goal claims the MINIMUM resources that
//             satisfy it (pikmin DEPLOYED or cards MARKED for the move phase),
//             then the remainder flows to the next goal:
//               1. DENY-interrupt  (unacceptable imminent enemy bank, stoppable
//                                   with SLACK only - never abandon own treasures)
//               2. ADVANCE         (piles movable NOW; latch is emergent - a held
//                                   pile is cheap to hold + full value = top)
//               3. PREPARE / proactive-DENY (open the best value/friction lane -
//                                   clearing is for ACCESS, drops incidental; or
//                                   wall to lock the board when ahead/late)
//               4. PASS            (nothing doable and nothing worth clearing)
//   friction = count of hazard TYPES not yet answerable (span is a minor
//              surcharge, NOT a new gate); mode emphasis slides with score
//              margin / lateness / resources; favoured lane = gentle tiebreak.
//
// STATUS: all three phases now carry real cascade logic (gather ladder, orders
// priority cascade, move card-play). v2 primitives are reused, not delegated to;
// the ctl "v3" seat + tournament base-vs-cascade wiring drive it head to head.
// ============================================================================

function ai3_step(_g) {
    global.aiDbgP = _g.activePlayer;
    switch (_g.phase) {
        case "gather": ai3_gather(_g); break;
        case "orders": ai3_orders(_g); break;
        case "move":   ai3_move(_g);   break;
    }
}

// ============================================================================
// CARD USEFULNESS MODULE (user-designed 2026-07-18, built one heuristic at a time)
// Three questions about a card given the board state, each for a different caller:
//   ai3_card_valid_targets(g,p,card)     - LEGAL to play now? (play phase)  [TODO]
//   ai3_card_strategic_targets(g,p,card) - a WORTHWHILE use now? (priority + the
//        conditional-usefulness test). LOCAL mechanical delta, NOT game-plan math.
//   ai3_card_useful(g,p,card)            - does holding it count as FLEXIBILITY,
//        i.e. should seeing it make me stop drawing? (the gather draw-again count)
// See memory: cascade-gather-spec. Unimplemented conditionals return false (safe).
// ============================================================================

/// Classification: "always" | "never" | "pellet" | "conditional".
function ai3_card_class(_card) {
    switch (_card) {
        case "spicyspray": case "oatchirush": case "bombrock": case "boulder":
        case "candypopbud": case "candypopbud2": case "queencandypopbud":
            return "always";                 // reliable holds - count regardless
        case "mine": case "pikminextinction":
            return "never";                  // panic/denial only - never flex
        case "colorchangingposy":
            return "pellet";                 // body-maker - counted on the PELLET side
        case "rawmaterial":
            return "pair";                   // building's always useful, but needs 2 to build
        default:
            return "conditional";            // useful only if it has a strategic target
    }
}

/// Does holding this card count as FLEXIBILITY (the gather draw-again decision)?
/// never->false, always->true (no checks - reliable holds), pellet->false (it's
/// pellet power, counted separately), pair->true only once you hold 2 (a lone one
/// is a keep-toward-the-pair, not a usable card yet), conditional->a strategic use
/// now. NOTE: the gather COUNT must count "pair" cards as floor(copies/2) so a
/// held pair is ONE useful card, not two (ai3_useful_card_count).
function ai3_card_useful(_g, _p, _card) {
    switch (ai3_card_class(_card)) {
        case "never":  return false;
        case "always": return true;
        case "pellet": return false;
        case "pair": {
            var _n = 0, _h = _g.players[_p].hand;
            for (var _i = 0; _i < array_length(_h); _i++) if (_h[_i] == _card) _n += 1;
            return _n >= 2;
        }
        default:       return ai3_card_strategic_targets(_g, _p, _card);
    }
}

/// Is there a WORTHWHILE (local, mechanical) use for this card right now? Per-card
/// heuristics, built ONE AT A TIME; anything unimplemented returns false so the
/// count is conservative (a card we haven't taught it about is "dead weight" until
/// we teach it - never a false positive).
function ai3_card_strategic_targets(_g, _p, _card) {
    switch (_card) {
        case "surveydrone": case "shipsignal": return ai3_strat_survey(_g, _p);
        case "icebomb": return ai3_strat_freeze_aoe(_g, _p, 1); // 1 space
        case "storm":   return ai3_strat_freeze_aoe(_g, _p, 2); // 2x2
        case "bitterspray": return ai3_strat_bitter(_g, _p);
        case "pikpikbundle": return ai3_strat_pikpik(_g, _p);
        case "phosbatpod": return ai3_strat_block(_g, _p, "enemyslot");
        case "rockstorm":  return ai3_strat_block(_g, _p, "emitter");
        case "ivoryandviolet": return ai3_strat_ivory(_g, _p);
        case "warp": return ai3_strat_warp(_g, _p);
        case "captainclone": return ai3_strat_clone(_g, _p);
        // rawmaterial is class "pair", not conditional - handled in ai3_card_useful
        default: return false;
    }
}

/// Can this card be LEGALLY played right now? Play-phase legality - built later,
/// with the orders/move card-playing logic.
function ai3_card_valid_targets(_g, _p, _card) {
    return false; // TODO
}

// ---- per-card strategic heuristics ----

/// SURVEY DRONE / SHIP SIGNAL: worthwhile iff some pile has a weight SPREAD where
/// re-topping creates a delta. Survey shuffles (gamble), ship picks (guaranteed) -
/// same opportunity test (user treats them the same). OFFENSE: lighten a pile I
/// can reach so my strength lifts a lighter card it currently can't, or rushes
/// (2x) one it currently can't. DEFENSE: heavy a pile the opponent can currently
/// lift but couldn't at a heavier top card. LOCAL weight/lift/reach arithmetic -
/// no plan valuation (user: keep it to the card's own mechanics).
function ai3_strat_survey(_g, _p) {
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) < 2 || _t.boss != undefined) continue;
        var _curW = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _minW = _curW, _maxW = _curW;
        for (var _c = 0; _c < array_length(_t.cards); _c++) {
            var _w = treasure_def_get(_t.cards[_c]).weight;
            if (_w < _minW) _minW = _w;
            if (_w > _maxW) _maxW = _w;
        }
        if (_minW == _maxW) continue; // no spread -> re-topping changes nothing

        // OFFENSE: what I can bring to this pile (on it + reachable from home)
        var _myPot = game_strength_at(_g, _p, _t.lane, _t.idx) + ai_send(_g, _p, _t.lane, _t.idx, 99, undefined, true);
        if (_myPot > 0) {
            if (_myPot < _curW && _myPot >= _minW) return true;                       // lighten -> now liftable
            if (_myPot >= _curW && _myPot >= _minW * 2 && _myPot < _curW * 2) return true; // lighten -> now RUSHable
        }
        // DEFENSE: opponent currently lifting here, deniable by a heavier top
        var _oppHere = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
        if (_oppHere >= _curW && _oppHere < _maxW) return true;
    }
    return false;
}

/// Total pikmin strength the opponent CONTROLS (home + deployed) - the base for
/// the "big clump" threshold (user: "75% of what they actually control").
function ai3_opp_total_str(_g, _p) {
    var _s = 0;
    var _toks = _g.players[1 - _p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) _s += pikmin_type_get(_toks[_i].typeId).carry;
    return max(1, _s);
}

/// ICE BOMB (size 1) / LIGHTNING STORM (size 2 = 2x2). Freeze is INDISCRIMINATE
/// (friendly + hostile), so DENIAL ONLY: worthwhile iff some footprint has NONE
/// of my pikmin in it (else I freeze my own) AND either the opponent holds a
/// controlling carry there, or ~75%+ of everything they control is clumped there
/// (freezing buys a full turn - they can't move OR discard those bodies).
function ai3_strat_freeze_aoe(_g, _p, _size) {
    var _oppTotal = ai3_opp_total_str(_g, _p);
    var _lc = _g.board.laneCount;
    for (var _l = 0; _l <= _lc - _size; _l++) {
        for (var _i = 0; _i <= 7 - _size; _i++) {
            var _myStr = 0, _oppStr = 0, _carry = false;
            for (var _dl = 0; _dl < _size; _dl++) {
                for (var _di = 0; _di < _size; _di++) {
                    var _ll = _l + _dl, _ii = _i + _di;
                    _myStr  += game_strength_at(_g, _p, _ll, _ii);
                    _oppStr += game_strength_at(_g, 1 - _p, _ll, _ii);
                    var _t = game_treasure_at(_g, _ll, _ii);
                    if (_t != undefined && _t.boss == undefined && array_length(_t.cards) > 0) {
                        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
                        if (game_strength_at(_g, 1 - _p, _ll, _ii) >= _w) _carry = true;
                    }
                }
            }
            if (_myStr > 0 || _oppStr <= 0) continue;         // would freeze my own / nothing there
            if (_carry) return true;                          // stall their carry
            if (_oppStr >= 0.75 * _oppTotal) return true;      // big clump
        }
    }
    return false;
}

/// BITTER SPRAY (single space, HOSTILES ONLY - never my pikmin). Flexible:
///  - TUG-WIN: a contested pile I could carry once theirs stop counting (my
///    strength >= weight but they're tying/winning) -> freeze theirs, walk it off.
///  - KILL-STOP: an enemy I'm engaging that I can kill, which would retaliate
///    (crush/normal damage) and is NOT suicide-defence (bitter can't stop that).
///  - big hostile clump (self-safe denial, same 75% test).
function ai3_strat_bitter(_g, _p) {
    var _oppTotal = ai3_opp_total_str(_g, _p);
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            var _myStr  = game_strength_at(_g, _p, _l, _i);
            var _oppStr = game_strength_at(_g, 1 - _p, _l, _i);
            var _t = game_treasure_at(_g, _l, _i);
            if (_t != undefined && _t.boss == undefined && array_length(_t.cards) > 0) {
                var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
                if (_myStr >= _w && _oppStr >= _myStr) return true; // tug-win
            }
            var _sp = _g.board.lanes[_l].spaces[_i];
            if (_sp.enemy != undefined && _myStr > 0) {
                var _ed = enemy_def_get(_sp.enemy.enemyDefId);
                var _suicide = (_ed.defenseElement != "" && _ed.defenseElement != "crush" && _ed.defenseElement != "height");
                if (!_suicide && _ed.damage > 0 && _myStr >= _sp.enemy.curHp) return true; // kill-stop
            }
            if (_oppStr > 0 && _oppStr >= 0.75 * _oppTotal) return true; // big clump
        }
    }
    return false;
}

/// PIKPIK CARROTS: a 5-hp decoy that soaks up to 5 of an enemy's damage BEFORE it
/// hits your pikmin. Only ENABLES A KILL in the SWIFT case (swift strikes first,
/// thinning your squad before it swings; soaking 5 lets that many more survive to
/// deal lethal). Non-swift damage lands AFTER your attack, so it never changes
/// whether you kill - only saves bodies. Trigger: an enemy I'm engaging where
/// without the soak my post-swift strength can't kill it, but with it, it can.
function ai3_strat_pikpik(_g, _p) {
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            var _sp = _g.board.lanes[_l].spaces[_i];
            var _e = _sp.enemy;
            if (_e == undefined) {
                var _t = game_treasure_at(_g, _l, _i);
                if (_t != undefined && _t.boss != undefined) _e = _t.boss;
            }
            if (_e == undefined) continue;
            var _myStr = game_strength_at(_g, _p, _l, _i);
            if (_myStr <= 0) continue; // must be engaging it
            var _ed = enemy_def_get(_e.enemyDefId);
            if (_ed.attackElement != "swift") continue; // only swift eats attack before it lands
            var _without = _myStr - _ed.damage;                 // post-swift strength, no decoy
            var _with    = _myStr - max(0, _ed.damage - 5);     // decoy soaks up to 5
            if (_without < _e.curHp && _with >= _e.curHp) return true;
        }
    }
    return false;
}

/// PHOSBAT POD (spawn an enemy in an empty enemy-slot) / ROCK STORM (drop an
/// emitter on an empty non-hazard space): BLOCKERS. Worthwhile iff a lane has the
/// opponent ACTIVELY pursuing a pile (their bodies in the lane AND a pile there)
/// AND a valid placement space in that lane to block them. _kind = "enemyslot"
/// (phosbat, needs an "enemy"-kind empty space + enemies left to spawn) or
/// "emitter" (rockstorm, needs a non-hazard empty space + the board offers
/// emitters). Coarse - exact placement is a play-phase decision.
function ai3_strat_block(_g, _p, _kind) {
    if (_kind == "emitter") {
        if (!variable_struct_exists(_g.boardDef.structures, "emitters") || array_length(_g.boardDef.structures.emitters) == 0) return false;
    }
    if (_kind == "enemyslot") {
        if (array_length(_g.decks.enemy) + array_length(_g.decks.enemyDiscard) == 0) return false; // nothing to spawn
    }
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        var _oppLaneStr = 0;
        var _otoks = _g.players[1 - _p].tokens;
        for (var _oi = 0; _oi < array_length(_otoks); _oi++)
            if (_otoks[_oi].loc.kind == "space" && _otoks[_oi].loc.lane == _l) _oppLaneStr += pikmin_type_get(_otoks[_oi].typeId).carry;
        if (_oppLaneStr <= 0) continue; // opponent has no presence/access in this lane
        var _hasPile = false;
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++)
            if (_g.treasures[_ti].lane == _l && array_length(_g.treasures[_ti].cards) > 0) { _hasPile = true; break; }
        if (!_hasPile) continue; // nothing in this lane worth denying
        for (var _i = 0; _i <= 6; _i++) {
            var _sp = _g.board.lanes[_l].spaces[_i];
            if (_sp.enemy != undefined || _sp.structure != undefined || game_treasure_at(_g, _l, _i) != undefined) continue;
            if (_kind == "enemyslot") { if (_sp.kind == "enemy") return true; }
            else { if (_sp.kind != "hazard") return true; }
        }
    }
    return false;
}

/// Count useful gather cards in hand for the gather draw-again decision. Handles
/// the "pair" class (rawmaterial) as floor(copies/2) - a held pair is ONE useful
/// card, a lone one is zero. Pellet-class cards are excluded (counted on the
/// pellet side). Everything else via ai3_card_useful.
function ai3_useful_card_count(_g, _p) {
    var _h = _g.players[_p].hand;
    var _count = 0, _raw = 0;
    for (var _i = 0; _i < array_length(_h); _i++) {
        var _cls = ai3_card_class(_h[_i]);
        if (_cls == "pair") { _raw += 1; continue; }        // count pairs below
        if (_cls == "pellet") continue;                     // pellet side, not flexibility
        if (ai3_card_useful(_g, _p, _h[_i])) _count += 1;
    }
    return _count + (_raw div 2);                           // each rawmaterial PAIR = 1
}

/// IVORY & VIOLET: trade bodies for whites (ivory, 2 each) and/or purples (violet,
/// 5 each). Worthwhile iff WHITES wanted (board has poison - white is poison-
/// immune, a nice-to-have there) OR PURPLES wanted (a body SURPLUS to spend 5-for-
/// 1, AND a lane a purple can actually work: purple has no traits/immunities so it
/// crosses NO hazards - it needs a pile whose road has none it can't pass).
function ai3_strat_ivory(_g, _p) {
    // WHITE: any poison on the board (terrain hazard or a placed poison emitter)
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            var _sp = _g.board.lanes[_l].spaces[_i];
            if (_sp.hazard == "poison") return true;
            if (_sp.structure != undefined && hazard_def_get(_sp.structure.structId).element == "poison") return true;
        }
    }
    // PURPLE: surplus to spend + an open lane a purple can traverse to a pile
    if (ai_home_strength(_g, _p) < 10) return false;         // no surplus -> not worth 5-for-1
    var _pd = pikmin_type_get("purple");
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _dir = (_p == 0) ? 1 : -1;
        var _s = (_p == 0) ? 0 : 6;
        var _open = true;
        while (_s != _t.idx) {
            var _rsp = _g.board.lanes[_t.lane].spaces[_s];
            if (_rsp.kind == "hazard" && _rsp.structure == undefined && !game_type_can_enter(_pd, _rsp, true, false)) { _open = false; break; }
            _s += _dir;
        }
        if (_open) return true; // a pile a purple can walk to = purple pays off
    }
    return false;
}

/// WARP: relocate a lane enemy into an empty enemy-slot, or swap two bosses.
/// Worthwhile iff an enemy blocks MY road to a pile (moving it clears my path) AND
/// a dump enemy-slot exists to receive it; OR there are 2+ bosses to swap (offload
/// an unwanted one). (Coarse - the "don't open the opponent's path" nuance is a
/// play-phase placement decision.)
function ai3_strat_warp(_g, _p) {
    // a dump destination: an empty enemy-slot
    var _dump = false;
    for (var _l = 0; _l < _g.board.laneCount && !_dump; _l++)
        for (var _i = 0; _i <= 6; _i++) {
            var _sp = _g.board.lanes[_l].spaces[_i];
            if (_sp.kind == "enemy" && _sp.enemy == undefined && _sp.structure == undefined && game_treasure_at(_g, _l, _i) == undefined) { _dump = true; break; }
        }
    if (_dump) {
        // an enemy blocking my road to a live pile -> relocate it off my path
        for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
            var _t = _g.treasures[_ti];
            if (array_length(_t.cards) == 0) continue;
            var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
            if (_blk != undefined && _blk.kind == "enemy") return true;
        }
    }
    // boss swap: 2+ bosses in play -> can offload an unwanted one
    var _bosses = 0;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) if (_g.treasures[_ti].boss != undefined) _bosses += 1;
    return _bosses >= 2;
}

/// CAPTAIN CLONE: copies any OTHER card in hand or on the discard top - so it's a
/// dupe of the best available card. Worthwhile iff some other card in hand is
/// useful, or the discard top is. (Skips clones - copying a clone is nothing.)
function ai3_strat_clone(_g, _p) {
    var _h = _g.players[_p].hand;
    for (var _i = 0; _i < array_length(_h); _i++) {
        if (_h[_i] == "captainclone") continue;
        if (ai3_card_useful(_g, _p, _h[_i])) return true;
    }
    var _disc = _g.decks.gatherDiscard;
    if (array_length(_disc) > 0) {
        var _top = _disc[array_length(_disc) - 1];
        if (_top != "captainclone" && ai3_card_useful(_g, _p, _top)) return true;
    }
    return false;
}

// --- scaffold: delegate to v2 until each phase's cascade logic is built ---

/// Is a gather card TYPE in THIS board's pool? (setsCopies keyed by board number
/// - candypops differ by board, so "can I draw the answer" is board-specific.)
/// NOTE (2026-07-18): currently UNUSED - it fed the old ratio gather's card-hunger
/// input, which the LADDER (ai3_gather_decision) replaced. Retained as verified,
/// reusable board knowledge (a future colour-need node is the likely next caller).
function ai3_board_has_gather(_g, _cardId) {
    var _key = string(_g.boardDef.setNumber);
    var _defs = global.gatherData.gather;
    for (var _i = 0; _i < array_length(_defs); _i++) {
        if (_defs[_i].id == _cardId) return variable_struct_exists(_defs[_i].setsCopies, _key) && _defs[_i].setsCopies[$ _key] > 0;
    }
    return false;
}

/// How is this hazard answered ON THIS BOARD? (Currently UNUSED - see the note on
/// ai3_board_has_gather; kept as reusable board knowledge.) "basic" = a basic colour crosses it
/// (roll for it), "card" = only a card in THIS board's pool answers it (draw for
/// it), "none" = nothing on this board answers it (drawing is futile - a dead
/// lane). The crossing colours come from ai2_gate_answers (flying crosses all,
/// height also by climbs/yellow, element by immunity, chasm only by flying).
/// Card answers: candypopbud mints R/B/Y, candypopbud2 mints rock/winged/ice,
/// rawmaterial builds a bridge (chasm/water) or climbing stick (height) - but
/// ONLY if the board's deck actually has that card.
function ai3_hazard_answer(_g, _hazard) {
    var _answers = ai2_gate_answers(_hazard); // colour ids that cross this hazard
    var _basics = _g.boardDef.basicColors;
    for (var _i = 0; _i < array_length(_answers); _i++) if (arr_has(_basics, _answers[_i])) return "basic";

    var _hasCP1 = ai3_board_has_gather(_g, "candypopbud");   // -> red/blue/yellow
    var _hasCP2 = ai3_board_has_gather(_g, "candypopbud2");  // -> rock/winged/ice
    for (var _i = 0; _i < array_length(_answers); _i++) {
        var _c = _answers[_i];
        if (_hasCP1 && (_c == "red" || _c == "blue" || _c == "yellow")) return "card";
        if (_hasCP2 && (_c == "rock" || _c == "winged" || _c == "ice")) return "card";
    }
    // ANY hazard yields to a bridge structure (stick/tunnel are the element-locked ones)
    if (ai3_hazard_bridgeable(_g, _hazard)) return "card";
    return "none";
}

/// Is the pellet reserve GOOD ENOUGH to be relied on to refill the roster? (the
/// body-emergency gate - when bodies are low, an adequate reserve will redeem
/// into pikmin so no emergency roll is needed). User's ideal: ~4 pellet cards
/// with >=1 five (preferably 2). THIN (fewer than 4) OR ALL-BAD (no five, all
/// "1"s) -> not ok, roll to top up / upgrade. A "5" pellet redeems 5 same-colour
/// bodies (sameTypeAmount 5); a "1" pellet redeems 2 (sameTypeAmount 2).
function ai3_pellet_reserve_ok(_g, _p) {
    var _pel = _g.players[_p].pellets;
    if (array_length(_pel) < 4) return false;                    // thin
    for (var _i = 0; _i < array_length(_pel); _i++)
        if (pellet_def_get(_pel[_i]).sameTypeAmount >= 5) return true; // has a five
    return false;                                                 // all "1"s -> all-bad
}

/// The CASCADE gather LADDER (user design 2026-07-18, see memory cascade-gather-
/// spec). Returns "roll" (fill the body pipeline: pellets -> pikmin at redemption)
/// or "draw" (buy card flexibility) for ONE gather action; the caller re-reads
/// state after acting (~3 actions/turn). COLOUR IS IGNORED here - roll full-
/// efficiency own-colour bodies, fix colour later via candypop. The ladder:
///   1. BODY EMERGENCY  - roster below half the cap AND the pellet reserve can't
///                        refill it (thin or all "1"s) -> ROLL. No board-fill math.
///   2. CARD FLOOR      - too few ACTIONABLE gather cards (usefulCount < 3) -> DRAW.
///   3. 6:4 COMPOSITION - both floors met: steer the HAND toward 60% gather / 40%
///                        pellet. Below 60% gather -> DRAW, else ROLL. A flood of
///                        pellets self-solves as DRAW (avoids over-rolling into the
///                        hand limit).
function ai3_gather_decision(_g, _p) {
    var _pl = _g.players[_p];

    // roster full: bodies do nothing this turn - only cards have any effect
    if (game_capped_count(_g, _p) >= global.rules.pikminBoardCap) {
        var _held = array_length(_pl.hand) + array_length(_pl.pellets);
        return (_held < global.rules.handLimit) ? "draw" : "roll";
    }

    // 1. body emergency - half-empty roster the reserve can't fix
    if (game_capped_count(_g, _p) < global.rules.pikminBoardCap * 0.5 && !ai3_pellet_reserve_ok(_g, _p)) return "roll";

    // 2. card floor - not enough flexibility to work with
    if (ai3_useful_card_count(_g, _p) < 3) return "draw";

    // 3. 6:4 gather:pellet hand composition
    var _gather = array_length(_pl.hand);
    var _pellet = array_length(_pl.pellets);
    if (_gather + _pellet == 0) return "draw";
    return (_gather / (_gather + _pellet) < 0.6) ? "draw" : "roll";
}

function ai3_gather(_g) {
    if (ai3_gather_decision(_g, _g.activePlayer) == "draw") game_gather_draw(_g); else game_gather_roll(_g);
}

// ============================================================================
// ORDERS PRIMITIVES (user-designed 2026-07-18, see memory cascade-orders-spec).
// Built ONE NODE AT A TIME with scrSim scenario tests, same as the card layer.
// ============================================================================

/// NODE 1 - the two-gate ATTACK BODY-COST. "If I strike this enemy THIS turn with
/// _send (a colour->count struct), how many of my bodies die, and does it die?"
/// Two INDEPENDENT gates (cascade-orders-spec), reusing the engine matchup atoms:
///   ai_type_can_hurt         - deals damage at all (attack-req quota / crush / height)
///   ai_type_survives_defense - DEFENSE gate: survives the retaliation MELT. If not,
///        that pikmin melts AFTER striking - it dies even on a clean kill (the melt
///        fires when you strike, not when it dies). Clean-kill is an OUTCOME, not
///        a safety category.
///   ai_type_immune_attack    - ATTACK gate, element half: immune to the swing's
///        element (always false for ""/swift/explosive/crush - those can't be
///        dodged by immunity; crush hits rock too, crush-immunity is defense-only).
/// The ATTACK gate's TIMING half: the swing lands UNLESS damage==0, OR we KILL it
/// this turn AND it's neither crush (strikes even dead) nor swift-without-spicy
/// (swift strikes first in pass 0; only the spicy round, which precedes swift,
/// beats it). Losses = every melting striker, PLUS the swing's `damage` taken from
/// the melt-surviving swing-vulnerable attackers (no double count). free == 0 lost.
function ai3_attack_cost(_g, _p, _enemyDef, _curHp, _send, _hasSpicy) {
    var _cols = variable_struct_get_names(_send);
    var _strength = 0, _canHurt = false;
    var _meltDead = 0, _safeVuln = 0;   // melt: dies to defense; safeVuln: survives melt but swing can take it
    for (var _i = 0; _i < array_length(_cols); _i++) {
        var _c = _cols[_i];
        var _n = _send[$ _c];
        if (_n <= 0) continue;
        if (ai_type_can_hurt(_c, _enemyDef)) { _canHurt = true; _strength += pikmin_type_get(_c).carry * _n; }
        if (!ai_type_survives_defense(_c, _enemyDef)) { _meltDead += _n; continue; } // DEFENSE gate -> melts
        if (!ai_type_immune_attack(_c, _enemyDef)) _safeVuln += _n;                  // survives melt, swing can still take it
    }
    // kill requirement (ai_enemy_req adds the swift first-strike soak; spicy removes
    // it, since the spicy round kills the swift enemy before it ever strikes)
    var _killReq = ai_enemy_req(_g, _p, _enemyDef, _curHp);
    if (_hasSpicy && _enemyDef.attackElement == "swift") _killReq = _curHp;
    var _kills = _canHurt && (_strength >= _killReq);
    // does the enemy's offensive swing land?
    var _swing = (_enemyDef.damage > 0);
    if (_swing && _kills && _enemyDef.attackElement != "crush"
        && (_enemyDef.attackElement != "swift" || _hasSpicy)) _swing = false;        // killed before it strikes
    var _losses = _meltDead + (_swing ? min(_enemyDef.damage, _safeVuln) : 0);
    return { canHurt: _canHurt, strength: _strength, killReq: _killReq, kills: _kills, losses: _losses, free: (_losses == 0) };
}

/// Can this colour legally reach ANY live pile, or a blocker on its road that this
/// colour could actually CLEAR (an enemy it can hurt / a structure)? The shared
/// reachability test for node 2 (deadweight) and the deferred colour-need shopping
/// list - same question, two callers. Runs against WHATEVER board it's handed, so
/// ai3_deadweight_strength projects the board forward first, then calls this. (Same
/// shape as ai_cull_deadweight's inline test, but blocker-aware: a colour stuck
/// behind an enemy it can't hurt is NOT "useful" via that pile. Structure blockers
/// stay reach-only for now - conservative, under-flags rather than over-flags.)
function ai3_color_reaches_target(_g, _p, _typeId) {
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
        if (_blk == undefined) {
            if (game_dest_legal(_g, _p, _typeId, _t.lane, _t.idx)) return true;   // unblocked pile
        } else if (_blk.kind == "enemy") {
            if (ai_type_can_hurt(_typeId, enemy_def_get(_blk.enemy.enemyDefId))   // can clear the blocker
                && game_dest_legal(_g, _p, _typeId, _t.lane, _blk.idx)) return true;
        } else if (_blk.kind == "structure") {
            if (game_dest_legal(_g, _p, _typeId, _t.lane, _blk.idx)) return true;  // reach-only (conservative)
        }
        // treasure-blocker (another pile in front): not clearable by fighting - skip
    }
    return false;
}

/// NODE 2 - DEADWEIGHT STRENGTH (user-designed 2026-07-18, cascade-orders-spec).
/// After the plan commits, how much of my LEFTOVER (home) strength is FREE TO SPEND
/// - i.e. its colour can reach NO productive target THIS turn NOR after this turn's
/// committed kills/unlocks resolve (ONE-turn lookahead, MY actions only). The
/// allocation's final leftover-placement step reads this to choose "suicide-chip a
/// reachable enemy for permanent HP progress" vs "keep it home". Projects the
/// post-resolution board (drop the enemies in _killedSet - node 1's `kills`; bridge
/// the spaces in _builtBridges), tests ai3_color_reaches_target per home colour,
/// restores. A body behind a blocker you're KILLING this turn is NOT deadweight
/// (its road opens next turn). Returns { total, byColor }.
function ai3_deadweight_strength(_g, _p, _killedSet = [], _builtBridges = []) {
    var _saved = [];
    for (var _i = 0; _i < array_length(_killedSet); _i++) {
        var _k = _killedSet[_i];
        var _sp = _g.board.lanes[_k.lane].spaces[_k.idx];
        var _t = game_treasure_at(_g, _k.lane, _k.idx);
        array_push(_saved, { lane: _k.lane, idx: _k.idx, enemy: _sp.enemy, kind: _sp.kind, hazard: _sp.hazard, structure: _sp.structure, t: _t, boss: (_t != undefined ? _t.boss : undefined) });
        _sp.enemy = undefined;                     // the kill removes it
        if (_t != undefined) _t.boss = undefined;  // (a boss guarding the pile, too)
    }
    for (var _i = 0; _i < array_length(_builtBridges); _i++) {
        var _b = _builtBridges[_i];
        var _sp = _g.board.lanes[_b.lane].spaces[_b.idx];
        array_push(_saved, { lane: _b.lane, idx: _b.idx, enemy: _sp.enemy, kind: _sp.kind, hazard: _sp.hazard, structure: _sp.structure, t: undefined, boss: undefined });
        _sp.kind = "plain"; _sp.hazard = ""; _sp.structure = undefined; // bridged -> anyone crosses
    }

    var _home = game_counts_struct(_g, _p, { kind: "home" });
    var _cols = variable_struct_get_names(_home);
    var _byColor = {};
    var _total = 0;
    for (var _c = 0; _c < array_length(_cols); _c++) {
        var _typeId = _cols[_c];
        var _n = _home[$ _typeId];
        if (_n <= 0) continue;
        if (!ai3_color_reaches_target(_g, _p, _typeId)) {
            _byColor[$ _typeId] = _n;
            _total += pikmin_type_get(_typeId).carry * _n;
        }
    }

    for (var _i = array_length(_saved) - 1; _i >= 0; _i--) {
        var _s = _saved[_i];
        var _sp = _g.board.lanes[_s.lane].spaces[_s.idx];
        _sp.enemy = _s.enemy; _sp.kind = _s.kind; _sp.hazard = _s.hazard; _sp.structure = _s.structure;
        if (_s.t != undefined) _s.t.boss = _s.boss;
    }
    return { total: _total, byColor: _byColor };
}

#macro ACCESS_INF 999   // road can't be opened by this player (dead lane for them)

/// Can a bridge/stick/tunnel open THIS terrain hazard on THIS board? Engine truth
/// (game_play_gather rawmaterial, scrGame:992): a "bridge" structure goes on ANY
/// hazard space - ice/fire/electric included - and only the climbing stick (height)
/// and tunnel (chasm) are element-locked. Requires rawmaterial in the board's pool
/// (else the card is unobtainable, so it isn't really bridgeable). SINGLE SOURCE OF
/// TRUTH for bridgeability - road_turns / hazard_answer / obstacle_answers all defer
/// here so the old "chasm/water/height only" bug can't come back.
function ai3_hazard_bridgeable(_g, _hazard) {
    if (!ai3_board_has_gather(_g, "rawmaterial")) return false;
    var _br = _g.boardDef.structures.bridges;
    if (arr_has(_br, "bridge")) return true;                        // any hazard
    if (_hazard == "height" && arr_has(_br, "climbingstick")) return true;
    if (_hazard == "chasm"  && arr_has(_br, "tunnel")) return true;
    return false;
}

/// Turns for _p to OPEN the road home->(lane,idx) so a carry can run it: +1 per
/// blocker _p must clear, ACCESS_INF if any blocker _p simply can't answer. A raw
/// hazard _p's colours already cross adds 0; a chasm/water/height _p can't cross
/// but the board's pool can bridge adds 1 (build it); an enemy _p can hurt / a wall
/// or blocking emitter _p can damage adds 1. COARSE turn proxy (one blocker ~ one
/// turn of friction; monotonic in blocker count - captures "cut through a bunch of
/// enemies = slower" without full DPS modelling). Per-player: pass _p = opponent
/// for their access. Feeds ai3_access_cost + the main-lane pick's access terms.
function ai3_road_turns(_g, _p, _lane, _idx) {
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    var _turns = 0;
    var _cols = [];
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) if (!arr_has(_cols, _toks[_i].typeId)) array_push(_cols, _toks[_i].typeId);
    while (_s != _idx) {
        var _sp = _g.board.lanes[_lane].spaces[_s];
        if (_sp.enemy != undefined) {
            if (ai_can_group_hurt(_g, _p, enemy_def_get(_sp.enemy.enemyDefId))) _turns += 1; else return ACCESS_INF;
        } else if (_sp.structure != undefined) {
            var _sDef = hazard_def_get(_sp.structure.structId);
            if (_sDef.type == "wall") {
                if (ai_can_damage_struct(_g, _p, _sp.structure.structId)) _turns += 1; else return ACCESS_INF;
            } else if (_sDef.type != "bridge") { // emitter: pass if a colour clears it, else must destroy it
                if (!ai_emitter_passable(_g, _p, _sDef)) {
                    if (ai_can_damage_struct(_g, _p, _sp.structure.structId)) _turns += 1; else return ACCESS_INF;
                }
            }
        } else if (_sp.kind == "hazard" && _sp.hazard != "" && _sp.hazard != "poison") {
            var _cross = false;
            for (var _c = 0; _c < array_length(_cols) && !_cross; _c++)
                if (game_type_can_enter(pikmin_type_get(_cols[_c]), _sp, true, false)) _cross = true;
            if (!_cross) {
                if (ai3_hazard_bridgeable(_g, _sp.hazard)) _turns += 1; // a bridge opens ANY hazard (stick=height, tunnel=chasm)
                else return ACCESS_INF;
            }
        }
        if (game_treasure_at(_g, _lane, _s) != undefined) _turns += 1; // another pile in the way (coarse)
        _s += _dir;
    }
    return _turns;
}

/// ACCESS COST (turns) for _p to REACH AND TAKE the pile at (lane,idx) = road-open
/// turns + carry turns, ACCESS_INF if the road can't be opened. The shared metric
/// behind BOTH main-lane pick (whole path, per player) and min-to-advance (its first
/// step). Carry term reuses ai2_turns_to_bank (spicy already discounts it there;
/// _hasSpicy defaults false - conservative, and we don't see the opponent's hand).
function ai3_access_cost(_g, _p, _lane, _idx, _hasSpicy = false) {
    var _road = ai3_road_turns(_g, _p, _lane, _idx);
    if (_road >= ACCESS_INF) return ACCESS_INF;
    var _t = game_treasure_at(_g, _lane, _idx);
    var _w = (_t != undefined && array_length(_t.cards) > 0) ? treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight : 1;
    return _road + ai2_turns_to_bank(_g, _p, _idx, _w, _hasSpicy);
}

// ============================================================================
// ACCESS ENUMERATION (node 1 of the demand-driven orders rework, 2026-07-22).
// Unlike ai3_road_turns (a scalar cost from the CURRENT roster), these enumerate
// how a pile COULD be accessed, roster-independent, so the funder can decide what
// colour is worth growing. Access has TWO directions with asymmetric rules:
//   REACH  - outbound (home -> pile, toward centre); enough to contest / DENY.
//   CARRY  - return  (pile -> home, away from centre); required to actually BANK.
// (height gates reach only; exp-yellow crosses a chasm toward centre but can't
// carry back; bridges/immunities/flying are symmetric.)
// ============================================================================

/// The ordered obstacles on the road from _p's home edge to (lane,idx) - the raw
/// material for the answers/methods layers. A faithful, DIRECTION-AGNOSTIC transcript
/// (direction-dependent crossing is applied later, per method). Each entry:
///   { idx, kind, soft, ... }
///     kind "enemy"   -> { enemyDefId, curHp }        clear by hurting it
///     kind "wall"    -> { structId, hp }             clear by damaging it
///     kind "emitter" -> { structId, element, hp }    cross if immune, else destroy
///     kind "hazard"  -> { hazard }                   terrain gate (chasm/water/height/element)
///     kind "pile"    -> { }                           another treasure in the lane
/// `soft: true` marks a non-blocking, damage-only obstacle (poison terrain / poison
/// emitter) - anyone crosses, non-immune (non-white) take damage; it's a colour
/// PREFERENCE, not a gate. Bridge structures are not obstacles. [] = clear road.
function ai3_road_obstacles(_g, _p, _lane, _idx) {
    var _dir = (_p == 0) ? 1 : -1;
    var _s   = (_p == 0) ? 0 : 6;
    var _out = [];
    while (_s != _idx) {
        var _sp = _g.board.lanes[_lane].spaces[_s];
        if (_sp.enemy != undefined) {
            array_push(_out, { idx: _s, kind: "enemy", soft: false, enemyDefId: _sp.enemy.enemyDefId, curHp: _sp.enemy.curHp });
        } else if (_sp.structure != undefined) {
            var _sd = hazard_def_get(_sp.structure.structId);
            if (_sd.type == "wall") {
                array_push(_out, { idx: _s, kind: "wall", soft: false, structId: _sp.structure.structId, hp: _sp.structure.curHp });
            } else if (_sd.type != "bridge") { // emitter (bridge never blocks)
                array_push(_out, { idx: _s, kind: "emitter", soft: (_sd.element == "poison"),
                    structId: _sp.structure.structId, element: _sd.element, hp: _sp.structure.curHp });
            }
        } else if (_sp.kind == "hazard" && _sp.hazard != "") {
            array_push(_out, { idx: _s, kind: "hazard", soft: (_sp.hazard == "poison"), hazard: _sp.hazard });
        }
        if (game_treasure_at(_g, _lane, _s) != undefined) array_push(_out, { idx: _s, kind: "pile", soft: false });
        _s += _dir;
    }
    return _out;
}

/// The ways past ONE obstacle in ONE direction (_towardCenter true = the outbound REACH
/// step; false = the CARRY-home step - the crossing rules are asymmetric, so the caller
/// asks twice). Returns:
///   { kind, soft,
///     nativeColors: [ids],   // pikmin types that cross with NO card, this direction
///                            //   (single source of truth = game_type_can_enter)
///     open: [ {via, ...} ] }  // non-native ways to make it passable this direction
/// open vias:
///   "bridge"        - ANY terrain hazard (ice/fire/electric/water/chasm/height); cost 2
///                     rawmaterial, DURABLE for reach but consumedByCarry (a treasure
///                     carried over it destroys it - one bank per bridge).
///   "climbingstick" - height only; "tunnel" - chasm only; cost 2, not carry-consumed.
///   "lifeguard"     - water only, exp rule; a blue-escorted group crosses, but REACH
///                     ONLY (lifeguard doesn't carry) - cost 0 bodies (needs a blue along).
///   "kill"          - an enemy blocks both ways; clear it (PREPARE prices the kill).
///   "destroy"       - a wall / element emitter: cross by immunity (nativeColors) or break it.
///   "clearpile"     - an intervening treasure pile; its own target, not simply passable.
/// Soft obstacles (poison) never block: nativeColors = everyone, open = [] (the count
/// cost of the poison chip is the funder's problem, not an access gate).
function ai3_obstacle_answers(_g, _lane, _obs, _towardCenter) {
    var _types = ["red", "yellow", "blue", "purple", "white", "rock", "ice", "winged", "bulbmin"];
    var _native = [];
    var _open = [];

    if (_obs.kind == "enemy") {
        array_push(_open, { via: "kill" });                    // no colour passes a live enemy
    } else if (_obs.kind == "wall") {
        array_push(_open, { via: "destroy" });
    } else if (_obs.kind == "pile") {
        array_push(_open, { via: "clearpile" });
    } else {
        // hazard terrain OR emitter structure: native passers via the engine's own rule
        var _sp = _g.board.lanes[_lane].spaces[_obs.idx];
        for (var _i = 0; _i < array_length(_types); _i++)
            if (game_type_can_enter(pikmin_type_get(_types[_i]), _sp, _towardCenter, false, false))
                array_push(_native, _types[_i]);

        if (!_obs.soft) {
            if (_obs.kind == "hazard") {
                if (ai3_hazard_bridgeable(_g, _obs.hazard)) {
                    // enumerate every applicable structure - the funder picks (bridge = any
                    // hazard but carry-consumed; stick/tunnel element-locked, not consumed).
                    var _br = _g.boardDef.structures.bridges;
                    if (arr_has(_br, "bridge")) array_push(_open, { via: "bridge", cost: 2, consumedByCarry: true });
                    if (_obs.hazard == "height" && arr_has(_br, "climbingstick")) array_push(_open, { via: "climbingstick", cost: 2, consumedByCarry: false });
                    if (_obs.hazard == "chasm"  && arr_has(_br, "tunnel"))        array_push(_open, { via: "tunnel", cost: 2, consumedByCarry: false });
                }
                if (_obs.hazard == "water" && global.expRules.blue) array_push(_open, { via: "lifeguard", cost: 0, reachOnly: true });
            } else if (_obs.kind == "emitter") {
                array_push(_open, { via: "destroy" });         // emitters aren't bridgeable (space occupied)
            }
        }
    }
    return { kind: _obs.kind, soft: _obs.soft, nativeColors: _native, open: _open };
}

/// NODE 1c - ACCESS METHODS: the roster-independent MENU of recipes to put weight on
/// a pile, one per carrier colour (user's framing: a method = one PROCESS to get N
/// bodies onto a Wt pile - "what combination of bodies + items"). For each colour, walk
/// the road's obstacles (answers cached both directions) and accumulate the opens it
/// needs. Bridges nullify a hazard BOTH ways (one build); a clear (kill/destroy) opens
/// an enemy/wall/emitter both ways; lifeguard opens water for REACH only. Each method:
///   { color, canReach, canCarry, bodies, builds:[{idx,via,cost}], clears:[idx],
///     cardCost, turns }
///   canCarry=false, canReach=true  -> a DENY-only recipe (reach it, can't bank it):
///     yellow-over-chasm, lifeguard-escort. ADVANCE must never count these toward a bank.
///   bodies = ceil(weight / carry) + poison attrition (1 body lost per poison space it
///     isn't immune to - user's "send 4 rocks over poison to land 3").
///   turns  = builds + clears (~1 turn each) + carry turns -> feeds value/turns scoring.
/// Colours that can't even REACH are omitted. V1 gap: when a colour CAN bank (via
/// bridges) it does NOT also surface the cheaper lifeguard reach-only variant - add
/// that when the DENY funder wants "wall it for 0 cards".
function ai3_access_methods(_g, _p, _lane, _idx) {
    var _obs = ai3_road_obstacles(_g, _p, _lane, _idx);
    var _t = game_treasure_at(_g, _lane, _idx);
    var _w = (_t != undefined && array_length(_t.cards) > 0) ? treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight : 1;

    var _ansR = [], _ansC = [];                                 // cache answers per obstacle, both directions
    for (var _o = 0; _o < array_length(_obs); _o++) {
        _ansR[_o] = ai3_obstacle_answers(_g, _lane, _obs[_o], true);
        _ansC[_o] = ai3_obstacle_answers(_g, _lane, _obs[_o], false);
    }

    var _types = ["red", "yellow", "blue", "purple", "white", "rock", "ice", "winged", "bulbmin"];
    var _methods = [];
    for (var _ci = 0; _ci < array_length(_types); _ci++) {
        var _C = _types[_ci];
        var _reachOk = true, _carryOk = true;
        var _builds = [], _clears = [], _cardCost = 0, _poison = 0;
        for (var _o = 0; _o < array_length(_obs); _o++) {
            var _O = _obs[_o];
            if (_O.soft) {                                       // poison: passable; attrition unless immune
                if (!arr_has(pikmin_type_get(_C).immunities, "poison")) _poison += 1;
                continue;
            }
            var _rNative = arr_has(_ansR[_o].nativeColors, _C);
            var _cNative = arr_has(_ansC[_o].nativeColors, _C);
            if (_rNative && _cNative) continue;                  // crosses freely both ways

            if (_O.kind != "hazard") {                           // enemy / wall / emitter / pile: must be cleared
                var _cleared = false;
                for (var _k = 0; _k < array_length(_ansR[_o].open); _k++) {
                    var _v = _ansR[_o].open[_k].via;
                    if (_v == "kill" || _v == "destroy") { array_push(_clears, _O.idx); _cleared = true; break; }
                }
                if (!_cleared) { _reachOk = false; break; }      // e.g. an intervening pile - no simple clear
            } else {                                             // terrain hazard: prefer a structure (serves both ways)
                var _built = false;
                for (var _k = 0; _k < array_length(_ansR[_o].open); _k++) {
                    var _op = _ansR[_o].open[_k];
                    if (_op.via == "bridge" || _op.via == "climbingstick" || _op.via == "tunnel") {
                        array_push(_builds, { idx: _O.idx, via: _op.via, cost: _op.cost });
                        _cardCost += _op.cost; _built = true; break;
                    }
                }
                if (!_built) {                                   // no structure available: native / lifeguard for reach only
                    var _lg = false;
                    for (var _k = 0; _k < array_length(_ansR[_o].open); _k++) if (_ansR[_o].open[_k].via == "lifeguard") _lg = true;
                    if (_rNative || _lg) { if (!_cNative) _carryOk = false; }  // reach ok; carry may fail (reach-only)
                    else { _reachOk = false; break; }            // can't even reach this hazard
                }
            }
        }
        if (!_reachOk) continue;
        var _carry = pikmin_type_get(_C).carry;
        var _bodies = ceil(_w / max(1, _carry)) + _poison;
        var _turns = array_length(_builds) + array_length(_clears) + ai2_turns_to_bank(_g, _p, _idx, _w, false);
        array_push(_methods, { color: _C, canReach: true, canCarry: _carryOk, bodies: _bodies,
            builds: _builds, clears: _clears, cardCost: _cardCost, turns: _turns });
    }
    return _methods;
}

/// DEMAND-DRIVEN REDEMPTION target (2026-07-22): the basic colour worth GROWING for
/// the turn plan - over live piles, the carrier colour of the cheapest CAN-CARRY access
/// method that is a board basic (pellet redemption only mints basics), scored by pile
/// value / (1 + cardCost + turns) so a cheaply-bankable colour wins. Feeds the preamble:
/// redeem a pellet into this colour ONLY when its own colour is deadweight (reaches no
/// live pile) - "grow the colour the plan needs, inefficiently, only when the efficient
/// colour is useless". Returns "" if no basic can bank anything. See cascade-orders-spec.
function ai3_growth_demand(_g, _p) {
    var _best = "", _bestScore = -1;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _v = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        var _methods = ai3_access_methods(_g, _p, _t.lane, _t.idx);
        for (var _mi = 0; _mi < array_length(_methods); _mi++) {
            var _m = _methods[_mi];
            if (!_m.canCarry) continue;                                        // must be able to BANK via this colour
            if (!arr_has(_g.boardDef.basicColors, _m.color)) continue;         // redemption only mints basics
            var _score = _v / (1 + _m.cardCost + _m.turns);                    // cheaper recipe wins
            if (_score > _bestScore) { _bestScore = _score; _best = _m.color; }
        }
    }
    return _best;
}

/// MAIN-LANE (ADVANCE target) pick (user, 2026-07-18). Score each lane's pile by
/// VALUE / MY-ACCESS, modulated by how much farther the OPPONENT is from it: a pile
/// they can't reach is nearly free (boost), one they're closer to is contested
/// (discount). Value DIVIDES by access so a rich pile survives a hard road (value
/// dominance - "a 1000-pt pile is worth cutting through enemies"). Opp factor is
/// bounded clamp(oppAccess/myAccess, 0.5, 2). Lanes MY access can't open (INF) are
/// skipped. Returns { lane, toIdx, score }; lane -1 if none. Coefficients tunable.
function ai3_main_lane(_g, _p) {
    var _bestLane = -1, _bestIdx = 3, _bestScore = -1;
    var _spicy = arr_has(_g.players[_p].hand, "spicyspray");
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _myA = ai3_access_cost(_g, _p, _t.lane, _t.idx, _spicy);
        if (_myA >= ACCESS_INF) continue;                              // can't open it -> not a main goal
        var _oppA = ai3_access_cost(_g, 1 - _p, _t.lane, _t.idx);      // opp hand unseen -> no spicy assumed
        var _V = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        var _score = _V / _myA * clamp(_oppA / max(1, _myA), 0.5, 2.0);
        if (_score > _bestScore) { _bestScore = _score; _bestLane = _t.lane; _bestIdx = _t.idx; }
    }
    return { lane: _bestLane, toIdx: _bestIdx, score: _bestScore };
}

#macro BREADTH_CAP 3    // max piles to contest in one turn (user: 25 pikmin banks ~2, 3 if one's cheap - never spread across all 5)

/// The BREADTH CAP: the top _maxN reachable piles by the main-lane score
/// (V / access, opp-modulated). Contest at most these; piles outside get no advance
/// this turn (spreading across all 5 thins out so NOTHING completes). Returns
/// {lane, idx, score}[], best first. (ai3_main_lane == this with _maxN 1.)
function ai3_target_piles(_g, _p, _maxN) {
    var _scored = [];
    var _spicy = arr_has(_g.players[_p].hand, "spicyspray");
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _myA = ai3_access_cost(_g, _p, _t.lane, _t.idx, _spicy);
        if (_myA >= ACCESS_INF) continue;
        var _oppA = ai3_access_cost(_g, 1 - _p, _t.lane, _t.idx);
        var _V = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        array_push(_scored, { lane: _t.lane, idx: _t.idx, score: _V / _myA * clamp(_oppA / max(1, _myA), 0.5, 2.0) });
    }
    for (var _a = 1; _a < array_length(_scored); _a++) {         // insertion sort, score desc
        var _tmp = _scored[_a], _b = _a - 1;
        while (_b >= 0 && _scored[_b].score < _tmp.score) { _scored[_b + 1] = _scored[_b]; _b -= 1; }
        _scored[_b + 1] = _tmp;
    }
    var _out = [];
    for (var _i = 0; _i < min(_maxN, array_length(_scored)); _i++) array_push(_out, _scored[_i]);
    return _out;
}

#macro SECURE_BUFFER 4  // rush-off depth over-stack above min-win (user: "3-5"); tunable

/// ADVANCE STEP-SIZING: strength to COMMIT to advance the pile at _t this turn.
/// Baseline = MIN-WIN (control the tug: > opponent-there AND >= weight). In DEPTH
/// mode (the single-reachable-pile case) it over-stacks per the pinned rules:
///   - RUSH 2x  when rush is ON, weight <= 8, opponent-on-pile < weight (else they
///     "hold" it and the carry caps at 1 space so 2x is wasted), and no purple on
///     the stack (purple = strong-but-slow, cancels rush).
///   - else SECURING BUFFER (+SECURE_BUFFER) only if the opponent can re-contest
///     the lane (has bodies in it) - no point buffering against nobody.
/// BREADTH mode (>=2 reachable piles) = min-win only, no over-stack (spread thin,
/// bet the opp can only answer one). Returns strength STILL to commit (0 = already
/// holding enough). See cascade-orders-spec milestone 3.
function ai3_advance_commit(_g, _p, _t, _depth) {
    var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
    var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
    var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
    var _oppLaneStr = 0;
    var _ot = _g.players[1 - _p].tokens;
    for (var _i = 0; _i < array_length(_ot); _i++)
        if (_ot[_i].loc.kind == "space" && _ot[_i].loc.lane == _t.lane) _oppLaneStr += pikmin_type_get(_ot[_i].typeId).carry;

    var _target = max(_w, _oppS + 1);   // MIN-WIN: control the tug
    if (_depth) {
        var _rushOk = global.expRules.rush && _w <= 8 && _oppS < _w && !game_carriers_have_purple(_g, _p, _t);
        if (_rushOk) _target = max(_target, _w * 2);            // 2x rush (2 spaces/turn)
        else if (_oppLaneStr > 0) _target += SECURE_BUFFER;     // secure vs re-contest
    }
    return max(0, _target - _myS);
}

/// EXPLOSIVE THREAT: total blast `damage` that will hit (lane,idx) THIS turn. An
/// explosive enemy detonates a + pattern (its space + the 4 orthogonally-adjacent),
/// killing `damage` pikmin of BOTH players in each space - even if you never engaged
/// it - UNLESS it dies this turn (killed in pass A -> no boom). So any space within
/// Manhattan distance 1 of a SURVIVING explosive enemy is a death trap for deployed
/// pikmin. Pass _killedSet (enemies my committed strength kills) so an explosive I'm
/// killing this turn is discounted. Covers explosive ENEMIES and explosive BOSSES.
function ai3_explosive_threat(_g, _p, _lane, _idx, _killedSet = []) {
    var _threat = 0;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            if (abs(_l - _lane) + abs(_i - _idx) > 1) continue;   // outside the + pattern
            var _e = _g.board.lanes[_l].spaces[_i].enemy;
            if (_e == undefined) { var _bt = game_treasure_at(_g, _l, _i); if (_bt != undefined) _e = _bt.boss; }
            if (_e == undefined) continue;
            var _def = enemy_def_get(_e.enemyDefId);
            if (_def.attackElement != "explosive" || _def.damage <= 0) continue;
            var _killed = false;
            for (var _k = 0; _k < array_length(_killedSet); _k++)
                if (_killedSet[_k].lane == _l && _killedSet[_k].idx == _i) { _killed = true; break; }
            if (!_killed) _threat += _def.damage;
        }
    }
    return _threat;
}

/// The explosive enemy most worth DEFUSING - one whose + pattern covers a space
/// where I HAVE PIKMIN (i.e. a space I'm ending on), and that I'm NOT already killing
/// this turn. Returns its {lane,idx} (highest damage first) or undefined. Per the
/// user: an explosive is only a threat worth spending a card on if it'll damage a
/// space you intend to end on. The defuse = freeze it (bitter/ice/storm) so it skips
/// its detonation, or one-shot it. Covers explosive enemies and bosses.
function ai3_explosive_to_defuse(_g, _p, _killedSet = []) {
    var _best = undefined, _bestDmg = 0;
    var _offs = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]];
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            var _e = _g.board.lanes[_l].spaces[_i].enemy;
            if (_e == undefined) { var _bt = game_treasure_at(_g, _l, _i); if (_bt != undefined) _e = _bt.boss; }
            if (_e == undefined) continue;
            var _def = enemy_def_get(_e.enemyDefId);
            if (_def.attackElement != "explosive" || _def.damage <= 0) continue;
            var _killed = false;
            for (var _k = 0; _k < array_length(_killedSet); _k++)
                if (_killedSet[_k].lane == _l && _killedSet[_k].idx == _i) { _killed = true; break; }
            if (_killed) continue;                                          // I kill it this turn -> no boom
            var _hitsMe = false;
            for (var _o = 0; _o < array_length(_offs) && !_hitsMe; _o++) {
                var _bl = _l + _offs[_o][0], _bi = _i + _offs[_o][1];
                if (_bl < 0 || _bl >= _g.board.laneCount || _bi < 0 || _bi > 6) continue;
                if (game_strength_at(_g, _p, _bl, _bi) > 0) _hitsMe = true;  // my pikmin in the blast
            }
            if (_hitsMe && _def.damage > _bestDmg) { _bestDmg = _def.damage; _best = { lane: _l, idx: _i }; }
        }
    }
    return _best;
}

/// Home strength of colour _col that can legally reach the pile at (lane,idx).
function ai3_reach_color(_g, _p, _lane, _idx, _col) {
    if (!game_dest_legal(_g, _p, _col, _lane, _idx)) return 0;
    var _s = 0, _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++)
        if (_toks[_i].loc.kind == "home" && _toks[_i].typeId == _col) _s += pikmin_type_get(_col).carry;
    return _s;
}

/// Home NON-PURPLE strength that can reach the pile (purple can't rush). Each colour
/// checked for road access separately.
function ai3_reach_nonpurple(_g, _p, _lane, _idx) {
    var _s = 0, _toks = _g.players[_p].tokens, _seen = {};
    for (var _i = 0; _i < array_length(_toks); _i++) {
        var _tk = _toks[_i];
        if (_tk.loc.kind != "home" || _tk.typeId == "purple") continue;
        if (!variable_struct_exists(_seen, _tk.typeId)) _seen[$ _tk.typeId] = game_dest_legal(_g, _p, _tk.typeId, _lane, _idx);
        if (_seen[$ _tk.typeId]) _s += pikmin_type_get(_tk.typeId).carry;
    }
    return _s;
}

/// SNIPE: can I carry this pile HOME THIS TURN (uncontestable bank)? spicy adds a 2nd
/// carry pass, rush/white make each pass 2 spaces -> 4 spaces = a centre pile (dist<=4)
/// banked in one turn. WHITE path: all-white carriers get the 2-step natively (rush-
/// independent, works even against a holding opp if I out-muscle) - need white reach
/// >= max(weight, oppOnPile+1). RUSH path (non-white, non-purple): needs rush ON, own
/// >= 2*weight, and opp NOT holding (opp < weight). Both need a spicy in hand and the
/// pile within a 4-space haul. See cascade-orders-spec (the Zak-game "snipe" tier).
function ai3_can_instant_bank(_g, _p, _t) {
    if (array_length(_t.cards) == 0 || _t.boss != undefined) return false;
    if (!arr_has(_g.players[_p].hand, "spicyspray")) return false;         // need the extra carry action
    var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
    var _dist = (_p == 0) ? (_t.idx + 1) : (7 - _t.idx);
    if (_dist > 4) return false;                                            // combo hauls at most 4 spaces
    var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
    // WHITE path (native 2-step, not opp-holding-gated): just out-muscle + meet weight
    if (ai3_reach_color(_g, _p, _t.lane, _t.idx, "white") >= max(_w, _oppS + 1)) return true;
    // RUSH path (non-white, non-purple): rush ON + 2x weight + opp not holding
    if (global.expRules.rush && _oppS < _w && ai3_reach_nonpurple(_g, _p, _t.lane, _t.idx) >= max(_w * 2, _oppS + 1)) return true;
    return false;
}

/// Bodies lost CLEARING this blocker enemy (prices PREPARE/clean so a suicide clear
/// doesn't out-rank cheap safe ones). If I own NO colour that both hurts it AND
/// survives its defence, the whole attack MELTS on a real suicide-defence (loss ~=
/// the kill req); plus any UNAVOIDABLE swing (swift/crush land even on the kill).
/// Coarse but enough to sink "melt the army into a fire wall" below "lose 1 to a swift".
function ai3_clear_loss(_g, _p, _eDef, _req) {
    var _safe = false;
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) {
        var _tid = _toks[_i].typeId;
        if (ai_type_can_hurt(_tid, _eDef) && ai_type_survives_defense(_tid, _eDef)) { _safe = true; break; }
    }
    var _melt = _safe ? 0 : _req;   // no immune-and-able clearer -> the whole attack melts
    var _swing = ((_eDef.attackElement == "swift" || _eDef.attackElement == "crush") && _eDef.damage > 0) ? _eDef.damage : 0;
    return _melt + _swing;
}

/// FRICTION (spec: count of hazard TYPES not yet answerable; span = minor
/// surcharge). Deliberately NOT ai2_road_needs.gates - that counts ALL types
/// incl. answerable ones (water reads as a gate even with blues), the exact
/// over-penalty the lane audit caught. Here a type ANY owned colour can already
/// cross costs ~0; only unanswered types (chasm/no-bridge, off-colour hazards)
/// are friction. Plus blocker HP on the road. Lower = easier to reach the pile.
function ai3_friction(_g, _p, _lane, _toIdx) {
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    var _seenTypes = [];
    var _fric = 0;
    var _cols = [];
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) if (!arr_has(_cols, _toks[_i].typeId)) array_push(_cols, _toks[_i].typeId);
    while (_s != _toIdx) {
        var _sp = _g.board.lanes[_lane].spaces[_s];
        if (_sp.enemy != undefined) _fric += _sp.enemy.curHp * 0.1;              // clear cost
        if (_sp.structure != undefined) _fric += _sp.structure.curHp * 0.1;
        if (_sp.structure == undefined && _sp.kind == "hazard" && _sp.hazard != "poison") {
            if (!arr_has(_seenTypes, _sp.hazard)) {
                array_push(_seenTypes, _sp.hazard);                              // count TYPES once
                var _answerable = false;
                for (var _c = 0; _c < array_length(_cols) && !_answerable; _c++) {
                    if (game_type_can_enter(pikmin_type_get(_cols[_c]), _sp, true, false)) _answerable = true;
                }
                if (!_answerable) _fric += (_sp.hazard == "chasm") ? 2.0 : 1.0;   // unanswered gate
            } else {
                _fric += 0.15;                                                    // extra span of a known type: minor
            }
        }
        _s += _dir;
    }
    return max(1, _fric);
}

/// The CASCADE orders planner: same proven primitives as v2, but candidates carry
/// a PRIORITY TIER (deny-interrupt > advance > prepare) and the sort is tier-then-
/// value. ai_orders_commit funds each at MINIMUM (req), so the reserve cascades
/// down the tiers - the user's "satisfy each goal minimally, remainder flows on".
/// Latch is emergent: a held pile's req = need - myStrengthThere is tiny, so it
/// tops its tier and consumes almost nothing (NO separate home-only viability
/// gate - that was planner v3.1's bug).
function ai3_orders_plan(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];

    // --- economy preamble (proven, shared shape with v2): redeem pellets, posy ---
    if (game_capped_count(_g, _p) >= global.rules.pikminBoardCap
        && array_length(_pl.pellets) > 0 && !arr_has(_pl.hand, "ivoryandviolet")) {
        ai_cull_deadweight(_g, _p);
    }
    // DEMAND-DRIVEN redemption: keep own-colour when it can reach a live pile (efficient
    // same-rate), but when own-colour is DEADWEIGHT (reaches nothing) redeem into the
    // colour the plan actually needs (ai3_growth_demand) instead - "grow the needed
    // colour, off-rate, only when the efficient one is useless". Falls back to v2 growth.
    var _demand = ai3_growth_demand(_g, _p);
    var _guard = 0;
    while (array_length(_pl.pellets) > 0 && game_capped_count(_g, _p) < global.rules.pikminBoardCap && _guard < 40) {
        _guard += 1;
        var _pDef = pellet_def_get(_pl.pellets[0]);
        var _own = _pDef.color;
        var _col;
        if (arr_has(_g.boardDef.basicColors, _own) && ai3_color_reaches_target(_g, _p, _own)) _col = _own; // own colour is useful
        else if (_demand != "") _col = _demand;                                                            // grow what the plan needs
        else _col = ai2_pick_growth_color(_g, _p);                                                         // nothing clear -> v2 fallback
        game_play_pellet(_g, 0, _col);
    }
    var _hi = 0;
    while (_hi < array_length(_pl.hand)) {
        if (_pl.hand[_hi] == "colorchangingposy" && game_capped_count(_g, _p) <= global.rules.pikminBoardCap - 3) {
            if (game_play_gather(_g, _hi, { color: ai2_pick_growth_color(_g, _p) })) continue;
        }
        _hi += 1;
    }

    // --- position-preserving recall (proven, copied from v2) ---
    var _tokens = _pl.tokens;
    var _mySideLo = (_p == 0) ? 0 : 4;
    var _mySideHi = (_p == 0) ? 2 : 6;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i];
        var _loc = _tok.loc;
        if (_loc.kind != "space") continue;
        if (token_is_disabled(_tok)) continue;
        if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue;
        var _rsp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
        if (_rsp.enemy != undefined || _rsp.structure != undefined || game_treasure_at(_g, _loc.lane, _loc.idx) != undefined) continue;
        if (_loc.idx >= _mySideLo && _loc.idx <= _mySideHi) _tok.loc = { kind: "home" };
        // far side / centre: stay put - position past one-way terrain can't be rebought
    }
    // NOTE: far-side local reassignment (v2 has it) deliberately NOT re-added here
    // yet - reverting to the exact known-good 3-win baseline first; add + test it
    // as an isolated change once this baseline is reconfirmed.

    var _risk = ai_risk_pref(_g, _p);              // <0 ahead (turtle), >0 behind (gamble), ×time
    var _scarce = ai_scarcity(_g, _p);
    var _myTurns = ai2_my_turns_left(_g);
    var _hasSpicy = arr_has(_pl.hand, "spicyspray");
    var _homeStr = ai_home_strength(_g, _p);
    ai_dbg("");
    ai_dbg("===== v3 TURN P" + string(_p + 1) + "  Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength)
        + ")  score " + string(game_realized_score(_g, _p)) + " vs " + string(game_realized_score(_g, 1 - _p))
        + "  myTurns=" + string(_myTurns) + "  homeStr=" + string(_homeStr) + "  risk=" + string(_risk) + " =====");

    // --- main-lane pick (reworked after the Zak game, cascade-orders-spec) ---
    // Default is FOCUS + secure the ONE main lane (spreading thin let a human flip
    // every thin contest). Breadth is now gated per-pile on OPPONENT NON-ACCESS, not
    // a reachable-pile count; a SNIPE (bank-this-turn) tops everything. Decided in the
    // per-treasure loop below.
    var _main = ai3_main_lane(_g, _p);
    ai_dbg("v3 main-lane " + string(_main.lane + 1) + " (score " + string(round(_main.score))
        + ") - focus+secure; snipe tops; breadth only where the opp can't reach");

    // --- my projected banking over the next ~2 turns (for the deny-interrupt bar) ---
    var _myProj = 0;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _mt = _g.treasures[_ti];
        if (array_length(_mt.cards) == 0 || _mt.boss != undefined) continue;
        var _mw = treasure_def_get(_mt.cards[array_length(_mt.cards) - 1]).weight;
        if (ai2_turns_to_bank(_g, _p, _mt.idx, _mw, _hasSpicy) <= 2
            && game_strength_at(_g, _p, _mt.lane, _mt.idx) >= _mw) {
            _myProj += max(ai_pile_marginal(_g, _p, _mt), ai_pile_raw(_mt) * 0.3);
        }
    }

    var _cands = [];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _raw = ai_pile_raw(_t);
        var _wMe = max(ai_pile_marginal(_g, _p, _t), _raw * 0.30);
        var _wOpp = max(ai_pile_marginal(_g, 1 - _p, _t), _raw * 0.30);
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);       // FLAG #2: bodies already there
        var _oppS = game_strength_at(_g, 1 - _p, _t.lane, _t.idx);
        // opponent's RE-CONTEST reserve: their bodies elsewhere in this lane that
        // can redeploy onto the pile next turn (the source of tug oscillation)
        var _oppLaneStr = 0;
        var _otoks = _g.players[1 - _p].tokens;
        for (var _oi = 0; _oi < array_length(_otoks); _oi++) {
            if (_otoks[_oi].loc.kind == "space" && _otoks[_oi].loc.lane == _t.lane) _oppLaneStr += pikmin_type_get(_otoks[_oi].typeId).carry;
        }
        var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
        var _tBank = ai2_turns_to_bank(_g, _p, _t.idx, _w, _hasSpicy);

        // ---- DENY-INTERRUPT: their movable pile about to bank an unacceptable swing ----
        var _theyMove = (_oppS >= _w && _oppS > _myS && _t.boss == undefined);
        if (_theyMove) {
            var _theirTb = ai2_turns_to_bank(_g, 1 - _p, _t.idx, _w, false);
            var _unacceptable = (_theirTb <= 2) && ((_wOpp - _myProj) > 150 || _wOpp > 300);
            var _stallReq = (_oppS - _myS) + 1;   // minimum to tie/break their tug
            // SLACK only: must not eat the reserve my own advances need (~half)
            if (_unacceptable && _stallReq <= max(2, _homeStr * 0.5)) {
                array_push(_cands, { tier: 3, kind: "pile", lane: _t.lane, idx: _t.idx, req: _stallReq,
                    value: _wOpp, enemyDef: undefined, oppS: _oppS, myS: _myS, w: _w,
                    why: "v3 DENY-interrupt " + string(round(_wOpp)) + "p (their tb" + string(_theirTb) + ")" });
                continue; // this pile is a threat, not a target for me this turn
            }
        }

        // Pursue every pile: PREPARE (clearing blockers) DEVELOPS the board and must
        // never be gated; ADVANCE contests. A SNIPE (bank this turn) is top priority;
        // the main lane is value-boosted. Securing is OPPORTUNISTIC in ai_orders_commit
        // (it overstacks toward 2x when affordable) so holds survive a re-contest and
        // body-cost naturally caps over-spread - NO hard skip gate (skipping secondaries
        // killed board development -> grotto 0-banks, the over-correction from Zak).
        var _isMain = (_t.lane == _main.lane);
        var _snipe  = ai3_can_instant_bank(_g, _p, _t);

        // ---- ADVANCE: a pile MOVABLE NOW (road clear to it) ----
        if (_blk == undefined) {
            if (_t.boss != undefined) {
                var _bDef = enemy_def_get(_t.boss.enemyDefId);
                if (!ai_can_group_hurt(_g, _p, _bDef)) { ai_dbg("v3 SKIP boss " + _bDef.name + ": can't hurt"); continue; }
                var _dps = max(1, ai_send(_g, _p, _t.lane, _t.idx, _t.boss.curHp, _bDef, true));
                var _tKill = ceil(_t.boss.curHp / _dps);
                if (_tKill + _tBank > _myTurns) { ai_dbg("v3 SKIP boss " + _bDef.name + ": t" + string(_tKill + _tBank) + ">" + string(_myTurns)); continue; }
                array_push(_cands, { tier: 2, kind: "boss", lane: _t.lane, idx: _t.idx, req: ai_enemy_req(_g, _p, _bDef, _t.boss.curHp),
                    value: (_wMe + ai_reward_value(_bDef)) / max(1, _tKill + _tBank) * 10, enemyDef: _bDef, oppS: 0, myS: 0, w: _w,
                    why: "v3 boss " + _bDef.name });
                continue;
            }
            var _canBank = (_tBank <= _myTurns);
            // req = MIN-WIN (always committable - never PASS a pile for lack of 2x);
            // a SNIPE needs the full carry strength THIS turn, so it's sized to depth
            // and presized (exact). Non-snipe advances stay un-presized so ai_orders_
            // commit overstacks toward 2x WHEN AFFORDABLE (opportunistic securing - a
            // held pile survives the opponent's re-stack instead of a thin flip).
            var _req = ai3_advance_commit(_g, _p, _t, _snipe);
            if (_req <= 0) {
                // already holding enough - advances free this turn, no bodies spent (the latch)
                ai_dbg("v3 holding lane" + string(_t.lane + 1) + " (myS " + string(_myS) + ") - advancing free");
                continue;
            }
            var _val = ((_canBank ? _wMe : 0) + (_oppS > 0 ? _wOpp * 0.5 : 0)) / max(1, _tBank);
            if (_isMain) _val *= 3;    // focus the main lane
            if (_snipe)  _val *= 5;    // an uncontestable bank tops everything
            // DEPLOY-AVOIDANCE: a pile in a surviving explosive's blast wipes carriers
            // sent there - discount it UNLESS I hold a defuser (bitter/ice) to neutralise
            // the explosive first (then I deploy + defuse, per the user's model).
            var _boom = ai3_explosive_threat(_g, _p, _t.lane, _t.idx);
            if (_boom > 0 && !arr_has(_pl.hand, "bitterspray") && !arr_has(_pl.hand, "icebomb")) _val /= (1 + _boom);
            if (_val <= 0) continue;
            array_push(_cands, { tier: 2, kind: "pile", lane: _t.lane, idx: _t.idx, req: _req,
                value: _val, enemyDef: undefined, oppS: _oppS, myS: _myS, w: _w, presized: _snipe,
                why: "v3 " + (_snipe ? "SNIPE" : (_isMain ? "FOCUS" : "advance")) + " " + string(_raw) + "p" + (_canBank ? " tb" + string(_tBank) : "") + (_myS > 0 ? " (holding " + string(_myS) + ")" : "") });
            continue;
        }

        // ---- PREPARE: the pile is BLOCKED - open the road (value ÷ friction) ----
        var _fric = ai3_friction(_g, _p, _t.lane, _t.idx);
        var _prepVal = _wMe / _fric; // access per difficulty; rich pile justifies more clearing
        if (_t.lane == _main.lane) _prepVal *= 3;   // opening the MAIN lane's blocker is the priority
        if (_blk.kind == "enemy") {
            var _eDef = enemy_def_get(_blk.enemy.enemyDefId);
            if (ai_can_group_hurt(_g, _p, _eDef)) {
                // price the clear by its BODY COST: a suicide-defence blocker we have
                // no immune colour for melts the whole attack -> heavily discount, so a
                // cheap safe clear elsewhere beats sacrificing the army to open one lane.
                var _clr = ai3_clear_loss(_g, _p, _eDef, ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp));
                var _expB = (_eDef.attackElement == "explosive") ? 2 : 1; // ONE-SHOT PRIORITY: killing it (pass A) removes a wide threat + no boom
                array_push(_cands, { tier: 1, kind: "enemy", lane: _t.lane, idx: _blk.idx, req: ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp),
                    value: _prepVal / (1 + _clr) * _expB, enemyDef: _eDef, oppS: 0, myS: 0,
                    why: "v3 PREPARE open " + _eDef.name + " (fric " + string(round(_fric * 10) / 10) + ", loss " + string(_clr) + ")" });
            }
        } else if (_blk.kind == "structure") {
            var _sSp = _g.board.lanes[_t.lane].spaces[_blk.idx];
            if (ai_can_damage_struct(_g, _p, _sSp.structure.structId)) {
                var _sD = hazard_def_get(_sSp.structure.structId);
                var _pseudo = (_sD.type == "hazard" && _sD.element != "")
                    ? { id: "emitterstruct", attackElement: "", defenseElement: _sD.element, damage: 0, reward: { pellets: 0, gather: 0 } }
                    : undefined;
                array_push(_cands, { tier: 1, kind: "structure", lane: _t.lane, idx: _blk.idx, req: _blk.hp,
                    value: _prepVal, enemyDef: _pseudo, oppS: 0, myS: 0,
                    why: "v3 PREPARE open " + _sD.name + " (fric " + string(round(_fric * 10) / 10) + ")" });
            }
        }
    }

    // ---- PREPARE cleanup: own-side enemies (access + safety; drops incidental) ----
    for (var _laneIdx = 0; _laneIdx < _g.board.laneCount; _laneIdx++) {
        for (var _si = _mySideLo; _si <= _mySideHi; _si++) {
            var _sp2 = _g.board.lanes[_laneIdx].spaces[_si];
            if (_sp2.enemy != undefined) {
                var _eD2 = enemy_def_get(_sp2.enemy.enemyDefId);
                if (ai_can_group_hurt(_g, _p, _eD2)) {
                    var _clr2 = ai3_clear_loss(_g, _p, _eD2, ai_enemy_req(_g, _p, _eD2, _sp2.enemy.curHp));
                    var _expB2 = (_eD2.attackElement == "explosive") ? 2 : 1; // one-shot priority (kill it before it booms)
                    array_push(_cands, { tier: 1, kind: "clean", lane: _laneIdx, idx: _si, req: ai_enemy_req(_g, _p, _eD2, _sp2.enemy.curHp),
                        value: (8 + ai_reward_value(_eD2) * 0.5) / (1 + _clr2) * _expB2, enemyDef: _eD2, oppS: 0, myS: 0,
                        why: "v3 clean " + _eD2.name + " (loss " + string(_clr2) + ")" });
                }
            }
        }
    }

    // favoured lane: gentle ×1.05 tiebreak for variety (the old ai2Goal, un-hardlocked)
    if (!variable_struct_exists(_g, "ai3Goal")) _g.ai3Goal = [irandom(_g.board.laneCount - 1), irandom(_g.board.laneCount - 1)];
    var _fav = _g.ai3Goal[_p];
    for (var _a = 0; _a < array_length(_cands); _a++) if (_cands[_a].lane == _fav) _cands[_a].value *= 1.05;

    // sort by TIER desc, then value desc within tier (the cascade)
    for (var _a = 0; _a < array_length(_cands); _a++) _cands[_a].ratio = _cands[_a].value / max(1, _cands[_a].req);
    for (var _a = 1; _a < array_length(_cands); _a++) {
        var _tmp = _cands[_a];
        var _b = _a - 1;
        while (_b >= 0 && (_cands[_b].tier < _tmp.tier || (_cands[_b].tier == _tmp.tier && _cands[_b].value < _tmp.value))) {
            _cands[_b + 1] = _cands[_b]; _b -= 1;
        }
        _cands[_b + 1] = _tmp;
    }
    return { cands: _cands, risk: _risk, scarce: _scarce, idx: 0 };
}

/// Enemies my ALREADY-DEPLOYED strength kills THIS turn (on-space strength >= its
/// kill requirement). Feeds the deadweight lookahead at finish, so bodies queued
/// behind a blocker I'm killing this turn aren't mislabelled deadweight.
function ai3_committed_kills(_g, _p) {
    var _out = [];
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _i = 0; _i <= 6; _i++) {
            var _e = _g.board.lanes[_l].spaces[_i].enemy;
            if (_e == undefined) continue;
            var _def = enemy_def_get(_e.enemyDefId);
            if (game_strength_at(_g, _p, _l, _i) >= ai_enemy_req(_g, _p, _def, _e.curHp)) array_push(_out, { lane: _l, idx: _i });
        }
    }
    return _out;
}

/// v3 finish: (1) reinforce dump - leftover onto the best pile we can at least tie
/// (as v2); then (2) the ANTI-HOARD deadweight GRIND - if leftover strength is
/// DEADWEIGHT (reaches no pile even after this turn's kills), throw it at a reachable
/// enemy a chip would DAMAGE (permanent HP progress) instead of hoarding it home.
/// Prefers element-locked enemies (can't be cheaply killed -> grinding pays most).
/// Bounded to one grind target; capped at the deadweight strength. See cascade-
/// orders-spec milestone 2/3. THIS is the fix for the minefield idle-army hoard.
function ai3_orders_finish(_g, _plan) {
    var _p = _g.activePlayer;
    var _cands = _plan.cands;

    // (1) reinforce a tie-able pile with the leftover reserve
    if (ai_home_strength(_g, _p) >= 6) {
        for (var _ci = 0; _ci < array_length(_cands); _ci++) {
            var _dc = _cands[_ci];
            if (_dc.value <= 0 || _dc.kind != "pile") continue;
            var _dry = ai_send(_g, _p, _dc.lane, _dc.idx, 99, undefined, true);
            if (game_strength_at(_g, _p, _dc.lane, _dc.idx) + _dry < game_strength_at(_g, 1 - _p, _dc.lane, _dc.idx)) continue; // can't even tie
            var _dumped = ai_send(_g, _p, _dc.lane, _dc.idx, 99, undefined);
            if (_dumped > 0) { ai_dbg("v3 reinforce dump " + string(_dumped) + " -> lane" + string(_dc.lane + 1)); break; }
        }
    }

    // (2) deadweight grind: idle bodies with nowhere productive to go -> chip a
    // reachable enemy for permanent HP, rather than sit home (the anti-hoard rule)
    var _dw = ai3_deadweight_strength(_g, _p, ai3_committed_kills(_g, _p), []);
    if (_dw.total > 0) {
        var _gL = -1, _gI = -1, _gDef = undefined, _gScore = -1;
        for (var _l = 0; _l < _g.board.laneCount; _l++) {
            for (var _i = 0; _i <= 6; _i++) {
                var _e = _g.board.lanes[_l].spaces[_i].enemy;
                if (_e == undefined) continue;
                var _def = enemy_def_get(_e.enemyDefId);
                if (!ai_can_group_hurt(_g, _p, _def)) continue;                     // a chip must land damage
                if (ai_send(_g, _p, _l, _i, 99, _def, true) <= 0) continue;         // must be reachable
                // element-locked (real suicide-defence) enemies are the pricey ones to
                // kill cleanly, so throwaway grinding pays most; then prefer lower HP.
                var _locked = (_def.defenseElement != "" && _def.defenseElement != "crush" && _def.defenseElement != "height") ? 100 : 0;
                var _sc = _locked + (30 - min(30, _e.curHp));
                if (_sc > _gScore) { _gScore = _sc; _gL = _l; _gI = _i; _gDef = _def; }
            }
        }
        if (_gL >= 0) {
            var _ground = ai_send(_g, _p, _gL, _gI, _dw.total, _gDef);
            if (_ground > 0) ai_dbg("v3 deadweight grind " + string(_ground) + " -> " + _gDef.name + " lane" + string(_gL + 1) + " (permanent HP)");
        }
    }

    var _handStr = "";
    var _hand2 = _g.players[_p].hand;
    for (var _hj = 0; _hj < array_length(_hand2); _hj++) _handStr += (_hj > 0 ? "," : "") + _hand2[_hj];
    ai_dbg("v3 orders done. homeStr=" + string(ai_home_strength(_g, _p)) + "  hand=[" + _handStr + "]");
    game_orders_done(_g);
}

/// Paced driver (one deployment per tick), mirrors ai2_orders.
function ai3_orders(_g) {
    if (!variable_struct_exists(_g, "ai3Plan") || _g.ai3Plan == undefined) {
        _g.ai3Plan = ai3_orders_plan(_g);
        return;
    }
    var _plan = _g.ai3Plan;
    while (_plan.idx < array_length(_plan.cands)) {
        var _moved = ai_orders_commit(_g, _plan.cands[_plan.idx], _plan.risk, _plan.scarce);
        _plan.idx += 1;
        if (_moved) return;
    }
    ai3_orders_finish(_g, _plan);
    _g.ai3Plan = undefined;
}

/// Cascade-aware bridge: open the hazard gate on the road to the most valuable
/// pile. More aggressive than v2's ai_try_card rawmaterial case, which bails if
/// an enemy sits on the road (orders clears that enemy separately) and demands 2
/// copies. One bridge opens pikmin passage now; the treasure carry re-bridges
/// later. Returns true if it played a card.
function ai3_try_bridge(_g, _p) {
    var _pl = _g.players[_p];
    if (!arr_has(_g.boardDef.structures.bridges, "bridge")) return false;
    // need 2+ copies (REVERTED from 1, 2026-07-17): a plain bridge BREAKS when the
    // treasure crosses, so a single bridge opens pikmin passage but the carry can't
    // extract - you need a second to re-bridge for the haul. The 1-copy relaxation
    // wasted materials building bridges that collapsed before anything banked.
    var _hi = -1, _copies = 0;
    for (var _i = 0; _i < array_length(_pl.hand); _i++) if (_pl.hand[_i] == "rawmaterial") { if (_hi < 0) _hi = _i; _copies += 1; }
    if (_hi < 0 || _copies < 2) return false;

    var _cols = [];
    for (var _i = 0; _i < array_length(_pl.tokens); _i++) if (!arr_has(_cols, _pl.tokens[_i].typeId)) array_push(_cols, _pl.tokens[_i].typeId);

    var _bgVal = 0, _bgLane = -1, _bgIdx = -1;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0) continue;
        var _val = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        if (_val <= _bgVal) continue;
        // first HAZARD gate no owned colour can cross - enemies on the road do NOT
        // abort (orders handles them); we just need the hazard bridged
        var _dir = (_p == 0) ? 1 : -1;
        var _s = (_p == 0) ? 0 : 6;
        var _gate = -1;
        while (_s != _t.idx) {
            var _sp = _g.board.lanes[_t.lane].spaces[_s];
            if (_sp.kind == "hazard" && _sp.structure == undefined && _sp.hazard != "poison") {
                var _passable = false;
                for (var _c = 0; _c < array_length(_cols) && !_passable; _c++) {
                    if (game_type_can_enter(pikmin_type_get(_cols[_c]), _sp, true, false)) _passable = true;
                }
                if (!_passable) { _gate = _s; break; }
            }
            _s += _dir;
        }
        if (_gate >= 0) { _bgVal = _val; _bgLane = _t.lane; _bgIdx = _gate; }
    }
    if (_bgLane >= 0 && game_play_gather(_g, _hi, { lane: _bgLane, idx: _bgIdx, build: "bridge" })) {
        ai_dbg("v3 BRIDGE gate lane" + string(_bgLane + 1) + " idx" + string(_bgIdx) + " (opens " + string(round(_bgVal)) + "p road)");
        return true;
    }
    return false;
}

// ============================================================================
// ACHIEVEMENT MODEL (v3b orders, user-designed 2026-07-22, see cascade-orders-spec).
// Reframes orders as "get the most POINTS out of this turn": enumerate every step you
// can COMPLETE this turn that advances a pile's capture, each worth that pile's value V,
// then the knapsack (node B) spends the body+card quota to maximise Σvalue. Focus falls
// out of V - finishing one pile's chain (clear+build+advance = 3V) beats scattering.
// ============================================================================

/// REMAINING WORK to bank a pile = the tug-axis distance: obstacles I must clear/bridge on
/// my road (enemies, walls, blocking emitters, hazards my colours can't cross, intervening
/// piles) + the carry distance from the pile to my home edge. Each unit is one "step" toward
/// the bank; an action's value is V x (units it completes) / remaining-work, so the same step
/// is worth MORE on a lane closer to done (fewer units left) - that's what makes it finish
/// what it starts, softly, without a gate. Min 1 (avoid /0 at the home edge).
function ai3b_remaining_work(_g, _p, _lane, _idx) {
    var _dir = (_p == 0) ? 1 : -1;
    var _s = (_p == 0) ? 0 : 6;
    var _work = 0;
    var _cols = [];
    var _toks = _g.players[_p].tokens;
    for (var _i = 0; _i < array_length(_toks); _i++) if (!arr_has(_cols, _toks[_i].typeId)) array_push(_cols, _toks[_i].typeId);
    while (_s != _idx) {
        var _sp = _g.board.lanes[_lane].spaces[_s];
        if (_sp.enemy != undefined) _work += 1;
        else if (_sp.structure != undefined) {
            var _sd = hazard_def_get(_sp.structure.structId);
            if (_sd.type == "wall") _work += 1;
            else if (_sd.type != "bridge" && !ai_emitter_passable(_g, _p, _sd)) _work += 1;
        } else if (_sp.kind == "hazard" && _sp.hazard != "" && _sp.hazard != "poison") {
            var _cross = false;
            for (var _c = 0; _c < array_length(_cols) && !_cross; _c++)
                if (game_type_can_enter(pikmin_type_get(_cols[_c]), _sp, true, false)) _cross = true;
            if (!_cross) _work += 1;
        }
        if (game_treasure_at(_g, _lane, _s) != undefined) _work += 1;
        _s += _dir;
    }
    var _carry = (_p == 0) ? (_idx + 1) : (7 - _idx);
    return max(1, _work + _carry);
}

/// NODE 1 (tug-axis value) - achievement enumeration. Each entry: { type, lane, idx, value,
/// bodies, color, cards }. Value = pile V x (units this action completes / remaining work),
/// on WILL-DIE / WILL-MOVE outcomes (not attempts):
///   build   - removes 1 obstacle-unit               -> V/W
///   clear   - an enemy that WILL die (I reach its kill req) -> V/W;
///   chip    - an enemy I can only damage, not kill    -> 20 flat (permanent-HP progress)
///   advance - the pile MOVES `spaces` toward my home  -> V*spaces/W (0 if a tie moves it none)
///   bank    - the move reaches home                    -> V*spaces/W + V (completion bonus, ~2V)
/// A DEEP pile has large W, so a 1-space drag is a tiny fraction - the optimizer prefers
/// near-home progress with no gate (that's how the idx5-tug dies). color "any" = ai_send picks
/// bodies; "hurt" = a colour that can damage the blocker.
function ai3b_achievements(_g, _p) {
    var _opp = 1 - _p;
    var _out = [];
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
        var _V = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        if (_V <= 0) continue;
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
        var _oppS = game_strength_at(_g, _opp, _t.lane, _t.idx);
        var _W = ai3b_remaining_work(_g, _p, _t.lane, _t.idx);   // tug-axis distance (min 1)

        // cheapest crewable method (roster-aware) - its builds are the bridges I actually need
        var _myCols = [];
        var _mt = _g.players[_p].tokens;
        for (var _k = 0; _k < array_length(_mt); _k++) if (!arr_has(_myCols, _mt[_k].typeId)) array_push(_myCols, _mt[_k].typeId);
        var _methods = ai3_access_methods(_g, _p, _t.lane, _t.idx);
        var _m = undefined, _mCost = 999999;
        for (var _mi = 0; _mi < array_length(_methods); _mi++) {
            if (!_methods[_mi].canCarry || !arr_has(_myCols, _methods[_mi].color)) continue;
            var _c = _methods[_mi].cardCost + _methods[_mi].turns;
            if (_c < _mCost) { _mCost = _c; _m = _methods[_mi]; }
        }

        // BUILD: each needed bridge removes 1 obstacle-unit -> V/W
        if (_m != undefined)
            for (var _bi = 0; _bi < array_length(_m.builds); _bi++)
                array_push(_out, { type: "build", lane: _t.lane, idx: _m.builds[_bi].idx, value: _V / _W, bodies: 0, color: "", cards: _m.builds[_bi].cost, build: _m.builds[_bi].via });

        // ADVANCE / BANK on the tug axis, WITH THE LOCK RULE + the CHAIN RULE (user). Two disciplines:
        //  - LOCK: a contested move the opponent can immediately re-contest scores NOTHING; the tug
        //    fraction only counts if the move is LOCKED (overcommit past their lane reserve, or a
        //    cheaper item-lock: freeze / wall / spicy-snipe). BANK is locked by completion.
        //  - CHAIN: an enemy blocker RESPAWNS+REGENS each day (scrGame day-respawn), and a live
        //    enemy makes the pile an illegal destination (game_dest_legal), so CLEARING it is worth
        //    points ONLY when the same PLAN also controls+carries the pile - a bare clear just gets
        //    undone tomorrow (that was the grind that never banked). So the supply-clear is folded
        //    INTO the advance/bank as extra body cost; a bare clear is not an achievement. BRIDGES
        //    are durable, so BUILD stays independent above.
        var _blk = ai_first_blocker(_g, _p, _t.lane, _t.idx);
        var _clearReq = 0, _clearIdx = -1, _blocked = false;
        if (_blk != undefined) {
            if (_blk.kind == "enemy") {
                var _eDef = enemy_def_get(_blk.enemy.enemyDefId);
                if (ai_can_group_hurt(_g, _p, _eDef)) {
                    var _creq = ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp);
                    var _ereach = ai_send(_g, _p, _t.lane, _blk.idx, 99, _eDef, true);
                    if (_ereach >= _creq) { _clearReq = _creq; _clearIdx = _blk.idx; } // survivors pour on to the pile
                    else _blocked = true;                       // can't open supply this turn -> no durable progress
                } else _blocked = true;                          // un-hurtable blocker -> dead lane for me
            } else _blocked = true;                              // hazard/wall -> a durable BUILD opens it, not a clear
        }
        if (!_blocked) {
            var _hasSpicy = arr_has(_g.players[_p].hand, "spicyspray");
            var _oppLaneStr = 0;
            var _otoks = _g.players[_opp].tokens;
            for (var _oi = 0; _oi < array_length(_otoks); _oi++)
                if (_otoks[_oi].loc.kind == "space" && _otoks[_oi].loc.lane == _t.lane) _oppLaneStr += pikmin_type_get(_otoks[_oi].typeId).carry;
            // bodies that end up on the pile: those already there + whatever pours past the cleared blocker.
            // Survivors only reach the pile if the cleared enemy was the LAST obstacle before it - a 2nd
            // blocker still stops them this turn (that lane needs another turn's clear first).
            var _pour = (_clearIdx >= 0)
                ? max(0, ai_send(_g, _p, _t.lane, _clearIdx, 99, undefined, true) - _clearReq)
                : ai_send(_g, _p, _t.lane, _t.idx, 99, undefined, true);
            if (_clearIdx >= 0) {
                var _lo2 = min(_clearIdx, _t.idx) + 1, _hi2 = max(_clearIdx, _t.idx) - 1;   // bounded, in-range 0..6
                for (var _s2 = _lo2; _s2 <= _hi2; _s2++)
                    if (_g.board.lanes[_t.lane].spaces[_s2].enemy != undefined) { _pour = 0; break; }
            }
            var _reach = _myS + _pour;
            var _carry = (_p == 0) ? (_t.idx + 1) : (7 - _t.idx);
            var _perTurn = (global.expRules.rush && _w <= 6) ? 2 : 1;
            var _carryNow = _perTurn * (_hasSpicy ? 2 : 1);
            // TWO LOCK THRESHOLDS (the fix for the mutual death-grip on a contested pile):
            //  - SNIPE (banks THIS turn): the opponent can't respond before it lands, so I only need to
            //    out-bid their CURRENT in-lane strength (oppLaneStr+1), cheaper with an item/wall lock.
            //  - HOLD (multi-turn advance): the opponent re-contests over the turns it takes, reinforcing
            //    from home - so to actually lock it I must out-bid their TOTAL reach (in-lane + the home
            //    reserve that can path to the pile). A pile the opponent can flood is NOT lockable for a
            //    haul; this diverts me to piles they can't reinforce (committed elsewhere / blocked road)
            //    instead of dumping my army into a tug I lose. Item locks are one-turn, so snipe-only.
            var _oppReach = _oppLaneStr + ai_send(_g, _opp, _t.lane, _t.idx, 99, undefined, true);
            var _itemLocks = false, _wallLocks = false;
            if (_oppLaneStr > 0) {
                var _fc = ["bitterspray", "icebomb", "storm"];
                for (var _fi = 0; _fi < array_length(_fc) && !_itemLocks; _fi++) {
                    if (!arr_has(_g.players[_p].hand, _fc[_fi])) continue;
                    var _fa = ai3_card_play_args(_g, _p, _fc[_fi]);
                    if (_fa != undefined && _fa.lane == _t.lane && _fa.idx == _t.idx) _itemLocks = true;
                }
                if (!_itemLocks && arr_has(_g.players[_p].hand, "phosbatpod")) {
                    var _wt = ai3_wall_target(_g, _p);
                    if (_wt != undefined && _wt.lane == _t.lane && (_wt.idx - ((_p == 0) ? 1 : -1)) == _t.idx) _wallLocks = true;
                }
            }
            var _snipeNeed = _w;                                             // lock-before-response = beat their in-lane
            if (_oppLaneStr > 0) {
                if (_itemLocks) _snipeNeed = _w;                            // frozen -> just lift
                else if (_wallLocks) _snipeNeed = max(_w, _oppS + 1);       // walled -> beat the current stack only
                else _snipeNeed = max(_w, _oppLaneStr + 1);                // beat the whole in-lane presence
            }
            // a WALL is DURABLE (unlike a one-turn freeze), so it cuts the reinforcement for the HOLD too:
            // the opponent can only contest with the current stack behind it.
            var _holdNeed = _wallLocks ? max(_w, _oppS + 1) : max(_w, _oppReach + 1);   // lock-across-turns

            // FINISH-IN-TIME: a multi-turn haul only realizes value if it BANKS before the game ends.
            var _tFinish = ai3_road_turns(_g, _p, _t.lane, _t.idx) + ai2_turns_to_bank(_g, _p, _t.idx, _w, _hasSpicy);
            if (_myS >= _holdNeed) _tFinish -= 1;                            // already controlling -> take-control turn paid
            var _inTime = (_tFinish <= ai2_my_turns_left(_g));

            if (_carry <= _carryNow && _reach >= _snipeNeed) {              // SNIPE / BANK: grab + carry home in one turn
                // LEVER 1: bank = fraction + 2V (realized-V + deny-their-potential-V + frees-my-army-V).
                // A live blocker on the carry path must die too (_clearReq folded into bodies).
                array_push(_out, { type: "bank", lane: _t.lane, idx: _t.idx, value: _V * min(_carryNow, _carry) / _W + 2 * _V, bodies: _clearReq + max(0, _snipeNeed - _myS), color: "any", cards: 0, clearIdx: _clearIdx, clearReq: _clearReq });
            } else if (_reach >= _holdNeed && _inTime) {                     // HOLD: multi-turn haul on a pile they can't flood
                array_push(_out, { type: "advance", lane: _t.lane, idx: _t.idx, value: _V * min(_carryNow, _carry) / _W, bodies: _clearReq + max(0, _holdNeed - _myS), color: "any", cards: 0, clearIdx: _clearIdx, clearReq: _clearReq });
            }
        }
    }
    return _out;
}

/// DENY value on the tug axis: what stopping the opponent's carry on a pile for a turn is
/// worth = their pile value x the spaces of their motion I prevent, over THEIR remaining axis
/// (obstacles+carry to their home). Near their home (small remaining axis) this is large -
/// stopping an imminent bank prevents their completion. 0 if they don't control it (no carry
/// to stop). This is the SAME currency as a pikmin advance, just measured on their motion.
function ai3b_deny_value(_g, _p, _t) {
    var _opp = 1 - _p;
    var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
    if (game_strength_at(_g, _opp, _t.lane, _t.idx) < _w) return 0;      // they don't control it
    var _oppV = max(ai_pile_marginal(_g, _opp, _t), ai_pile_raw(_t) * 0.3);
    var _oppWork = ai3b_remaining_work(_g, _opp, _t.lane, _t.idx);
    var _oppPerTurn = (global.expRules.rush && _w <= 6) ? 2 : 1;
    var _oppCarry = (_opp == 0) ? (_t.idx + 1) : (7 - _t.idx);
    return _oppV * min(_oppPerTurn, _oppCarry) / max(1, _oppWork);
}

/// NODE 2 - ITEM achievements: each held card's best play, valued on the SAME tug axis as
/// pikmin actions, so ONE optimizer spends pikmin AND items toward one score. Items cost
/// their card, not bodies (bodies 0), so they don't compete with pikmin-advances - that's
/// how "use items for deny" falls out. Reuses the built targeting (ai3_card_play_args /
/// ai3_wall_target) as the target picker; the value is the tug-axis motion it causes/prevents.
/// { type:"item", play:<cardId>, lane, idx, value, bodies:0, cards:0, args }.
function ai3b_item_achievements(_g, _p) {
    var _hand = _g.players[_p].hand;
    var _out = [];
    // FREEZE (bitter / ice / storm): stop an opponent carry (or convert/defuse -> chip floor)
    var _fc = ["bitterspray", "icebomb", "storm"];
    for (var _fi = 0; _fi < array_length(_fc); _fi++) {
        if (!arr_has(_hand, _fc[_fi])) continue;
        var _args = ai3_card_play_args(_g, _p, _fc[_fi]);               // the built targeting picks the play
        if (_args == undefined) continue;
        var _t = game_treasure_at(_g, _args.lane, _args.idx);
        var _val = (_t != undefined) ? ai3b_deny_value(_g, _p, _t) : 0;
        if (_val < 20) _val = 20;                                       // a play the targeting chose is worth at least the chip floor
        array_push(_out, { type: "item", play: _fc[_fi], lane: _args.lane, idx: _args.idx, value: _val, bodies: 0, cards: 0, args: _args });
    }
    // WALL (phosbat): trap an opponent pile -> denies its whole bank (their remaining axis)
    if (arr_has(_hand, "phosbatpod")) {
        var _wt = ai3_wall_target(_g, _p);
        if (_wt != undefined) {
            var _pileIdx = _wt.idx - ((_p == 0) ? 1 : -1);              // the pile the wall sits behind
            var _pt = game_treasure_at(_g, _wt.lane, _pileIdx);
            var _val = 20;
            if (_pt != undefined) _val = max(ai3b_deny_value(_g, _p, _pt), max(ai_pile_marginal(_g, 1 - _p, _pt), ai_pile_raw(_pt) * 0.3) * 0.5);
            array_push(_out, { type: "item", play: "phosbatpod", lane: _wt.lane, idx: _wt.idx, value: _val, bodies: 0, cards: 0, args: { lane: _wt.lane, idx: _wt.idx } });
        }
    }
    return _out;
}

/// NODE B - the EXACT OPTIMIZER (replaces greedy, user 2026-07-22: "take out the greedy
/// calculus... it needs to optimize the value"). "Do as many high-value actions as you
/// can, simultaneously." Body-actions (clear/advance/bank) cost only bodies; card-actions
/// (build) cost only rawmaterial - DISJOINT resources - so it's two independent 0/1
/// knapsacks, each finding the max-value subset within its budget. No mutual exclusions
/// remain (min-contest dropped -> at most one advance/bank per pile). Colour/reach is
/// still enforced at execution (ai_send skips what it can't crew).
function ai3b_optimize(_achs, _bodyBudget, _cardBudget) {
    var _body = [], _card = [];
    for (var _i = 0; _i < array_length(_achs); _i++) {
        if (_achs[_i].cards > 0) array_push(_card, _achs[_i]); else array_push(_body, _achs[_i]);
    }
    var _chosen = ai3b_knapsack(_body, _bodyBudget, "bodies");
    var _cc = ai3b_knapsack(_card, _cardBudget, "cards");
    for (var _i = 0; _i < array_length(_cc); _i++) array_push(_chosen, _cc[_i]);
    return _chosen;
}

/// 0/1 knapsack: the max-value subset of _items within _cap of the _costKey resource
/// (exact DP). Zero-cost items (a free bank/advance already controlled) are always taken.
function ai3b_knapsack(_items, _cap, _costKey) {
    var _n = array_length(_items);
    var _cap0 = max(0, _cap);
    var _dp = array_create(_cap0 + 1, 0);
    var _keep = array_create(_n);
    for (var _i = 0; _i < _n; _i++) {
        _keep[_i] = array_create(_cap0 + 1, false);
        var _cost = _items[_i][$ _costKey];
        var _val = _items[_i].value;
        if (_cost <= 0) {                                            // free: always taken (a constant offset)
            for (var _b = 0; _b <= _cap0; _b++) { _dp[_b] += _val; _keep[_i][_b] = true; }
            continue;
        }
        for (var _b = _cap0; _b >= _cost; _b--) {
            if (_dp[_b - _cost] + _val > _dp[_b]) { _dp[_b] = _dp[_b - _cost] + _val; _keep[_i][_b] = true; }
        }
    }
    var _chosen = [];
    var _rem = _cap0;
    for (var _i = _n - 1; _i >= 0; _i--) {
        if (_keep[_i][_rem]) {
            array_push(_chosen, _items[_i]);
            var _cost = _items[_i][$ _costKey];
            if (_cost > 0) _rem -= _cost;
        }
    }
    return _chosen;
}

/// v3's economy preamble as a shared helper (redeem pellets demand-driven, play posy,
/// position-preserving recall). v3b reuses it; cascade keeps its own inline copy untouched
/// (it's the tournament baseline - don't risk it). Mutates _g in place.
function ai3_economy_preamble(_g, _p) {
    var _pl = _g.players[_p];
    if (game_capped_count(_g, _p) >= global.rules.pikminBoardCap
        && array_length(_pl.pellets) > 0 && !arr_has(_pl.hand, "ivoryandviolet")) ai_cull_deadweight(_g, _p);
    var _demand = ai3_growth_demand(_g, _p);
    var _guard = 0;
    while (array_length(_pl.pellets) > 0 && game_capped_count(_g, _p) < global.rules.pikminBoardCap && _guard < 40) {
        _guard += 1;
        var _own = pellet_def_get(_pl.pellets[0]).color;
        var _col;
        if (arr_has(_g.boardDef.basicColors, _own) && ai3_color_reaches_target(_g, _p, _own)) _col = _own;
        else if (_demand != "") _col = _demand;
        else _col = ai2_pick_growth_color(_g, _p);
        game_play_pellet(_g, 0, _col);
    }
    var _hi = 0;
    while (_hi < array_length(_pl.hand)) {
        if (_pl.hand[_hi] == "colorchangingposy" && game_capped_count(_g, _p) <= global.rules.pikminBoardCap - 3
            && game_play_gather(_g, _hi, { color: ai2_pick_growth_color(_g, _p) })) continue;
        _hi += 1;
    }
    var _tokens = _pl.tokens;
    var _lo = (_p == 0) ? 0 : 4, _hiSide = (_p == 0) ? 2 : 6;
    for (var _i = 0; _i < array_length(_tokens); _i++) {
        var _tok = _tokens[_i], _loc = _tok.loc;
        if (_loc.kind != "space" || token_is_disabled(_tok)) continue;
        if (!game_can_reach_home(_g, _p, _tok.typeId, _loc.lane, _loc.idx)) continue;
        var _rsp = _g.board.lanes[_loc.lane].spaces[_loc.idx];
        if (_rsp.enemy != undefined || _rsp.structure != undefined || game_treasure_at(_g, _loc.lane, _loc.idx) != undefined) continue;
        if (_loc.idx >= _lo && _loc.idx <= _hiSide) _tok.loc = { kind: "home" };
    }
}

/// v3b ORDERS: preamble, then enumerate achievements, knapsack them, and commit. Body
/// budget = deployable home strength; card budget = rawmaterial count (a build costs 2).
function ai3b_orders_plan(_g) {
    var _p = _g.activePlayer;
    ai3_economy_preamble(_g, _p);
    var _achs = ai3b_achievements(_g, _p);
    var _items = ai3b_item_achievements(_g, _p);              // fold held items into the SAME optimizer
    for (var _ii = 0; _ii < array_length(_items); _ii++) array_push(_achs, _items[_ii]);
    var _bodyBudget = ai_home_strength(_g, _p);
    var _raw = 0, _hand = _g.players[_p].hand;
    for (var _i = 0; _i < array_length(_hand); _i++) if (_hand[_i] == "rawmaterial") _raw += 1;
    var _chosen = ai3b_optimize(_achs, _bodyBudget, _raw);
    ai_dbg("");
    ai_dbg("===== v3b TURN P" + string(_p + 1) + "  Day " + string(_g.dayNumber) + " (" + string(_g.dayTrack) + "/" + string(global.rules.dayTrackLength)
        + ")  score " + string(game_realized_score(_g, _p)) + " vs " + string(game_realized_score(_g, 1 - _p))
        + "  budget=" + string(_bodyBudget) + "  chose " + string(array_length(_chosen)) + "/" + string(array_length(_achs)) + " =====");
    for (var _i = 0; _i < array_length(_chosen); _i++) {
        var _a = _chosen[_i];
        ai_dbg("v3b " + _a.type + " lane" + string(_a.lane + 1) + " idx" + string(_a.idx) + " val" + string(round(_a.value)) + " bodies" + string(_a.bodies));
    }
    return { chosen: _chosen, idx: 0 };
}

/// Paced driver: one committed achievement per tick, then leftover -> chip-grind + done.
function ai3b_orders(_g) {
    if (!variable_struct_exists(_g, "ai3bPlan") || _g.ai3bPlan == undefined) {
        _g.ai3bPlan = ai3b_orders_plan(_g);
        return;
    }
    var _plan = _g.ai3bPlan;
    while (_plan.idx < array_length(_plan.chosen)) {
        var _a = _plan.chosen[_plan.idx];
        _plan.idx += 1;
        if (ai3b_execute(_g, _g.activePlayer, _a)) return;   // one visible commit per tick
    }
    ai3_orders_finish(_g, { cands: [] });                    // empty cands -> just the chip-grind + orders done
    _g.ai3bPlan = undefined;
}

/// Execute one chosen achievement: build a structure, or send bodies to a clear/carry.
/// A 0-body bank/advance (already controlling) needs no deploy - the move phase carries it.
function ai3b_execute(_g, _p, _a) {
    switch (_a.type) {
        case "build":
            for (var _hi = 0; _hi < array_length(_g.players[_p].hand); _hi++)
                if (_g.players[_p].hand[_hi] == "rawmaterial")
                    return game_play_gather(_g, _hi, { lane: _a.lane, idx: _a.idx, build: _a.build });
            return false;
        case "advance": case "bank":
            var _did = false;
            // CHAIN: open the supply blocker first (a live enemy makes the pile an illegal destination;
            // it respawns each day, so it's only worth clearing paired with this carry). The control
            // bodies land once the enemy resolves - next turn's replan sees the open lane and carries.
            var _cReq = variable_struct_exists(_a, "clearReq") ? _a.clearReq : 0;
            if (variable_struct_exists(_a, "clearIdx") && _a.clearIdx >= 0 && _cReq > 0) {
                var _esp = _g.board.lanes[_a.lane].spaces[_a.clearIdx];
                if (_esp.enemy != undefined)
                    _did = ai_send(_g, _p, _a.lane, _a.clearIdx, _cReq, enemy_def_get(_esp.enemy.enemyDefId)) > 0;
            }
            var _ctrl = _a.bodies - _cReq;                    // bodies to control/carry the pile itself
            if (_ctrl > 0) _did = (ai_send(_g, _p, _a.lane, _a.idx, _ctrl, undefined) > 0) || _did;
            return _did;                                      // 0-body, already-controlling move carries on its own
    }
    return false;
}

/// The v3b BRAIN: v3's gather + move (card play), with the achievement-model orders.
function ai3b_step(_g) {
    global.aiDbgP = _g.activePlayer;
    switch (_g.phase) {
        case "gather": ai3_gather(_g); break;
        case "orders": ai3b_orders(_g); break;
        case "move":   ai3_move(_g);   break;
    }
}

// ============================================================================
// CARD PLAY (move phase) - the v3 play layer, built card-by-card. Each ai3_play_*
// returns the game_play_gather ARGS for the best play of that card right now, or
// undefined for "don't play it". ai3_card_play_args dispatches; ai3_try_play_cards
// drives. Cards not yet ported return undefined and fall through to v2's ai_try_card.
// ============================================================================

/// SPICY SPRAY {lane,idx}: an extra carry action (2 spaces) for the pikmin on a
/// space. Play it on the most valuable pile I already CONTROL (my strength >= weight
/// and > the opponent's) that isn't about to bank on its own (dist >= 2, else the
/// spray is wasted). This is what completes a SNIPE (a controlled centre pile the
/// spray carries the rest of the way home) and accelerates any heavy haul.
function ai3_play_spicy(_g, _p) {
    var _best = undefined, _bestVal = -1;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
        if (_myS < _w || _myS <= game_strength_at(_g, 1 - _p, _t.lane, _t.idx)) continue; // must control the carry
        var _dist = (_p == 0) ? (_t.idx + 1) : (7 - _t.idx);
        if (_dist < 2) continue;                                    // banks on its own - don't waste the spray
        var _val = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        if (_val > _bestVal) { _bestVal = _val; _best = { lane: _t.lane, idx: _t.idx }; }
    }
    return _best;
}

/// A stun-deny/convert is worth playing a card for only if it swings at least this much
/// pile value (marginal points). Below it, hold the card.
#macro STUN_DENY_MIN 8

/// BITTER as a DENY/CONVERT tool. Bitter freezes the opponent's tokens on a space but
/// SPARES your own (the one stun that does), so it can freeze a group sharing a pile
/// with you. Frozen pikmin are skipped by game_strength_at, so their carry reads 0 for
/// the resolution. Two uses, scored by pile value:
///   CONVERT - a pile I have the carry weight on (myS >= w) but can't take because the
///             opponent out-contests me (oppS >= myS): freeze flips control to me and I
///             carry/advance it this turn.
///   DENY    - a pile the opponent controls and is about to carry home (oppS >= w) that
///             I can't out-body: freeze stalls the carry a turn (weighted by how close
///             it is to THEIR bank - near-home carries hurt most).
/// Returns the best {lane, idx, val} or undefined. Bitter is single-space and the
/// contesting/carrying group sits on the pile's own space, so that's the target.
function ai3_bitter_pikmin_target(_g, _p) {
    var _best = undefined, _bestVal = -1;
    var _opp = 1 - _p;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
        var _oppS = game_strength_at(_g, _opp, _t.lane, _t.idx);
        if (_oppS <= 0) continue;                                   // nothing of theirs to freeze
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
        var _w   = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _val = -1;
        if (_myS >= _w && _oppS >= _myS) {                          // CONVERT: I have the weight, they out-contest me
            _val = max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3);
        } else if (_oppS >= _w && _oppS > _myS) {                   // DENY: they're carrying it and I can't out-body them
            var _oppDist = (_opp == 0) ? (_t.idx + 1) : (7 - _t.idx); // spaces to the opponent's home
            var _imm = clamp((7 - _oppDist) / 7, 0.3, 1.0);
            _val = max(ai_pile_marginal(_g, _opp, _t), ai_pile_raw(_t) * 0.3) * _imm * 0.8;
        }
        if (_val > _bestVal) { _bestVal = _val; _best = { lane: _t.lane, idx: _t.idx, val: _val }; }
    }
    return _best;
}

/// BITTER SPRAY {lane,idx}. Prefer a strong pikmin convert/deny (a points swing); else
/// defuse a threatening explosive (protects deployed bodies); else fall through to v2's
/// ai_try_card for bitter's other uses.
function ai3_play_bitter(_g, _p) {
    var _pk  = ai3_bitter_pikmin_target(_g, _p);
    if (_pk != undefined && _pk.val >= STUN_DENY_MIN) return { lane: _pk.lane, idx: _pk.idx };
    var _exp = ai3_explosive_to_defuse(_g, _p);
    if (_exp != undefined) return _exp;
    if (_pk != undefined) return { lane: _pk.lane, idx: _pk.idx };
    return undefined;
}

/// ICE/STORM as a DENY tool: freeze is INDISCRIMINATE (hits my own pikmin too), so it
/// can only stall an opposing carry on a pile where I have NO pikmin in the footprint.
/// Finds the highest-value size×size footprint covering a pile the opponent controls
/// (oppS >= w, out-bodying me) that holds none of my pikmin. Returns {lane,idx,val}.
function ai3_freeze_deny_target(_g, _p, _size) {
    var _best = undefined, _bestVal = -1;
    var _opp = 1 - _p;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
        var _oppS = game_strength_at(_g, _opp, _t.lane, _t.idx);
        var _w    = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        if (_oppS < _w) continue;                                              // they don't control -> nothing to stall
        if (_oppS <= game_strength_at(_g, _p, _t.lane, _t.idx)) continue;      // I already out-contest with bodies
        for (var _dl = -(_size - 1); _dl <= 0; _dl++) {
            for (var _di = -(_size - 1); _di <= 0; _di++) {
                var _l0 = clamp(_t.lane + _dl, 0, _g.board.laneCount - _size);
                var _i0 = clamp(_t.idx + _di, 0, 7 - _size);
                if (!(_t.lane >= _l0 && _t.lane <= _l0 + _size - 1 && _t.idx >= _i0 && _t.idx <= _i0 + _size - 1)) continue;
                var _safe = true;
                for (var _a = 0; _a < _size && _safe; _a++)
                    for (var _b = 0; _b < _size; _b++)
                        if (game_strength_at(_g, _p, _l0 + _a, _i0 + _b) > 0) { _safe = false; break; } // would freeze my own
                if (_safe) {
                    var _oppDist = (_opp == 0) ? (_t.idx + 1) : (7 - _t.idx);
                    var _imm = clamp((7 - _oppDist) / 7, 0.3, 1.0);
                    var _val = max(ai_pile_marginal(_g, _opp, _t), ai_pile_raw(_t) * 0.3) * _imm;
                    if (_val > _bestVal) { _bestVal = _val; _best = { lane: _l0, idx: _i0, val: _val }; }
                }
            }
        }
    }
    return _best;
}

/// ICE BOMB (size 1) / LIGHTNING STORM (size 2, 2x2). First DEFUSE a threatening
/// explosive via a size×size footprint that covers it and holds none of my own pikmin
/// (user: "as you don't have pikmin on ITS space"); if there's nothing to defuse, use
/// the freeze to DENY an opposing carry (same no-friendly-in-footprint rule).
function ai3_play_freeze(_g, _p, _size) {
    var _exp = ai3_explosive_to_defuse(_g, _p);
    if (_exp != undefined) {
        for (var _dl = -(_size - 1); _dl <= 0; _dl++) {
            for (var _di = -(_size - 1); _di <= 0; _di++) {
                var _l0 = clamp(_exp.lane + _dl, 0, _g.board.laneCount - _size);
                var _i0 = clamp(_exp.idx + _di, 0, 7 - _size);
                if (!(_exp.lane >= _l0 && _exp.lane <= _l0 + _size - 1 && _exp.idx >= _i0 && _exp.idx <= _i0 + _size - 1)) continue; // must cover the explosive
                var _safe = true;
                for (var _a = 0; _a < _size && _safe; _a++)
                    for (var _b = 0; _b < _size; _b++)
                        if (game_strength_at(_g, _p, _l0 + _a, _i0 + _b) > 0) { _safe = false; break; } // freeze would hit my own
                if (_safe) return { lane: _l0, idx: _i0 };
            }
        }
    }
    var _deny = ai3_freeze_deny_target(_g, _p, _size);
    if (_deny != undefined && _deny.val >= STUN_DENY_MIN) return { lane: _deny.lane, idx: _deny.idx };
    return undefined;
}
function ai3_play_ice(_g, _p)   { return ai3_play_freeze(_g, _p, 1); }
function ai3_play_storm(_g, _p) { return ai3_play_freeze(_g, _p, 2); }

/// WALL-OFF (v1: PHOSBAT POD only - the guaranteed enemy wall). Cut the opponent's
/// supply/extraction on a contested pile: spawn an enemy on the space BETWEEN the pile
/// and the OPPONENT's home edge (their side), so their pikmin already on the pile can't
/// carry it home and their reserves can't reinforce. The block space is on the opponent's
/// side, so it never obstructs MY own carry (opposite direction). NO pile-value floor -
/// a guaranteed pull is worth it at ANY weight; the wall's whole point is you win by the
/// MINIMUM (beat their now-TRAPPED stack + 1) instead of over-contesting to beat a re-stack.
/// Fires when either:
///   WIN  - my current + still-reachable strength can hit max(weight, trappedStack+1),
///          i.e. once they can't reinforce, I can out-number and carry it this run.
///   DENY - they already control it (would bank) and I can't take it -> wall stops the carry.
/// Returns phosbat args {lane,idx} for the best such pile, or undefined. Needs an EMPTY
/// enemy-slot at the block space + enemies to spawn. (rockstorm/warp/element-pick = follow-ups.)
function ai3_wall_target(_g, _p) {
    if (!arr_has(_g.players[_p].hand, "phosbatpod")) return undefined;
    if (array_length(_g.decks.enemy) + array_length(_g.decks.enemyDiscard) == 0) return undefined; // nothing to spawn
    var _opp = 1 - _p;
    var _blockDir = (_p == 0) ? 1 : -1;                       // toward the opponent's home = away from mine
    var _best = undefined, _bestVal = -1;
    for (var _ti = 0; _ti < array_length(_g.treasures); _ti++) {
        var _t = _g.treasures[_ti];
        if (array_length(_t.cards) == 0 || _t.boss != undefined) continue;
        var _oppS = game_strength_at(_g, _opp, _t.lane, _t.idx);
        if (_oppS <= 0) continue;                             // no opposing stack to trap / cut off
        // closest EMPTY enemy-slot between the pile and the opponent's home. Walling as
        // close to the pile as possible stops them advancing the treasure toward their
        // home before the wall bites. (Slots are mirrored, so an opp-side slot usually
        // exists even when it isn't pile-adjacent - scan, don't just check idx+1.)
        var _blockIdx = -1;
        var _bs = _t.idx + _blockDir;
        while (_bs >= 0 && _bs <= 6) {
            var _cand = _g.board.lanes[_t.lane].spaces[_bs];
            if (_cand.kind == "enemy" && _cand.enemy == undefined && _cand.structure == undefined
                && game_treasure_at(_g, _t.lane, _bs) == undefined) { _blockIdx = _bs; break; }
            _bs += _blockDir;
        }
        if (_blockIdx < 0) continue;                          // no wallable slot on their side of this pile
        var _w = treasure_def_get(_t.cards[array_length(_t.cards) - 1]).weight;
        var _myS = game_strength_at(_g, _p, _t.lane, _t.idx);
        var _myPot = _myS + ai_send(_g, _p, _t.lane, _t.idx, 99, undefined, true); // + still-reachable this turn
        var _canWin = (_myPot >= max(_w, _oppS + 1));         // beat their TRAPPED stack + make weight
        var _deny   = (!_canWin) && (_oppS >= _w);            // they'd bank it, I can't take it -> stop the carry
        if (!_canWin && !_deny) continue;
        var _val = _canWin ? max(ai_pile_marginal(_g, _p, _t), ai_pile_raw(_t) * 0.3)
                           : max(ai_pile_marginal(_g, _opp, _t), ai_pile_raw(_t) * 0.3);
        if (_canWin) _val *= 1.2;                             // winning a pile beats merely denying one
        if (_val > _bestVal) { _bestVal = _val; _best = { lane: _t.lane, idx: _blockIdx }; }
    }
    return _best;
}
function ai3_play_block(_g, _p) { return ai3_wall_target(_g, _p); }

/// Dispatch a card to its v3 play-args finder. undefined = not v3-ported (or no good
/// play now) -> the caller falls through to v2's ai_try_card.
function ai3_card_play_args(_g, _p, _cardId) {
    switch (_cardId) {
        case "spicyspray":  return ai3_play_spicy(_g, _p);
        case "bitterspray": return ai3_play_bitter(_g, _p);
        case "icebomb":     return ai3_play_ice(_g, _p);
        case "storm":       return ai3_play_storm(_g, _p);
        case "phosbatpod":  return ai3_play_block(_g, _p);
        default: return undefined;
    }
}

/// Try to play one v3-ported card from hand (the first with a valid play). Returns
/// true if it played something.
function ai3_try_play_cards(_g, _p) {
    var _hand = _g.players[_p].hand;
    for (var _hi = 0; _hi < array_length(_hand); _hi++) {
        var _cardId = _hand[_hi];
        var _args = ai3_card_play_args(_g, _p, _cardId);
        if (_args != undefined && game_play_gather(_g, _hi, _args)) {
            ai_dbg("v3 PLAY " + _cardId + " @ lane" + string(_args.lane + 1) + " idx" + string(_args.idx)); // visible in probes
            return true;
        }
    }
    return false;
}

/// Move phase: chain-candypop, then v3-ported card plays, then cascade bridge, then
/// v2's remaining situational plays (cards not yet ported), then resolve.
function ai3_move(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    ai2_try_chain_candypop(_g, _p);
    var _passes = 0;
    while (_passes < 12) {
        _passes += 1;
        if (_g.activePlayer != _p) return; // a card ended the turn
        var _played = ai3_try_play_cards(_g, _p);      // v3-ported plays first
        if (!_played) _played = ai3_try_bridge(_g, _p);
        if (!_played) {
            for (var _hi2 = 0; _hi2 < array_length(_pl.hand); _hi2++) {
                if (ai_try_card(_g, _p, _hi2)) { _played = true; break; } // v2 fallback for un-ported cards
            }
        }
        if (!_played) break;
    }
    if (_g.activePlayer != _p) return;
    game_resolve_moves(_g);
}

function ai3_place_free_hazard(_g) {
    ai2_place_free_hazard(_g);
}
