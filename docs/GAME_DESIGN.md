# Dandori Battle — Game Design Document

Transcribed from `Dandori Battle Rules.pdf` (v: 2026-07-13). This is the implementation
contract for the digital adaptation. **Corrections welcome — the PDF is the source of
truth, this doc is how the code will interpret it.** Anything marked ⚠️ is an open
question the rulebook doesn't fully answer.

## Goal & game end

- Players compete to gather the most treasure, measured in **poko value** of treasure
  cards successfully returned to their base.
- **Set-collection scoring** (confirmed 2026-07-13): loose treasures always score
  face value; series ("Set") treasures score **only if you hold 3+ pieces of that
  series** — then all held pieces of it count. (`setThreshold` in rules.json.)
  Set 1 / TSet 1: 21 loose treasures + Controller Series (10 pieces) + Game
  Series (19 pieces).
- The game ends after **3 days** (configurable — 3 is the playtest value). A day passes
  when the day tracker reaches the end and resets.
- Highest total poko value wins.

## Setup

1. **Treasure piles:** on each treasure space, deal cards face-up from the treasure deck
   until the pile's total poko value **≥ 500p**. A pile acts as a single treasure — the
   top card's values (weight, effects) are the ones in play.
2. **Enemies:** deal enemy cards face-up onto all enemy spaces on both sides of the
   board. If a **boss** is drawn, place it on top of the treasure pile currently showing
   the highest-value treasure, then continue filling. If every treasure pile already has
   a boss, shuffle the boss back in and continue.
3. **Starting pikmin:** each player puts 1 pikmin token of each of the 3 basic colors
   (scenario-dependent which colors) in their HOME.
4. Choose who goes first.

## Turn structure

### 1. Gather Phase
- Remove any sprays you placed last turn that are still on the board.
- You get **gather actions**: 3 on your first turn, 2 on every later turn.
- Each gather action buys either:
  - a draw from the **gather deck**, or
  - a roll of one **pellet die**.

### 2. Orders Phase
- Move your pikmin on the board freely and assign them to spaces, subject to lane
  rules (below): they may only go to spaces that are past hazards they are immune to,
  or to the enemy **furthest from the center**. Anything on the board stops further
  advance until cleared.
- Pellet cards may be redeemed here for pikmin tokens (own color at full rate,
  another color at a slightly worse rate ⚠️ exact rates unspecified).
- **Hard cap: 25 pikmin tokens on the board per player.** You may voluntarily discard
  your own tokens at any time; pellet pikmin that would exceed the cap are wasted.
  **Bulbmin do NOT count toward the cap** (confirmed 2026-07-14) — they exist
  separately, are recruited only from the Bulbmin enemy, and all 5 are granted on its
  death regardless of how full you are. (Engine: `game_capped_count` excludes bulbmin;
  HUD shows `capped/25` plus a `+Nb` bulbmin tally.)

### 3. Move Phase
- After orders are given but before they resolve is the **only** window to play gather
  cards (exceptions: cards that state their own timing or say "play at any time").
- Orders then resolve. Each thing pikmin do is a "move," resolved in this order:
  1. **Carry:** move any treasure they hold (that is free to move) one space.
  2. **Attack:** deal damage to enemies they are attached to.
  3. **Defend:** take damage from enemies that aren't dead yet.
- When an enemy dies, its reward is rolled/drawn **immediately**.
- End of turn: discard down to **10 cards in hand**, then play passes.

## Day track

- The day counter advances one space every time play returns to the first player, and
  its event (if any) resolves. For the playtest ruleset the only midday event is enemy
  respawning in the first phase.
- **When the track resets (a day ends):**
  - all empty enemy spaces are refilled;
  - surviving enemies heal to full HP;
  - all pikmin tokens return to their HOMEs;
  - treasure **stays where it is**.
- A non-boss enemy that would spawn on a treasure space is skipped — treasure takes
  priority and does not move between days.

## Board, spaces & lanes

- The board is made of **lanes**. Each lane has 3 spaces per player side plus a shared
  **treasure space** in the middle (so 7 spaces per lane). ⚠️ Number of lanes, and the
  positions of enemy/hazard spaces within lanes, need the physical board layout.
- "**Your side**" = the treasure space plus the 3 lane spaces you traverse to reach it.
  The treasure space counts as *both* players' side (matters for cards like Oatchi Rush).
- A space is **empty** if it has no card on it — pikmin don't occupy a space in that
  sense.
