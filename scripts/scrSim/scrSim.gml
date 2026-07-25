// ============================================================================
// scrSim - headless simulation harness
//
// Runs complete games with no renderer, no pacing and no frame loop, so the
// engine can be used as a search primitive (rollouts) rather than only as a
// thing you watch. Three pieces:
//
//   game_clone(_g)                 - deep copy of a game state (the search's "undo")
//   game_playout(_g, _ctl)         - run a state to gameover, return the result
//   sim_benchmark(...) / sim_selftest(...) - is this affordable, and is it correct?
//
// The engine was already built for this: game state is pure data (ids, plain
// structs - see game_new / board_create), deterministic, and the AI seats read
// _g.activePlayer rather than any controller state. The only things standing
// between "a game" and "a rollout" are the presentation gates, which the anims
// toggle already bypasses, and the two drains the controller normally performs
// (departing piles in Draw, fx events in Draw).
//
// F3 in-game runs the selftest + benchmark on the current board (Step_0).
// ============================================================================

#macro SIM_MAX_TICKS 20000

/// AI debug logging opens/writes/closes ai_debug.txt PER LINE. That's fine when a
/// human is watching one turn; it's fatal inside a rollout loop. Everything that
/// runs headless silences it.
function sim_silence(_on) {
    global.aiSilent = _on;
}
function sim_silent_get() {
    return (variable_global_exists("aiSilent") && global.aiSilent);
}

/// Map a controller slot to a brain. A playout has no human, so human seats are
/// coerced to v1 (the caller decides if that's the right stand-in).
function sim_ctl(_ctl, _p) {
    var _c = _ctl[_p];
    return (_c == "human") ? "v1" : _c;
}

/// Display label for a policy = its brain VERSION (v1/v2/v3/v3b/v4), which is exactly its ctl
/// (defaulting to "v2"). Used in tournament output so brains read as version numbers, not nicknames -
/// and the short labels also dodge the fixed-width column merge that long ids ("cascade2") caused.
function sim_brain_label(_pol) {
    return variable_struct_exists(_pol, "ctl") ? _pol.ctl : "v2";
}

// ---------- cloning ----------

/// Deep copy a game state. The copy shares nothing mutable with the original, so
/// you can play it out and throw it away.
///
/// REFUSES mid-resolution. _g.combatFights entries hold LIVE references to the
/// board's enemy structs and to treasure structs (_fights[i].enemy / .hostT, built
/// in game_combat_step) - a deep copy would duplicate those, silently decoupling
/// the in-flight fight from the board it's supposed to be damaging. The same goes
/// for the per-phase AI scratch plans. Clone at a clean decision point (start of a
/// tick, queue empty) and this can't bite.
///
/// Returns undefined if the state isn't clonable.
function game_clone(_g) {
    if (array_length(_g.resolveQueue) > 0 || _g.combatFights != undefined) {
        show_debug_message("[SIM] game_clone REFUSED: mid-resolution (queue "
            + string(array_length(_g.resolveQueue)) + ", combatFights "
            + (_g.combatFights == undefined ? "none" : "LIVE") + ") - clone at a clean tick boundary.");
        return undefined;
    }

    // Detach everything we don't want deep-copied, clone, then put it all back.
    //   boardDef - shared immutable board data (never mutated); re-linked by reference
    //   log / fx  - junk in a rollout, and fx would just grow forever
    //   aiPlan / ai2Plan - per-phase scratch holding live candidate references
    var _boardDef = _g.boardDef;
    var _log      = _g.log;
    var _fx       = _g.fx;
    var _hasAiPlan  = variable_struct_exists(_g, "aiPlan");
    var _hasAi2Plan = variable_struct_exists(_g, "ai2Plan");
    var _aiPlan  = _hasAiPlan  ? _g.aiPlan  : undefined;
    var _ai2Plan = _hasAi2Plan ? _g.ai2Plan : undefined;

    _g.boardDef = undefined;
    _g.log = [];
    _g.fx = [];
    if (_hasAiPlan)  _g.aiPlan  = undefined;
    if (_hasAi2Plan) _g.ai2Plan = undefined;

    var _c = variable_clone(_g); // deep; preserves undefined sentinels

    _g.boardDef = _boardDef;
    _g.log = _log;
    _g.fx = _fx;
    if (_hasAiPlan)  _g.aiPlan  = _aiPlan;
    if (_hasAi2Plan) _g.ai2Plan = _ai2Plan;

    _c.boardDef = _boardDef;   // shared by reference, exactly like the original
    _c.trace = [false, false]; // a clone never writes human trace lines to disk
    return _c;
}

// ---------- playout ----------

/// One headless tick. This is objGame's Step_0 dispatch with the presentation
/// removed: no camera, no input, no day cinematic, no settle gates (anims off
/// already collapses all of those), plus the two drains the controller normally
/// does from Draw - departing piles and fx events.
function sim_tick(_g, _ctl) {
    // Day rollover: with anims off Step_0 just clears the spawn marks (they only
    // exist to stage the reveal cinematic).
    if (_g.phase != "gameover" && _g.dayNumber > _g.simPrevDay) {
        _g.simPrevDay = _g.dayNumber;
        game_clear_spawn_marks(_g);
    }

    // Staged resolution drains in one go (Step_0's anims-off branch).
    if (array_length(_g.resolveQueue) > 0) {
        while (array_length(_g.resolveQueue) > 0) game_resolve_step(_g);
        _g.fx = [];
        return;
    }

    // Departing piles: normally the Draw loop banks these (instantly with anims
    // off). Headless there is no Draw, so nothing would ever score.
    while (array_length(_g.departing) > 0) game_finalize_departing(_g, _g.departing[0]);

    if (_g.phase == "gameover") return;

    // Hand-limit overflow, then boss-bounty hazards, then the turn itself -
    // same precedence as Step_0.
    if (_g.pendingDiscard != undefined) {
        if (sim_ctl(_ctl, _g.pendingDiscard.playerIdx) == "v4") ai4_resolve_discard(_g);
        else ai_resolve_discard(_g);
        _g.fx = [];
        return;
    }
    if (array_length(_g.pendingFree) > 0) {
        var _fb = sim_ctl(_ctl, _g.pendingFree[0].playerIdx);
        if (_fb == "v3" || _fb == "v3b" || _fb == "v4") ai3_place_free_hazard(_g);
        else if (_fb == "v2") ai2_place_free_hazard(_g);
        else ai_place_free_hazard(_g);
        _g.fx = [];
        return;
    }

    var _brain = sim_ctl(_ctl, _g.activePlayer);
    if (_brain == "v3") ai3_step(_g); else if (_brain == "v3b") ai3b_step(_g); else if (_brain == "v4") ai4_step(_g); else if (_brain == "v2") ai2_step(_g); else ai_step(_g);
    _g.fx = []; // nothing drains it headless; the rules never read it
}

/// Run _g to gameover. MUTATES _g (clone first if you need it after).
/// Returns { ok, p0, p1, diff, winner, ticks } - diff is from player 0's view.
/// ok=false means it hit the tick ceiling without finishing (an AI stall).
function game_playout(_g, _ctl, _maxTicks = SIM_MAX_TICKS) {
    var _savedAnims  = global.expRules.anims;
    var _savedSilent = sim_silent_get();
    global.expRules.anims = false; // no pacing, no cinematic, instant resolution
    sim_silence(true);             // ai_dbg does file I/O per line

    _g.trace = [false, false];
    if (!variable_struct_exists(_g, "simPrevDay")) _g.simPrevDay = _g.dayNumber;

    var _ticks = 0;
    var _ok = true;
    while (_g.phase != "gameover") {
        if (_ticks >= _maxTicks) { _ok = false; break; }
        _ticks += 1;
        sim_tick(_g, _ctl);
    }
    if (_ok) game_finalize_gameover(_g); // banks piles still in flight, sets winner

    global.expRules.anims = _savedAnims;
    sim_silence(_savedSilent);

    var _s0 = game_realized_score(_g, 0);
    var _s1 = game_realized_score(_g, 1);
    return {
        ok: _ok,
        p0: _s0,
        p1: _s1,
        diff: _s0 - _s1,
        winner: _g.winner,
        ticks: _ticks,
    };
}

/// Fresh game -> played out. The rollout primitive.
function sim_play_game(_boardId, _ctl, _maxTicks = SIM_MAX_TICKS) {
    return game_playout(game_new(_boardId), _ctl, _maxTicks);
}

// ---------- benchmark ----------

function sim_report(_line) {
    show_debug_message("[SIM] " + _line);
    var _f = file_text_open_append("sim_bench.txt");
    file_text_write_string(_f, _line);
    file_text_writeln(_f);
    file_text_close(_f);
}

/// THE NUMBER: how many complete games per second can this machine run?
/// Everything downstream (flat rollout, MCTS, weight fitting) is priced off it.
function sim_benchmark(_boardId, _n = 25, _ctl = ["v2", "v2"]) {
    sim_report("=== benchmark: board " + string(_boardId) + "  " + string(_n)
        + " games  P1=" + sim_ctl(_ctl, 0) + " P2=" + sim_ctl(_ctl, 1) + " ===");

    var _t0 = get_timer();
    var _tot0 = 0, _tot1 = 0, _w0 = 0, _w1 = 0, _draw = 0, _ticks = 0, _stalls = 0;
    for (var _i = 0; _i < _n; _i++) {
        var _r = sim_play_game(_boardId, _ctl);
        if (!_r.ok) _stalls += 1;
        _tot0 += _r.p0; _tot1 += _r.p1; _ticks += _r.ticks;
        if (_r.winner == 0) _w0 += 1; else if (_r.winner == 1) _w1 += 1; else _draw += 1;
    }
    var _us = get_timer() - _t0;

    var _msPer = (_us / 1000) / _n;
    sim_report("  " + string(_n) + " games in " + string(_us / 1000000) + "s"
        + "  ->  " + string(_msPer) + " ms/game"
        + "  =  " + string(1000 / max(_msPer, 0.0001)) + " games/sec");
    sim_report("  avg score P1 " + string(_tot0 / _n) + "  P2 " + string(_tot1 / _n)
        + "   W/L/D " + string(_w0) + "/" + string(_w1) + "/" + string(_draw)
        + "   avg ticks " + string(_ticks / _n)
        + (_stalls > 0 ? "   *** " + string(_stalls) + " STALLED ***" : ""));

    // What the number buys you: a flat 1-ply rollout over ~8 candidates x N playouts.
    var _perDecision = 8 * 20;
    sim_report("  => 1-ply rollout (8 candidates x 20 playouts = " + string(_perDecision)
        + " games) would cost ~" + string(_perDecision * _msPer / 1000) + "s per decision.");
    return _msPer;
}

// ============================================================================
// POLICY TOURNAMENT
//
// The question this answers: "what long-game strategies work?" - which is a
// POLICY question, not a per-move one. Advantage-per-decision doesn't compose
// into "contest the rich lane early, concede late", so we force a whole-game
// strategy on each seat and let them fight it out.
//
// Policies are not a second brain: they hook v2's existing decision points (the
// mind's focus lane, and the gather economy) and let the rest of v2 execute. So
// a result means "v2 executing strategy X", not "a different AI".
//
// READ THE RESULT AS RELATIVE, NOT ABSOLUTE. Every number here means "wins when
// the opponent is also v2 playing one of these strategies". It is not what beats
// Zak, and it can't discover a strategy that isn't in this list.
// ============================================================================

/// The roster. Each entry: { id, kind, lane }.
///   lane1..lane5 - force the mind onto ONE lane, all game, whatever the board says.
///                  Five entries (one per lane) so "is focusing a lane meta?" and
///                  "is lane N special?" are separable questions.
///   spread2      - work the best TWO lanes at once (mind boosts both).
///   contestN     - NAIVE contest-awareness: predict the opponent's focus by
///                  running THEIR lane evaluator, discount lanes they want, re-pick.
///                  Deterministic + shared logic -> on mirrored boards its mirror
///                  match should collide one level up (the user's regress point);
///                  its diagonal tie rate is the test.
///   contestR     - REACTIVE contest-awareness: discount lanes by the opponent's
///                  OBSERVED deployed strength (bodies standing in the lane), not a
///                  prediction. Turn 1 (nothing deployed) it degenerates to base;
///                  from then on mirrors decorrelate off the actual board.
///                  Focus-selection only - neither row prices deny-vs-develop.
///   numbers      - PRESERVE THE ROSTER. Never throw pikmin at something that kills
///                  them: take only the free kills (dies-before-it-strikes, 0-damage
///                  whittle, immune chip) and refuse every branch of the commit
///                  ladder that spends bodies, however good the price. Leftovers
///                  reinforce piles only (else the dump leaks bodies out the back),
///                  and gather tops the count back toward the 25 cap.
///   base         - unmodified v2. The control - without it the table has no zero.
function sim_policies_all() {
    return [
        { id: "v1",      kind: "none",    lane: -1, ctl: "v1" },   // the original heuristic brain (ai_step)
        { id: "base",    kind: "none",    lane: -1 },              // stock v2 (ctl defaults to "v2")
        { id: "lane1",   kind: "lane",    lane: 0 },
        { id: "lane2",   kind: "lane",    lane: 1 },
        { id: "lane3",   kind: "lane",    lane: 2 },
        { id: "lane4",   kind: "lane",    lane: 3 },
        { id: "lane5",   kind: "lane",    lane: 4 },
        { id: "spread2", kind: "spread",  lane: -1 },
        { id: "numbers", kind: "numbers", lane: -1 },
        { id: "contestN", kind: "contestN", lane: -1 },
        { id: "contestR", kind: "contestR", lane: -1 },
        { id: "tiered",  kind: "tiered",  lane: -1, valueBar: 600, contestMin: 2 },
        { id: "planner", kind: "planner", lane: -1, threatBar: 200 },
        // v3 CASCADE brain: not a v2 hook - its seat runs ai3_step (kind "none" so
        // no v2 policy hooks fire; ctl "v3" swaps the whole brain)
        { id: "cascade", kind: "none",    lane: -1, ctl: "v3" },
        // v3b ACHIEVEMENT brain: v3 gather+move, achievement-model orders (ctl "v3b")
        { id: "cascade2", kind: "none",   lane: -1, ctl: "v3b" },
        // v4 VALUATION brain: from-scratch one-valuation/three-pass (ctl "v4"); shared move layer
        { id: "v4",      kind: "none",    lane: -1, ctl: "v4" },
    ];
}

/// The ACTIVE roster. The full brain ladder (2026-07-25): v1 -> v2(base) -> v3(cascade)
/// -> v3b(cascade2) -> v4. Purpose is per-board difficulty ranking: run all five, then
/// tools/derive_board_ai.py ranks them per board (head-to-head) into easy/medium/hard tiers.
/// 5 policies -> 25 pairings; at 100/pairing = 2500 games/board (~15-20 min each, so an
/// F12 over 16 boards is a long overnight run - drop games/pairing if it's too slow).
function sim_policies() {
    var _active = ["v1", "base", "cascade", "cascade2", "v4"];
    var _all = sim_policies_all();
    var _out = [];
    for (var _i = 0; _i < array_length(_all); _i++) {
        if (arr_has(_active, _all[_i].id)) array_push(_out, _all[_i]);
    }
    return _out;
}

/// The seat's forced strategy, or undefined for stock v2. scrAI2 asks this at
/// its decision points; outside the tournament it always answers undefined, so
/// normal play is untouched.
function sim_policy_get(_g, _p) {
    if (!variable_struct_exists(_g, "simPol")) return undefined;
    var _pol = _g.simPol[_p];
    if (_pol == undefined || _pol.kind == "none") return undefined;
    return _pol;
}

function sim_policy_set(_g, _pol0, _pol1) {
    _g.simPol = [_pol0, _pol1];
}

/// Plan-churn instrumentation. Hypothesis under test: `base` scores below every
/// forced-lane policy because ai2_state_epoch includes BANKED COUNTS - so every
/// bank flips the epoch, the mind re-derives, and it can switch focus lanes
/// mid-game. The forced policies never switch. If commitment is what buys that
/// score, v2's plan is less persistent than the design intends.
///
/// Doubles as a manipulation check: the lane1..lane5 policies MUST report zero
/// switches. If they don't, the override isn't holding and their rows are junk.
/// Inert outside the tournament (no simReplan field -> no-op).
function sim_note_replan(_g, _p, _prev, _new) {
    if (!variable_struct_exists(_g, "simReplan")) return;
    var _r = _g.simReplan[_p];
    _r.replans += 1;
    if (_prev != undefined && _prev.lane != _new.lane) _r.switches += 1;
}

function sim_policy_by_id(_id) {
    var _all = sim_policies_all(); // retired policies stay resolvable by id
    for (var _i = 0; _i < array_length(_all); _i++) if (_all[_i].id == _id) return _all[_i];
    return undefined;
}

/// Run the full round robin on one board. Every ORDERED pair (A as P1 vs B as P2)
/// including mirrors - the seats aren't symmetric (P1 has a mild first-move edge,
/// and a lane means different things from each end), so folding them would hide
/// exactly the asymmetry we want to see.
///
/// PAIRED SEEDS (common random numbers): game k of EVERY pairing starts from the
/// same seed, so all 64 pairings face the identical deck shuffles, board setup and
/// treasure piles. Policies are then compared on the same luck instead of each
/// drawing its own, which is where most of the variance lived (SE ~45 on effects
/// of ~50 in the first Grotto run - underpowered for everything but `numbers`).
///
/// It is NOT perfect pairing, and don't read it as such: the seeded stream is
/// shared by the engine AND the AI, so once two policies make a different number
/// of random calls (personality jitter, pellet rolls) their streams diverge
/// mid-game. What's guaranteed identical is the STARTING conditions - deck order,
/// setup, piles - which is the dominant term. Downstream divergence is inherent
/// without a second RNG stream, and isn't worth the surgery.
///
/// 8 policies -> 64 pairings x _perPair games. At ~114 ms/game, 60 each = ~7.5 min.
/// Start an INCREMENTAL tournament: state lives on global.simTourney and the
/// controller pumps sim_tournament_tick once per frame (Step_0). One sim game
/// costs 115-345ms - many frames of budget - so per-frame ticking matches the
/// old blocking loop's throughput while the window stays live: Draw_64 shows a
/// progress bar + ETA instead of Windows greying the title bar, and GM's own
/// between-frames GC runs naturally (the manual gc_collect stays as belt+braces).
/// BATCH RUN: queue several boards and play their tournaments back-to-back,
/// unattended. Pass a list of board ids; the first starts now, the rest chain as
/// each finishes (see the completion hook in sim_tournament_tick). Progress bar +
/// Esc-cancel work throughout; Esc cancels the CURRENT board and stops the batch.
function sim_tournament_run_boards(_boardList, _perPair = 100) {
    if (variable_global_exists("simTourney") && global.simTourney != undefined) return; // already running
    global.simBoardQueue = [];
    for (var _i = 1; _i < array_length(_boardList); _i++) array_push(global.simBoardQueue, _boardList[_i]);
    sim_report("");
    sim_report(">>> BATCH RUN: " + string(array_length(_boardList)) + " boards @ " + string(_perPair) + "/pairing: " + string(_boardList));
    sim_tournament_begin(_boardList[0], _perPair);
}

function sim_tournament_begin(_boardId, _perPair = 60, _seed = 20260717) {
    if (variable_global_exists("simTourney") && global.simTourney != undefined) return; // already running
    var _pols = sim_policies();
    var _n = array_length(_pols);

    sim_report("");
    sim_report("######## TOURNAMENT  board " + string(_boardId) + "  "
        + date_datetime_string(date_current_datetime()) + " ########");
    sim_report("policies " + string(_n) + ", " + string(_perPair) + " games/pairing, "
        + string(_n * _n * _perPair) + " games total, paired seeds from " + string(_seed));

    var _f = file_text_open_append("sim_tourney.csv");
    file_text_write_string(_f, "board,seed,p1pol,p2pol,p1score,p2score,winner,p1switch,p2switch,p1replan,p2replan");
    file_text_writeln(_f);
    file_text_close(_f);

    var _wins = array_create(_n), _pts = array_create(_n);
    for (var _i = 0; _i < _n; _i++) { _wins[_i] = array_create(_n, 0); _pts[_i] = 0; }
    global.simTourney = {
        boardId: _boardId, pols: _pols, n: _n, perPair: _perPair, seed: _seed,
        a: 0, b: 0, k: 0, done: 0, total: _n * _n * _perPair,
        wins: _wins, pts: _pts, played: array_create(_n, 0),
        sw: array_create(_n, 0), rp: array_create(_n, 0),
        stalls: 0, t0: get_timer(),
    };
}

