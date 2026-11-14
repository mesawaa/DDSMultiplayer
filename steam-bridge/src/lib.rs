//! Network bridge for the DDS Multiplayer mod.
//!
//! Loaded into the game process by the Lua mod (`package.loadlib`). It talks to the
//! `steam_api64.dll` the game already initialised (Steamworks SDK 1.39 flat API) and
//! exchanges data with the Lua side through files in the mod's ipc directory:
//!
//!   cmd.txt      Lua -> bridge, one command per line
//!                HOST n | HOSTQUIET n | INVITE | JOIN id | LEAVE | STATE | LOOPBACK 0|1
//!                MSG <target|*> <payload>        reliable message to one peer or all
//!                FILE <target|*> <tag> <path>    reliable file transfer
//!   evt.txt      bridge -> Lua, one event per line, tab separated
//!                READY, LOBBY, MEMBERS, MEMBER, MSG, FILE, LINK, LEFT, INVITE_DIALOG, INFO, ERR
//!   pos_out.txt  Lua -> bridge: this player's latest state line (sent unreliably when it changes)
//!   pos_in.txt   bridge -> Lua: latest state line of every peer, rewritten in place, ends with END
//!
//! Transports, picked per peer:
//!   - Steam P2P (ISteamNetworking) once a ping has been answered over it;
//!   - Steam lobby chat as the always-available fallback (slower, small frames);
//!   - a localhost TCP link for development (`-ddsmp_local=host:PORT` / `join:PORT`), which
//!     lets two game instances on one machine sync without two Steam accounts.
//!
//! `-ddsmp=NAME` on the command line selects the ipc directory `ipc_NAME` so several
//! instances can share one mod folder.

#![allow(non_snake_case, clippy::missing_safety_doc)]

use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, c_void, CStr, CString};
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleA(name: *const c_char) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    fn GetModuleFileNameW(module: *mut c_void, buf: *mut u16, len: u32) -> u32;
    fn GetModuleHandleExW(flags: u32, addr: *const u16, out: *mut *mut c_void) -> i32;
}

const GET_MODULE_HANDLE_EX_FLAG_PIN: u32 = 0x1;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;

// Interface versions of Steamworks SDK 1.39 (the flat API in the game's DLL is built for these).
const VER_MATCHMAKING: &[u8] = b"SteamMatchMaking009\0";
const VER_FRIENDS: &[u8] = b"SteamFriends015\0";
const VER_USER: &[u8] = b"SteamUser019\0";
const VER_UTILS: &[u8] = b"SteamUtils008\0";
const VER_NETWORKING: &[u8] = b"SteamNetworking005\0";

const CB_GAME_LOBBY_JOIN_REQUESTED: i32 = 333;
const CB_LOBBY_ENTER: i32 = 504;
const CB_LOBBY_CHAT_UPDATE: i32 = 506;
const CB_LOBBY_CHAT_MSG: i32 = 507;
const CB_LOBBY_CREATED: i32 = 513;
const CB_P2P_SESSION_REQUEST: i32 = 1202;

const LOBBY_TYPE_FRIENDS_ONLY: i32 = 1;

// Frame: [kind u8][target u64 LE, 0 = everyone][payload]. Over lobby chat it is prefixed
// with CHAT_MAGIC.
const CHAT_MAGIC: &[u8] = b"DDSM2";
const KIND_MSG: u8 = 1;
const KIND_POS: u8 = 2;
const KIND_FILE: u8 = 3;
const KIND_PING: u8 = 4;
const KIND_PONG: u8 = 5;
const FRAME_HEADER: usize = 9;

const P2P_UNRELIABLE_NO_DELAY: i32 = 1;
const P2P_RELIABLE: i32 = 2;
const CH_MSG: i32 = 0;
const CH_POS: i32 = 1;
const CH_FILE: i32 = 2;
const CH_PING: i32 = 3;

const CHAT_CHUNK: usize = 3000;
const P2P_CHUNK: usize = 60_000;

const LOCAL_HOST_ID: u64 = 1_000_001;
const LOCAL_GUEST_ID: u64 = 1_000_002;
const LOCAL_LOBBY: u64 = 42;

#[repr(C)]
struct LobbyCreated {
    result: i32,
    lobby: u64,
}

#[repr(C)]
struct LobbyEnter {
    lobby: u64,
    permissions: u32,
    locked: u8,
    response: u32,
}

#[repr(C)]
struct LobbyChatUpdate {
    lobby: u64,
    user_changed: u64,
    making_change: u64,
    state_change: u32,
}

#[repr(C)]
struct LobbyChatMsg {
    lobby: u64,
    user: u64,
    entry_type: u8,
    chat_id: u32,
}

#[repr(C)]
struct GameLobbyJoinRequested {
    lobby: u64,
    friend: u64,
}

#[repr(C)]
struct P2PSessionRequest {
    remote: u64,
}

type P = isize;

struct Steam {
    mm: P,
    friends: P,
    utils: P,
    net: P,
    me: u64,
    register_callback: unsafe extern "C" fn(*mut Callback, i32),
    create_lobby: unsafe extern "C" fn(P, i32, i32) -> u64,
    join_lobby: unsafe extern "C" fn(P, u64) -> u64,
    leave_lobby: unsafe extern "C" fn(P, u64),
    send_chat: unsafe extern "C" fn(P, u64, *const c_void, i32) -> u8,
    get_chat_entry: unsafe extern "C" fn(P, u64, i32, *mut u64, *mut c_void, i32, *mut i32) -> i32,
    num_members: unsafe extern "C" fn(P, u64) -> i32,
    member_by_index: unsafe extern "C" fn(P, u64, i32) -> u64,
    lobby_owner: unsafe extern "C" fn(P, u64) -> u64,
    set_lobby_data: unsafe extern "C" fn(P, u64, *const c_char, *const c_char) -> u8,
    invite_dialog: unsafe extern "C" fn(P, u64),
    friend_name: unsafe extern "C" fn(P, u64) -> *const c_char,
    my_name: unsafe extern "C" fn(P) -> *const c_char,
    set_rich_presence: unsafe extern "C" fn(P, *const c_char, *const c_char) -> u8,
    overlay_enabled: unsafe extern "C" fn(P) -> u8,
    call_completed: unsafe extern "C" fn(P, u64, *mut u8) -> u8,
    call_result: unsafe extern "C" fn(P, u64, *mut c_void, i32, i32, *mut u8) -> u8,
    p2p_send: unsafe extern "C" fn(P, u64, *const c_void, u32, i32, i32) -> u8,
    p2p_available: unsafe extern "C" fn(P, *mut u32, i32) -> u8,
    p2p_read: unsafe extern "C" fn(P, *mut c_void, u32, *mut u32, *mut u64, i32) -> u8,
    p2p_accept: unsafe extern "C" fn(P, u64) -> u8,
    p2p_close: unsafe extern "C" fn(P, u64) -> u8,
}

unsafe impl Send for Steam {}
unsafe impl Sync for Steam {}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Steam,
    LocalHost(u16),
    LocalGuest(u16),
}

enum PendingKind {
    Create { invite: bool },
    Join,
}

