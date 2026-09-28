#!/usr/bin/env bash
#
# Builds the native half of Drive Player's libVLC — libvlc.so, libvlcjni.so and libc++_shared.so
# for arm64-v8a — from sources licensed under the GNU LGPL 2.1 or more permissively, and with only
# what the app plays.
#
# `./local_build.sh --build-libvlc` runs this inside VideoLAN's own Android build image, so the NDK
# and every tool the contribs expect are the ones VideoLAN builds libVLC with. It mounts
#   /recipe  this directory, read-only;
#   /work    .local_build/libvlc/work: tarballs/ keeps the contribs' source downloads between
#            runs (each is checked against VLC's recorded SHA-512), and src/, out/ and home/ are
#            recreated by every run, so nothing an earlier recipe built can leak into this one.
# It leaves in /work/out:
#   jni/arm64-v8a/   the libraries the AAR ships, stripped;
#   bindings/        the libvlcjni Java sources, resources and manifest the AAR is compiled from;
#   licenses/        each built component's own license files, for the legal notice;
#   build-info.txt   the pinned revisions, the contribs built and the modules linked.
#
# The steps are those of libvlcjni's buildsystem/compile-libvlc.sh at the pinned commit — its
# toolchain setup, its static module table and its ndk-build of the libraries. What goes in is where
# this build differs, and each difference is stated where it is made:
#  - contribs: an exact allowlist, built with the GPL and GPLv3 guards on (contrib_packages), and
#    FFmpeg's own license checked after it is configured;
#  - VLC: stream output, networking, discs, Lua, discovery and the other unused features are
#    configured out (vlc_configure_args);
#  - modules: upstream's exclusions plus the GPL-licensed and unused ones (module_blacklist), and
#    the build stops if any module left declares the GPL;
#  - patches/: the few source changes the LGPL-only result needs.
# When the pin moves, diff upstream's compile-libvlc.sh between the two commits and carry what
# changed over to this script.

set -euo pipefail

readonly LIBVLCJNI_REPOSITORY="https://code.videolan.org/videolan/libvlcjni.git"
# libvlcjni-3.x as of its libvlcVersion 3.7.6. The branch carries no release tags, so the pin is
# the commit; the VLC revision comes from that commit's buildsystem/get-vlc.sh.
readonly LIBVLCJNI_COMMIT="ddde54fff93ab40c529a46eae80fe357ae0af97e"
readonly VLC_REPOSITORY="https://code.videolan.org/videolan/vlc.git"

# 64-bit ARM only: every device this app targets has it, and one ABI is a quarter of the build time
# and of the APK's native payload. upstream builds 64-bit ABIs against API 21 with NDK r27–r29.
readonly ANDROID_ABI="arm64-v8a"
readonly TARGET_TUPLE="aarch64-linux-android"
readonly ANDROID_API=21

readonly RECIPE_DIR="/recipe"
readonly WORK_DIR="/work"
readonly TARBALLS_DIR="$WORK_DIR/tarballs"
readonly SRC_DIR="$WORK_DIR/src"
readonly OUT_DIR="$WORK_DIR/out"
readonly LIBVLCJNI_DIR="$SRC_DIR/libvlcjni"
readonly VLC_DIR="$LIBVLCJNI_DIR/vlc"
readonly VLC_BUILD_DIR="$VLC_DIR/build-android-$TARGET_TUPLE"
readonly CONTRIB_BUILD_DIR="$VLC_DIR/contrib/contrib-android-$TARGET_TUPLE"
readonly CONTRIB_PREFIX="$VLC_DIR/contrib/$TARGET_TUPLE"

