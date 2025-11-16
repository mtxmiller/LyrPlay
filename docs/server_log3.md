[25-11-04 05:48:49.8216] Slim::Player::Song::open (480) Opening stream (no direct streaming) using Slim::Player::Protocols::File [file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac]
[25-11-04 05:48:49.8218] Slim::Player::Protocols::File::open (81) duration: [394.453] size: [43549347] endian [] offset: [0] for file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:48:49.8219] Slim::Player::Protocols::File::open (98) Opening file /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 07 - In the Air Tonight.flac
[25-11-04 05:48:49.8221] Slim::Player::Protocols::File::open (190) Seeking in 0 into /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 07 - In the Air Tonight.flac
[25-11-04 05:48:49.8223] Slim::Player::Song::open (510) URL is a song (audio): file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac, type=flc
[25-11-04 05:48:49.8266] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:48:49.8268] Slim::Player::Squeezebox::stream_s (561) stream_s called: format: flc url: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:48:49.8271] Slim::Player::Squeezebox::stream_s (954) Using smart transition mode
[25-11-04 05:48:49.8273] Slim::Player::Squeezebox::stream_s (1019) Starting decoder with format: f flags: 0x0 autostart: 1 buffer threshold: 255 output threshold: 0 samplesize: ? samplerate: ? endian: ? channels: ?, transitionType: 0
[25-11-04 05:48:49.8276] Slim::Player::StreamingController::_Stream (1338) Song queue is now 6,5
[25-11-04 05:48:49.8277] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:48:49.8282] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:48:49.8286] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:48:49.8396] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=1.062
[25-11-04 05:48:49.9654] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMc: fullness=262144, output_fullness=4096, elapsed=1.184
[25-11-04 05:48:49.9850] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=1.187
[25-11-04 05:48:51.1937] Slim::Player::Protocols::File::sysread (284) Trying to read past the end of file: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:48:51.1939] Slim::Player::Source::_readNextChunk (379) end of file or error on socket, song pos: 43549347, tell says: 43549347, totalbytes: 43549347
[25-11-04 05:48:51.1939] Slim::Player::Source::_readNextChunk (384) 02:5e:64:d4:63:09 mark end of stream
[25-11-04 05:48:51.1940] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMOUT
[25-11-04 05:48:51.6356] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMd: fullness=262144, output_fullness=4096, elapsed=2.859
[25-11-04 05:48:51.6358] Slim::Player::StreamingController::playerReadyToStream (2260) 02:5e:64:d4:63:09
[25-11-04 05:48:51.6359] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:48:51.6360] Slim::Player::StreamingController::_RetryOrNext (930) streaming track not started yet, will wait until then to try next track
[25-11-04 05:48:53.0145] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=4.236
[25-11-04 05:48:53.0173] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.523
[25-11-04 05:48:53.0335] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=4.236
[25-11-04 05:48:53.0372] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.563
[25-11-04 05:48:53.0403] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=34.178
[25-11-04 05:48:53.0514] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.373
[25-11-04 05:48:58.0137] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=9.236
[25-11-04 05:48:58.0153] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.524
[25-11-04 05:48:58.0352] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=9.236
[25-11-04 05:48:58.0414] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=39.186
[25-11-04 05:48:58.0454] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.570
[25-11-04 05:48:58.0537] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.363
[25-11-04 05:49:02.0147] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=13.237
[25-11-04 05:49:02.0163] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.525
[25-11-04 05:49:02.0214] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=43.159
[25-11-04 05:49:02.0256] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=13.237
[25-11-04 05:49:02.0539] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.375
[25-11-04 05:49:02.0595] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.584
[25-11-04 05:49:06.2873] Slim::Player::StreamingController::jumpToTime (2208) 02:5e:64:d4:63:09
[25-11-04 05:49:06.2876] Slim::Player::Squeezebox::stream (1071) strm-q
[25-11-04 05:49:06.2879] Slim::Player::StreamingController::_Stop (609) Song queue is now 5
[25-11-04 05:49:06.2880] Slim::Player::StreamingController::_setPlayingState (2419) new playing state STOPPED
[25-11-04 05:49:06.2881] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:49:06.2882] Slim::Player::StreamingController::_Stream (1151) 02:5e:64:d4:63:09: got song from params, song index 5
[25-11-04 05:49:06.2883] Slim::Player::StreamingController::_Stream (1225) Song queue is now 5
[25-11-04 05:49:06.2884] Slim::Player::StreamingController::_Stream (1228) 02:5e:64:d4:63:09: preparing to stream song index 5
[25-11-04 05:49:06.2885] Slim::Player::Song::open (363) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:49:06.2887] Slim::Player::Song::open (371) Adding seekdata { timeOffset => 67 }
[25-11-04 05:49:06.2892] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:49:06.2893] Slim::Player::Song::open (395) seek=true time=67 canSeek=1
[25-11-04 05:49:06.2895] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:49:06.2895] Slim::Player::Song::open (425) Transcoder: streamMode=I, streamformat=flc
[25-11-04 05:49:06.2896] Slim::Player::Song::open (480) Opening stream (no direct streaming) using Slim::Player::Protocols::File [file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac]
[25-11-04 05:49:06.2898] Slim::Player::Protocols::File::open (81) duration: [98.88] size: [9486277] endian [] offset: [0] for file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:49:06.2899] Slim::Player::Protocols::File::open (98) Opening file /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 06 - Last Stop.flac
[25-11-04 05:49:06.2901] Slim::Player::Protocols::File::_timeToOffset (355) seeking using Slim::Formats::FLAC findFrameBoundaries(6427796, 67)
[25-11-04 05:49:06.2903] Slim::Player::Protocols::File::_timeToOffset (367) 67 -> 6734102 (align: 1 size: 9486277 duration: 98.88)
[25-11-04 05:49:06.2905] Slim::Player::Protocols::File::open (190) Seeking in 6734102 into /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 06 - Last Stop.flac
[25-11-04 05:49:06.2906] Slim::Player::Song::open (510) URL is a song (audio): file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac, type=flc
[25-11-04 05:49:06.2919] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:49:06.2920] Slim::Player::Squeezebox::stream_s (561) stream_s called: format: flc url: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:49:06.2923] Slim::Player::Squeezebox::stream_s (954) Using smart transition mode
[25-11-04 05:49:06.2925] Slim::Player::Squeezebox::stream_s (1019) Starting decoder with format: f flags: 0x0 autostart: 1 buffer threshold: 255 output threshold: 0 samplesize: ? samplerate: ? endian: ? channels: ?, transitionType: 0
[25-11-04 05:49:06.2927] Slim::Player::StreamingController::_Stream (1338) Song queue is now 5
[25-11-04 05:49:06.2928] Slim::Player::StreamingController::_setPlayingState (2419) new playing state BUFFERING
[25-11-04 05:49:06.2929] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:49:06.2938] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:49:06.2941] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:49:06.2996] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=17.523
[25-11-04 05:49:06.3036] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=17.523
[25-11-04 05:49:06.3091] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:49:06.3146] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=17.527
[25-11-04 05:49:06.3147] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=17.527
[25-11-04 05:49:06.3537] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMc: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:06.3655] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMs: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:06.3657] Slim::Player::StreamingController::playerTrackStarted (2242) 02:5e:64:d4:63:09
[25-11-04 05:49:06.3658] Slim::Player::StreamingController::_setPlayingState (2419) new playing state PLAYING
[25-11-04 05:49:06.3659] Slim::Player::StreamingController::_Playing (367) Song 5 has now started playing
[25-11-04 05:49:06.3662] Slim::Player::StreamingController::_Playing (396) Song queue is now 5
[25-11-04 05:49:06.3663] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:06.3705] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist newsong
[25-11-04 05:49:06.3707] Plugins::DynamicMix::Plugin::isDynamicPlaylistActive (609) DynamicPlaylist not active
[25-11-04 05:49:06.6720] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: -
[25-11-04 05:49:07.0130] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:07.0135] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=48.157
[25-11-04 05:49:07.0144] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.523
[25-11-04 05:49:07.0238] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:07.0517] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.374
[25-11-04 05:49:07.0592] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.583
[25-11-04 05:49:11.0130] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=52.156
[25-11-04 05:49:11.0134] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:11.0145] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.521
[25-11-04 05:49:11.0250] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:11.0506] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.575
[25-11-04 05:49:11.0517] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.364
[25-11-04 05:49:15.0127] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=56.157
[25-11-04 05:49:15.0136] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:15.0145] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.522
[25-11-04 05:49:15.0249] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:15.0466] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.572
[25-11-04 05:49:15.0516] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.373
[25-11-04 05:49:20.0131] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:20.0176] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.524
[25-11-04 05:49:20.0242] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:20.0539] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.374
[25-11-04 05:49:20.0576] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=61.202
[25-11-04 05:49:20.0637] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.586
[25-11-04 05:49:24.0131] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:24.0179] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=65.158
[25-11-04 05:49:24.0196] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.523
[25-11-04 05:49:24.0229] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:49:24.0531] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.364