# gcwii

**gcwii** is an experimental, community-built fork of [DolphiniOS](https://github.com/oatmealdome/dolphin-ios)
that brings the desktop [Dolphin](https://dolphin-emu.org/) **Netplay core** back to iOS — so an
iPhone can join the same online matches as a Windows PC, with the same emulation core, the same
protocol and the same session. GameCube and Wii emulation on iOS, now actually playable with friends
across platforms.

> Status: experimental. Netplay has been verified between an iPhone 13 mini and a Windows PC running
> desktop Dolphin. Expect rough edges; this is a fork maintained by one person, not an official release.

## Legal Notice & Disclaimer

**Read this before downloading, building or running anything from this repository.**

- **This repository does not contain any proprietary Nintendo software.** It ships no game ROMs, no
  ISO/GCM/WBFS/WIA images, no NAND dumps, no Wii Common Keys, no decryption keys, no IOS or system
  titles, and no copyrighted firmware of any kind. Only source code, build scripts and artwork
  created for this project or inherited from the GPL-licensed upstream projects are included.
- **You must supply your own games and system files.** Everything you load into the emulator has to
  come from hardware and media you legally own. Dumping games you do not own, or downloading them
  from the internet, is illegal in most countries and is not supported here.
- **This project is for educational and personal research use only.** It exists to study emulation,
  the Dolphin Netplay protocol and iOS platform integration.
- **This is not an official Dolphin or DolphiniOS build, and it is not affiliated with Nintendo.**
  "GameCube" and "Wii" are trademarks of Nintendo. gcwii is not endorsed by, sponsored by or
  associated with Nintendo in any way.
- **Any problem, error, bug or crash in gcwii is the responsibility of this fork alone.** The Dolphin
  Team and the DolphiniOS Project did not write these changes and are **not responsible** for
  anything that breaks here. Please do not report gcwii bugs on the official Dolphin forums, bug
  tracker or Discord, or to the DolphiniOS Project — they cannot help you with this build.
- Report gcwii issues at <https://github.com/AroToavina/gcwii/issues>.

## Features

- **Cross-platform Netplay — iOS ↔ PC.** gcwii re-integrates the native desktop Dolphin Netplay core
  into the iOS build, so an iPhone can host or join a session with a Windows PC instead of being
  limited to iOS-only lobbies. Hosting, joining, direct IP/port connections and the traversal server
  are all supported.
- **GameCube and Wii emulation** on iPhone and iPad, powered by the Dolphin core (Metal renderer).
- **Customizable touch controls.** Every on-screen button, stick and D-pad can be moved, resized and
  re-mapped in layout edit mode, so the controls fit your device and your hands.
- **Local controller support.** Pair an MFi, Xbox, PlayStation, Switch Pro or other GameController
  compatible pad and play with real sticks and triggers; the touch overlay can be hidden while a
  physical controller is connected.
- **Per-game and global settings** for graphics, audio, controllers and Netplay, plus save states and
  memory card support inherited from DolphiniOS.
- **Diagnostics built in.** A per-launch `events.log` written to the app's Documents folder records
  NetPlay and core activity, which makes troubleshooting a desync or a failed connection much easier.

## Requirements

**iOS device**

- A 64-bit iPhone or iPad running **iOS 14.0 or later**.
- **JIT is effectively mandatory.** Without JIT (Just-In-Time recompilation), the PowerPC core falls
  back to the interpreter: performance collapses far below 60 FPS, frame pacing becomes uneven, and
  Netplay sessions **desync within seconds** because the two peers no longer advance in lockstep.
  Enable JIT with one of these:
  - **[Jitterbug](https://github.com/osy/Jitterbug)** — pairs with a companion app to grant JIT.
  - **[SideStore](https://sidestore.io/)** (or AltStore with a JIT enabler) — sideloads the app and
    can re-enable JIT on launch.
  - **Xcode / StikDebug** — install with a debugger attached and keep the debug session (or a JIT
    enabler such as StikDebug) running so the app can map executable memory.
- A stable Wi-Fi connection. Wired/Ethernet is strongly recommended on the PC side; mobile data is
  not usable for Netplay.

**PC (for cross-platform Netplay)**

- Desktop Dolphin, the same major version as the core in your gcwii build.
- The **exact same game image** (same region, same revision, same dump format handling). A 1.0 and a
  1.02 disc, or a trimmed/rebuilt ISO, will desync immediately.
- The **same settings that affect emulated hardware**: same game region, same memory card behaviour,
  cheats and Gecko/AR codes disabled, consistent CPU/GPU determinism settings, and no per-game hacks
  that change emulation state.
- The same Netplay buffer preference on both sides; a higher buffer tolerates more latency.

**Same game and same settings is not a suggestion — it is a requirement.** Netplay runs both peers
in lockstep, so any difference in the loaded disc or emulated hardware state is a guaranteed desync.

## Usage

### 1. Install

1. Download the unsigned IPA from the [Releases](https://github.com/AroToavina/gcwii/releases)
   page (release `v1.0.0`, Dolphin core 2609).
2. Sideload it with SideStore, AltStore, Sideloadly, TrollStore or Xcode. The IPA is **unsigned**, so
   it must be signed with your own certificate.
3. Launch gcwii and enable JIT as described above *before* starting a Netplay session.

> Use the IPA attached to the latest release. Workflow artifacts are development builds and are
> not supported installation packages.

### 2. Add your games

1. Copy your legally dumped ISO/GCM/RVZ/WIA/WBFS files into the app's `Documents/Software` folder
   through the Files app (**On My iPhone → gcwii → Software**), or use the import button.
2. Wait for the game list to index. Tap a game to launch it and confirm it boots before going online.

### 3. Start a Netplay session

**Hosting on the PC (recommended and tested path):**

1. On the PC, open Dolphin → **Tools → Start Netplay Session** (or the Netplay tab).
2. Choose the **exact same game** you have on the iPhone, then click **Host**.
3. Note the IP address and port shown in the Netplay window (default port `2626`).

**Joining from the iPhone:**

1. In gcwii, open the game list and choose **NetPlay**.
2. Select the same game and press **Start / Connect**.
3. Enter the host's details:
   - **Direct connection:** the PC's LAN IP (for example `192.168.1.20`) and port `2626`.
   - **Traversal server:** use the same traversal server and room as the PC side if you are not on the
     same network, and set a room name both sides share.
4. Wait for the session to synchronize. Once both peers report the same input delay/buffer, the game
   starts on both screens.

**Hosting from the iPhone:** choose the game, select the host port, start hosting, then connect to
your iPhone's IP from the PC's Dolphin Netplay window. Port-forward `2626` on your router if joining
over the internet.

### 4. Controllers

- Physical pads: connect over Bluetooth or Lightning/USB, then open **Settings → Controllers → Port 1**
  and map the controller. Buttons are detected automatically; use the mapping screen to fix any
  layout differences.
- Touch controls: in game, open the pause menu and choose **Edit Layout** to drag, resize and
  re-map on-screen controls. The layout is saved per pad type (GameCube, Wii Remote, Classic
  Controller).
- In Netplay, only **Port 1** is used. Every peer must have a controller mapped to Port 1, otherwise
  the session will stall waiting for input.

### 5. If something goes wrong

- **Desync right after starting:** the disc images differ, or a setting (cheats, region, memory card)
  differs between the two machines. Compare the game and settings, then restart the session.
- **Stutter, low FPS, or desync after a few minutes:** JIT was not enabled. Relaunch with JIT active.
- **Connection refused / timeout:** check the port, the firewall on the PC, and that both devices are
  on the same network (or that port forwarding is configured).
- **Anything else:** copy `events.log` out of **Files → On My iPhone → gcwii** right after the problem
  happens (it is truncated on every launch) and attach it to an issue.

## Building from source

gcwii is built exactly like upstream DolphiniOS: Xcode for the app, CMake for the Dolphin core. The
[build workflow](.github/workflows/build.yml) contains the full, reproducible recipe used for the
released IPA:

```sh
xcodebuild archive \
  -project Source/iOS/App/DolphiniOS.xcodeproj \
  -scheme "DiOS (NJB)" \
  -configuration "Release (Non-Jailbroken)" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

- Bundle identifier: `com.gcwii.emu` (see
  `Source/iOS/App/Project/Config/BundleIdentifier.xcconfig`; set `DOL_PBID_BASE_IDENTIFIER` for your
  own signing identity).
- App icon source artwork: [`app-icons/`](app-icons).
- The core is compiled as `libdolphin.dylib` and embedded in the app bundle; JIT entitlements are
  required for the recompiler cores.

## License

gcwii is distributed under the **GNU General Public License, version 2 or later (GPL-2.0-or-later)**,
inherited from Dolphin and DolphiniOS. See [COPYING](COPYING) and [LICENSES](LICENSES) for the full
text. If you redistribute a modified build, you must also make the corresponding source available
under the same license.

## Credits

- **[Dolphin Emulator](https://github.com/dolphin-emu/dolphin)** — the emulation core, Netplay protocol
  and years of work by the Dolphin Team.
- **[DolphiniOS](https://github.com/oatmealdome/dolphin-ios)** and the DolphiniOS Project — the iOS
  port that this fork is based on.
- All upstream contributors whose code makes this project possible.