struct Pending {
    call: u64,
    kind: PendingKind,
}

struct Peer {
    p2p_ok: bool,
    last_ping: Instant,
    pos: Option<Vec<u8>>,
}

struct FileRx {
    path: PathBuf,
    received: u32,
    /// Offsets of the chunks that have arrived (a chunk may come twice, and chunks may
    /// overtake each other when the transport changes in the middle of a file).
    seen: std::collections::HashSet<u32>,
}

#[derive(Default)]
struct Net {
    peers: HashMap<u64, Peer>,
    pos_dirty: bool,
    files: HashMap<(u64, String), FileRx>,
    /// Outgoing file chunks: (target, payload, force lobby chat). Drained a few per tick
    /// so a big file does not flood the lobby chat.
    file_queue: VecDeque<(u64, Vec<u8>, bool)>,
}

static STEAM: OnceLock<Steam> = OnceLock::new();
static DIR: OnceLock<PathBuf> = OnceLock::new();
static MODE: OnceLock<Mode> = OnceLock::new();
static LOBBY: AtomicU64 = AtomicU64::new(0);
static LOOPBACK: AtomicBool = AtomicBool::new(false);
static EVT_FILE: Mutex<Option<fs::File>> = Mutex::new(None);
static PENDING: Mutex<Vec<Pending>> = Mutex::new(Vec::new());
static NET: OnceLock<Mutex<Net>> = OnceLock::new();
/// The development link's connections: on the host one per guest (keyed by the guest's
/// id), on a guest the one to the host.
static LOCAL_STREAMS: Mutex<Vec<(u64, TcpStream)>> = Mutex::new(Vec::new());
/// A guest's own id on the development link (the host's is LOCAL_HOST_ID).
static LOCAL_ME: AtomicU64 = AtomicU64::new(LOCAL_GUEST_ID);
/// Development link only: the list of members, sent by the host.
const KIND_MEMBERS: u8 = 6;

fn net() -> std::sync::MutexGuard<'static, Net> {
    NET.get_or_init(|| Mutex::new(Net::default())).lock().unwrap_or_else(|e| e.into_inner())
}

fn mode() -> Mode {
    *MODE.get().unwrap_or(&Mode::Steam)
}

fn me() -> u64 {
    match mode() {
        Mode::Steam => STEAM.get().map(|s| s.me).unwrap_or(0),
        Mode::LocalHost(_) => LOCAL_HOST_ID,
        Mode::LocalGuest(_) => LOCAL_ME.load(Ordering::SeqCst),
    }
}

// ---------------------------------------------------------------- IPC

fn ipc_path(name: &str) -> PathBuf {
    DIR.get().cloned().unwrap_or_default().join(name)
}

fn clean(s: &str) -> String {
    s.chars().map(|c| if c == '\t' || c == '\r' || c == '\n' { ' ' } else { c }).collect()
}

fn emit(fields: &[&str]) {
    let line = fields.iter().map(|f| clean(f)).collect::<Vec<_>>().join("\t") + "\n";
    // The file is kept open: opening and closing it for every line is what a virus scanner
    // looks at every time.
    let mut guard = EVT_FILE.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() && DIR.get().is_some() {
        *guard = OpenOptions::new().create(true).append(true).open(ipc_path("evt.txt")).ok();
    }
    if let Some(f) = guard.as_mut() {
        if f.write_all(line.as_bytes()).is_err() {
            *guard = None;
        }
    }
}

fn info(text: &str) {
    emit(&["INFO", text]);
}

fn err(text: &str) {
    emit(&["ERR", text]);
}

/// Reads complete new lines from cmd.txt starting at `offset`.
fn read_commands(file: &mut Option<fs::File>, offset: &mut u64) -> Vec<String> {
    let mut out = Vec::new();
    if file.is_none() {
        *file = fs::File::open(ipc_path("cmd.txt")).ok();
    }
    let Some(f) = file.as_mut() else { return out };
    let len = match f.metadata() {
        Ok(m) => m.len(),
        Err(_) => {
            *file = None;
            return out;
        }
    };
    if len < *offset {
        *offset = 0; // file was truncated
    }
    if len == *offset || f.seek(SeekFrom::Start(*offset)).is_err() {
        return out;
    }
    let mut buf = Vec::new();
    if f.read_to_end(&mut buf).is_err() {
        return out;
    }
    let Some(last_nl) = buf.iter().rposition(|&b| b == b'\n') else { return out };
    *offset += last_nl as u64 + 1;
    for line in String::from_utf8_lossy(&buf[..last_nl]).lines() {
        let line = line.trim_end_matches('\r');
        if !line.is_empty() {
            out.push(line.to_string());
        }
    }
    out
}

fn sanitize_tag(tag: &str) -> String {
    let t: String = tag.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').take(40).collect();
    if t.is_empty() { "file".into() } else { t }
}

// ---------------------------------------------------------------- frames

fn frame(kind: u8, target: u64, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(FRAME_HEADER + payload.len());
    v.push(kind);
    v.extend_from_slice(&target.to_le_bytes());
    v.extend_from_slice(payload);
    v
}

/// Handles one received frame. `direct` is true when it arrived over P2P or the local link.
fn dispatch(sender: u64, data: &[u8], direct: bool) {
    if data.len() < FRAME_HEADER || sender == 0 {
        return;
    }
    let kind = data[0];
    let target = u64::from_le_bytes(data[1..9].try_into().unwrap());
    let mine = me();
    if target != 0 && target != mine {
        return;
    }
    let payload = &data[FRAME_HEADER..];
    if direct && sender != mine {
        let mut n = net();
        if let Some(p) = n.peers.get_mut(&sender) {
            if !p.p2p_ok {
                p.p2p_ok = true;
                drop(n);
                emit(&["LINK", &sender.to_string(), "p2p"]);
            }
        }
    }
    match kind {
        KIND_MSG => {
            emit(&["MSG", &sender.to_string(), &name_of(sender), &String::from_utf8_lossy(payload)]);
        }
        KIND_POS => {
            let mut n = net();
            if let Some(p) = n.peers.get_mut(&sender) {
                p.pos = Some(payload.to_vec());
                n.pos_dirty = true;
            }
        }
        KIND_FILE => receive_file_chunk(sender, payload),
        KIND_PING => {
            if direct {
                send_direct(sender, &frame(KIND_PONG, sender, b""), true, CH_PING);
            }
        }
        _ => {}
    }
}