# The contribs linked into libvlc.so, dependencies included. The contrib system is started with
# every package deselected and these selected, and the build stops if the set it resolves differs
# in any way — so a package is built only when it is listed here, and each one listed has its
# license in the legal notice. Why each is here:
#   ffmpeg (+ zlib, gsm, openjpeg, its own dependencies)  demuxing and decoding of most formats;
#     built without encoders, muxers or network protocols
#   dav1d                           AV1
#   ogg opus flac speex             the Xiph formats; Vorbis and Theora are decoded by FFmpeg,
#                                   because VLC's own modules for them also want the encoders
#   mpg123                          MP3
#   soxr                            audio resampling
#   ebml matroska (+ utfcpp)        Matroska / WebM
#   dvbpsi                          MPEG-TS
#   ass freetype2 fribidi harfbuzz (+ png, iconv)  subtitle rendering
#   libxml2                         the Android font list the text renderer reads, and TTML
#   jpeg                            linked by libvlcjni's own Android.mk
#   libplacebo                      the OpenGL output's color conversion and tone mapping
# fontconfig is deliberately absent: without it, the text renderer reads Android's font list
# instead of scanning every system font on first use.
contrib_packages=(
    ass dav1d dvbpsi ebml ffmpeg flac freetype2 fribidi gsm harfbuzz iconv jpeg libplacebo
    libxml2 matroska mpg123 ogg openjpeg opus png soxr speex utfcpp zlib
)

# VLC's own configure switches. Everything that would need a contrib outside the list above is
# switched off explicitly rather than left to detection, so a stray package cannot switch it on.
vlc_configure_args=(
    # As upstream.
    --with-pic --disable-nls --disable-vlc --disable-shared --disable-update-check
    --disable-vlm --disable-dbus --disable-vcd --disable-v4l2 --disable-linsys --disable-decklink
    --disable-libva --disable-dv1394 --disable-sid --disable-tremor --disable-mad --disable-dca
    --disable-sdl-image --disable-fluidsynth --disable-jack --disable-pulse --disable-alsa
    --disable-samplerate --disable-xcb --disable-qt --disable-skins2 --disable-mtp
    --disable-notify --disable-svg --disable-udev --disable-caca --disable-goom
    --disable-projectm --disable-faad --disable-vnc
    --enable-avformat --enable-swscale --enable-avcodec --enable-opus --enable-opensles
    --enable-matroska --enable-dvbpsi --enable-mpg123 --enable-libass --enable-libxml2
    --enable-gles2 --enable-jpeg
    # Upstream enables these; this build leaves them out. Stream output (transcoding, recording,
    # casting), Lua scripts, tag reading, discs, tracker and chiptune formats, teletext through
    # zvbi, MIDI, and the network shares.
    --disable-sout --disable-lua --disable-taglib --disable-bluray --disable-dvdread
    --disable-dvdnav --disable-mod --disable-gme --disable-zvbi --disable-fluidlite
    --disable-smb2 --disable-live555
    # Further features off: fontconfig (see contrib_packages), the codec modules whose formats
    # FFmpeg decodes (vorbis, theora, vpx, aom), archives, discovery, remote access, TLS and
    # credential stores, and the remaining encoders.
    --disable-fontconfig --disable-vorbis --disable-theora --disable-vpx --disable-aom
    --disable-archive --disable-upnp
    --disable-microdns --disable-nfs --disable-sftp --disable-spatialaudio --disable-gnutls
    --disable-libgcrypt --disable-secret --disable-kwallet --disable-avahi --disable-realrtsp
    --disable-addonmanagermodules --disable-shout --disable-twolame --disable-shine
    --disable-x264 --disable-kate --disable-tiger --disable-libcddb
    # The contribs above, required rather than detected.
    --enable-dav1d --enable-flac --enable-speex --enable-ogg --enable-soxr
    --enable-freetype --enable-fribidi --enable-harfbuzz --enable-png --enable-libplacebo
)

