# DDS Multiplayer

Co-op mod for Drug Dealer Simulator (Unreal Engine 4.21, Steam app 682990): Steam lobbies
and invites, and a shared world hosted by one player, for up to four players.

This repository holds the complete source of the mod: the Lua scripts and the one piece of
compiled code, the Steam bridge DLL.

## What is in a release archive

| File in the archive | What it is | Source |
|---|---|---|
| `ue4ss/Mods/DDSMultiplayer/Scripts/**.lua` | The mod. Plain Lua, run by UE4SS. | `mod/Scripts/` here |
| `ue4ss/Mods/DDSMultiplayer/assets/**.png` | Pictures the mod loads (the scratch tickets). | `mod/assets/` here |
| `ue4ss/Mods/DDSMultiplayer/bin/ddsmp_steam.dll` | Steam bridge: lobbies and messages between players. | `steam-bridge/` here |
| `dwmapi.dll`, `ue4ss/UE4SS.dll` | UE4SS v3.0.1 (experimental), the script loader the mod runs on. Not part of this project. | https://github.com/UE4SS-RE/RE-UE4SS |
| `ue4ss/UE4SS-settings.ini`, `ue4ss/Mods/mods.txt` and UE4SS's own stock mods | UE4SS's configuration and bundled Lua mods. | UE4SS |
| `Install.bat`, `Install.ps1`, `DDSMultiplayer-INSTALL.txt` | Optional installer: finds the game folder and copies the files into it. Plain text. | `installer/` here |

Nothing else is compiled. There is no executable, and the mod downloads nothing.

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

## Installing by hand

Copy the contents of a release archive into
`<Steam library>\steamapps\common\DrugDealerSimulator\DrugDealerSimulator\Binaries\Win64\`,
so that `dwmapi.dll` lies next to `DrugDealerSimulator-Win64-Shipping.exe`. Start the game
through Steam. The main menu has a MULTIPLAYER entry.

To remove the mod, delete `dwmapi.dll` and the `ue4ss` folder from that directory.

## Layout of this repository

```
mod/Scripts/       the mod (Lua): core.lua, net.lua, ui.lua, coop/*.lua ...
mod/assets/        pictures the mod loads (scratch tickets)
steam-bridge/      the bridge (Rust): Cargo.toml, Cargo.lock, src/lib.rs
installer/         Install.bat, Install.ps1, INSTALL.txt
```

## Credits

UE4SS (https://github.com/UE4SS-RE/RE-UE4SS, MIT licence) loads and runs the Lua scripts.
Drug Dealer Simulator is by Byterunners; this mod is not affiliated with them.
