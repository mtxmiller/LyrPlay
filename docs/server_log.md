[25-11-04 05:06:10.2628] Slim::Player::StreamingController::_setPlayingState (2419) new playing state PLAYING
[25-11-04 05:06:10.2629] Slim::Player::StreamingController::_Playing (361) Song 0 is not longer in the queue
[25-11-04 05:06:10.2630] Slim::Player::StreamingController::_Playing (367) Song 1 has now started playing
[25-11-04 05:06:10.2634] Slim::Player::StreamingController::_Playing (396) Song queue is now 1
[25-11-04 05:06:10.2634] Slim::Player::StreamingController::_PlayAndNext (1375) now playing already fully streaming song => get next
[25-11-04 05:06:10.2635] Slim::Player::StreamingController::nextsong (888) The next song is number 2, was 1
[25-11-04 05:06:10.2646] Slim::Player::Song::new (110) index 2 -> file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.2648] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state TRACKWAIT
[25-11-04 05:06:10.2649] Slim::Player::Song::getNextSong (224) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.2650] Slim::Player::StreamingController::_nextTrackReady (743) 02:5e:64:d4:63:09: nextTrack will be index 2
[25-11-04 05:06:10.2651] Slim::Player::StreamingController::_Stream (1225) Song queue is now 2,1
[25-11-04 05:06:10.2652] Slim::Player::StreamingController::_Stream (1228) 02:5e:64:d4:63:09: preparing to stream song index 2
[25-11-04 05:06:10.2653] Slim::Player::Song::open (363) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.2657] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:06:10.2658] Slim::Player::Song::open (395) seek=false time=0 canSeek=1
[25-11-04 05:06:10.2660] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:06:10.2661] Slim::Player::Song::open (425) Transcoder: streamMode=I, streamformat=flc
[25-11-04 05:06:10.2661] Slim::Player::Song::open (480) Opening stream (no direct streaming) using Slim::Player::Protocols::File [file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac]
[25-11-04 05:06:10.2663] Slim::Player::Protocols::File::open (81) duration: [210.026] size: [27421548] endian [] offset: [0] for file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.2664] Slim::Player::Protocols::File::open (98) Opening file /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 03 - Princes of the Universe.flac
[25-11-04 05:06:10.2666] Slim::Player::Protocols::File::open (190) Seeking in 0 into /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 03 - Princes of the Universe.flac
[25-11-04 05:06:10.2667] Slim::Player::Song::open (510) URL is a song (audio): file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac, type=flc
[25-11-04 05:06:10.2712] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:06:10.2715] Slim::Player::Squeezebox::stream_s (561) stream_s called: format: flc url: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.2718] Slim::Player::Squeezebox::stream_s (954) Using smart transition mode
[25-11-04 05:06:10.2719] Slim::Player::Squeezebox::stream_s (1019) Starting decoder with format: f flags: 0x0 autostart: 1 buffer threshold: 255 output threshold: 0 samplesize: ? samplerate: ? endian: ? channels: ?, transitionType: 0
[25-11-04 05:06:10.2722] Slim::Player::StreamingController::_Stream (1338) Song queue is now 2,1
[25-11-04 05:06:10.2723] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:06:10.2785] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist newsong
[25-11-04 05:06:10.2787] Plugins::DynamicMix::Plugin::isDynamicPlaylistActive (609) DynamicPlaylist not active
[25-11-04 05:06:10.2793] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:06:10.2797] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:06:10.2863] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=0.024
[25-11-04 05:06:10.3563] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:06:10.4321] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMc: fullness=262144, output_fullness=4096, elapsed=0.169
[25-11-04 05:06:10.4467] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.170
[25-11-04 05:06:10.9814] Slim::Player::Protocols::File::sysread (284) Trying to read past the end of file: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2003%20-%20Princes%20of%20the%20Universe.flac
[25-11-04 05:06:10.9816] Slim::Player::Source::_readNextChunk (379) end of file or error on socket, song pos: 27421548, tell says: 27421548, totalbytes: 27421548
[25-11-04 05:06:10.9817] Slim::Player::Source::_readNextChunk (384) 02:5e:64:d4:63:09 mark end of stream
[25-11-04 05:06:10.9818] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMOUT
[25-11-04 05:06:11.4245] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMd: fullness=262144, output_fullness=4096, elapsed=1.162
[25-11-04 05:06:11.4247] Slim::Player::StreamingController::playerReadyToStream (2260) 02:5e:64:d4:63:09
[25-11-04 05:06:11.4249] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:06:11.4250] Slim::Player::StreamingController::_RetryOrNext (930) streaming track not started yet, will wait until then to try next track
[25-11-04 05:06:14.0134] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=3.752
[25-11-04 05:06:14.0215] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.521
[25-11-04 05:06:14.0244] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=3.753