// ============================ P2P NETWORKING (LAN direct-IP) ============================
// Phase 1: the transport + message protocol. The HOST opens a TCP server on NET_PORT; the JOINER
// connects to the host's IP. TCP = reliable + ordered, ideal for a turn-based game. All connection
// state lives on `global.net`. The Async - Networking event on objGame (Other_68) receives packets
// and dispatches them via net_handle_message. Later phases stream the full game-state JSON
// (NETMSG.state) on every interaction so the opponent watches the turn unfold.
//
// Message wire format: [u8 type][string payload]. Sent with network_send_packet (GM frames it, so
// each network_type_data event delivers exactly one message).

#macro NET_PORT 6510
// LAN DISCOVERY (UDP beacon). The host announces itself ~once a second on this port; browsing
// clients bind a UDP socket to it and collect announcements, so games appear in the browser without
// anyone typing an IP. Deliberately a SEPARATE port from the TCP game port so a browsing client can
// listen without touching the game transport at all.
// LIMITS (inherent to broadcast, not to GameMaker): it does not cross subnets/VLANs, and some Wi-Fi
// access points enable client isolation which silently drops broadcast between wireless clients.
// That is exactly why manual "Join by IP" has to stay available as a fallback.
#macro NET_DISCOVERY_PORT 6511
#macro NET_BEACON_MS 1000       // how often the host announces
#macro NET_BEACON_STALE_MS 4000 // a host unheard-from for this long drops off the browser list
// network_create_server demands a concrete max_clients, so this number has to exist - but it is a
// FORMALITY, not a design limit, and deliberately set far above anything a LAN game would use.
// Spectators are uncapped by intent: the cost of each one is a full game JSON per state change on
// the host's uplink, which scales with the number of viewers and is therefore SELF-limiting - the
// host's own network decides how many is too many. Imposing a low ceiling here would just take that
// choice away from someone whose network could handle more. Raise it further if it ever binds.
#macro NET_MAX_CLIENTS 256

enum NETMSG {
    hello,     // client -> host: the client's name
    welcome,   // host   -> ONE client: JSON { hostName, seat, role } - the handshake + seat assignment
    board,     // host   -> all: the board id the host is currently previewing
    start,     // host   -> all: launch THIS board id now
    state,     // player -> host -> all: full game-state JSON (in-game sync; spectators only receive)
    chat,      // either -> either: a pre-formatted "<name>: <message>" log line
    roster,    // host   -> all: JSON array of { name, role, seat } - drives the lobby player list
    seat,      // host   -> ONE client: JSON { seat, role } - a seat reassignment after the handshake
    kick,      // host   -> ONE client: you've been removed (sent before the socket is destroyed)
    pause,     // host   -> all: "1"/"0" - a HOST-CONTROLLED pause that halts play for everyone
}

/// Initialise the global connection state. Called once at boot (objGame Create).
function net_init() {
    global.net = {
        mode: "off",             // "off" | "host" | "join"
        server: -1,              // host's listening socket
        peer: -1,                // the socket we SEND through (host: the accepted client; join: our own)
        status: "idle",          // idle | listening | connecting | ready | failed | disconnected | closed
        localName: "Player",
        remoteName: "",
        localSeat: 0,            // host = seat 0, the assigned player client = seat 1, SPECTATOR = -1
        role: "player",          // "player" | "spectator" - what WE are in this session
        previewBoard: "",        // host's live board choice (everyone else mirrors it in the preview pane)
        startBoard: "",          // set when START arrives (non-hosts launch this board)
        pendingState: undefined, // last game-state JSON received, waiting to be applied in-game
        // --- HOST ONLY ---
        clients: [],             // [{ sock, name, role, seat }] - every connected client (players AND spectators)
        stateWanted: [],         // sockets that connected mid-game and still need a full state push (drained in Step_0)
        // --- everyone (host builds it, clients receive it) ---
        roster: [],              // [{ name, role, seat }] for the lobby list, INCLUDING the host at index 0
        // --- LAN discovery (independent of mode: a browsing client is still "off") ---
        discSock: -1,            // UDP socket: bound for listening on a browser, unbound for sending on a host
        discFound: [],           // [{ ip, port, name, players, spectators, board, inGame, id, t }] - t = last-heard ms
        discLastBeacon: 0,
        sessionId: "",           // random per-session tag so a host can recognise (and ignore) its OWN beacon
        hostPort: NET_PORT,      // the TCP port we're actually hosting on (advertised in the beacon)
        netPaused: false,        // a HOST-CONTROLLED pause in force (applied to the local `paused` flag by Step_0)
        ctlDirty: false,         // our seat changed mid-game -> Step_0 must rebuild the local ctl array
        inGame: false,           // HOST: is a match actually under way? published every frame by Step_0 (scrNet can't see `mode`); gates mid-game seat assignment + the browser's LIVE/SETUP badge
    };
}

