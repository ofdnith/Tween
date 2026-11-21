<img src="Clarion/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="96" alt="">

# Clarion

A Mac app that shows a games console full screen with as little added delay as it can manage, and
optionally upscales, sharpens and frame-generates the picture on the way.

The picture comes from either a USB HDMI capture card or the window of a streaming app such as
PS Remote Play. Everything runs on the GPU with Apple's own frameworks (AVFoundation, Metal, MetalFX,
VideoToolbox, ScreenCaptureKit). There are no third-party dependencies and no drivers, and the app is
sandboxed.

**Status:** a hobby project, version 0.1. It has been used for hours with PS Remote Play on one
M3 MacBook. The capture-card path is written and has never been run against a real card. Intel
builds compile and have never been run. Expect rough edges.

## What it does

- **Low-latency display.** Uncompressed capture, no CPU copies, at most one frame in flight, two
  drawables. In a synthetic test on an M3 at 60 Hz this adds about 25 ms from frame arrival to screen.
- **Upscaling** to the display's resolution with MetalFX, or Lanczos where MetalFX isn't available.
- **Sharpening** (contrast adaptive), with a gentler default for compressed streams.
- **Frame generation** from 30 to 60 fps with VideoToolbox's low-latency interpolator (macOS 26 or
  newer). Details and costs below.
- **Screenshots and recording** of the enhanced picture with the game's sound, with or without the
  stats.
- **Live streaming** to Twitch and YouTube, with microphone and webcam. See Going live.
- **A latency test** for measuring the whole chain with a phone camera.

## Requirements

- macOS 14 or newer. Frame generation needs macOS 26 or newer and is hidden otherwise.
- Apple Silicon recommended.
- A UVC capture card (one macOS lists as a camera), or a streaming app on the same Mac.

## Install

Download `Clarion.zip` from [Releases](../../releases), unzip it and drag Clarion to Applications.

The app is not notarized, because that needs a paid Apple developer account. macOS will refuse to
open it the first time:

1. Double-click Clarion and dismiss the warning.
2. Open System Settings → Privacy & Security, scroll down and click **Open Anyway**.

If you would rather not trust a binary from a stranger, build it yourself (see below). The source
is about 4,000 lines of Swift and Metal.

## Use

Clarion opens borderless and full screen, on an external display if there is one. **Tab** opens the
settings.

**Capture card:** plug it in and turn the console on. Allow Camera (the video) and Microphone (the
game sound). Some consoles need HDCP turned off first (PS5: Settings → System → HDMI).

**Streaming app:** start streaming in PS Remote Play, Steam Link, Chiaki, Moonlight, Xbox or
GeForce NOW, then choose Source → Remote Play app in Clarion. Allow Screen Recording and reopen
Clarion. Keep the streaming app open; it can sit behind Clarion. Sound keeps coming from the
streaming app.

| Key | Does |
|---|---|
| Tab or ⌘, | Settings |
| O | Stats: off, compact, full |
| M | Fit / Fill / Stretch |
| V | V-Sync (off is fastest and can tear) |
| U | Upscaling |
| S | Sharpening |
| F | Frame generation |
| A | Capture-card audio |
| P | Screenshot (Pictures → Clarion) |
| R | Start / stop recording (Movies → Clarion) |
| N | Mute / unmute the microphone while live |
| L | Latency test |

## Going live

Clarion can stream what it shows to Twitch and YouTube, with the game's sound, your microphone and
a webcam. It uses the Mac's hardware H.264 encoder and nothing else. No key starts a stream: open
Settings (Tab), find Live stream and press Go live.

Type each site's stream key into Settings. Keys are kept in a file only your user account can
read, in Clarion's own folder, and are not encrypted. Set the title and who can watch on the site
itself.

- Twitch gets 1080p60 at 6,000 kbps, sent to `rtmps://live.twitch.tv/app`.
- YouTube gets 1080p, 1440p (the default) or 2160p at 9,000, 18,000 or 35,000 kbps, sent to
  `rtmps://a.rtmps.youtube.com/live2`.
- The server address and bitrate can be changed under Advanced.
- Both sites can be live at once. Each gets its own encoder unless they share a size and bitrate.
- Sound is AAC, 160 kbps, 48 kHz stereo.

The stream is a constant 60 fps on a 16:9 canvas. The picture is the one Clarion shows, upscaling
and sharpening included. The stats overlay is never in the stream, and neither is the LIVE badge
that appears at the top of your screen with the time on air.

The webcam is off by default. When on, it is a corner picture in the stream only (four corners,
three sizes), with a small preview in Settings. It never appears over the game on your own screen.

