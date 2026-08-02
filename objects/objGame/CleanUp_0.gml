vertex_delete_buffer(groundVB);
if (tileVB != -1) vertex_delete_buffer(tileVB);
camera_destroy(camera);
card_sprites_free();
music_stop();  // stop any playing map music
carry_stop_all(); // stop any looping carry SFX
emitters_free();  // free spatial-audio emitters
net_close();   // close any open P2P sockets
