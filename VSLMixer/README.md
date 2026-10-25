# VSL Mixer

A low-latency Mac mixer for the PreSonus AudioBox 1818VSL, replacing the
discontinued PreSonus VSL software.  Eight inputs, each with high-pass, 3-band
EQ and a compressor, mixed to Main (outs 1+2) and six mono auxes (outs 3–8),
plus raw multitrack recording.

## Background: there is no DSP in the box

The 1818VSL has no onboard mixer.  PreSonus's Windows installer
(`PreSonus_AudioBox_Installer_v1_3_5653.exe`, v1.3) shows how VSL worked: it
is a Thesycon USB audio driver (`paeusbaudio.sys`) plus a DSP plugin running
*inside the driver* (`paeusbaudiodsp.sys`, "tusbaudiodsp_framework").  The
VSL app sent parameters to that plugin through `TUSBAUDIO_SetDspProperty`.
PreSonus's own marketing calls it a "computer-based ... ultra-low latency
mixer".  So all mixing happened on the computer, in the kernel, to keep
latency down.

The hardware is a USB Audio Class 2 device (VID 0x194F, PID 0x0103) with 18
inputs and 18 outputs (8 analog, 8 ADAT, 2 S/PDIF).  Its descriptors have only
clock sources, terminals and feature units (volume/mute): no mixer or
extension units and no vendor interface.  macOS's class driver handles it
fine, and a user-space CoreAudio IOProc gets close to what the kernel approach
did.

Firmware: the unit reports `bcdDevice` 0x0131.  Universal Control offers
v1.49; the VSL 1.3 software wanted v1.18.  Firmware updates have bricked units
for some owners, and nothing suggests newer firmware helps class-compliant
use, so this unit hasn't been updated.

## Measured on this Mac (Apple Silicon, macOS 26)

Round-trip latency, analog out → analog in through one loopback cable:

| Rate | Buffer | Round trip |
|---|---|---|
| 48 kHz | 16 | 4.0–4.4 ms |
| 48 kHz | 32 | 4.7–5.0 ms |
| 48 kHz | 64 | 6.0 ms |
| 96 kHz | 32 | 3.3 ms |

That's about 155 frames of fixed device/driver delay plus two buffers,
matching the latency and safety-offset properties CoreAudio reports, which is
what the app's latency estimate uses.  Going through PortAudio
(`sounddevice`) instead adds 14+ ms; talk to CoreAudio directly.

Reliability, 8 channels in and out with a mixer-like DSP load: 48 kHz with 16
or 32 frames ran 5–10 minute soaks with zero dropouts, **once the box was
plugged directly into the Mac**.  Lessons:

- **Don't use a USB hub.** Through a cheap USB 2.0 hub (Terminus chip,
  VID 0x1A40) the kernel logged hundreds of isochronous `transaction error`s a
  minute, and each one made CoreAudio restart the device (~235 ms of
  silence).  Direct connection: ~2 errors per run, at start/stop.  The device
  is USB 2.0 only; it negotiates 480 Mbps even on a USB-C port.
- **The box can lock up.** Once, between runs, it stopped delivering audio at
  every rate and buffer size until power-cycled, with nothing in the system
  log.  The app's watchdog restarts audio on stalls and tells the user to
  power-cycle if restarts don't help.
- **Avoid page faults on the IO thread.** An early soak test wrote into
  freshly allocated memory from the callback and saw 1–2 ms stalls; with the
  buffer pre-touched and locked, worst-case callback time was 10–30 µs
  against a 333 µs budget.
- The CPU cost is trivial: about 2–10 µs per callback.

An overnight soak at 48 kHz / 16 frames hasn't been run yet.

## Layout

```
Engine/engine.{h,c}   real-time mixer, device IO, recorder (C)
App/                  SwiftUI app
Remote/               phone control page (HTML/CSS/JS, served by the app)
Tests/                offline DSP tests, a hardware loopback test, phone-control tests
Tools/                latency and dropout measurement tools
project.yml           XcodeGen spec; VSLMixer.xcodeproj is generated from it
```

### Engine (C)

Everything on the CoreAudio IO thread is C, so it never allocates, locks or
touches the Swift runtime.

- Signal chain per input: input meter (pre-everything) → high-pass (12 dB/oct
  Butterworth) → low shelf → peaking mid → high shelf (RBJ biquads, double
  precision) → feed-forward peak compressor with hard knee → mute → a send to
  each of 7 mixes.  Each mix's sum then gets the same chain (high-pass, EQ,
  compressor, mute) before its master.  Inputs and mixes share the code as
  "strips".  After its master, each mix can be delayed up to 250 ms (to
  line up with distant speakers; the UI shows ms and feet at 1.125 ft/ms);
  changes crossfade over 256 samples so they don't click.  Main is mono and
  drives outs 1 and 2; aux N drives out N+2.
  Outputs 9–18 are silent.