- A lane is **clear** if there are no cards between you and the treasure. Pikmin don't
  block clearance; map hazards don't either, but **hazard cards do**.
- **Attachment on spawn:** if an enemy or treasure appears on a space with pikmin,
  those pikmin auto-attach, but don't start resolving the interaction until their next
  action. (E.g. spicy spray + kill a boss with the first action → the second action
  starts carrying the dropped treasure.)

### Hazards on spaces
- A space with a hazard can only be entered by pikmin immune to it, **except height**:
  - **Height** is one-way: only height-capable pikmin (yellow, winged) may enter it
    while traveling *toward* the treasure; anyone can exit it (fall off the cliff), and
    any type can exist on it (e.g. via candypop bud).
- Pikmin **spawned** onto a hazard they can't survive die immediately.
- A hazard **spawned** onto pikmin that can't survive it kills them at their next action
  (not immediately).
- **Poison:** groups take 1 damage *per color* per turn when **passing** the space
  (exiting it), or when sitting on it for a turn without moving. A space is not
  "passed" if a card effect moves pikmin over it (Oatchi Rush carrying pikmin doesn't
  damage a bridge, etc.).

## Cards

### Treasure
- Starts mid-board on treasure spaces; must be carried back to your side to score.
- Piles act as one treasure; use the **top card's** values.
- To move a treasure you must:
  - (A) have total **carry strength ≥ the weight** (bottom-right corner), AND
  - (B) have **more pikmin (by carry strength) on it than your opponent**.
- Equal strength on both sides = **carry stalemate**: the treasure doesn't move. Broken
  only by Ultra-Spicy Spray (moves it a space despite the stalemate) or by removing
  the opponent's pikmin.

### Pellets
- When a reward shows pellets, or a pellet draw is color-unspecified: roll a **pellet
  die** and take the card matching the color and value shown.
- **Die faces are board data** (special editions use other colors): a board's die has
  a 1 and a 5 face for each of its 3 basic colors. Standard: 1 red, 5 red, 1 blue,
  5 blue, 1 yellow, 5 yellow.
- Redeemed during the Orders Phase for pikmin tokens:
  - **1-pellet card** → 2 pikmin of the matching color, OR 1 of another color.
  - **5-pellet card** → 5 pikmin of the matching color, OR 2 of another color.

### Enemies
Card anatomy:
- **Attack element** (top-left, by the name) and **defense element** (next to HP). Not
  all enemies have elements.
- **HP** (big green circle; gold = boss) — damage persists between turns (until the
  day resets it). **Damage** (red circle) = number of pikmin *tokens* it discards when
  attacking.
- **Rewards** box (bottom): granted on death — roll pellet dice per pellet icon, draw
  gather cards per gather icon.
- **Ability** box (above rewards, optional): special requirements to damage it, or
  on-death effects (e.g. dweevils drop a hazard of their type).

### Bosses
- Gold HP circle + "BOSS" label; shuffled into the enemy deck, but always spawn onto
  the highest-value visible treasure pile instead of an enemy space (see Setup).
- The treasure under a boss cannot be collected until the boss dies. The boss stays on
  that pile even if the pile's top card changes.
- When a boss dies, pikmin on the space auto-attach to the dropped treasure but can't
  move it until the next move phase (unless a spare ultra-spicy action remains).

### Sprays
- **Ultra-Spicy / Ultra-Bitter Spray:** discard the card on play, put a token on a
  space. Spicy grants an extra move (also the stalemate-breaker); bitter makes a move
  be skipped. The token is discarded when the extra move is used / a move is skipped.
  Sprays you placed that are still on the board are cleaned up in your next Gather
  Phase.
- **Bewilder Bomb:** puts a token on an *enemy*, removing its elements until it dies.
  Only one Bewilder token may exist on the board — placing a new one moves the old
  one (the previous enemy gets its elements back).

## Combat

Each move phase, an enemy in contact with pikmin:
1. loses HP equal to the **total carry strength** of pikmin on its space;
2. then kills **tokens** equal to its damage — *unless it died this turn*.
   - Token count, not strength: a purple deals 5 damage but only absorbs 1 point of
     enemy damage.

### Combat timing (confirmed 2026-07-14): three simultaneous passes

1. **Swift enemies strike first** (before any pikmin damage).
2. **All pikmin damage resolves** across every engagement — including the ice
   freeze-swarm and suicide-defence losses — before any other enemy responds.
   Enemy deaths and their rewards happen immediately in this pass.
