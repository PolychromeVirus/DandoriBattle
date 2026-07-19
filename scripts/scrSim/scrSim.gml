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
        ai_resolve_discard(_g);
        _g.fx = [];
        return;
    }
    if (array_length(_g.pendingFree) > 0) {
        var _fb = sim_ctl(_ctl, _g.pendingFree[0].playerIdx);
        if (_fb == "v3") ai3_place_free_hazard(_g);
        else if (_fb == "v2") ai2_place_free_hazard(_g);
        else ai_place_free_hazard(_g);
        _g.fx = [];
        return;
    }

    var _brain = sim_ctl(_ctl, _g.activePlayer);
    if (_brain == "v3") ai3_step(_g); else if (_brain == "v2") ai2_step(_g); else ai_step(_g);
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
        { id: "base",    kind: "none",    lane: -1 },
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
    ];
}

/// The ACTIVE roster. Cut to the current question (2026-07-17): does planner v3
/// beat stock v2? base = control, lane5 = the known-good yardstick (+92/+99/+99
/// across three builds - if IT doesn't show, the run is broken), planner = the
/// candidate. Retired with verdicts in hand: lane1 (trap, 3x replicated),
/// spread2 (noise everywhere), numbers (story complete: mild here, fatal on rich
/// boards), tiered (trap-seeking vacuum rule + mirror collision), contestN/R
/// (null). 3 policies -> 9 pairings; at 100/pairing = 900 games (~5 min
/// riverbank). Revive anything by adding its id back to _active.
function sim_policies() {
    var _active = ["base", "lane5", "cascade"];
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
        + _pols[_st.a].id + "," + _pols[_st.b].id
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
            sim_report("  ...done " + _pols[_st.a].id + " as P1 (" + string((get_timer() - _st.t0) / 1000000) + "s elapsed)");
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
    for (var _b = 0; _b < _n; _b++) _hdr += string_format_width(_pols[_b].id, 8);
    sim_report("");
    sim_report("WIN MATRIX (row = P1 policy, cell = P1 wins out of " + string(_perPair) + " vs col as P2)");
    sim_report(_hdr);
    for (var _a = 0; _a < _n; _a++) {
        var _row = string_format_width(_pols[_a].id, 8);
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
        sim_report("  " + string_format_width(_pols[_a].id, 9)
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

    // fire crossed by fire-immune reds -> 0; fire + non-immune rocks (unbridgeable) -> INF
    var _f = sim_blank("familiargrotto");
    _f.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _f.board.lanes[0].spaces[1].kind = "hazard"; _f.board.lanes[0].spaces[1].hazard = "fire";
    sim_put_home_col(_f, 0, "red", 6);
    _all &= sim_expect(ai3_road_turns(_f, 0, 0, 3), 0, "road: fire crossed by fire-immune reds -> 0");
    var _f2 = sim_blank("familiargrotto");
    _f2.treasures = [{ cards: [TW5], lane: 0, idx: 3, boss: undefined }];
    _f2.board.lanes[0].spaces[1].kind = "hazard"; _f2.board.lanes[0].spaces[1].hazard = "fire";
    sim_put_home_col(_f2, 0, "rock", 6);
    _all &= sim_expect(ai3_road_turns(_f2, 0, 0, 3), ACCESS_INF, "road: fire, non-immune rocks, unbridgeable -> INF");

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
