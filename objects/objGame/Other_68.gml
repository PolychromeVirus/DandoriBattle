// Async - Networking: receives connection events + packets for the P2P layer (scrNet).
// The SOCKET is threaded through every branch now: the host holds many clients at once (one P2
// player plus any number of spectators), so "which socket" is what tells them apart. A client still
// only ever talks to one peer and can ignore it.
if (!variable_global_exists("net")) exit;

var _t = async_load[? "type"];

if (_t == network_type_connect) {
    // HOST: a client connected. It is NOT seated yet - it stays an unnamed spectator until its HELLO
    // arrives with a name, at which point net_handle_message assigns the free P2 seat or the pool.
    var _cs = async_load[? "socket"];
    global.net.peer = _cs;              // kept for the single-peer client path + legacy callers
    net_on_connect(_cs);
} else if (_t == network_type_disconnect) {
    net_on_disconnect(async_load[? "socket"]);
} else if (_t == network_type_data) {
    var _buf = async_load[? "buffer"];
    var _size = async_load[? "size"];
    var _sock = async_load[? "id"];
    if (_buf >= 0 && _size >= 1) {
        buffer_seek(_buf, buffer_seek_start, 0);
        // DISCOVERY packets arrive on the UDP socket and carry a bare JSON string (no NETMSG byte) -
        // told apart by which socket delivered them, not by content. async_load's "ip" is the
        // sender's address, which IS the address a joiner needs to connect to.
        if (_sock >= 0 && _sock == global.net.discSock) {
            net_discovery_heard(async_load[? "ip"], buffer_read(_buf, buffer_string));
        } else {
            var _mt  = buffer_read(_buf, buffer_u8);
            var _str = buffer_read(_buf, buffer_string);
            net_handle_message(_mt, _str, _sock);
        }
    }
}