fn receive_file_chunk(sender: u64, payload: &[u8]) {
    // [u16 tag len][tag][u32 total][u32 offset][bytes]
    if payload.len() < 2 {
        return;
    }
    let tag_len = u16::from_le_bytes([payload[0], payload[1]]) as usize;
    if payload.len() < 2 + tag_len + 8 {
        return;
    }
    let tag = sanitize_tag(&String::from_utf8_lossy(&payload[2..2 + tag_len]));
    let total = u32::from_le_bytes(payload[2 + tag_len..6 + tag_len].try_into().unwrap());
    let offset = u32::from_le_bytes(payload[6 + tag_len..10 + tag_len].try_into().unwrap());
    let bytes = &payload[10 + tag_len..];
    let key = (sender, tag.clone());
    let mut n = net();
    // Chunks are written where they belong, in whatever order they come: the first part of
    // a file may travel through the lobby and the rest over the direct link that came up
    // meanwhile, and then the later chunks arrive first.
    if total == 0 || total > 256 * 1024 * 1024 || offset as u64 + bytes.len() as u64 > total as u64 {
        return;
    }
    if !n.files.contains_key(&key) {
        let path = ipc_path(&format!("recv_{}_{}.bin", tag, sender));
        match fs::File::create(&path) {
            Ok(f) => {
                let _ = f.set_len(total as u64);
            }
            Err(_) => return,
        }
        n.files.insert(key.clone(), FileRx { path, received: 0, seen: std::collections::HashSet::new() });
    }
    let Some(rx) = n.files.get_mut(&key) else { return };
    if !rx.seen.insert(offset) {
        return; // this chunk has been written already
    }
    let written = match OpenOptions::new().write(true).open(&rx.path) {
        Ok(mut f) => f.seek(SeekFrom::Start(offset as u64)).is_ok() && f.write_all(bytes).is_ok(),
        Err(_) => false,
    };
    if !written {
        rx.seen.remove(&offset);
        return;
    }
    rx.received += bytes.len() as u32;
    if rx.received >= total {
        let path = rx.path.to_string_lossy().into_owned();
        n.files.remove(&key);
        drop(n);
        emit(&["FILE", &sender.to_string(), &tag, &path, &total.to_string()]);
    }
}

// ---------------------------------------------------------------- sending

/// Writes one frame to the development link: `[len u32][sender u64][frame]`. `only` limits
/// it to one connection, `except` leaves one out. False when nothing took it.
fn local_send(sender: u64, data: &[u8], only: Option<u64>, except: Option<u64>) -> bool {
    let mut guard = LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner());
    let mut out = Vec::with_capacity(12 + data.len());
    out.extend_from_slice(&((data.len() + 8) as u32).to_le_bytes());
    out.extend_from_slice(&sender.to_le_bytes());
    out.extend_from_slice(data);
    let mut sent = false;
    let mut broken: Vec<u64> = Vec::new();
    for (id, stream) in guard.iter_mut() {
        if only.map(|o| o != *id).unwrap_or(false) || except == Some(*id) {
            continue;
        }
        if stream.write_all(&out).is_ok() {
            sent = true;
        } else {
            broken.push(*id);
        }
    }
    guard.retain(|(id, _)| !broken.contains(id));
    sent
}

/// Sends one of our own frames over the development link. A guest has only the host to
/// send to (which passes on what is meant for another guest); the host picks the guest.
fn local_write(data: &[u8]) -> bool {
    if data.len() < FRAME_HEADER {
        return false;
    }
    let target = u64::from_le_bytes(data[1..9].try_into().unwrap());
    if me() == LOCAL_HOST_ID {
        local_send(LOCAL_HOST_ID, data, if target == 0 { None } else { Some(target) }, None)
    } else {
        local_send(me(), data, None, None)
    }
}

fn chat_send(data: &[u8]) -> bool {
    let Some(steam) = STEAM.get() else { return false };
    let lobby = LOBBY.load(Ordering::SeqCst);
    if lobby == 0 || data.len() + CHAT_MAGIC.len() > 3900 {
        return false;
    }
    let mut body = Vec::with_capacity(CHAT_MAGIC.len() + data.len());
    body.extend_from_slice(CHAT_MAGIC);
    body.extend_from_slice(data);
    unsafe { (steam.send_chat)(steam.mm, lobby, body.as_ptr() as *const c_void, body.len() as i32) != 0 }
}

/// Sends a frame straight to one peer (P2P or local link). Returns false if that failed.
fn send_direct(peer: u64, data: &[u8], reliable: bool, channel: i32) -> bool {
    match mode() {
        Mode::Steam => {
            let Some(steam) = STEAM.get() else { return false };
            let kind = if reliable { P2P_RELIABLE } else { P2P_UNRELIABLE_NO_DELAY };
            unsafe { (steam.p2p_send)(steam.net, peer, data.as_ptr() as *const c_void, data.len() as u32, kind, channel) != 0 }
        }
        _ => local_write(data),
    }
}

/// Peers a frame for `target` (0 = all) goes to, and whether all of them have a direct link.
fn route(target: u64) -> (Vec<u64>, bool) {
    let n = net();
    let ids: Vec<u64> = n.peers.keys().copied().filter(|id| target == 0 || *id == target).collect();
    let all_direct = mode() != Mode::Steam || ids.iter().all(|id| n.peers.get(id).map(|p| p.p2p_ok).unwrap_or(false));
    (ids, all_direct)
}

/// Sends a frame to `target` (0 = all peers), choosing the transport. Unreliable frames
/// are dropped rather than queued when nothing can carry them.
fn send_frame(kind: u8, target: u64, payload: &[u8], reliable: bool, channel: i32) -> bool {
    let data = frame(kind, target, payload);
    if target == 0 && LOOPBACK.load(Ordering::SeqCst) && kind == KIND_MSG {
        dispatch(me(), &data, false);
    }
    let (ids, all_direct) = route(target);
    if ids.is_empty() {
        return false;
    }
    if all_direct {
        if mode() != Mode::Steam {
            return local_write(&data);
        }
        let mut ok = true;
        for id in ids {
            if !send_direct(id, &data, reliable, channel) {
                ok = false;
                if let Some(p) = net().peers.get_mut(&id) {
                    p.p2p_ok = false;
                }
                emit(&["LINK", &id.to_string(), "lobby"]);
                if reliable {
                    chat_send(&frame(kind, id, payload));
                }
            }
        }
        ok
    } else {
        chat_send(&data)
    }
}

fn queue_file(target: u64, tag: &str, path: &str, force_chat: bool) {
    let Ok(bytes) = fs::read(path) else { return err(&format!("Cannot read {}", path)) };
    let (ids, all_direct) = route(target);
    if ids.is_empty() && !force_chat {
        return err("No peer to send the file to");
    }
    let tag = sanitize_tag(tag);
    let chunk = if all_direct && !force_chat { P2P_CHUNK } else { CHAT_CHUNK };
    let total = bytes.len() as u32;
    let mut n = net();
    let mut offset = 0usize;
    loop {
        let end = (offset + chunk).min(bytes.len());
        let mut payload = Vec::with_capacity(10 + tag.len() + end - offset);
        payload.extend_from_slice(&(tag.len() as u16).to_le_bytes());
        payload.extend_from_slice(tag.as_bytes());
        payload.extend_from_slice(&total.to_le_bytes());
        payload.extend_from_slice(&(offset as u32).to_le_bytes());
        payload.extend_from_slice(&bytes[offset..end]);
        n.file_queue.push_back((target, payload, force_chat));
        offset = end;
        if offset >= bytes.len() {
            break;
        }
    }
}

