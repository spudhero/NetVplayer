# Local playback and HDMI probes

These tools run in a separate test host. They are not linked into NetVplayer.

`mpv_dolby_playback_host.m` renders a local fixture through the selected runtime.
Its `NV_TEST_AUDIBLE=1` switch explicitly enables an audible receiver check.
The encoded CoreAudio path does not apply PCM gain, so `mute=yes` alone does not
establish that the receiver is silent.

## Capture the IOProc output

`coreaudio_io_capture.c` interposes this process's `AudioDeviceCreateIOProcID`
and `AudioDeviceDestroyIOProcID`. Capture is disabled unless an absolute,
unused `NETVPLAYER_CA_CAPTURE_PREFIX` is supplied. Compile and sign it with:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror -dynamiclib -framework CoreAudio \
  script/probes/coreaudio_io_capture.c -o /private/tmp/coreaudio_io_capture.dylib
codesign --force --sign - /private/tmp/coreaudio_io_capture.dylib
```

For an explicitly selected test host, add these environment variables to its
normal launch command:

```sh
DYLD_INSERT_LIBRARIES=/private/tmp/coreaudio_io_capture.dylib \
NETVPLAYER_CA_CAPTURE_PREFIX=/private/tmp/hdmi-capture-new-run \
  /path/to/test-host its-normal-arguments
```

The wrapper first calls the original producer. For a single output buffer it
then copies the first **64 MiB** into memory allocated and prefaulted before
IOProc registration. At the observed EAC3 carrier rate of **768000 bytes/s**,
this holds **87.38 seconds**, enough for the complete 75.56-second fixture.
The callback performs no file IO, allocation, or logging. Byte counts and
timing statistics continue after capture fills. At most 131072 callback trace
entries are retained.

After all IOProcs are destroyed and the process exits normally, the probe
writes `PREFIX.raw`, `PREFIX.json`, and `PREFIX.callbacks.csv`. Output uses
exclusive creation and never overwrites an existing file. Forced termination
does not flush the capture. The JSON and CSV include output timestamp flags,
sample-time steps, actual buffer byte sizes, callback intervals, and producer
and wrapper durations.

The interposer uses its own direct symbol bindings for the original CoreAudio
functions. `dlsym(RTLD_NEXT, ...)` can resolve to the replacement on macOS and
must not be used here. The exported
`netvplayer_ca_capture_verify_bindings()` helper prints `dladdr` evidence and
checks that the original and wrapper addresses differ without opening a
device.

## Inspect captured bytes without playing them

```sh
python3 script/probes/coreaudio_io_analyze.py /private/tmp/hdmi-capture-new-run.raw \
  --callbacks /private/tmp/hdmi-capture-new-run.callbacks.csv \
  --extract-eac3 /private/tmp/hdmi-capture-new-run.eac3
```

The analyzer checks EAC3 preambles, **24576-byte** burst spacing, byte-swapped
payload sync, and zero padding. EAC3's `Pd` length is in bytes. Expected zeros
inside a burst are separate from runs containing at least a whole burst of
zeros. Such long runs can also occur during startup, pause, or shutdown and
are not automatically classified as underruns. The final captured burst may
be truncated by the capture limit.

The callback trace independently measures bytes and sample frames per output
host-time second. Comparing complete captured bursts with a reference stream
is stronger evidence than preamble checks alone. These probes establish what
the IOProc supplied; stable HAL format, byte continuity, and `current-ao` do
not establish continuous receiver Atmos lock or HDMI/eARC wire behavior.

## Check the FFmpeg 9 channel-layout boundary

`swresample_channel_layout_test.c` runs entirely in memory against the selected
runtime's FFmpeg libraries. It reproduces the rejected synthetic `0x7f` layout,
then checks seven-channel conversion and resampling, known 6.1/7.1 layouts,
unknown layouts, channel-index truncation/zero filling, and known stereo remix.
Each independent input channel is compared sample by sample with a separate
mono conversion, which detects unwanted mixing or reordering.

```sh
ffmpeg_headers=/path/to/ffmpeg-9.0.1
runtime_frameworks=/path/to/runtime.app/Contents/Frameworks
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$ffmpeg_headers" \
  script/probes/swresample_channel_layout_test.c \
  "$runtime_frameworks/libswresample.7.dylib" \
  "$runtime_frameworks/libavutil.61.dylib" \
  -Wl,-rpath,"$runtime_frameworks" -o /private/tmp/swresample-channel-layout-test
/private/tmp/swresample-channel-layout-test
```

This validates the FFmpeg API and sample behavior used by the adapter. Rebuilt
mpv and the formal app still require their own integration verification.

## Check PCM format switching without a device

`coreaudio_pcm_lifecycle_test.py` compiles the selected mpv checkout's actual
shared-CoreAudio lifecycle and format-selection function bodies against a fake
HAL. It does not link CoreAudio or open an output device.

```sh
python3 script/probes/coreaudio_pcm_lifecycle_test.py /path/to/patched/mpv
```

The cases cover continuous sample-rate ranges, compressed-format exclusion,
snapshot failures, partial writes, rollback retry, later initialization errors,
and balanced hotplug listeners. They establish cleanup control flow; physical
sample-rate acceptance and restore still need a separate hardware check.
