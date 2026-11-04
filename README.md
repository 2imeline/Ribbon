# Ribbon

Ribbon is an instant-replay clipper for Apple Silicon Macs that you can leave running without noticing it. It lives in the menu bar and keeps the last 30 seconds (or however long you set) of your screen and audio in memory. Press **⌥⇧C** and that stretch is saved as an `.mp4`.

## Install

1. Download **Ribbon.zip** from the [latest release](https://github.com/2imeline/Ribbon/releases/latest).
2. Unzip it and drag **Ribbon.app** into **Applications**.
3. The first time, **right-click Ribbon → Open → Open**. Ribbon isn't notarized by Apple, so macOS asks once. If macOS still refuses, run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Ribbon.app
   ```
4. When asked, allow **Screen Recording** and **Microphone**. If you're asked to reopen Ribbon after granting Screen Recording, do that.

A ⏺ icon appears in the menu bar. That's all of Ribbon you'll see. It has no Dock icon.

## Updating

Menu bar → **Check for Updates…**, or Settings → About. Ribbon downloads the new version from this repo's Releases, swaps itself in place and relaunches. Your clips and settings stay as they are. It also checks quietly once at launch. If there's an update, the menu item changes to "Update to 1.0.x…".

## What it records

Ribbon **detects games on its own**: Roblox, Steam and Epic games, App Store and Arcade games, League, WoW, GeForce NOW and more. When you open one, a small popup says **"Now clipping Roblox · ⌥⇧C to save"**, and clips then contain **only that game's window and its audio**, plus Discord and your mic if those are on. When no game is open, Ribbon records the whole screen.

To record something else, use the menu bar → **Record**: pick **Whole Screen** or any running app. Your pick stays until you choose **Detect games** again. If a game isn't detected, pick it there.

Detection only runs when apps open, quit or switch, so it costs nothing while you play.

## Using it

| | |
|---|---|
| Save a clip | **⌥⇧C**, or the menu bar → Save Clip. A "da-ding" and a "Clip saved" popup mean it's saved |
| Watch clips | Menu bar → **Open Clips…**. Clips are grouped by day, newest first, and you can filter by game |
| Rename | Double-click the name, right-click → Rename, or edit the title in the player |
| Trim | In the player → **Trim**. Drag the yellow handles and press Trim. Ribbon saves a "(trimmed)" copy without re-encoding |
| Share to Discord | **Copy**, then paste in Discord. You can also drag a clip out of the library |
| Show in Finder / Delete | Right-click a clip, or use the buttons in the player. Delete moves the clip to the Trash |

Clips are saved to `~/Movies/Ribbon` as `<Game> 2026-11-04 14.33.02.mp4`. The name is the game being recorded, or the app in front when recording the whole screen.

## Settings

- **Clip length:** 5 s to 10 min (default 30 s).
- **Resolution:** Native, 1440p, 1080p or 720p. **Frame rate:** 30, 60 or 120. **Bitrate:** 1–100 Mbps (default 15).
- **Codec:** H.264 (default, plays everywhere) or HEVC (smaller files).
- **Audio:** game/app audio (the target app's audio, or all system audio when recording the whole screen), Discord, and microphone each turn on or off separately, and you can pick the microphone. All enabled sources are mixed into one track so every player hears them.
  Turning Discord off also hides Discord's windows from clips, because macOS filters audio per app along with its windows.
- **Hotkey**, **save folder**, **save sound**, **open at login**.

## Why it's light

- **Capture:** ScreenCaptureKit hands over frames as GPU surfaces (IOSurface) in the encoder's native format (NV12). Scaling happens on the GPU. When the screen doesn't change, no frame is produced.
- **Encode:** those surfaces go straight to the **Media Engine** hardware encoder (VideoToolbox, hardware-only, real-time, no B-frames). The CPU never touches pixels.
- **Buffer:** the last N seconds are kept **in RAM, already compressed**, so nothing is written to the SSD until you save a clip and SSD wear while idling is zero. Audio stays as raw PCM in memory, so idling spends no CPU on audio encoding.
- **Save:** the video is copied as-is (no re-encode). Only the audio is mixed and AAC-encoded, and that takes well under a second.
- **Idle:** capture pauses when the screen sleeps or locks. The clips window releases its memory when you close it.

Memory used ≈ bitrate × clip length, plus about 12 MB per audio source for every 30 s. Settings shows the live number. The table assumes game audio and mic are on.

| Clip length | 15 Mbps | 30 Mbps |
|---|---|---|
| 30 s | ~80 MB | ~135 MB |
| 2 min | ~320 MB | ~540 MB |

## Optional: keep permissions across updates

Release builds are ad-hoc signed by default. Because of that, macOS may ask for Screen Recording permission again after an update. To make it remember, give the build a stable self-signed certificate. You only do this once:

1. On your Mac, open **Keychain Access → Keychain Access menu → Certificate Assistant → Create a Certificate…**. Name: `Ribbon Self-Signed`, Identity Type: *Self Signed Root*, Certificate Type: *Code Signing*. Click Create.
2. In Keychain Access → *My Certificates*, right-click it → **Export…** → save as `Ribbon.p12` with a password.
3. Run `base64 -i Ribbon.p12 | pbcopy`. Then in GitHub → this repo → **Settings → Secrets and variables → Actions**, add `RIBBON_CERT_P12` (paste the copied text) and `RIBBON_CERT_PASSWORD`.

Builds made after that are signed with the certificate. After you install the first certificate-signed build, re-allow Screen Recording one last time.

## Building from source

If you build it yourself, create the `Ribbon Self-Signed` certificate from step 1 above once. `scripts/bundle.sh` uses it automatically, and macOS then keeps Ribbon's Screen Recording permission across rebuilds.

Requires macOS 15+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
scripts/bundle.sh
```

```bash
open build/Ribbon.app
```

Every push to `main` builds on GitHub Actions, runs the tests and publishes a numbered release. That release is what the in-app updater installs.
