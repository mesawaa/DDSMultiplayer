//! Music files from the player's own folder (the mod's `Music` folder: mp3 and wav). The
//! game cannot load a sound file at run time, so the files are decoded here (symphonia)
//! and mixed into one stream of the Windows wave output (winmm, on every PC). The Lua side
//! places each sound itself: it tells each playing slot its loudness for the left and the
//! right ear as the player moves about.
//!
//! Commands (music_cmd.txt, see lib.rs):
//!   MPLAY <slot> <ms> <path>     play the file from `ms` milliseconds on (slot: a short name)
//!   MVOL <slot> <left> <right>   loudness 0..1 for each ear (silent until the first one)
//!   MSTOP <slot> | MSTOPALL
//!   MSCAN <dir>                  -> MFILE name size, ..., MSCANEND count; the files of the
//!                                folder and of its folders one level down ("Stink/a.mp3")
//!   MLEN <path>                  -> MLEN path ms   (0: the file cannot be played)
//!   MOPEN <dir>                  opens the folder in Explorer
//!   MMOVE <size>|<from>|<to>     moves a file of that size (the Lua side cannot name files
//!                                outside the ANSI code page) -> MMOVED to | MMOVEFAIL to
//! Events: MEND slot (the file has played to its end), MERR slot text.
//! While the game's window is not in front everything is silent (the game's own sound is
//! too).

use std::collections::HashMap;
use std::ffi::c_void;
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;

#[repr(C)]
struct WaveFormatEx {
    format_tag: u16,
    channels: u16,
    samples_per_sec: u32,
    avg_bytes_per_sec: u32,
    block_align: u16,
    bits_per_sample: u16,
    cb_size: u16,
}

#[repr(C)]
struct WaveHdr {
    data: *mut u8,
    buffer_length: u32,
    bytes_recorded: u32,
    user: usize,
    flags: u32,
    loops: u32,
    next: *mut WaveHdr,
    reserved: usize,
}

#[link(name = "winmm")]
extern "system" {
    fn waveOutOpen(out: *mut *mut c_void, device: u32, fmt: *const WaveFormatEx, cb: usize, inst: usize, flags: u32) -> u32;
    fn waveOutPrepareHeader(h: *mut c_void, hdr: *mut WaveHdr, size: u32) -> u32;
    fn waveOutUnprepareHeader(h: *mut c_void, hdr: *mut WaveHdr, size: u32) -> u32;
    fn waveOutWrite(h: *mut c_void, hdr: *mut WaveHdr, size: u32) -> u32;
    fn waveOutReset(h: *mut c_void) -> u32;
    fn waveOutClose(h: *mut c_void) -> u32;
}

#[link(name = "user32")]
extern "system" {
    fn GetForegroundWindow() -> *mut c_void;
    fn GetWindowThreadProcessId(hwnd: *mut c_void, pid: *mut u32) -> u32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcessId() -> u32;
}

#[link(name = "shell32")]
extern "system" {
    fn ShellExecuteW(hwnd: *mut c_void, op: *const u16, file: *const u16, params: *const u16, dir: *const u16, show: i32) -> isize;
}

const RATE: u32 = 44_100;
const FRAMES: usize = 2048; // per buffer (46 ms)
const BUFFERS: usize = 4;
const WAVE_MAPPER: u32 = 0xFFFF_FFFF;
const WHDR_DONE: u32 = 1;

enum Msg {
    Line(String),
    Ready(String, u32, Box<Voice>),
}

static TX: OnceLock<Mutex<Sender<Msg>>> = OnceLock::new();