The microphone is mixed with the game sound and has its own volume. N mutes and unmutes it, and
the badge says MIC OFF while it is muted. "Remove game sound from the microphone" is for when the
game plays from the Mac's speakers, so it doesn't come back through the microphone. macOS lowers
other sound a little while it is on. With headphones, turn it off.

A connection that drops after the stream has started is retried five times, after 1, 2, 4, 8 and
16 seconds. Then that site stops and says why, and the other one carries on. A site that refuses the
stream (a wrong key, or already live), or whose first connection fails, is not retried. When the
connection is too slow, video is dropped up to the next keyframe, sound keeps going, and the site's
line in Settings says "Connection too slow".

If the hardware encoder loses its session or stops answering, Clarion starts a new one and the
stream picks up again from a keyframe. If no frame has come out 10 seconds later, the sites using
that encoder stop with "The video encoder stopped working".

The server field takes a full address, including anything after a `?` (YouTube's backup ingest is
`rtmps://b.rtmps.youtube.com/live2?backup=1`). A plain `rtmp://` address sends the stream key
unencrypted, and Settings says so under the field.

The latency test's square is part of the picture, so it is not available while live: L does nothing,
and going live turns it off.

Limits:

- With a capture card, the game's sound reaches the stream only while audio passthrough is on.
- The stream shows what Clarion shows. If its window is hidden, viewers see the last picture.
- The upload has to carry both bitrates added together.
- Twitch viewers get 1080p at most.
- There is no software encoder. On an M3 the hardware encoder ignored bitrate caps, so in very busy
  scenes Clarion holds the bitrate by skipping frames.

This has been tested against a local RTMP server. It has not been through a long stream to the real
Twitch or YouTube yet.

## Frame generation

A 30 fps game on a 60 Hz signal sends every frame twice. Clarion drops the repeats and shows a
generated frame between each pair of real ones.

What it costs: a real frame can't be shown until the frame between it and the previous one has been,
so everything is at least one refresh later. On a real PS Remote Play stream (1080p, M3, 60 Hz
display) the typical delay from frame arrival to screen was 61 ms with frame generation on. It makes
motion look smoother. It does not make the game respond faster, so leave it off for anything
timing-critical.

Things it handles that took a while to get right:

- Streams re-encode the repeated frames, so they aren't identical. Clarion learns the real/repeat
  rhythm instead of comparing pixels for equality.
- Pixels that have held still for several frames (HUD, text) are taken from the real frame, so they
  stay sharp in generated ones.
- Output is produced exactly as fast as the display consumes it, so any frame that gets queued stays
  queued. A small controller notices and skips one generated frame to drain it. Without it the same
  stream sat at about 110 ms.

What it doesn't fix: a stream that delivers a frame late leaves one refresh with nothing new to
show, and a stream that stalls shows as a stall.

## Measuring delay

The overlay's LAT line is the time from a frame's capture timestamp to that frame being on screen.
With a capture card about 20–25 ms of it is the card and macOS delivering the frame (MS2130,
1080p60, V-Sync on: 43–66 ms in total, depending on how the card's clock lines up with the display's;
its YUY2 mode is about 6 ms quicker than 420v). It does not include the console's HDMI output, the network,
or the display's own lag. With V-Sync off the line reads much lower (about 31 ms on the same card),
but macOS then reports when the frame was handed over, not when it lit up, so treat that number as
a lower bound. To measure all of it:

1. Press **L** (not while live). A square in the corner of the video turns white while the centre of the picture is bright.
2. Put something that flashes on the console.
3. Film the controller and the screen together in slow motion and count frames from the button
   press to the square. At 240 fps each frame is 4.2 ms.

## Build

Xcode 16 or newer, with the Metal toolchain installed.

```sh
xcodebuild -project Clarion.xcodeproj -scheme Clarion -derivedDataPath build build
./scripts/export.sh    # universal app and zip in export/
```

Builds are signed ad hoc. macOS ties the Camera and Screen Recording permissions to the signature,
so it asks again after each rebuild unless you set a signing team in Xcode.

`docs/PLAN.md` describes the frame path. `CLAUDE.md` holds the latency rules and the dead ends
(what was tried, measured and dropped) and is worth reading before changing the renderer.

## Known limits

- Tested with one capture card (MacroSilicon MS2130, 1080p60). Never tested on an Intel Mac or on a
  display faster than 60 Hz.
- Frame generation is 2× only, and its in-between frames are made at 720p or 1080p.
- No HDR. Sources are treated as 8-bit SDR.
- Streaming apps add their own delay, usually more than Clarion's. A capture card avoids it.
- Going live is untested on real servers, and the added delay while live has not been measured.

## License

MIT. See [LICENSE](LICENSE).

Clarion is not affiliated with Sony, Microsoft, Valve, NVIDIA or Apple. Product names belong to
their owners.
