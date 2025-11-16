# Alternative FLAC Transcode Using flac Encoder Instead of sox

## Current Rule (Using sox)
```
flc flc LyrPlay *
	# IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -r 44100 -C 0 -b 16 -
```

## Alternative Rule (Using flac encoder)
```
flc flc LyrPlay *
	# IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [flac] --endian=little --sign=signed --channels=$CHANNELS$ --sample-rate=$SAMPLERATE$ --bps=$SAMPLESIZE$ --force-raw-format --compression-level-0 - -o -
```

**Theory:** The `flac` encoder might handle streaming headers to stdout better than `sox`.

**To test:** Replace the rule in custom-convert.conf and restart LMS.