/// Run ONE tournament game (called once per frame by Step_0 while active).
function sim_tournament_tick() {
    var _st = global.simTourney;
    if (_st == undefined) return;
    var _pols = _st.pols;

    _st.done += 1;
    if ((_st.done % 25) == 0) gc_collect(); // belt+braces; frames also collect now

    random_set_seed(_st.seed + _st.k); // paired: game k = same world in every pairing
    var _g = game_new(_st.boardId);
    sim_policy_set(_g, _pols[_st.a], _pols[_st.b]);
    _g.simReplan = [{ replans: 0, switches: 0 }, { replans: 0, switches: 0 }];
    // each policy carries which BRAIN its seat uses (default v2); a "cascade" row
    // points its seat at v3 so base(v2)-vs-cascade(v3) runs head to head
    var _ctlA = variable_struct_exists(_pols[_st.a], "ctl") ? _pols[_st.a].ctl : "v2";
    var _ctlB = variable_struct_exists(_pols[_st.b], "ctl") ? _pols[_st.b].ctl : "v2";
    var _r = game_playout(_g, [_ctlA, _ctlB]);
    if (!_r.ok) _st.stalls += 1;

    if (_r.winner == 0) { var _wrow = _st.wins[_st.a]; _wrow[_st.b] += 1; }
    _st.pts[_st.a] += _r.p0; _st.pts[_st.b] += _r.p1;
    _st.played[_st.a] += 1; _st.played[_st.b] += 1;
    var _c0 = _g.simReplan[0], _c1 = _g.simReplan[1];
    _st.sw[_st.a] += _c0.switches; _st.rp[_st.a] += _c0.replans;
    _st.sw[_st.b] += _c1.switches; _st.rp[_st.b] += _c1.replans;

    var _f = file_text_open_append("sim_tourney.csv"); // per-game append: a crash loses nothing
    file_text_write_string(_f, string(_st.boardId) + "," + string(_st.seed + _st.k) + ","
        + sim_brain_label(_pols[_st.a]) + "," + sim_brain_label(_pols[_st.b])
        + "," + string(_r.p0) + "," + string(_r.p1) + "," + string(_r.winner)
        + "," + string(_c0.switches) + "," + string(_c1.switches)
        + "," + string(_c0.replans) + "," + string(_c1.replans));
    file_text_writeln(_f);
    file_text_close(_f);

    // advance k -> b -> a
    _st.k += 1;
    if (_st.k >= _st.perPair) {
        _st.k = 0;
        _st.b += 1;
        if (_st.b >= _st.n) {
            _st.b = 0;
            sim_report("  ...done " + sim_brain_label(_pols[_st.a]) + " as P1 (" + string((get_timer() - _st.t0) / 1000000) + "s elapsed)");
            _st.a += 1;
            if (_st.a >= _st.n) {
                sim_tournament_report(_st);
                var _pp = _st.perPair;
                global.simTourney = undefined;
                // BATCH: if more boards are queued, roll straight into the next one
                // so a multi-board run finishes unattended (no per-map restart)
                if (variable_global_exists("simBoardQueue") && array_length(global.simBoardQueue) > 0) {
                    var _next = global.simBoardQueue[0];
                    array_delete(global.simBoardQueue, 0, 1);
                    sim_report(">>> BATCH: starting next board '" + _next + "'  (" + string(array_length(global.simBoardQueue)) + " left after)");
                    sim_tournament_begin(_next, _pp);
                }
            }
        }
    }
}

/// Esc mid-run: report what finished, then stop.
function sim_tournament_cancel() {
    var _st = global.simTourney;
    if (_st == undefined) return;
    sim_report("  *** CANCELLED at " + string(_st.done) + "/" + string(_st.total) + " games - partial totals below ***");
    sim_tournament_report(_st);
    global.simTourney = undefined;
    if (variable_global_exists("simBoardQueue")) global.simBoardQueue = []; // Esc stops the whole batch
}

function sim_tournament_report(_st) {
    var _pols = _st.pols;
    var _n = _st.n;
    var _perPair = _st.perPair;
    var _wins = _st.wins, _pts = _st.pts, _played = _st.played, _sw = _st.sw, _rp = _st.rp;
    var _t0 = _st.t0;
    var _stalls = _st.stalls;
    var _total = _st.done;

    // --- win matrix: rows = policy as P1, cols = opponent as P2 ---
    var _hdr = "        ";
    for (var _b = 0; _b < _n; _b++) _hdr += string_format_width(sim_brain_label(_pols[_b]), 8);
    sim_report("");
    sim_report("WIN MATRIX (row = P1 brain, cell = P1 wins out of " + string(_perPair) + " vs col as P2)");
    sim_report(_hdr);
    for (var _a = 0; _a < _n; _a++) {
        var _row = string_format_width(sim_brain_label(_pols[_a]), 8);
        var _wrowR = _wins[_a];
        for (var _b = 0; _b < _n; _b++) _row += string_format_width(string(_wrowR[_b]), 8);
        sim_report(_row);
    }
    sim_report("  (diagonal = mirror match; ~" + string(_perPair / 2) + " is the no-edge baseline)");

    // --- overall: win rate as P1 across all opponents, and avg score in every game played ---
    sim_report("");
    sim_report("OVERALL (winRate = wins as P1 over " + string(_n * _perPair) + " P1 games; avgScore across all seats)");
    sim_report("  laneSwitch/replan = plan churn per game. lane1-5 MUST read 0 switches");
    sim_report("  (if not, the override isn't holding and their rows are junk).");
    for (var _a = 0; _a < _n; _a++) {
        var _w = 0;
        var _wrowO = _wins[_a];
        for (var _b = 0; _b < _n; _b++) _w += _wrowO[_b];
        sim_report("  " + string_format_width(sim_brain_label(_pols[_a]), 9)
            + " winRate " + string_format_width(string(_w / max(1, _n * _perPair)), 7)
            + " avgScore " + string_format_width(string(_pts[_a] / max(1, _played[_a])), 9)
            + " laneSwitch/g " + string_format_width(string(_sw[_a] / max(1, _played[_a])), 7)
            + " replan/g " + string(_rp[_a] / max(1, _played[_a])));
    }
    sim_report("NOTE: exclude `numbers` when comparing contenders - the field's differentials");
    sim_report("      sum to zero, so a policy that loses by ~400 inflates everyone else.");
    var _secs = (get_timer() - _t0) / 1000000;
    sim_report("=== " + string(_total) + " games in " + string(_secs) + "s"
        + (_stalls > 0 ? "   *** " + string(_stalls) + " STALLED ***" : "") + " ===");
    sim_report("rows -> sim_tourney.csv");
}

/// Right-pad (the matrix is unreadable otherwise).
function string_format_width(_s, _w) {
    var _o = string(_s);
    while (string_length(_o) < _w) _o += " ";
    return _o;
}

// ---------- scenario tests (fast, deterministic - verify a decision node's
// ---------- FLOW without a tournament; the loop that catches logic bugs in ms) ----

/// Craft a controlled single-pile board: pile at (lane 0, idx) with the given
/// treasure-card ids, `_myOn` of my strength standing ON it, `_oppOn` of theirs.
/// (red carry = 1, so N reds = N strength.)
function sim_make_pile(_pileCards, _idx, _myOn, _oppOn) {
    random_set_seed(1);
    var _g = game_new("familiargrotto");
    _g.treasures = [{ cards: _pileCards, lane: 0, idx: _idx, boss: undefined }];
    _g.players[0].tokens = [];
    _g.players[1].tokens = [];
    repeat (_myOn)  array_push(_g.players[0].tokens, { typeId: "red", loc: { kind: "space", lane: 0, idx: _idx } });
    repeat (_oppOn) array_push(_g.players[1].tokens, { typeId: "red", loc: { kind: "space", lane: 0, idx: _idx } });
    return _g;
}

function sim_expect(_got, _want, _what) {
    sim_report((_got == _want ? "  PASS  " : "  *** FAIL *** ") + _what + "  (got " + string(_got) + ", want " + string(_want) + ")");
    return _got == _want;
}

/// Treasure ids by weight (from treasures.json) for building spreads.
#macro TW1 "difficult-choicetotem"
#macro TW5 "aspiration-ritualball"
#macro TW10 "cosmicarchive"

function sim_test_survey() {
    sim_report("");
    sim_report("=== SCENARIO TEST: survey drone strategic (ai3_strat_survey) ===");
    var _all = true;
    // top card = LAST in the array.

    // OFFENSE lighten->lift: pile [w1,w5] top=w5, 3 of mine on it. 3<5 (can't lift)
    // but 3>=1 (could lift the w1) -> lighten enables lift -> TRUE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW1, TW5], 1, 3, 0), 0), true, "offense: lighten to enable a lift");

    // NO SPREAD: [w5,w5] -> minW==maxW -> FALSE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW5, TW5], 1, 3, 0), 0), false, "no weight spread -> false");

    // CAN'T ACT: [w1,w5], nobody present -> myPot 0, oppHere 0 -> FALSE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW1, TW5], 1, 0, 0), 0), false, "neither side present -> false");

    // OFFENSE lighten->rush: [w1,w5] top=w5, 6 of mine. 6>=5 (lift now); rush current
    // needs 10; 6>=2 (2*w1) and 6<10 -> lighten enables RUSH -> TRUE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW1, TW5], 1, 6, 0), 0), true, "offense: lighten to enable a rush");

    // DEFENSE deny: [w10,w1] top=w1, OPP has 3. 3>=1 (they lift) 3<10 (couldn't lift w10) -> TRUE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW10, TW1], 1, 0, 3), 0), true, "defense: heavy to deny opponent");

    // DEFENSE no spread: [w1,w1] opp 3 -> FALSE
    _all &= sim_expect(ai3_strat_survey(sim_make_pile([TW1, TW1], 1, 0, 3), 0), false, "defense: no spread -> false");

    sim_report(_all ? "=== survey drone: ALL PASS ===" : "=== survey drone: FAILURES ABOVE ===");
    return _all;
}

/// Blank a board: no treasures, no tokens, no enemies/structures - place your own.
function sim_blank(_board) {
    random_set_seed(1);
    var _g = game_new(_board);
    _g.treasures = [];
    _g.players[0].tokens = [];
    _g.players[1].tokens = [];
    for (var _l = 0; _l < _g.board.laneCount; _l++)
        for (var _i = 0; _i <= 6; _i++) {
            var _sp = _g.board.lanes[_l].spaces[_i];
            _sp.enemy = undefined; _sp.structure = undefined;
            _sp.kind = "plain"; _sp.hazard = ""; // plain slate - tests set kinds they need
        }
    return _g;
}
function sim_put(_g, _p, _l, _i, _n) { repeat (_n) array_push(_g.players[_p].tokens, { typeId: "red", loc: { kind: "space", lane: _l, idx: _i } }); }

function sim_test_freeze() {
    sim_report("");
    sim_report("=== SCENARIO TEST: ice/storm freeze (denial) + bitter spray ===");
    var _all = true;

    // ICE: opp controlling carry, none of mine. +10 opp elsewhere so the CLUMP
    // branch can't fire -> isolates the carry branch.
    var _g = sim_blank("familiargrotto");
    _g.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g, 1, 2, 3, 5); sim_put(_g, 1, 0, 0, 10);
    _all &= sim_expect(ai3_strat_freeze_aoe(_g, 0, 1), true, "ice: opp controlling carry, none of mine");

    // ICE: same carry but I'm also standing there -> would freeze my own -> FALSE
    var _g2 = sim_blank("familiargrotto");
    _g2.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g2, 1, 2, 3, 5); sim_put(_g2, 1, 0, 0, 10); sim_put(_g2, 0, 2, 3, 3);
    _all &= sim_expect(ai3_strat_freeze_aoe(_g2, 0, 1), false, "ice: my pikmin in footprint -> skip");

    // ICE big clump: 6 of 8 opp on one space (75%), no carry, none of mine -> TRUE
    var _g3 = sim_blank("familiargrotto");
    sim_put(_g3, 1, 1, 2, 6); sim_put(_g3, 1, 4, 5, 2);
    _all &= sim_expect(ai3_strat_freeze_aoe(_g3, 0, 1), true, "ice: 75% clump");

    // ICE sub-threshold: 3 of 8, no carry -> FALSE
    var _g4 = sim_blank("familiargrotto");
    sim_put(_g4, 1, 1, 2, 3); sim_put(_g4, 1, 4, 5, 5);
    _all &= sim_expect(ai3_strat_freeze_aoe(_g4, 0, 1), false, "ice: sub-threshold clump, no carry");

    // BITTER tug-win: pile w5, I have 5, opp 6 (tying/winning). +10 opp elsewhere so
    // clump can't fire -> isolates tug-win.
    var _b = sim_blank("familiargrotto");
    _b.treasures = [{ cards: [TW5], lane: 2, idx: 1, boss: undefined }];
    sim_put(_b, 0, 2, 1, 5); sim_put(_b, 1, 2, 1, 6); sim_put(_b, 1, 0, 0, 10);
    _all &= sim_expect(ai3_strat_bitter(_b, 0), true, "bitter: tug-win (freeze their carriers off it)");

    // BITTER kill-stop: plain retaliator hp3 dmg1, I have 4 on it, opp has 0 pikmin
    // (no clump) -> isolates kill-stop -> TRUE
    var _k = sim_blank("familiargrotto");
    _k.board.lanes[2].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    sim_put(_k, 0, 2, 1, 4);
    _all &= sim_expect(ai3_strat_bitter(_k, 0), true, "bitter: kill-stop (clean kill of a retaliator)");

    // BITTER suicide-defence enemy: bitter can't stop the defence melt -> FALSE
    var _s = sim_blank("familiargrotto");
    _s.board.lanes[2].spaces[1].enemy = { enemyDefId: "wolpole", curHp: 3 };
    sim_put(_s, 0, 2, 1, 4);
    _all &= sim_expect(ai3_strat_bitter(_s, 0), false, "bitter: suicide-defence enemy -> no kill-stop");

    sim_report(_all ? "=== freeze/bitter: ALL PASS ===" : "=== freeze/bitter: FAILURES ABOVE ===");
    return _all;
}

function sim_test_pikpik() {
    sim_report("");
    sim_report("=== SCENARIO TEST: pikpik carrots (ai3_strat_pikpik) ===");
    var _all = true;
    // burrowingsnagret = swift, damage 3. curHp set per case. albino = non-swift.

    // soak BRIDGES the kill: swift D3, hp4, I have 5. without=5-3=2<4, with=5-0=5>=4 -> TRUE
    var _g = sim_blank("familiargrotto");
    _g.board.lanes[2].spaces[1].enemy = { enemyDefId: "burrowingsnagret", curHp: 4 };
    sim_put(_g, 0, 2, 1, 5);
    _all &= sim_expect(ai3_strat_pikpik(_g, 0), true, "swift: 5-soak bridges the kill");

    // ALREADY killable without it: swift D3, hp4, I have 8. without=5>=4 -> FALSE (not needed)
    var _g2 = sim_blank("familiargrotto");
    _g2.board.lanes[2].spaces[1].enemy = { enemyDefId: "burrowingsnagret", curHp: 4 };
    sim_put(_g2, 0, 2, 1, 8);
    _all &= sim_expect(ai3_strat_pikpik(_g2, 0), false, "swift: already killable -> not needed");

    // soak INSUFFICIENT: swift D3, hp5, I have 3. without=0<5, with=3<5 -> FALSE
    var _g3 = sim_blank("familiargrotto");
    _g3.board.lanes[2].spaces[1].enemy = { enemyDefId: "burrowingsnagret", curHp: 5 };
    sim_put(_g3, 0, 2, 1, 3);
    _all &= sim_expect(ai3_strat_pikpik(_g3, 0), false, "swift: soak insufficient to reach lethal");

    // NON-SWIFT enemy: damage lands after my attack -> never enables a kill -> FALSE
    var _g4 = sim_blank("familiargrotto");
    _g4.board.lanes[2].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 4 };
    sim_put(_g4, 0, 2, 1, 3);
    _all &= sim_expect(ai3_strat_pikpik(_g4, 0), false, "non-swift enemy -> false");

    // NOT ENGAGING: swift enemy but no pikmin on it -> FALSE
    var _g5 = sim_blank("familiargrotto");
    _g5.board.lanes[2].spaces[1].enemy = { enemyDefId: "burrowingsnagret", curHp: 4 };
    _all &= sim_expect(ai3_strat_pikpik(_g5, 0), false, "swift but I'm not engaging it -> false");

    sim_report(_all ? "=== pikpik: ALL PASS ===" : "=== pikpik: FAILURES ABOVE ===");
    return _all;
}

function sim_test_block() {
    sim_report("");
    sim_report("=== SCENARIO TEST: phosbat / rock storm blockers (ai3_strat_block) ===");
    var _all = true;
    // grotto has emitters. sim_blank normalises all spaces to "plain".

    // PHOSBAT: opp active in lane 2 (bodies + a pile) AND an empty enemy-slot there -> TRUE
    var _g = sim_blank("familiargrotto");
    _g.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g, 1, 2, 4, 4);                    // opponent bodies in lane 2
    _g.board.lanes[2].spaces[5].kind = "enemy"; // an empty enemy-slot in lane 2
    _all &= sim_expect(ai3_strat_block(_g, 0, "enemyslot"), true, "phosbat: opp-active lane + enemy-slot");

    // PHOSBAT: same but NO enemy-slot in the lane (all plain) -> FALSE
    var _g2 = sim_blank("familiargrotto");
    _g2.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g2, 1, 2, 4, 4);
    _all &= sim_expect(ai3_strat_block(_g2, 0, "enemyslot"), false, "phosbat: no enemy-slot -> false");

    // PHOSBAT: opponent NOT in lane 2 -> nothing to block -> FALSE
    var _g3 = sim_blank("familiargrotto");
    _g3.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g3, 1, 0, 4, 4);                   // opp in lane 0, not the pile's lane
    _g3.board.lanes[2].spaces[5].kind = "enemy";
    _all &= sim_expect(ai3_strat_block(_g3, 0, "enemyslot"), false, "phosbat: opp not in the lane -> false");

    // PHOSBAT: no enemies left to spawn -> FALSE
    var _g4 = sim_blank("familiargrotto");
    _g4.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_g4, 1, 2, 4, 4);
    _g4.board.lanes[2].spaces[5].kind = "enemy";
    _g4.decks.enemy = []; _g4.decks.enemyDiscard = [];
    _all &= sim_expect(ai3_strat_block(_g4, 0, "enemyslot"), false, "phosbat: empty enemy deck -> false");

    // ROCK STORM: opp active in lane 2 + a plain (non-hazard) space there -> TRUE (grotto has emitters)
    var _r = sim_blank("familiargrotto");
    _r.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_r, 1, 2, 4, 4);
    _all &= sim_expect(ai3_strat_block(_r, 0, "emitter"), true, "rockstorm: opp-active lane + placeable space");

    // ROCK STORM: opponent not active -> FALSE
    var _r2 = sim_blank("familiargrotto");
    _r2.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put(_r2, 1, 0, 4, 4);
    _all &= sim_expect(ai3_strat_block(_r2, 0, "emitter"), false, "rockstorm: opp not active -> false");

    sim_report(_all ? "=== block: ALL PASS ===" : "=== block: FAILURES ABOVE ===");
    return _all;
}

function sim_h(_hand) { var _g = sim_blank("familiargrotto"); _g.players[0].hand = _hand; return _g; }

function sim_test_rawmaterial() {
    sim_report("");
    sim_report("=== SCENARIO TEST: raw material pair + useful-card count ===");
    var _all = true;

    // rawmaterial is class "pair": a pair is a usable card, a lone one is not yet
    _all &= sim_expect(ai3_card_useful(sim_h(["rawmaterial", "rawmaterial"]), 0, "rawmaterial"), true,  "raw: 2 copies -> useful");
    _all &= sim_expect(ai3_card_useful(sim_h(["rawmaterial"]), 0, "rawmaterial"),                false, "raw: 1 copy -> not yet a card");

    // ai3_useful_card_count: a held PAIR counts as ONE, not two
    _all &= sim_expect(ai3_useful_card_count(sim_h(["rawmaterial", "rawmaterial"]), 0), 1, "count: a pair = 1 useful card");
    // a lone rawmaterial counts 0; two pairs count 2
    _all &= sim_expect(ai3_useful_card_count(sim_h(["rawmaterial"]), 0), 0, "count: lone raw = 0");
    _all &= sim_expect(ai3_useful_card_count(sim_h(["rawmaterial", "rawmaterial", "rawmaterial", "rawmaterial"]), 0), 2, "count: two pairs = 2");

    // mixed hand: spicy (always) + posy (pellet, excluded) + lone raw (0) = 1
    _all &= sim_expect(ai3_useful_card_count(sim_h(["spicyspray", "colorchangingposy", "rawmaterial"]), 0), 1, "count: spicy=1, posy excluded, lone raw=0");
    // never cards don't count: mine + extinction + oatchi(always) = 1
    _all &= sim_expect(ai3_useful_card_count(sim_h(["mine", "pikminextinction", "oatchirush"]), 0), 1, "count: mine/extinction excluded, oatchi=1");

    sim_report(_all ? "=== raw material: ALL PASS ===" : "=== raw material: FAILURES ABOVE ===");
    return _all;
}

function sim_put_home(_g, _p, _n) { repeat (_n) array_push(_g.players[_p].tokens, { typeId: "red", loc: { kind: "home" } }); }

function sim_test_ivory_warp_clone() {
    sim_report("");
    sim_report("=== SCENARIO TEST: ivory&violet / warp / captain clone ===");
    var _all = true;

    // IVORY WHITE: board has a poison space -> TRUE (no surplus needed)
    var _iw = sim_blank("familiargrotto");
    _iw.board.lanes[1].spaces[2].hazard = "poison";
    _all &= sim_expect(ai3_strat_ivory(_iw, 0), true, "ivory: poison on board -> white wanted");

    // IVORY PURPLE: surplus (10 home) + a plain-road pile -> TRUE
    var _ip = sim_blank("familiargrotto");
    _ip.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put_home(_ip, 0, 10);
    _all &= sim_expect(ai3_strat_ivory(_ip, 0), true, "ivory: surplus + open lane -> purple wanted");

    // IVORY neither: no poison, no surplus -> FALSE
    var _in = sim_blank("familiargrotto");
    _in.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    sim_put_home(_in, 0, 4);
    _all &= sim_expect(ai3_strat_ivory(_in, 0), false, "ivory: no poison, no surplus -> false");

    // IVORY surplus but no open lane (chasm on the road purple can't cross) -> FALSE
    var _ic = sim_blank("familiargrotto");
    _ic.treasures = [{ cards: [TW5], lane: 2, idx: 3, boss: undefined }];
    _ic.board.lanes[2].spaces[1].kind = "hazard"; _ic.board.lanes[2].spaces[1].hazard = "chasm";
    sim_put_home(_ic, 0, 10);
    _all &= sim_expect(ai3_strat_ivory(_ic, 0), false, "ivory: surplus but purple can't reach any pile -> false");

    // WARP relocate: an enemy on my road to a pile + a dump enemy-slot -> TRUE
    var _w = sim_blank("familiargrotto");
    _w.treasures = [{ cards: [TW5], lane: 2, idx: 4, boss: undefined }];
    _w.board.lanes[2].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 }; // blocks my road (idx1 < idx4)
    _w.board.lanes[0].spaces[3].kind = "enemy"; // an empty dump slot
    _all &= sim_expect(ai3_strat_warp(_w, 0), true, "warp: blocker on my road + dump slot");

    // WARP no dump slot, no bosses -> FALSE
    var _w2 = sim_blank("familiargrotto");
    _w2.treasures = [{ cards: [TW5], lane: 2, idx: 4, boss: undefined }];
    _w2.board.lanes[2].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(ai3_strat_warp(_w2, 0), false, "warp: blocker but no dump slot -> false");

    // WARP boss swap: 2 bosses -> TRUE
    var _w3 = sim_blank("familiargrotto");
    _w3.treasures = [
        { cards: [TW5], lane: 1, idx: 3, boss: { enemyDefId: "albinodwarfbulborb", curHp: 3 } },
        { cards: [TW5], lane: 3, idx: 3, boss: { enemyDefId: "albinodwarfbulborb", curHp: 3 } }
    ];
    _all &= sim_expect(ai3_strat_warp(_w3, 0), true, "warp: 2 bosses -> swap");

    // CLONE: hand has clone + spicy (always useful) -> TRUE
    _all &= sim_expect(ai3_strat_clone(sim_h(["captainclone", "spicyspray"]), 0), true, "clone: a useful card to copy");
    // CLONE: hand has clone + only never-cards -> FALSE
    _all &= sim_expect(ai3_strat_clone(sim_h(["captainclone", "mine", "pikminextinction"]), 0), false, "clone: nothing worth copying");
    // CLONE: discard top is useful (oatchi) -> TRUE
    var _cd = sim_h(["captainclone", "mine"]);
    _cd.decks.gatherDiscard = ["oatchirush"];
    _all &= sim_expect(ai3_strat_clone(_cd, 0), true, "clone: useful card on discard top");

    sim_report(_all ? "=== ivory/warp/clone: ALL PASS ===" : "=== ivory/warp/clone: FAILURES ABOVE ===");
    return _all;
}