/// Sends queued file chunks: several per tick over a direct link, one every 50 ms over
/// lobby chat (about 60 kB/s) to stay under the chat rate limit of Steam.
fn pump_file_queue(last_chat_chunk: &mut Instant) {
    for _ in 0..4 {
        let (direct, forced) = {
            let n = net();
            let Some((target, _, forced)) = n.file_queue.front() else { return };
            let direct = mode() != Mode::Steam
                || n.peers.iter().filter(|(id, _)| *target == 0 || **id == *target).all(|(_, p)| p.p2p_ok);
            (direct && !*forced, *forced)
        };
        if !direct && last_chat_chunk.elapsed() < Duration::from_millis(50) {
            return;
        }
        let Some((target, payload, _)) = net().file_queue.pop_front() else { return };
        if forced {
            chat_send(&frame(KIND_FILE, target, &payload));
        } else {
            send_frame(KIND_FILE, target, &payload, true, CH_FILE);
        }
        if !direct {
            *last_chat_chunk = Instant::now();
            return;
        }
    }
}

/// Exercises the Steam transports against ourselves (needs LOOPBACK 1 and a lobby):
/// a lobby chat message, a file through lobby chat, and a P2P packet to our own id.
fn selftest(path: &str) {
    let Some(steam) = STEAM.get() else { return err("Steam is not ready yet") };
    if LOBBY.load(Ordering::SeqCst) == 0 {
        return err("Self-test needs a lobby");
    }
    let ok = chat_send(&frame(KIND_MSG, steam.me, b"{\"t\":\"selftest\",\"via\":\"chat\"}"));
    info(&format!("Self-test: chat message sent={}", ok));
    if !path.is_empty() {
        queue_file(steam.me, "selftest", path, true);
    }
    let ping = frame(KIND_PING, steam.me, b"");
    let sent = unsafe { (steam.p2p_send)(steam.net, steam.me, ping.as_ptr() as *const c_void, ping.len() as u32, P2P_RELIABLE, CH_PING) };
    info(&format!("Self-test: P2P packet to self sent={}", sent));
}

// ---------------------------------------------------------------- positions

fn pump_positions(
    last_out: &mut Vec<u8>,
    last_send: &mut Instant,
    last_write: &mut Instant,
    out_file: &mut Option<fs::File>,
    in_file: &mut Option<fs::File>,
) {
    // Outgoing: send when the Lua side has written a new line. (Both files stay open.)
    if out_file.is_none() {
        *out_file = fs::File::open(ipc_path("pos_out.txt")).ok();
    }
    let mut buf = [0u8; 1200];
    let mut got = 0usize;
    if let Some(f) = out_file.as_mut() {
        match f.seek(SeekFrom::Start(0)).and_then(|_| f.read(&mut buf)) {
            Ok(n) => got = n,
            Err(_) => *out_file = None,
        }
    }
    if got > 0 {
        let data = &buf[..got];
        let line = data.split(|&b| b == b'\n').next().unwrap_or(&[]);
        if !line.is_empty() && line.len() < 1000 && line != last_out.as_slice() {
            let (ids, all_direct) = route(0);
            let min_gap = if all_direct { 30 } else { 250 };
            if !ids.is_empty() && last_send.elapsed() >= Duration::from_millis(min_gap) {
                *last_out = line.to_vec();
                *last_send = Instant::now();
                send_frame(KIND_POS, 0, line, false, CH_POS);
            }
        }
    }
    // Incoming: rewrite the snapshot file when something changed.
    if last_write.elapsed() >= Duration::from_millis(30) {
        let mut n = net();
        if n.pos_dirty {
            n.pos_dirty = false;
            let mut out = Vec::new();
            for (id, p) in n.peers.iter() {
                if let Some(pos) = &p.pos {
                    out.extend_from_slice(id.to_string().as_bytes());
                    out.push(b'\t');
                    out.extend_from_slice(pos);
                    out.push(b'\n');
                }
            }
            out.extend_from_slice(b"END\n");
            drop(n);
            if in_file.is_none() {
                *in_file = OpenOptions::new().write(true).create(true).open(ipc_path("pos_in.txt")).ok();
            }
            if let Some(f) = in_file.as_mut() {
                // emptied first: a reader that comes in between sees no END and waits
                let ok = f.seek(SeekFrom::Start(0)).is_ok() && f.set_len(0).is_ok() && f.write_all(&out).is_ok();
                if !ok {
                    *in_file = None;
                }
            }
            *last_write = Instant::now();
        }
    }
}

// ---------------------------------------------------------------- Steam callbacks

#[repr(C)]
struct CallbackVtbl {
    // MSVC lays out the two Run overloads in reverse declaration order. Both entries only
    // use the data pointer, so the exact order does not matter.
    run_a: unsafe extern "C" fn(*mut Callback, *mut c_void, u8, u64),
    run_b: unsafe extern "C" fn(*mut Callback, *mut c_void),
    size: unsafe extern "C" fn(*mut Callback) -> i32,
}

#[repr(C)]
struct Callback {
    vtbl: *const CallbackVtbl,
    flags: u8,
    id: i32,
    handler: fn(*const c_void),
    size: i32,
}

unsafe extern "C" fn cb_run_a(this: *mut Callback, data: *mut c_void, _io_failure: u8, _call: u64) {
    if !data.is_null() {
        ((*this).handler)(data);
    }
}

unsafe extern "C" fn cb_run_b(this: *mut Callback, data: *mut c_void) {
    if !data.is_null() {
        ((*this).handler)(data);
    }
}

unsafe extern "C" fn cb_size(this: *mut Callback) -> i32 {
    (*this).size
}

static CALLBACK_VTBL: CallbackVtbl = CallbackVtbl { run_a: cb_run_a, run_b: cb_run_b, size: cb_size };

fn register(steam: &Steam, id: i32, size: usize, handler: fn(*const c_void)) {
    let cb = Box::leak(Box::new(Callback { vtbl: &CALLBACK_VTBL, flags: 0, id: 0, handler, size: size as i32 }));
    unsafe { (steam.register_callback)(cb, id) };
}

fn on_join_requested(data: *const c_void) {
    let d = unsafe { &*(data as *const GameLobbyJoinRequested) };
    info("Steam invite accepted, joining lobby");
    join(d.lobby);
}

fn on_chat_update(data: *const c_void) {
    let d = unsafe { &*(data as *const LobbyChatUpdate) };
    let Some(steam) = STEAM.get() else { return };
    if d.lobby != LOBBY.load(Ordering::SeqCst) || d.lobby == 0 {
        return;
    }
    let what = if d.state_change & 1 != 0 { "joined" } else { "left" };
    emit(&["MEMBER", what, &d.user_changed.to_string(), &name_of(d.user_changed)]);
    emit_members(steam, d.lobby);
}

fn on_chat_msg(data: *const c_void) {
    let d = unsafe { &*(data as *const LobbyChatMsg) };
    let Some(steam) = STEAM.get() else { return };
    if d.lobby != LOBBY.load(Ordering::SeqCst) || d.lobby == 0 {
        return;
    }
    let mut buf = [0u8; 4096];
    let mut sender = 0u64;
    let mut entry_type = 0i32;
    let n = unsafe {
        (steam.get_chat_entry)(
            steam.mm,
            d.lobby,
            d.chat_id as i32,
            &mut sender,
            buf.as_mut_ptr() as *mut c_void,
            buf.len() as i32,
            &mut entry_type,
        )
    };
    if n <= 0 || entry_type != 1 {
        return;
    }
    let body = &buf[..(n as usize).min(buf.len())];
    let Some(data) = body.strip_prefix(CHAT_MAGIC) else { return };
    if sender == steam.me && !LOOPBACK.load(Ordering::SeqCst) {
        return; // our own broadcast echoed back by Steam
    }
    dispatch(sender, data, false);
}

