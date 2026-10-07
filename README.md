# libVLC for Drive Player — corresponding source

This repository holds the complete corresponding source of the libVLC library that the Drive Player
Android app ships: `com.example.driveplayer.thirdparty:libvlc-lgpl`, a build of libVLC and its Java
bindings (libvlcjni) made from sources under the GNU Lesser General Public License 2.1 or more
permissive licenses only, for arm64-v8a.

Each published build of the library has a tag named after its version (`libvlc-lgpl-<version>`).
The tag holds exactly the sources, patches and build scripts that produced that build.

| Library version | Tag |
|---|---|
| 3.7.6-9 | `libvlc-lgpl-3.7.6-9` |
| 3.7.6-8 | `libvlc-lgpl-3.7.6-8` |
| 3.7.6-7 | `libvlc-lgpl-3.7.6-7` |
| 3.7.6-6 | `libvlc-lgpl-3.7.6-6` |
| 3.7.6-5 | `libvlc-lgpl-3.7.6-5` |
| 3.7.6-4 | `libvlc-lgpl-3.7.6-4` |
| 3.7.6-3 | `libvlc-lgpl-3.7.6-3` |
| 3.7.6-2 | `libvlc-lgpl-3.7.6-2` |
| 3.7.6-1 | `libvlc-lgpl-3.7.6-1` |

## Contents

| Path | What it is |
|---|---|
| `sources/libvlcjni-ddde54ff-drive-player.tar.xz` | libvlcjni at commit `ddde54fff93ab40c529a46eae80fe357ae0af97e`, with Drive Player's patches applied |
| `sources/vlc-66455a98-drive-player.tar.xz` | VLC media player 3.0 at commit `66455a98c8c515796b4a192acaa125c5d68c76c8`, with libvlcjni's patches and Drive Player's patches applied. It includes VLC's contrib build system (`contrib/src`), with the patches it applies to the third-party components |
| `sources/contrib/` | The source archives of the 24 third-party components linked into `libvlc.so`, as published by each project |
| `sources/SHA256SUMS` | Checksums of the archives above |
| `third-party/libvlc/build-native.sh` | The script that builds `libvlc.so`, `libvlcjni.so` and `libc++_shared.so` |
| `third-party/libvlc/patches/` | Drive Player's modifications to libvlcjni and VLC, as `git am` patches |
| `third-party/libvlc/aar/` | The Gradle build that packages the libraries and the Java bindings as an Android library (AAR) |
| `gradle/`, `gradlew` | The Gradle wrapper (Gradle 8.7) and the version entries the AAR build reads |

The layout of `third-party/libvlc/` and `gradle/` matches the Drive Player source tree, where the same
files are used unchanged.

## What was changed, and why

The libVLC published by VideoLAN on Maven Central (`org.videolan.android:libvlc-all`) statically links
components under the GNU General Public License. This build leaves every such component out:

- Third-party components are selected by an explicit list (`contrib_packages` in `build-native.sh`), and
  VLC's contrib system is run with its GPL and GPLv3 guards on. FFmpeg's configuration is checked to have
  its GPL, version 3 and non-free parts disabled.
- VLC modules that declare the GPL are not linked (`module_blacklist`), and the build stops if any
  linked module declares it.
- `patches/libvlcjni/0001-build-the-bindings-without-the-renderer-discoverer.patch`: the renderer
  discoverer's JNI part is removed, because `RendererDiscoverer.java` is published under the GPL. The AAR
  build leaves that Java file out of the packaged sources.
- `patches/vlc/0001-deinterlace-build-without-the-yadif-algorithm.patch`: the yadif algorithm, whose
  sources are published under the GPL, is removed from the deinterlace module.