/// Build a gather-decision case on a blank grotto (P0's seat): _bodies pikmin at
/// HOME (all count toward the cap), the given pellet-card reserve, and the given
/// gather hand. sim_blank already emptied tokens; we set pellets/hand explicitly.
function sim_gather_case(_bodies, _pellets, _hand) {
    var _g = sim_blank("familiargrotto");
    sim_put_home(_g, 0, _bodies);
    _g.players[0].pellets = _pellets;
    _g.players[0].hand = _hand;
    return _g;
}

function sim_test_gather() {
    sim_report("");
    sim_report("=== SCENARIO TEST: gather ladder (ai3_gather_decision) ===");
    var _all = true;

    // 1. BODY EMERGENCY takes priority: roster half-empty + thin reserve -> ROLL,
    //    even though the hand already clears the card floor (3 always-useful cards).
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(5, [], ["spicyspray", "oatchirush", "bombrock"]), 0), "roll", "emergency: low bodies + no reserve -> roll (over card floor)");
    // emergency does NOT fire when the reserve can refill (4 pellets, >=1 five):
    // falls through both floors to composition -> 3 gather vs 4 pellet = draw.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(5, ["red5", "red5", "red1", "red1"], ["spicyspray", "oatchirush", "bombrock"]), 0), "draw", "no emergency: low bodies but reserve OK -> composition draw");
    // boundary: 13 bodies is NOT below half the cap (12.5) -> no emergency.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(13, [], ["spicyspray"]), 0), "draw", "boundary: 13 bodies not an emergency -> card floor draw");

    // 2. CARD FLOOR: plenty of bodies, too few actionable cards -> DRAW.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(20, ["red5"], ["spicyspray"]), 0), "draw", "card floor: 1 useful card -> draw");
    // never-cards don't satisfy the floor (usefulCount 0).
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(20, ["red1"], ["mine", "pikminextinction", "mine"]), 0), "draw", "card floor: never-cards don't count -> draw");

    // 3. 6:4 COMPOSITION, both floors met:
    //    gather-heavy (5:1 = 83%) -> ROLL.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(20, ["red1"], ["spicyspray", "oatchirush", "bombrock", "candypopbud", "boulder"]), 0), "roll", "composition: 83% gather -> roll");
    //    flood of pellets (3:5 = 37%) self-solves as DRAW.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(20, ["red1", "red1", "red1", "red1", "red1"], ["spicyspray", "oatchirush", "bombrock"]), 0), "draw", "composition: pellet flood -> draw");
    //    exactly 60% (3:2) is NOT below the bar -> ROLL.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(20, ["red1", "red1"], ["spicyspray", "oatchirush", "bombrock"]), 0), "roll", "composition: exactly 60% gather -> roll");

    // ROSTER FULL: bodies do nothing - draw while there's hand room, else roll.
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(25, [], ["spicyspray"]), 0), "draw", "roster full: hand room -> draw");
    _all &= sim_expect(ai3_gather_decision(sim_gather_case(25, [], ["spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray", "spicyspray"]), 0), "roll", "roster full: hand full -> roll");

    sim_report(_all ? "=== gather ladder: ALL PASS ===" : "=== gather ladder: FAILURES ABOVE ===");
    return _all;
}

function sim_test_attack_cost() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders node 1 - attack body-cost (ai3_attack_cost) ===");
    var _all = true;
    var _g = sim_blank("familiargrotto"); // empties tokens -> 0 home whites (swift-soak baseline)

    // PLAIN (albinodwarfbulborb hp3 dmg1, no elements): 3 reds kill, killed before it swings -> FREE
    var _r = ai3_attack_cost(_g, 0, enemy_def_get("albinodwarfbulborb"), 3, { red: 3 }, false);
    _all &= sim_expect(_r.kills, true,  "plain: 3 reds kill hp3");
    _all &= sim_expect(_r.losses, 0,    "plain: killed before it swings -> 0 lost");
    // 2 reds chip (don't kill) -> eat the dmg1 swing -> 1 lost
    _r = ai3_attack_cost(_g, 0, enemy_def_get("albinodwarfbulborb"), 3, { red: 2 }, false);
    _all &= sim_expect(_r.kills, false, "plain: 2 reds don't kill hp3");
    _all &= sim_expect(_r.losses, 1,    "plain: chip eats the swing -> 1 lost");

    // WATER DEFENSE (wolpole hp3 dmg0 def water): reds KILL but ALL melt (clean kill != safe); blues free
    _r = ai3_attack_cost(_g, 0, enemy_def_get("wolpole"), 3, { red: 3 }, false);
    _all &= sim_expect(_r.kills, true,  "wolpole: 3 reds reach hp3");
    _all &= sim_expect(_r.losses, 3,    "wolpole: all 3 reds melt on the water defense (clean kill != safe)");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("wolpole"), 3, { blue: 3 }, false);
    _all &= sim_expect(_r.free, true,   "wolpole: 3 blues kill it free (immune to the melt)");

    // CRUSH ATTACK (armoredcannonbeetle hp25 dmg10 atk crush): lands even on a clean kill, hits rock too
    _r = ai3_attack_cost(_g, 0, enemy_def_get("armoredcannonbeetle"), 25, { red: 25 }, false);
    _all &= sim_expect(_r.kills, true,  "crush beetle: 25 reds reach hp25");
    _all &= sim_expect(_r.losses, 10,   "crush beetle: crush strikes even dead -> 10 lost");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("armoredcannonbeetle"), 25, { rock: 25 }, false);
    _all &= sim_expect(_r.losses, 10,   "crush beetle: rock isn't immune to a crush ATTACK (crush-imm is defense-only) -> 10 lost");

    // SWIFT (burrowingsnagret hp20 dmg3 atk swift): no spicy eats 3; spicy strikes first -> free
    _r = ai3_attack_cost(_g, 0, enemy_def_get("burrowingsnagret"), 20, { red: 23 }, false);
    _all &= sim_expect(_r.kills, true,  "snagret: 23 reds meet the swift-soak req (20+3)");
    _all &= sim_expect(_r.losses, 3,    "snagret no spicy: eats 3 to the swift first-strike");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("burrowingsnagret"), 20, { red: 20 }, true);
    _all &= sim_expect(_r.kills, true,  "snagret spicy: no soak needed -> 20 reds kill hp20");
    _all &= sim_expect(_r.free, true,   "snagret spicy: spicy round beats swift -> free");

    // HEIGHT GATE (honeywisp hp3 dmg0 def height): reds can't reach it; yellows climb + free-kill
    _r = ai3_attack_cost(_g, 0, enemy_def_get("honeywisp"), 3, { red: 3 }, false);
    _all &= sim_expect(_r.canHurt, false, "wisp: reds fail the height gate (can't hurt)");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("honeywisp"), 3, { yellow: 3 }, false);
    _all &= sim_expect(_r.kills, true,  "wisp: yellows climb it");
    _all &= sim_expect(_r.free, true,   "wisp: dmg0 + no melt -> free");

    // POISON/POISON (moldyslooch hp6 dmg4): whites clean, reds all melt, and the deadweight whittle
    _r = ai3_attack_cost(_g, 0, enemy_def_get("moldyslooch"), 6, { white: 6 }, false);
    _all &= sim_expect(_r.free, true,   "poison/poison: 6 whites kill it clean");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("moldyslooch"), 6, { red: 6 }, false);
    _all &= sim_expect(_r.kills, true,  "poison/poison: 6 reds reach hp6");
    _all &= sim_expect(_r.losses, 6,    "poison/poison: but all 6 reds melt (whites-only clean kill)");
    _r = ai3_attack_cost(_g, 0, enemy_def_get("moldyslooch"), 6, { red: 3 }, false);
    _all &= sim_expect(_r.kills, false, "poison/poison whittle: 3 reds don't kill hp6");
    _all &= sim_expect(_r.losses, 3,    "poison/poison whittle: 3 reds deal 3 permanent, all melt (deadweight grind)");

    sim_report(_all ? "=== attack body-cost: ALL PASS ===" : "=== attack body-cost: FAILURES ABOVE ===");
    return _all;
}

function sim_put_home_col(_g, _p, _col, _n) { repeat (_n) array_push(_g.players[_p].tokens, { typeId: _col, loc: { kind: "home" } }); }

function sim_test_deadweight() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders node 2 - deadweight strength (ai3_deadweight_strength) ===");
    var _all = true;

    // A. unblocked reachable pile -> reds NOT deadweight
    var _g = sim_blank("familiargrotto");
    _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g, 0, "red", 5);
    _all &= sim_expect(ai3_deadweight_strength(_g, 0, [], []).total, 0, "A: reds reach an open pile -> 0 deadweight");

    // B. pile blocked by an enemy reds CAN'T hurt (height wisp), no kill planned -> reds deadweight
    var _b = sim_blank("familiargrotto");
    _b.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _b.board.lanes[0].spaces[1].enemy = { enemyDefId: "honeywisp", curHp: 3 };
    sim_put_home_col(_b, 0, "red", 5);
    _all &= sim_expect(ai3_deadweight_strength(_b, 0, [], []).total, 5, "B: 5 reds stuck behind an un-hurtable blocker -> 5 deadweight");

    // C. same board, but that blocker is in the killedSet -> one-turn lookahead clears it -> NOT deadweight
    _all &= sim_expect(ai3_deadweight_strength(_b, 0, [{ lane: 0, idx: 1 }], []).total, 0, "C: killing the blocker this turn -> reds reach the pile next turn -> 0 deadweight");

    // D. pile behind a chasm -> reds deadweight; with a planned bridge -> not
    var _d = sim_blank("familiargrotto");
    _d.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _d.board.lanes[0].spaces[1].kind = "hazard"; _d.board.lanes[0].spaces[1].hazard = "chasm";
    sim_put_home_col(_d, 0, "red", 4);
    _all &= sim_expect(ai3_deadweight_strength(_d, 0, [], []).total, 4, "D: 4 reds behind a chasm -> 4 deadweight");
    _all &= sim_expect(ai3_deadweight_strength(_d, 0, [], [{ lane: 0, idx: 1 }]).total, 0, "D: plan a bridge over it -> 0 deadweight");

    // E. minefield-shaped mixed roster: reds cross the fire to reach the blocker (useful), rocks can't
    var _e = sim_blank("familiargrotto");
    _e.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _e.board.lanes[0].spaces[1].kind = "hazard"; _e.board.lanes[0].spaces[1].hazard = "fire";
    _e.board.lanes[0].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    sim_put_home_col(_e, 0, "red", 3);
    sim_put_home_col(_e, 0, "rock", 3);
    var _r = ai3_deadweight_strength(_e, 0, [], []);
    _all &= sim_expect(_r.total, 3, "E: reds cross fire to the blocker (useful), rocks can't -> 3 deadweight");
    _all &= sim_expect(variable_struct_exists(_r.byColor, "rock") ? _r.byColor.rock : 0, 3, "E: byColor flags the 3 stuck rocks");
    _all &= sim_expect(variable_struct_exists(_r.byColor, "red"), false, "E: useful reds not flagged");

    sim_report(_all ? "=== deadweight: ALL PASS ===" : "=== deadweight: FAILURES ABOVE ===");
    return _all;
}

function sim_test_access() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders access cost (ai3_road_turns / ai3_access_cost) ===");
    var _all = true;
    var _savedRush = global.expRules.rush;
    global.expRules.rush = false; // determinism for the carry term (ai2_turns_to_bank)

    // --- ROAD TURNS ---
    var _g = sim_blank("familiargrotto");
    _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g, 0, "red", 6);
    _all &= sim_expect(ai3_road_turns(_g, 0, 0, 3), 0, "road: open lane -> 0 turns");
    _g.board.lanes[0].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(ai3_road_turns(_g, 0, 0, 3), 1, "road: one clearable enemy -> 1 turn");
    _g.board.lanes[0].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(ai3_road_turns(_g, 0, 0, 3), 2, "road: two clearable enemies -> 2 turns");

    // un-hurtable blocker (height wisp, reds can't hurt) -> INF
    var _u = sim_blank("familiargrotto");
    _u.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _u.board.lanes[0].spaces[1].enemy = { enemyDefId: "honeywisp", curHp: 3 };
    sim_put_home_col(_u, 0, "red", 6);
    _all &= sim_expect(ai3_road_turns(_u, 0, 0, 3), ACCESS_INF, "road: un-hurtable blocker -> INF (dead for me)");

    // fire crossed by fire-immune reds -> 0; fire + non-immune rocks -> BRIDGEABLE (a
    // bridge goes on ANY hazard, incl. fire) -> +1 turn, NOT a dead lane (was the bug).
    var _f = sim_blank("familiargrotto");
    _f.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _f.board.lanes[0].spaces[1].kind = "hazard"; _f.board.lanes[0].spaces[1].hazard = "fire";
    sim_put_home_col(_f, 0, "red", 6);
    _all &= sim_expect(ai3_road_turns(_f, 0, 0, 3), 0, "road: fire crossed by fire-immune reds -> 0");
    var _f2 = sim_blank("familiargrotto");
    _f2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _f2.board.lanes[0].spaces[1].kind = "hazard"; _f2.board.lanes[0].spaces[1].hazard = "fire";
    sim_put_home_col(_f2, 0, "rock", 6);
    _all &= sim_expect(ai3_road_turns(_f2, 0, 0, 3), 1, "road: fire, non-immune rocks, but bridgeable -> 1 (build a bridge)");

    // chasm reds can't cross, but the board's pool can bridge it -> +1
    var _c = sim_blank("familiargrotto");
    _c.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _c.board.lanes[0].spaces[1].kind = "hazard"; _c.board.lanes[0].spaces[1].hazard = "chasm";
    sim_put_home_col(_c, 0, "red", 6);
    _all &= sim_expect(ai3_road_turns(_c, 0, 0, 3), 1, "road: chasm bridgeable -> 1 turn (build a bridge)");

    // --- ACCESS COST = road + carry (rush off: carry(w5,idx3,p0) = ceil(4/1)+1 = 5) ---
    var _a = sim_blank("familiargrotto");
    _a.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_a, 0, "red", 6);
    _all &= sim_expect(ai3_access_cost(_a, 0, 0, 3), 5, "access: open road (0) + carry (5) -> 5");
    _a.board.lanes[0].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(ai3_access_cost(_a, 0, 0, 3), 6, "access: one blocker (+1) + carry (5) -> 6");
    _all &= sim_expect(ai3_access_cost(_u, 0, 0, 3), ACCESS_INF, "access: un-openable road -> INF");

    global.expRules.rush = _savedRush;
    sim_report(_all ? "=== access cost: ALL PASS ===" : "=== access cost: FAILURES ABOVE ===");
    return _all;
}

function sim_test_main_lane() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders main-lane pick (ai3_main_lane) ===");
    var _all = true;
    var _savedRush = global.expRules.rush;
    global.expRules.rush = false;

    // A. equal value, lane0 open vs lane1 with 2 blockers on my side -> cheaper-access lane 0
    var _a = sim_blank("familiargrotto");
    _a.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }, { cards: [TW5], lane: 1, idx: 3, boss: undefined }];
    _a.board.lanes[1].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _a.board.lanes[1].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    sim_put_home_col(_a, 0, "red", 8); sim_put_home_col(_a, 1, "red", 8);
    _all &= sim_expect(ai3_main_lane(_a, 0).lane, 0, "main: equal value, easier access wins (lane 0)");

    // B. equal access, lane1 far richer (cosmicarchive 230 vs totem 20) -> lane 1
    var _b = sim_blank("familiargrotto");
    _b.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }, { cards: [TW10], lane: 1, idx: 3, boss: undefined }];
    sim_put_home_col(_b, 0, "red", 8); sim_put_home_col(_b, 1, "red", 8);
    _all &= sim_expect(ai3_main_lane(_b, 0).lane, 1, "main: equal access, richer pile wins (lane 1)");

    // C. equal value & my-access, but opponent CAN'T reach lane 0 (blocked on THEIR side) -> free pile
    var _c = sim_blank("familiargrotto");
    _c.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }, { cards: [TW5], lane: 1, idx: 3, boss: undefined }];
    _c.board.lanes[0].spaces[5].enemy = { enemyDefId: "honeywisp", curHp: 3 }; // opp-side blocker they can't hurt
    sim_put_home_col(_c, 0, "red", 8); sim_put_home_col(_c, 1, "red", 8);
    _all &= sim_expect(ai3_main_lane(_c, 0).lane, 0, "main: free pile (opp can't reach lane 0) beats a contested equal");

    // D. lane1 is richer but MY access is dead (un-hurtable blocker) -> reachable lane 0
    var _d = sim_blank("familiargrotto");
    _d.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }, { cards: [TW10], lane: 1, idx: 3, boss: undefined }];
    _d.board.lanes[1].spaces[1].enemy = { enemyDefId: "honeywisp", curHp: 3 }; // my side, can't hurt -> lane1 INF for me
    sim_put_home_col(_d, 0, "red", 8); sim_put_home_col(_d, 1, "red", 8);
    _all &= sim_expect(ai3_main_lane(_d, 0).lane, 0, "main: un-openable rich lane skipped -> reachable lane 0");

    global.expRules.rush = _savedRush;
    sim_report(_all ? "=== main-lane: ALL PASS ===" : "=== main-lane: FAILURES ABOVE ===");
    return _all;
}

function sim_test_advance_commit() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders advance step-sizing (ai3_advance_commit) ===");
    var _all = true;
    var _savedRush = global.expRules.rush;
    global.expRules.rush = false;
    var _g;

    // 1. min-win, uncontested -> weight 5
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true), 5, "commit: uncontested min-win = weight 5");

    // 2. contested (opp 6 on pile): BREADTH beats them at min-win (7); DEPTH also buffers
    //    (the on-pile opp counts as in-lane presence) -> 7 + 4 = 11
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g, 1, 0, 3, 6);
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], false), 7,  "commit: breadth contested -> min-win beats opp (6) = 7 (no buffer)");
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true),  11, "commit: depth contested -> min-win(7) + buffer(4) = 11");

    // 3. already holding enough (6 of mine on pile) -> 0
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g, 0, 0, 3, 6);
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true), 0, "commit: already holding -> 0");

    // 4/5. opp present ELSEWHERE in the lane (3 at idx5): BREADTH ignores buffer, DEPTH adds it
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g, 1, 0, 5, 3);
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], false), 5, "commit: breadth = min-win only (no buffer) = 5");
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true),  9, "commit: depth + opp-in-lane -> min-win + buffer(4) = 9");

    // 6. depth but opp absent -> no buffer = 5
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true), 5, "commit: depth but opp absent -> no buffer = 5");

    // 7. depth RUSH (rush on, weight<=8, opp<weight) -> 2x weight = 10
    global.expRules.rush = true;
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true), 10, "commit: depth rush -> 2x weight = 10");

    // 8. opp HOLDING (oppS >= weight) DISABLES rush -> min-win+buffer, NOT 2x.
    //    w=1, oppS=1 (holding): min-win=max(1,2)=2, +buffer4 = 6 (a 2x would be 2)
    _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }]; sim_put(_g, 1, 0, 3, 1);
    _all &= sim_expect(ai3_advance_commit(_g, 0, _g.treasures[0], true), 6, "commit: opp holding disables rush -> min-win+buffer 6 (not 2x)");

    global.expRules.rush = _savedRush;
    sim_report(_all ? "=== advance commit: ALL PASS ===" : "=== advance commit: FAILURES ABOVE ===");
    return _all;
}

function sim_test_target_piles() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders breadth cap (ai3_target_piles) ===");
    var _all = true;
    var _savedRush = global.expRules.rush;
    global.expRules.rush = false;

    // 4 reachable piles, worsening access (lane0 open .. lane3 = 3 blockers) -> the
    // top-3 by score are lanes 0,1,2; the worst-access lane 3 is capped out.
    var _g = sim_blank("familiargrotto");
    _g.treasures = [
        { cards: [TW5], lane: 0, idx: 3, boss: undefined },
        { cards: [TW5], lane: 1, idx: 3, boss: undefined },
        { cards: [TW5], lane: 2, idx: 3, boss: undefined },
        { cards: [TW5], lane: 3, idx: 3, boss: undefined }
    ];
    _g.board.lanes[1].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.board.lanes[2].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.board.lanes[2].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.board.lanes[3].spaces[0].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.board.lanes[3].spaces[1].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.board.lanes[3].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    sim_put_home_col(_g, 0, "red", 12);

    var _tp = ai3_target_piles(_g, 0, 3);
    _all &= sim_expect(array_length(_tp), 3, "cap: 4 reachable piles -> capped at 3 targets");
    _all &= sim_expect(_tp[0].lane, 0, "cap: best-access lane (0) ranked first");
    var _has3 = false;
    for (var _i = 0; _i < array_length(_tp); _i++) if (_tp[_i].lane == 3) _has3 = true;
    _all &= sim_expect(_has3, false, "cap: worst-access lane (3) excluded from the top-3");

    global.expRules.rush = _savedRush;
    sim_report(_all ? "=== breadth cap: ALL PASS ===" : "=== breadth cap: FAILURES ABOVE ===");
    return _all;
}