fn on_lobby_enter(_data: *const c_void) {
    // Create/join results are read through the API call result; nothing to do here.
}

fn on_p2p_session_request(data: *const c_void) {
    let d = unsafe { &*(data as *const P2PSessionRequest) };
    let Some(steam) = STEAM.get() else { return };
    // Only lobby members may open a session.
    if net().peers.contains_key(&d.remote) {
        unsafe { (steam.p2p_accept)(steam.net, d.remote) };
    }
}

// ---------------------------------------------------------------- Steam helpers

fn name_of(id: u64) -> String {
    match id {
        LOCAL_HOST_ID => return "DevHost".into(),
        LOCAL_GUEST_ID => return "DevGuest".into(),
        _ => {}
    }
    if mode() != Mode::Steam {
        return format!("DevGuest{}", id.saturating_sub(LOCAL_HOST_ID));
    }
    let Some(steam) = STEAM.get() else { return id.to_string() };
    let p = unsafe {
        if id == steam.me {
            (steam.my_name)(steam.friends)
        } else {
            (steam.friend_name)(steam.friends, id)
        }
    };
    if p.is_null() {
        return id.to_string();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    if s.is_empty() { id.to_string() } else { s }
}

/// Brings the peer table in line with the member list and reports the members.
fn set_members(ids: &[u64], owner: u64) {
    let mine = me();
    {
        let mut n = net();
        let gone: Vec<u64> = n.peers.keys().copied().filter(|id| !ids.contains(id)).collect();
        for id in gone {
            n.peers.remove(&id);
            n.pos_dirty = true;
            if let Some(steam) = STEAM.get() {
                if mode() == Mode::Steam {
                    unsafe { (steam.p2p_close)(steam.net, id) };
                }
            }
        }
        for id in ids {
            if *id != mine && !n.peers.contains_key(id) {
                let direct = mode() != Mode::Steam;
                n.peers.insert(*id, Peer { p2p_ok: direct, last_ping: Instant::now() - Duration::from_secs(10), pos: None });
            }
        }
    }
    let mut fields = vec!["MEMBERS".to_string(), ids.len().to_string(), owner.to_string()];
    for id in ids {
        fields.push(format!("{}={}", id, name_of(*id)));
    }
    emit(&fields.iter().map(|s| s.as_str()).collect::<Vec<_>>());
}

fn emit_members(steam: &Steam, lobby: u64) {
    let n = unsafe { (steam.num_members)(steam.mm, lobby) }.max(0);
    let ids: Vec<u64> = (0..n).map(|i| unsafe { (steam.member_by_index)(steam.mm, lobby, i) }).collect();
    let owner = unsafe { (steam.lobby_owner)(steam.mm, lobby) };
    set_members(&ids, owner);
}

fn emit_state() {
    let mine = me();
    emit(&["READY", &mine.to_string(), &name_of(mine)]);
    match mode() {
        Mode::Steam => {
            let Some(steam) = STEAM.get() else { return };
            let lobby = LOBBY.load(Ordering::SeqCst);
            if lobby != 0 {
                let owner = unsafe { (steam.lobby_owner)(steam.mm, lobby) };
                emit(&["LOBBY", &lobby.to_string(), "current", &owner.to_string()]);
                emit_members(steam, lobby);
            } else {
                emit(&["LEFT"]);
            }
        }
        _ => {
            if LOBBY.load(Ordering::SeqCst) != 0 {
                emit(&["LOBBY", &LOCAL_LOBBY.to_string(), "current", &LOCAL_HOST_ID.to_string()]);
                let ids = local_members();
                set_members(&ids, LOCAL_HOST_ID);
            } else {
                emit(&["LEFT"]);
            }
        }
    }
}

fn set_connect_presence(steam: &Steam, lobby: u64) {
    let value = if lobby != 0 { format!("+connect_lobby {}", lobby) } else { String::new() };
    let value = CString::new(value).unwrap_or_default();
    unsafe { (steam.set_rich_presence)(steam.friends, b"connect\0".as_ptr() as *const c_char, value.as_ptr()) };
}

fn open_invite_dialog(steam: &Steam) {
    let lobby = LOBBY.load(Ordering::SeqCst);
    if lobby == 0 {
        err("Not in a lobby");
        return;
    }
    if unsafe { (steam.overlay_enabled)(steam.utils) } == 0 {
        info("Steam overlay is disabled: friends can still use 'Join Game' on you in their friends list");
        return;
    }
    unsafe { (steam.invite_dialog)(steam.friends, lobby) };
    emit(&["INVITE_DIALOG"]);
}

fn forget_peers() {
    let mut n = net();
    if let Some(steam) = STEAM.get() {
        if mode() == Mode::Steam {
            for id in n.peers.keys() {
                unsafe { (steam.p2p_close)(steam.net, *id) };
            }
        }
    }
    n.peers.clear();
    n.files.clear();
    n.file_queue.clear();
    n.pos_dirty = true;
}

fn leave() {
    if mode() != Mode::Steam {
        return;
    }
    let Some(steam) = STEAM.get() else { return };
    let lobby = LOBBY.swap(0, Ordering::SeqCst);
    if lobby != 0 {
        unsafe { (steam.leave_lobby)(steam.mm, lobby) };
        set_connect_presence(steam, 0);
        forget_peers();
        emit(&["LEFT"]);
    }
}

fn host(max_members: i32, invite: bool) {
    if mode() != Mode::Steam {
        return emit_state();
    }
    let Some(steam) = STEAM.get() else { return err("Steam is not ready yet") };
    if LOBBY.load(Ordering::SeqCst) != 0 {
        if invite {
            open_invite_dialog(steam);
        }
        return;
    }
    let mut pending = PENDING.lock().unwrap();
    if pending.iter().any(|p| matches!(p.kind, PendingKind::Create { .. })) {
        return;
    }
    let call = unsafe { (steam.create_lobby)(steam.mm, LOBBY_TYPE_FRIENDS_ONLY, max_members.clamp(2, 16)) };
    if call == 0 {
        return err("CreateLobby failed to start");
    }
    pending.push(Pending { call, kind: PendingKind::Create { invite } });
}

fn join(lobby: u64) {
    if mode() != Mode::Steam {
        return;
    }
    let Some(steam) = STEAM.get() else { return err("Steam is not ready yet") };
    if lobby == 0 || lobby == LOBBY.load(Ordering::SeqCst) {
        return;
    }
    leave();
    let call = unsafe { (steam.join_lobby)(steam.mm, lobby) };
    if call == 0 {
        return err("JoinLobby failed to start");
    }
    PENDING.lock().unwrap().push(Pending { call, kind: PendingKind::Join });
}

fn poll_pending(steam: &Steam) {
    let mut done = Vec::new();
    {
        let mut pending = PENDING.lock().unwrap();
        let mut i = 0;
        while i < pending.len() {
            let mut failed = 0u8;
            if unsafe { (steam.call_completed)(steam.utils, pending[i].call, &mut failed) } != 0 {
                done.push(pending.remove(i));
            } else {
                i += 1;
            }
        }
    }
    for p in done {
        let mut failed = 0u8;
        match p.kind {
            PendingKind::Create { invite } => {
                let mut r = LobbyCreated { result: 0, lobby: 0 };
                let ok = unsafe {
                    (steam.call_result)(
                        steam.utils,
                        p.call,
                        &mut r as *mut _ as *mut c_void,
                        std::mem::size_of::<LobbyCreated>() as i32,
                        CB_LOBBY_CREATED,
                        &mut failed,
                    )
                };
                if ok == 0 || failed != 0 || r.result != 1 || r.lobby == 0 {
                    err(&format!("Could not create Steam lobby (result {})", r.result));
                    continue;
                }
                LOBBY.store(r.lobby, Ordering::SeqCst);
                unsafe {
                    (steam.set_lobby_data)(
                        steam.mm,
                        r.lobby,
                        b"ddsmp\0".as_ptr() as *const c_char,
                        b"2\0".as_ptr() as *const c_char,
                    )
                };
                set_connect_presence(steam, r.lobby);
                emit(&["LOBBY", &r.lobby.to_string(), "created", &steam.me.to_string()]);
                emit_members(steam, r.lobby);
                if invite {
                    open_invite_dialog(steam);
                }
            }
            PendingKind::Join => {
                let mut r = LobbyEnter { lobby: 0, permissions: 0, locked: 0, response: 0 };
                let ok = unsafe {
                    (steam.call_result)(
                        steam.utils,
                        p.call,
                        &mut r as *mut _ as *mut c_void,
                        std::mem::size_of::<LobbyEnter>() as i32,
                        CB_LOBBY_ENTER,
                        &mut failed,
                    )
                };
                if ok == 0 || failed != 0 || r.response != 1 || r.lobby == 0 {
                    err(&format!("Could not join Steam lobby (response {})", r.response));
                    continue;
                }
                LOBBY.store(r.lobby, Ordering::SeqCst);
                set_connect_presence(steam, r.lobby);
                let owner = unsafe { (steam.lobby_owner)(steam.mm, r.lobby) };
                emit(&["LOBBY", &r.lobby.to_string(), "joined", &owner.to_string()]);
                emit_members(steam, r.lobby);
            }
        }
    }
}

/// Reads everything waiting on the Steam P2P channels.
fn pump_p2p(steam: &Steam, buf: &mut Vec<u8>) {
    for channel in [CH_MSG, CH_POS, CH_FILE, CH_PING] {
        for _ in 0..256 {
            let mut size = 0u32;
            if unsafe { (steam.p2p_available)(steam.net, &mut size, channel) } == 0 {
                break;
            }
            if buf.len() < size as usize {
                buf.resize(size as usize, 0);
            }
            let mut read = 0u32;
            let mut sender = 0u64;
            let ok = unsafe {
                (steam.p2p_read)(steam.net, buf.as_mut_ptr() as *mut c_void, buf.len() as u32, &mut read, &mut sender, channel)
            };
            if ok == 0 {
                break;
            }
            // Only lobby members are listened to.
            if net().peers.contains_key(&sender) {
                dispatch(sender, &buf[..read as usize], true);
            } else if sender == steam.me && LOOPBACK.load(Ordering::SeqCst) {
                info("Self-test: P2P packet from self received");
            }
        }
    }
}

/// Probes the P2P path to peers that are still on the lobby-chat fallback.
fn pump_pings() {
    if mode() != Mode::Steam {
        return;
    }
    let due: Vec<u64> = {
        let mut n = net();
        let mut v = Vec::new();
        for (id, p) in n.peers.iter_mut() {
            if !p.p2p_ok && p.last_ping.elapsed() >= Duration::from_secs(2) {
                p.last_ping = Instant::now();
                v.push(*id);
            }
        }
        v
    };
    for id in due {
        send_direct(id, &frame(KIND_PING, id, b""), true, CH_PING);
    }
}

// ---------------------------------------------------------------- local development link

/// Everybody on the development link, as this side knows it.
fn local_members() -> Vec<u64> {
    let mut ids = vec![LOCAL_HOST_ID];
    if me() == LOCAL_HOST_ID {
        for (id, _) in LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            ids.push(*id);
        }
    } else {
        let n = net();
        for id in n.peers.keys() {
            if *id != LOCAL_HOST_ID {
                ids.push(*id);
            }
        }
        ids.push(me());
    }
    ids.sort();
    ids.dedup();
    ids
}