# Modules built but not linked, as extended regular expressions over the module name (the part of
# lib<name>_plugin.a between "lib" and "_plugin.a"), matched whole.
module_blacklist=(
    # upstream's list
    'addons.*' stats 'access_(bd|shm|imem)' oldrc real hotkeys gestures sap dynamicoverlay rss
    ball 'audiobargraph_[av]' clone mosaic osdmenu puzzle mediadirs t140 ripple motion sharpen
    grain posterize mirror wall scene blendbench psychedelic alphamask netsync audioscrobbler
    motiondetect motionblur export podcast bluescreen erase stream_filter_record speex_resampler
    remoteosd magnify gradient dtstofloat32 logger visual fb aout_file yuv '.dummy'
    # Declared under the GPL: the dummy interface, the file and syslog loggers, the RTSP VoD
    # server, three channel mixers and two video filters.
    dummy file_logger syslog vod_rtsp headphone_channel_mixer mono dolby_surround_decoder rotate
    hqdn3d
    # Modules that write what they read to a file (the demux dumper, the stream recorder, the
    # file audio output): nothing here may write media anywhere.
    demuxdump record afile
    # Inputs other than the app's own, which serves every byte through libVLC's callback input
    # (the imem module, behind patches/libvlcjni/0002): network access and streaming protocols,
    # tuners, shared memory, and the external decompressor, which forks a process.
    http https access_http adaptive access_mms ftp udp tcp rtp rist satip sdp vdr avio
    hds smooth access_concat unixsocket shm dtv dvb timecode decomp directory_demux noseek
    # Outputs and services the app does not use: memory audio, the network LED-wall display,
    # the audio fingerprinter, cover art from the media's folder and the console log. (The OMX
    # module, iomx, stays: the MediaCodec decoder links its picture-copy routines.)
    amem flaschen fingerprinter folder console_logger
    # Credential stores, which only network access asks.
    '(memory|file)_keystore'
    # Playlist files, external subtitle files and the video filters nothing enables.
    playlist subtitle vobsub stl smf canvas croppadd fps freeze gaussianblur gradfun extract
    invert colorthres edgedetection anaglyph antiflicker sepia oldmovie vhs logo marq subsdelay
    vmem
    # Audio effects nothing enables, and S/PDIF passthrough.
    normvol compressor param_eq chorus_flanger karaoke stereo_widen spatializer stereo_pan
    tospdif
)

# What VLC embeds, verbatim, in a module that declares itself GPL-licensed.
readonly VLC_GPL_LICENSE_TEXT="Licensed under the terms of the GNU General Public License, version 2 or later."

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

# Fetches exactly one commit, without history: the pins name commits, not branches.
fetch_commit() {
    local dir="$1" repository="$2" commit="$3"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$repository" "$commit"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

apply_patches() {
    local dir="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    git -C "$dir" -c user.name="Drive Player" -c user.email="drive-player@localhost" \
        am -q --message-id "$@"
}

fetch_sources() {
    log "Fetching libvlcjni $LIBVLCJNI_COMMIT"
    fetch_commit "$LIBVLCJNI_DIR" "$LIBVLCJNI_REPOSITORY" "$LIBVLCJNI_COMMIT"
    apply_patches "$LIBVLCJNI_DIR" "$RECIPE_DIR"/patches/libvlcjni/*.patch

    VLC_COMMIT="$(sed -n 's/^VLC_TESTED_HASH=\([0-9a-f]*\)$/\1/p' "$LIBVLCJNI_DIR/buildsystem/get-vlc.sh")"
    [ -n "$VLC_COMMIT" ] || die "libvlcjni's get-vlc.sh no longer names VLC_TESTED_HASH"
    log "Fetching VLC $VLC_COMMIT"
    fetch_commit "$VLC_DIR" "$VLC_REPOSITORY" "$VLC_COMMIT"
    # libvlcjni's patches first, as its get-vlc.sh applies them, then this build's own.
    apply_patches "$VLC_DIR" "$LIBVLCJNI_DIR"/libvlc/patches/*.patch
    apply_patches "$VLC_DIR" "$RECIPE_DIR"/patches/vlc/*.patch
}

setup_toolchain() {
    [ -n "${ANDROID_NDK:-}" ] || die "ANDROID_NDK is not set; this runs inside VideoLAN's Android image."
    NDK_RELEASE="$(sed -n 's/^Pkg.Revision *= *\([0-9]*\)\..*/\1/p' "$ANDROID_NDK/source.properties")"
    case "$NDK_RELEASE" in
        27|28|29) ;;
        *) die "libvlcjni builds 64-bit ABIs with NDK r27–r29; the image has r$NDK_RELEASE." ;;
    esac

    local toolchain="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    export PATH="$VLC_DIR/extras/tools/build/bin:$toolchain:$PATH"
    CROSS_TOOLS="$toolchain/llvm-"
    CROSS_CLANG="$toolchain/${TARGET_TUPLE}${ANDROID_API}-clang"
    NDK_BUILD="$ANDROID_NDK/ndk-build"
    MAKEFLAGS_JOBS="-j$(nproc)"

    # Release flags, as upstream's --release.
    VLC_CFLAGS="-g -O2 -fPIC -fdata-sections -ffunction-sections -funwind-tables -fstack-protector-strong -no-canonical-prefixes -DNDEBUG"
    VLC_CXXFLAGS="-fexceptions -frtti -fdata-sections -ffunction-sections"
    VLC_LDFLAGS="-z max-page-size=16384"
}