fn send(m: Msg) {
    if let Some(tx) = TX.get() {
        let _ = tx.lock().unwrap_or_else(|e| e.into_inner()).send(m);
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn slot_name(s: &str) -> String {
    let t: String = s.chars().filter(|c| c.is_ascii_alphanumeric()).take(24).collect();
    if t.is_empty() { "x".into() } else { t }
}

fn playable(name: &str) -> bool {
    let l = name.to_ascii_lowercase();
    l.ends_with(".mp3") || l.ends_with(".wav")
}

// ---------------------------------------------------------------- decoding

fn open(path: &str) -> Result<(Box<dyn FormatReader>, u32), String> {
    let file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| e.to_string())?;
    let format = probed.format;
    let track = format.tracks().iter().find(|t| t.codec_params.codec != CODEC_TYPE_NULL).ok_or("no sound in the file")?;
    let id = track.id;
    Ok((format, id))
}

/// The file's length in milliseconds (0 when it cannot be read).
fn length_ms(path: &str) -> u64 {
    let Ok((mut format, id)) = open(path) else { return 0 };
    let params = format.tracks().iter().find(|t| t.id == id).map(|t| t.codec_params.clone());
    let Some(params) = params else { return 0 };
    let rate = params.sample_rate.unwrap_or(44_100) as u64;
    if let Some(n) = params.n_frames {
        if n > 0 {
            return n * 1000 / rate.max(1);
        }
    }
    // (no frame count in the file: the packets' own lengths, read without decoding)
    let mut frames = 0u64;
    loop {
        match format.next_packet() {
            Ok(p) => {
                if p.track_id() == id {
                    frames += p.dur;
                }
            }
            Err(_) => break,
        }
    }
    frames * 1000 / rate.max(1)
}

pub struct Voice {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track: u32,
    rate: f64,
    buf: Vec<f32>, // stereo, interleaved
    pos: f64,      // in frames of `buf`
    done: bool,
    left: f32,
    right: f32,
    cur_left: f32,
    cur_right: f32,
}

impl Voice {
    fn load(path: &str, ms: u64) -> Result<Voice, String> {
        let (mut format, track) = open(path)?;
        let params = format.tracks().iter().find(|t| t.id == track).map(|t| t.codec_params.clone()).ok_or("no track")?;
        let decoder = symphonia::default::get_codecs().make(&params, &DecoderOptions::default()).map_err(|e| e.to_string())?;
        let rate = params.sample_rate.unwrap_or(44_100) as f64;
        if ms > 0 {
            let time = Time::new(ms / 1000, (ms % 1000) as f64 / 1000.0);
            format.seek(SeekMode::Accurate, SeekTo::Time { time, track_id: Some(track) }).map_err(|e| e.to_string())?;
        }
        Ok(Voice { format, decoder, track, rate, buf: Vec::new(), pos: 0.0, done: false, left: 0.0, right: 0.0, cur_left: 0.0, cur_right: 0.0 })
    }

    /// Decodes the next packet onto the end of `buf`. False at the end of the file.
    fn decode_more(&mut self) -> bool {
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymError::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(_) => return false,
            };
            if packet.track_id() != self.track {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(decoded) => {
                    let spec = *decoded.spec();
                    let ch = spec.channels.count().max(1);
                    let mut sb = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                    sb.copy_interleaved_ref(decoded);
                    for f in sb.samples().chunks(ch) {
                        let l = f[0];
                        let r = if ch > 1 { f[1] } else { l };
                        self.buf.push(l);
                        self.buf.push(r);
                    }
                    return true;
                }
                Err(SymError::DecodeError(_)) => continue,
                Err(_) => return false,
            }
        }
    }

    /// Adds `out.len() / 2` frames of this voice to `out`. False once it has ended.
    fn mix(&mut self, out: &mut [f32], focused: bool) -> bool {
        let frames = out.len() / 2;
        let step = self.rate / RATE as f64;
        let (tl, tr) = if focused { (self.left, self.right) } else { (0.0, 0.0) };
        let (sl, sr) = (self.cur_left, self.cur_right);
        for i in 0..frames {
            let need = self.pos as usize + 2;
            while !self.done && self.buf.len() / 2 < need {
                if !self.decode_more() {
                    self.done = true;
                }
            }
            let n = self.buf.len() / 2;
            let at = self.pos as usize;
            if at + 1 >= n && self.done {
                self.cur_left = tl;
                self.cur_right = tr;
                return false;
            }
            let frac = (self.pos - at as f64) as f32;
            let (l0, r0) = (self.buf[at * 2], self.buf[at * 2 + 1]);
            let (l1, r1) = if at + 1 < n { (self.buf[at * 2 + 2], self.buf[at * 2 + 3]) } else { (l0, r0) };
            // (the loudness glides over the buffer: no clicks when it changes)
            let t = i as f32 / frames as f32;
            let gl = sl + (tl - sl) * t;
            let gr = sr + (tr - sr) * t;
            out[i * 2] += (l0 + (l1 - l0) * frac) * gl;
            out[i * 2 + 1] += (r0 + (r1 - r0) * frac) * gr;
            self.pos += step;
        }
        self.cur_left = tl;
        self.cur_right = tr;
        // (what has been played is dropped from the front now and then)
        let used = self.pos as usize;
        if used > 16_384 {
            self.buf.drain(..used * 2);
            self.pos -= used as f64;
        }
        true
    }
}