/// Host: tells itself and every guest who is on the link now.
fn local_announce_members() {
    let ids = local_members();
    set_members(&ids, LOCAL_HOST_ID);
    let mut payload = Vec::with_capacity(ids.len() * 8);
    for id in &ids {
        payload.extend_from_slice(&id.to_le_bytes());
    }
    local_send(LOCAL_HOST_ID, &frame(KIND_MEMBERS, 0, &payload), None, None);
}

fn local_read(reader: &mut TcpStream) -> Option<(u64, Vec<u8>)> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).ok()?;
    let len = u32::from_le_bytes(len_buf) as usize;
    if !(8..=8 * 1024 * 1024).contains(&len) {
        return None;
    }
    let mut data = vec![0u8; len];
    reader.read_exact(&mut data).ok()?;
    let sender = u64::from_le_bytes(data[..8].try_into().unwrap());
    Some((sender, data[8..].to_vec()))
}

/// Host: one guest's connection, from its first message to its end.
fn local_serve(stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let Ok(mut reader) = stream.try_clone() else { return };
    // the first message says who it is
    let Some((guest, _)) = local_read(&mut reader) else { return };
    if guest <= LOCAL_HOST_ID {
        return;
    }
    {
        let mut streams = LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner());
        streams.retain(|(id, _)| *id != guest);
        streams.push((guest, stream));
    }
    if LOBBY.swap(LOCAL_LOBBY, Ordering::SeqCst) == 0 {
        emit(&["LOBBY", &LOCAL_LOBBY.to_string(), "created", &LOCAL_HOST_ID.to_string()]);
    }
    local_announce_members();
    emit(&["MEMBER", "joined", &guest.to_string(), &name_of(guest)]);
    emit(&["LINK", &guest.to_string(), "local"]);
    while let Some((_, data)) = local_read(&mut reader) {
        if data.len() < FRAME_HEADER {
            continue;
        }
        let target = u64::from_le_bytes(data[1..9].try_into().unwrap());
        if target == 0 {
            // for everybody: us and the other guests
            local_send(guest, &data, None, Some(guest));
            dispatch(guest, &data, true);
        } else if target == LOCAL_HOST_ID {
            dispatch(guest, &data, true);
        } else {
            local_send(guest, &data, Some(target), None);
        }
    }
    let left = {
        let mut streams = LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner());
        streams.retain(|(id, _)| *id != guest);
        streams.is_empty()
    };
    emit(&["MEMBER", "left", &guest.to_string(), &name_of(guest)]);
    if left {
        // the last guest is gone: the lobby ends, as it always did on this link
        LOBBY.store(0, Ordering::SeqCst);
        forget_peers();
        emit(&["LEFT"]);
    } else {
        local_announce_members();
    }
}

