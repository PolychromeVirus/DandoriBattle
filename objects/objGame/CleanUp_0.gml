vertex_delete_buffer(groundVB);
if (tileVB != -1) vertex_delete_buffer(tileVB);
camera_destroy(camera);
card_sprites_free();
net_close();   // close any open P2P sockets
