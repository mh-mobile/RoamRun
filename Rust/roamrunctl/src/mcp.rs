//! `roamrunctl mcp`: the device's commands as MCP tools over stdin/stdout (one JSON-RPC message a
//! line), as `roamrun mcp` gives them on a Mac. This process holds the connections: a device is
//! opened at its first call and kept. Points are pixels of the image the last look returned.
//! One call at a time, in the order asked. A call taken back (notifications/cancelled) before its turn isn't
//! made, nor one whose turn comes after the client went; one that runs already runs out. An install goes on
//! aside: it answers at once, `install_status` says how it goes, and the device does nothing else meanwhile.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use roamrun_device::safe::Device;
use serde_json::{json, Value};

use crate::device;
use crate::http::Uploads;

/// A look serves one action, within this long.
const LOOK_STANDS: Duration = Duration::from_secs(60);
/// A look, or text typed or pasted, right after an input waits this long from it for the screen to settle. Keys
/// sent at once after a tap on a field were seen lost, or put before the cursor (iOS 27.0, a Japanese keyboard).
const SETTLE: Duration = Duration::from_secs(1);
/// The most `type` takes in one call.
const LONGEST_TYPED: usize = 500;
/// The MCP versions spoken here: initialize answers the one asked for if it is one of them, else the newest.
pub const VERSIONS: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

const INSTRUCTIONS: &str = "Operates a real iPhone or iPad from this machine. Look, act, look again: each look serves one \
action, and points are pixels of the image the last look returned, given with the id it answered with. Pairing with a device and signing for one \
(`roamrunctl pair`, `roamrunctl sign`) are the user's to run, never yours. These press what is really there — don't tap what spends \
money, posts, sends, deletes or signs in unless the user asked for exactly that. A look shows whatever is on the screen \
(notifications, messages); don't pass the image on. The device shows no screen-sharing session for this; what an action itself brings up (paste's \"Allow Paste\") shows there. Type and paste give the id of the latest look too, within a minute of it (after a tap with it is fine), and are refused once something else was looked at or done since: they go to whatever has focus. Press goes to whatever is on the screen: look before it too.";

/// The device's latest look, while nothing else was done since.
struct Shown {
    /// The image's size, as the caller saw it.
    size: (f64, f64),
    /// Which way up the interface was: see `upright`.
    way: u8,
    at: Instant,
    /// The saved file of the device it was of (see `device::mark`): another saved under the name isn't it.
    of: Option<Vec<u8>>,
    /// Its id, which a tap, swipe, type or paste gives: another look since, by any caller, isn't this one.
    id: u64,
    /// A tap, swipe, type or paste went by it: no other tap or swipe does (what it saw may have moved), but text
    /// still may (look → tap a field → type).
    spent: bool,
}

/// A device's install, going on aside with the device's connection, or how the last one went.
struct Install {
    /// The app's bundle identifier (`bundle`), or the .app folder's path.
    what: String,
    bundle: bool,
    megabytes: u64,
    given: Duration,
    began: Instant,
    /// The library's answer, while it is awaited.
    going: Option<std::thread::JoinHandle<String>>,
    /// How it went, and how long it took.
    ended: Option<(Result<(), String>, Duration)>,
}

/// A point of a picture, as fractions of it, in the terms of the device held upright, where a touch is sent.
/// Whether the device was turned between a look and now.
/// ponytail: a way not said (0) is taken as no turn; the look's shape still refuses the sideways case.
pub fn turned(then: u8, now: u8) -> bool { then != 0 && now != 0 && then != now }

/// None where the picture lies on its side and which way isn't known: the mirror of a point isn't pressed.
/// Tried on an iPhone held each way on its side (iOS 27.0): a point off the picture landed where it was.
pub fn upright(way: u8, sideways: bool, (x, y): (f64, f64)) -> Option<(f64, f64)> {
    match way {
        // Turned between the picture and the asking: the two don't go together, and nothing is pressed.
        1 | 2 if sideways => None,
        3 | 4 if !sideways => None,
        1 => Some((x, y)),
        2 => Some((1.0 - x, 1.0 - y)),
        3 => Some((1.0 - y, x)),
        4 => Some((y, 1.0 - x)),
        _ => (!sideways).then_some((x, y)),
    }
}

#[derive(Default)]
pub struct Server {
    /// Each with its saved file as it was when it was opened: a name saved anew since isn't this device.
    open: HashMap<String, (Device, Option<Vec<u8>>)>,
    shown: HashMap<String, Shown>,
    acted: HashMap<String, Instant>,
    /// Over HTTP (`mcp --http`): the devices named there, each with its saved file as it was then (see
    /// `device::mark`) — the only ones listed and used, and only while that file is as it was; and no
    /// install from a path, which would name a file on this machine for whoever calls.
    offered: Option<Vec<(String, Option<Vec<u8>>)>>,
    /// Over HTTP with `--allow-install`: what is installed from, by its id.
    uploads: Option<Arc<Uploads>>,
    installs: HashMap<String, Install>,
    /// The last look's id; the first is a random one, so that a look kept from an earlier run isn't taken for one since.
    looks: u64,
}

fn text(s: impl Into<String>) -> Vec<Value> { vec![json!({ "type": "text", "text": s.into() })] }

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    let mut properties = properties;
    let mut needs: Vec<&str> = Vec::new();
    if name != "devices" {
        properties["device"] = json!({ "type": "string", "description": "The device's name here (see `devices`)" });
        needs.push("device");
    }
    needs.extend(required);
    json!({ "name": name, "description": description, "inputSchema": { "type": "object", "properties": properties, "required": needs }, "annotations": hints(name) })
}

/// What a client may take each tool to do, the same in `roamrun mcp`. `look` only reads: nothing it does on
/// the device lasts. `elements` may scroll. Destructive: whatever presses or types into what is there,
/// can't be undone from here (`lock`), ends an app, or replaces one.
fn hints(name: &str) -> Value {
    let reads = matches!(name, "devices" | "look" | "install_status");
    let destroys = matches!(name, "tap" | "swipe" | "type" | "paste" | "press" | "install" | "launch");
    json!({ "readOnlyHint": reads, "destructiveHint": destroys })
}