build_tools() {
    log "Building the buildsystem tools the image lacks"
    (cd "$VLC_DIR/extras/tools" && ./bootstrap)
    make -C "$VLC_DIR/extras/tools" "$MAKEFLAGS_JOBS"
    log "Bootstrapping VLC"
    (cd "$VLC_DIR" && ./bootstrap)
}

# Writes a pkg-config file for a platform library the contribs and VLC link against.
write_platform_pc() {
    local name="$1" version="$2"
    printf 'Name: %s\nDescription: %s\nVersion: %s\nLibs: -l%s\nCflags:\n' \
        "$name" "$name" "$version" "$name" > "$CONTRIB_PREFIX/lib/pkgconfig/$(echo "$name" | tr 'A-Z' 'a-z').pc"
}

build_contribs() {
    log "Building the contribs"
    mkdir -p "$CONTRIB_PREFIX/lib/pkgconfig" "$CONTRIB_BUILD_DIR"
    write_platform_pc EGL 1.1
    write_platform_pc GLESv2 2

    local bootstrap_args=(
        --host="$TARGET_TUPLE"
        # LGPL 2.1 with advertising clauses allowed, as upstream's --license a. A package that
        # requires the GPL or GPLv3 then stops the build instead of being built.
        --disable-gpl --disable-gnuv3 --enable-ad-clauses
        --disable-net --disable-disc --disable-sout
        --disable-all
    )
    local package
    for package in "${contrib_packages[@]}"; do
        bootstrap_args+=("--enable-$package")
    done
    (cd "$CONTRIB_BUILD_DIR" &&
        env ANDROID_ABI="$ANDROID_ABI" ANDROID_API="$ANDROID_API" USE_FFMPEG=1 \
            ../bootstrap "${bootstrap_args[@]}")

    cat >> "$CONTRIB_BUILD_DIR/config.mak" <<EOF
EXTRA_CFLAGS=$VLC_CFLAGS
EXTRA_CXXFLAGS=$VLC_CXXFLAGS
EXTRA_LDFLAGS=$VLC_LDFLAGS
CC=$CROSS_CLANG
CXX=${CROSS_CLANG}++
AR=${CROSS_TOOLS}ar
AS=${CROSS_TOOLS}as
RANLIB=${CROSS_TOOLS}ranlib
LD=${CROSS_TOOLS}ld
EOF

    # libass's rules force fontconfig on Android; a command-line value overrides the makefile's.
    local contrib_make=(make --no-print-directory -C "$CONTRIB_BUILD_DIR" TARBALLS="$TARBALLS_DIR" WITH_FONTCONFIG=0)

    "${contrib_make[@]}" list | tee "$OUT_DIR/contrib-list.txt"
    local resolved expected
    # The last section of the listing, wrapped over as many lines as it takes.
    resolved="$(sed -n '/^To-be-built packages:/,$p' "$OUT_DIR/contrib-list.txt" | tail -n +2 | tr ' ' '\n' | sed '/^$/d' | sort)"
    expected="$(printf '%s\n' "${contrib_packages[@]}" | sort)"
    if [ "$resolved" != "$expected" ]; then
        diff <(echo "$expected") <(echo "$resolved") >&2 || true
        die "The contribs to be built differ from contrib_packages (< listed only, > resolved only)."
    fi

    "${contrib_make[@]}" "$MAKEFLAGS_JOBS" fetch
    # As upstream: a parallel contrib build occasionally trips over its own ordering, and the
    # serial retry finishes what is left.
    "${contrib_make[@]}" "$MAKEFLAGS_JOBS" -k || "${contrib_make[@]}" -j1

    # As upstream: the contribs' pkg-config files must not force libc++ on the final link, which
    # picks the C++ runtime itself.
    find "$CONTRIB_PREFIX/lib/pkgconfig" -type f -name '*.pc' -exec sed -i 's/ -lc++//' {} +
}