- Sections that are flat (high-pass at 20 Hz, all EQ gains 0, ratio 1:1 with
  no makeup) are skipped, so they're bit-exact passthrough.
- The UI hands over channel settings through a per-channel seqlock; gains,
  mutes and masters are atomics, smoothed over ~5 ms on the IO thread.
- Recording copies raw inputs into a lock-free ring buffer (~5 s); a writer
  thread drains it to eight mono 24-bit WAVs via ExtAudioFile.
- The IO thread keeps the last 4096 samples of every input and every mix
  sum (before processing) for the EQ editor's spectrum; `Spectrum.swift`
  FFTs it with Accelerate at 30 Hz, only while an EQ editor is open.  The
  after-EQ spectrum is the before spectrum plus the EQ curve.
- `mx_eq_response_db` uses the same filter design, so the curves drawn in the
  UI are exactly what's running.

### App (SwiftUI)

- `AppState.swift`: owns the engine, pushes the `Session` to it on every
  change, and every 0.5 s runs a watchdog that restarts audio after a stall,
  an unplug or an outside sample-rate change.  It also handles recording
  (`~/Music/VSL Mixer/<date>/NN Name.wav`), scenes and persistence.
- `Model.swift`: `Strip` (an input or an output, for the EQ/comp editors),
  `Session` (saved to the sandbox container's
  `Application Support/VSL Mixer/session.json` and restored at launch),
  `ChannelSettings`, `FaderScale`, `MixerScene`.
- Fader taper: the bottom 3% is −∞, then −20 dB → +10 dB, with unity at
  0.75.  Saved files record a `faderTaper` version; `FaderScale.migrate`
  converts older positions so levels don't change.  Bump `currentTaper` if
  you change the mapping.
- `ChannelSettings` decodes leniently and migrates fields from earlier
  versions (which had on/off switches), so old sessions and scenes keep
  loading.  Keep that up when adding fields.
- Scenes live in `Application Support/VSL Mixer/Scenes/*.json`.  "Blank
  board" is built in (defaults, including names).  Every load first saves the
  current board as "Previous", so a load can be undone.
- The layout is designed at 1440×900 and scales up with the window to 1.8×
  (`uiScale` environment value, `uiFont`, and `* k` on fixed sizes).
- UI rules from the owner: each output has its own color at equal lightness
  (OKLCH L≈0.33), applied only to the output-specific parts (output buttons,
  fader boxes, the output strip with its EQ, comp and mute, and the output's
  EQ/compressor editors).  Input names, EQ, comp, meters and mute are neutral
  because they apply to every output.  No pan.  EQ and compressor have no
  on/off; flat and 1:1 are the defaults.  Names are edited in place.

### Phone control

Musicians control their own aux from their phones, and the owner can run the
whole board, from any phone browser (Android or iPhone), with nothing to
install.

- Phone control is off until someone turns it on in the Phones sheet.  It
  advertises itself over Bonjour, which makes macOS ask for Local Network
  access at that point rather than at launch.
- The sandbox needs `network.client` as well as `network.server`: replying
  on a connection accepted from another device counts as outbound, and
  without it the sandbox silently drops every phone's connection
  ("deny network-outbound" in the system log).  Loads from the Mac itself
  go over loopback and still work, which hides the problem.
- Chrome on Android 17 can fail with ERR_TOO_MANY_RETRIES even with Nearby
  devices allowed; its net log shows ERR_LOCAL_NETWORK_PERMISSION_MISSING
  and nothing reaches the Mac.  Firefox on the same phone works.  What
  fixed it: force stop Chrome, set Nearby devices to Don't allow, back to
  Allow, force stop again.  Apparently a grant from before Android 17
  didn't cover local network access.
- `RemoteServer.swift` serves `Remote/` over plain HTTP on port 8080 (or the
  next free even port) and speaks JSON over a WebSocket on the port after it.
  The protocol is documented at the top of that file.  Everything runs on the
  main queue; state goes out at most every 40 ms and meters 15 times a
  second, and slow phones skip meter frames.
- Roles: `aux` clients can only move their own aux's sends and master.
  `board` needs the passcode (`Session.remoteCode`, four digits, shown in the
  Phones sheet).  Changing the passcode drops phones that were using the old
  one.  Mute, EQ and compression are board-only because they affect every
  output.  Values from phones are clamped (`ChannelSettings.limits`).
