# NetVplayer Dolby runtime

This source overlay provides embedded Dolby Vision reconstruction, HDR Vivid
dynamic display adaptation, native
E-AC-3/JOC output, qualified TrueHD MAT / DTS-HD MA HDMI transport, and opt-in
TrueHD object-to-7.1.4 / binaural PCM rendering. It is consumed by the normal macOS application build; it does
not launch a second player or fetch an independent copy of the playing stream.

## Sources

- mpv: `99b4c12cccb4d8d3f72b41944cb6c640e2156650` (upstream BL/EL decoding and pairing).
- libplacebo: `0df80ae5229e8e520c0fa4e3d666098a3ffa1cbc` (API 376, RPU mapping and FEL reconstruction).
- The libplacebo render adapter starts from [mpv PR 17828](https://github.com/mpv-player/mpv/pull/17828), revision `bba260c9a92e8f49b7712cd1238dceab6ccccb05`, with NetVplayer's OpenGL FBO bridge, ICC, subtitles, screenshot, rotation, lifecycle and frame telemetry changes.
- FFmpeg headers must match the audited **9.0.1** binary dependency bundle. The
  recipe downloads the official source archive and checks its SHA-256.
- LibTrueHD: `aebd5ffe1046dadbea833ce87a75d00fd8b1edd1`, C API v2, with
  `matrix-interpolation`; its `truehd` dependency is pinned to
  `33bae1657ceb25b5fe0347f42c544c3414e2760e`. This supplies decoded elements
  and timed OAMD to the application's renderer, not Dolby's certified renderer.

The reference-product observations are recorded in
`NetVplayer/Docs/senplayer_playback_analysis_20261016.md` and
`NetVplayer/Docs/clouddrive2_advanced_playback_analysis_20261016.md`.
No extracted proprietary decoder, shader or binary is included here.
The mpv license texts accompany the overlay; packaged runtime notices include
all binary dependencies and their source/license hashes.

## Build

Use disposable source checkouts: the recipe applies `mpv/integration.patch`
and copies the overlay source/header files into the mpv checkout.
Xcode, Python 3.12+, Meson, Ninja, pkg-config, Rust/Cargo **1.98.1** and the development headers used
by the existing macOS runtime build are required. Check out the exact pins:

```sh
git clone https://github.com/mpv-player/mpv.git /tmp/netvplayer-mpv
git -C /tmp/netvplayer-mpv checkout 99b4c12cccb4d8d3f72b41944cb6c640e2156650
git clone --recursive https://github.com/haasn/libplacebo.git /tmp/netvplayer-placebo
git -C /tmp/netvplayer-placebo checkout 0df80ae5229e8e520c0fa4e3d666098a3ffa1cbc
git -C /tmp/netvplayer-placebo submodule update --init --recursive
rustup toolchain install 1.98.1 --profile minimal --target aarch64-apple-darwin

python3 script/build_dolby_runtime.py \
  --base-runtime /path/to/audited-ffmpeg-9.0.1-runtime.app \
  --work-dir NetVplayer/.build/dolby-runtime \
  --mpv-source /tmp/netvplayer-mpv \
  --libplacebo-source /tmp/netvplayer-placebo

./script/build_and_run.sh --verify
```

`--tools-bin` optionally supplies Meson/Ninja. The base bundle must already have
complete `ThirdPartyLicenses/libmpv-runtime.json`, notices and license texts.
The recipe links against the matching FFmpeg headers, restricts the assembled
dependency closure to the audited base, rejects external load paths and
deployment targets above macOS 14, signs the rebuilt libraries, and audits the
license manifest. It writes `Contents/Resources/dolby-runtime-build.json` with
source pins, overlay hashes and final binary hashes. Do not replace Mach-O
minimum-version fields to bypass the deployment check.
The recipe also queries the assembled library's ABI/capability contract
without opening an audio device and records the returned bits in the receipt.
The recipe clones the pinned LibTrueHD source automatically; `--truehd-source`
can select an existing clean checkout at that exact commit. Its helper builds
with the locked matrix-interpolation feature and packages crate and Rust
standard-library notices. Release workflows install the pinned Rust toolchain.

## Shared DASH playback runtime

The normal runtime recipe also rebuilds FFmpeg 9.0.1 libavformat with the Apple
SDK's libxml2 when the base lacks DASH. It retains the baseline codec libraries,
all existing demuxers/input protocols and the macOS 14 deployment target.
`--openssl` can select the matching OpenSSL headers (default: the arm64 Homebrew
openssl@3 prefix). The source archive uses the same audited SHA as the headers.

To rebuild just libavformat from an **already available** archive, with no download:

```sh
python3 script/build_dash_runtime.py \
  --source-archive /path/to/ffmpeg-9.0.1.tar.xz \
  --baseline-app /path/to/audited-runtime.app \
  --openssl /opt/homebrew/opt/openssl@3 \
  --work /path/to/NEW-dash-build \
  --output /path/to/NEW-dash-runtime.app
python3 script/verify_playback_runtime.py --bundle /path/to/NEW-dash-runtime.app
```

The final verification command above requires an already qualified Dolby base.
When the complete Dolby recipe starts from a licensed stock runtime, its earlier
DASH step verifies the new binary, source patches and FFmpeg license record as
a build intermediate. It does not invent a Dolby receipt. The later Dolby
assembler creates the linked receipt and runs the full shipping gate; an
intermediate alone is still rejected by the application packager. Cached DASH
intermediates must also match the builder, original binary and remaining base
dependencies before reuse.

An already qualified Dolby base can also use the empty default output path
`NetVplayer/.build/dolby-runtime/runtime.app` for this rebuild. The resulting Dolby
and DASH receipts are retained there; the normal application build then needs no
playback runtime override. The 2026-10-29 default Release build and its installed
seven-source playback validation were tested separately from capability enumeration; those historical device receipts remain in the internal archive.
The playback bundle owns top-level dylibs only; Sparkle and other framework trees
remain with their respective application packagers.

Select a separately prepared bundle with `NETVPLAYER_LIBMPV_RUNTIME_BUNDLE` for the normal
application packaging entrypoint. Default prepared runtimes and explicit bundle
overrides both undergo an independent ABI query for DASH/HLS/MP4 and the required
file/HTTP/TLS protocols before copying. The packager preserves the DASH receipt;
its hash, the Dolby binary receipt and the FFmpeg license record must agree.
The explicit stock-runtime branch remains a dependency bootstrap for the CI Dolby
builder and compatibility experiments; it is not the shipping prepared-runtime path.

The builder checks source and baseline pins and uses fresh output directories.
Missing local source is a failure, not a download or reuse of an older binary.
Capability enumeration and synthetic ABI packaging tests do not prove DASH playback:
qualify the rebuilt runtime with media/track/seek/Range and retirement tests before
claiming a real-source fix. The 2026-10-29 matrix found that the earlier P3-03
standalone development overlay had not reached normal Release packaging. Public source checks must verify the rebuilt normal packaging path independently.

## Experimental source Dolby Vision metadata

Renderer capability bit `32` and render parameter `10002` add a synchronous,
versioned source-frame callback. The caller and runtime must agree on the
libavutil major ABI. The borrowed `AVFrame` is valid only during the callback;
the application copies it and presents **after** the render call returns, so
mpv retains scheduling ownership. This is separate from global audio runtime
capabilities (`1011` in the audited build).

The application has a separate, default-off source-metadata preference inside
the existing system DV experiment. Initially it accepts verified P8.1/P8.4
configuration, disabled residual, limited-range 10-bit 4:2:0 and matching
BT.2020/PQ or HLG. It copies original samples into bounded P010 buffers and
copies the source RPU unchanged to the experimental `DolbyVisionRPUData`
attachment. P5/P7, missing or incompatible metadata, subtitles/OSD, transforms
and unsupported source filters retain the reconstructed path. Every frame
still runs normal libplacebo reconstruction; this is not a hardware-decoding,
zero-copy or total-performance claim.

CoreVideo/IOSurface attachments are cleared before reuse. Static HDR SEI
payloads are rebuilt in big-endian wire format, never copied as FFmpeg structs.
Seek, preference changes and release clear submission evidence; old generations
cannot restore it. Source RPU L1 values are not reported as regenerated GPU
statistics. System submission does not prove macOS consumed the private RPU,
HDMI passthrough, receiver DV mode or calibrated output. These require independent hardware validation.

## TrueHD objects and headphones

Capability bit `512` adds `netvplayer-truehd-objects=off|7.1.4|binaural|tracked`.
The default is `off`. The selected mpv demux stream, decoder timeline, PCM
filters and audio sink remain the playback path. `netvplayer-object-audio`
reports actual decoding, metadata, fallbacks, HRTF frames and fresh sensor
samples. Explicit object mode is PCM; it does not encode PCM into Dolby MAT.

The application requires a physical device with twelve explicitly named
speakers before selecting 7.1.4 PCM. Binaural rendering is an offline HRTFHQ
graph; tracked mode additionally requests compatible headphone motion with
permission and falls back to a fixed listener when no fresh pose is available.
ISF positions unavailable in the decoder use the aligned complete channel mix
and increment a fallback counter. A fixed 0.25 output factor reserves about
12 dB of mix headroom before user gain and filters. The public tests below cover integration boundaries; physical listening and sensor behavior need separate verification.

Offline tests (the include path must contain the pinned `truehd_atmos.h`):

```sh
clang -std=c11 -Wall -Wextra -Werror \
  -I script/runtime/mpv/audio/decode -I /path/to/LibTrueHD/include \
  script/tests/test_atmos_render.c script/runtime/mpv/audio/decode/atmos_render.c \
  -o /tmp/test-atmos-render
/tmp/test-atmos-render

clang -fblocks -mmacosx-version-min=14.0 \
  -framework Foundation -framework AVFoundation -framework CoreMotion \
  -I script/runtime/mpv/audio/decode -I /path/to/LibTrueHD/include \
  script/tests/test_atmos_binaural.m script/runtime/mpv/audio/decode/atmos_binaural.m \
  -o /tmp/test-atmos-binaural
/tmp/test-atmos-binaural

python3 script/verify_truehd_objects.py \
  --runtime NetVplayer/.build/dolby-runtime/runtime.app \
  --sample /path/to/TrueHD-Atmos.mka --output /tmp/truehd-object-proof
```

The integration verifier requires an object fixture without ISF fallback. It
writes WAV/JSON via `ao=pcm`, tests seek/mode transitions for samples over five
seconds, and opens no physical audio device. Its standalone Python host has no
motion usage permission, so it also verifies that selecting tracking never
fabricates sensor proof. These tests do not verify real speaker locations,
headphone listening quality, real sensor axes/latency, or Dolby certification.

## HDR Vivid

`mpv/video/out/hdr_vivid.h` implements the single-window, system-start-code 1
display adaptation described by GY/T 358-2022 sections 9–11 and annex A. FFmpeg
9.0.1 supplies decoded `AV_FRAME_DATA_DYNAMIC_HDR_VIVID`; the renderer uses scene
statistics, authored base curves, target adaptation, cubic splines and saturation
parameters for each frame. PQ and HLG sources map to SDR or floating HDR targets.
ICC/gamut conversion follows the dynamic curve; generic tone mapping and peak
detection are disabled for an already adapted Vivid frame. Temporal interpolation
is disabled for Vivid frames to keep each curve attached to its own decoded frame.
Screenshots and chapter previews use the same adaptation.

The existing version-1 render telemetry ABI gains capability bit `16`. Current
frame bits `16`, `32`, `64` mean Vivid side data, successfully mapped Vivid, and
Vivid fallback, respectively. Reset/reconfigure clears frame proof. Unsupported
start codes, invalid rationals, reserved parameters and unusable spline intervals
fall back to the PQ/HLG image. Metadata presence alone does not light the badge.
This is display adaptation, not native HDR Vivid or Dolby Vision HDMI signalling.
Use the scalar and native render checks below to validate a rebuilt runtime.

Generate original integration fixtures with:

```sh
python3 script/generate_playback_hdr_vivid_fixtures.py --output-dir /tmp/vivid-fixtures
NETVPLAYER_LIBMPV_PATH="$PWD/NetVplayer/.build/dolby-runtime/runtime.app/Contents/Frameworks/libmpv.2.dylib" \
NETVPLAYER_HDR_VIVID_FIXTURES=/tmp/vivid-fixtures \
swift test --package-path NetVplayer --disable-sandbox --filter MPVHDRVividRenderTests
```

Run native render tests from a macOS graphical session. The scalar test can run
without a window and should be built against the pinned FFmpeg 9.0.1 headers:

```sh
clang -O1 -g -fsanitize=address,undefined -I/path/to/ffmpeg-headers/include \
  script/runtime/tests/hdr_vivid.c -o /tmp/test-hdr-vivid
/tmp/test-hdr-vivid
```

Normal packaging uses `NetVplayer/.build/dolby-runtime/runtime.app` and verifies
its overlay/binary hashes. A missing or stale cache stops packaging. An explicit
`NETVPLAYER_LIBMPV_RUNTIME_BUNDLE` can select a separately prepared bundle.
An ordinary Homebrew libmpv does **not** acquire these capabilities from the
Swift code alone; `NETVPLAYER_ALLOW_STOCK_LIBMPV=1` is an explicit compatibility
build. The application checks the runtime ABI and capability bits; older
runtimes keep their existing conservative compatibility behavior.

The release workflow and public export template rebuild these pinned sources
against the separately audited macOS 14 dependency bundle before setting
`NETVPLAYER_LIBMPV_RUNTIME_BUNDLE`. That bundle supplies the dependency ABI;
the release application receives the newly built Dolby libraries and receipt.
The local clean build has been executed; the cloud release workflow is only
checked structurally until an authorized release run occurs.

## Runtime behavior

- `opengl-placebo` keeps the existing mpv GPU backend for ordinary SDR output,
  including HDR-to-SDR and ICC conversion. HDR-to-FP16 output uses libplacebo.
  Frames with decoded Dolby metadata also use libplacebo reconstruction,
  including the paired P7 FEL enhancement layer. Both paths share one libmpv
  session, timing, OpenGL context and presentation surface.
- Missing RPU or required enhancement data cannot claim reconstruction.
  Versioned, thread-safe renderer observations identify the current frame and
  reset at reconfiguration/seek. Capabilities alone are never playback proof.
- The AVFoundation AO preserves complete independent/dependent E-AC-3 packets,
  derives `dec3` metadata, and submits compressed sample buffers to the system
  renderer/synchronizer. JOC is read from parsed metadata, not a filename.
  Pause, seek, device changes and failure fallback stay on the mpv timeline.
- Speed changes and PCM filters select PCM; restoring normal speed and removing
  filters restores native output. HDMI passthrough requires an advertised
  matching compressed format, exclusive ownership and format readback. LPCM
  formats are never used as an unverified compressed-data carrier.
- The strict CoreAudio HDMI route additionally recognizes E-AC-3's observed
  `cec3` carrier at 192 kHz, two 16-bit transport channels, with a 6,144-frame
  IEC burst. Physical and virtual ASBDs must match in full; the logical SPDIF
  format and byte clock remain unchanged. This is a transport layout, not a
  two-speaker movie mix. Other private IDs (`cc+3`, `cd+3`, `mtc+`)
  remain unqualified. See the 2026-10-18 HDMI evidence in `NetVplayer/Docs`.
- Capability bit 64 allows the application to opt into `coreaudio-truehd-mat`.
  With strict HDMI output, logical TrueHD 192 kHz × 8 × 16 bit can use the
  observed `mtct` carrier: 768 kHz × 2 × 16 bit, flags 76, 61440 bytes per packet.
  Both ASBDs must match. Byte-based reframing preserves the logical clock;
  carrier latency uses the HAL clock. Other endpoints and the 44.1 kHz family
  fall back to PCM. This transports original TrueHD and does not decode objects
  or encode PCM into MAT object audio. Receiver Atmos was physically confirmed
  on the documented Mac/Sony chain; other receivers remain unverified.
- Capability bit 256 independently enables `coreaudio-dtshd-hbr=yes`, together
  with `coreaudio-spdif-only=yes` and `audio-spdif=dts-hd`. Only DTS-HD MA's
  logical 192 kHz × 8 × 16 bit transport qualifies for the same exact `mtct`
  descriptor: 768 kHz × 2 × 16 bit, flags 76, 61440 B / 15360 carrier frames.
  HRA's 192 kHz × 2 transport and other private descriptors stay rejected.
  The tested DTS type-IV fixture has 32768-byte bursts; the driver packet
  descriptor does not force MAT's 61440-byte burst geometry onto DTS data.
  Continuous byte reframing preserves the decoder clock, uses carrier-frame
  latency, and applies no second word swap, gain, sample conversion or remix.
  A macOS packing-boundary check compares each original DTS packet against
  the IEC payload, including HD/object extension bytes, and rejects silent
  core-only substitution. An integrity failure retains the original packet
  and PTS, disables SPDIF for that decoder session, and replays it once through
  the normal PCM decoder. It does not keep dropping affected packets while
  continuing passthrough. Normal carrier rejection follows the existing PCM
  fallback; explicit DTS core remains available separately. Independent exact
  `mtct` tests preserved the complete MA payload and the user confirmed the
  receiver displayed DTS-HD 7.1 / 48 kHz. DTS:X receiver recognition has not
  been tested and is not implied by the MA result. See
  `NetVplayer/Docs/evidence/hdmi-atmos-implementation-20261018/dtshd-hbr-investigation.md`.
- The swresample boundary preserves unspecified channel layouts rather than
  fabricating a native speaker mask. This fixes seven-channel format conversion
  rejected by FFmpeg 9; unknown layouts use channel-index mapping when needed.

Run the native integration tests with `NETVPLAYER_LIBMPV_PATH` pointing to the
prepared library. `NETVPLAYER_NATIVE_DOLBY_FIXTURES` enables the P5/P7/P8/JOC
session tests; `NETVPLAYER_AV_COLOR_FIXTURES` enables independent color/ICC and
subtitle readback. Combining both also checks Dolby-to-ordinary-frame
transitions without changing the existing reference or tolerances.
`script/probes/eac3_packet_roundtrip.m` checks payload preservation;
`script/probes/mpv_dolby_playback_host.m` provides explicit-library GPU, pause,
seek and performance probes. Real server credentials and media stay outside Git.

Capability bit 128 enables temporary PCM physical-format changes with checked
rollback snapshots, synchronous restoration and cleanup after partial AO
initialization failures. `coreaudio-change-physical-format=yes` and
`audio-samplerate=0` request the decoded source rate, subject to the device's
advertised PCM formats. The option triggers AO reinitialization when changed.
The application avoids treating its own clock change as a new device topology.
Compressed passthrough continues to use codec-specific carrier clocks, not this
PCM option. `script/probes/coreaudio_pcm_lifecycle_test.py MPV_SOURCE` injects
failures into the actual lifecycle bodies without accessing a device.

`script/probes/coreaudio_hdmi_test.c` checks codec-specific carrier selection
and strict ASBD readback without touching audio hardware. The opt-in Swift
`PlaybackHDMITransportTests` uses `NETVPLAYER_HDMI_JOC_FIXTURE` and optionally
`NETVPLAYER_HDMI_REPORT` to check physical HDMI transport and playback controls.
It is muted and does not prove receiver Atmos lock. The native playback host
also defaults to mute when `NV_TEST_AO` is set; only an explicit
`NV_TEST_AUDIBLE=1` enables a separate audible receiver check. Neither probe
automatically claims the receiver reported Atmos.
