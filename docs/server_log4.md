[25-11-04 05:55:39.4570] Slim::Player::Squeezebox::stream (1071) strm-q
[25-11-04 05:55:39.4783] Slim::Player::StreamingController::_Stop (609) Song queue is now 5
[25-11-04 05:55:39.4786] Slim::Player::StreamingController::_setPlayingState (2419) new playing state STOPPED
[25-11-04 05:55:39.4788] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:55:39.4791] Slim::Player::StreamingController::nextsong (888) The next song is number 6, was 5
[25-11-04 05:55:39.4804] Slim::Player::Song::new (110) index 6 -> file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.4806] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state TRACKWAIT
[25-11-04 05:55:39.4821] Slim::Player::StreamingController::_playersMessage (795) Now Playing: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.4837] Slim::Player::Song::getNextSong (224) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.4839] Slim::Player::StreamingController::_nextTrackReady (743) 02:5e:64:d4:63:09: nextTrack will be index 6
[25-11-04 05:55:39.4840] Slim::Player::StreamingController::_Stream (1225) Song queue is now 6
[25-11-04 05:55:39.4841] Slim::Player::StreamingController::_Stream (1228) 02:5e:64:d4:63:09: preparing to stream song index 6
[25-11-04 05:55:39.4842] Slim::Player::Song::open (363) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.4846] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.4848] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.4849] Slim::Player::Song::open (395) seek=false time=0 canSeek=2
[25-11-04 05:55:39.4852] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.4852] Slim::Player::Song::open (425) Transcoder: streamMode=I, streamformat=flc
[25-11-04 05:55:39.4854] Slim::Player::Song::open (480) Opening stream (no direct streaming) using Slim::Player::Protocols::File [file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac]
[25-11-04 05:55:39.4856] Slim::Player::Protocols::File::open (81) duration: [394.453] size: [43549347] endian [] offset: [0] for file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.4857] Slim::Player::Protocols::File::open (98) Opening file /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 07 - In the Air Tonight.flac
[25-11-04 05:55:39.4859] Slim::Player::Protocols::File::open (190) Seeking in 0 into /music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 07 - In the Air Tonight.flac
[25-11-04 05:55:39.4860] Slim::Player::Song::open (510) URL is a song (audio): file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac, type=flc
[25-11-04 05:55:39.4863] Slim::Player::TranscodingHelper::tokenizeConvertCommand2 (668) Using command for conversion: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- - | "/lms/Bin/x86_64-linux/sox" -q -t raw --encoding signed-integer -b 16 -r 44100 -c 2 -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.4864] Slim::Player::Song::open (586) Tokenized command: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- - | "/lms/Bin/x86_64-linux/sox" -q -t raw --encoding signed-integer -b 16 -r 44100 -c 2 -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.5152] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:55:39.5155] Slim::Player::Squeezebox::stream_s (561) stream_s called: paused format: flc url: file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2007%20-%20In%20the%20Air%20Tonight.flac
[25-11-04 05:55:39.5157] Slim::Player::Squeezebox::stream_s (1019) Starting decoder with format: f flags: 0x0 autostart: 0 buffer threshold: 255 output threshold: 0 samplesize: ? samplerate: ? endian: ? channels: ?, transitionType: 2
[25-11-04 05:55:39.5159] Slim::Player::StreamingController::_Stream (1338) Song queue is now 6
[25-11-04 05:55:39.5161] Slim::Player::StreamingController::_setPlayingState (2419) new playing state BUFFERING
[25-11-04 05:55:39.5161] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:55:39.5179] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist index
[25-11-04 05:55:39.5232] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:39.5233] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:39.5248] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist stop
[25-11-04 05:55:39.5252] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:55:39.5254] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:55:39.5290] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:39.5470] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.5473] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:39.5830] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMf: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:40.4139] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMc: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:40.4314] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMs: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:40.4316] Slim::Player::StreamingController::playerTrackStarted (2242) 02:5e:64:d4:63:09
[25-11-04 05:55:40.4317] Slim::Player::StreamingController::_setPlayingState (2419) new playing state PLAYING
[25-11-04 05:55:40.4318] Slim::Player::StreamingController::_Playing (367) Song 6 has now started playing
[25-11-04 05:55:40.4322] Slim::Player::StreamingController::_Playing (396) Song queue is now 6
[25-11-04 05:55:40.4323] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:40.4327] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist newsong
[25-11-04 05:55:40.4329] Plugins::DynamicMix::Plugin::isDynamicPlaylistActive (609) DynamicPlaylist not active
[25-11-04 05:55:40.7393] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:40.7396] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->flc via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
[25-11-04 05:55:41.0130] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.512
[25-11-04 05:55:41.0136] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.521
[25-11-04 05:55:41.0238] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.512
[25-11-04 05:55:41.0542] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.369
[25-11-04 05:55:41.0919] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=442.239
[25-11-04 05:55:41.0941] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.581
[25-11-04 05:55:45.0108] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.518
[25-11-04 05:55:45.0138] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:45.0249] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:45.0532] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.368
[25-11-04 05:55:45.0889] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:a2:e9:1a: STAT-STMt: fullness=2097151, output_fullness=3324328, elapsed=95.575
[25-11-04 05:55:45.0917] Slim::Networking::Slimproto::_stat_handler (810) dc:a6:32:87:4a:51: STAT-STMt: fullness=2097151, output_fullness=3338240, elapsed=446.231
[25-11-04 05:55:49.0261] Slim::Networking::Slimproto::_stat_handler (810) b8:27:eb:16:b5:1a: STAT-STMt: fullness=2097151, output_fullness=3353080, elapsed=96.531
[25-11-04 05:55:49.0593] Slim::Networking::Slimproto::_stat_handler (810) 02:5e:64:d4:63:09: STAT-STMt: fullness=262144, output_fullness=4096, elapsed=0.000
[25-11-04 05:55:49.0648] Slim::Networking::Slimproto::_stat_handler (810) 00:00:00:00:00:00: STAT-STMt: fullness=394511, output_fullness=83707616, elapsed=4.379