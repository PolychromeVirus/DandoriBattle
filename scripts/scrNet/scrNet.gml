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

enum NETMSG {
    hello,     // joiner -> host: the joiner's name
    welcome,   // host   -> joiner: the host's name (handshake complete both ways)
    board,     // host   -> joiner: the board id the host is currently previewing
    start,     // host   -> joiner: launch THIS board id now
    state,     // either -> either: full game-state JSON (in-game sync)
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
        localSeat: 0,            // host = seat 0, joiner = seat 1
        previewBoard: "",        // host's live board choice (the joiner mirrors it in the preview pane)
        startBoard: "",          // set when START arrives (the joiner launches this board)
        pendingState: undefined, // last game-state JSON received, waiting to be applied in-game
    };
}

/// True while a session is host or join (not "off").
function net_online() { return variable_global_exists("net") && global.net.mode != "off"; }

/// HOST: open a server and wait for a joiner (result arrives as network_type_connect).
function net_host(_name) {
    net_close();
    global.net.mode = "host";
    global.net.localName = _name;
    global.net.localSeat = 0;
    global.net.server = network_create_server(network_socket_tcp, NET_PORT, 1);
    global.net.status = (global.net.server >= 0) ? "listening" : "failed";
    return global.net.server >= 0;
}

/// JOIN: connect to a host by IP. Blocking connect (instant on LAN; on a bad IP it stalls briefly
/// then reports "failed"). On success we introduce ourselves with HELLO; the host replies WELCOME.
function net_join(_ip, _name) {
    net_close();
    global.net.mode = "join";
    global.net.localName = _name;
    global.net.localSeat = 1;
    global.net.peer = network_create_socket(network_socket_tcp);
    if (global.net.peer < 0) { global.net.status = "failed"; return false; }
    if (network_connect(global.net.peer, _ip, NET_PORT) < 0) { global.net.status = "failed"; return false; }
    global.net.status = "connecting";      // socket open; handshake completes on WELCOME
    net_send(NETMSG.hello, global.net.localName);
    return true;
}

/// Send one message to the peer. _str is the payload (kept as a string; JSON for larger payloads).
function net_send(_type, _str) {
    if (!net_online() || global.net.peer < 0) return;
    var _buf = buffer_create(256, buffer_grow, 1);
    buffer_write(_buf, buffer_u8, _type);
    buffer_write(_buf, buffer_string, _str);
    network_send_packet(global.net.peer, _buf, buffer_tell(_buf));
    buffer_delete(_buf);
}

// convenience senders (host-only ones no-op on the joiner)
function net_send_board(_boardId) { if (global.net.mode == "host") net_send(NETMSG.board, _boardId); }
function net_send_start(_boardId) { if (global.net.mode == "host") net_send(NETMSG.start, _boardId); }
function net_send_state(_json)    { net_send(NETMSG.state, _json); }

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
    for (var _i = 0; _i < array_length(_g.treasures); _i++) {
        if (!variable_struct_exists(_g.treasures[_i], "boss")) _g.treasures[_i].boss = undefined;
    }
}

/// Dispatch an incoming message (called from the Async - Networking event).
function net_handle_message(_type, _str) {
    switch (_type) {
        case NETMSG.hello:                                   // host: the joiner introduced itself...
            global.net.remoteName = _str;
            net_send(NETMSG.welcome, global.net.localName);  // ...reply with our name -> both sides now paired
            global.net.status = "ready";
            break;
        case NETMSG.welcome:                                 // joiner: received the host's name
            global.net.remoteName = _str;
            global.net.status = "ready";
            break;
        case NETMSG.board:  global.net.previewBoard = _str; break;
        case NETMSG.start:  global.net.startBoard   = _str; break;
        case NETMSG.state:  global.net.pendingState = _str; break;
    }
}

/// The peer dropped (disconnect event, or a join that failed after the socket opened).
function net_on_disconnect() {
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
}
