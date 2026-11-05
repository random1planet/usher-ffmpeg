# usher-ffmpeg

The FFmpeg part of **Usher**, a private home media app for Apple TV, iPhone and iPad.

Usher uses two FFmpeg libraries, **libavcodec** and **libavutil**, to play standard-definition (SD) TV channels:
Freeview's SD channels use MPEG-2 video and MPEG-1 Layer II (MP2) sound, which Apple's own decoders don't play.
This repository holds exactly what is needed to rebuild those two libraries: FFmpeg's source as released, the build
script, and the exact settings used. It contains none of Usher's own code.

## What is here

| File | What it is |
|---|---|
| `source/ffmpeg-8.1.3.tar.xz` | FFmpeg 8.1.3's source, the official release tarball from <https://ffmpeg.org/releases/>, unchanged |
| `source/ffmpeg-8.1.3.tar.xz.asc` | FFmpeg's own signature for that tarball |
| `build-xcframework.sh` | the script that builds the two libraries for Usher |
| `BUILDINFO.txt` | the exact build: FFmpeg version, checksums, configure options, Xcode and SDK versions, sizes |
| `LICENSE` | the GNU Lesser General Public License, version 2.1 (FFmpeg's `COPYING.LGPLv2.1`) |
| `SHA256SUMS` | checksums of the files above |

FFmpeg itself is not changed in any way. The build only turns parts of it off (see below).

## Checking the source

The tarball is signed by FFmpeg's release signing key, fingerprint
`FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`, as published on <https://ffmpeg.org/download.html>.

```
curl https://ffmpeg.org/ffmpeg-devel.asc | gpg --import
gpg --verify source/ffmpeg-8.1.3.tar.xz.asc source/ffmpeg-8.1.3.tar.xz
shasum -a 256 -c SHA256SUMS
```

The tarball's SHA-256 is `7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3`. It is the same file
you can download from ffmpeg.org.

## What the build includes

Only what SD channels need, everything else switched off:

- decoders: `mpeg2video`, `mp2float` (the one Usher plays), `mp2` (used in Usher's tests);
- parsers: `mpegvideo`, `mpegaudio`;
- no encoders, no file formats, no network code, no filters;
- no GPL or non-free parts: the result is under the LGPL, version 2.1 or later.

The full configure line is in `BUILDINFO.txt`.

## Rebuilding the libraries

You need a Mac with Xcode (the build used Xcode 27.2) and `gpg`.

```
OUT=/path/to/a/folder ./build-xcframework.sh
```

The script checks the tarball's signature and checksum before it unpacks anything, builds libavutil and libavcodec
for four targets (Apple TV, Apple TV simulator, iPhone and iPad, iPhone and iPad simulator), and makes
`libavutil.xcframework` and `libavcodec.xcframework` in `$OUT/dist/UsherFFmpeg/`. It stops if the settings would
bring in GPL or non-free code. It takes the tarball from `source/`; without that folder it downloads it from ffmpeg.org.

## Replacing the libraries in Usher (relinking)

Usher loads these two libraries as separate dynamic frameworks, `libavcodec.framework` and `libavutil.framework`,
inside the app's `Frameworks` folder. They are never built into Usher's own code. To use your own build:

1. Build them with the script (you may change FFmpeg or the settings, as the LGPL allows).
2. Replace `Frameworks/libavcodec.framework` and `Frameworks/libavutil.framework` inside `Usher.app` with yours.
   Keep the same version (8.1.3) or another one with the same programming interface.
3. Sign the app again with your own Apple developer identity (`codesign`) and install it on your device.

## Licence

FFmpeg is free software, licensed under the GNU Lesser General Public License, version 2.1 or (at your option) any
later version. See `LICENSE`, or <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>.

FFmpeg is copyright the FFmpeg developers. More at <https://ffmpeg.org> and <https://ffmpeg.org/legal.html>.
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. This repository is not part of the FFmpeg
project and is not endorsed by it.

The build script and this README are offered under the same licence (LGPL 2.1 or later).