/// The tools: over HTTP without install unless `installs` (and then from an upload, not a path).
fn tools(remote: bool, installs: bool) -> Value {
    let point = json!({ "type": "number", "description": "Pixels of the image the last look returned" });
    let look = json!({ "type": "integer", "description": "The id the last look answered with" });
    let since = json!({ "type": "integer", "description": "The id of the device's latest look, less than a minute old, with no other look, button, launch, install or elements since (taps, swipes, types and pastes by it are fine)" });
    let all = json!([
        tool("devices", "The devices this machine can use, one a line: its name, a tab, and how it is kept (one sentence where there is none). One \"not used here yet\" is offered by another machine and believed the first time it is used: use it only if the user named it.", json!({}), &[]),
        tool("look", "The device's screen now, as an image, and the look's id. Do this before every tap or swipe: it serves one action, which gives that id.", json!({}), &[]),
        tool("tap", "Tap a point of the last look. Operates the device: whatever is there gets pressed.", json!({ "look": look, "x": point, "y": point }), &["look", "x", "y"]),
        tool("swipe", "Drag from one point of the last look to another (to scroll, or move something). Operates the device.",
             json!({ "look": look, "x1": point, "y1": point, "x2": point, "y2": point, "milliseconds": { "type": "integer", "description": "How long the drag takes (50...5000, default 300)" } }),
             &["look", "x1", "y1", "x2", "y2"]),
        tool("elements", "What accessibility says is on the screen, one caption a line (\"Home, tab, selected\"). No positions: find a caption in a look to tap it. The screen may scroll to what is visited. Nothing on the home screen.",
             json!({ "limit": { "type": "integer", "description": "How many at most (default 40)" } }), &[]),
        tool("type", "Type text on the device's keyboard, into whatever has its focus. US-keyboard characters only; a newline is Return. Right only while the device's keyboard is an English one — look first: under a Japanese one keys go to its conversion. 500 characters at most.",
             json!({ "look": since, "text": { "type": "string" } }), &["look", "text"]),
        tool("paste", "Put any text into whatever has the keyboard's focus, by the device's pasteboard (which it replaces). iOS then asks \"Allow Paste\" on the device each time: look, and tap it only if the user wants that.",
             json!({ "look": since, "text": { "type": "string" } }), &["look", "text"]),
        tool("press", "Press a hardware button. `lock` can't be undone from here: the user has to unlock.",
             json!({ "button": { "type": "string", "enum": ["home", "lock", "volume-up", "volume-down"] } }), &["button"]),
        if remote {
            tool("install", "Start installing an .ipa sent with PUT /upload, built and signed for this device: the upload's id and sha256, as the upload answered them. It answers at once; install_status says when the app is in (a megabyte takes a few seconds, a large app minutes), and until then other calls on the device answer that it is installing. An upload serves one install.",
                 json!({ "upload": { "type": "string" }, "sha256": { "type": "string" } }), &["upload", "sha256"])
        } else {
            tool("install", "Start installing an app built and signed for this device: the path, on this machine, of an .ipa or an .app folder. It answers at once; install_status says when the app is in (a megabyte takes a few seconds, a large app minutes), and until then other calls on the device answer that it is installing.",
                 json!({ "path": { "type": "string" } }), &["path"])
        },
        tool("install_status", "How the device's install goes: still going (for how long), done (with the app's bundle identifier, for launch), or why it failed.", json!({}), &[]),
        tool("launch", "Launch an app on the device by its bundle identifier (one already running is ended first).",
             json!({ "bundle": { "type": "string" } }), &["bundle"]),
    ]);
    Value::Array(all.as_array().into_iter().flatten().filter(|t| !remote || installs || !t["name"].as_str().is_some_and(|n| n.starts_with("install"))).cloned().collect())
}

/// Over HTTP, of an offered device removed, or another saved under its name, since the server began.
fn anew(name: &str) -> String {
    format!("{name} was removed here, or saved anew, since this began: it isn't used. To offer it again, end this and run it again")
}

/// A tap, swipe, type or paste by a look of another device than the one saved under the name now.
const OF_ANOTHER: &str = "the device saved under that name isn't the one that look was of: look again";

/// An upload dropped between being found and being read (unused for half an hour): where it was isn't said.
fn gone_meanwhile() -> String { "the upload was dropped meanwhile: send it again".into() }

/// The look a tap, swipe, type or paste gives: a number, or one written as text, as a model sometimes gives it.
fn look_of(arguments: &Value) -> Result<u64, String> {
    let given = &arguments["look"];
    if given.is_null() { return Err("look is missing: give the id the last look answered with".into()) }
    given.as_u64().or_else(|| given.as_str()?.trim().parse().ok())
        .ok_or_else(|| "look isn't a look's id: give the id the last look answered with, a whole number".to_string())
}

/// Whether the call `line` asks for was taken back by a message that came after it (notifications/cancelled):
/// it then isn't made, and isn't answered. One that runs already runs out.
fn taken_back<'a>(line: &str, later: impl Iterator<Item = &'a String>) -> bool {
    if !is_call(line) { return false }
    let Some(id) = serde_json::from_str::<Value>(line).ok().and_then(|call| call.get("id").cloned()).filter(|id| !id.is_null()) else { return false };
    later.filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .any(|said| said["method"] == "notifications/cancelled" && said["params"]["requestId"] == id)
}

/// Whether a message asks for a tool: the only kind that is taken back, or dropped once the client went.
fn is_call(line: &str) -> bool {
    serde_json::from_str::<Value>(line).is_ok_and(|said| said["method"] == "tools/call")
}

impl Server {
    /// For `mcp --http`: these devices only, each while it is saved as `device::mark` gave it then, and installs
    /// only from `uploads` (`--allow-install`).
    pub fn offering(offered: Vec<(String, Option<Vec<u8>>)>, uploads: Option<Arc<Uploads>>) -> Server {
        Server { offered: Some(offered), uploads, ..Server::default() }
    }

    fn next_look(&mut self) -> u64 {
        if self.looks == 0 { self.looks = crate::hold::random::<4>().map_or(1, |r| u32::from_le_bytes(r) as u64 % 1_000_000_000 + 1) }
        self.looks += 1;
        self.looks
    }