function sim_test_clear_loss() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders clear-loss pricing (ai3_clear_loss) ===");
    var _all = true;
    var _g = sim_blank("familiargrotto"); sim_put_home_col(_g, 0, "red", 5);

    // plain enemy, reds -> free clear
    _all &= sim_expect(ai3_clear_loss(_g, 0, enemy_def_get("albinodwarfbulborb"), 3), 0, "clear: plain enemy w/ reds -> 0 lost");
    // swift (dmg3) no defence -> lose the unavoidable first strike (3)
    _all &= sim_expect(ai3_clear_loss(_g, 0, enemy_def_get("burrowingsnagret"), 23), 3, "clear: swift -> lose the first-strike (3)");
    // crush (dmg10) -> unavoidable swing (10)
    _all &= sim_expect(ai3_clear_loss(_g, 0, enemy_def_get("armoredcannonbeetle"), 25), 10, "clear: crush -> unavoidable 10");
    // water-defence wolpole, reds (not immune) -> the WHOLE attack melts = req (this is the Fiery-Bulblax bug)
    _all &= sim_expect(ai3_clear_loss(_g, 0, enemy_def_get("wolpole"), 3), 3, "clear: suicide-defence, no immune colour -> melts all (req 3)");
    // ...but with an immune colour (blues vs water) it's free
    var _b = sim_blank("familiargrotto"); sim_put_home_col(_b, 0, "blue", 5);
    _all &= sim_expect(ai3_clear_loss(_b, 0, enemy_def_get("wolpole"), 3), 0, "clear: suicide-defence w/ immune colour -> 0 lost");

    sim_report(_all ? "=== clear-loss: ALL PASS ===" : "=== clear-loss: FAILURES ABOVE ===");
    return _all;
}

function sim_test_instant_bank() {
    sim_report("");
    sim_report("=== SCENARIO TEST: orders snipe / instant-bank (ai3_can_instant_bank) ===");
    var _all = true;
    var _savedRush = global.expRules.rush;

    // WHITE path: 5 whites on a centre w5 pile + spicy -> YES (all-white 2-step, rush-INDEPENDENT)
    global.expRules.rush = false;
    var _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g.players[0].hand = ["spicyspray"]; sim_put_home_col(_g, 0, "white", 5);
    _all &= sim_expect(ai3_can_instant_bank(_g, 0, _g.treasures[0]), true, "snipe: 5 whites, centre w5, spicy -> yes (white, rush off)");
    // white out-muscles a HOLDING opp (whites aren't opp-holding-gated): 8 whites vs opp 5
    var _gw = sim_blank("familiargrotto"); _gw.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gw.players[0].hand = ["spicyspray"]; sim_put_home_col(_gw, 0, "white", 8); sim_put(_gw, 1, 0, 3, 5);
    _all &= sim_expect(ai3_can_instant_bank(_gw, 0, _gw.treasures[0]), true, "snipe: 8 whites out-muscle a holding opp (5) -> yes");
    // white insufficient (4 < weight 5)
    var _g2 = sim_blank("familiargrotto"); _g2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g2.players[0].hand = ["spicyspray"]; sim_put_home_col(_g2, 0, "white", 4);
    _all &= sim_expect(ai3_can_instant_bank(_g2, 0, _g2.treasures[0]), false, "snipe: 4 whites < weight 5 -> no");

    // RUSH path: 10 reds, centre w5, rush ON + spicy -> yes (>= 2x weight)
    global.expRules.rush = true;
    var _g3 = sim_blank("familiargrotto"); _g3.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g3.players[0].hand = ["spicyspray"]; sim_put_home_col(_g3, 0, "red", 10);
    _all &= sim_expect(ai3_can_instant_bank(_g3, 0, _g3.treasures[0]), true, "snipe: 10 reds (2x w5), rush+spicy -> yes");
    // below 2x
    var _g4 = sim_blank("familiargrotto"); _g4.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g4.players[0].hand = ["spicyspray"]; sim_put_home_col(_g4, 0, "red", 8);
    _all &= sim_expect(ai3_can_instant_bank(_g4, 0, _g4.treasures[0]), false, "snipe: 8 reds < 2x weight (10) -> no");
    // rush OFF disables the non-white path
    global.expRules.rush = false;
    _all &= sim_expect(ai3_can_instant_bank(_g3, 0, _g3.treasures[0]), false, "snipe: 10 reds but rush OFF -> no (non-white needs rush)");
    // opp HOLDING disables the rush path (reds can't rush a held pile)
    global.expRules.rush = true;
    var _g5 = sim_blank("familiargrotto"); _g5.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g5.players[0].hand = ["spicyspray"]; sim_put_home_col(_g5, 0, "red", 12); sim_put(_g5, 1, 0, 3, 5);
    _all &= sim_expect(ai3_can_instant_bank(_g5, 0, _g5.treasures[0]), false, "snipe: reds vs holding opp (5>=w5) -> no");

    // NO SPICY (only 1 carry action = 2 spaces, can't clear 4)
    var _g6 = sim_blank("familiargrotto"); _g6.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _g6.players[0].hand = []; sim_put_home_col(_g6, 0, "white", 8);
    _all &= sim_expect(ai3_can_instant_bank(_g6, 0, _g6.treasures[0]), false, "snipe: no spicy -> no");
    // TOO FAR (pile at idx4 -> dist 5 > 4)
    var _g7 = sim_blank("familiargrotto"); _g7.treasures = [{ cards: [TW5], lane: 0, idx: 4, boss: undefined }];
    _g7.players[0].hand = ["spicyspray"]; sim_put_home_col(_g7, 0, "white", 8);
    _all &= sim_expect(ai3_can_instant_bank(_g7, 0, _g7.treasures[0]), false, "snipe: pile too far (dist 5 > 4) -> no");

    global.expRules.rush = _savedRush;
    sim_report(_all ? "=== instant-bank: ALL PASS ===" : "=== instant-bank: FAILURES ABOVE ===");
    return _all;
}

function sim_test_play_spicy() {
    sim_report("");
    sim_report("=== SCENARIO TEST: card play - spicy target (ai3_play_spicy) ===");
    var _all = true;

    // controlled centre pile (6 mine >= w5, opp 0, dist 4) -> spray it (lane index 0)
    var _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g, 0, 0, 3, 6);
    var _r = ai3_play_spicy(_g, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.lane, 0, "spicy: controlled centre pile -> spray it");

    // not controlling (4 < weight 5) -> no play
    var _g2 = sim_blank("familiargrotto"); _g2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g2, 0, 0, 3, 4);
    _r = ai3_play_spicy(_g2, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.lane, -1, "spicy: not controlling the tug -> no play");

    // controlled but at the home edge (dist 1) -> banks on its own, don't waste it
    var _g3 = sim_blank("familiargrotto"); _g3.treasures = [{ cards: [TW5], lane: 0, idx: 0, boss: undefined }]; sim_put(_g3, 0, 0, 0, 6);
    _r = ai3_play_spicy(_g3, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.lane, -1, "spicy: dist 1 (banks anyway) -> no play");

    // two controlled piles -> spray the RICHER one (lane index 1 = cosmicarchive 230 > totem 20)
    var _g4 = sim_blank("familiargrotto");
    _g4.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }, { cards: [TW10], lane: 1, idx: 3, boss: undefined }];
    sim_put(_g4, 0, 0, 3, 12); sim_put(_g4, 0, 1, 3, 12);
    _r = ai3_play_spicy(_g4, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.lane, 1, "spicy: two controlled -> spray the richer pile");

    // opponent out-muscling the tug -> not controlling -> no play
    var _g5 = sim_blank("familiargrotto"); _g5.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }]; sim_put(_g5, 0, 0, 3, 5); sim_put(_g5, 1, 0, 3, 6);
    _r = ai3_play_spicy(_g5, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.lane, -1, "spicy: opp out-muscles the tug -> no play");

    sim_report(_all ? "=== spicy play: ALL PASS ===" : "=== spicy play: FAILURES ABOVE ===");
    return _all;
}

function sim_test_explosive() {
    sim_report("");
    sim_report("=== SCENARIO TEST: explosive blast threat (ai3_explosive_threat) ===");
    var _all = true;
    // volatiledweevil: explosive, damage 10.
    var _g = sim_blank("familiargrotto");
    _g.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };

    _all &= sim_expect(ai3_explosive_threat(_g, 0, 0, 3), 10, "on its space -> 10");
    _all &= sim_expect(ai3_explosive_threat(_g, 0, 0, 2), 10, "adjacent idx -> 10");
    _all &= sim_expect(ai3_explosive_threat(_g, 0, 1, 3), 10, "adjacent lane -> 10");
    _all &= sim_expect(ai3_explosive_threat(_g, 0, 0, 1), 0,  "2 spaces away (outside +) -> 0");
    _all &= sim_expect(ai3_explosive_threat(_g, 0, 2, 3), 0,  "2 lanes away -> 0");
    // killed this turn -> no boom
    _all &= sim_expect(ai3_explosive_threat(_g, 0, 0, 3, [{ lane: 0, idx: 3 }]), 0, "explosive I kill this turn -> 0");

    // non-explosive enemy -> no threat
    var _g2 = sim_blank("familiargrotto");
    _g2.board.lanes[0].spaces[3].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(ai3_explosive_threat(_g2, 0, 0, 3), 0, "non-explosive enemy -> 0");

    // two explosives both adjacent to one space -> summed
    var _g3 = sim_blank("familiargrotto");
    _g3.board.lanes[0].spaces[2].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    _g3.board.lanes[0].spaces[4].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    _all &= sim_expect(ai3_explosive_threat(_g3, 0, 0, 3), 20, "two adjacent explosives -> 10+10");

    sim_report(_all ? "=== explosive threat: ALL PASS ===" : "=== explosive threat: FAILURES ABOVE ===");
    return _all;
}

function sim_test_explosive_defuse() {
    sim_report("");
    sim_report("=== SCENARIO TEST: defuse a threatening explosive (ai3_explosive_to_defuse) ===");
    var _all = true;

    // explosive on (0,3), my pikmin ON it -> defuse (idx 3)
    var _g = sim_blank("familiargrotto");
    _g.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g, 0, 0, 3, 3);
    var _r = ai3_explosive_to_defuse(_g, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "my pikmin on the explosive's space -> defuse it");

    // my pikmin ADJACENT (its blast covers them) -> still defuse
    var _g2 = sim_blank("familiargrotto");
    _g2.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g2, 0, 0, 2, 3);
    _r = ai3_explosive_to_defuse(_g2, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "my pikmin adjacent (in the blast) -> defuse");

    // my pikmin 2 away (outside the +) -> not a threat, don't waste a card
    var _g3 = sim_blank("familiargrotto");
    _g3.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g3, 0, 0, 1, 3);
    _r = ai3_explosive_to_defuse(_g3, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "my pikmin outside the blast -> no defuse");

    // explosive with NO pikmin of mine near -> not my problem
    var _g4 = sim_blank("familiargrotto");
    _g4.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    _r = ai3_explosive_to_defuse(_g4, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "explosive but no pikmin in its blast -> no defuse");

    // one I one-shot this turn -> no boom -> no defuse needed
    _r = ai3_explosive_to_defuse(_g, 0, [{ lane: 0, idx: 3 }]);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "explosive I kill this turn -> no defuse");

    // two threats -> defuse the higher-damage one (volatile d10 @ idx2 > careening d5 @ idx4)
    var _g5 = sim_blank("familiargrotto");
    _g5.board.lanes[0].spaces[2].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    _g5.board.lanes[0].spaces[4].enemy = { enemyDefId: "careeningdirigibug", curHp: 7 };
    sim_put(_g5, 0, 0, 3, 3);
    _r = ai3_explosive_to_defuse(_g5, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 2, "two threats -> defuse the higher-damage explosive");

    sim_report(_all ? "=== explosive defuse: ALL PASS ===" : "=== explosive defuse: FAILURES ABOVE ===");
    return _all;
}

function sim_test_play_freeze() {
    sim_report("");
    sim_report("=== SCENARIO TEST: ice/storm explosive defuse (ai3_play_ice / ai3_play_storm) ===");
    var _all = true;

    // ICE (size 1): explosive (0,3), my pikmin ADJACENT (0,2) - the 1-space footprint
    // on the explosive spares them -> defuse at the explosive's space
    var _g = sim_blank("familiargrotto");
    _g.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g, 0, 0, 2, 3);
    var _r = ai3_play_ice(_g, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "ice: adjacent pikmin -> freeze the explosive's space");

    // ICE unsafe: my pikmin ON the explosive -> ice would freeze them -> no play
    var _g2 = sim_blank("familiargrotto");
    _g2.board.lanes[0].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g2, 0, 0, 3, 3);
    _r = ai3_play_ice(_g2, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "ice: my pikmin on the explosive -> unsafe, no play");

    // STORM (2x2): explosive (1,3), my pikmin at (0,3) - a 2x2 can cover the explosive
    // WITHOUT my pikmin -> safe defuse exists
    var _g3 = sim_blank("familiargrotto");
    _g3.board.lanes[1].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g3, 0, 0, 3, 3);
    _r = ai3_play_storm(_g3, 0);
    _all &= sim_expect(is_undefined(_r) ? 0 : 1, 1, "storm: pikmin on one side -> a safe 2x2 exists");

    // STORM unsafe: my pikmin ON the explosive -> every covering 2x2 hits them -> no play
    var _g4 = sim_blank("familiargrotto");
    _g4.board.lanes[1].spaces[3].enemy = { enemyDefId: "volatiledweevil", curHp: 4 };
    sim_put(_g4, 0, 1, 3, 3);
    _r = ai3_play_storm(_g4, 0);
    _all &= sim_expect(is_undefined(_r) ? 0 : 1, 0, "storm: pikmin on the explosive -> no safe 2x2");

    sim_report(_all ? "=== ice/storm defuse: ALL PASS ===" : "=== ice/storm defuse: FAILURES ABOVE ===");
    return _all;
}

function sim_test_stun_deny() {
    sim_report("");
    sim_report("=== SCENARIO TEST: stun as deny/convert (ai3_play_bitter / ai3_play_ice) ===");
    var _all = true;

    // BITTER CONVERT: I have the weight (12 >= w10) but the opponent out-contests me
    // (12) -> freeze their group (bitter spares mine) so my stack carries it this turn.
    var _g = sim_blank("familiargrotto"); _g.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g, 0, 0, 3, 12); sim_put(_g, 1, 0, 3, 12);
    var _r = ai3_play_bitter(_g, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "bitter: contested pile I have weight on -> convert it");

    // BITTER DENY: opp controls (12 >= w10) and I can't out-body them (0) -> stall it.
    var _g2 = sim_blank("familiargrotto"); _g2.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g2, 1, 0, 3, 12);
    _r = ai3_play_bitter(_g2, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "bitter: opp about to carry, I can't out-body -> deny it");

    // BITTER no-op: I already control cleanly (12 vs opp 3) -> don't waste the card.
    var _g3 = sim_blank("familiargrotto"); _g3.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g3, 0, 0, 3, 12); sim_put(_g3, 1, 0, 3, 3);
    _r = ai3_play_bitter(_g3, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "bitter: I already win the tug -> no play");

    // BITTER no-op: nothing of theirs on the pile -> no play.
    var _g4 = sim_blank("familiargrotto"); _g4.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g4, 0, 0, 3, 12);
    _r = ai3_play_bitter(_g4, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "bitter: no opponent pikmin to freeze -> no play");

    // ICE DENY: opp controls (12 >= w10), I have NO pikmin near -> freeze their carry.
    var _g5 = sim_blank("familiargrotto"); _g5.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g5, 1, 0, 3, 12);
    _r = ai3_play_ice(_g5, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, 3, "ice: opp carrying, no pikmin of mine -> deny it");

    // ICE blocked: my pikmin share the pile -> ice would freeze them too -> no play.
    var _g6 = sim_blank("familiargrotto"); _g6.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g6, 1, 0, 3, 12); sim_put(_g6, 0, 0, 3, 5);
    _r = ai3_play_ice(_g6, 0);
    _all &= sim_expect(is_undefined(_r) ? -1 : _r.idx, -1, "ice: my pikmin on the pile -> won't freeze my own");

    sim_report(_all ? "=== stun deny/convert: ALL PASS ===" : "=== stun deny/convert: FAILURES ABOVE ===");
    return _all;
}

function sim_test_road_obstacles() {
    sim_report("");
    sim_report("=== SCENARIO TEST: road obstacles (ai3_road_obstacles) ===");
    var _all = true;

    var _g = sim_blank("familiargrotto");
    // paint lane 0 clear, then place: chasm @1, enemy @2 (road to a pile @4)
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "chasm", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[2].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _g.treasures = [{ cards: [TW5], lane: 0, idx: 4, boss: undefined }];
    var _obs = ai3_road_obstacles(_g, 0, 0, 4);
    _all &= sim_expect(array_length(_obs), 2, "p0 -> idx4: chasm + enemy = 2 obstacles");
    _all &= sim_expect(array_length(_obs) >= 1 ? _obs[0].kind : "", "hazard", "first obstacle is the chasm");
    _all &= sim_expect(array_length(_obs) >= 2 ? _obs[1].kind : "", "enemy",  "second obstacle is the enemy");

    // clear lane -> no obstacles
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[1].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _all &= sim_expect(array_length(ai3_road_obstacles(_g, 0, 1, 4)), 0, "clear road -> no obstacles");

    // poison terrain is SOFT (listed, but flagged non-blocking)
    _g.board.lanes[1].spaces[2] = { kind: "hazard", hazard: "poison", enemy: undefined, structure: undefined };
    var _pobs = ai3_road_obstacles(_g, 0, 1, 4);
    _all &= sim_expect(array_length(_pobs), 1, "poison on the road -> listed");
    _all &= sim_expect(array_length(_pobs) >= 1 ? (_pobs[0].soft ? 1 : 0) : -1, 1, "poison obstacle is soft");

    // direction matters: p1 comes from idx6, so the same pile-side obstacles differ.
    // pile @2, obstacles for p1 (walking 6->2): enemy @4.
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[2].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g.board.lanes[2].spaces[4].enemy = { enemyDefId: "albinodwarfbulborb", curHp: 3 };
    _all &= sim_expect(array_length(ai3_road_obstacles(_g, 1, 2, 2)), 1, "p1 6->2: one enemy on the way");

    sim_report(_all ? "=== road obstacles: ALL PASS ===" : "=== road obstacles: FAILURES ABOVE ===");
    return _all;
}

function sim_open_has(_ans, _via) {
    for (var _i = 0; _i < array_length(_ans.open); _i++) if (_ans.open[_i].via == _via) return true;
    return false;
}

function sim_test_obstacle_answers() {
    sim_report("");
    sim_report("=== SCENARIO TEST: obstacle answers (ai3_obstacle_answers) ===");
    var _all = true;
    var _sb = global.expRules.blue, _sy = global.expRules.yellow;
    global.expRules.blue = true; global.expRules.yellow = false;

    // WATER (grotto): blue crosses, red doesn't; bridge + lifeguard open it
    var _g = sim_blank("familiargrotto");
    _g.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    var _wa = ai3_obstacle_answers(_g, 0, { idx: 1, kind: "hazard", soft: false, hazard: "water" }, true);
    _all &= sim_expect(arr_has(_wa.nativeColors, "blue") ? 1 : 0, 1, "water: blue crosses natively");
    _all &= sim_expect(arr_has(_wa.nativeColors, "red")  ? 1 : 0, 0, "water: red does not");
    _all &= sim_expect(sim_open_has(_wa, "bridge")    ? 1 : 0, 1, "water: bridgeable");
    _all &= sim_expect(sim_open_has(_wa, "lifeguard") ? 1 : 0, 1, "water: lifeguard open (exp on)");

    // ICE (frigid): the CORRECTION - ice IS bridgeable; ice crosses, blue doesn't
    var _gf = sim_blank("frigidwasteland");
    _gf.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "ice", enemy: undefined, structure: undefined };
    var _ia = ai3_obstacle_answers(_gf, 0, { idx: 1, kind: "hazard", soft: false, hazard: "ice" }, true);
    _all &= sim_expect(arr_has(_ia.nativeColors, "ice")  ? 1 : 0, 1, "ice: ice pikmin cross");
    _all &= sim_expect(arr_has(_ia.nativeColors, "blue") ? 1 : 0, 0, "ice: blue does not");
    _all &= sim_expect(sim_open_has(_ia, "bridge") ? 1 : 0, 1, "ice: bridgeable (the fix)");

    // HEIGHT (scorched): reach needs a climber; stick + bridge open it
    var _gs = sim_blank("scorchedplayground");
    _gs.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "height", enemy: undefined, structure: undefined };
    var _hr = ai3_obstacle_answers(_gs, 0, { idx: 1, kind: "hazard", soft: false, hazard: "height" }, true);
    _all &= sim_expect(arr_has(_hr.nativeColors, "yellow") ? 1 : 0, 1, "height reach: yellow climbs");
    _all &= sim_expect(arr_has(_hr.nativeColors, "red")    ? 1 : 0, 0, "height reach: red can't");
    _all &= sim_expect(sim_open_has(_hr, "climbingstick") ? 1 : 0, 1, "height: stick available");
    // carry direction: height is free going home
    var _hc = ai3_obstacle_answers(_gs, 0, { idx: 1, kind: "hazard", soft: false, hazard: "height" }, false);
    _all &= sim_expect(arr_has(_hc.nativeColors, "red") ? 1 : 0, 1, "height carry: free for all going home");

    // ENEMY: nobody passes a live enemy; killing clears it
    var _ea = ai3_obstacle_answers(_g, 0, { idx: 1, kind: "enemy", soft: false, enemyDefId: "albinodwarfbulborb", curHp: 3 }, true);
    _all &= sim_expect(array_length(_ea.nativeColors), 0, "enemy: no colour passes a live enemy");
    _all &= sim_expect(sim_open_has(_ea, "kill") ? 1 : 0, 1, "enemy: cleared by killing");

    // POISON: soft - everyone passes, nothing to open
    _g.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "poison", enemy: undefined, structure: undefined };
    var _pa = ai3_obstacle_answers(_g, 0, { idx: 2, kind: "hazard", soft: true, hazard: "poison" }, true);
    _all &= sim_expect(arr_has(_pa.nativeColors, "red") ? 1 : 0, 1, "poison: non-immune still passes (soft)");
    _all &= sim_expect(array_length(_pa.open), 0, "poison: nothing to open");

    global.expRules.blue = _sb; global.expRules.yellow = _sy;
    sim_report(_all ? "=== obstacle answers: ALL PASS ===" : "=== obstacle answers: FAILURES ABOVE ===");
    return _all;
}