/// NET_SEAT_SPECTATOR: a seat index that can never equal game.activePlayer, so every existing
/// `activePlayer == localSeat` input gate and the Step_0 broadcast gate reject a spectator for free -
/// no new checks needed anywhere. Spectators additionally run ctl ["remote","remote"].
#macro NET_SEAT_SPECTATOR -1

function net_is_spectator() { return net_online() && global.net.localSeat == NET_SEAT_SPECTATOR; }

/// Display name of whoever holds a PLAYER seat (0 or 1), from the roster. A spectator is watching two
/// other people, so "you"/"the opponent" is meaningless to it - it needs both names by seat.
/// Falls back to "P1"/"P2" when the roster hasn't arrived or the seat is empty.
function net_seat_name(_seat) {
    if (variable_global_exists("net")) {
        var _r = global.net.roster;
        for (var _i = 0; _i < array_length(_r); _i++) if (_r[_i].seat == _seat) return _r[_i].name;
    }
    return "P" + string(_seat + 1);
}
function net_is_host()      { return net_online() && global.net.mode == "host"; }

/// True while a session is host or join (not "off").
function net_online() { return variable_global_exists("net") && global.net.mode != "off"; }

/// HOST: open a server and wait for a joiner (result arrives as network_type_connect). _port
/// defaults to NET_PORT but the lobby can override it (both sides must use the same port).
function net_host(_name, _port = NET_PORT) {
    net_close();
    global.net.mode = "host";
    global.net.localName = _name;
    // random per-session tag, so our own broadcast (which comes straight back to us on the same LAN)
    // is recognisable and ignored rather than showing up as a phantom game in our own browser
    global.net.sessionId = string(irandom(999999999)) + "-" + string(current_time);
    global.net.discLastBeacon = 0;
    global.net.localSeat = 0;       // the host is ALWAYS P1 - seat 1 and the spectator pool are handed out to clients
    global.net.role = "player";
    global.net.clients = [];
    global.net.hostPort = _port;    // the beacon has to advertise the REAL port - the host may not be on the default
    global.net.server = network_create_server(network_socket_tcp, _port, NET_MAX_CLIENTS);
    global.net.status = (global.net.server >= 0) ? "listening" : "failed";
    net_roster_rebuild();
    return global.net.server >= 0;
}

/// JOIN: connect to a host by IP. Blocking connect (instant on LAN; on a bad IP it stalls briefly
/// then reports "failed"). On success we introduce ourselves with HELLO; the host replies WELCOME.
/// _port must match the host's chosen port (defaults to NET_PORT).
function net_join(_ip, _name, _port = NET_PORT) {
    net_close();
    global.net.mode = "join";
    global.net.localName = _name;
    // provisional until WELCOME lands with our real assignment - spectator is the SAFE default, since
    // a client that wrongly believes it's a player could send state and corrupt the authoritative game
    global.net.localSeat = NET_SEAT_SPECTATOR;
    global.net.role = "spectator";
    global.net.peer = network_create_socket(network_socket_tcp);
    if (global.net.peer < 0) { global.net.status = "failed"; return false; }
    if (network_connect(global.net.peer, _ip, _port) < 0) { global.net.status = "failed"; return false; }
    global.net.status = "connecting";      // socket open; handshake completes on WELCOME
    net_send(NETMSG.hello, global.net.localName);
    return true;
}