3. **All surviving enemies strike simultaneously** — crush enemies strike even
   while dying, and **explosions land here alongside everything else** (an
   explosive enemy can never pre-empt an adjacent group's attack; the Volatile
   Dweevil dies when it explodes in this pass, but if killed in pass 2 it grants
   rewards and never detonates).

### Ice Pikmin: freeze-swarm (user-designed 2026-07-14)

If the ice pikmin on an enemy number at least **ceil(remaining HP / 2)**, that
quota of ice **freeze it instead of dealing damage** — it skips its turn (same
stun as Bitter Spray, consumed at its next action). Ice above the quota deal
damage as normal. No double-freezing: if it's already incapacitated, all ice
just fight. Freezing isn't damage, so it works even on crush-defence enemies.

### Attack elements (marker by the name)
- **Elemental (fire/water/electric/ice/…):** can't kill pikmin immune to that element.
- **Crush (box + down arrow):** deals its full damage every turn *even if it dies that
  turn*. Rock pikmin take no damage from crush enemies.
- **Speed:** the enemy attacks *before* the pikmin attack phase.
- **Explosive:** attacks all pikmin on the 5 spaces in a **+** centered on itself; can
  hit pikmin a space away even if they aren't attacking it.

### Defense elements (marker by the HP)
- A pikmin that attacks the enemy dies after attacking (its damage still counts)
  unless immune to the defense element. Exceptions — these gate who can damage it at
  all instead:
  - **Crush defense:** only crush-breakers (Rock pikmin) can harm it.
  - **Height defense:** only height-capable pikmin (yellow, winged) can harm it.

## Enemy respawning

- Triggered by gather cards, boss/treasure effects, or midday day-track events.
- Refill all enemy spaces as at setup unless the effect says otherwise.
- Skip spaces that already hold a card (hazard, carried treasure, …).
- Enemies spawning onto pikmin-only spaces auto-engage, but no damage in either
  direction until the next move action.

## Pikmin types

| Type | Class | Carry str | Immunities / traits |
|---|---|---|---|
| Red | Basic | 1 | Fire |
| Blue | Basic | 1 | Water |
| Yellow | Basic | 1 | Electricity; climbs height hazards |
| Purple | Advanced | 5 | None |
| White | Advanced | 1 | Poison; deals 1 damage to its target when killed; a treasure carried *only* by whites moves 2 spaces per action (one action — bitter spray cancels all of it) |
| Bulbmin (green) | Special | 1 ⚠️ | Only from defeating the bulbmin enemy. Immune to fire, water, electric, ice, poison, control; NOT height/crush/stab; explosions hit normally |
| Rock (black) | Basic (map-specific) | 1 ⚠️ | Can't be crushed or stabbed |
| Ice (cyan) | Basic (map-specific) | 1 ⚠️ | Immune to ice (hazards and enemies) |
| Winged (pink) | — ⚠️ | 1 ⚠️ | Flies over hazards; cannot pass **walls** |

## Experimental type-identity abilities (playtest toggles, OFF by default)

Being tested to give the pure-immunity colours some identity. Each is a board-select
menu toggle (`global.expRules.{red,blue,yellow}`); when off, behaviour is exactly as
before. Not final rules.

- **Red — second combat pass.** Reds strike again *after* the enemy turn, so combat
  becomes: spicy bonus → swift → pikmin → enemy → **red second strike**. A red thus
  attacks twice per combat (three times if also sprayed). Consequence: **Bitter Spray
  = two free red attacks** (enemy skips its turn between them), **Spicy Spray = three**.
  Implemented as Pass C in `game_combat_step` (reds only, gated by crush/height/attack-
  requirement like normal; suicide-defence needs no re-gate since surviving reds are
  immune by construction). Enemy targets only for now — not structures.
- **Blue — lifeguard.** A moving group may cross **water** carrying up to one
  non-blue per blue (water-immune = lifeguard; winged don't need carrying). Legality
  (`game_lifeguard_ok`): lifeguards ≥ non-immune-non-flying in the moving group,
  counted **together**; if the landing space is itself water, pikmin already standing
  there count too. Off unless toggled. The AI doesn't route through water yet (its
  reachability check passes no coverage), so it plays "safe" without lifeguard tech.
  **Deliberately does NOT apply while carrying treasure** (ruling 2026-07-15): pikmin
  holding a pile can't help each other across — matches the original game. Keeps blue
  a combat-positioning tool (ferry purples to a Waterwraith across a lake), not a
  treasure-routing one — parallel to yellow. So the carry path stays per-pikmin (a
  mixed group stalls at water unless every carrier is water-immune).