function sim_test_road_bridgeable() {
    sim_report("");
    sim_report("=== SCENARIO TEST: ANY hazard is bridgeable (ai3_road_turns / hazard_bridgeable fix) ===");
    var _all = true;

    // frigid: an ICE gate with no native crosser used to read ACCESS_INF (dead lane).
    // With the fix it's bridgeable -> a finite +1-turn road.
    var _g = sim_blank("frigidwasteland");
    _g.players[0].tokens = [];                                   // no ice/winged in roster
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "ice", enemy: undefined, structure: undefined };
    _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    var _rt = ai3_road_turns(_g, 0, 0, 3);
    _all &= sim_expect(_rt < ACCESS_INF ? 1 : 0, 1, "ice lane is NOT dead (bridgeable)");
    _all &= sim_expect(_rt, 1, "ice gate costs +1 turn to bridge");

    // the helper directly: bridge opens any element hazard on a bridge-board
    _all &= sim_expect(ai3_hazard_bridgeable(_g, "ice")     ? 1 : 0, 1, "ice bridgeable");
    _all &= sim_expect(ai3_hazard_bridgeable(_g, "fire")    ? 1 : 0, 1, "fire bridgeable");
    _all &= sim_expect(ai3_hazard_bridgeable(_g, "electric")? 1 : 0, 1, "electric bridgeable");

    sim_report(_all ? "=== bridgeable fix: ALL PASS ===" : "=== bridgeable fix: FAILURES ABOVE ===");
    return _all;
}

function sim_method_for(_methods, _color) {
    for (var _i = 0; _i < array_length(_methods); _i++) if (_methods[_i].color == _color) return _methods[_i];
    return undefined;
}

function sim_test_access_methods() {
    sim_report("");
    sim_report("=== SCENARIO TEST: access methods (ai3_access_methods) - the hand-analyzed lanes ===");
    var _all = true;
    var _sb = global.expRules.blue, _sy = global.expRules.yellow;
    global.expRules.blue = true; global.expRules.yellow = false;

    // helper: paint lane 0 of a board with the given hazard road, pile at idx3
    // (caller sets spaces after).

    // --- SCORCHED height lane: plain, height, height, treasure ---
    var _gs = sim_blank("scorchedplayground");
    for (var _i = 0; _i <= 6; _i++) _gs.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gs.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "height", enemy: undefined, structure: undefined };
    _gs.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "height", enemy: undefined, structure: undefined };
    _gs.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    var _m = ai3_access_methods(_gs, 0, 0, 3);
    var _my = sim_method_for(_m, "yellow"); var _mr = sim_method_for(_m, "red");
    _all &= sim_expect(is_undefined(_my) ? 0 : (_my.canCarry ? 1 : 0), 1, "scorched: yellow climbs+carries");
    _all &= sim_expect(is_undefined(_my) ? -1 : array_length(_my.builds), 0, "scorched: yellow needs no builds");
    _all &= sim_expect(is_undefined(_mr) ? 0 : (_mr.canCarry ? 1 : 0), 1, "scorched: red can bank (with structures)");
    _all &= sim_expect(is_undefined(_mr) ? -1 : array_length(_mr.builds), 2, "scorched: red bridges both heights (2)");

    // --- GROTTO water lane: plain, water, water, treasure ---
    var _gg = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gg.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gg.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gg.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gg.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _m = ai3_access_methods(_gg, 0, 0, 3);
    var _mb = sim_method_for(_m, "blue"); var _mp = sim_method_for(_m, "purple");
    _all &= sim_expect(is_undefined(_mb) ? -1 : array_length(_mb.builds), 0, "grotto: blue swims free (0 builds)");
    _all &= sim_expect(is_undefined(_mb) ? 0 : (_mb.canCarry ? 1 : 0), 1, "grotto: blue banks");
    _all &= sim_expect(is_undefined(_mp) ? -1 : array_length(_mp.builds), 2, "grotto: purple bridges both waters (2)");

    // --- FRIGID ice lane: ice, ice, water, treasure (the bridgeable-ice fix) ---
    var _gf = sim_blank("frigidwasteland");
    for (var _i = 0; _i <= 6; _i++) _gf.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gf.board.lanes[0].spaces[0] = { kind: "hazard", hazard: "ice", enemy: undefined, structure: undefined };
    _gf.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "ice", enemy: undefined, structure: undefined };
    _gf.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gf.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _m = ai3_access_methods(_gf, 0, 0, 3);
    var _mw = sim_method_for(_m, "winged"); var _mi = sim_method_for(_m, "ice"); var _mbf = sim_method_for(_m, "blue");
    _all &= sim_expect(is_undefined(_mw) ? -1 : array_length(_mw.builds), 0, "frigid: winged flies all (0 builds)");
    _all &= sim_expect(is_undefined(_mi) ? -1 : array_length(_mi.builds), 1, "frigid: ice crosses ice, bridges only the water (1)");
    _all &= sim_expect(is_undefined(_mbf) ? -1 : array_length(_mbf.builds), 2, "frigid: blue bridges the two ices (2) - ice IS bridgeable");

    // --- PLATEAU lane: enemy, fire, water, treasure ---
    var _gp = sim_blank("undergroundplateau");
    for (var _i = 0; _i <= 6; _i++) _gp.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gp.board.lanes[0].spaces[0] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gp.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "fire", enemy: undefined, structure: undefined };
    _gp.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gp.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _m = ai3_access_methods(_gp, 0, 0, 3);
    var _mpp = sim_method_for(_m, "purple");
    _all &= sim_expect(is_undefined(_mpp) ? 0 : (_mpp.canCarry ? 1 : 0), 1, "plateau: purple can bank lane 3");
    _all &= sim_expect(is_undefined(_mpp) ? -1 : array_length(_mpp.builds), 2, "plateau: purple bridges fire + water (2)");
    _all &= sim_expect(is_undefined(_mpp) ? -1 : array_length(_mpp.clears), 1, "plateau: purple clears the entry enemy (1)");

    global.expRules.blue = _sb; global.expRules.yellow = _sy;
    sim_report(_all ? "=== access methods: ALL PASS ===" : "=== access methods: FAILURES ABOVE ===");
    return _all;
}

function sim_test_growth_demand() {
    sim_report("");
    sim_report("=== SCENARIO TEST: demand-driven growth colour (ai3_growth_demand) ===");
    var _all = true;
    var _sb = global.expRules.blue; global.expRules.blue = true;

    // grotto water lane: blue banks for 0 cards -> it's the demanded colour
    var _g = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _g.treasures = [{ cards: [TW10], lane: 0, idx: 3, boss: undefined }];
    _all &= sim_expect(ai3_growth_demand(_g, 0), "blue", "water pile -> grow blue (cheapest carrier)");

    // open lane: any basic banks for 0 cards -> demand is some board basic
    var _g2 = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g2.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    var _d = ai3_growth_demand(_g2, 0);
    _all &= sim_expect(arr_has(_g2.boardDef.basicColors, _d) ? 1 : 0, 1, "open pile -> demand is a board basic");

    global.expRules.blue = _sb;
    sim_report(_all ? "=== growth demand: ALL PASS ===" : "=== growth demand: FAILURES ABOVE ===");
    return _all;
}

function sim_test_wall_off() {
    sim_report("");
    sim_report("=== SCENARIO TEST: wall-off (ai3_wall_target / phosbat) ===");
    var _all = true;

    // helper: fresh grotto with lane 0 plain + an empty enemy-slot at idx4 (opp side for p0)
    // WIN case: contested TW5 @idx3 (opp 3, I can reach 6) -> wall so I out-number the trapped 3
    var _g = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _g.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g, 1, 0, 3, 3);                       // opp 3 on the pile (not controlling w5)
    sim_put_home_col(_g, 0, "red", 6);             // I can send 6 -> beats trapped 3 + makes weight
    _g.players[0].hand = ["phosbatpod"]; _g.decks.enemy = ["albinodwarfbulborb"];
    var _wt = ai3_wall_target(_g, 0);
    _all &= sim_expect(is_undefined(_wt) ? -1 : _wt.idx, 4, "wall WIN: can out-number the trapped stack -> phosbat at idx4");

    // 1/1 MIRROR on a 1-weight pile: wall + a second body wins it (any weight is worth a pull)
    var _gm = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gm.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gm.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _gm.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gm, 1, 0, 3, 1); sim_put(_gm, 0, 0, 3, 1);   // mirror 1/1
    sim_put_home_col(_gm, 0, "red", 2);                    // a second body to add
    _gm.players[0].hand = ["phosbatpod"]; _gm.decks.enemy = ["albinodwarfbulborb"];
    _all &= sim_expect(is_undefined(ai3_wall_target(_gm, 0)) ? -1 : 1, 1, "wall WIN: 1/1 mirror, 1-weight -> still worth walling");

    // DENY case: opp CONTROLS (6 >= w5), I have no stake -> wall stops their carry
    var _gd = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gd.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gd.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _gd.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gd, 1, 0, 3, 6);
    _gd.players[0].hand = ["phosbatpod"]; _gd.decks.enemy = ["albinodwarfbulborb"];
    _all &= sim_expect(is_undefined(ai3_wall_target(_gd, 0)) ? -1 : 1, 1, "wall DENY: opp controls, I can't take it -> wall to stop the bank");

    // slot NOT pile-adjacent: enemy-slot at idx5 only (idx4 plain) -> scan finds idx5
    var _gn = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gn.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gn.board.lanes[0].spaces[5] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _gn.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gn, 1, 0, 3, 6);                       // opp controls -> deny
    _gn.players[0].hand = ["phosbatpod"]; _gn.decks.enemy = ["albinodwarfbulborb"];
    var _wn = ai3_wall_target(_gn, 0);
    _all &= sim_expect(is_undefined(_wn) ? -1 : _wn.idx, 5, "wall: non-adjacent opp-side slot -> scan finds idx5");

    // contested but I CAN'T win and they DON'T control (opp 2 < w5, I have nothing) -> skip
    var _gs = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gs.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gs.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _gs.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gs, 1, 0, 3, 2);
    _gs.players[0].hand = ["phosbatpod"]; _gs.decks.enemy = ["albinodwarfbulborb"];
    _all &= sim_expect(is_undefined(ai3_wall_target(_gs, 0)) ? -1 : 1, -1, "wall: can't win & they don't control -> no premature wall");

    // block space is plain (no enemy-slot) -> phosbat can't land there
    var _g3 = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g3.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g3.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g3, 1, 0, 3, 6);
    _g3.players[0].hand = ["phosbatpod"]; _g3.decks.enemy = ["albinodwarfbulborb"];
    _all &= sim_expect(is_undefined(ai3_wall_target(_g3, 0)) ? -1 : 1, -1, "wall: block space not an enemy-slot -> no wall");

    // don't hold phosbat -> no wall
    var _g4 = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g4.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g4.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };
    _g4.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_g4, 1, 0, 3, 6);
    _g4.players[0].hand = []; _g4.decks.enemy = ["albinodwarfbulborb"];
    _all &= sim_expect(is_undefined(ai3_wall_target(_g4, 0)) ? -1 : 1, -1, "wall: no phosbat in hand -> no wall");

    sim_report(_all ? "=== wall-off: ALL PASS ===" : "=== wall-off: FAILURES ABOVE ===");
    return _all;
}

function sim_test_achievements() {
    sim_report("");
    sim_report("=== SCENARIO TEST: achievement enumeration (ai3b_achievements, tug-axis value) ===");
    var _all = true;
    var _sb = global.expRules.blue, _sr = global.expRules.rush;
    global.expRules.blue = true; global.expRules.rush = false;      // perTurn = 1 -> deterministic

    // BANK: a controlled pile at the home edge -> W=1, moves 1 (the last), reaches home ->
    // value = V*(1/1) + V (completion bonus) = 2V
    var _gb = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gb.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gb.treasures = [{ cards: [TW1], lane: 0, idx: 0, boss: undefined }];
    sim_put(_gb, 0, 0, 0, 3);
    var _Vb = max(ai_pile_marginal(_gb, 0, _gb.treasures[0]), ai_pile_raw(_gb.treasures[0]) * 0.3);
    var _bank = undefined, _abk = ai3b_achievements(_gb, 0);
    for (var _a = 0; _a < array_length(_abk); _a++) if (_abk[_a].type == "bank") _bank = _abk[_a];
    _all &= sim_expect(is_undefined(_bank) ? -1 : round(_bank.value), round(3 * _Vb), "bank: home edge = V*1/W + 2V premium (realized + deny + freed army) = 3V");

    // CHAIN RULE: an enemy blocker respawns each day AND makes the pile an illegal destination, so
    // clearing it is worth points ONLY when the same plan also controls+carries. A pile behind a
    // killable enemy is now ONE bundled ADVANCE (clear folded in as body cost, clearIdx set) - never
    // a bare clear. TW1@3 behind a dwarf@2, enough red to clear AND lift.
    var _gA = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gA.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gA.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gA.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gA, 0, "red", 8);
    var _VA = max(ai_pile_marginal(_gA, 0, _gA.treasures[0]), ai_pile_raw(_gA.treasures[0]) * 0.3);
    var _advA = undefined, _bareA = 0, _aA = ai3b_achievements(_gA, 0);
    for (var _a = 0; _a < array_length(_aA); _a++) {
        if (_aA[_a].type == "clear" || _aA[_a].type == "chip") _bareA += 1;
        if (_aA[_a].type == "advance") _advA = _aA[_a];
    }
    _all &= sim_expect(_bareA, 0, "chain: NO standalone clear/chip achievement exists anymore");
    _all &= sim_expect(is_undefined(_advA) ? 0 : 1, 1, "chain: pile behind a killable enemy -> ONE bundled advance");
    _all &= sim_expect(is_undefined(_advA) ? -1 : _advA.clearIdx, 2, "chain: the advance carries its supply-clear (clearIdx=2)");
    _all &= sim_expect(is_undefined(_advA) ? -1 : round(_advA.value), round(_VA / 5), "chain: value = advance fraction V*1/W (W = enemy + carry4 = 5)");

    // GRIND ELIMINATION (the whole point): only enough bodies to KILL the blocker, none left to
    // control the pile -> the plan can't complete -> NO achievement at all. The old model emitted a
    // bare clear here (worth V/W) and ground the same respawning enemy every turn, never banking.
    var _gG = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gG.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gG.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gG.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];   // weight 5 -> control needs 5
    sim_put_home_col(_gG, 0, "red", 4);            // ~kills the dwarf, but <5 survivors -> can't lift
    var _prog = 0, _aG = ai3b_achievements(_gG, 0);
    for (var _a = 0; _a < array_length(_aG); _a++) if (_aG[_a].type == "clear" || _aG[_a].type == "chip" || _aG[_a].type == "advance" || _aG[_a].type == "bank") _prog += 1;
    _all &= sim_expect(_prog, 0, "grind gone: can clear but not also control -> NO achievement (was a bare-clear grind)");

    // CHIP REMOVED: a tanky enemy I can't kill this turn -> supply stays shut -> NO achievement
    // (no chip-grind: chip damage regens at day-end anyway).
    var _gc = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gc.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gc.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "armoredcannonbeetle", curHp: 25 }, structure: undefined };
    _gc.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gc, 0, "red", 2);            // 2 << req -> can't open supply
    var _prog2 = 0, _ac = ai3b_achievements(_gc, 0);
    for (var _a = 0; _a < array_length(_ac); _a++) if (_ac[_a].type == "clear" || _ac[_a].type == "chip" || _ac[_a].type == "advance" || _ac[_a].type == "bank") _prog2 += 1;
    _all &= sim_expect(_prog2, 0, "chip removed: can't kill the blocker this turn -> NO progress achievement");

    // TWO BLOCKERS: clearing the FIRST doesn't open the pile (the 2nd still stops the pour), so no
    // advance fires until the lane is down to one blocker - even with a huge army.
    var _g2 = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g2.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g2.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g2, 0, "red", 12);
    var _prog3 = 0, _a2 = ai3b_achievements(_g2, 0);
    for (var _a = 0; _a < array_length(_a2); _a++) if (_a2[_a].type == "advance" || _a2[_a].type == "bank") _prog3 += 1;
    _all &= sim_expect(_prog3, 0, "two blockers: 2nd enemy stops the pour -> no advance this turn (clear one first)");

    // FINISH-IN-TIME (never-bank discipline): a pile tugged deep on the opponent's side that can't be
    // banked before the game ends realizes NOTHING -> no advance offered, even with a huge army. The
    // SAME pile early (plenty of turns left) IS offered. This is the opportunity-cost lever cascade
    // wins on - the achievement model was chasing un-bankable deep piles with its whole army.
    var _gft = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gft.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gft.treasures = [{ cards: [TW1], lane: 0, idx: 5, boss: undefined }];   // idx5 -> carry 6 -> ~7 turns to bank
    sim_put_home_col(_gft, 0, "red", 12);
    _gft.players[0].hand = [];
    _gft.dayNumber = global.rules.days; _gft.dayTrack = global.rules.dayTrackLength;   // last turn -> ~1 turn left
    var _advLate = 0, _afl = ai3b_achievements(_gft, 0);
    for (var _a = 0; _a < array_length(_afl); _a++) if (_afl[_a].type == "advance") _advLate = 1;
    _all &= sim_expect(_advLate, 0, "finish-in-time: deep pile, out of turns -> no advance (it never banks)");
    _gft.dayNumber = 1; _gft.dayTrack = 1;                                              // early -> plenty of turns
    var _advEarly = 0, _afe = ai3b_achievements(_gft, 0);
    for (var _a = 0; _a < array_length(_afe); _a++) if (_afe[_a].type == "advance") _advEarly = 1;
    _all &= sim_expect(_advEarly, 1, "finish-in-time: same deep pile early -> advance offered (time to finish)");

    // BUILD: water lane, red only -> bridges enumerated at V/W; no advance (can't cross yet)
    var _gwat = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gwat.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gwat.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gwat.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "water", enemy: undefined, structure: undefined };
    _gwat.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gwat, 0, "red", 12);
    var _bld = undefined, _advWat = 0, _aw = ai3b_achievements(_gwat, 0);
    for (var _a = 0; _a < array_length(_aw); _a++) { if (_aw[_a].type == "build") _bld = _aw[_a]; if (_aw[_a].type == "advance" || _aw[_a].type == "bank") _advWat += 1; }
    _all &= sim_expect(is_undefined(_bld) ? 0 : 1, 1, "build: bridges enumerated for the red method");
    _all &= sim_expect(_advWat, 0, "water lane, red can't cross -> no advance (bridge first)");

    // DEEP unwinnable: opp controls the pile with 12, I can bring 4 -> can't out-muscle -> 0 spaces -> no advance
    var _gd = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gd.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gd.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gd, 1, 0, 3, 12); sim_put_home_col(_gd, 0, "red", 4);
    var _advD = 0, _ad = ai3b_achievements(_gd, 0);
    for (var _a = 0; _a < array_length(_ad); _a++) if (_ad[_a].type == "advance" || _ad[_a].type == "bank") _advD += 1;
    _all &= sim_expect(_advD, 0, "can't out-muscle -> it moves 0 spaces -> no advance (no gate, just 0 value)");

    // LOCK RULE: a contested pile (opp has IN-LANE reserve that can re-contest) advances only
    // if I OVERCOMMIT past that reserve. TW1 pile @3, opp 5 sitting at idx2 (reserve, not on it).
    var _glk = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _glk.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _glk.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put(_glk, 1, 0, 2, 5);                      // opp 5 in the lane (can re-contest)
    sim_put_home_col(_glk, 0, "red", 8);            // 8 >= 5+1 -> can LOCK it
    var _advLk = 0, _alk = ai3b_achievements(_glk, 0);
    for (var _a = 0; _a < array_length(_alk); _a++) if (_alk[_a].type == "advance") _advLk = 1;
    _all &= sim_expect(_advLk, 1, "lock: overcommit past the opp's lane reserve -> advance scores");

    var _gum = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gum.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gum.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gum, 1, 0, 2, 5);                      // opp 5 in the lane
    sim_put_home_col(_gum, 0, "red", 3);            // 3 < 5+1 -> can't lock -> it would just oscillate
    var _advUm = 0, _aum = ai3b_achievements(_gum, 0);
    for (var _a = 0; _a < array_length(_aum); _a++) if (_aum[_a].type == "advance") _advUm = 1;
    _all &= sim_expect(_advUm, 0, "lock: can't overcommit past the reserve -> no advance (would just re-contest)");

    // ITEM-LOCK (freeze is one-turn -> SNIPE-only): a NEAR-HOME pile (carry 1, bankable this turn) the
    // opp controls; I can bring only 5 (< overcommit 6), but a held bitter freezes their stack so I
    // lift+bank it in one turn. A freeze can't lock a multi-turn haul (it wears off) - hence near-home.
    var _gil = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gil.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gil.treasures = [{ cards: [TW5], lane: 0, idx: 0, boss: undefined }];   // home edge -> carry 1 -> snipeable
    sim_put(_gil, 1, 0, 0, 5);                      // opp controls it (bitter can deny)
    sim_put_home_col(_gil, 0, "red", 5);            // 5 < overcommit 6, but == lift 5
    _gil.players[0].hand = [];
    var _advNoItem = 0, _an = ai3b_achievements(_gil, 0);
    for (var _a = 0; _a < array_length(_an); _a++) if (_an[_a].type == "bank" || _an[_a].type == "advance") _advNoItem = 1;
    _all &= sim_expect(_advNoItem, 0, "item-lock: no freeze -> can't out-muscle -> no snipe");
    _gil.players[0].hand = ["bitterspray"];         // now a freeze locks the one-turn grab
    var _advItem = 0, _ai2 = ai3b_achievements(_gil, 0);
    for (var _a = 0; _a < array_length(_ai2); _a++) if (_ai2[_a].type == "bank" || _ai2[_a].type == "advance") _advItem = 1;
    _all &= sim_expect(_advItem, 1, "item-lock: hold a bitter that targets it -> freeze locks the one-turn snipe -> banks");

    // WALL-LOCK (lever 2): opp 3 on the pile + 5 reserve at idx2 (whole lane 8). I bring 5 - can't
    // overcommit 9, but a phosbat walls idx4 behind the pile (cuts the reserve) so I only need oppS+1=4.
    var _gwl = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gwl.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gwl.board.lanes[0].spaces[4] = { kind: "enemy", hazard: "", enemy: undefined, structure: undefined };   // wall goes here
    _gwl.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gwl, 1, 0, 3, 3); sim_put(_gwl, 1, 0, 2, 5);   // opp 3 on it + 5 reserve
    sim_put_home_col(_gwl, 0, "red", 5);
    _gwl.decks.enemy = ["albinodwarfbulborb"];
    _gwl.players[0].hand = [];
    var _advNoW = 0, _anw = ai3b_achievements(_gwl, 0);
    for (var _a = 0; _a < array_length(_anw); _a++) if (_anw[_a].type == "advance") _advNoW = 1;
    _all &= sim_expect(_advNoW, 0, "wall-lock: no phosbat, 5 < overcommit 9 -> no advance");
    _gwl.players[0].hand = ["phosbatpod"];
    var _advW2 = 0, _aw3 = ai3b_achievements(_gwl, 0);
    for (var _a = 0; _a < array_length(_aw3); _a++) if (_aw3[_a].type == "advance") _advW2 = 1;
    _all &= sim_expect(_advW2, 1, "wall-lock: phosbat walls behind it -> only out-muscle the current stack -> advance scores");

    // SNIPE (reach-based bank): a contested near-home pile I do NOT yet control - bringing enough to
    // out-bid their IN-LANE strength banks it THIS turn (before they can respond). The old model only
    // banked a pile it ALREADY controlled, so it could never grab a fresh pile decisively (the miss).
    var _gsnA = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gsnA.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gsnA.treasures = [{ cards: [TW1], lane: 0, idx: 0, boss: undefined }];  // carry 1 -> bankable this turn
    sim_put(_gsnA, 1, 0, 0, 3);                     // opp 3 on it; I hold none
    _gsnA.players[0].hand = [];
    sim_put_home_col(_gsnA, 0, "red", 3);           // 3 < out-bid 4 -> can't grab
    var _snLo = 0, _asl = ai3b_achievements(_gsnA, 0);
    for (var _a = 0; _a < array_length(_asl); _a++) if (_asl[_a].type == "bank") _snLo = 1;
    _all &= sim_expect(_snLo, 0, "snipe: 3 red < out-bid their in-lane 3 -> no one-turn grab");
    var _gsnB = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gsnB.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gsnB.treasures = [{ cards: [TW1], lane: 0, idx: 0, boss: undefined }];
    sim_put(_gsnB, 1, 0, 0, 3);
    _gsnB.players[0].hand = [];
    sim_put_home_col(_gsnB, 0, "red", 5);           // 5 >= out-bid 4 -> snipe banks it, though I pre-control none
    var _snHi = 0, _ash = ai3b_achievements(_gsnB, 0);
    for (var _a = 0; _a < array_length(_ash); _a++) if (_ash[_a].type == "bank") _snHi = 1;
    _all &= sim_expect(_snHi, 1, "snipe: 5 red out-bid their in-lane 3 -> bank in one turn (didn't pre-control)");

    global.expRules.blue = _sb; global.expRules.rush = _sr;
    sim_report(_all ? "=== achievements: ALL PASS ===" : "=== achievements: FAILURES ABOVE ===");
    return _all;
}