// ============================== LAN DISCOVERY (UDP beacon) ==============================

/// BROWSER: start listening for host announcements. Binds a UDP socket to the discovery port
/// (network_create_socket_ext is the binding form - a plain network_create_socket gets an ephemeral
/// port and would never receive the broadcast). Safe to call repeatedly; no-ops if already listening.
function net_discovery_listen() {
    if (!variable_global_exists("net")) net_init();
    if (global.net.discSock >= 0) return true;
    global.net.discSock = network_create_socket_ext(network_socket_udp, NET_DISCOVERY_PORT);
    global.net.discFound = [];
    return global.net.discSock >= 0;
}

/// HOST: open an UNBOUND udp socket purely to send from. A host doesn't need to receive beacons, and
/// binding the discovery port on the host would collide with a browser running on the same machine.
function net_beacon_socket() {
    if (global.net.discSock >= 0) return global.net.discSock;
    global.net.discSock = network_create_socket(network_socket_udp);
    return global.net.discSock;
}

function net_discovery_stop() {
    if (!variable_global_exists("net")) return;
    if (global.net.discSock >= 0) network_destroy(global.net.discSock);
    global.net.discSock = -1;
    global.net.discFound = [];
}

/// HOST: announce this session to the LAN. Self-throttling (NET_BEACON_MS), so callers can just call
/// it every frame. _boardId / _inGame describe what's happening right now, so the browser can show a
/// live game as joinable-to-watch. _tcpPort is what a joiner must actually connect to - the host may
/// be on a non-default port, and the browser has no other way to learn it.
function net_beacon_tick(_boardId, _inGame, _tcpPort) {
    if (!net_is_host()) return;
    if (current_time - global.net.discLastBeacon < NET_BEACON_MS) return;
    global.net.discLastBeacon = current_time;
    var _sock = net_beacon_socket();
    if (_sock < 0) return;

    var _players = 1, _spec = 0;            // the host itself is always a player
    var _cl = global.net.clients;
    for (var _i = 0; _i < array_length(_cl); _i++) {
        if (_cl[_i].role == "player") _players += 1; else _spec += 1;
    }
    var _payload = json_stringify({
        id: global.net.sessionId, name: global.net.localName, port: _tcpPort,
        players: _players, spectators: _spec, board: _boardId, inGame: _inGame,
    });
    var _buf = buffer_create(256, buffer_grow, 1);
    buffer_write(_buf, buffer_string, _payload);
    network_send_broadcast(_sock, NET_DISCOVERY_PORT, _buf, buffer_tell(_buf));
    buffer_delete(_buf);
}

/// BROWSER: record (or refresh) a host we just heard from. Keyed on ip+port so two games on one
/// machine stay distinct. Refreshing an existing entry only stamps `t`, so list order stays stable
/// while browsing instead of reshuffling every second.
function net_discovery_heard(_ip, _payload) {
    var _d;
    try { _d = json_parse(_payload); } catch (_e) { return; }   // a stray packet on this port isn't fatal
    if (!is_struct(_d) || !variable_struct_exists(_d, "id")) return;
    if (net_is_host() && _d.id == global.net.sessionId) return;  // our own beacon looped back
    var _port = variable_struct_exists(_d, "port") ? _d.port : NET_PORT;
    var _f = global.net.discFound;
    for (var _i = 0; _i < array_length(_f); _i++) {
        if (_f[_i].ip == _ip && _f[_i].port == _port) {
            _f[_i].name = _d.name; _f[_i].players = _d.players; _f[_i].spectators = _d.spectators;
            _f[_i].board = _d.board; _f[_i].inGame = _d.inGame; _f[_i].t = current_time;
            return;
        }
    }
    array_push(_f, { ip: _ip, port: _port, name: _d.name, players: _d.players, spectators: _d.spectators,
                     board: _d.board, inGame: _d.inGame, id: _d.id, t: current_time });
}