// ---------------------------------------------------------------- output

struct Output {
    handle: *mut c_void,
    headers: Vec<Box<WaveHdr>>,
    data: Vec<Vec<i16>>,
}

impl Output {
    fn open() -> Option<Output> {
        let fmt = WaveFormatEx {
            format_tag: 1,
            channels: 2,
            samples_per_sec: RATE,
            avg_bytes_per_sec: RATE * 4,
            block_align: 4,
            bits_per_sample: 16,
            cb_size: 0,
        };
        let mut handle = std::ptr::null_mut();
        if unsafe { waveOutOpen(&mut handle, WAVE_MAPPER, &fmt, 0, 0, 0) } != 0 {
            return None;
        }
        let mut out = Output { handle, headers: Vec::new(), data: Vec::new() };
        for _ in 0..BUFFERS {
            let mut data = vec![0i16; FRAMES * 2];
            let mut hdr = Box::new(WaveHdr {
                data: data.as_mut_ptr() as *mut u8,
                buffer_length: (FRAMES * 4) as u32,
                bytes_recorded: 0,
                user: 0,
                flags: 0,
                loops: 0,
                next: std::ptr::null_mut(),
                reserved: 0,
            });
            unsafe { waveOutPrepareHeader(handle, &mut *hdr, std::mem::size_of::<WaveHdr>() as u32) };
            // (a fresh buffer counts as played: it is filled at once)
            hdr.flags |= WHDR_DONE;
            out.headers.push(hdr);
            out.data.push(data);
        }
        Some(out)
    }

    fn close(&mut self) {
        unsafe {
            waveOutReset(self.handle);
            for h in self.headers.iter_mut() {
                waveOutUnprepareHeader(self.handle, &mut **h, std::mem::size_of::<WaveHdr>() as u32);
            }
            waveOutClose(self.handle);
        }
    }
}

// ---------------------------------------------------------------- the player

struct Player {
    voices: HashMap<String, Box<Voice>>,
    // the newest MPLAY of each slot: a file still loading for an older one is dropped
    gens: HashMap<String, u32>,
    // loudness told before the file was ready
    early: HashMap<String, (f32, f32)>,
    seq: u32,
    out: Option<Output>,
    idle_since: Instant,
    focused: bool,
    mix: Vec<f32>,
}