/// Guest: the connection to the host.
fn local_connected(stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let Ok(mut reader) = stream.try_clone() else { return };
    {
        let mut streams = LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner());
        streams.clear();
        streams.push((LOCAL_HOST_ID, stream));
    }
    // say who we are (an empty frame from us)
    if !local_send(me(), &[], None, None) {
        return;
    }
    while let Some((sender, data)) = local_read(&mut reader) {
        if data.len() >= FRAME_HEADER && data[0] == KIND_MEMBERS {
            let ids: Vec<u64> = data[FRAME_HEADER..].chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect();
            if LOBBY.swap(LOCAL_LOBBY, Ordering::SeqCst) == 0 {
                emit(&["LOBBY", &LOCAL_LOBBY.to_string(), "joined", &LOCAL_HOST_ID.to_string()]);
                emit(&["LINK", &LOCAL_HOST_ID.to_string(), "local"]);
            }
            set_members(&ids, LOCAL_HOST_ID);
            continue;
        }
        dispatch(sender, &data, true);
    }
    LOCAL_STREAMS.lock().unwrap_or_else(|e| e.into_inner()).clear();
    if LOBBY.swap(0, Ordering::SeqCst) != 0 {
        forget_peers();
        emit(&["MEMBER", "left", &LOCAL_HOST_ID.to_string(), &name_of(LOCAL_HOST_ID)]);
        emit(&["LEFT"]);
    }
}

fn local_thread(m: Mode) {
    match m {
        Mode::LocalHost(port) => {
            let Ok(listener) = TcpListener::bind(("127.0.0.1", port)) else {
                return err(&format!("Dev link: cannot listen on port {}", port));
            };
            info(&format!("Dev link: hosting on 127.0.0.1:{}", port));
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || local_serve(stream));
            }
        }
        Mode::LocalGuest(port) => loop {
            if let Ok(stream) = TcpStream::connect(("127.0.0.1", port)) {
                local_connected(stream);
            }
            std::thread::sleep(Duration::from_secs(1));
        },
        Mode::Steam => {}
    }
}

// ---------------------------------------------------------------- startup

unsafe fn sym<T: Copy>(module: *mut c_void, name: &str) -> Option<T> {
    let cname = CString::new(name).ok()?;
    let p = GetProcAddress(module, cname.as_ptr());
    if p.is_null() {
        None
    } else {
        Some(std::mem::transmute_copy::<*mut c_void, T>(&p))
    }
}

/// Returns None while Steam is not initialised yet, Err on a permanent problem.
unsafe fn try_init() -> Result<Option<Steam>, String> {
    let module = GetModuleHandleA(b"steam_api64.dll\0".as_ptr() as *const c_char);
    if module.is_null() {
        return Ok(None);
    }
    macro_rules! f {
        ($name:literal) => {
            sym(module, $name).ok_or_else(|| format!("steam_api64.dll is missing {}", $name))?
        };
    }
    let steam_client: unsafe extern "C" fn() -> P = f!("SteamClient");
    let get_pipe: unsafe extern "C" fn() -> i32 = f!("SteamAPI_GetHSteamPipe");
    let get_user: unsafe extern "C" fn() -> i32 = f!("SteamAPI_GetHSteamUser");
    let client = steam_client();
    let pipe = get_pipe();
    let user = get_user();
    if client == 0 || pipe == 0 {
        return Ok(None);
    }
    type GetIface = unsafe extern "C" fn(P, i32, i32, *const c_char) -> P;
    type GetUtils = unsafe extern "C" fn(P, i32, *const c_char) -> P;
    let get_mm: GetIface = f!("SteamAPI_ISteamClient_GetISteamMatchmaking");
    let get_friends: GetIface = f!("SteamAPI_ISteamClient_GetISteamFriends");
    let get_iuser: GetIface = f!("SteamAPI_ISteamClient_GetISteamUser");
    let get_net: GetIface = f!("SteamAPI_ISteamClient_GetISteamNetworking");
    let get_utils: GetUtils = f!("SteamAPI_ISteamClient_GetISteamUtils");
    let mm = get_mm(client, user, pipe, VER_MATCHMAKING.as_ptr() as *const c_char);
    let friends = get_friends(client, user, pipe, VER_FRIENDS.as_ptr() as *const c_char);
    let iuser = get_iuser(client, user, pipe, VER_USER.as_ptr() as *const c_char);
    let net = get_net(client, user, pipe, VER_NETWORKING.as_ptr() as *const c_char);
    let utils = get_utils(client, pipe, VER_UTILS.as_ptr() as *const c_char);
    if mm == 0 || friends == 0 || iuser == 0 || utils == 0 || net == 0 {
        return Err("Steam did not provide the matchmaking/friends/networking interfaces".into());
    }
    let get_steam_id: unsafe extern "C" fn(P) -> u64 = f!("SteamAPI_ISteamUser_GetSteamID");
    let me = get_steam_id(iuser);
    if me == 0 {
        return Ok(None);
    }
    Ok(Some(Steam {
        mm,
        friends,
        utils,
        net,
        me,
        register_callback: f!("SteamAPI_RegisterCallback"),
        create_lobby: f!("SteamAPI_ISteamMatchmaking_CreateLobby"),
        join_lobby: f!("SteamAPI_ISteamMatchmaking_JoinLobby"),
        leave_lobby: f!("SteamAPI_ISteamMatchmaking_LeaveLobby"),
        send_chat: f!("SteamAPI_ISteamMatchmaking_SendLobbyChatMsg"),
        get_chat_entry: f!("SteamAPI_ISteamMatchmaking_GetLobbyChatEntry"),
        num_members: f!("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers"),
        member_by_index: f!("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex"),
        lobby_owner: f!("SteamAPI_ISteamMatchmaking_GetLobbyOwner"),
        set_lobby_data: f!("SteamAPI_ISteamMatchmaking_SetLobbyData"),
        invite_dialog: f!("SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog"),
        friend_name: f!("SteamAPI_ISteamFriends_GetFriendPersonaName"),
        my_name: f!("SteamAPI_ISteamFriends_GetPersonaName"),
        set_rich_presence: f!("SteamAPI_ISteamFriends_SetRichPresence"),
        overlay_enabled: f!("SteamAPI_ISteamUtils_IsOverlayEnabled"),
        call_completed: f!("SteamAPI_ISteamUtils_IsAPICallCompleted"),
        call_result: f!("SteamAPI_ISteamUtils_GetAPICallResult"),
        p2p_send: f!("SteamAPI_ISteamNetworking_SendP2PPacket"),
        p2p_available: f!("SteamAPI_ISteamNetworking_IsP2PPacketAvailable"),
        p2p_read: f!("SteamAPI_ISteamNetworking_ReadP2PPacket"),
        p2p_accept: f!("SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser"),
        p2p_close: f!("SteamAPI_ISteamNetworking_CloseP2PSessionWithUser"),
    }))
}

