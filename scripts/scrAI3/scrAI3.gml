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
    // geometric gates also yield to a structure (bridge/climbing stick)
    if ((_hazard == "chasm" || _hazard == "height" || _hazard == "water") && ai3_board_has_gather(_g, "rawmaterial")) return "card";
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
                if ((_sp.hazard == "chasm" || _sp.hazard == "water" || _sp.hazard == "height") && ai3_board_has_gather(_g, "rawmaterial")) _turns += 1; // bridge / climbing stick
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
    var _guard = 0;
    while (array_length(_pl.pellets) > 0 && game_capped_count(_g, _p) < global.rules.pikminBoardCap && _guard < 40) {
        _guard += 1;
        var _pDef = pellet_def_get(_pl.pellets[0]);
        var _col = arr_has(_g.boardDef.basicColors, _pDef.color) ? _pDef.color : ai2_pick_growth_color(_g, _p);
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

    // --- main-lane pick + breadth/depth decision (milestone 3) ---
    var _main = ai3_main_lane(_g, _p);
    var _reachN = 0;
    for (var _rti = 0; _rti < array_length(_g.treasures); _rti++) {
        var _rt = _g.treasures[_rti];
        if (array_length(_rt.cards) > 0 && ai3_access_cost(_g, _p, _rt.lane, _rt.idx, _hasSpicy) < ACCESS_INF) _reachN += 1;
    }
    var _depth = (_reachN <= 1); // one reachable pile -> pour in; else spread thin
    var _targets = ai3_target_piles(_g, _p, BREADTH_CAP); // contest at most 3 piles
    var _tgtStr = "";
    for (var _tsi = 0; _tsi < array_length(_targets); _tsi++) _tgtStr += (_tsi > 0 ? "," : "") + string(_targets[_tsi].lane + 1);
    ai_dbg("v3 main-lane " + string(_main.lane + 1) + " (score " + string(round(_main.score)) + ")  reachable piles "
        + string(_reachN) + " -> " + (_depth ? "DEPTH" : "BREADTH") + "  targets [" + _tgtStr + "]");

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

        // ---- BREADTH CAP: only pursue the top-3 reachable piles this turn (a
        // DENY threat already `continue`d above; this gates MY advance/prepare) ----
        var _inCap = false;
        for (var _tc = 0; _tc < array_length(_targets); _tc++)
            if (_targets[_tc].lane == _t.lane && _targets[_tc].idx == _t.idx) { _inCap = true; break; }
        if (!_inCap) { ai_dbg("v3 skip lane" + string(_t.lane + 1) + " - outside breadth cap " + string(BREADTH_CAP)); continue; }

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
            // MILESTONE-3 sizing: ai3_advance_commit owns min-win + the depth/breadth
            // over-stack (2x rush / securing buffer). DEPTH only on the ONE main lane;
            // every other reachable pile is min-contested (breadth). `presized` tells
            // ai_orders_commit NOT to re-apply its own rush overstack.
            var _useDepth = _depth && (_t.lane == _main.lane);
            var _req = ai3_advance_commit(_g, _p, _t, _useDepth);
            if (_req <= 0) {
                // already holding enough - advances free this turn, no bodies spent (the latch)
                ai_dbg("v3 holding lane" + string(_t.lane + 1) + " (myS " + string(_myS) + ") - advancing free");
                continue;
            }
            var _val = ((_canBank ? _wMe : 0) + (_oppS > 0 ? _wOpp * 0.5 : 0)) / max(1, _tBank);
            if (_t.lane == _main.lane) _val *= 3;   // MAIN-GOAL focus: tops its tier
            if (_val <= 0) continue;
            array_push(_cands, { tier: 2, kind: "pile", lane: _t.lane, idx: _t.idx, req: _req,
                value: _val, enemyDef: undefined, oppS: _oppS, myS: _myS, w: _w, presized: true,
                why: "v3 ADVANCE " + string(_raw) + "p " + (_useDepth ? "DEPTH" : "breadth") + (_canBank ? " tb" + string(_tBank) : " DENY") + (_myS > 0 ? " (holding " + string(_myS) + ")" : "") });
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
                array_push(_cands, { tier: 1, kind: "enemy", lane: _t.lane, idx: _blk.idx, req: ai_enemy_req(_g, _p, _eDef, _blk.enemy.curHp),
                    value: _prepVal / (1 + _clr), enemyDef: _eDef, oppS: 0, myS: 0,
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
                    array_push(_cands, { tier: 1, kind: "clean", lane: _laneIdx, idx: _si, req: ai_enemy_req(_g, _p, _eD2, _sp2.enemy.curHp),
                        value: (8 + ai_reward_value(_eD2) * 0.5) / (1 + _clr2), enemyDef: _eD2, oppS: 0, myS: 0,
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

/// Move phase: chain-candypop, then cascade bridge (PREPARE via card), then the
/// shared situational plays (spicy/ice/bomb/wall - v2's are well-tuned), resolve.
function ai3_move(_g) {
    var _p = _g.activePlayer;
    var _pl = _g.players[_p];
    ai2_try_chain_candypop(_g, _p);
    var _passes = 0;
    while (_passes < 12) {
        _passes += 1;
        if (_g.activePlayer != _p) return; // a card ended the turn
        var _played = ai3_try_bridge(_g, _p);
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

function ai3_place_free_hazard(_g) {
    ai2_place_free_hazard(_g);
}
