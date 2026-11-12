# iOdus

iOdus is a native macOS front end for Xbox PC games. It looks like a game
console dashboard, and you can use it with a game controller from the couch.
It installs your Xbox PC games (owned and Game Pass), starts them with Wine and
Apple's D3DMetal, keeps their cloud saves in sync, and shows your friends,
messages, and achievements.

iOdus is written in SwiftUI. It is inspired by
[Xodus Nexus](https://github.com/domsvoboda/xodus-nexus), but it is not a clone
or a fork of it. The Xbox account work is done by the backend,
[iodus-xodus](https://github.com/burghr/iodus-xodus/tree/iodus) (branch `iodus`), a fork of
[Xodus](https://github.com/xodus-gaming/xodus) with the Nexus backend patches.

> **Unofficial project.** iOdus is not affiliated with, endorsed by, or
> sponsored by Microsoft, Xbox, Apple, CodeWeavers, Xodus, or Xodus Nexus.
> It uses no Microsoft logos or fonts. Use it at your own risk.

![The iOdus home screen with the recent games row](docs/screenshots/home.png)

| My games & apps | Achievements | Social |
|---|---|---|
| ![The library with filters](docs/screenshots/library.png) | ![The achievements list](docs/screenshots/achievements.png) | ![The messages list](docs/screenshots/social.png) |

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Build from source](#build-from-source)
- [How iOdus works](#how-iodus-works)
- [Game runtimes](#game-runtimes)
- [Saves](#saves)
- [Achievements](#achievements)
- [Friends, messages, and Store](#friends-messages-and-store)
- [Cloud streaming](#cloud-streaming)
- [Controls](#controls)
- [Files and folders](#files-and-folders)
- [Development](#development)
- [Project rules](#project-rules)
- [Known limits](#known-limits)
- [Licenses and credits](#licenses-and-credits)

## Features

- **Library:** All your owned and Game Pass games, with Store art, filters
  (All, Owned, Game Pass, Installed), and search.
- **Install and Uninstall:** A download queue with pause, resume, and stop.
  Uninstall deletes the game files after a confirmation; the saves stay.
- **Play:** iOdus starts games with Wine and D3DMetal. A on a running game stops it
  in the normal way, so that the game saves and its Xbox presence ends.
- **Game runtimes:** The built-in Game Porting Toolkit 3.0 runtime (Wine 7.7), and
  a downloadable Wine 11 runtime. You choose a default and a runtime for each game.
- **Cloud saves:** A sync status on each game page, an upload when a game quits,
  a choice when the Mac save and the cloud save are different, and save backups.
- **Achievements:** A popup over the game when you unlock one, an achievement hub,
  and the list of each game.
- **Social:** Friends (online first) and Xbox messages in one Social page.
- **Store:** "Recently added to PC Game Pass", "Trending games", and search.
- **Cloud streaming:** Games on Xbox Cloud Gaming play in the official web player
  inside iOdus, with iOdus screens over the page.
- **Status bar:** Notifications, controllers and their battery, and the network.
- **Settings:** The install folder, full screen, update checks, the game runtimes,
  Microsoft's Visual C++ runtime, and a log export without personal data.

## Requirements

- A Mac with Apple silicon and **macOS 15** or later.
- **Rosetta 2.** The game runtime is an Intel program. iOdus installs Rosetta for
  you in the first setup.
- A Microsoft account with Xbox games (owned or Game Pass for PC).
- Free disk space for the runtime (about 1 GB) and for your games.

## Quick start

1. Open `iOdus.app`.
2. Sign in with your Microsoft account in the sign-in window that iOdus opens.
3. Do the setup steps that iOdus shows:
   1. Install Rosetta (macOS asks for your administrator password).
   2. Accept Apple's license for D3DMetal, and let iOdus download the
      Game Porting Toolkit runtime. If you already have Game Porting Toolkit 3.0-3
      in `/Applications`, iOdus can copy it.
4. Choose a game, and press **Install**. iOdus shows the size and the free space first.
5. When the download is complete, press **Play**.

The first start of a runtime prepares its Wine prefix, so that start takes longer.

## Build from source

You need Xcode (Swift 6 tools) and the backend. The backend and the runtime DLLs
are separate builds.

```sh
# 1. The backend (see the README of the backend repository)
cd ~/projects/iodus-xodus
cargo build --locked --release -p xodus-cli -p xodus-service

# 2. The Xbox runtime DLLs (Xodus Wine 11 tree + Nexus and iOdus patches; long build)
cd ~/projects/iOdus
scripts/build-runtime.sh ~/projects/iodus-runtime-build

# 3. Sign the backend: a Developer ID identity if the keychain has one, else
#    the local "iOdus Local Signing" identity (keeps the Keychain access)
scripts/sign-backend.sh

# 4. Run from source, or build the app bundle
swift build
.build/debug/iOdus --windowed
scripts/build-app.sh            # makes build/iOdus.app
```

iOdus finds `xodus-cli` in this order: `$IODUS_XODUS_CLI`, the app bundle, then
`~/projects/iodus-xodus/target/release/xodus-cli`.

### Scripts

| Script | What it does |
|---|---|
| `scripts/build-app.sh [--notarize] [version]` | Builds `build/iOdus.app` with the backend, the runtime DLLs, and the icon. Signs it with the hardened runtime. With `--notarize`, Apple notarizes it (notary profile `iodus-notary`) and the ticket is stapled. |
| `scripts/make-dmg.sh [--notarize]` | Makes `build/iOdus-<version>.dmg` from `build/iOdus.app`: the app, an Applications link, and a background (`scripts/dmg/background.swift`). Signs it, and with `--notarize`, notarizes and staples it. Uses only macOS tools. |
| `scripts/build-runtime.sh <work folder>` | Builds `xgameruntime.dll` and the other Xbox runtime DLLs from the pinned Xodus Wine source, the patches in `scripts/nexus-runtime-patches/` (from Xodus Nexus) and `scripts/runtime-patches/`. Also builds the proxies in `scripts/runtime-compat/`. Needs no other checkout. |
| `scripts/build-wine-runtime.sh [<work folder>]` | Builds the Wine 11 runtime ("CrossOver 26.3 Wine") from the pinned CrossOver source. Stages: `source`, `deps`, `wine`, `assemble`, `d3dmetal`, `package`. |
| `scripts/sign-backend.sh` | Signs `xodus-cli` and `xodus-service` with the same identity and entitlements as the app. |
| `scripts/iodus-wine` | Runs Wine with the iOdus prefix, for manual tests. |
| `scripts/xodus-bridge.py` | A TCP bridge to the service socket, for manual tests. |

## How iOdus works

```
iOdus (SwiftUI)
  ├─ xodus-cli (subprocess)      account, library, Store packages, downloads,
  │                              achievements, friends, messages
  ├─ xodus-cli service           the account service on a Unix socket
  │    └─ XodusBridge (TCP)      Wine programs cannot use Unix sockets
  └─ xodus-cli run … <wine>      decrypts the game executable and starts the game
       └─ Wine + D3DMetal        with the Xbox runtime DLLs in the prefix
```

- iOdus starts `xodus-cli` as a subprocess. It does not link the Rust code.
  The account tokens stay in the backend and in the Keychain.
- **Library:** `xodus-cli library --json` gives the entitlements. The public Store
  catalog gives the titles and the art. The title history of the account gives
  the last played games and the gamerscore.
- **Downloads:** `xodus-cli streaming` downloads a game with progress lines on
  stdout and takes pause and resume on stdin. One download runs at a time.
- **Play:**
  1. iOdus prepares the prefix of the game's runtime, if necessary.
  2. iOdus starts `xodus-cli service`, if it is not running.
  3. iOdus reads the executable from `MicrosoftGame.config`, and runs
     `xodus-cli run <folder> <wine> --exe <exe> --materialize-chain --market <region>`.
- **Stop:** iOdus closes the game windows first (`taskkill` without `/f`). If the
  game is still open after 10 seconds, iOdus interrupts it.
- **Unity games:** D3DMetal crashes on Cmd+Tab in exclusive full screen. iOdus
  starts Unity games with `-window-mode borderless`.

## Game runtimes

A runtime is a Wine build with D3DMetal. Each runtime has its own Wine prefix,
because two Wine versions must not share one.

| Runtime | Wine | Where it comes from |
|---|---|---|
| Game Porting Toolkit 3.0 (default) | 7.7 | The Gcenx build of Apple's toolkit, downloaded in the setup |
| CrossOver 26.3 Wine | 11.0 | Built by `scripts/build-wine-runtime.sh` from the CrossOver 26.3 source; Settings > Game runtimes offers the download |
| CrossOver 26.3 Wine + D3DMetal 4 (beta) | 11.0 | The same Wine, with D3DMetal 4 from Game Porting Toolkit 4; macOS 27 or later; Settings > Game runtimes offers the download |

- **Settings > Game runtime:** A sets the default runtime. X prepares the prefix
  of a runtime again. A runtime that is not installed shows **Download**.
- **Game page > Runtime:** sets the runtime of one game. iOdus does not allow the
  change while a save of the game is not uploaded, or while it has a save conflict.
- **D3DMetal** is Apple's binary, and the runtime package does not contain it.
  iOdus copies D3DMetal 3 from the Game Porting Toolkit that you installed. The
  beta runtime downloads D3DMetal 4 as a separate package (see below).
- **Visual C++ runtime:** Settings > Microsoft Visual C++ runtime installs
  Microsoft's runtime into all runtime prefixes. A new prefix gets it at its setup.
- **Compatibility parts for Wine 7.7** (in `scripts/runtime-compat/`):
  - a `d3d11.dll` proxy, because D3DMetal answers E_INVALIDARG for some multisample counts
  - a `winhttp.dll` proxy, because the GPTK WinHTTP has no `WINHTTP_OPTION_URL`, and
    GDK games need it for their Xbox Live requests
  - a forwarder for the app notification API set
- The plan and the build notes are in [`docs/runtime-versions-plan.md`](docs/runtime-versions-plan.md).

### D3DMetal 4 and Forza Horizon 6

Forza Horizon 6 needs DirectX 12 enhanced barriers, which only D3DMetal 4 has.
D3DMetal 4 is part of Apple's Game Porting Toolkit 4 beta and runs only on
macOS 27.

- **Install:** Settings > Runtimes > Game runtime > "CrossOver 26.3 Wine +
  D3DMetal 4 (beta)". iOdus downloads the Wine package and the D3DMetal package
  from the iOdus release, checks both SHA-256 values and Apple's signature, and
  installs the runtime. The Forza Horizon 6 game page says when the runtime is
  missing, and the game uses the beta runtime when it is installed.
- **The D3DMetal package** (`d3dmetal-4.0b3.tar.xz`) is the `redist` folder of
  Apple's toolkit, unchanged, with Apple's license, acknowledgements, and
  read-me files. `scripts/package-d3dmetal.sh` makes it. Apple's license allows
  its free, non-commercial distribution (sections 2A(iii) and 2C).
- **For development:** `scripts/make-d3dmetal4-runtime.sh` makes the same
  runtime from a local Wine build and a local `redist` folder.

The D3DMetal 4 runtime also has a `d3d12.dll` layer from Highball in front of
D3DMetal (`scripts/runtime-compat/highball-d3d12-shim.c`). For Forza Horizon 6,
iOdus also:

- reports an Intel GPU to D3DMetal (`GameCompat.swift`);
- writes a Gaming Services version (38.117.27001.0) into the registry of each
  prefix, because the game checks it;
- puts the PlayFab save proxy from Xodus Nexus in front of the game's
  `PlayFabGameSave.dll` in the temporary launch folder
  (`scripts/runtime-compat/iodus-wine-launch`); without it, the game stops with
  E:0-17-4.

Reported by other projects: short freezes about every 1.3 seconds during play,
caused by the game's copy protection under Rosetta.

## Saves

The Xbox runtime keeps the cloud saves of a game in the prefix of its runtime:
`drive_c/users/<user>/AppData/Local/XodusGameSave/<xuid>/<scid>/`.

- **Status:** The game page shows "Cloud saves synced", "not uploaded yet",
  "Uploading the save…", or "Save conflict".
- **Upload at quit:** Many games write the save when they quit, and then end at
  once. After a game ends with a save that is not uploaded, iOdus runs a short
  sync step with the same runtime (`rundll32 xgameruntime.dll,XodusSyncSaves`).
  The step sets no Xbox presence.
- **Conflict:** When the Mac save and the cloud save both changed, Play asks which
  save to keep: "Use cloud save" or "Keep Mac save". iOdus backs up the Mac save
  before it downloads the cloud save.
- **Save backups:** The game page lists the backups. A restores a backup (after a
  new backup of the current save), and X deletes one.

## Achievements

- The `winhttp.dll` proxy writes a signal line when a game sends an achievement
  unlock. iOdus then reads the achievement list from Xbox Live. Only an
  achievement that Xbox Live lists as unlocked gets a popup, so the popup also
  confirms that Microsoft has the unlock.
- While a game runs, iOdus also reads the list every 5 minutes, and one time when
  the game stops.
- The popup shows at the bottom center of the screen, above the game, for 6 seconds.
  Each unlock also goes into the notification list.
- Games that use event-based achievements: the runtime keeps their events in a
  local file, but does not upload them yet.

## Friends, messages, and Store

- **Social:** one page with two tabs (LB and RB). Friends shows online friends
  first, then favorites. A opens a profile card. Messages shows the Xbox inbox;
  A opens a conversation, and you can write and send messages.
- **Store:** public lists without sign-in. A game in your library opens its game
  page. Other games open a Store page with a link to xbox.com, because iOdus
  cannot buy games.

## Cloud streaming

- Games in the Xbox Cloud Gaming list show **Stream** on their game page. When the
  cloud list has an edition of the game (for example "Standard Edition"), iOdus
  finds that edition through the Store data.
- iOdus opens the official web player in a web view, and covers it with its own
  screens: loading, the queue, and errors. You sign in on Microsoft's real page.
- Hold B, or press Shift+Esc, for the stream menu: resume, show the page, or stop.
- The guide of the web player works. Voice chat is off, because iOdus has no
  microphone access.

## Controls

| Input | Action |
|---|---|
| D-pad, left stick, or arrow keys | Move |
| A or Return | Select |
| B or Escape | Back |
| X | The second action of a page (for example the next library filter) |
| Y, "/", or Cmd+F | Search |
| LB and RB | Switch tabs |
| Xbox button | Home |

The mouse can click all tiles and buttons.

## Files and folders

| Path | Content |
|---|---|
| `~/Games/iOdus/<title>` | Installed games (Settings can change the folder for new installs) |
| `~/Library/Application Support/iOdus/state.json` | The download queue and the installed games |
| `~/Library/Application Support/iOdus/Runtime/` | The GPTK runtime and, for development builds, the runtime DLLs |
| `~/Library/Application Support/iOdus/Prefix/` | The Wine prefix of the GPTK runtime |
| `~/Library/Application Support/iOdus/Runtimes/<id>/` | More runtimes, each with a `runtime.json` |
| `~/Library/Application Support/iOdus/Prefixes/<id>/` | The Wine prefixes of more runtimes |
| `~/Library/Application Support/iOdus/SaveBackups/` | Save backups |
| `~/Library/Application Support/iOdus/notifications.json` | The last 50 notifications |
| `~/Library/Logs/iOdus/` | One log for each game, and `Stream.log` |
| `~/Library/Caches/iOdus/` | Store images |

**Log export:** Settings > Export logs makes a zip file on the Desktop. iOdus
removes tokens, email addresses, XUIDs, your account name, your user name, and
your home folder from it.

## Development

```sh
swift test                                   # all unit tests (no network, no Wine)
.build/debug/iOdus --demo --windowed         # sample games, no account
.build/debug/iOdus --snapshot out.png home   # one frame of a screen to a PNG file
```

Snapshot screens include `home`, `library`, `detail`, `install`, `downloads`,
`settings`, `friends`, `messages`, `conversation`, `achievements`, `hub`, `store`,
`runtimes`, `runtimesgame`, `savebackups`, `achievementpopup`, and the setup and
stream screens.

### Environment variables

| Variable | Use |
|---|---|
| `IODUS_XODUS_CLI` | The path of `xodus-cli` |
| `IODUS_WINEDEBUG` | Wine debug channels for games, for example `+loaddll,err+all,trace+gdkc` |
| `IODUS_ROSETTA_AVX=0` | Do not report AVX to games (iOdus sets `ROSETTA_ADVERTISE_AVX=1`) |
| `IODUS_PRESENCE=0` | No Xbox title presence from the runtime |
| `IODUS_LIVE=1` | Run the tests that read real data (setup download, save status) |
| `IODUS_NETWORK_TESTS=1` | Also test the public Store catalog |
| `IODUS_RUNTIME_PACKAGE=<file>` | Test the install of a runtime package |

Tests never use the real folders in `~/Library/Application Support/iOdus`, and
demo mode never reads the real runtime folders.

## Project rules

See [`CONTRIBUTING.md`](CONTRIBUTING.md). The most important rule: **Xbox Live
gets real data only.** Code and tests never send made-up or test data (events, achievements,
presence, saves, messages, friend or Store actions) to Xbox Live or other
Microsoft services. Reads are allowed. Tests of code that writes use a fake
server or injected answers.

## Known limits

- **Forza Horizon 6** does not start. On Wine 7.7, its code protection does not
  decrypt its code. On Wine 11, it gets further and then stops in D3DMetal with
  "Video Card Crash (FHG11)". CrossOver 26 users report the same. Use **Stream**.
- **Encrypted DLLs:** Games that keep DLLs (not only the executable) encrypted
  need file maps that GPTK Wine 7.7 does not read. See
  [`docs/encrypted-dlls-plan.md`](docs/encrypted-dlls-plan.md).
- **Event-based achievements and statistics** stay local; the upload format is
  not public.
- **Groups:** Group conversations show in the inbox, but you cannot reply yet.
- **Runtime download:** The Wine 11 runtime (`crossover-26.3-3.tar.xz`) is a
  file of the release v0.1.0, with its source files. You can also build it
  with `scripts/build-wine-runtime.sh`. The runtime files still contain debug
  data with the build paths.
- **Updates:** The update check ignores pre-releases, so it does not show
  v0.1.0 or later pre-releases.
- **Signing:** Release builds are signed with a Developer ID and notarized.
  `scripts/signing.sh` chooses the identity. `xodus-cli` has one entitlement
  (`Resources/xodus-cli.entitlements`): Wine needs `DYLD_FALLBACK_LIBRARY_PATH`,
  which the hardened runtime removes without it.

## Licenses and credits

- **iOdus:** the code in this repository, under the GNU General Public License
  version 3 ([LICENSE](LICENSE)). You can use, change, and share it. If you
  share a changed version, you must share its source under the same license.
- **App bundle:** `Contents/Resources/LICENSES` has the license texts and
  `SOURCES.md`, which names the exact source commits of the build.
- **Backend:** [Xodus](https://github.com/xodus-gaming/xodus) (GPL-3.0) with the
  backend patches of [Xodus Nexus](https://github.com/domsvoboda/xodus-nexus)
  (MIT). If you give someone an iOdus build that includes `xodus-cli`, the GPL
  requires that they can get the source of that backend.
- **Game Porting Toolkit and D3DMetal:** Apple's software, under Apple's license.
  iOdus downloads the [Gcenx build](https://github.com/Gcenx/game-porting-toolkit)
  after you accept the license. The app does not contain D3DMetal. For the
  D3DMetal 4 beta runtime, an iOdus release has Apple's D3DMetal 4 files,
  unchanged, free of charge and for non-commercial use only, under Apple's
  license (sections 2A(iii) and 2C), with Apple's license file. They are not
  under the iOdus license.
- **Wine 11 runtime:** Wine and the CodeWeavers changes (LGPL 2.1 or later),
  GnuTLS (LGPL 2.1 or later), Nettle and GMP (LGPL 3 or GPL 2), FreeType
  (FreeType License or GPL 2), and SDL2 (zlib License). The runtime package has the license texts and a
  source offer (`LICENSES/` and `SOURCES.md`).
- **Xbox runtime DLLs:** built from the Xodus Wine source (LGPL 2.1 or later) with
  the patches in `scripts/nexus-runtime-patches/` and `scripts/runtime-patches/`.
  The first folder is a copy of 36 runtime patches of Xodus Nexus (MIT; see its
  `NOTICE.md`). iOdus maintains them now and replaces them over time.