impl Player {
    fn command(&mut self, line: &str) {
        let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
        match cmd {
            "MPLAY" => {
                let mut p = arg.splitn(3, ' ');
                if let (Some(slot), Some(ms), Some(path)) = (p.next(), p.next(), p.next()) {
                    let slot = slot_name(slot);
                    self.voices.remove(&slot);
                    self.early.remove(&slot);
                    self.seq += 1;
                    let gen = self.seq;
                    self.gens.insert(slot.clone(), gen);
                    let ms: u64 = ms.parse().unwrap_or(0);
                    let path = path.trim().to_string();
                    std::thread::spawn(move || {
                        let loaded = catch_unwind(AssertUnwindSafe(|| Voice::load(&path, ms)));
                        match loaded {
                            Ok(Ok(v)) => send(Msg::Ready(slot, gen, Box::new(v))),
                            Ok(Err(e)) => crate::emit(&["MERR", &slot, &e]),
                            Err(_) => crate::emit(&["MERR", &slot, "the file could not be read"]),
                        }
                    });
                }
            }
            "MVOL" => {
                let mut p = arg.split(' ');
                if let (Some(slot), Some(l), Some(r)) = (p.next(), p.next(), p.next()) {
                    let slot = slot_name(slot);
                    let (l, r) = (l.parse::<f32>().unwrap_or(0.0).clamp(0.0, 1.0), r.parse::<f32>().unwrap_or(0.0).clamp(0.0, 1.0));
                    if let Some(v) = self.voices.get_mut(&slot) {
                        v.left = l;
                        v.right = r;
                    } else {
                        self.early.insert(slot, (l, r));
                    }
                }
            }
            "MSTOP" => {
                let slot = slot_name(arg.trim());
                self.voices.remove(&slot);
                self.gens.remove(&slot);
                self.early.remove(&slot);
            }
            "MSTOPALL" => {
                self.voices.clear();
                self.gens.clear();
                self.early.clear();
            }
            // MTEST <ms> <path>: two seconds from `ms` on decoded into memory (nothing is
            // heard) -> MTEST path rms
            "MTEST" => {
                let mut p = arg.splitn(2, ' ');
                if let (Some(ms), Some(path)) = (p.next(), p.next()) {
                    let ms: u64 = ms.parse().unwrap_or(0);
                    let path = path.trim().to_string();
                    std::thread::spawn(move || {
                        let rms = catch_unwind(AssertUnwindSafe(|| {
                            let mut v = Voice::load(&path, ms).ok()?;
                            v.left = 1.0;
                            v.right = 1.0;
                            v.cur_left = 1.0;
                            v.cur_right = 1.0;
                            let mut out = vec![0f32; RATE as usize * 4];
                            v.mix(&mut out, true);
                            Some((out.iter().map(|s| s * s).sum::<f32>() / out.len() as f32).sqrt())
                        }))
                        .ok()
                        .flatten();
                        crate::emit(&["MTEST", &path, &rms.map(|r| format!("{:.4}", r)).unwrap_or_else(|| "-1".into())]);
                    });
                }
            }
            "MSCAN" => {
                let dir = arg.trim();
                let _ = fs::create_dir_all(dir);
                let mut names: Vec<(String, u64)> = Vec::new();
                if let Ok(entries) = fs::read_dir(dir) {
                    for e in entries.flatten() {
                        let name = e.file_name().to_string_lossy().into_owned();
                        let Ok(meta) = e.metadata() else { continue };
                        if meta.is_file() && playable(&name) {
                            names.push((name, meta.len()));
                        } else if meta.is_dir() && !name.starts_with('_') {
                            if let Ok(inner) = fs::read_dir(e.path()) {
                                for f in inner.flatten() {
                                    let file = f.file_name().to_string_lossy().into_owned();
                                    let Ok(m) = f.metadata() else { continue };
                                    if m.is_file() && playable(&file) {
                                        names.push((format!("{}/{}", name, file), m.len()));
                                    }
                                }
                            }
                        }
                    }
                }
                names.sort_by(|a, b| a.0.to_lowercase().cmp(&b.0.to_lowercase()));
                let count = names.len();
                for (name, size) in names {
                    crate::emit(&["MFILE", &name, &size.to_string()]);
                }
                crate::emit(&["MSCANEND", &count.to_string()]);
            }
            "MLEN" => {
                let path = arg.trim().to_string();
                std::thread::spawn(move || {
                    let ms = catch_unwind(AssertUnwindSafe(|| if Path::new(&path).is_file() { length_ms(&path) } else { 0 })).unwrap_or(0);
                    crate::emit(&["MLEN", &path, &ms.to_string()]);
                });
            }
            "MMOVE" => {
                let mut p = arg.trim().splitn(3, '|');
                if let (Some(size), Some(from), Some(to)) = (p.next(), p.next(), p.next()) {
                    let size: u64 = size.parse().unwrap_or(0);
                    let ok = fs::metadata(from).map(|m| m.len() == size).unwrap_or(false) && {
                        if let Some(parent) = Path::new(to).parent() {
                            let _ = fs::create_dir_all(parent);
                        }
                        let _ = fs::remove_file(to);
                        fs::rename(from, to).is_ok() || (fs::copy(from, to).is_ok() && fs::remove_file(from).is_ok())
                    };
                    if !ok {
                        let _ = fs::remove_file(from);
                    }
                    crate::emit(&[if ok { "MMOVED" } else { "MMOVEFAIL" }, to]);
                }
            }
            "MOPEN" => {
                let dir = arg.trim();
                let _ = fs::create_dir_all(dir);
                let (op, file) = (wide("open"), wide(dir));
                unsafe { ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), 1) };
            }
            _ => {}
        }
    }

    fn ready(&mut self, slot: String, gen: u32, mut v: Box<Voice>) {
        if self.gens.get(&slot) != Some(&gen) {
            return; // stopped or replaced while it was loading
        }
        if let Some((l, r)) = self.early.remove(&slot) {
            v.left = l;
            v.right = r;
            v.cur_left = l;
            v.cur_right = r;
        }
        self.voices.insert(slot, v);
    }

    /// Fills every buffer the device has played.
    fn pump(&mut self) {
        if self.voices.is_empty() {
            if self.out.is_some() && self.idle_since.elapsed() > Duration::from_secs(10) {
                if let Some(mut o) = self.out.take() {
                    o.close();
                }
            }
            if self.out.is_none() {
                return;
            }
        } else {
            self.idle_since = Instant::now();
            if self.out.is_none() {
                self.out = Output::open();
                if self.out.is_none() {
                    for slot in self.voices.keys() {
                        crate::emit(&["MERR", slot, "no sound output"]);
                    }
                    self.voices.clear();
                    return;
                }
            }
        }
        let Some(out) = self.out.as_mut() else { return };
        for i in 0..out.headers.len() {
            if out.headers[i].flags & WHDR_DONE == 0 {
                continue;
            }
            self.mix.clear();
            self.mix.resize(FRAMES * 2, 0.0);
            let mut ended = Vec::new();
            for (slot, v) in self.voices.iter_mut() {
                let alive = catch_unwind(AssertUnwindSafe(|| v.mix(&mut self.mix, self.focused))).unwrap_or(false);
                if !alive {
                    ended.push(slot.clone());
                }
            }
            for slot in ended {
                self.voices.remove(&slot);
                self.gens.remove(&slot);
                crate::emit(&["MEND", &slot]);
            }
            let data = &mut out.data[i];
            for (d, s) in data.iter_mut().zip(self.mix.iter()) {
                *d = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
            }
            let hdr = &mut out.headers[i];
            hdr.flags &= !WHDR_DONE;
            unsafe { waveOutWrite(out.handle, &mut **hdr, std::mem::size_of::<WaveHdr>() as u32) };
        }
    }

    fn check_focus(&mut self) {
        self.focused = unsafe {
            let w = GetForegroundWindow();
            let mut pid = 0u32;
            if !w.is_null() {
                GetWindowThreadProcessId(w, &mut pid);
            }
            pid == GetCurrentProcessId()
        };
    }
}

