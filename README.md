# MVCtoSBS
Converts 3D MVC (Multi-View Codec) files to SBS (side-by-side) or HSBS (half-side-by-side) MKV
Building in Swift around ffmpeg to encode in H264 or x265 (you can install this with Homebrew) and edge264-mvc to decode interleaved MVC Blu-Ray files (which it will install if needed).

Coded with Claude since the only program I found to do this was only for Windows [BD3D2MK3D](https://www.videohelp.com/software/BD3D2MK3D#download).

## Build
1. `xcode-select --install`   (once)
2. `brew install ffmpeg`      (once)
3. `./build_app.sh`           → produces `MVCtoSBS.app`

If macOS blocks the first launch: right-click the app → Open.

## Supported inputs
- **Frame-packed 3D** (1920×2205 / 1280×1470, or plain top/bottom) – the most common "3D Blu-ray MKV" release format
- **Two separate video streams** (left/right) in one MKV

## Blu-ray 3D (MVC) MKV input
Rip the 3D disc with MakeMKV and tick **both** the main video track and its child "MPEG4 MVC" track.
Add the resulting MKV: the app detects MVC automatically (one track with both views interleaved, or
two separate tracks), decodes both eyes with the open-source **edge264-mvc** decoder, and encodes
full or half SBS. Audio, chapters and (optionally) subtitles are copied from the original.

The decoder is a separate small program. Either click **Build decoder** in the app (needs git +
`xcode-select --install`), or build it yourself:

    git clone --depth 1 https://github.com/jens-duttke/edge264-mvc.git
    cd edge264-mvc && make STATIC=yes
    # then use "Locate…" on edge264mvc_test, or copy it next to build_app.sh before building the app

Pipeline: MKV reader (in-app) → `edge264mvc_test - -O` (side-by-side Y4M) → ffmpeg encoder.
Decoding is software-only, so MVC conversions use several CPU cores and take longer than other modes.

## Blu-ray input (unencrypted)
Add a disc folder (the one containing `BDMV`), a `.iso`, or a loose `.m2ts`.
The app reads the playlists (.mpls), defaults to the longest one, and lets you pick another
from a menu. ISOs are mounted read-only and detached automatically.
LPCM audio is converted losslessly to FLAC (MKV can't hold Blu-ray LPCM); other audio is copied.
If a 3D disc is authored as half top-and-bottom, tick "Source is half top-and-bottom 3D".

## Not supported
3D MVC straight from a disc folder/ISO (rip to MKV with MakeMKV first). Interlaced or non-4:2:0 / non-8-bit sources. ffmpeg cannot decode the
dependent view. The app detects these and tells you. Convert them first with
BD3D2MK3D (Windows/Wine), then use this app.

## Output
- Half SBS: 1920×1080 – what most 3D TVs / players expect (HSBS)
- Full SBS: 3840×1080
- Output is tagged `stereo_mode=left_right`; filename gets " - HSBS" or " - SBS".

## App icon
`Icon/AppIcon.icns` is used by `build_app.sh`. The source is `Icon/make_icon.py` (generates `AppIcon.svg`;
needs `pip install cairosvg`); edit it and re-run to change the artwork.