function sim_test_item_achievements() {
    sim_report("");
    sim_report("=== SCENARIO TEST: item achievements (ai3b_deny_value / ai3b_item_achievements) ===");
    var _all = true;
    var _sb = global.expRules.blue, _sr = global.expRules.rush;
    global.expRules.blue = true; global.expRules.rush = false;

    // DENY value: stopping a carry NEAR the opponent's home (small remaining axis) is worth
    // more than stopping a deep one.  opp = player 1 (home idx6).
    var _gn = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gn.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gn.treasures = [{ cards: [TW5], lane: 0, idx: 5, boss: undefined }];   // near opp home
    sim_put(_gn, 1, 0, 5, 8);
    var _dn = ai3b_deny_value(_gn, 0, _gn.treasures[0]);

    var _gf = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gf.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gf.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];   // centre (deeper for them)
    sim_put(_gf, 1, 0, 3, 8);
    var _df = ai3b_deny_value(_gf, 0, _gf.treasures[0]);
    _all &= sim_expect((_dn > _df) ? 1 : 0, 1, "deny: stopping a near-home bank worth more than a deep one");

    // DENY 0 when they don't control it (no carry to stop)
    var _gu = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gu.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gu.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gu, 1, 0, 3, 2);                                // 2 < weight 5 -> not controlling
    _all &= sim_expect(ai3b_deny_value(_gu, 0, _gu.treasures[0]), 0, "deny: opp doesn't control -> 0");

    // ITEM enumeration: hold bitter + opp carrying a pile -> a bitter deny item achievement
    var _gi = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gi.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gi.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gi, 1, 0, 3, 8);                                // opp carrying -> bitter can deny it
    _gi.players[0].hand = ["bitterspray"];
    var _hasBitter = 0, _its = ai3b_item_achievements(_gi, 0);
    for (var _i = 0; _i < array_length(_its); _i++) if (_its[_i].type == "item" && _its[_i].play == "bitterspray") _hasBitter = 1;
    _all &= sim_expect(_hasBitter, 1, "item: hold bitter + opp carrying -> bitter deny achievement (0 bodies)");

    // no relevant items in hand -> no item achievements
    var _ge = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _ge.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _ge.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put(_ge, 1, 0, 3, 8);
    _ge.players[0].hand = ["surveydrone"];                   // not a deny/wall item we enumerate yet
    _all &= sim_expect(array_length(ai3b_item_achievements(_ge, 0)), 0, "item: no freeze/wall in hand -> none");

    global.expRules.blue = _sb; global.expRules.rush = _sr;
    sim_report(_all ? "=== item achievements: ALL PASS ===" : "=== item achievements: FAILURES ABOVE ===");
    return _all;
}

function sim_test_ach_optimize() {
    sim_report("");
    sim_report("=== SCENARIO TEST: achievement optimizer (ai3b_optimize) ===");
    var _all = true;

    // THE case greedy gets wrong: budget 10. Greedy-by-value takes the 100 (10 bodies) = 100.
    // The exact knapsack takes 60+60 (5+5 bodies) = 120. The optimizer must find 120.
    var _achs = [
        { type: "clear", lane: 1, idx: 1, value: 100, bodies: 10, cards: 0 },
        { type: "clear", lane: 2, idx: 1, value: 60,  bodies: 5,  cards: 0 },
        { type: "clear", lane: 3, idx: 1, value: 60,  bodies: 5,  cards: 0 },
    ];
    var _ch = ai3b_optimize(_achs, 10, 0);
    var _tot = 0; for (var _i = 0; _i < array_length(_ch); _i++) _tot += _ch[_i].value;
    _all &= sim_expect(_tot, 120, "optimize: knapsack beats greedy (60+60 > 100)");

    // free (0-body) bank always taken; an unaffordable clear is dropped
    var _achs2 = [
        { type: "bank",  lane: 0, idx: 0, value: 100, bodies: 0,  cards: 0 },
        { type: "clear", lane: 1, idx: 1, value: 50,  bodies: 20, cards: 0 },
    ];
    var _ch2 = ai3b_optimize(_achs2, 5, 0);
    var _hasBank = 0, _hasClear = 0;
    for (var _i = 0; _i < array_length(_ch2); _i++) { if (_ch2[_i].type == "bank") _hasBank = 1; if (_ch2[_i].type == "clear") _hasClear = 1; }
    _all &= sim_expect(_hasBank, 1, "optimize: free bank always taken");
    _all &= sim_expect(_hasClear, 0, "optimize: unaffordable clear dropped");

    // builds use the CARD budget, not bodies
    var _achs3 = [{ type: "build", lane: 0, idx: 1, value: 80, bodies: 0, cards: 2 }];
    _all &= sim_expect(array_length(ai3b_optimize(_achs3, 0, 2)), 1, "optimize: build taken with 2 rawmaterial");
    _all &= sim_expect(array_length(ai3b_optimize(_achs3, 0, 1)), 0, "optimize: build dropped with only 1 rawmaterial");

    sim_report(_all ? "=== ach optimize: ALL PASS ===" : "=== ach optimize: FAILURES ABOVE ===");
    return _all;
}

/// v4 brick 1 — the value core: m(endSpace) curve, escalating removal stack, grab.
function sim_test_v4_value() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 value core (ai4_move_mult / removal_stack / grab) ===");
    var _all = true;

    // m-curve, player 0 (home = low idx): +0.25 / space toward home, floor 1.0, bank 2.0
    _all &= sim_expect(ai4_move_mult(0, 3),  1.00, "m: p0 centre idx3 = 1.00");
    _all &= sim_expect(ai4_move_mult(0, 2),  1.25, "m: p0 idx2 = 1.25");
    _all &= sim_expect(ai4_move_mult(0, 1),  1.50, "m: p0 idx1 = 1.50");
    _all &= sim_expect(ai4_move_mult(0, 0),  1.75, "m: p0 idx0 = 1.75");
    _all &= sim_expect(ai4_move_mult(0, -1), 2.00, "m: p0 banked (off edge) = 2.00");
    _all &= sim_expect(ai4_move_mult(0, 5),  1.00, "m: p0 far half idx5 = 1.00 (floored)");
    // mirror for player 1 (home = high idx)
    _all &= sim_expect(ai4_move_mult(1, 3),  1.00, "m: p1 centre = 1.00");
    _all &= sim_expect(ai4_move_mult(1, 4),  1.25, "m: p1 idx4 = 1.25");
    _all &= sim_expect(ai4_move_mult(1, 6),  1.75, "m: p1 idx6 = 1.75");
    _all &= sim_expect(ai4_move_mult(1, 7),  2.00, "m: p1 banked = 2.00");
    _all &= sim_expect(ai4_move_mult(1, 1),  1.00, "m: p1 far half = 1.00 (floored)");

    // escalating removal stack: grab 120 over 3 open tasks (the crowded-lane crack)
    _all &= sim_expect(ai4_removal_stack(120, 3, 1),  40, "stack: 1 of 3 = grab/3 = 40");
    _all &= sim_expect(ai4_removal_stack(120, 3, 2), 100, "stack: 2 of 3 = grab/3 + grab/2 = 100");
    _all &= sim_expect(ai4_removal_stack(120, 3, 3), 220, "stack: 3 of 3 = grab(1/3+1/2+1)=220 (> flat grab 120)");
    _all &= sim_expect(ai4_removal_stack(120, 1, 1), 120, "stack: last task in a 1-task lane = full grab");

    // grab ties to the pile's position: centred grab = V, advanced grab = V x m
    var _gv = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gv.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gv.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    var _V = ai4_pile_value(_gv, 0, _gv.treasures[0]);
    _all &= sim_expect(ai4_grab_value(_gv, 0, _gv.treasures[0]), _V, "grab: centred pile grab = V");
    _gv.treasures[0].idx = 1;
    _all &= sim_expect(ai4_grab_value(_gv, 0, _gv.treasures[0]), _V * 1.5, "grab: pile advanced to idx1 -> grab = 1.5V");

    sim_report(_all ? "=== v4 value core: ALL PASS ===" : "=== v4 value core: FAILURES ABOVE ===");
    return _all;
}

/// v4 brick 2a — removal outcome enumeration (fundable-only, escalation inputs).
function sim_test_v4_removals() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 removal outcomes (ai4_lane_removals) ===");
    var _all = true;

    // two dwarves on the road; pikmin can only pay the FIRST -> 1 outcome, nOpen counts BOTH
    var _g2 = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _g2.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g2.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g2, 0, "red", 8);
    _g2.players[0].hand = [];
    var _r2 = ai4_lane_removals(_g2, 0, _g2.treasures[0]);
    _all &= sim_expect(array_length(_r2), 1, "removals: 2 dwarves, pikmin reaches only the first -> 1 outcome");
    _all &= sim_expect(array_length(_r2) > 0 ? _r2[0].nOpen : -1, 2, "removals: nOpen counts BOTH tasks (divisor stays 2)");

    // give a bomb -> the second (unreachable) enemy becomes payable by item -> 2 outcomes
    _g2.players[0].hand = ["bombrock"];
    var _r2b = ai4_lane_removals(_g2, 0, _g2.treasures[0]);
    _all &= sim_expect(array_length(_r2b), 2, "removals: + a bomb opens the deep enemy (no path needed) -> 2 outcomes");

    // CHASM gaps (no fieldable colour crosses) bridge with raw material; both enumerated. WATER on
    // grotto is crossable via blue (a board basic -> pellet-fieldable) = a USELESS task: excluded.
    var _gw = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gw.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gw.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "chasm", enemy: undefined, structure: undefined };
    _gw.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "chasm", enemy: undefined, structure: undefined };
    _gw.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gw, 0, "red", 8);
    _gw.players[0].hand = ["rawmaterial", "rawmaterial"];
    var _rw = ai4_lane_removals(_gw, 0, _gw.treasures[0]);
    _all &= sim_expect(array_length(_rw), 2, "removals: two chasm gaps, both bridgeable with raw material -> 2 outcomes");
    _gw.board.lanes[0].spaces[1].hazard = "water"; _gw.board.lanes[0].spaces[2].hazard = "water";
    _all &= sim_expect(array_length(ai4_lane_removals(_gw, 0, _gw.treasures[0])), 0, "removals: water crossable via a fieldable basic -> useless tasks, nothing to remove");

    // REACHABLE but unaffordable: a tanky beetle red can hurt+reach but not out-strength with 2.
    // Enumeration is now REACHABILITY-based (pellets could fund it later), so it IS enumerated;
    // affordability is the OPTIMIZER/funding's job, and there it gets dropped.
    var _gu = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gu.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gu.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "armoredcannonbeetle", curHp: 25 }, structure: undefined };
    _gu.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gu, 0, "red", 2);
    _gu.players[0].hand = []; _gu.players[0].pellets = [];
    _all &= sim_expect(array_length(ai4_lane_removals(_gu, 0, _gu.treasures[0])), 1, "removals: reachable enemy IS enumerated (affordability is funding's job, not enumeration's)");
    _all &= sim_expect(array_length(ai4_optimize(_gu, 0).chosen), 0, "removals: ...but the optimizer won't fund a 25-strength kill with 2 red + no pellets");

    // boss on the pile: one removal, nOpen 1, grab = the treasure underneath (the cheat)
    var _gb = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gb.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gb.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: { enemyDefId: "armoredcannonbeetle", curHp: 25 } }];
    sim_put_home_col(_gb, 0, "red", 30);
    _gb.players[0].hand = [];
    var _rb = ai4_lane_removals(_gb, 0, _gb.treasures[0]);
    _all &= sim_expect(array_length(_rb), 1, "removals: boss is one removal outcome");
    _all &= sim_expect(array_length(_rb) > 0 ? _rb[0].nOpen : -1, 1, "removals: boss lane nOpen = 1");
    _all &= sim_expect((array_length(_rb) > 0 && _rb[0].boss) ? 1 : 0, 1, "removals: boss flagged (grab = treasure underneath)");

    // FIELDABLE colours only (minefield loop): enemy behind a chasm on a red/white/rock board -
    // exp-yellow could path there, but yellow is NOT fieldable (not owned, not a basic) -> no
    // phantom pikmin outcome. A bomb (no path needed) still opens it.
    var _gmf = sim_blank("theminefield");
    for (var _i = 0; _i <= 6; _i++) _gmf.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gmf.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "chasm", enemy: undefined, structure: undefined };
    _gmf.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gmf.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gmf.players[0].tokens = []; sim_put_home_col(_gmf, 0, "red", 8);
    _gmf.players[0].hand = []; _gmf.players[0].pellets = [];
    var _rmf = ai4_lane_removals(_gmf, 0, _gmf.treasures[0]);
    var _mfPik = 0;
    for (var _i = 0; _i < array_length(_rmf); _i++) { var _vv = _rmf[_i].variants;
        for (var _v = 0; _v < array_length(_vv); _v++) if (_vv[_v].str > 0) _mfPik = 1; }
    _all &= sim_expect(_mfPik, 0, "fieldable: chasm-locked enemy, no fieldable colour paths -> no phantom pikmin outcome");
    _gmf.players[0].hand = ["bombrock"];
    _all &= sim_expect(array_length(ai4_lane_removals(_gmf, 0, _gmf.treasures[0])) >= 1, true, "fieldable: a bomb (no path) still opens it");

    // MINES: an armed mine on my road is a task; its removal = 1 sacrificial body. A carry that
    // would end riders on a live/armable mine is not offered; clear it and the move opens.
    var _gmn = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gmn.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gmn.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gmn.players[0].tokens = []; sim_put_home_col(_gmn, 0, "red", 8);
    _gmn.players[0].hand = []; _gmn.players[0].pellets = [];
    _gmn.mines = [{ lane: 0, idx: 1, dmg: 10 }];                     // armed, on my carry path
    var _rmn = ai4_lane_removals(_gmn, 0, _gmn.treasures[0]);
    var _mnOk = 0;
    for (var _i = 0; _i < array_length(_rmn); _i++) { var _vv = _rmn[_i].variants;
        for (var _v = 0; _v < array_length(_vv); _v++) if (_vv[_v].str == 1) _mnOk = 1; }
    _all &= sim_expect(_mnOk, 1, "mine: armed mine is a removal task - detonate with 1 sacrificial body");
    _all &= sim_expect(array_length(ai4_lane_moves(_gmn, 0, _gmn.treasures[0])), 0, "mine: carry over a live mine would wipe the riders -> move not offered");
    _gmn.mines = [];
    _all &= sim_expect(array_length(ai4_lane_moves(_gmn, 0, _gmn.treasures[0])), 1, "mine: cleared -> the move opens");
    _gmn.mines = [{ lane: 0, idx: 1, dmg: 2 }];                      // unarmed, my 5-deploy keeps it under 10
    _all &= sim_expect(array_length(ai4_lane_moves(_gmn, 0, _gmn.treasures[0])) >= 1, true, "mine: unarmed + small deploy stays under 10 -> carry safe, move offered");
    _gmn.mines = [{ lane: 0, idx: 1, dmg: 6 }];                      // 6 + deploy 5 >= 10 -> my own march arms it
    _all &= sim_expect(array_length(ai4_lane_moves(_gmn, 0, _gmn.treasures[0])), 0, "mine: my own deploy would arm it -> move not offered");

    // DEATH-SPIRAL guard: army wiped to 0, pellets in hand -> a kill must STILL be enumerated and
    // funded (ai_can_group_hurt read owned tokens and bricked the brain for the rest of the game).
    var _gds = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gds.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gds.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gds.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gds.players[0].tokens = [];                                     // the whole army is DEAD
    _gds.players[0].pellets = ["red5"]; _gds.players[0].hand = [];
    var _ods = ai4_optimize(_gds, 0);
    _all &= sim_expect(array_length(_ods.chosen) >= 1, true, "death-spiral: army 0 + a red5 pellet -> the kill is still enumerated AND funded");

    sim_report(_all ? "=== v4 removal outcomes: ALL PASS ===" : "=== v4 removal outcomes: FAILURES ABOVE ===");
    return _all;
}