- `PhonesView.swift` is the Phones sheet: a QR code to join the Wi-Fi (if
  you enter its name and password) and one for the page itself, which opens
  on a list of mixes and the whole board.  The `#aux/N` and `#board` links
  still work if typed or bookmarked.
- The page (`remote.js`) is portrait, with screens chosen by the URL hash: pick
  a mix, your aux, the whole board (output chips plus rows with Mute), and a
  channel's EQ and compressor (touch-draggable points).  The EQ math is a port
  of the engine's filter design.  Faders drag relative to where they were, so
  a tap never jumps; the −/+ buttons step one whole dB and repeat when held.
  While a control is being moved, the mixer's echo of it is ignored for
  700 ms so the finger doesn't fight the network.
- Networking: phones must be on the same network as the Mac.  With no venue
  Wi-Fi, use a pocket travel router (most reliable), or Internet Sharing to
  Wi-Fi.  Neither has been tried at a gig yet.  Phones warn there's no
  internet but stay connected.  The page can't keep phone screens awake,
  because the Screen Wake Lock API needs HTTPS.
- Bluetooth was considered: Web Bluetooth would work on Android only, for
  roughly one phone at a time, so Wi-Fi it is.

## Building

```
brew install xcodegen
cd VSLMixer
xcodegen generate     # after editing project.yml or adding files
xcodebuild -project VSLMixer.xcodeproj -scheme VSLMixer -configuration Debug build
```

or open `VSLMixer.xcodeproj` in Xcode.  Edit `project.yml`, not the
generated project.  Entitlements are listed in `project.yml` too, because
XcodeGen overwrites `App/VSLMixer.entitlements` from it.

Debug builds are signed with an Apple Development certificate (team
C58DMTY76R).  Ad-hoc signing works, but macOS then asks for microphone
permission again after every rebuild.  The app is sandboxed with audio-input
and Music-folder access, ready for the Mac App Store.  Before submitting:

- Rename it.  "VSL" is PreSonus's product name.
- Add an app icon and a privacy policy.
- Archive with the Release config.

## Tests

```
Tests/run_tests.sh              # offline: filter curves, routing, EQ, compressor, mute
Tests/run_tests.sh --hardware   # also through the real box
```

`Tests/remote_test.py` (needs the app running; `pip install websockets
playwright` into a venv) checks the phone protocol: roles, permissions,
clamping, broadcasting, meters, saving.  With `--ui` it also drives the page
in headless Chrome at Pixel, iPhone and small-iPhone sizes, with touch: drags
faders and EQ/compressor points and checks that the mixer heard them.  It
changes the live board, so it saves a snapshot, silences every master while
it runs, and restores everything afterwards.  If a run dies partway, the next
run restores the snapshot first.

The hardware test needs each output N cabled to input N.  It injects a tone on
out 1, has the mixer route in 1 only to Aux 1 (out 3), and uses the app's own
recorder to compare in 3 with in 1.  That checks gain, EQ, compression, send
level, mute, recording and dropouts end to end, with no feedback path.
Knobs were at 12 o'clock when it was written; it measures relative levels, so
the exact gain doesn't matter.

## Soak testing

With the same loopback cabling (`brew` numpy into a venv for the analysis):

```
clang -O2 Tools/soak.c -framework CoreAudio -framework CoreFoundation -o soak
./soak 1818 48000 16 3600 0.08 /tmp/soak.raw      # one hour, 8 channels
python3 Tools/analyze_soak.py /tmp/soak.raw 48000
log show --start '<start time>' --predicate \
  'eventMessage CONTAINS "AudioBox 1818 VSL" AND eventMessage CONTAINS "error"'
```

`soak` reports CoreAudio overloads, timeline discontinuities (with
timestamps) and callback timing.  `analyze_soak.py` fits each channel's sine
and flags any 64-sample window that deviates, so a dropout can't hide.  At
0.08 amplitude the inputs sit around −12 dBFS with knobs at noon.  A 1-hour
48 kHz recording is about 1.4 GB.  `roundtrip.c` measures latency and
`device_props.c` prints what CoreAudio reports for a device.

## Not done yet

- Overnight soak at 48 kHz / 16 frames.
- Phone control hasn't been tried on real phones or at a gig, only in headless
  Chrome.
- App Store submission (see above).
- The compressor editor's live dot uses the pre-EQ input level.
- Recordings stop at WAV's 4 GB-per-file limit (~8.3 h at 48 kHz) instead of
  rolling over to new files.