/// BROWSER: drop hosts we haven't heard from recently, so a game that quit disappears on its own.
function net_discovery_prune() {
    if (!variable_global_exists("net")) return;
    var _f = global.net.discFound;
    for (var _i = array_length(_f) - 1; _i >= 0; _i--) if (current_time - _f[_i].t > NET_BEACON_STALE_MS) array_delete(_f, _i, 1);
}

/// Send one message to ONE socket. The single place a packet is actually written.
function net_send_to(_sock, _type, _str) {
    if (_sock < 0) return;
    var _buf = buffer_create(256, buffer_grow, 1);
    buffer_write(_buf, buffer_u8, _type);
    buffer_write(_buf, buffer_string, _str);
    network_send_packet(_sock, _buf, buffer_tell(_buf));
    buffer_delete(_buf);
}

/// Send to EVERYONE we're connected to. On the HOST that's a fan-out to every client (players and
/// spectators alike - a spectator is just a client that never sends anything back); on a client it's
/// the single socket to the host. Callers don't need to care which side they're on.
/// _exceptSock (optional) skips one client - used when relaying a message that came FROM that client.
function net_send(_type, _str, _exceptSock = -1) {
    if (!net_online()) return;
    if (global.net.mode == "host") {
        var _cl = global.net.clients;
        for (var _i = 0; _i < array_length(_cl); _i++) {
            if (_cl[_i].sock == _exceptSock) continue;
            net_send_to(_cl[_i].sock, _type, _str);
        }
    } else {
        net_send_to(global.net.peer, _type, _str);
    }
}

// convenience senders (host-only ones no-op on a client)
function net_send_board(_boardId) { if (net_is_host()) net_send(NETMSG.board, _boardId); }
function net_send_start(_boardId) { if (net_is_host()) net_send(NETMSG.start, _boardId); }
/// State from the P2 CLIENT has to be relayed by the host to every spectator - spectators are only
/// connected to the host, not to each other, so a client's packet reaches nobody else on its own.
function net_send_state(_json)    { net_send(NETMSG.state, _json); }

// --- host-side client bookkeeping ---

function net_client_find(_sock) {
    if (!net_is_host()) return undefined;
    var _cl = global.net.clients;
    for (var _i = 0; _i < array_length(_cl); _i++) if (_cl[_i].sock == _sock) return _cl[_i];
    return undefined;
}

/// Is seat 1 (the second PLAYER seat) already taken by some client?
function net_seat1_taken() {
    var _cl = global.net.clients;
    for (var _i = 0; _i < array_length(_cl); _i++) if (_cl[_i].seat == 1) return true;
    return false;
}

/// Rebuild the roster the lobby renders. The HOST is always entry 0 (seat 0, player); clients follow
/// in connection order. Host-only - clients get this list over the wire via NETMSG.roster.
function net_roster_rebuild() {
    if (!net_is_host()) return;
    var _r = [{ name: global.net.localName, role: "player", seat: 0 }];
    var _cl = global.net.clients;
    for (var _i = 0; _i < array_length(_cl); _i++) array_push(_r, { name: _cl[_i].name, role: _cl[_i].role, seat: _cl[_i].seat });
    global.net.roster = _r;
}

/// Rebuild + push the roster to everyone. Call after ANY membership or seat change.
function net_roster_broadcast() {
    if (!net_is_host()) return;
    net_roster_rebuild();
    net_send(NETMSG.roster, json_stringify(global.net.roster));
}