fn arg_value(prefix: &str) -> Option<String> {
    std::env::args().find_map(|a| a.strip_prefix(prefix).map(|v| v.to_string()))
}

fn lobby_from_command_line() -> u64 {
    let args: Vec<String> = std::env::args().collect();
    args.windows(2)
        .find(|w| w[0].eq_ignore_ascii_case("+connect_lobby"))
        .and_then(|w| w[1].parse().ok())
        .unwrap_or(0)
}

fn parse_target(s: &str) -> u64 {
    if s == "*" { 0 } else { s.parse().unwrap_or(u64::MAX) }
}

fn handle_command(line: &str) {
    let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
    match cmd {
        "HOST" => host(arg.trim().parse().unwrap_or(4), true),
        "HOSTQUIET" => host(arg.trim().parse().unwrap_or(4), false),
        "INVITE" => {
            if let Some(steam) = STEAM.get() {
                if mode() == Mode::Steam {
                    open_invite_dialog(steam)
                }
            }
        }
        "JOIN" => join(arg.trim().parse().unwrap_or(0)),
        "LEAVE" => leave(),
        "MSG" => {
            if let Some((target, payload)) = arg.split_once(' ') {
                let target = parse_target(target);
                if target != u64::MAX && !payload.is_empty() {
                    send_frame(KIND_MSG, target, payload.as_bytes(), true, CH_MSG);
                }
            }
        }
        "FILE" => {
            let mut parts = arg.splitn(3, ' ');
            if let (Some(target), Some(tag), Some(path)) = (parts.next(), parts.next(), parts.next()) {
                let target = parse_target(target);
                if target != u64::MAX {
                    queue_file(target, tag, path, false);
                }
            }
        }
        "LOOPBACK" => LOOPBACK.store(arg.trim() == "1", Ordering::SeqCst),
        "SELFTEST" => selftest(arg.trim()),
        "STATE" => {
            if mode() == Mode::Steam && STEAM.get().is_none() {
                info("Waiting for Steam");
            } else {
                emit_state();
            }
        }
        _ => {}
    }
}

fn worker() {
    let mut cmd_offset = 0u64;
    let mut cmd_file: Option<fs::File> = None;
    let mut pos_out_file: Option<fs::File> = None;
    let mut pos_in_file: Option<fs::File> = None;
    let mut waited = 0u32;
    let mut warned = false;
    let mut p2p_buf = vec![0u8; 64 * 1024];
    let mut last_pos_out: Vec<u8> = Vec::new();
    let mut last_pos_send = Instant::now();
    let mut last_pos_write = Instant::now();
    let mut last_chat_chunk = Instant::now();
    let m = mode();
    if m != Mode::Steam {
        let mine = me();
        emit(&["READY", &mine.to_string(), &name_of(mine)]);
        std::thread::spawn(move || local_thread(m));
    }
    loop {
        if m == Mode::Steam && STEAM.get().is_none() {
            match unsafe { try_init() } {
                Ok(Some(steam)) => {
                    register(&steam, CB_GAME_LOBBY_JOIN_REQUESTED, std::mem::size_of::<GameLobbyJoinRequested>(), on_join_requested);
                    register(&steam, CB_LOBBY_CHAT_UPDATE, std::mem::size_of::<LobbyChatUpdate>(), on_chat_update);
                    register(&steam, CB_LOBBY_CHAT_MSG, std::mem::size_of::<LobbyChatMsg>(), on_chat_msg);
                    register(&steam, CB_LOBBY_ENTER, std::mem::size_of::<LobbyEnter>(), on_lobby_enter);
                    register(&steam, CB_P2P_SESSION_REQUEST, std::mem::size_of::<P2PSessionRequest>(), on_p2p_session_request);
                    let _ = STEAM.set(steam);
                    let steam = STEAM.get().unwrap();
                    emit(&["READY", &steam.me.to_string(), &name_of(steam.me)]);
                    let lobby = lobby_from_command_line();
                    if lobby != 0 {
                        info("Launched from a Steam invite, joining lobby");
                        join(lobby);
                    }
                }
                Ok(None) => {
                    waited += 1;
                    if waited > 3000 && !warned {
                        warned = true;
                        err("Steam is not available (is the game started through Steam?)");
                    }
                }
                Err(e) => {
                    err(&e);
                    return;
                }
            }
        }
        for line in read_commands(&mut cmd_file, &mut cmd_offset) {
            handle_command(&line);
        }
        if m == Mode::Steam {
            if let Some(steam) = STEAM.get() {
                poll_pending(steam);
                if LOBBY.load(Ordering::SeqCst) != 0 {
                    pump_p2p(steam, &mut p2p_buf);
                    pump_pings();
                }
            }
        }
        if LOBBY.load(Ordering::SeqCst) != 0 {
            pump_file_queue(&mut last_chat_chunk);
            pump_positions(&mut last_pos_out, &mut last_pos_send, &mut last_pos_write, &mut pos_out_file, &mut pos_in_file);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[no_mangle]
pub unsafe extern "system" fn DllMain(module: *mut c_void, reason: u32, _reserved: *mut c_void) -> i32 {
    if reason == 1 {
        // Keep the DLL loaded for the life of the process: Steam holds pointers into it.
        let mut pinned = std::ptr::null_mut();
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            DllMain as *const u16,
            &mut pinned,
        );
        let mut buf = [0u16; 1024];
        let n = GetModuleFileNameW(module, buf.as_mut_ptr(), buf.len() as u32) as usize;
        let dll = PathBuf::from(String::from_utf16_lossy(&buf[..n]));
        // <mod>/bin/ddsmp_steam.dll -> <mod>/ipc or <mod>/ipc_NAME
        let ipc_name = match arg_value("-ddsmp=") {
            Some(name) => format!("ipc_{}", sanitize_tag(&name)),
            None => "ipc".to_string(),
        };
        let dir = dll.parent().and_then(|p| p.parent()).map(|p| p.join(ipc_name)).unwrap_or_default();
        let _ = fs::create_dir_all(&dir);
        for name in ["cmd.txt", "evt.txt", "pos_out.txt", "pos_in.txt"] {
            let _ = fs::write(dir.join(name), b"");
        }
        let _ = DIR.set(dir);
        let local = arg_value("-ddsmp_local=").and_then(|v| {
            // host:PORT, join:PORT, or join:PORT:N for the N-th guest (1 when left out)
            let (role, rest) = v.split_once(':')?;
            let (port, index) = match rest.split_once(':') {
                Some((p, i)) => (p, i.parse::<u64>().unwrap_or(1).clamp(1, 15)),
                None => (rest, 1),
            };
            LOCAL_ME.store(LOCAL_HOST_ID + index, Ordering::SeqCst);
            let port: u16 = port.parse().ok()?;
            match role {
                "host" => Some(Mode::LocalHost(port)),
                "join" => Some(Mode::LocalGuest(port)),
                _ => None,
            }
        });
        let _ = MODE.set(local.unwrap_or(Mode::Steam));
        std::thread::spawn(worker);
    }
    1
}
