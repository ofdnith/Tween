# Clarion: frame path and build notes

Shows a console full screen on a Mac with the lowest delay it can, then upscales and sharpens the
picture. First goal: under 100 ms glass to glass. Second: a sharper image.

## Frame path

```
capture card ─▶ AVCaptureVideoDataOutput (YUY2 / UYVY / 420v, late frames discarded)
streaming app ─▶ ScreenCaptureKit window capture (420v, 16:9 crop of the window)
        ─▶ CVMetalTextureCache (zero copy, IOSurface-backed)
        ─▶ [frame generation: 420v copy → VTFrameProcessor → still-pixel lock]
        ─▶ YCbCr → RGB ─▶ [MetalFX / Lanczos upscale] ─▶ [CAS sharpen] into the Fit/Fill/Stretch viewport
        ─▶ CAMetalLayer (2 drawables, framebufferOnly, V-Sync toggle) ─▶ present
```

Without frame generation the capture thread hands each frame to a present queue and returns. That
queue waits until the screen can take a frame and then draws the newest one; an older frame still
waiting is replaced, not queued. If every frame ends up waiting for the screen, one is left out to
empty the display's queue.

While live, the finished picture also goes to the stream: the renderer hands the frame to the broadcaster
through the frame sink, and the broadcaster composes, encodes (hardware H.264) and sends it from its own
queue at a constant 60 fps. The capture thread and `presentQueue` do none of that work.

With frame generation the capture thread only queues GPU work. A separate queue presents the
generated frame, then the real one a refresh later, from three drawables.

## Built

1. Capture, zero-copy display, display detection, stats overlay.
2. Upscaling: MetalFX spatial, separable Lanczos-3 fallback.
3. Contrast adaptive sharpening.
4. Capture-card audio passthrough in its own session.
5. Frame generation (macOS 26+), off by default: repeat detection, still-pixel lock, latency governor.
6. Latency test, universal build script.
7. Window capture for streaming apps.
8. Screenshots and recording of the enhanced picture with the source's sound.
9. Live stream to Twitch and YouTube over RTMPS, with the game's sound, a microphone and a corner webcam.
   Reconnects on its own. A LIVE badge on the owner's screen, never in the stream. Checked against a local
   RTMP server (`scripts/check-stream.sh`). The delays while live have not been measured yet, nor a stream
   of an hour, nor a stream to the real sites.
   An encoder session that VideoToolbox loses, that keeps failing, or that holds a frame for 2 s without
   output is rebuilt (at most every 2 s) and restarts with a keyframe; after 10 s without output the sites
   on it fail and the others go on. The video is tagged BT.709 in the session, the canvas buffers and the SPS.
   Known cost: recording with the stats while live copies each frame on the CPU, on the recorder's queue,
   so the stats can be drawn on the copy and stay out of the stream. It is off the frame path.

## Looked at and not built

Checked on an M3, macOS 27:

- Apple's low-latency super resolution (`VTLowLatencySuperResolutionScaler`) takes at most 1280×1280 input
  (720p ×1.5 or 540p ×2), about 2–3 ms a frame. Useless for a 1080p source; a possible upscaler choice for 720p ones.
- Apple's temporal noise filter only accepts lossless-compressed pixel formats (`&8v0`…), not plain 420v, and
  targets camera noise, not stream compression artefacts.
- Two generated frames for a frame that arrives a refresh late: worse on screen than one. See `CLAUDE.md`.
- Open: local video files through the same pipeline, HDR output, deblocking before sharpening.