/// HOST: move a client between the P2 player seat and the spectator pool, and tell them about it.
/// _role is "player" or "spectator". Promoting to player when seat 1 is already held DEMOTES the
/// current holder first, so seat 1 can never end up double-assigned.
function net_assign_role(_sock, _role) {
    if (!net_is_host()) return;
    var _c = net_client_find(_sock);
    if (_c == undefined) return;
    if (_role == "player") {
        var _cl = global.net.clients;
        for (var _i = 0; _i < array_length(_cl); _i++) {
            if (_cl[_i].sock != _sock && _cl[_i].seat == 1) {
                _cl[_i].seat = NET_SEAT_SPECTATOR; _cl[_i].role = "spectator";
                net_send_to(_cl[_i].sock, NETMSG.seat, json_stringify({ seat: NET_SEAT_SPECTATOR, role: "spectator" }));
            }
        }
        _c.seat = 1; _c.role = "player";
    } else {
        _c.seat = NET_SEAT_SPECTATOR; _c.role = "spectator";
    }
    net_send_to(_sock, NETMSG.seat, json_stringify({ seat: _c.seat, role: _c.role }));
    if (_c.seat == 1) global.net.remoteName = _c.name;   // the HUD's "opponent" label follows the seat
    net_roster_broadcast();
}

/// HOST: remove a client from the session. Tells them first (so they can show "removed by the host"
/// rather than a bare connection drop), then destroys the socket. net_on_disconnect does the actual
/// bookkeeping - going through it rather than duplicating the removal means a kick and a client
/// simply vanishing end up in exactly the same state, including reopening seat 1.
function net_kick(_sock) {
    if (!net_is_host() || _sock < 0) return;
    net_send_to(_sock, NETMSG.kick, "1");
    network_destroy(_sock);
    net_on_disconnect(_sock);
}

/// HOST: pause or resume play for EVERYONE. Broadcast so clients halt too - otherwise the host freezes
/// while the others keep taking turns, which desyncs nothing (state is authoritative) but is baffling
/// to watch. The host's own `paused` flag is applied by Step_0 alongside the clients'.
function net_set_pause(_on) {
    if (!net_is_host()) return;
    global.net.netPaused = _on;
    net_send(NETMSG.pause, _on ? "1" : "0");
}

// --- game-state (de)serialization for the state sync ---
// The whole game struct is JSON. boardDef travels with it, so the peer gets the EXACT board -
// including a random board's decks (so random boards sync for free). Sent whenever the serialized
// state changes (see objGame Step). Turn-based + small (~KB), so this is plenty fast.
function net_serialize_game(_g) { return json_stringify(_g); }

function net_deserialize_game(_json) {
    if (_json == undefined || _json == "") return undefined;
    var _g = json_parse(_json);
    net_rehydrate(_g);
    return _g;
}

