//! Music addon of the DDS Multiplayer mod: plays the player's own music files (audio.rs).
//!
//! A separate DLL, so that the addon never replaces the mod's network bridge
//! (ddsmp_steam.dll). Loaded by the addon's Lua (`coop/music.lua`, `package.loadlib`), it
//! talks to it through two files of its own in the mod's ipc directory (the same directory
//! as the bridge's: `ipc`, or `ipc_NAME` with `-ddsmp=NAME` on the command line):
//!
//!   music_cmd.txt  Lua -> addon, one command per line (see audio.rs)
//!   music_evt.txt  addon -> Lua, one event per line, tab separated

#![allow(non_snake_case, clippy::missing_safety_doc)]

mod audio;

use std::ffi::c_void;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleFileNameW(module: *mut c_void, buf: *mut u16, len: u32) -> u32;
    fn GetModuleHandleExW(flags: u32, addr: *const u16, out: *mut *mut c_void) -> i32;
}

const GET_MODULE_HANDLE_EX_FLAG_PIN: u32 = 0x1;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

static DIR: OnceLock<PathBuf> = OnceLock::new();
static EVT: Mutex<Option<fs::File>> = Mutex::new(None);

fn clean(s: &str) -> String {
    s.chars().map(|c| if c == '\t' || c == '\r' || c == '\n' { ' ' } else { c }).collect()
}

/// Writes one event line.
pub(crate) fn emit(fields: &[&str]) {
    let line = fields.iter().map(|f| clean(f)).collect::<Vec<_>>().join("\t") + "\n";
    let mut guard = EVT.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        if let Some(dir) = DIR.get() {
            *guard = OpenOptions::new().create(true).append(true).open(dir.join("music_evt.txt")).ok();
        }
    }
    if let Some(f) = guard.as_mut() {
        if f.write_all(line.as_bytes()).is_err() {
            *guard = None;
        }
    }
}

fn arg_value(prefix: &str) -> Option<String> {
    std::env::args().find_map(|a| a.strip_prefix(prefix).map(|v| v.to_string()))
}

fn sanitize(tag: &str) -> String {
    tag.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').take(40).collect()
}

/// Reads the commands added to music_cmd.txt and hands them to the player.
fn worker() {
    let Some(dir) = DIR.get() else { return };
    let path = dir.join("music_cmd.txt");
    let mut offset = 0u64;
    let mut file: Option<fs::File> = None;
    loop {
        if file.is_none() {
            file = fs::File::open(&path).ok();
        }
        if let Some(f) = file.as_mut() {
            let len = f.metadata().map(|m| m.len()).unwrap_or(0);
            if len < offset {
                offset = 0; // (the file was emptied)
            }
            if len > offset && f.seek(SeekFrom::Start(offset)).is_ok() {
                let mut buf = Vec::new();
                if f.take(len - offset).read_to_end(&mut buf).is_ok() {
                    if let Some(last) = buf.iter().rposition(|&b| b == b'\n') {
                        offset += last as u64 + 1;
                        for line in String::from_utf8_lossy(&buf[..last]).lines() {
                            let line = line.trim_end_matches('\r');
                            if !line.is_empty() {
                                audio::command(line);
                            }
                        }
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

#[no_mangle]
pub unsafe extern "system" fn DllMain(module: *mut c_void, reason: u32, _reserved: *mut c_void) -> i32 {
    if reason == 1 {
        // (stays loaded for the life of the process: its threads run in it)
        let mut pinned = std::ptr::null_mut();
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, DllMain as *const u16, &mut pinned);
        let mut buf = [0u16; 1024];
        let n = GetModuleFileNameW(module, buf.as_mut_ptr(), buf.len() as u32) as usize;
        let dll = PathBuf::from(String::from_utf16_lossy(&buf[..n]));
        let ipc = match arg_value("-ddsmp=") {
            Some(name) => format!("ipc_{}", sanitize(&name)),
            None => "ipc".to_string(),
        };
        // <mod>/bin/ddsmp_audio.dll -> <mod>/ipc
        let dir = dll.parent().and_then(|p| p.parent()).map(|p| p.join(ipc)).unwrap_or_default();
        let _ = fs::create_dir_all(&dir);
        for name in ["music_cmd.txt", "music_evt.txt"] {
            let _ = fs::write(dir.join(name), b"");
        }
        let _ = DIR.set(dir);
        std::thread::spawn(worker);
    }
    1
}