/// v4 brick 2b — move outcome enumeration (securing folded in, carry value, oatchi).
function sim_test_v4_moves() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 move outcomes (ai4_lane_moves) ===");
    var _all = true;
    var _sr = global.expRules.rush; global.expRules.rush = false;   // deterministic: baseSteps = 1

    // UNCONTESTED carry: pile TW1@centre, road clear, 8 red, no opponent anywhere.
    // min-win only (no buffer), carries 1 space to idx2 -> value V x 1.25.
    var _gu = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gu.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gu.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gu, 0, "red", 8);
    _gu.players[0].hand = [];
    var _Vu = ai4_pile_value(_gu, 0, _gu.treasures[0]);
    var _mu = ai4_lane_moves(_gu, 0, _gu.treasures[0]);
    _all &= sim_expect(array_length(_mu), 1, "move: open uncontested lane -> one move outcome");
    var _minWinOk = 0, _valOk = 0;
    if (array_length(_mu) > 0) { var _vu = _mu[0].variants;
        for (var _v = 0; _v < array_length(_vu); _v++) {
            if (_vu[_v].str == 1 && _vu[_v].endIdx == 2) _minWinOk = 1;
            if (_vu[_v].endIdx == 2 && _vu[_v].value == _Vu * 1.25) _valOk = 1;
        } }
    _all &= sim_expect(_minWinOk, 1, "move: uncontested -> min-win (str 1), lands idx2");
    _all &= sim_expect(_valOk, 1, "move: value = V x m(idx2) = 1.25V");

    // CONTESTED haul: opp 3 reserve in-lane -> min-win(1) + buffer(4) = str 5 (no bank this turn)
    var _gc = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gc.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gc.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put(_gc, 1, 0, 2, 3);                       // opponent reserve that can re-contest
    sim_put_home_col(_gc, 0, "red", 12);
    _gc.players[0].hand = [];
    var _mc = ai4_lane_moves(_gc, 0, _gc.treasures[0]);
    var _bufOk = 0;
    if (array_length(_mc) > 0) { var _vc = _mc[0].variants;
        for (var _v = 0; _v < array_length(_vc); _v++) if (_vc[_v].str == 5) _bufOk = 1; }
    _all &= sim_expect(_bufOk, 1, "move: contested haul -> min-win + buffer = str 5");

    // BANK this turn: pile at my home edge -> banks regardless of contest, no buffer, value 2V
    var _gb = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gb.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gb.treasures = [{ cards: [TW1], lane: 0, idx: 0, boss: undefined }];
    sim_put(_gb, 1, 0, 1, 3);                       // they have reserve, but can't answer before it banks
    sim_put_home_col(_gb, 0, "red", 5);
    _gb.players[0].hand = [];
    var _Vb = ai4_pile_value(_gb, 0, _gb.treasures[0]);
    var _mb = ai4_lane_moves(_gb, 0, _gb.treasures[0]);
    var _bankOk = 0;
    if (array_length(_mb) > 0) { var _vb = _mb[0].variants;
        for (var _v = 0; _v < array_length(_vb); _v++) if (_vb[_v].str == 1 && _vb[_v].value == _Vb * 2.0) _bankOk = 1; }
    _all &= sim_expect(_bankOk, 1, "move: banking this turn -> out-muscle current only (str 1), value 2V");

    // OATCHI jump: treasure on the far side, oatchirush in hand, no bodies -> a 2-space jump for free
    var _go = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _go.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _go.treasures = [{ cards: [TW1], lane: 0, idx: 4, boss: undefined }];
    _go.players[0].hand = ["oatchirush"];
    var _mo = ai4_lane_moves(_go, 0, _go.treasures[0]);
    var _oatOk = 0;
    if (array_length(_mo) > 0) { var _vo = _mo[0].variants;
        for (var _v = 0; _v < array_length(_vo); _v++) if (_vo[_v].str == 0 && arr_has(_vo[_v].items, "oatchirush") && _vo[_v].endIdx == 2) _oatOk = 1; }
    _all &= sim_expect(_oatOk, 1, "move: oatchi jumps the far-side pile 2 spaces (idx4->idx2), no control needed");

    // RESOURCE DESIGNATION (ruling): an all-white 2-step is only offered BOUND to white funding
    var _gwh = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gwh.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gwh.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gwh, 0, "white", 6);
    _gwh.players[0].hand = [];
    var _mwh = ai4_lane_moves(_gwh, 0, _gwh.treasures[0]);
    var _whOk = 0;
    if (array_length(_mwh) > 0) { var _vw = _mwh[0].variants;
        for (var _v = 0; _v < array_length(_vw); _v++)
            if (_vw[_v].endIdx == 1 && variable_struct_exists(_vw[_v], "cols") && array_length(_vw[_v].cols) == 1 && _vw[_v].cols[0] == "white") _whOk = 1; }
    _all &= sim_expect(_whOk, 1, "designation: all-white 2-step offered, BOUND to white-only funding (idx3->idx1)");

    // RESOURCE DESIGNATION: a rush variant funds purple-free (purple cancels rush)
    global.expRules.rush = true;
    var _gru = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gru.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gru.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gru, 0, "red", 12); sim_put_home_col(_gru, 0, "purple", 2);
    _gru.players[0].hand = [];
    var _mru = ai4_lane_moves(_gru, 0, _gru.treasures[0]);
    var _ruOk = 0;
    if (array_length(_mru) > 0) { var _vr = _mru[0].variants;
        for (var _v = 0; _v < array_length(_vr); _v++)
            if (_vr[_v].endIdx == 1 && variable_struct_exists(_vr[_v], "cols") && !arr_has(_vr[_v].cols, "purple") && _vr[_v].str >= 10) _ruOk = 1; }
    _all &= sim_expect(_ruOk, 1, "designation: rush 2-step demands 2x weight, funded purple-free");
    global.expRules.rush = false;

    // RESPAWN ruling: an enemy kill on the LAST turn of the day = salvage 20 (any other turn: full value)
    var _gst = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gst.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gst.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gst.treasures = [{ cards: [TW5, TW5, TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_gst, 0, "red", 8);
    _gst.players[0].hand = []; _gst.players[0].pellets = [];
    _gst.dayTrack = global.rules.dayTrackLength;
    _all &= sim_expect(round(ai4_optimize(_gst, 0).value), 20, "respawn: last-turn-of-day enemy kill = salvage 20");
    _gst.dayTrack = 1;
    _all &= sim_expect(ai4_optimize(_gst, 0).value > 20, true, "respawn: any earlier turn -> full kill value");

    global.expRules.rush = _sr;

    // HOLD (contested-pile ruling): a pile I control, ADVANCED behind a blocking enemy (carriers can't
    // reach it -> no advance move), that the opponent can still contest -> a HOLD outcome worth V,
    // so I don't strip the lifters (== -V for abandoning it). Uncontested -> no hold (lifters free).
    var _gh = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gh.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gh.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };  // blocks home->idx2
    _gh.treasures = [{ cards: [TW5], lane: 0, idx: 2, boss: undefined }];   // pile advanced to idx2
    _gh.players[0].tokens = []; sim_put(_gh, 0, 0, 2, 6);                   // my 6 lifters ON the pile
    _gh.players[1].tokens = []; sim_put_home_col(_gh, 1, "red", 8);         // opponent can march to contest
    var _mh = ai4_lane_moves(_gh, 0, _gh.treasures[0]);
    _all &= sim_expect(array_length(_mh), 1, "hold: blocked+controlled+contested pile -> a hold move is offered");
    if (array_length(_mh) > 0) {
        _all &= sim_expect(_mh[0].variants[0].endIdx, 2, "hold: holds in place (endIdx = current idx2)");
        _all &= sim_expect((variable_struct_exists(_mh[0].variants[0], "hold") && _mh[0].variants[0].hold) ? 1 : 0, 1, "hold: flagged as a hold");
        _all &= sim_expect(round(_mh[0].variants[0].value), round(ai4_pile_value(_gh, 0, _gh.treasures[0])), "hold: worth the pile's value V");
    }
    _gh.players[1].tokens = [];                                            // uncontested
    _all &= sim_expect(array_length(ai4_lane_moves(_gh, 0, _gh.treasures[0])), 0, "hold: uncontested pile -> no hold (lifters are true surplus)");

    sim_report(_all ? "=== v4 move outcomes: ALL PASS ===" : "=== v4 move outcomes: FAILURES ABOVE ===");
    return _all;
}

/// v4 brick 3 — joint funding (ai4_can_fund): colour pool + pellet conversion + items.
function sim_test_v4_funding() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 funding (ai4_can_fund) ===");
    var _all = true;
    var _any = ["red", "blue", "yellow", "purple", "white", "rock", "ice", "winged"];

    var _g = sim_blank("familiargrotto");
    sim_put_home_col(_g, 0, "red", 8);
    _g.players[0].pellets = []; _g.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_g, 0, [{ str: 5, colors: _any }], {}) ? 1 : 0, 1, "fund: 8 home strength pays a 5 demand");
    _all &= sim_expect(ai4_can_fund(_g, 0, [{ str: 12, colors: _any }], {}) ? 1 : 0, 0, "fund: 8 can't pay 12");
    _all &= sim_expect(ai4_can_fund(_g, 0, [{ str: 5, colors: _any }, { str: 5, colors: _any }], {}) ? 1 : 0, 0, "fund: two 5-demands (=10) > 8 home -> infeasible");
    _g.players[0].pellets = ["red5"];
    _all &= sim_expect(ai4_can_fund(_g, 0, [{ str: 5, colors: _any }, { str: 5, colors: _any }], {}) ? 1 : 0, 1, "fund: + a red5 pellet (5) -> the pair is jointly fundable");

    // forced colour: red at home can't pay a blue-only demand, a blue pellet can
    var _gb = sim_blank("familiargrotto");
    sim_put_home_col(_gb, 0, "red", 8); _gb.players[0].pellets = []; _gb.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_gb, 0, [{ str: 3, colors: ["blue"] }], {}) ? 1 : 0, 0, "fund: blue-forced demand, only red at home -> infeasible");
    _gb.players[0].pellets = ["blue5"];
    _all &= sim_expect(ai4_can_fund(_gb, 0, [{ str: 3, colors: ["blue"] }], {}) ? 1 : 0, 1, "fund: a blue5 pellet pays the blue demand");

    // off-conversion: a red5 pellet becomes 2 of any other colour (off-rate)
    var _go = sim_blank("familiargrotto");
    _go.players[0].tokens = []; _go.players[0].pellets = ["red5"]; _go.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_go, 0, [{ str: 2, colors: ["blue"] }], {}) ? 1 : 0, 1, "fund: red5 off-converts to 2 blue -> pays a 2 demand");
    _all &= sim_expect(ai4_can_fund(_go, 0, [{ str: 3, colors: ["blue"] }], {}) ? 1 : 0, 0, "fund: one off-conversion (2) can't pay a 3 demand");

    // purple carry: 2 purples = 10 strength
    var _gp = sim_blank("familiargrotto");
    _gp.players[0].tokens = []; sim_put_home_col(_gp, 0, "purple", 2); _gp.players[0].pellets = []; _gp.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_gp, 0, [{ str: 10, colors: ["purple"] }], {}) ? 1 : 0, 1, "fund: 2 purples = 10 strength");

    // item multiset: two bridges need 4 raw material
    var _gi = sim_blank("familiargrotto");
    sim_put_home_col(_gi, 0, "red", 8); _gi.players[0].pellets = [];
    _gi.players[0].hand = ["rawmaterial", "rawmaterial", "rawmaterial"];
    _all &= sim_expect(ai4_can_fund(_gi, 0, [], { rawmaterial: 4 }) ? 1 : 0, 0, "fund: 3 raw material can't build 2 bridges (need 4)");
    _gi.players[0].hand = ["rawmaterial", "rawmaterial", "rawmaterial", "rawmaterial"];
    _all &= sim_expect(ai4_can_fund(_gi, 0, [], { rawmaterial: 4 }) ? 1 : 0, 1, "fund: 4 raw material builds 2 bridges");

    // TREASURE-LIFTER: carriers on a pile ARE reassignable surplus - they fund elsewhere AND
    // ai4_send2 can pull them (players swap lifters). No phantom: funding and deploy agree.
    var _gdt = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gdt.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gdt.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gdt.players[0].tokens = []; sim_put(_gdt, 0, 0, 3, 12);          // 12 lifters ON the pile, none home
    _gdt.players[0].pellets = []; _gdt.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_gdt, 0, [{ str: 5, colors: _any }], {}) ? 1 : 0, 1, "treasure-lifter: pile carriers ARE available (reassignable) -> a 5-demand elsewhere funds");
    _all &= sim_expect(ai4_send2(_gdt, 0, [{ lane: 0, idx: 1, amount: 5, colors: ["red"] }], false).delivered[0] >= 5, true, "treasure-lifter: ai4_send2 actually pulls 5 lifters off the pile to another space");
    // ...and their own pile's move is still chosen (in-place lifters fund the hold at zero move)
    var _odt = ai4_optimize(_gdt, 0);
    var _dtMove = 0;
    for (var _i = 0; _i < array_length(_odt.chosen); _i++) if (_odt.chosen[_i].outcome.type == "move") _dtMove = 1;
    _all &= sim_expect(_dtMove, 1, "treasure-lifter: the pile's own move is still chosen (in-place lifters hold it)");

    // BOARD CAP: at 25 tokens a pellet grants nothing -> it can't fund a demand
    var _gcap = sim_blank("familiargrotto");
    _gcap.players[0].tokens = []; sim_put_home_col(_gcap, 0, "red", 25);
    _gcap.players[0].pellets = ["red5"]; _gcap.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_gcap, 0, [{ str: 28, colors: _any }], {}) ? 1 : 0, 0, "cap: at 25 tokens the pellet grants 0 -> 28 demand infeasible");
    var _gcap2 = sim_blank("familiargrotto");
    _gcap2.players[0].tokens = []; sim_put_home_col(_gcap2, 0, "red", 20);
    _gcap2.players[0].pellets = ["red5"]; _gcap2.players[0].hand = [];
    _all &= sim_expect(ai4_can_fund(_gcap2, 0, [{ str: 25, colors: _any }], {}) ? 1 : 0, 1, "cap: 20 tokens + red5 (room 5) -> 25 demand feasible");

    // ONE PLANNING LAYER: ai4_send2 both plans (dry) and executes (real) - pellet-only kill.
    var _gled = sim_blank("familiargrotto");
    for (var _i = 0; _i <= 6; _i++) _gled.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _gled.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _gled.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _gled.players[0].tokens = [];                                   // no bodies at all - pellet-only funding
    _gled.players[0].pellets = ["red5"]; _gled.players[0].hand = [];
    _gled.phase = "orders";                                         // game_play_pellet is orders-phase-gated
    var _dled = [{ lane: 0, idx: 1, amount: 3, colors: ["red"] }];
    _all &= sim_expect(ai4_send2(_gled, 0, _dled, true).ok ? 1 : 0, 1, "send2: pellet-only 3-kill is feasible (dry-run)");
    var _resl = ai4_send2(_gled, 0, _dled, false);
    _all &= sim_expect(_resl.ok ? 1 : 0, 1, "send2: real run redeems the pellet and fields the squad");
    _all &= sim_expect(array_length(_gled.players[0].pellets), 0, "send2: the red5 pellet was redeemed");
    _all &= sim_expect(game_strength_at(_gled, 0, 0, 1) >= 3, true, "send2: the kill squad actually arrived (>=3 on the enemy)");

    // DISCRETE BODIES (the plateau purple-waste): a 1-strength demand must take one carry-1 body,
    // NOT a whole purple - and the purple must stay in the pool for a later bulk demand.
    var _gpb = sim_blank("undergroundplateau");                     // basics purple/white/rock
    _gpb.players[0].tokens = [];
    sim_put_home_col(_gpb, 0, "purple", 2);                         // 2 purples (carry 5) ...
    sim_put_home_col(_gpb, 0, "rock", 3);                           // ... and 3 rocks (carry 1)
    _gpb.players[0].pellets = [];
    var _led = ai4_fund(_gpb, 0, [{ str: 1, colors: ["purple","white","rock"] }], {}, true);
    _all &= sim_expect(_led != undefined ? 1 : 0, 1, "discrete: a 1-demand is fundable");
    if (_led != undefined) {
        var _e0 = _led[0];
        var _usedPurple = variable_struct_exists(_e0.tokens, "purple") ? _e0.tokens.purple : 0;
        var _usedRock = variable_struct_exists(_e0.tokens, "rock") ? _e0.tokens.rock : 0;
        _all &= sim_expect(_usedPurple, 0, "discrete: 1-demand takes NO purple (no 5-for-1 waste)");
        _all &= sim_expect(_usedRock, 1, "discrete: 1-demand takes exactly one rock");
    }
    // the plateau turn shape: kills of 1 and 5 must BOTH fund - the 1 takes a rock, the 5 takes a purple
    var _led2 = ai4_fund(_gpb, 0, [{ str: 1, colors: ["purple","white","rock"] }, { str: 5, colors: ["purple","white","rock"] }], {}, true);
    _all &= sim_expect(_led2 != undefined ? 1 : 0, 1, "discrete: 1-demand + 5-demand jointly fundable (rock for the 1, purple for the 5)");

    sim_report(_all ? "=== v4 funding: ALL PASS ===" : "=== v4 funding: FAILURES ABOVE ===");
    return _all;
}

/// v4 brick 4 — the optimizer (ai4_optimize): best jointly-fundable subset.
function sim_test_v4_optimize() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 optimizer (ai4_optimize) ===");
    var _all = true;
    var _sr = global.expRules.rush; global.expRules.rush = false;

    // one open lane, plenty of bodies -> take the move (1-space carry = 1.25V)
    var _g1 = sim_blank("familiargrotto");
    for (var _l = 0; _l < _g1.board.laneCount; _l++) for (var _i = 0; _i <= 6; _i++) _g1.board.lanes[_l].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g1.treasures = [{ cards: [TW1], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g1, 0, "red", 8); _g1.players[0].hand = []; _g1.players[0].pellets = [];
    var _V1 = ai4_pile_value(_g1, 0, _g1.treasures[0]);
    var _o1 = ai4_optimize(_g1, 0);
    _all &= sim_expect(array_length(_o1.chosen), 1, "opt: one open lane -> take the move");
    _all &= sim_expect(round(_o1.value * 4), round(_V1 * 5), "opt: value = 1-space carry = 1.25V");

    // crowded lane: pikmin cracks the first enemy, a bomb cracks the deep one -> take BOTH (escalation)
    var _g2 = sim_blank("familiargrotto");
    for (var _l = 0; _l < _g2.board.laneCount; _l++) for (var _i = 0; _i <= 6; _i++) _g2.board.lanes[_l].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g2.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.board.lanes[0].spaces[2] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };
    _g2.treasures = [{ cards: [TW5, TW5, TW5], lane: 0, idx: 3, boss: undefined }];   // realistic V so a clean kill out-values the 20 chip
    sim_put_home_col(_g2, 0, "red", 8); _g2.players[0].hand = ["bombrock"]; _g2.players[0].pellets = [];
    var _V2 = ai4_pile_value(_g2, 0, _g2.treasures[0]);
    var _o2 = ai4_optimize(_g2, 0);
    _all &= sim_expect(array_length(_o2.chosen), 2, "opt: crowded lane -> crack BOTH (pikmin + bomb)");
    _all &= sim_expect(round(_o2.value * 2), round(_V2 * 3), "opt: 2-of-2 escalation = grab/2 + grab = 1.5V");

    // strip the bomb -> only the first is reachable -> a single crack worth grab/2
    _g2.players[0].hand = [];
    var _o2b = ai4_optimize(_g2, 0);
    _all &= sim_expect(array_length(_o2b.chosen), 1, "opt: no bomb -> only the first (reachable) removal");
    _all &= sim_expect(round(_o2b.value * 2), round(_V2), "opt: 1-of-2 = grab/2 = 0.5V");

    // nothing payable -> empty plan, zero value
    var _g3 = sim_blank("familiargrotto");
    for (var _l = 0; _l < _g3.board.laneCount; _l++) for (var _i = 0; _i <= 6; _i++) _g3.board.lanes[_l].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined };
    _g3.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "armoredcannonbeetle", curHp: 25 }, structure: undefined };
    _g3.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    sim_put_home_col(_g3, 0, "red", 2); _g3.players[0].hand = []; _g3.players[0].pellets = [];
    var _o3 = ai4_optimize(_g3, 0);
    _all &= sim_expect(array_length(_o3.chosen), 0, "opt: nothing payable -> empty plan");

    global.expRules.rush = _sr;
    sim_report(_all ? "=== v4 optimizer: ALL PASS ===" : "=== v4 optimizer: FAILURES ABOVE ===");
    return _all;
}

/// v4 discard policy: junk cards before pellets; never the 5-pellet while a 1 exists.
function sim_test_v4_discard() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 hand-limit discard (ai4_resolve_discard) ===");
    var _all = true;
    var _g = sim_blank("familiargrotto");
    _g.players[0].hand = ["surveydrone", "rawmaterial"];
    _g.players[0].pellets = ["red5", "red1"];
    _g.pendingDiscard = { playerIdx: 0, need: 1 };
    ai4_resolve_discard(_g);
    _all &= sim_expect(arr_has(_g.players[0].hand, "surveydrone") ? 1 : 0, 0, "discard: junk card (surveydrone) goes before any pellet");
    _all &= sim_expect(array_length(_g.players[0].pellets), 2, "discard: the pellet reserve is untouched");
    var _g2 = sim_blank("familiargrotto");
    _g2.players[0].hand = [];
    _g2.players[0].pellets = ["red5", "red1"];
    _g2.pendingDiscard = { playerIdx: 0, need: 1 };
    ai4_resolve_discard(_g2);
    _all &= sim_expect(arr_has(_g2.players[0].pellets, "red5") ? 1 : 0, 1, "discard: pellets-only -> the 1 goes, the 5 is protected");
    sim_report(_all ? "=== v4 discard: ALL PASS ===" : "=== v4 discard: FAILURES ABOVE ===");
    return _all;
}