    /// Serves until stdin closes.
    pub fn serve(&mut self) -> i32 {
        let stdout = std::io::stdout();
        // Read as it comes, while a call runs: what is taken back meanwhile is known before its turn.
        // No more than these wait at once: a client that sends on regardless waits itself.
        let (tell, told) = std::sync::mpsc::sync_channel::<String>(256);
        let gone = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let went = gone.clone();
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                match line {
                    Ok(line) => if tell.send(line).is_err() { break },
                    // Not text: not a message, and not the end of them.
                    Err(e) if e.kind() == std::io::ErrorKind::InvalidData => continue,
                    Err(_) => break,
                }
            }
            went.store(true, std::sync::atomic::Ordering::SeqCst);
        });
        let mut waiting = std::collections::VecDeque::new();
        while let Some(line) = waiting.pop_front().or_else(|| told.recv().ok()) {
            // All that came meanwhile, this call's own taking back among it.
            waiting.extend(told.try_iter());
            if line.trim().is_empty() || taken_back(&line, waiting.iter()) { continue }
            // The client went: what it had asked of the device and wasn't begun, isn't.
            if gone.load(std::sync::atomic::Ordering::SeqCst) && is_call(&line) { continue }
            if let Some(answer) = self.handle(&line) {
                let mut out = stdout.lock();
                if writeln!(out, "{answer}").and_then(|()| out.flush()).is_err() { break }
            }
        }
        self.finish();
        0
    }

    /// An install that runs already runs out.
    fn finish(&mut self) {
        for install in self.installs.values_mut() { if let Some(going) = install.going.take() { let _ = going.join(); } }
    }

    /// One message in, its answer out; None for a notification.
    pub fn handle(&mut self, message: &str) -> Option<String> {
        let wrong = |id: Value, code: i32, what: &str| Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": what } }).to_string());
        let Ok(object) = serde_json::from_str::<Value>(message) else { return wrong(Value::Null, -32700, "not JSON") };
        if !object.is_object() { return wrong(Value::Null, -32600, "one request at a time, as an object") }
        let id = object.get("id")?.clone();
        let Some(method) = object["method"].as_str() else { return wrong(id, -32600, "no method") };
        let params = &object["params"];
        let result = match method {
            "initialize" => json!({
                "protocolVersion": VERSIONS.into_iter().find(|v| params["protocolVersion"] == *v).or(VERSIONS.into_iter().max()),
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "roamrunctl", "version": env!("ROAMRUN_VERSION") },
                "instructions": INSTRUCTIONS,
            }),
            "ping" => json!({}),
            "tools/list" => json!({ "tools": tools(self.offered.is_some(), self.uploads.is_some()) }),
            "tools/call" => match self.call(params["name"].as_str().unwrap_or(""), &params["arguments"]) {
                Ok(content) => json!({ "content": content, "isError": false }),
                Err(why) => json!({ "content": text(why), "isError": true }),
            },
            _ => return Some(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("no such method: {method}") } }).to_string()),
        };
        Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string())
    }

    /// Refuses a point of a look taken with the device another way up than it is now.
    fn unturned(&mut self, name: &str, way: u8, by: &Option<Vec<u8>>) -> Result<(), String> {
        let device = self.device(name, Some(by))?;
        if turned(way, match device.way() { 0 => device.way(), now => now }) { return Err("the device was turned since that look: nothing was pressed. Look again".into()) }
        Ok(())
    }

    /// The device, opened if it isn't — over HTTP only as it was offered, though another be saved under the name
    /// since (while a look waited for the screen, say): before it is opened, and by what it was opened from. `by`:
    /// for a tap, swipe, type or paste, the saved file of the look it goes by, held to as an offered one is.
    fn device(&mut self, name: &str, by: Option<&Option<Vec<u8>>>) -> Result<&Device, String> {
        // Removed since, or another saved under the name: the one that is open isn't the one named any more.
        if self.open.get(name).is_some_and(|(_, was)| device::mark(name) != *was) {
            // What was seen of the other isn't this one's screen.
            self.open.remove(name); self.shown.remove(name); self.acted.remove(name);
        }
        if !self.open.contains_key(name) {
            let offered = self.offered.as_ref().map(|offered| offered.iter().find(|(n, _)| n == name).and_then(|(_, was)| was.clone()));
            if offered.as_ref().is_some_and(|was| device::mark(name) != *was) { return Err(anew(name)) }
            // Saved anew since the look (while asked which way up it was, say): the other isn't opened for its points.
            if by.is_some_and(|by| device::mark(name) != *by) { return Err(OF_ANOTHER.into()) }
            let held = if offered.is_some() { device::held_here(name)?.ok_or_else(|| anew(name))? } else { device::held(name)? };
            if offered.as_ref().is_some_and(|was| held.1 != *was) { return Err(anew(name)) }
            if by.is_some_and(|by| held.1 != *by) { return Err(OF_ANOTHER.into()) }
            self.open.insert(name.to_string(), held);
        }
        Ok(&self.open[name].0)
    }

    /// Asks the device, once: the library sends again by itself where nothing had reached the device, and
    /// what may have reached it isn't sent twice. After a failure the next call opens it anew.
    fn ask(&mut self, name: &str, by: Option<&Option<Vec<u8>>>, call: impl Fn(&Device) -> String) -> Result<Value, String> {
        let raw = call(self.device(name, by)?);
        self.answered(name, raw)
    }

    /// What the device answered `raw`. Refused for what it says, before anything was sent: the connection is as it
    /// was. Failed otherwise, it may have reached the device and moved what the look saw: nothing more goes by that look.
    fn answered(&mut self, name: &str, raw: String) -> Result<Value, String> {
        if serde_json::from_str::<Value>(&raw).is_ok_and(|said| said["invalid"] == true) { return device::said(raw) }
        let said = device::said(raw);
        if said.is_err() { self.open.remove(name); self.shown.remove(name); }
        said.map_err(|why| format!("{why}. It may or may not have reached the device: look before doing it again"))
    }

    /// Refuses the device's look where it no longer stands: more than a minute old, or of another device than the
    /// one saved under the name now. It is let go of then.
    fn stale(&mut self, name: &str) -> Result<(), String> {
        let Some(shown) = self.shown.get(name) else { return Ok(()) };
        let why = if shown.at.elapsed() > LOOK_STANDS {
            "that look is more than a minute old: look again"
        } else if device::mark(name) != shown.of {
            OF_ANOTHER
        } else {
            return Ok(());
        };
        self.shown.remove(name);
        Err(why.into())
    }

    /// The device's look, once something goes by it: no other tap or swipe does.
    fn spend(&mut self, name: &str) {
        if let Some(shown) = self.shown.get_mut(name) { shown.spent = true }
    }

    /// An input just made on the device: the screen is given what is left of a moment to settle (see `SETTLE`).
    fn settle(&self, name: &str) {
        if let Some(wait) = self.acted.get(name).and_then(|at| SETTLE.checked_sub(at.elapsed())) { std::thread::sleep(wait); }
    }

    fn call(&mut self, tool: &str, arguments: &Value) -> Result<Vec<Value>, String> {
        if tool == "devices" {
            // Those offered are saved here: no machine that might sign is asked.
            let Some(offered) = &self.offered else { return device::listed(true).map(text) };
            // One removed, or saved anew, since it was offered isn't used: not listed either.
            let names: Vec<String> = offered.iter().filter(|(name, was)| device::mark(name) == *was).map(|(name, _)| name.clone()).collect();
            return Ok(text(if names.is_empty() { "No device offered here can be used now.".to_string() } else { device::lines(&names, &[]) }));
        }
        let name = arguments["device"].as_str().ok_or("device is missing")?.to_string();
        if let Some(offered) = &self.offered {
            let Some((_, was)) = offered.iter().find(|(offered, _)| *offered == name) else {
                return Err(format!("{name} isn't offered here: {}", offered.iter().map(|(name, _)| name.as_str()).collect::<Vec<_>>().join(", ")));
            };
            // Removed, or another saved under the name, since this began: not the device that was offered.
            if device::mark(&name) != *was { return Err(anew(&name)) }
            if tool.starts_with("install") && self.uploads.is_none() { return Err("install isn't offered here: this was started without --allow-install".into()) }
        }
        if tool == "install_status" { return self.install_status(&name).map(text) }
        // Its connection is the install's meanwhile.
        if let Some(busy) = self.installing(&name) { return Err(busy) }
        // One that is open is known, and one offered over HTTP is saved here (held to it above): asking what there is
        // would run Tailscale and ask every machine that might sign, in the device's turn.
        if self.offered.is_none() && !self.open.contains_key(&name) {
            let names = device::names()?;
            if !names.contains(&name) { return Err(format!("no such device “{name}”: `devices` lists what there is, and says where a machine that should sign isn't found")); }
        }
        let number = |key: &str| arguments[key].as_f64().ok_or(format!("{key} is missing"));
        let word = |key: &str| arguments[key].as_str().map(str::to_string).ok_or("nothing to send".to_string());
        match tool {
            "look" => {
                // A look that fails leaves none to act by: what an earlier one saw may have moved meanwhile.
                self.shown.remove(&name);
                self.settle(&name);
                self.device(&name, None)?;
                let of = self.open[&name].1.clone();
                let device = &self.open[&name].0;
                let (png, way) = match device.screenshot() {
                    // Not said the first time, it is asked once more: a point is turned by it.
                    Ok(png) => (png, match device.way() { 0 => device.way(), way => way }),
                    Err(_) => {
                        // Let go of meanwhile: once more, on a new connection.
                        self.open.remove(&name);
                        let device = self.device(&name, None)?;
                        (device.screenshot()?, device.way())
                    }
                };
                let (jpeg, width, height) = device::fitted(&png, image::ImageFormat::Jpeg)?;
                let id = self.next_look();
                self.shown.insert(name, Shown { size: (width as f64, height as f64), way, at: Instant::now(), of, id, spent: false });
                let mut content = vec![json!({ "type": "image", "data": base64::engine::general_purpose::STANDARD.encode(jpeg), "mimeType": "image/jpeg" })];
                content.extend(text(format!("{width} x {height}, look {id}. Points for tap and swipe are pixels of this image, given with look {id}. It serves one tap or swipe, and type and paste, within a minute: look again after them.")));
                Ok(content)
            }
            "tap" | "swipe" => {
                // The look is spent by what reaches the device: a call refused for what it says leaves it.
                let shown = self.shown.get(&name).filter(|shown| !shown.spent).ok_or("look first: a point is given in the pixels of the image a look returns")?;
                let (id, size, way, of) = (shown.id, shown.size, shown.way, shown.of.clone());
                // A number, or one written as text, as a model sometimes gives it.
                let given = look_of(arguments)?;
                // Looked at again since, by another caller or this one: what that look saw may not be on the screen any more.
                if given != id { return Err(format!("look again: look {given} isn't the device's latest look (it was looked at again since)")) }
                self.stale(&name)?;
                let real = |x: f64, y: f64| -> Result<(f64, f64), String> {
                    if !(0.0..size.0).contains(&x) || !(0.0..size.1).contains(&y) {
                        return Err(format!("the point must be inside the image ({} x {})", size.0, size.1));
                    }
                    upright(way, size.0 > size.1, (x / size.0, y / size.1)).ok_or_else(|| if way == 0 {
                        "the device is on its side and doesn't say which way: nothing was pressed. Ask the user to turn it upright".to_string()
                    } else {
                        "the device was turned as that look was taken: nothing was pressed. Look again".to_string()
                    })
                };
                let done = if tool == "tap" {
                    let (x, y) = real(number("x")?, number("y")?)?;
                    self.spend(&name);
                    self.unturned(&name, way, &of)?;
                    self.ask(&name, Some(&of), |d| d.tap(x, y)).map(|_| "tapped; look to see what it did")
                } else {
                    let (from, to) = (real(number("x1")?, number("y1")?)?, real(number("x2")?, number("y2")?)?);
                    let ms = match &arguments["milliseconds"] {
                        Value::Null => 300,
                        given => given.as_u64().filter(|ms| (50..=5000).contains(ms)).ok_or("milliseconds is a whole number, 50...5000")? as u32,
                    };
                    self.spend(&name);
                    self.unturned(&name, way, &of)?;
                    self.ask(&name, Some(&of), |d| d.swipe(from, to, ms)).map(|_| "swiped; look to see what it did")
                };
                self.acted.insert(name, Instant::now());
                done.map(text)
            }
            "elements" => {
                self.shown.remove(&name);   // the walk can scroll the screen
                let limit = arguments["limit"].as_u64().unwrap_or(40) as u32;
                let said = self.ask(&name, None, |d| d.elements(limit))?;
                let captions: Vec<&str> = said["elements"].as_array().map(|all| all.iter().filter_map(|e| e["caption"].as_str()).collect()).unwrap_or_default();
                let more = if said["complete"] == true { String::new() } else { format!("\n({} elements; the walk was cut short, there may be more)", captions.len()) };
                Ok(text(captions.join("\n") + &more))
            }
            "type" | "paste" | "press" => {
                let value = word(if tool == "press" { "button" } else { "text" })?;
                if tool == "type" && value.chars().count() > LONGEST_TYPED {
                    return Err(format!("too long to type here: {LONGEST_TYPED} characters at most (half a minute or more). paste takes any length"));
                }
                let by = if tool == "press" {
                    self.shown.remove(&name);
                    None
                } else {
                    // Into whatever has focus: only by the device's latest look, with nothing done since but by it —
                    // held to after the screen's moment, in which another device could be saved under the name.
                    self.settle(&name);
                    let given = look_of(arguments)?;
                    if self.shown.get(&name).is_none_or(|shown| shown.id != given) {
                        return Err(format!("look again: look {given} isn't the device's latest look, or something else was done since: nothing was {}", if tool == "type" { "typed" } else { "pasted" }));
                    }
                    self.stale(&name)?;
                    self.spend(&name);
                    Some(self.shown[&name].of.clone())
                };
                let done = self.ask(&name, by.as_ref(), |d| match tool { "type" => d.type_text(&value), "paste" => d.paste(&value), _ => d.button(&value) });
                self.acted.insert(name, Instant::now());
                done.map(|_| text(if tool == "type" && value.contains([' ', '\n']) {
                    "typed. If the device's keyboard wasn't an English one, its spaces and Returns converted or confirmed instead of being typed, and under an English one auto-correction may have changed a word it didn't know: look, and if the text isn't what you sent, use paste"
                } else { "sent; look to see what it did" }))
            }
            "install" => self.install(&name, arguments).map(text),
            "launch" => {
                let bundle = arguments["bundle"].as_str().ok_or("bundle is missing")?.to_string();
                self.shown.remove(&name);
                let done = self.ask(&name, None, |d| d.launch(&bundle));
                self.acted.insert(name, Instant::now());
                done.map(|said| text(format!("launched (pid {}); look to see it", said["pid"])))
            }
            _ => Err(format!("no such tool: {tool}")),
        }
    }

    /// Starts installing, aside with the device's connection, which is the install's until it ends (it is opened
    /// anew after): from a path here, or over HTTP from an upload, used up once the device is open. What is installed
    /// is checked before the device is asked.
    fn install(&mut self, name: &str, arguments: &Value) -> Result<String, String> {
        let upload = match &self.uploads {
            None => None,
            Some(uploads) => {
                let (id, sha256) = (arguments["upload"].as_str().ok_or("upload is missing: the id PUT /upload answered")?, arguments["sha256"].as_str().ok_or("sha256 is missing")?);
                Some((uploads.clone(), id.to_string(), sha256.to_string(), uploads.path(id, sha256)?))
            }
        };
        let path = match &upload {
            Some((.., path)) => path.to_string_lossy().into_owned(),
            None => arguments["path"].as_str().ok_or("path is missing")?.to_string(),
        };
        if !std::path::Path::new(&path).exists() { return Err(if upload.is_some() { gone_meanwhile() } else { format!("{path} isn't on this machine") }); }
        let bundle = !std::path::Path::new(&path).is_dir();
        // An upload's file is named so: where it is kept here is no caller's business.
        let what = if bundle { roamrun_device::ipa_checked(&path).map_err(|why| if upload.is_some() { why.replace(&path, "the upload") } else { why })? } else { path.clone() };
        // What a look saw may move while the app is replaced.
        self.shown.remove(name);
        // Before the upload is used up: a device that can't be used now leaves it for another try.
        self.device(name, None)?;
        let upload = upload.map(|(uploads, id, sha256, _)| uploads.claim(&id, &sha256)).transpose()?;
        let (device, _) = self.open.remove(name).ok_or("the device isn't open")?;
        let (megabytes, given) = roamrun_device::install_given(&path);
        let going = std::thread::spawn(move || { let said = device.install(&path); drop(upload); said });
        self.installs.insert(name.to_string(), Install { what: what.clone(), bundle, megabytes, given, began: Instant::now(), going: Some(going), ended: None });
        Ok(format!("installing {what} ({megabytes} MB) on {name}, for {} s at most: install_status says how it goes. Until it ends, other calls on {name} answer that it is installing.", given.as_secs()))
    }

    /// The device's install, while it goes on: what any other call on it is answered.
    fn installing(&mut self, name: &str) -> Option<String> {
        let install = self.installs.get_mut(name)?;
        if let Some(going) = install.going.take_if(|going| going.is_finished()) {
            let said = going.join().map_err(|_| "failed inside roamrunctl".to_string()).and_then(device::said);
            install.ended = Some((said.map(|_| ()), install.began.elapsed()));
        }
        install.going.as_ref().map(|_| format!("installing {} on {name} ({} s so far): nothing else is done on it until that ends. install_status says how it goes", install.what, install.began.elapsed().as_secs()))
    }

    fn install_status(&mut self, name: &str) -> Result<String, String> {
        if let Some(going) = self.installing(name) { return Ok(going) }
        let Some(Install { what, bundle, megabytes, given, ended: Some((said, took)), .. }) = self.installs.get(name) else { return Ok(format!("no install was begun on {name} since this began")) };
        let took = took.as_secs();
        match said {
            Ok(()) if *bundle => Ok(format!("{what} is installed on {name} ({megabytes} MB in {took} s): launch takes it by that bundle identifier")),
            Ok(()) => Ok(format!("{what} is installed on {name} ({megabytes} MB in {took} s)")),
            Err(why) => Err(format!("installing {what} on {name} failed after {took} s (of the {} s it was given): {why}", given.as_secs())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_point_is_turned_back_to_the_device_held_upright() {
        assert_eq!(upright(1, false, (0.25, 0.1)), Some((0.25, 0.1)));
        assert_eq!(upright(2, false, (0.25, 0.1)), Some((0.75, 0.9)));
        assert_eq!(upright(3, true, (0.25, 0.1)), Some((0.9, 0.25)));
        assert_eq!(upright(4, true, (0.25, 0.1)), Some((0.1, 0.75)));
        // Not said, and upright by its shape: taken as it is. On its side: not pressed.
        assert_eq!(upright(0, false, (0.25, 0.1)), Some((0.25, 0.1)));
        assert_eq!(upright(0, true, (0.25, 0.1)), None);
        // Said one way and shaped the other (turned in between): not pressed.
        assert!(turned(1, 3) && !turned(1, 1) && !turned(0, 3) && !turned(3, 0));
        assert_eq!((upright(1, true, (0.25, 0.1)), upright(3, false, (0.25, 0.1))), (None, None));
    }

    #[test]
    fn the_server_says_what_it_is_and_what_it_has() {
        let mut server = Server::default();
        let hello: Value = serde_json::from_str(&server.handle(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#).unwrap()).unwrap();
        assert_eq!(hello["result"]["protocolVersion"], "2025-06-18");
        assert_eq!(hello["result"]["serverInfo"]["name"], "roamrunctl");
        // A version not spoken here, or none, gets the newest that is: not an echo of what was asked.
        let mut answered = |params: &str| -> Value {
            let hello: Value = serde_json::from_str(&server.handle(&format!(r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{params}}}"#)).unwrap()).unwrap();
            hello["result"]["protocolVersion"].clone()
        };
        assert_eq!(answered(r#"{"protocolVersion":"2024-11-05"}"#), "2024-11-05");
        assert_eq!(answered(r#"{"protocolVersion":"2026-07-28"}"#), "2025-11-25");
        assert_eq!(answered("{}"), "2025-11-25");
        assert_eq!(answered(r#"{"protocolVersion":20251125}"#), "2025-11-25");
        // What can't be read is answered with JSON-RPC's error for it, as `roamrun mcp` does.
        for (message, code) in [("not json", -32700), ("[]", -32600), (r#"{"jsonrpc":"2.0","id":9}"#, -32600)] {
            let failed: Value = serde_json::from_str(&server.handle(message).unwrap()).unwrap();
            assert_eq!(failed["error"]["code"], code, "{message}");
        }
        let listed: Value = serde_json::from_str(&server.handle(r#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#).unwrap()).unwrap();
        let names: Vec<&str> = listed["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["devices", "look", "tap", "swipe", "elements", "type", "paste", "press", "install", "install_status", "launch"]);
        assert_eq!(listed["id"], "a");
        // Every tool but `devices` names its device, and says whether it only reads.
        for t in listed["result"]["tools"].as_array().unwrap() {
            assert_eq!(t["inputSchema"]["required"].as_array().unwrap().iter().any(|r| r == "device"), t["name"] != "devices");
        }
        let hinted = |hint: &str| -> Vec<&str> { listed["result"]["tools"].as_array().unwrap().iter().filter(|t| t["annotations"][hint] == true).map(|t| t["name"].as_str().unwrap()).collect() };
        assert_eq!(hinted("readOnlyHint"), ["devices", "look", "install_status"]);
        assert_eq!(hinted("destructiveHint"), ["tap", "swipe", "type", "paste", "press", "install", "launch"]);
        // A notification gets no answer; an unknown method gets an error with its id.
        assert!(server.handle(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).is_none());
        let garbled: Value = serde_json::from_str(&server.handle("not json").unwrap()).unwrap();
        assert_eq!(garbled["error"]["code"], -32700);
        // A call taken back before its turn isn't made; another's being taken back doesn't touch it.
        let (call, cancel) = (r#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#.to_string(), r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.to_string());
        assert!(taken_back(&call, [&cancel].into_iter()));
        assert!(!taken_back(&call.replace("7", "8"), [&cancel].into_iter()) && !taken_back(&call, [].into_iter()) && !taken_back(&cancel, [&cancel].into_iter()));
        // Only a tool's call: what says what the server is, is answered whatever follows.
        assert!(!taken_back(&call.replace("tools/call", "initialize"), [&cancel].into_iter()) && is_call(&call) && !is_call(&cancel));
        let batch: Value = serde_json::from_str(&server.handle(r#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#).unwrap()).unwrap();
        assert_eq!(batch["error"]["code"], -32600);
        let unknown: Value = serde_json::from_str(&server.handle(r#"{"jsonrpc":"2.0","id":7,"method":"nope"}"#).unwrap()).unwrap();
        assert_eq!((unknown["error"]["code"].as_i64(), unknown["id"].as_i64()), (Some(-32601), Some(7)));
    }

    #[test]
    fn a_point_needs_a_look_and_a_tool_its_arguments() {
        let mut server = Server::default();
        let call = |server: &mut Server, name: &str, arguments: Value| -> Value {
            let asked = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": name, "arguments": arguments } });
            serde_json::from_str::<Value>(&server.handle(&asked.to_string()).unwrap()).unwrap()["result"].clone()
        };
        // No device named, and one that isn't saved: said, as a failure of the tool.
        assert_eq!(call(&mut server, "tap", json!({ "x": 1, "y": 1 }))["isError"], true);
        let none = call(&mut server, "look", json!({ "device": "not-saved-anywhere-7f3a" }));
        assert_eq!(none["isError"], true);
        assert!(none["content"][0]["text"].as_str().unwrap().starts_with("no such device"));
        let headless: Value = serde_json::from_str(&server.handle(r#"{"id":1}"#).unwrap()).unwrap();
        assert_eq!(headless["error"]["code"], -32600);
    }

    #[test]
    fn a_point_is_pressed_only_by_a_look_of_that_device_still_good() {
        // A device saved with no address: nothing is connected to, and what gets as far as asking it fails there.
        let name = format!("mcp-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        // A tap, swipe, type or paste gives look 7 unless it says another.
        let call = |server: &mut Server, tool: &str, mut arguments: Value| -> String {
            arguments["device"] = json!(name);
            if matches!(tool, "tap" | "swipe" | "type" | "paste") && arguments["look"].is_null() { arguments["look"] = json!(7) }
            server.call(tool, &arguments).err().unwrap_or_else(|| "done".into())
        };
        let look = |server: &mut Server, size, way, at| {
            server.shown.insert(name.clone(), Shown { size, way, at, of: device::mark(&name), id: 7, spent: false });
        };
        let (upright, now) = ((100.0, 200.0), Instant::now);
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).starts_with("look first"));
        // Refused for what it says, the look stands: outside the image, a swipe too short, too much to type.
        look(&mut server, upright, 1, now());
        assert!(call(&mut server, "tap", json!({ "x": 100, "y": 1 })).contains("inside the image"));
        assert!(call(&mut server, "swipe", json!({ "x1": 1, "y1": 1, "x2": 2, "y2": 2, "milliseconds": 10 })).contains("50...5000"));
        assert!(call(&mut server, "type", json!({ "text": "a".repeat(501) })).starts_with("too long"));
        assert!(server.shown.contains_key(&name));
        // Sent, it is spent — though the device didn't answer.
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).contains("doesn't answer"));
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).starts_with("look first"));
        // A tap, swipe or text gone by it already: no tap goes by it.
        look(&mut server, upright, 1, now());
        server.shown.get_mut(&name).unwrap().spent = true;
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).starts_with("look first"));
        // And by whatever else is sent in between.
        for (tool, arguments) in [("swipe", json!({ "x1": 1, "y1": 1, "x2": 2, "y2": 2 })), ("type", json!({ "text": "a" })), ("paste", json!({ "text": "a" })), ("press", json!({ "button": "home" })), ("elements", json!({})), ("launch", json!({ "bundle": "a.b" }))] {
            look(&mut server, upright, 1, now());
            assert!(call(&mut server, tool, arguments).contains("doesn't answer"), "{tool}");
            assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).starts_with("look first"), "{tool}");
        }
        // Not the latest look (another, by whichever caller, since), or none named: not pressed, and the latest stands.
        look(&mut server, upright, 1, now());
        assert!(call(&mut server, "tap", json!({ "look": 6, "x": 1, "y": 1 })).starts_with("look again: look 6"));
        assert!(call(&mut server, "type", json!({ "look": 6, "text": "a" })).starts_with("look again: look 6"));
        assert!(server.call("tap", &json!({ "device": name, "x": 1, "y": 1 })).unwrap_err().starts_with("look is missing"));
        assert!(call(&mut server, "tap", json!({ "look": -1, "x": 1, "y": 1 })).starts_with("look isn't a look's id"));
        // Written as text, as a model sometimes gives it: taken.
        assert!(call(&mut server, "tap", json!({ "look": "7", "x": 1, "y": 1 })).contains("doesn't answer"));
        look(&mut server, upright, 1, now());
        assert!(server.shown.contains_key(&name));
        // Turned since, or a minute old: not pressed.
        look(&mut server, (200.0, 100.0), 1, now());
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).contains("was turned"));
        look(&mut server, upright, 1, now().checked_sub(LOOK_STANDS + std::time::Duration::from_secs(1)).unwrap());
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).contains("more than a minute"));
        // Another device saved under the name since the look: its look isn't this one's.
        look(&mut server, upright, 1, now());
        device::unstub(&name);
        device::stub(&name, 49153);
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).contains("isn't the one that look was of"));
        assert!(call(&mut server, "tap", json!({ "x": 1, "y": 1 })).starts_with("look first"));
        device::unstub(&name);
    }

    #[test]
    fn what_goes_by_a_look_goes_to_no_device_saved_under_the_name_after_it() {
        let name = format!("resaved-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        let of = device::mark(&name);
        server.shown.insert(name.clone(), Shown { size: (100.0, 200.0), way: 1, at: Instant::now(), of: of.clone(), id: 7, spent: false });
        // Saved anew after the look was checked (while the device was asked which way up it was, say): the other
        // isn't opened, and nothing is sent to it.
        device::unstub(&name);
        device::stub(&name, 49153);
        assert!(server.unturned(&name, 1, &of).unwrap_err().contains("isn't the one that look was of"));
        assert!(server.ask(&name, Some(&of), |d| d.tap(0.5, 0.5)).unwrap_err().contains("isn't the one that look was of"));
        // A look is held to none: it opens the device saved now (which doesn't answer, as it isn't there).
        assert!(server.call("look", &json!({ "device": name })).unwrap_err().contains("doesn't answer"));
        device::unstub(&name);
    }

    #[test]
    fn type_and_paste_go_only_by_the_latest_look_still_good_with_nothing_else_since() {
        let name = format!("typed-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        let call = |server: &mut Server, tool: &str, mut arguments: Value| -> String {
            arguments["device"] = json!(name);
            server.call(tool, &arguments).err().unwrap_or_else(|| "done".into())
        };
        // The device's latest look, taken `at`; `spent`: a tap went by it.
        let look = |server: &mut Server, id: u64, at: Instant, spent: bool| {
            server.shown.insert(name.clone(), Shown { size: (100.0, 200.0), way: 1, at, of: device::mark(&name), id, spent });
        };
        let typed = |look: u64| json!({ "look": look, "text": "a" });
        // No look yet: nothing is sent.
        assert!(call(&mut server, "type", typed(1)).starts_with("look again: look 1"));
        // The latest look, a tap gone by it: text still goes by it. (Sent: the device doesn't answer, as it isn't
        // there to open, and nothing reached it, so the look stands.)
        look(&mut server, 7, Instant::now(), true);
        assert!(call(&mut server, "type", typed(6)).starts_with("look again"));
        assert!(call(&mut server, "type", json!({ "text": "a" })).starts_with("look is missing"));
        assert!(call(&mut server, "type", typed(7)).contains("doesn't answer"));
        assert!(call(&mut server, "paste", typed(7)).contains("doesn't answer"));
        // Text gone by a look: no tap goes by it after.
        look(&mut server, 8, Instant::now(), false);
        assert!(call(&mut server, "type", typed(8)).contains("doesn't answer"));
        assert!(call(&mut server, "tap", json!({ "look": 8, "x": 1, "y": 1 })).starts_with("look first"));
        // Refused by the device for what it says, before anything was sent: the look stands. Failed otherwise, it may
        // have reached the device and moved what the look saw: nothing more goes by it.
        assert!(server.answered(&name, r#"{"ok":false,"invalid":true,"error":"no such button"}"#.into()).is_err());
        assert!(server.shown.contains_key(&name));
        assert!(server.answered(&name, r#"{"ok":false,"error":"timed out"}"#.into()).unwrap_err().contains("may or may not"));
        assert!(call(&mut server, "type", typed(8)).starts_with("look again"));
        // Another look since, by whoever; one more than a minute old; one of another device saved under the name
        // since: not sent.
        look(&mut server, 9, Instant::now(), false);
        assert!(call(&mut server, "type", typed(8)).starts_with("look again"));
        look(&mut server, 9, Instant::now().checked_sub(LOOK_STANDS + std::time::Duration::from_secs(1)).unwrap(), false);
        assert!(call(&mut server, "paste", typed(9)).contains("more than a minute"));
        look(&mut server, 9, Instant::now(), false);
        device::unstub(&name);
        device::stub(&name, 49153);
        assert!(call(&mut server, "type", typed(9)).contains("isn't the one that look was of"));
        // Something done since that gives no look (a button, an app launched, the elements walked), or a look that
        // failed: not sent.
        for (tool, arguments) in [("press", json!({ "button": "home" })), ("launch", json!({ "bundle": "a.b" })), ("elements", json!({})), ("look", json!({}))] {
            look(&mut server, 10, Instant::now(), false);
            assert_ne!(call(&mut server, tool, arguments), "done", "{tool}");
            assert!(call(&mut server, "paste", typed(10)).starts_with("look again"), "{tool}");
        }
        device::unstub(&name);
    }

    #[test]
    fn text_waits_out_a_moment_after_an_input_as_a_look_does() {
        let name = format!("settled-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        // How long `tool` takes, an input made `ago`: sent by the latest look (the device doesn't answer, as it isn't
        // there; that it doesn't is known at once).
        let sent = |server: &mut Server, tool: &str, ago: Duration| -> Duration {
            server.shown.insert(name.clone(), Shown { size: (100.0, 200.0), way: 1, at: Instant::now(), of: device::mark(&name), id: 7, spent: true });
            server.acted.insert(name.clone(), Instant::now().checked_sub(ago).unwrap());
            let began = Instant::now();
            assert!(server.call(tool, &json!({ "device": name, "look": 7, "text": "a" })).unwrap_err().contains("doesn't answer"));
            began.elapsed()
        };
        // Right after a tap on a field, say: keys sent at once were seen lost, or put before the cursor.
        for tool in ["type", "paste"] {
            assert!(sent(&mut server, tool, Duration::ZERO) >= SETTLE - Duration::from_millis(100), "{tool}");
        }
        // An input long enough ago: nothing to wait out.
        assert!(sent(&mut server, "type", SETTLE * 2) < SETTLE / 2);
        // Another device saved under the name in that moment: the text isn't sent to it.
        server.shown.insert(name.clone(), Shown { size: (100.0, 200.0), way: 1, at: Instant::now(), of: device::mark(&name), id: 7, spent: true });
        server.acted.insert(name.clone(), Instant::now());
        let anew = { let name = name.clone(); std::thread::spawn(move || { std::thread::sleep(SETTLE / 4); device::unstub(&name); device::stub(&name, 49153); }) };
        assert!(server.call("type", &json!({ "device": name, "look": 7, "text": "a" })).unwrap_err().contains("isn't the one that look was of"));
        anew.join().unwrap();
        device::unstub(&name);
    }

    fn server_devices(server: &mut Server) -> String {
        server.call("devices", &json!({})).unwrap()[0]["text"].as_str().unwrap().to_string()
    }

    #[test]
    fn over_http_only_the_devices_offered_are_used_and_only_as_they_were_saved() {
        let name = format!("offered-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::offering(vec![(name.clone(), device::mark(&name))], None);
        let call = |server: &mut Server, tool: &str| server.call(tool, &json!({ "device": name, "path": "/etc/hosts" })).err().unwrap_or_else(|| "done".into());
        assert!(call(&mut server, "look").contains("doesn't answer"));
        // No install from a path over HTTP, and none at all without --allow-install.
        assert!(call(&mut server, "install").contains("without --allow-install"));
        assert!(call(&mut server, "install_status").contains("without --allow-install"));
        // Saved anew under the name, or removed, since it was offered: not used.
        assert!(server_devices(&mut server).starts_with(&name));
        device::unstub(&name);
        device::stub(&name, 49153);
        assert!(call(&mut server, "look").contains("saved anew"));
        assert!(!server_devices(&mut server).contains(&name));
        device::unstub(&name);
        assert!(call(&mut server, "look").contains("saved anew"));
        assert_eq!(server_devices(&mut server), "No device offered here can be used now.");
        assert!(server.call("look", &json!({ "device": "another" })).unwrap_err().contains("isn't offered here"));
    }

    #[test]
    fn over_http_what_is_saved_while_a_look_waits_isnt_opened() {
        let name = format!("waited-{}", std::process::id());
        // Removed while the look waited for the screen, or another saved under the name: neither is opened.
        for again in [None, Some(49153)] {
            device::stub(&name, 49152);
            let mut server = Server::offering(vec![(name.clone(), device::mark(&name))], None);
            server.acted.insert(name.clone(), Instant::now());
            let meanwhile = { let name = name.clone(); std::thread::spawn(move || { std::thread::sleep(SETTLE / 4); device::unstub(&name); if let Some(port) = again { device::stub(&name, port) } }) };
            let said = server.call("look", &json!({ "device": name })).unwrap_err();
            assert!(said.contains("saved anew"), "{again:?}: {said}");
            meanwhile.join().unwrap();
            if again.is_some() { device::unstub(&name) }
        }
    }

    const INFO: &[u8] = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>io.example.app</string></dict></plist>";

    /// An .ipa of one app with this Info.plist, stored, as an archiver writes it.
    fn ipa(info: &[u8]) -> Vec<u8> {
        let name = b"Payload/A.app/Info.plist";
        let crc = !info.iter().fold(!0u32, |c, &b| (0..8).fold(c ^ b as u32, |c, _| if c & 1 == 1 { (c >> 1) ^ 0xedb8_8320 } else { c >> 1 }));
        let (size, name_len) = ((info.len() as u32).to_le_bytes(), (name.len() as u16).to_le_bytes());
        // Version 20, no flags, stored, no time; then its CRC and sizes, and its name's length with no extra. The
        // central directory's adds no comment, disk, attributes, and where the entry begins (0).
        let common = [&20u16.to_le_bytes()[..], &[0; 8], &crc.to_le_bytes(), &size, &size, &name_len, &[0; 2]].concat();
        let local = [&0x0403_4b50u32.to_le_bytes()[..], &common, name, info].concat();
        let central = [&0x0201_4b50u32.to_le_bytes()[..], &20u16.to_le_bytes(), &common, &[0; 10], &0u32.to_le_bytes(), name].concat();
        let end = [&0x0605_4b50u32.to_le_bytes()[..], &[0; 4], &1u16.to_le_bytes(), &1u16.to_le_bytes(), &(central.len() as u32).to_le_bytes(), &(local.len() as u32).to_le_bytes(), &[0; 2]].concat();
        [local, central, end].concat()
    }

    /// Waits, a few seconds at most, for the device's install to end; how it went, as install_status says.
    fn ended(server: &mut Server, name: &str) -> Result<String, String> {
        let began = Instant::now();
        while server.installing(name).is_some() && began.elapsed() < Duration::from_secs(10) { std::thread::sleep(Duration::from_millis(20)) }
        server.install_status(name)
    }

    #[test]
    fn an_install_goes_on_aside_and_the_device_does_nothing_else_meanwhile() {
        let name = format!("installing-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        // An install going on until told to end (one on a real device takes a while), answered `said`.
        let going = |server: &mut Server, said: &'static str| -> std::sync::mpsc::Sender<()> {
            let (end, ends) = std::sync::mpsc::channel::<()>();
            let going = std::thread::spawn(move || { let _ = ends.recv(); if said.is_empty() { panic!("inside") } said.to_string() });
            server.installs.insert(name.clone(), Install { what: "io.example.app".into(), bundle: true, megabytes: 3, given: Duration::from_secs(345), began: Instant::now(), going: Some(going), ended: None });
            end
        };
        let end = going(&mut server, r#"{"ok":true}"#);
        for (tool, arguments) in [("look", json!({})), ("tap", json!({ "look": 7, "x": 1, "y": 1 })), ("type", json!({ "look": 7, "text": "a" })), ("press", json!({ "button": "home" })), ("elements", json!({})), ("launch", json!({ "bundle": "a.b" })), ("install", json!({ "path": env!("CARGO_MANIFEST_DIR") }))] {
            let mut arguments = arguments;
            arguments["device"] = json!(name);
            let said = server.call(tool, &arguments).unwrap_err();
            assert!(said.starts_with("installing io.example.app on") && said.contains("nothing else is done"), "{tool}: {said}");
        }
        assert!(server.install_status(&name).unwrap().contains("s so far"));
        end.send(()).unwrap();
        assert!(ended(&mut server, &name).unwrap().starts_with("io.example.app is installed on"));
        // Ended, the device is used again (opened anew: it doesn't answer, as it isn't there).
        assert!(server.call("look", &json!({ "device": name })).unwrap_err().contains("doesn't answer"));
        // A failure, and one inside, are said.
        let end = going(&mut server, r#"{"ok":false,"error":"timed out"}"#);
        end.send(()).unwrap();
        let failed = ended(&mut server, &name).unwrap_err();
        assert!(failed.contains("failed after") && failed.contains("timed out"), "{failed}");
        let end = going(&mut server, "");
        end.send(()).unwrap();
        assert!(ended(&mut server, &name).unwrap_err().contains("failed inside roamrunctl"));
        // At the end of stdio, one that runs runs out.
        let end = going(&mut server, r#"{"ok":true}"#);
        std::thread::spawn(move || { std::thread::sleep(Duration::from_millis(200)); let _ = end.send(()); });
        server.finish();
        assert!(server.installs[&name].going.is_none());
        device::unstub(&name);
    }

    #[test]
    fn an_install_answers_once_begun_with_the_connection_its_own() {
        let name = format!("begun-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::default();
        let app = std::env::temp_dir().join(format!("rr-begun-{}.app", std::process::id()));
        std::fs::create_dir_all(&app).unwrap();
        std::fs::write(app.join("Info.plist"), b"<plist/>").unwrap();
        // Refused before anything is begun: no such file, an .ipa that isn't an app's.
        assert!(server.call("install", &json!({ "device": name, "path": "/nowhere/at/all.ipa" })).unwrap_err().contains("isn't on this machine"));
        let not_ipa = app.join("Info.plist");
        let said = server.call("install", &json!({ "device": name, "path": not_ipa }));
        assert!(said.as_ref().unwrap_err().contains("isn't an app's .ipa"), "{said:?}");
        assert!(server.install_status(&name).unwrap().starts_with("no install was begun"));
        // A device that can't be opened: nothing is begun, but the look is ended as it is tried.
        server.shown.insert(name.clone(), Shown { size: (100.0, 200.0), way: 1, at: Instant::now(), of: device::mark(&name), id: 7, spent: false });
        assert!(server.call("install", &json!({ "device": name, "path": app })).unwrap_err().contains("doesn't answer"));
        assert!(!server.shown.contains_key(&name));
        assert!(server.install_status(&name).unwrap().starts_with("no install was begun"));
        std::fs::remove_dir_all(app).unwrap();
        device::unstub(&name);
    }

    #[test]
    fn over_http_an_install_is_offered_with_allow_install_and_takes_an_upload() {
        let listed = |server: &mut Server| -> Vec<Value> {
            let said: Value = serde_json::from_str(&server.handle(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).unwrap()).unwrap();
            said["result"]["tools"].as_array().unwrap().iter().filter(|t| t["name"].as_str().unwrap().starts_with("install")).cloned().collect()
        };
        assert!(listed(&mut Server::offering(vec![], None)).is_empty());
        let uploads = Uploads::new(1 << 20).unwrap();
        let tools = listed(&mut Server::offering(vec![], Some(uploads.clone())));
        assert_eq!(tools.iter().map(|t| t["name"].as_str().unwrap()).collect::<Vec<_>>(), ["install", "install_status"]);
        assert_eq!(tools[0]["inputSchema"]["required"], json!(["device", "upload", "sha256"]));
        let name = format!("uploaded-{}", std::process::id());
        device::stub(&name, 49152);
        let mut server = Server::offering(vec![(name.clone(), device::mark(&name))], Some(uploads.clone()));
        // A path isn't taken; an upload not kept isn't either.
        assert!(server.call("install", &json!({ "device": name, "path": "/etc/hosts" })).unwrap_err().contains("upload is missing"));
        assert!(server.call("install", &json!({ "device": name, "upload": "0", "sha256": "0" })).unwrap_err().contains("no upload 0"));
        // One that isn't an app's .ipa is refused by what it is called, not by where it is kept here.
        let (id, sha256) = uploads.put("n1", b"not an ipa");
        let said = server.call("install", &json!({ "device": name, "upload": id, "sha256": sha256 })).unwrap_err();
        assert!(said.starts_with("the upload isn't an app's .ipa") && !said.contains(&*uploads.path(&id, &sha256).unwrap().to_string_lossy()), "{said}");
        // Its file gone between being found and being read: where it was isn't said either.
        let (id, sha256) = uploads.put("n1", &ipa(INFO));
        let kept = uploads.path(&id, &sha256).unwrap();
        std::fs::remove_file(&kept).unwrap();
        let said = server.call("install", &json!({ "device": name, "upload": id, "sha256": sha256 })).unwrap_err();
        assert!(said.contains("dropped meanwhile") && !said.contains(&*kept.to_string_lossy()), "{said}");
        let (id, sha256) = uploads.put("n1", &ipa(INFO));
        // A device that can't be used now leaves the upload for another try.
        let said = server.call("install", &json!({ "device": name, "upload": id, "sha256": sha256 }));
        assert!(said.as_ref().unwrap_err().contains("doesn't answer"), "{said:?}");
        device::unstub(&name);
        device::stub(&name, 49153);
        assert!(server.call("install", &json!({ "device": name, "upload": id, "sha256": sha256 })).unwrap_err().contains("saved anew"));
        assert!(uploads.check(&id, "n1", &sha256).is_ok());
        device::unstub(&name);
        uploads.end();
    }
}
