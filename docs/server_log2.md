11-04 05:21:52.5930] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:52.5931] Slim::Player::Song::open (425) Transcoder: streamMode=F, streamformat=ops
[25-11-04 05:21:52.5933] Slim::Player::TranscodingHelper::tokenizeConvertCommand2 (668) Using command for conversion: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- "/music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 05 - No Easy Way Out.flac" | "/usr/bin/opusenc" --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=256 - - & |
[25-11-04 05:21:52.5934] Slim::Player::Song::open (586) Tokenized command: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- "/music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 05 - No Easy Way Out.flac" | "/usr/bin/opusenc" --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=256 - - & |
[25-11-04 05:21:52.6640] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:21:52.6656] Slim::Player::StreamingController::_Stream (1338) Song queue is now 4
[25-11-04 05:21:52.6658] Slim::Player::StreamingController::_setPlayingState (2419) new playing state BUFFERING
[25-11-04 05:21:52.6659] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:21:52.6678] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist index
[25-11-04 05:21:52.6688] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist stop
[25-11-04 05:21:52.6691] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:21:52.6694] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:21:52.6875] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:52.6877] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:52.7697] Slim::Player::StreamingController::playerTrackStarted (2242) 02:5e:64:d4:63:09
[25-11-04 05:21:52.7698] Slim::Player::StreamingController::_setPlayingState (2419) new playing state PLAYING
[25-11-04 05:21:52.7699] Slim::Player::StreamingController::_Playing (367) Song 4 has now started playing
[25-11-04 05:21:52.7701] Slim::Player::StreamingController::_Playing (396) Song queue is now 4
[25-11-04 05:21:52.7745] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist newsong
[25-11-04 05:21:52.7746] Plugins::DynamicMix::Plugin::isDynamicPlaylistActive (609) DynamicPlaylist not active
[25-11-04 05:21:52.7841] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:52.7842] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:54.6192] Slim::Player::Source::_readNextChunk (379) end of file or error on socket, song pos: 35337056
[25-11-04 05:21:54.6193] Slim::Player::Source::_readNextChunk (384) 02:5e:64:d4:63:09 mark end of stream
[25-11-04 05:21:54.6195] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMOUT
[25-11-04 05:21:55.0429] Slim::Player::StreamingController::playerReadyToStream (2260) 02:5e:64:d4:63:09
[25-11-04 05:21:55.0431] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:21:55.0438] Slim::Player::StreamingController::nextsong (888) The next song is number 5, was 4
[25-11-04 05:21:55.0451] Slim::Player::Song::new (110) index 5 -> file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:21:55.0453] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state TRACKWAIT
[25-11-04 05:21:55.0454] Slim::Player::Song::getNextSong (224) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:21:55.0456] Slim::Player::StreamingController::_nextTrackReady (743) 02:5e:64:d4:63:09: nextTrack will be index 5
[25-11-04 05:21:55.0457] Slim::Player::StreamingController::_Stream (1225) Song queue is now 5,4
[25-11-04 05:21:55.0458] Slim::Player::StreamingController::_Stream (1228) 02:5e:64:d4:63:09: preparing to stream song index 5
[25-11-04 05:21:55.0459] Slim::Player::Song::open (363) file:///music/The%20Protomen/The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20(2015)/The%20Protomen%20-%20The%20Cover%20Up%20-%20Original%20Soundtrack%20From%20the%20Motion%20Picture%20-%2006%20-%20Last%20Stop.flac
[25-11-04 05:21:55.0464] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:55.0466] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:55.0467] Slim::Player::Song::open (395) seek=false time=0 canSeek=2
[25-11-04 05:21:55.0469] Slim::Player::TranscodingHelper::getConvertCommand2 (494) Matched: flc->ops via: [flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [opusenc] --raw --raw-bits=$SAMPLESIZE$ --raw-rate=$SAMPLERATE$ --raw-chan=$CHANNELS$ --bitrate=256 - -
[25-11-04 05:21:55.0470] Slim::Player::Song::open (425) Transcoder: streamMode=F, streamformat=ops
[25-11-04 05:21:55.0473] Slim::Player::TranscodingHelper::tokenizeConvertCommand2 (668) Using command for conversion: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- "/music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 06 - Last Stop.flac" | "/usr/bin/opusenc" --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=256 - - & |
[25-11-04 05:21:55.0474] Slim::Player::Song::open (586) Tokenized command: "/lms/Bin/x86_64-linux/flac" -dcs --force-raw-format --sign=signed --endian=little -- "/music/The Protomen/The Cover Up - Original Soundtrack From the Motion Picture (2015)/The Protomen - The Cover Up - Original Soundtrack From the Motion Picture - 06 - Last Stop.flac" | "/usr/bin/opusenc" --raw --raw-bits=16 --raw-rate=44100 --raw-chan=2 --bitrate=256 - - & |
[25-11-04 05:21:55.1191] Slim::Player::StreamingController::_Stream (1299) 02:5e:64:d4:63:09: stream
[25-11-04 05:21:55.1212] Slim::Player::StreamingController::_Stream (1338) Song queue is now 5,4
[25-11-04 05:21:55.1214] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMING
[25-11-04 05:21:55.1219] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:21:55.1264] Plugins::DynamicMix::Plugin::commandCallback (371) DynamicMix: received command: playlist open
[25-11-04 05:21:56.0572] Slim::Player::Source::_readNextChunk (379) end of file or error on socket, song pos: 38317746
[25-11-04 05:21:56.0573] Slim::Player::Source::_readNextChunk (384) 02:5e:64:d4:63:09 mark end of stream
[25-11-04 05:21:56.0575] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state STREAMOUT
[25-11-04 05:21:56.4944] Slim::Player::StreamingController::playerReadyToStream (2260) 02:5e:64:d4:63:09
[25-11-04 05:21:56.4947] Slim::Player::StreamingController::_setStreamingState (2428) new streaming state IDLE
[25-11-04 05:21:56.4953] Slim::Player::StreamingController::_RetryOrNext (930) streaming track not started yet, will wait until then to try next track