/// ai4_send2 - the physical fielding layer (idle-first, colour-locked-first, in-place, poison sizing).
function sim_test_v4_send2() {
    sim_report("");
    sim_report("=== SCENARIO TEST: ai4_send2 (physical fielding) ===");
    var _all = true;

    // helper: a fully-plain grotto lane 0
    var _plain = function(_g) { for (var _i = 0; _i <= 6; _i++) _g.board.lanes[0].spaces[_i] = { kind: "plain", hazard: "", enemy: undefined, structure: undefined }; };

    // IDLE FIRST: 5 idle blue at home + 6 blue sitting on a treasure at idx2; demand 5 blue onto idx4.
    var _g1 = sim_blank("familiargrotto"); _plain(_g1);
    _g1.treasures = [{ cards: [TW5], lane: 0, idx: 2, boss: undefined }];   // a real treasure at idx2 (game_treasure_at reads _g.treasures)
    _g1.players[0].tokens = [];
    repeat (5) array_push(_g1.players[0].tokens, { typeId: "blue", loc: { kind: "home" } });
    repeat (6) array_push(_g1.players[0].tokens, { typeId: "blue", loc: { kind: "space", lane: 0, idx: 2 } });
    var _r1 = ai4_send2(_g1, 0, [{ lane: 0, idx: 1, amount: 5, colors: ["blue"] }], false);   // idx1 = near side (not blocked by the idx2 treasure)
    _all &= sim_expect(_r1.ok ? 1 : 0, 1, "send2: 5-blue demand is fillable");
    _all &= sim_expect(_r1.delivered[0], 5, "send2: delivers 5");
    _all &= sim_expect(game_strength_at(_g1, 0, 0, 2), 6, "send2: IDLE taken first - the 6 on the treasure are untouched");

    // COLOUR-LOCKED FIRST (whole plan): 3 yellow + 6 rock; demands [3 yellow] and [6 any] BOTH fill.
    var _g2 = sim_blank("familiargrotto"); _plain(_g2);
    _g2.players[0].tokens = [];
    repeat (3) array_push(_g2.players[0].tokens, { typeId: "yellow", loc: { kind: "home" } });
    repeat (6) array_push(_g2.players[0].tokens, { typeId: "rock", loc: { kind: "home" } });
    var _r2 = ai4_send2(_g2, 0, [{ lane: 0, idx: 4, amount: 3, colors: ["yellow"] }, { lane: 0, idx: 3, amount: 6, colors: [] }], true);
    _all &= sim_expect(_r2.ok ? 1 : 0, 1, "send2: locked {3 yellow} + agnostic {6 any} jointly feasible");
    _all &= sim_expect(_r2.delivered[0], 3, "send2: the yellow quota is met (agnostic didn't steal them)");

    // IN PLACE: bodies already on the target satisfy the demand at zero move.
    var _g3 = sim_blank("familiargrotto"); _plain(_g3);
    _g3.players[0].tokens = [];
    repeat (4) array_push(_g3.players[0].tokens, { typeId: "rock", loc: { kind: "space", lane: 0, idx: 3 } });
    var _r3 = ai4_send2(_g3, 0, [{ lane: 0, idx: 3, amount: 4, colors: ["rock"] }], true);
    _all &= sim_expect(_r3.delivered[0], 4, "send2: in-place bodies satisfy their own demand");

    // TREASURE EXCESS as fallback: 2 idle blue + 6 blue on a treasure; demand 5 -> 2 idle + 3 excess.
    var _g4 = sim_blank("familiargrotto"); _plain(_g4);
    _g4.treasures = [{ cards: [TW5], lane: 0, idx: 2, boss: undefined }];
    _g4.players[0].tokens = [];
    repeat (2) array_push(_g4.players[0].tokens, { typeId: "blue", loc: { kind: "home" } });
    repeat (6) array_push(_g4.players[0].tokens, { typeId: "blue", loc: { kind: "space", lane: 0, idx: 2 } });
    var _r4 = ai4_send2(_g4, 0, [{ lane: 0, idx: 1, amount: 5, colors: ["blue"] }], true);   // idx1 = near side
    _all &= sim_expect(_r4.delivered[0], 5, "send2: dips into treasure-excess once idle runs out");

    // POISON ATTRITION: target behind 2 poison; 6 rock (carry 1) -> 4 arrive (send 6, 2 die).
    var _g5 = sim_blank("familiargrotto"); _plain(_g5);
    _g5.board.lanes[0].spaces[1] = { kind: "hazard", hazard: "poison", enemy: undefined, structure: undefined };
    _g5.board.lanes[0].spaces[2] = { kind: "hazard", hazard: "poison", enemy: undefined, structure: undefined };
    _g5.players[0].tokens = [];
    repeat (6) array_push(_g5.players[0].tokens, { typeId: "rock", loc: { kind: "home" } });
    var _r5 = ai4_send2(_g5, 0, [{ lane: 0, idx: 3, amount: 4, colors: ["rock"] }], true);
    _all &= sim_expect(_r5.delivered[0], 4, "send2: 4 arrive through 2 poison (6 committed, 2 die)");
    var _r5b = ai4_send2(_g5, 0, [{ lane: 0, idx: 3, amount: 5, colors: ["rock"] }], true);
    _all &= sim_expect(_r5b.ok ? 1 : 0, 0, "send2: can't land 5 through 2 poison with only 6 rock -> infeasible");

    // COLOUR NECESSITY ordering: pool 2 yellow + 2 red. Feed the LOOSER demand first; the function
    // must reorder so the yellow-only quota claims yellows before the red-or-yellow one takes them.
    var _g6 = sim_blank("familiargrotto"); _plain(_g6);
    _g6.players[0].tokens = [];
    repeat (2) array_push(_g6.players[0].tokens, { typeId: "yellow", loc: { kind: "home" } });
    repeat (2) array_push(_g6.players[0].tokens, { typeId: "red", loc: { kind: "home" } });
    var _r6 = ai4_send2(_g6, 0, [{ lane: 0, idx: 1, amount: 2, colors: ["red", "yellow"] }, { lane: 0, idx: 2, amount: 2, colors: ["yellow"] }], true);
    _all &= sim_expect(_r6.ok ? 1 : 0, 1, "send2: most-constrained-first - both quotas met though fed loosest-first");
    _all &= sim_expect(_r6.delivered[1], 2, "send2: the yellow-only quota (fed 2nd) still gets its yellows");

    // TIE-BREAK on availability: two 2-colour demands. Pool 1 red + 1 blue + 3 yellow.
    // [red|blue] has only 2 bodies, [red|yellow] has 4 - so [red|blue] (fewer bodies) must go first,
    // or it'd lose the red to [red|yellow] and fail. Feed [red|yellow] first to force the reorder.
    var _g7 = sim_blank("familiargrotto"); _plain(_g7);
    _g7.players[0].tokens = [];
    array_push(_g7.players[0].tokens, { typeId: "red", loc: { kind: "home" } });
    array_push(_g7.players[0].tokens, { typeId: "blue", loc: { kind: "home" } });
    repeat (3) array_push(_g7.players[0].tokens, { typeId: "yellow", loc: { kind: "home" } });
    var _r7 = ai4_send2(_g7, 0, [{ lane: 0, idx: 1, amount: 2, colors: ["red", "yellow"] }, { lane: 0, idx: 2, amount: 2, colors: ["red", "blue"] }], true);
    _all &= sim_expect(_r7.ok ? 1 : 0, 1, "send2: tie-break - fewer-bodies 2-colour demand goes first, both fill");
    _all &= sim_expect(_r7.delivered[1], 2, "send2: the scarcer [red|blue] quota (fed 2nd) still gets red+blue");

    // QUOTA SPLIT: an enemy that "must be attacked by at least 3 whites" (hp 10) -> demand splits into
    // [3 white] (locked) + [7 anything] (agnostic), and ai4_send2 fields it from 3 white + 7 red.
    var _gq = sim_blank("familiargrotto"); _plain(_gq);
    var _qDef = { id: "quotatest", defenseElement: "", attackElement: "", damage: 0, ability: "must be attacked by at least 3 whites" };
    var _spl = ai4_body_demands(_gq, 0, 0, 1, "hurt", _qDef, 10);
    _all &= sim_expect(array_length(_spl), 2, "quota: a 10-hp 3-white-quota kill splits into 2 demands");
    _all &= sim_expect(array_length(_spl[0].colors) == 1 && _spl[0].colors[0] == "white" ? 1 : 0, 1, "quota: first demand is white-locked");
    _all &= sim_expect(_spl[0].amount, 3, "quota: the locked part is 3 (the quota)");
    _gq.players[0].tokens = [];
    repeat (3) array_push(_gq.players[0].tokens, { typeId: "white", loc: { kind: "home" } });
    repeat (7) array_push(_gq.players[0].tokens, { typeId: "red", loc: { kind: "home" } });
    var _dq = [];
    for (var _i = 0; _i < array_length(_spl); _i++) array_push(_dq, { lane: 0, idx: 1, amount: _spl[_i].amount, colors: _spl[_i].colors });
    var _rq = ai4_send2(_gq, 0, _dq, true);
    _all &= sim_expect(_rq.ok ? 1 : 0, 1, "quota: fieldable as 3 white + 7 red (the whites aren't over-demanded)");

    // STRANDED-IN-PLACE (the minefield hold bug): a lifter on a pile that CAN'T path home (enemy behind
    // it) still holds the pile in place AND can move onto the in-lane enemy in front of it (engine rule).
    var _gs = sim_blank("familiargrotto"); _plain(_gs);
    _gs.board.lanes[0].spaces[1] = { kind: "enemy", hazard: "", enemy: { enemyDefId: "albinodwarfbulborb", curHp: 3 }, structure: undefined };  // blocks home->idx2
    _gs.treasures = [{ cards: [TW5], lane: 0, idx: 2, boss: undefined }];
    _gs.players[0].tokens = []; sim_put(_gs, 0, 0, 2, 5);                   // 5 red lifters on the pile (stranded - can't reach home)
    _all &= sim_expect(ai4_send2(_gs, 0, [{ lane: 0, idx: 2, amount: 5, colors: ["red"] }], true).delivered[0], 5, "stranded: in-place lifters HOLD their own pile (funded, no path home needed)");
    _all &= sim_expect(ai4_send2(_gs, 0, [{ lane: 0, idx: 1, amount: 3, colors: ["red"] }], true).delivered[0] >= 3, true, "stranded: those lifters can move onto the in-lane enemy at idx1 to fight it");

    sim_report(_all ? "=== ai4_send2: ALL PASS ===" : "=== ai4_send2: FAILURES ABOVE ===");
    return _all;
}

/// v4 gather reserve rule - and the 6-colour override (no 5-pellets in the die).
function sim_test_v4_gather() {
    sim_report("");
    sim_report("=== SCENARIO TEST: v4 gather reserve (ai4_gather_roll) ===");
    var _all = true;
    // 5-pellet board (grotto): unchanged rule - a 5-pellet AND >= 4 pellets to DRAW
    var _g5 = sim_blank("familiargrotto");
    _g5.players[0].pellets = ["red1", "blue1", "yellow1", "red1"];              // 4 pellets, no 5
    _all &= sim_expect(ai4_gather_roll(_g5, 0) ? 1 : 0, 1, "5-die board: 4 pellets but no 5 -> ROLL");
    _g5.players[0].pellets = ["red5", "blue1", "yellow1", "red1"];              // a 5 + 4 total
    _all &= sim_expect(ai4_gather_roll(_g5, 0) ? 1 : 0, 0, "5-die board: a 5-pellet + >=4 pellets -> DRAW");
    // 6-colour board (disco): die rolls only "1"s -> body-count reserve (~10), never infinite-roll
    var _g6 = sim_blank("discodancefloor");
    _g6.players[0].pellets = ["red1", "blue1", "yellow1"];                      // 3 ones = 6 bodies
    _all &= sim_expect(ai4_gather_roll(_g6, 0) ? 1 : 0, 1, "6-colour board: 6 pellet-bodies < 10 -> ROLL");
    _g6.players[0].pellets = ["red1", "blue1", "yellow1", "rock1", "winged1"];  // 5 ones = 10 bodies
    _all &= sim_expect(ai4_gather_roll(_g6, 0) ? 1 : 0, 0, "6-colour board: 10 pellet-bodies -> DRAW (was infinite-roll pre-fix)");
    sim_report(_all ? "=== v4 gather: ALL PASS ===" : "=== v4 gather: FAILURES ABOVE ===");
    return _all;
}

/// Run all scenario tests (add each node's tests here as it's built).
function sim_run_scenarios() {
    sim_report("");
    sim_report("######## SCENARIO TESTS  " + date_datetime_string(date_current_datetime()) + " ########");
    sim_test_survey();
    sim_test_freeze();
    sim_test_pikpik();
    sim_test_block();
    sim_test_rawmaterial();
    sim_test_ivory_warp_clone();
    sim_test_gather();
    sim_test_attack_cost();
    sim_test_deadweight();
    sim_test_access();
    sim_test_main_lane();
    sim_test_advance_commit();
    sim_test_target_piles();
    sim_test_clear_loss();
    sim_test_instant_bank();
    sim_test_play_spicy();
    sim_test_stun_deny();
    sim_test_road_obstacles();
    sim_test_obstacle_answers();
    sim_test_road_bridgeable();
    sim_test_access_methods();
    sim_test_growth_demand();
    sim_test_wall_off();
    sim_test_achievements();
    sim_test_item_achievements();
    sim_test_ach_optimize();
    sim_test_explosive();
    sim_test_explosive_defuse();
    sim_test_play_freeze();
    sim_test_v4_value();
    sim_test_v4_removals();
    sim_test_v4_moves();
    sim_test_v4_funding();
    sim_test_v4_optimize();
    sim_test_v4_discard();
    sim_test_v4_send2();
    sim_test_v4_gather();
}

// ---------- probe ----------

/// One VERBOSE seeded game between two policies: the full ai_dbg decision log
/// goes to ai_debug.txt (tournaments silence it - which is why a policy can lose
/// 900 games without anyone ever seeing a single choice it made). The autopsy
/// tool: read the PLANNER lines and see what it actually decided, turn by turn.
function sim_probe(_boardId, _idA, _idB, _seed = 20260717) {
    sim_report("");
    sim_report("=== probe: " + _idA + "(P1) vs " + _idB + "(P2)  board " + string(_boardId)
        + "  seed " + string(_seed) + "  -> full decision log in ai_debug.txt ===");
    random_set_seed(_seed);
    var _g = game_new(_boardId);
    var _polA = sim_policy_by_id(_idA), _polB = sim_policy_by_id(_idB);
    sim_policy_set(_g, _polA, _polB);
    _g.simReplan = [{ replans: 0, switches: 0 }, { replans: 0, switches: 0 }];
    _g.trace = [false, false];
    // derive the per-seat BRAIN from the policies (a "cascade" row uses v3) - the
    // hardcoded ["v2","v2"] here was silently running v2-vs-v2 and ignoring ctl
    var _ctlA = variable_struct_exists(_polA, "ctl") ? _polA.ctl : "v2";
    var _ctlB = variable_struct_exists(_polB, "ctl") ? _polB.ctl : "v2";
    var _pctl = [_ctlA, _ctlB];
    var _savedAnims = global.expRules.anims;
    global.expRules.anims = false;
    sim_silence(false); // the whole point: keep the log (game_playout would re-silence, so roll our own loop)
    ai_dbg("");
    ai_dbg("######## PROBE " + _idA + "(" + _ctlA + ",P1) vs " + _idB + "(" + _ctlB + ",P2)  board " + string(_boardId) + "  seed " + string(_seed) + " ########");
    if (!variable_struct_exists(_g, "simPrevDay")) _g.simPrevDay = _g.dayNumber;
    var _ticks = 0;
    while (_g.phase != "gameover" && _ticks < SIM_MAX_TICKS) { _ticks += 1; sim_tick(_g, _pctl); }
    game_finalize_gameover(_g);
    global.expRules.anims = _savedAnims;
    sim_report("  probe result: " + _idA + " " + string(game_realized_score(_g, 0))
        + " : " + string(game_realized_score(_g, 1)) + " " + _idB + "  (" + string(_ticks) + " ticks)");
}

// ---------- lane audit ----------

/// V2'S LANE BELIEFS vs THE TOURNAMENT'S GROUND TRUTH. Plays NO games: it
/// regenerates the SAME starting worlds the tournament ran (identical paired
/// seeds -> identical deck shuffles, piles, enemies) and dumps what
/// ai2_lane_score - the mind's actual evaluator, jitter off - thinks each lane
/// is worth, averaged over the worlds, with the full component breakdown.
///
/// Read it against the forced-lane differentials from sim_tourney.csv: where the
/// score column's RANKING disagrees with the tournament's ranking, the mispriced
/// term is visible in the components (swing wrong? difficulty over-penalizing
/// gates/blockers? boss discount?). If the components DON'T explain the gap, the
/// cause is dynamic (respawns, deck composition, what happens mid-game) and no
/// start-of-world evaluator tweak will capture it - also worth knowing.
function sim_lane_audit(_boardId, _n = 60, _seed = 20260717) {
    sim_report("");
    sim_report("######## LANE AUDIT  board " + string(_boardId) + "  " + string(_n)
        + " worlds, seeds from " + string(_seed) + "  (static - no games played) ########");

    var _savedSilent = sim_silent_get();
    sim_silence(true);

    var _lc = -1;
    var _acc = undefined;
    for (var _k = 0; _k < _n; _k++) {
        random_set_seed(_seed + _k);
        var _g = game_new(_boardId);
        if (_lc < 0) { // first world: size the accumulators
            _lc = _g.board.laneCount;
            _acc = array_create(2);
            for (var _p = 0; _p < 2; _p++) {
                _acc[_p] = array_create(_lc);
                for (var _l = 0; _l < _lc; _l++) {
                    _acc[_p][_l] = { swing: 0, gates: 0, bhp: 0, diff: 0, score: 0, bossed: 0, piles: 0, best: 0 };
                }
            }
        }
        for (var _p = 0; _p < 2; _p++) {
            var _bestL = -1, _bestS = -1;
            for (var _l = 0; _l < _lc; _l++) {
                var _ls = ai2_lane_score(_g, _p, _l);
                if (!_ls.hasPile) continue;
                var _a = _acc[_p][_l];
                _a.piles += 1;
                _a.swing += _ls.swing; _a.gates += _ls.gates; _a.bhp += _ls.blockerHp;
                _a.diff += _ls.difficulty; _a.score += _ls.score;
                if (_ls.bossed) _a.bossed += 1;
                if (_ls.score > _bestS) { _bestS = _ls.score; _bestL = _l; }
            }
            if (_bestL >= 0) _acc[_p][_bestL].best += 1;
        }
        if ((_k % 25) == 0) gc_collect(); // blocking loop: GM never collects on its own
    }
    sim_silence(_savedSilent);

    for (var _p = 0; _p < 2; _p++) {
        sim_report("SEAT P" + string(_p + 1) + " (averages over worlds where the lane HAD a pile; pick% = jitter-free focus choice)");
        sim_report("  lane  score    swing    diff   gates  blkHp  bossed%  pick%   worlds");
        for (var _l = 0; _l < _lc; _l++) {
            var _a = _acc[_p][_l];
            var _m = max(1, _a.piles);
            sim_report("  " + string_format_width(string(_l + 1), 6)
                + string_format_width(string(round(_a.score / _m)), 9)
                + string_format_width(string(round(_a.swing / _m)), 9)
                + string_format_width(string(round(_a.diff / _m * 100) / 100), 8)
                + string_format_width(string(round(_a.gates / _m * 10) / 10), 7)
                + string_format_width(string(round(_a.bhp / _m * 10) / 10), 7)
                + string_format_width(string(round(100 * _a.bossed / _m)) + "%", 9)
                + string_format_width(string(round(100 * _a.best / _n)) + "%", 8)
                + string(_a.piles) + "/" + string(_n));
        }
    }
    sim_report("ground truth (run 2 diffs): riverbank lane5 +92, lane1 -77 | minefield lane1 +55, lane2 -70, lane5 -61");
}

// ---------- selftest ----------

function sim_assert(_cond, _what) {
    sim_report((_cond ? "  PASS  " : "  *** FAIL *** ") + _what);
    return _cond;
}

/// Prove the harness before trusting a single number out of it:
///  1. the engine is deterministic under a fixed seed
///  2. a clone is independent (playing it out doesn't touch the original)
///  3. a clone is faithful (undefined sentinels survive; boardDef stays shared)
function sim_selftest(_boardId, _ctl = ["v2", "v2"]) {
    sim_report("=== selftest: board " + string(_boardId) + " ===");
    var _all = true;

    // 1. determinism: same seed -> same game
    random_set_seed(12345);
    var _r1 = sim_play_game(_boardId, _ctl);
    random_set_seed(12345);
    var _r2 = sim_play_game(_boardId, _ctl);
    _all &= sim_assert(_r1.p0 == _r2.p0 && _r1.p1 == _r2.p1 && _r1.ticks == _r2.ticks,
        "determinism: seed 12345 -> " + string(_r1.p0) + "/" + string(_r1.p1)
        + " (" + string(_r1.ticks) + "t) vs " + string(_r2.p0) + "/" + string(_r2.p1)
        + " (" + string(_r2.ticks) + "t)");

    // 2/3. clone fidelity + independence
    random_set_seed(999);
    var _g = game_new(_boardId);
    var _c = game_clone(_g);
    if (_c == undefined) {
        sim_assert(false, "clone: refused on a fresh game (should never happen)");
        return false;
    }

    _all &= sim_assert(_c.boardDef == _g.boardDef, "clone: boardDef shared by reference (not copied)");
    _all &= sim_assert(_c.board != _g.board, "clone: board state is a distinct object");
    _all &= sim_assert(_c.players[0].tokens != _g.players[0].tokens, "clone: token arrays are distinct");

    // undefined sentinels must survive the copy - the engine tests `!= undefined`
    // everywhere (enemy, structure, boss, pendingDiscard, combatFights). If a deep
    // copy turned those into null/pointer_null, every one of those checks inverts.
    var _sentinelOk = true, _checked = 0;
    for (var _l = 0; _l < _g.board.laneCount; _l++) {
        for (var _s = 0; _s <= 6; _s++) {
            var _og = _g.board.lanes[_l].spaces[_s];
            var _cl = _c.board.lanes[_l].spaces[_s];
            if (is_undefined(_og.structure)) { _checked += 1; if (!is_undefined(_cl.structure)) _sentinelOk = false; }
            if (is_undefined(_og.enemy))     { _checked += 1; if (!is_undefined(_cl.enemy))     _sentinelOk = false; }
        }
    }
    _all &= sim_assert(_sentinelOk && _checked > 0,
        "clone: empty space.enemy/.structure stayed a real undefined, not null (" + string(_checked) + " checked)");
    _all &= sim_assert(is_undefined(_c.combatFights), "clone: combatFights sentinel survived as undefined");
    _all &= sim_assert(is_undefined(_c.pendingDiscard), "clone: pendingDiscard sentinel survived as undefined");

    var _origTokens = array_length(_g.players[0].tokens);
    var _origDay = _g.dayNumber;
    var _origPhase = _g.phase;
    var _origScore = _g.players[0].score;

    random_set_seed(777);
    var _rc = game_playout(_c, _ctl);

    _all &= sim_assert(_rc.ok, "clone: played out to gameover (" + string(_rc.ticks) + " ticks, "
        + string(_rc.p0) + "/" + string(_rc.p1) + ")");
    _all &= sim_assert(_g.dayNumber == _origDay && _g.phase == _origPhase
        && array_length(_g.players[0].tokens) == _origTokens && _g.players[0].score == _origScore,
        "clone: original UNTOUCHED by the clone's playout (day " + string(_g.dayNumber)
        + ", phase " + _g.phase + ", " + string(array_length(_g.players[0].tokens)) + " tokens)");

    sim_report(_all ? "=== selftest PASSED ===" : "=== selftest FAILED - do not trust the numbers ===");
    return _all;
}

/// F3 entry point: prove it, then price it.
function sim_run_diagnostics(_boardId, _ctl) {
    sim_report("");
    sim_report("######## sim diagnostics  " + date_datetime_string(date_current_datetime()) + " ########");
    if (!sim_selftest(_boardId, _ctl)) return;
    sim_benchmark(_boardId, 25, _ctl);
}