fn run(rx: Receiver<Msg>) {
    let mut p = Player {
        voices: HashMap::new(),
        gens: HashMap::new(),
        early: HashMap::new(),
        seq: 0,
        out: None,
        idle_since: Instant::now(),
        focused: true,
        mix: Vec::with_capacity(FRAMES * 2),
    };
    let mut last_focus = Instant::now();
    loop {
        loop {
            match rx.try_recv() {
                Ok(Msg::Line(line)) => p.command(&line),
                Ok(Msg::Ready(slot, gen, v)) => p.ready(slot, gen, v),
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(_) => return,
            }
        }
        if last_focus.elapsed() >= Duration::from_millis(250) {
            last_focus = Instant::now();
            p.check_focus();
        }
        p.pump();
        std::thread::sleep(Duration::from_millis(if p.voices.is_empty() { 30 } else { 8 }));
    }
}

/// True for the commands of this module (they are handed to its thread).
pub fn command(line: &str) -> bool {
    let cmd = line.split(' ').next().unwrap_or("");
    if !matches!(cmd, "MPLAY" | "MVOL" | "MSTOP" | "MSTOPALL" | "MSCAN" | "MLEN" | "MOPEN" | "MTEST" | "MMOVE") {
        return false;
    }
    TX.get_or_init(|| {
        let (tx, rx) = channel::<Msg>();
        std::thread::spawn(move || run(rx));
        Mutex::new(tx)
    });
    send(Msg::Line(line.to_string()));
    true
}

/// (tests) The output's loudness for the same two seconds mixed at each of `gains`.
pub fn gain_check(path: &str, ms: u64, gains: &[f32]) -> Vec<f32> {
    let mut out = Vec::new();
    for &g in gains {
        let Ok(mut v) = Voice::load(path, ms) else { return out };
        v.left = g;
        v.right = g;
        v.cur_left = g;
        v.cur_right = g;
        let mut buf = vec![0f32; RATE as usize * 4];
        v.mix(&mut buf, true);
        out.push((buf.iter().map(|s| s * s).sum::<f32>() / buf.len() as f32).sqrt());
    }
    out
}