/// json_parse can drop members that were `undefined` at stringify time; the engine reads several of
/// them directly (`_g.pendingDiscard != undefined`, etc.), so make sure they exist after a round-trip.
function net_rehydrate(_g) {
    if (!variable_struct_exists(_g, "pendingDiscard")) _g.pendingDiscard = undefined;
    if (!variable_struct_exists(_g, "bombCue"))        _g.bombCue = undefined;
    if (!variable_struct_exists(_g, "combatFights"))   _g.combatFights = undefined;
    if (!variable_struct_exists(_g, "soothed"))        _g.soothed = false;
    if (!variable_struct_exists(_g, "bankCues"))       _g.bankCues = [];
    if (!variable_struct_exists(_g, "sfxCue"))         _g.sfxCue = [];
    if (!variable_struct_exists(_g, "dayRawFree"))     _g.dayRawFree = false;
    if (!variable_struct_exists(_g, "dayPelletBonus")) _g.dayPelletBonus = false;
    for (var _fp = 0; _fp < array_length(_g.players); _fp++) {
        if (!variable_struct_exists(_g.players[_fp], "flarlicBonus")) _g.players[_fp].flarlicBonus = 0;
        if (!variable_struct_exists(_g.players[_fp], "wildCount")) _g.players[_fp].wildCount = 0;
        if (!variable_struct_exists(_g.players[_fp], "glowUp")) _g.players[_fp].glowUp = false;
    }
    if (!variable_struct_exists(_g, "dayTrackDef"))    _g.dayTrackDef = game_day_track_default();
    if (!variable_struct_exists(_g, "pendingDaySwap")) _g.pendingDaySwap = undefined;
    if (!variable_struct_exists(_g, "pendingDayPlace")) _g.pendingDayPlace = undefined;
    if (!variable_struct_exists(_g, "pendingEvent"))    _g.pendingEvent = undefined;
    if (!variable_struct_exists(_g, "eventPending"))    _g.eventPending = [];
    if (!variable_struct_exists(_g, "pendingTypePick")) _g.pendingTypePick = undefined;
    if (!variable_struct_exists(_g, "pendingLose"))     _g.pendingLose = undefined;
    if (!variable_struct_exists(_g, "tileVersion")) _g.tileVersion = 0;
    // popHistory needs no special sync work - it's a plain array on _g, so json_stringify carries the
    // WHOLE history in every state packet. That's what makes the end-of-game graph survive both a
    // late join (the joiner receives the full history from turn 1, not just from the moment it
    // connected) and a disconnect (each side already holds a complete copy). This guard only covers
    // a state that arrives without the field at all - an older build, or a struct it was removed
    // from - so the graph degrades to empty instead of the array being missing outright.
    if (!variable_struct_exists(_g, "popHistory") || !is_array(_g.popHistory)) _g.popHistory = [];
    if (!variable_struct_exists(_g, "pendingSpy")) _g.pendingSpy = undefined;
    if (!variable_struct_exists(_g, "pendingReveal")) _g.pendingReveal = undefined;
    for (var _i = 0; _i < array_length(_g.treasures); _i++) {
        if (!variable_struct_exists(_g.treasures[_i], "boss")) _g.treasures[_i].boss = undefined;
    }
}

/// HOST: a client's socket opened. They're not seated until their HELLO arrives with a name.
function net_on_connect(_sock) {
    if (!net_is_host()) return;
    if (net_client_find(_sock) != undefined) return;
    array_push(global.net.clients, { sock: _sock, name: "...", role: "spectator", seat: NET_SEAT_SPECTATOR });
    global.net.status = "connecting";   // completes on their HELLO
}

/// Dispatch an incoming message (called from the Async - Networking event). _sock is the sender's
/// socket - the host needs it to tell its clients apart; a client can ignore it (only one peer).
function net_handle_message(_type, _str, _sock = -1) {
    switch (_type) {
        case NETMSG.hello:                                   // HOST: a client introduced itself
            if (!net_is_host()) break;
            var _c = net_client_find(_sock);
            if (_c == undefined) { net_on_connect(_sock); _c = net_client_find(_sock); }
            if (_c == undefined) break;
            _c.name = _str;
            // DEFAULT SEATING: in the LOBBY, the first client to arrive takes the free P2 seat and
            // everyone after is a spectator (the host can move anyone either way via net_assign_role).
            // ONCE THE GAME IS UNDER WAY, arrivals are ALWAYS spectators even when seat 1 is empty -
            // a game in progress has a committed board, hand and army for P2, so dropping a stranger
            // into that seat mid-match hands them someone else's position. Someone clicking "Watch"
            // means it. Host-side manual mid-game seat population is a deliberate LATER feature.
            if (!global.net.inGame && !net_seat1_taken()) { _c.seat = 1; _c.role = "player"; }
            else                                          { _c.seat = NET_SEAT_SPECTATOR; _c.role = "spectator"; }
            if (_c.role == "player") global.net.remoteName = _c.name;   // the HUD's "opponent" label
            net_send_to(_sock, NETMSG.welcome, json_stringify({ hostName: global.net.localName, seat: _c.seat, role: _c.role }));
            global.net.status = "ready";
            // a client that arrives MID-GAME needs the board launched and the current state pushed;
            // Step_0 drains this (scrNet can't see the `game` instance variable from here)
            array_push(global.net.stateWanted, _sock);
            net_roster_broadcast();
            break;

        case NETMSG.welcome: {                               // CLIENT: our handshake + seat assignment
            var _w = json_parse(_str);
            global.net.remoteName = _w.hostName;
            global.net.localSeat  = _w.seat;
            global.net.role       = _w.role;
            global.net.status     = "ready";
            break;
        }

        case NETMSG.seat: {                                  // CLIENT: the host moved us
            var _s = json_parse(_str);
            global.net.localSeat = _s.seat;
            global.net.role      = _s.role;
            // MID-GAME HANDOVER: our ctl array is baked at start_game_online and no longer matches the
            // seat we now hold, so Step_0 has to rebuild it. Until it does, a promoted spectator still
            // has ["remote","remote"] and couldn't act. The game state itself needs nothing - the
            // promoted player simply inherits the committed position from the ongoing full-state sync.
            global.net.ctlDirty = true;
            break;
        }

        case NETMSG.kick:                                    // CLIENT: the host removed us
            global.net.status = "kicked";
            break;

        case NETMSG.pause:                                   // CLIENT: host paused/resumed for everyone
            global.net.netPaused = (_str == "1");
            break;

        case NETMSG.roster: global.net.roster = json_parse(_str); break;
        case NETMSG.board:  global.net.previewBoard = _str; break;
        case NETMSG.start:  global.net.startBoard   = _str; break;

        case NETMSG.state:
            global.net.pendingState = _str;
            // RELAY: spectators are connected only to the host, so when the P2 CLIENT is the one
            // acting, its state packet would otherwise never reach them. The host forwards it to
            // everyone except the sender. (Host-authored state fans out via net_send already.)
            if (net_is_host()) net_send(NETMSG.state, _str, _sock);
            break;

        case NETMSG.chat:
            if (variable_instance_exists(id, "game") && game != undefined) game_log(game, chr(1) + _str); // chr(1) = chat marker
            if (net_is_host()) net_send(NETMSG.chat, _str, _sock);   // relay so spectators see it too
            break;
    }
}