build_vlc() {
    log "Configuring and building VLC"
    mkdir -p "$VLC_BUILD_DIR"
    # As upstream for API < 26: bionic declares sys/shm.h but has none of its functions.
    export ac_cv_header_sys_shm_h=no
    (cd "$VLC_BUILD_DIR" &&
        CFLAGS="$VLC_CFLAGS" \
        CXXFLAGS="$VLC_CFLAGS $VLC_CXXFLAGS" \
        CC="$CROSS_CLANG" \
        CXX="${CROSS_CLANG}++" \
        NM="${CROSS_TOOLS}nm" \
        STRIP="${CROSS_TOOLS}strip" \
        RANLIB="${CROSS_TOOLS}ranlib" \
        AR="${CROSS_TOOLS}ar" \
        AS="${CROSS_TOOLS}as" \
        PKG_CONFIG_LIBDIR="$CONTRIB_PREFIX/lib/pkgconfig" \
        PKG_CONFIG_PATH="$CONTRIB_PREFIX/lib/pkgconfig" \
        PATH="../contrib/bin:$PATH" \
        sh ../configure --host="$TARGET_TUPLE" --build=x86_64-unknown-linux \
            --with-contrib="$CONTRIB_PREFIX" \
            --prefix="$VLC_BUILD_DIR/install/" \
            "${vlc_configure_args[@]}")
    make -C "$VLC_BUILD_DIR" "$MAKEFLAGS_JOBS"
    make -C "$VLC_BUILD_DIR" "$MAKEFLAGS_JOBS" install
}

# The module name of a lib<name>_plugin.a.
module_name() {
    local base
    base="$(basename "$1")"
    base="${base#lib}"
    echo "${base%_plugin.a}"
}

# Generates the static module table libvlc.so is linked with, from the modules the blacklist
# leaves, and stops if any of them declares the GPL.
generate_module_table() {
    log "Generating the static module table"
    local regexp
    regexp="^($(IFS='|'; echo "${module_blacklist[*]}"))\$"
    local redefined_dir="$VLC_BUILD_DIR/install/lib/vlc/plugins"
    rm -rf "$redefined_dir"
    mkdir -p "$redefined_dir" "$VLC_BUILD_DIR/ndk"

    local modules=() excluded=() gpl=() file name
    while IFS= read -r file; do
        name="$(module_name "$file")"
        if [[ "$name" =~ $regexp ]]; then
            excluded+=("$name")
        else
            modules+=("$file")
            if grep -qaF "$VLC_GPL_LICENSE_TEXT" "$file"; then
                gpl+=("$name")
            fi
        fi
    done < <(find "$VLC_BUILD_DIR/modules" -name 'lib*_plugin.a' | sort)
    [ "${#gpl[@]}" -eq 0 ] || die "GPL-licensed modules would be linked: ${gpl[*]}. Add them to module_blacklist."

    local definitions="" builtins="const void *vlc_static_modules[] = {\n" symbols entry
    for file in "${modules[@]}"; do
        name="$(module_name "$file")"
        symbols="$("${CROSS_TOOLS}nm" -g "$file")"
        entry="$(echo "$symbols" | grep 'vlc_entry__' | cut -d' ' -f3)"
        # As upstream: every module's entry points get unique names so they can share one library.
        cat > "$redefined_dir/syms" <<EOF
AccessOpen AccessOpen__$name
AccessClose AccessClose__$name
StreamOpen StreamOpen__$name
StreamClose StreamClose__$name
OpenDemux OpenDemux__$name
CloseDemux CloseDemux__$name
DemuxOpen DemuxOpen__$name
DemuxClose DemuxClose__$name
OpenFilter OpenFilter__$name
CloseFilter CloseFilter__$name
Open Open__$name
Close Close__$name
$entry vlc_entry__$name
$(echo "$symbols" | grep 'vlc_entry_copyright' | cut -d' ' -f3) vlc_entry_copyright__$name
$(echo "$symbols" | grep 'vlc_entry_license' | cut -d' ' -f3) vlc_entry_license__$name
EOF
        "${CROSS_TOOLS}objcopy" --redefine-syms "$redefined_dir/syms" "$file" "$redefined_dir/$(basename "$file")"
        definitions+="int vlc_entry__$name (int (*)(void *, void *, int, ...), void *);\n"
        builtins+=" vlc_entry__$name,\n"
    done
    rm -f "$redefined_dir/syms"
    builtins+=" NULL\n};\n"
    printf "/* Autogenerated from the list of modules */\n#include <unistd.h>\n$definitions\n$builtins\n" \
        > "$VLC_BUILD_DIR/ndk/libvlcjni-modules.c"

    definitions=""
    builtins="const void *libvlc_functions[] = {\n"
    local function
    for function in $(cat "$VLC_DIR/lib/libvlc.sym"); do
        definitions+="int $function(void);\n"
        builtins+=" $function,\n"
    done
    builtins+=" NULL\n};\n"
    printf "/* Autogenerated from the list of modules */\n#include <unistd.h>\n$definitions\n$builtins\n" \
        > "$VLC_BUILD_DIR/ndk/libvlcjni-symbols.c"
    touch "$VLC_BUILD_DIR/ndk/dummy.cpp"

    LINKED_MODULES="$(for file in "${modules[@]}"; do module_name "$file"; done | sort | tr '\n' ' ')"
    EXCLUDED_MODULES="$(printf '%s\n' "${excluded[@]}" | sort | tr '\n' ' ')"
}