- **Yellow — chasm crossing, one-way inward.** Yellows cross a **chasm** hazard only
  when heading toward the centre (`_towardCenter`), never coming back — flavour for
  being light/throwable; lets you land them on enemies before bridges exist. Minimal
  competitive impact by design.
- **2× Rush Carry.** A treasure hauled by carrying power ≥ **double its weight** moves
  **2 spaces** in one carry action instead of 1 (`game_carry_step`; same 2-space cap
  as an all-white team — they don't stack to 3). Gives late-game overloaded stacks a
  rush option. Three conditions, all required (beyond the normal move rules):
  - your carrying power `_own` ≥ 2 × the pile's weight;
  - the **opponent is below the weight requirement** (`_opp < weight`) — if they're at
    or above it they'd be pulling it themselves, so you can only inch a contested pile
    1 space no matter how far you overpower it (e.g. weight 2, you 2 vs me 4 → moves 1);
  - **no purple on the stack** (`game_carriers_have_purple`) — purples are strong-but-
    slow, so the rush rewards swarms of light pikmin, not a couple of heavy carriers.

  Whites still get their own always-2 fast carry regardless. AI doesn't deliberately
  target 2× weight yet, though its over-commits sometimes reach it.

## Co-op mode (out of scope for v1, recorded for later)

- Each player gets a random **Captain Card** with a passive ability.
- Some captains create tokens that live at HOME and respawn there at the start of the
  next Move phase after dying:
  - **Charlie token** — strength 2, no immunities.
  - **Oatchi token** — strength 5, immune to all map hazards, treats enemy hazard
    icons as neutral/neutral; can only damage enemies/walls, cannot carry treasure.

## Numbering taxonomy (don't conflate these!)

- **Board number 1–16**: each board has its OWN enemy deck and gather deck
  (`EnemyN`/`GatherN` tabs in the xlsx; `setsCopies` keys in enemies/gather.json;
  the "Set N:" prefixes in the Board Layouts tab are board numbers).
- **Treasure set (TSet) 1–7**: which treasure pool the board deals piles from
  (`treasureSet` in boards.json; several boards share a TSet).
- **Release waves** ("sets" in the product sense): marketing bundles of boards
  (wave 1 = the first two boards, etc.) — not used by the engine at all.

## Data files

All content lives in `datafiles/data/` as JSON so it can be rebalanced without code
changes:

- `enemies.json` — the base-set enemy deck (67 cards, 15 bosses), converted from
  `PikminCardReference - Enemy.csv`. `copies` = deck count (believed: weak enemies ×3,
  mediums ×2, strong/boss ×1 ⚠️ confirm). Attack element `swift` = the rulebook's
  "Speed" marker. Rewards are stored as counts: `@[P]` pellet-die rolls, `@[G]`
  gather draws.
- `pikmin.json` — the type table (carry strength, immunities, traits).
- `boards.json` — board definitions. Boards vary (different layouts, basic colors,
  pellet-die faces), so each board declares its lanes as 7-space arrays (3 per side +
  shared treasure space), its 3 basic colors, and its explicit die faces. Random board
  generation is a planned feature on top of this schema. The current `test_field`
  layout is a **placeholder guess**.
- `rules.json` — global constants: 3 days, 25-token cap, 10-card hand limit, 3/2
  gather actions, 500p treasure piles, pellet exchange rates.
- `treasures.json` — 50 base-set treasures (poko value, weight, set-collection
  effects, descriptions), all with sprites.
- `gather.json` — 13 gather card types, 50-card deck with copy counts, effect text.
- `pellets.json` — 16 pellet cards (all colors, 1s and 5s) with per-card exchange
  amounts (same-type / off-type).
- `hazards.json` — 13 placeable cards in three types: **hazard** (emitters/spouts,
  element-gated passage), **wall** (blocks a lane; some element-locked), **bridge**
  (bridge/climbing stick/tunnel — grants passage over chasm/height). This is the
  "building things on tiles" system.
- `dice.json` — 8 pellet-die variants (6 faces each of color+value); a board
  references whichever die it uses.

All converted from `PikminCardReference.xlsx` by scratchpad script `convert_xlsx.py`;
each record carries a `sprite` field mapped to the actual sprite resource by
normalized-name matching. Only base ("Set 1") lists are used; showcase/numbered
variant editions are out of scope.

## M3 engine interpretations (flag anything wrong!)

The turn engine (`scrGame`) had to pin down details the rulebook leaves open:

- **Day track length:** NOT in the rules — implemented as `dayTrackLength: 5` in
  rules.json (5 rounds per day, 3 days). ⚠️ Needs the real number.
- **Movement scope** (corrected 2026-07-13): pikmin may be ordered anywhere along a
  lane, INCLUDING across the middle onto the opponent's side - but every card on the
  way blocks, so crossing is only possible where the centre pile is gone. Height
  gating is relative to the treasure space: steps toward the centre need climbers,
  steps away (including descending the far side) are free. The first blocking card
  is a legal destination (attach). Candypop taxonomy (confirmed 2026-07-14): the
  classic **Candypop Bud converts to Red/Blue/Yellow ONLY** on any board (its
  exotic-board utility); **Queen Candypop Bud** converts to the board's starting
  colours; the rock/winged/ice variant covers off-board types. Conversion cards
  (Candypop buds, Ivory & Violet)
  work in place - new/changed pikmin stay on the targeted space - and may target
  HOME as well as spaces.
- **Collection point:** a treasure that moves past lane index 0/6 is scored; all
  riders (both players') return to their homes.
- **Carry through hazards:** a treasure can't advance into a hazard space unless every
  token on it (both players') can exist there; it can't advance into a space with a card.
- **Enemy retaliation targets:** tokens die cheapest-first (basics, then whites, then
  purples). Later this could become a player choice.
- **Explosive enemies:** attack in a + pattern hitting both players' tokens, and
  trigger even unengaged if any active-player token is in range. Volatile Dweevil
  dies after attacking with no reward (per its ability).
- **Hand limit:** gather + pellets count together. **The owner CHOOSES what to
  discard** (2026-07-16, matches the tabletop): going over the limit at end of turn
  sets `game.pendingDiscard` and defers the turn handoff (`game_end_turn_finish`)
  until the owner has discarded down via `game_discard_choice`. Humans get a modal
  card picker (Draw_64); AI seats pick via `ai_resolve_discard` (weakest pellet
  roll first, then surplus 3rd+ copies, then a static junk ranking).
- **Onion discard zone** (2026-07-16): a circle decal to each player's LEFT (mirror
  of their treasure horde, same footprint). During the orders phase, selected pikmin
  clicked onto it are dismissed ("returned to the Onion") via `game_order_discard` -
  legality mirrors an ordered retreat HOME (trapped/frozen/buried pikmin can't go;
  mines take pass damage from the walk). Frees token-cap space. The AI uses it at
  the cap: colours with no legal destination anywhere on the board are culled when
  pellets are waiting (`ai_cull_deadweight`; skipped while Ivory & Violet is held -
  chaff is purple fodder).
- **Gather cards: all 13 implemented** (slice 2), with these interpretations:
  - *Raw Material* builds from the board's allowed structures; a Captain Clone
    copying it needs one real copy in hand as the "second" card. Bridges may only go
    on hazard spaces.
  - *Structures:* walls block everyone (not attackable yet); emitters add their
    element to the space and block passage like a card; bridges let anyone cross and
    don't block lane clearance. Structures currently take damage only from Bomb Rock
    (10) — per-pass bridge wear and attacking walls are future work.
  - *Bomb Rock* (10) / *Boulder* (5) wipe both players' pikmin on the space and
    damage enemy/boss/structure there (kill credit + rewards to the player who
    played it). **One blast = one impact** (ruling 2026-07-15): the damage lands on
    whatever was already on the space — a hazard a dying dweevil drops spawns AFTER
    and takes none of it; overkill is not carried over to what spawns. (Enforced by
    an `_hadStructure` snapshot taken before the blast; the dropped hazard is also
    flagged `fresh` so nothing chews it until the next turn.)
  - *Ivory and Violet*: the player **chooses which pikmin are traded** (2026-07-16) -
    the trade menu has a per-colour payment picker (must add up to the cost exactly;
    left blank it falls back to cheapest-first, which is also the AI's path via the
    optional `pay` arg to `game_play_gather` / `game_discard_tokens_pay`). New
    purples/whites appear in place at the traded space (or HOME).
  - *Ultra-Spicy Spray:* token on a space; that player's pikmin there act twice,
    and the BONUS action resolves FIRST (confirmed by user): sprayed pikmin carry/
    attack before everything else - before even swift enemies - and enemies give no
    response to the bonus strike (suicide-defence losses still apply). Ties only
    move on the bonus action, so a tied carry moves 1 space, untied moves 2. The
    spray token travels with a carried treasure; spent after use, leftovers cleaned
    in the owner's next gather phase.
  - *Pile refill:* whenever a lane ends a turn with no treasure anywhere in it, a
    new >=500p pile is dealt to its treasure space (until the treasure deck runs
    out) - no lane ever sits empty (confirmed by user).
  - *Warp* is two-mode: click boss → boss = swap flow; click lane enemy → move flow.
  - *Oatchi Rush* requires the treasure strictly on the opponent's side (treasure
    space counts as yours) and a clear lane (bridges don't block); riders are carried
    and hazards aren't "passed".
  - *Captain Clone* copying Captain Clone does nothing (discards for no effect).
  - *Pikmin Extinction* executes immediately on click - no confirmation (yet) - and
    **ends the player's turn on the spot** (confirmed ruling 2026-07-15): no further
    cards, no move resolution; the engine calls `game_end_turn` inside the card
    effect. (Safe for the AI: its later card attempts fail the move-phase gate.)
- **Enemy abilities implemented** (generalised 2026-07-15 — matched on ability TEXT
  so every set's variants work, not just set 1's enemies):
  - *"Creates a \<Hazard\> when it dies"* (all Dweevils incl. Iceblown): the named
    hazard is looked up in the hazard defs and dropped on the death space.
  - *"Must be attacked by at least N \<type\>"* (Waterwraith's purple, the rock
    beasts, Vehemoth Phosbat's 3 yellows): without the quota no damage lands; with
    it met the whole group's strength counts. AI steers the required type there.
  - *"Any Pikmin attacked this turn can't move next turn"* (Snitchbug family,
    Mamuta, cold Blowhogs): attack stuns instead of kills.
  - *"Any Pikmin attacked this turn return HOME"* (Blowhogs, Snoot Whacker,
    Arctic Cannon larva/beetle): attack blows tokens back to HOME instead of killing.
  - *"Any Pikmin attacked this turn are thrown one lane left/right"* (Antenna
    Beetle, Groovy Long Legs, Puffstool, Scornet Maestro): tokens are relocated a
    lane sideways; thrown off the board's edge they die on boards flagged
    `killedIfThrownOut` (else cling on and stay); landing on a hazard they can't
    survive kills them (walls/chasm rules as if arriving as a destination).
  - Bulbmin grants 5 bulbmin tokens IN PLACE to the killer; Volatile Dweevil
    self-destructs rewardless.
  - *Giant Breadbug* (boss, 0 damage) is a **progress-loss clock** (confirmed
    2026-07-15): it spawns on a pile that has been moved and, at EVERY turn end,
    drags the pile one space back toward the centre treasure space - never past
    it - until killed. Blocked by an occupied space ("path is blocked"). Riders
    (both players' pikmin on the pile) are dragged along carry-style; non-immune
    riders dragged onto a blocking hazard die. Sprays travel with the pile;
    hauling off a plain Bridge snaps it. Instrumental for adventure mode
    (singleplayer/co-op) later.
  - *"Each player places N free hazards when it dies"* (Titan Dweevil 1 / Plasm
    Wraith 2 / Ancient Sirehound 3): queues N placements per player, **killer
    first**, into `game.pendingFree`. The queue is modal — all normal play is blocked
    until resolved. Placements follow Rock Storm rules (board's emitter list, empty
    basic space); a player may pass to forfeit one placement. Humans get a type
    picker + click-to-place; the AI picks the emitter whose element favours its own
    roster and drops it on the opponent's side of their most valuable lane. Skipped
    entirely if the board allows no emitters.
  The enemy `copies` column is deck count, and defeated enemies go to a **discard
  pile** that reshuffles into the enemy deck when it runs dry.
- **Structures** (confirmed 2026-07-13):
  - **Walls** block passage for everyone, but are attackable as a destination
    (0-damage, 10hp); pikmin ordered onto a wall deal their carry strength per move
    phase.
  - **Emitters** are NOT walls - they are destructible **floor hazards** of their
    element. Passage obeys the floor-hazard element gate (a Water Spout is passed by
    blues for free; non-immune are blocked), they block lane clearance (they're
    cards), and they behave like a **0-damage enemy with a defensive element**: ANY
    pikmin may be assigned to attack one, dealing carry strength, but non-immune
    attackers die after striking (immune survive). So only blues can safely dismantle
    a Water Spout; a red thrown at it deals 1 then dies.
  - **Bridges break when a treasure pile moves off of them** (not from pikmin
    passage; Oatchi Rush never breaks them).
- **Starting hand** (confirmed): none - the extra first-turn gather action exists so
  players shape their own opening hand.
- The enemy `tall` flag is **cosmetic only** (a card-maker hint to rescale tall
  sprites so they center correctly) - no gameplay meaning.
- **Treasure carrying over hazards** (confirmed 2026-07-13): hazards, emitters, and
  walls are tile modifications the treasure passes OVER - a carry only stalls if a
  *carrying* pikmin can't cross that tile (a wall, or a hazard/emitter that pikmin
  isn't immune to, acts as a wall to it). Immune carriers glide a treasure across
  freely; a non-immune pikmin in the carrying group stalls the whole move. Enemies
  and another treasure pile still hard-block. (Only the carrying player's pikmin
  gate the move; contesting opponent pikmin ride along.)
- **Poison** (implemented 2026-07-14): poison spaces and **Poison Emitters do NOT
  block** — any pikmin walks over them freely (unlike fire/water/etc. which gate on
  immunity). Instead they deal **1 damage per colour per turn** to the active
  player's pikmin that *pass* a poison space (order-move path crosses it, or a normal
  carry exits it) or *idle* on one (end their turn there without moving). White,
  Bulbmin, and Winged are immune. Card-effect moves (Oatchi Rush) don't count as
  passing. Model: `exposedPoison`/`movedThisTurn` token flags → `game_poison_step`
  at move resolution; simplified to **1 per colour per turn** (not per-space).
- **Contested-carry hazard deaths** (implemented 2026-07-14): a pikmin dragged onto
  a blocking hazard it can't survive (e.g. an opponent's blue hauled onto fire) is
  lost when the treasure moves over it.
- **Known AI gap (fix in sharpening):** the AI's lane-blocker scan uses
  `game_space_has_card`, which counts a Poison Emitter as a blocker even though
  pikmin can walk past it — so the AI may over-value clearing poison it could ignore.

## ⚠️ Open questions (blockers for M2+)

1. ~~Board layout~~ ✅ all 16 real boards extracted from the Board Layouts tab's
   colored cells into `boards.json`: every board is 5 lanes x 7 spaces,
   mirror-symmetric, with difficulty, treasure set (TSet 1-7 or all), 3-6 basic
   colors, a matched pellet die, allowed structures (bridges/walls/emitters), and a
   killed-if-thrown-out-of-map flag. New space kind discovered: **chasm** (winged fly
   over; tunnels bridge it). Treasures regenerated to include all 7 numeric sets
   (353 cards); boards pick their treasure deck via `treasureSet`.
2. ~~Card lists~~ ✅ all decks received via the xlsx (enemy, treasure, gather, pellet,
   hazard, dice). Gather/treasure card *effects* are stored as text and still need
   engine implementations one by one (M3+).
3. ~~Pellet die faces~~ ✅ answered: 1 & 5 of each of the board's 3 basic colors,
   encoded per-board in `boards.json`.
4. ~~Pellet exchange rates~~ ✅ answered: 1-card → 2 matching / 1 other; 5-card → 5
   matching / 2 other.
5. **Starting hand:** do players start with gather cards, or only what the Gather
   Phase provides?
11. **CSV columns:** does `copies` (the first, unnamed column: 1/2/3) mean deck copies
    of that card? And what does the `tall` flag do (only the Grubchucker has it)?
6. **Day track length:** how many spaces before it resets, and are there midday events
   beyond enemy respawns planned for v1?
7. **Walls & bridges:** both are referenced (winged can't pass walls; bridges have
   health; Oatchi can damage walls) but not defined — these are the "building things
   on tiles" system. How are they built, what HP, who can pass?
8. **Scenarios:** which 3 basic colors per scenario, and which maps enable rock/ice?
9. **25-token cap:** confirmed per player (not global)?
10. **Stab:** rock pikmin resist "stabbed" — is stab an attack element like crush, and
    which enemies have it?
