// Async - Networking: receives connection events + packets for the P2P layer (scrNet).
if (!variable_global_exists("net")) exit;

var _t = async_load[? "type"];

if (_t == network_type_connect) {
    // HOST: a joiner connected. Remember their socket as the peer we send through.
    global.net.peer = async_load[? "socket"];
    global.net.status = "connecting";                   // wait for their HELLO to complete the handshake
} else if (_t == network_type_disconnect) {
    net_on_disconnect();
} else if (_t == network_type_data) {
    var _buf = async_load[? "buffer"];
    var _size = async_load[? "size"];
    if (_buf >= 0 && _size >= 1) {
        buffer_seek(_buf, buffer_seek_start, 0);
        var _mt  = buffer_read(_buf, buffer_u8);
        var _str = buffer_read(_buf, buffer_string);
        net_handle_message(_mt, _str);
    }
}
