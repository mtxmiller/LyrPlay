# Third-party notices

LyrPlay's own source code is released under the [MIT License](LICENSE). The components below are not LyrPlay's code. They keep their own licences, and the MIT License does not cover them.

## BASS, BASSFLAC and BASSOPUS

- **Copyright:** © un4seen developments, <https://www.un4seen.com>
- **In this repository:** `Frameworks/bass.xcframework`, `Frameworks/bassflac.xcframework`, `Frameworks/bassopus.xcframework`, `BASS_Headers/`
- **Licence:** proprietary, not open source. LyrPlay uses BASS under a commercial licence from un4seen.

BASS is free for non-commercial use. If you build and ship a product from this source that makes money (sales, in-app purchases, advertising), you need your own BASS licence from un4seen. LyrPlay's licence does not cover other people's products. See <https://www.un4seen.com> for the licence terms and prices.

BASS and its add-ons include decoders from these projects:

| Decoder | Used by | Copyright | Licence |
|---|---|---|---|
| minimp3 | BASS (MP3) | lieff, <https://github.com/lieff/minimp3> | CC0 1.0 |
| libogg / libvorbis | BASS (Ogg Vorbis) | © 2002-2020 Xiph.Org Foundation | BSD 3-clause |
| libFLAC | BASSFLAC | © 2000-2009 Josh Coalson, © 2011-2023 Xiph.Org Foundation | BSD 3-clause |
| libopus | BASSOPUS | © 2001-2011 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo | BSD 3-clause |

## CocoaAsyncSocket

- **Source:** <https://github.com/robbiehanson/CocoaAsyncSocket>, installed with CocoaPods
- **In this repository:** `Pods/CocoaAsyncSocket`
- **Licence:** public domain, or BSD at the user's choice. The full text is in [`Pods/CocoaAsyncSocket/LICENSE.txt`](Pods/CocoaAsyncSocket/LICENSE.txt).