link_libraries() {
    log "Linking libvlc.so and libvlcjni.so"
    local modules contrib_ldflags
    modules="$(find "$VLC_BUILD_DIR/install/lib/vlc/plugins" -name 'lib*_plugin.a' | sort | tr '\n' ' ')"
    contrib_ldflags="$(cd "$CONTRIB_PREFIX/lib/pkgconfig" &&
        PKG_CONFIG_PATH="$CONTRIB_PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$CONTRIB_PREFIX/lib/pkgconfig" \
            pkg-config --libs $(ls ./*.pc | sed -e 's|^\./||' -e 's/\.pc$//'))"
    "$NDK_BUILD" -C "$LIBVLCJNI_DIR/libvlc" \
        APP_STL=c++_shared \
        VLC_SRC_DIR="$VLC_DIR" \
        VLC_BUILD_DIR="$VLC_BUILD_DIR" \
        VLC_CONTRIB="$CONTRIB_PREFIX" \
        VLC_CONTRIB_LDFLAGS="$contrib_ldflags" \
        VLC_MODULES="$modules" \
        VLC_LDFLAGS="$VLC_LDFLAGS" \
        VLC_BUILD_JNI=1 \
        APP_BUILD_SCRIPT=jni/Android.mk \
        APP_PLATFORM="android-$ANDROID_API" \
        APP_ABI="$ANDROID_ABI" \
        NDK_PROJECT_PATH=jni \
        NDK_TOOLCHAIN_VERSION=clang \
        NDK_DEBUG=0 \
        "$MAKEFLAGS_JOBS"
}

# FFmpeg decides its own license from its configure switches, beyond the contrib system's guards:
# its GPL, version 3 and non-free parts must all be off.
verify_ffmpeg_license() {
    log "Verifying FFmpeg's license"
    local config="$CONTRIB_BUILD_DIR/ffmpeg/vlc_build/config.h" flag
    [ -f "$config" ] || die "FFmpeg's config.h is not at $config"
    for flag in CONFIG_GPL CONFIG_NONFREE CONFIG_VERSION3; do
        grep -qx "#define $flag 0" "$config" || die "FFmpeg was configured with $flag on."
    done
    grep -qxF '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' "$config" ||
        die "FFmpeg does not report LGPL 2.1 or later."
}

collect_outputs() {
    log "Collecting the outputs"
    local libs_dir="$LIBVLCJNI_DIR/libvlc/jni/libs/$ANDROID_ABI"
    mkdir -p "$OUT_DIR/jni/$ANDROID_ABI"
    local library
    for library in libvlc.so libvlcjni.so libc++_shared.so; do
        [ -f "$libs_dir/$library" ] || die "ndk-build did not produce $library"
        "${CROSS_TOOLS}strip" --strip-unneeded -o "$OUT_DIR/jni/$ANDROID_ABI/$library" "$libs_dir/$library"
    done

    mkdir -p "$OUT_DIR/bindings"
    cp -R "$LIBVLCJNI_DIR/libvlc/src" "$LIBVLCJNI_DIR/libvlc/res" \
        "$LIBVLCJNI_DIR/libvlc/AndroidManifest.xml" "$OUT_DIR/bindings/"

    # Each component's own license files, as its source tree ships them. Every directory in the
    # contrib build tree is one built package's source (some named after the project rather than
    # the package, such as libass for ass).
    mkdir -p "$OUT_DIR/licenses"
    cp "$LIBVLCJNI_DIR/libvlc/COPYING.LIB" "$OUT_DIR/licenses/libvlcjni-COPYING.LIB"
    cp "$VLC_DIR/COPYING.LIB" "$OUT_DIR/licenses/vlc-COPYING.LIB"
    local source name
    for source in "$CONTRIB_BUILD_DIR"/*/; do
        name="$(basename "$source")"
        mkdir -p "$OUT_DIR/licenses/$name"
        find "$source" -maxdepth 1 -type f \
            \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYRIGHT*' -o -iname 'README*' -o -iname 'AUTHORS*' \) \
            -exec cp {} "$OUT_DIR/licenses/$name/" \;
    done
}

# A contrib's version as its rules.mak defines it: the first *_VERSION variable, evaluated by make,
# since some are composed from others.
contrib_version() {
    local variable
    variable="$(sed -n 's/^\([A-Z0-9_]*_VERSION\) *:\{0,1\}=.*/\1/p' "$VLC_DIR/contrib/src/$1/rules.mak" | head -1)"
    [ -n "$variable" ] || return 0
    make -s --no-print-directory -C "$CONTRIB_BUILD_DIR" TARBALLS="$TARBALLS_DIR" WITH_FONTCONFIG=0 \
        --eval="print-contrib-version: ; @echo \$($variable)" print-contrib-version
}

write_build_info() {
    {
        echo "libvlcjni: $LIBVLCJNI_REPOSITORY @ $LIBVLCJNI_COMMIT"
        echo "VLC: $VLC_REPOSITORY @ $VLC_COMMIT ($(git -C "$VLC_DIR" describe --tags --always "$VLC_COMMIT" 2>/dev/null || echo "$VLC_COMMIT"))"
        echo "NDK: r$NDK_RELEASE ($ANDROID_NDK)"
        echo "ABI: $ANDROID_ABI, API $ANDROID_API"
        echo "Patches: $(cd "$RECIPE_DIR/patches" && find . -name '*.patch' | sort | tr '\n' ' ')"
        echo "Contribs:"
        local package
        for package in "${contrib_packages[@]}"; do
            echo "  $package $(contrib_version "$package")"
        done
        echo "Linked modules: $LINKED_MODULES"
        echo "Excluded modules: $EXCLUDED_MODULES"
        echo "Library sizes:"
        (cd "$OUT_DIR/jni/$ANDROID_ABI" && ls -l)
    } > "$OUT_DIR/build-info.txt"
}

main() {
    rm -rf "$SRC_DIR" "$OUT_DIR" "$WORK_DIR/home"
    mkdir -p "$SRC_DIR" "$OUT_DIR" "$TARBALLS_DIR" "$WORK_DIR/home"
    export HOME="$WORK_DIR/home"

    fetch_sources
    setup_toolchain
    build_tools
    build_contribs
    verify_ffmpeg_license
    build_vlc
    generate_module_table
    link_libraries
    collect_outputs
    write_build_info
    log "Done: $OUT_DIR"
    cat "$OUT_DIR/build-info.txt"
}

main "$@"