/// A socket dropped. On the HOST that's one client leaving (the session continues for everyone
/// else); on a client it's the host going away, which ends the session.
function net_on_disconnect(_sock = -1) {
    if (net_is_host()) {
        var _cl = global.net.clients;
        for (var _i = array_length(_cl) - 1; _i >= 0; _i--) {
            if (_sock >= 0 && _cl[_i].sock != _sock) continue;
            var _wasPlayer = (_cl[_i].seat == 1);
            array_delete(global.net.clients, _i, 1);
            // Losing a SPECTATOR is a non-event. Losing the P2 player just REOPENS seat 1 - the host
            // is still hosting and any spectators are still watching, so this must NOT set
            // status "disconnected": that's the client-side "the session is over" signal, and the
            // lobby treats it as "leave and close", which would evict everyone over one departure.
            // The next client to say HELLO (or a host reassignment) fills the seat again.
            if (_wasPlayer) global.net.remoteName = "";
            if (_sock >= 0) break;
        }
        global.net.status = (array_length(global.net.clients) > 0) ? "ready" : "listening";
        net_roster_broadcast();
        return;
    }
    global.net.status = "disconnected";
    global.net.remoteName = "";
    global.net.peer = -1;
}

/// Tear down all sockets and reset to "off".
function net_close() {
    if (!variable_global_exists("net")) { net_init(); return; }
    // the joiner owns its client socket; the host's accepted client socket closes with the server
    if (global.net.mode == "join" && global.net.peer >= 0) network_destroy(global.net.peer);
    if (global.net.server >= 0) network_destroy(global.net.server);
    global.net.peer = -1;
    global.net.server = -1;
    global.net.mode = "off";
    global.net.status = "closed";
    global.net.remoteName = "";
    global.net.previewBoard = "";
    global.net.startBoard = "";
    global.net.pendingState = undefined;
    net_discovery_stop();           // drops the beacon/listen socket; the browser re-opens it on demand
    global.net.clients = [];        // accepted client sockets close with the server, so just drop the list
    global.net.stateWanted = [];
    global.net.roster = [];
    global.net.localSeat = 0;
    global.net.role = "player";
}