Two further patches let the app serve a media's bytes through callbacks instead of a file descriptor
it answers itself. Such a descriptor (Android's proxy file descriptor) cannot be torn down when the
app's process is killed while libVLC waits on a read, and keeps a CPU core busy until the device
restarts:

- `patches/libvlcjni/0002-add-a-media-read-through-java-callbacks.patch`: `org.videolan.libvlc.MediaInput`
  and a `Media` constructor that reads through it (`libvlc_media_new_callbacks`).
- `patches/vlc/0002-imem-access-report-seekable-callbacks-as-fast-seekable.patch`: a callback input that
  answers seeks is read like a file, rather than through the prefetch filter's large background reads.

Two more keep the end of every track when the app moves on to the next one. VLC's Android audio output
ended its drain once it had written the audio to the `AudioTrack`; what the `AudioTrack` still held (twice
the device's minimum buffer, some 100 ms) was then discarded by the pause at the end of the media and by
the output's release:

- `patches/vlc/0003-audiotrack-drain-until-the-written-audio-has-been-pl.patch`: the drain waits until the
  `AudioTrack`'s playback head has reached the frames written, bounded by the time they take and 200 ms.
- `patches/vlc/0004-input-check-for-drained-decoders-at-the-end-more-oft.patch`: at the end of a stream the
  input checks for drained decoders every 10 ms rather than every 100 ms, so the end is reported as soon
  as the audio has been played.

One more lets the app open the next track ahead of time and hold it before its first sound
(`start-paused`), whatever its format. Pausing an input paused the decoders it had, but a decoder made
afterwards started unpaused. Ogg's demuxer finds its streams in the first data pages, after such an
input has paused, so an Ogg track (Vorbis, Opus) played the start it had buffered while it waited:

- `patches/vlc/0005-es_out-start-a-decoder-made-while-the-input-is-pause.patch`: a decoder made while the
  input is paused starts paused, as `input_DecoderChangePause`'s FIXME describes for a track added while
  paused.

Audio output initialization can miss the converted deadline of the first PCM buffer. The
original late-buffer policy then discarded the beginning of the media before the output had played
anything:

- `patches/vlc/0006-retain-pcm-at-delayed-audio-start.patch`: retain and retime the first buffer after
  output creation, restart or flush, and delay the shared input clock using its original stream
  timestamp. Pause is accounted for under the clock lock, and a flushing decoder does not rebase a
  seek from an in-flight buffer. Ordinary late buffers during playback retain the original drop policy.

Detaching views can race the Java binding's internal texture initialization. The texture and its
Surface were published separately, so release could dereference a not-yet-constructed Surface;
unattached callback loopers were also left alive:

- `patches/libvlcjni/0003-cancel-surface-initialization-on-view-release.patch`: publish both resources
  together, cancel pending initialization on detach, keep old waiters from acquiring a new
  attachment's resources, defer attached texture release to its GL owner, and join the callback
  thread without holding its monitor.

Some Android MediaCodec decoders report macroblock-aligned buffer dimensions without crop fields,
while their SurfaceTexture still applies the correct crop. Using those padded dimensions to fit the
picture creates extra black bars:

- `patches/vlc/0007-mediacodec-retain-visible-dimensions-without-crop.patch`: keep input/SPS visible
  dimensions separately from coded dimensions, use them for initial opaque output and for missing or
  invalid crop fields when they fit the output buffer, and update them when the SPS changes. Valid
  decoder crop rectangles remain authoritative.

Program and transport streams can identify video tracks before the decoder learns their dimensions
and pixel aspect. Reading parsed-media metadata early would then cache zero dimensions:

- `patches/libvlcjni/0004-expose-current-input-track-formats.patch`: expose
  `IMedia.getTracksSnapshot()` to read current native input formats, including visible dimensions,
  pixel aspect and orientation discovered during decoding. Parsed-media metadata keeps its cache.

Matroska's display aspect ratio uses the same width-to-height direction as pixel display units:

- `patches/vlc/0008-mkv-preserve-display-aspect-ratio.patch`: divide the declared display aspect by
  the visible picture aspect for `DisplayUnit=3`, instead of inverting the pixel aspect. A 384x288
  picture displayed as 16:9 has SAR 4:3, not 3:4.

MediaCodec's output format omits pixel aspect. An H.26x input whose container does not declare it
can therefore retain the opaque output's initial square pixels:

- `patches/vlc/0009-mediacodec-read-undeclared-pixel-aspect.patch`: read the current H.264/HEVC SPS
  when updating an output whose input did not specify pixel aspect. A container's declared ratio
  remains authoritative.

Features the app does not use are also left out: stream output (transcoding, recording, casting), network
access and streaming protocols, disc playback, Lua scripts, tag reading, service discovery, fontconfig, and
the modules listed in `module_blacklist`.

## Build

The native libraries are built inside VideoLAN's Android build image, which provides NDK r29 and the
tools VLC's build expects. The image is pinned by digest:

```
registry.videolan.org/vlc-debian-android@sha256:5f041ff50465aea803b93855d463f4b98f1d9f3be6628e304af2bf3fded6f98e
```

```bash
mkdir -p work
docker run --rm --init \
    --user "$(id -u):$(id -g)" \
    --volume "$PWD/work:/work" \
    --volume "$PWD/third-party/libvlc:/recipe:ro" \
    registry.videolan.org/vlc-debian-android@sha256:5f041ff50465aea803b93855d463f4b98f1d9f3be6628e304af2bf3fded6f98e \
    bash /recipe/build-native.sh
```

The libraries, the Java bindings and a record of the build (`build-info.txt`: revisions, component
versions, linked modules) are left in `work/out/`. The AAR is then packaged with JDK 21 and an Android SDK
with platform 36 (`ANDROID_HOME` set):

```bash
./gradlew -p third-party/libvlc/aar publish \
    -Plibvlc.nativeOutput="$PWD/work/out" \
    -Plibvlc.repository="$PWD/repository"
```

`build-native.sh` fetches the pinned libvlcjni and VLC commits and the component archives from their
upstream locations. To build from this repository's copies instead:

- Extract `sources/libvlcjni-*.tar.xz` to `work/src/libvlcjni` and `sources/vlc-*.tar.xz` to
  `work/src/libvlcjni/vlc`. These are the trees `build-native.sh` produces in its `fetch_sources` step,
  patches applied; run the remaining steps of `main` against them.
- Copy `sources/contrib/*` to `work/tarballs/`. VLC's contrib build uses the archives it finds there and
  verifies each against the SHA-512 it records in `contrib/src/<component>/SHA512SUMS`.

## Licenses

libVLC, libvlcjni and this build are distributed under the GNU Lesser General Public License, version 2.1
or later ([LICENSE](LICENSE)). Drive Player's build scripts and patches in this repository are provided
under the same license. Each third-party component in `sources/contrib/` is distributed under its own
license, found in its archive:

| License | Components |
|---|---|
| GNU LGPL 2.1 or later | FFmpeg, libdvbpsi, libebml, libmatroska, GNU FriBidi, GNU libiconv, libplacebo, libsoxr, mpg123 |
| BSD 2-Clause | dav1d, OpenJPEG |
| BSD 3-Clause | libogg, libFLAC, Opus, Speex |
| MIT | HarfBuzz ("Old MIT"), libxml2 |
| ISC | libass |
| FreeType Project License | FreeType |
| Independent JPEG Group License | libjpeg |
| PNG Reference Library License version 2 | libpng |
| zlib License | zlib |
| Boost Software License 1.0 | UTF8-CPP |
| GSM license (permissive) | libgsm |

The Android app links libVLC only as these shared libraries (`libvlc.so`, `libvlcjni.so`) through the
libvlcjni Java API, so a modified build made from these sources can take their place.
