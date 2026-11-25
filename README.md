# DDS Multiplayer

Co-op mod for Drug Dealer Simulator (Steam app 682990): Steam lobbies and invites, and a
shared world hosted by one player, for up to four players.

The same scripts run on the game's regular build (Unreal Engine 4.21) and on its
`controller_beta` branch (Unreal Engine 4.27). The beta build is tested less often. Saves
made on the regular build do not load properly on the beta build (this is the game's own
behaviour, with or without the mod); saves made on the beta load there.

This repository holds the complete source of the mod: the Lua scripts and the two pieces of
compiled code, the Steam bridge DLL and the DLL of the optional music addon.

## What is in a release archive

| File in the archive | What it is | Source |
|---|---|---|
| `ue4ss/Mods/DDSMultiplayer/Scripts/**.lua` | The mod. Plain Lua, run by UE4SS. | `mod/Scripts/` here |
| `ue4ss/Mods/DDSMultiplayer/assets/**.png` | Pictures the mod loads (scratch tickets, slot machines). | `mod/assets/` here |
| `ue4ss/Mods/DDSMultiplayer/bin/ddsmp_steam.dll` | Steam bridge: lobbies and messages between players. | `steam-bridge/` here |
| `ue4ss/Mods/DDSMultiplayer/bin/ddsmp_audio.dll` | Music addon: plays the mp3 and wav files of the mod's `Music` folder. | `audio-addon/` here |
| `ue4ss/Mods/DDSMultiplayer/Scripts/coop/music.lua`, `ue4ss/Mods/DDSMultiplayer/Music/README.txt` | The music addon's script and the text of its folder. | `mod/Scripts/coop/music.lua`, `mod/Music/` here |
| `dwmapi.dll`, `ue4ss/UE4SS.dll` | UE4SS v3.0.1 (experimental), the script loader the mod runs on. Not part of this project. | https://github.com/UE4SS-RE/RE-UE4SS |
| `ue4ss/UE4SS-settings.ini`, `ue4ss/Mods/mods.txt` and UE4SS's own stock mods | UE4SS's configuration and bundled Lua mods. | UE4SS |
| `Install.bat`, `Install.ps1`, `DDSMultiplayer-INSTALL.txt` | Optional installer: finds the game folder and copies the files into it. Plain text. | `installer/` here |

Nothing else is compiled. There is no executable, and the mod downloads nothing.

The music addon is optional: the mod runs the same without `coop/music.lua` and
`ddsmp_audio.dll`. The archive with the installer includes it. On Nexus Mods the main file
has no installer and no addon, and the addon is a file of its own (the same three files
plus `MusicAddon-INSTALL.txt`, here in `installer/`).

## Building the Steam bridge

Requirements: Windows, and the stable Rust toolchain for `x86_64-pc-windows-msvc`
(https://rustup.rs; it needs the Visual Studio C++ build tools for the linker).

```
cd steam-bridge
cargo build --release
```

The result is `steam-bridge\target\release\ddsmp_steam.dll`. It goes to
`<game>\DrugDealerSimulator\Binaries\Win64\ue4ss\Mods\DDSMultiplayer\bin\`.

The bridge has no dependencies: one source file (`steam-bridge/src/lib.rs`) and the Rust
standard library. The released DLL was built with rustc 1.95.0.

## What the bridge does

It is loaded into the game process by the Lua mod (`package.loadlib` in
`mod/Scripts/net.lua`) and does three things:

- It calls the `steam_api64.dll` that the game itself ships and has already initialised
  (Steamworks flat API): creating and joining a lobby, opening the Steam invite dialog,
  and sending data to the other lobby members over Steam P2P, with lobby chat as the
  fallback.
- It exchanges text with the Lua side through files in the mod's own `ipc` folder
  (`cmd.txt`, `evt.txt`, `pos_out.txt`, `pos_in.txt`). The protocol is described at the
  top of `lib.rs`.
- For development only, with `-ddsmp_local=host:PORT` or `-ddsmp_local=join:PORT` on the
  game's command line, it links two game instances on one machine over a TCP connection
  on `127.0.0.1`. Without that argument no socket is opened.

It does not read or write anything outside the mod's folder, and it talks to no server
other than Steam's, through the game's own Steam library.

## Building the music addon

```
cd audio-addon
set RUSTFLAGS=--remap-path-prefix=%USERPROFILE%\.cargo=cargo
cargo build --release --locked
```

The result is `audio-addon\target\release\ddsmp_audio.dll`; it goes to the same `bin`
folder. The `RUSTFLAGS` line keeps the builder's user folder out of the DLL (Rust stores
the source paths of its dependencies for error messages). The released DLL was built with
rustc 1.95.0.

It depends on `symphonia` 0.5 with the mp3, wav and pcm features (pure Rust; the exact
versions of it and of what it pulls in are in `audio-addon/Cargo.lock`).

## What the music addon does

It is loaded into the game process by `mod/Scripts/coop/music.lua` (`package.loadlib`) and
does this:

- It reads the mp3 and wav files of the mod's `Music` folder, decodes them and plays them
  through the Windows wave output (`winmm`). The game itself cannot load a sound file at
  run time. The files are only read.
- It exchanges text with the Lua side through two files of its own in the mod's `ipc`
  folder (`music_cmd.txt`, `music_evt.txt`). The commands are listed at the top of
  `audio-addon/src/audio.rs`.
- In co-op a guest receives the host's songs through the Steam bridge into
  `Music\_from_host`; the addon moves a received file to its name there and can open the
  `Music` folder in Explorer when the player presses the button for it.

It opens no network connection.

## Installing by hand

Copy the contents of a release archive into
`<Steam library>\steamapps\common\DrugDealerSimulator\DrugDealerSimulator\Binaries\Win64\`,
so that `dwmapi.dll` lies next to `DrugDealerSimulator-Win64-Shipping.exe`. Start the game
through Steam. The main menu has a MULTIPLAYER entry.

To remove the mod, delete `dwmapi.dll` and the `ue4ss` folder from that directory.

## Layout of this repository

```
mod/Scripts/       the mod (Lua): core.lua, net.lua, ui.lua, coop/*.lua ...
mod/assets/        pictures the mod loads (scratch tickets, slot machines)
mod/Music/         README.txt of the folder for the player's own songs
steam-bridge/      the bridge (Rust): Cargo.toml, Cargo.lock, src/lib.rs
audio-addon/       the music addon's DLL (Rust): Cargo.toml, Cargo.lock, src/lib.rs, src/audio.rs
installer/         Install.bat, Install.ps1, INSTALL.txt, MusicAddon-INSTALL.txt
```

## Credits

UE4SS (https://github.com/UE4SS-RE/RE-UE4SS, MIT licence) loads and runs the Lua scripts.
Drug Dealer Simulator is by Byterunners; this mod is not affiliated with them.
