//! Holding a pairing with a device and using it: what is saved here, and the commands on it.

use std::io::Write;
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::Subcommand;
use roamrun_device::safe::Device;
use serde::{Deserialize, Serialize};

use crate::Command;

#[derive(Subcommand)]
pub enum Devices {
    /// Forget a device and its pairing here (remove this machine on the device too, in its list)
    Remove { name: String },
    /// A saved device as a line for another machine, without its key: that machine asks this one to sign (`roamrunctl sign`)
    Export { name: String },
    /// Save the device of such a line: its key stays on the machine that made the line
    Add {
        line: String,
        /// The name to save it under here
        #[arg(long = "as")]
        name: Option<String>,
    },
}

#[derive(Subcommand)]
pub enum Key {
    /// Save the device and the pairing of a file `roamrun key create` wrote, under a passphrase; the file is removed
    Import {
        file: PathBuf,
        /// The name to save it under here
        #[arg(long = "as")]
        name: Option<String>,
        /// Keep it without a passphrase: a file only its owner can read, and no more
        #[arg(long)]
        plain: bool,
    },
}

/// A device as it is saved: where it is on the tailnet, and the pairing that opens it.
#[derive(Serialize, Deserialize)]
pub struct Saved {
    v: u32,
    name: String,
    ip: String,
    port: u16,
    /// The pairing itself, a property list's text: the key to the device — or, where `signer` is set,
    /// the pairing without its private key (any key stands in its place), which opens nothing by itself.
    pairing: String,
    /// The Tailscale name of the machine that keeps the private key and signs with it, and this
    /// pairing's own identifier, which it is asked by.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    signer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    identifier: Option<String>,
}

/// The looks' longer side, as on the Mac.
const LONGER: u32 = 1280;
/// Where the device's pairing port has been found: it isn't announced across a tailnet.
const PORTS: std::ops::Range<u16> = 49152..49168;

/// The user's own, as far as the system has a word for that: on Unix a mode; on Windows a folder under the
/// user's profile is the user's by what it inherits, and nothing is set here.
fn own_folder(folder: &Path) -> std::io::Result<()> {
    let mut make = std::fs::DirBuilder::new();
    make.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut make, 0o700);
    make.create(folder)
}

/// A new file, the user's own (see `own_folder`); one that is there already is an error.
pub fn own_file(path: &Path) -> std::io::Result<std::fs::File> {
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut open, 0o600);
    open.open(path)
}

/// The mode of a file that others can read, where the system has modes.
fn open_to_others(meta: &std::fs::Metadata) -> Option<u32> {
    #[cfg(unix)]
    { let mode = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()); (mode & 0o077 != 0).then_some(mode & 0o777) }
    #[cfg(not(unix))]
    { let _ = meta; None }
}

pub fn folder() -> Result<PathBuf, String> {
    let base = if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute())
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
    }.ok_or("no home folder to keep devices in")?;
    let folder = base.join("roamrunctl").join("devices");
    own_folder(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    Ok(folder)
}

/// A name that is a file's name and nothing else.
fn named(name: &str) -> Result<&str, String> {
    let fits = !name.is_empty() && name.len() <= 63 && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    fits.then_some(name).ok_or_else(|| format!("“{name}” can't be a device's name here: letters, digits, - _ . only"))
}

/// Where a device is kept: under a passphrase (.age), or as it is (.json).
fn kept(name: &str) -> Result<Option<(PathBuf, bool)>, String> {
    let folder = folder()?;
    let name = named(name)?;
    Ok([("age", true), ("json", false)].into_iter().map(|(ending, sealed)| (folder.join(format!("{name}.{ending}")), sealed)).find(|(path, _)| path.exists()))
}

fn load(name: &str) -> Result<Saved, String> {
    let (path, sealed) = kept(name)?.ok_or_else(|| format!("no device “{name}” here: `roamrunctl devices` lists them"))?;
    let meta = std::fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    // The file is a key: as ssh does, one that others can read isn't used.
    if let Some(mode) = open_to_others(&meta) {
        return Err(format!("{} can be read by others (mode {mode:o}): `chmod 600` it, or pair again", path.display()));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let bytes = if sealed { crate::secret::opened(&bytes, &crate::secret::passphrase(name, false)?).map_err(|why| format!("{name}: {why}"))? } else { bytes };
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// `passphrase`: kept under it; None: as it is.
fn save(saved: &Saved, passphrase: Option<&str>) -> Result<PathBuf, String> {
    if kept(&saved.name)?.is_some() {
        return Err(format!("a device “{}” is saved here already: `roamrunctl devices remove {}` first, or --as another name", saved.name, saved.name));
    }
    let text = serde_json::to_vec_pretty(saved).map_err(|e| e.to_string())?;
    let (bytes, ending) = match passphrase {
        Some(passphrase) => (crate::secret::sealed(&text, passphrase)?, "age"),
        None => (text, "json"),
    };
    let path = folder()?.join(format!("{}.{ending}", saved.name));
    let mut file = own_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}

/// What `roamrun key create` writes, as far as it is read here.
#[derive(Deserialize)]
struct Shared {
    #[serde(rename = "roamrunPairing")]
    version: u32,
    device: SharedDevice,
    pairing: String,
}

#[derive(Deserialize)]
struct SharedDevice {
    #[serde(rename = "displayName")]
    name: String,
    #[serde(rename = "providerIP")]
    ip: String,
    #[serde(rename = "remotePairingPort")]
    port: Option<u16>,
}

fn import(file: &Path, name: Option<String>, plain: bool) -> Result<String, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let shared: Shared = serde_json::from_str(&text).map_err(|_| format!("{} isn't a file `roamrun key create` wrote", file.display()))?;
    if shared.version != 1 || shared.pairing.is_empty() || shared.device.ip.parse::<std::net::Ipv4Addr>().is_err() {
        return Err(format!("{} isn't a file `roamrun key create` wrote", file.display()));
    }
    let name = name.unwrap_or_else(|| shared.device.name.chars().map(|c| if c.is_ascii_alphanumeric() || "-_.".contains(c) { c } else { '-' }).collect());
    let saved = Saved { v: 1, name, ip: shared.device.ip, port: shared.device.port.unwrap_or(PORTS.start), pairing: shared.pairing, signer: None, identifier: None };
    named(&saved.name)?;
    if kept(&saved.name)?.is_some() {
        return Err(format!("a device “{}” is saved here already: `roamrunctl devices remove {}` first, or --as another name", saved.name, saved.name));
    }
    // Tried before it is kept, and the file goes only once it is: a key that doesn't open the device isn't one.
    open(&saved)?;
    let passphrase = if plain { None } else { Some(crate::secret::passphrase(&saved.name, true)?) };
    let path = save(&saved, passphrase.as_deref())?;
    std::fs::remove_file(file).map_err(|e| format!("saved, but {} couldn't be removed ({e}): remove it yourself, it is a key", file.display()))?;
    Ok(match passphrase {
        Some(_) => format!("Saved {} ({}), and it connects. Its pairing is kept under the passphrase, in {}: that keeps the file from being a key on its own, not from whoever has both.", saved.name, saved.ip, path.display()),
        None => format!("Saved {} ({}), and it connects. The key is {}, as it is: whoever can read it and reach the device can see and operate it.", saved.name, saved.ip, path.display()),
    })
}

fn open(saved: &Saved) -> Result<Device, String> {
    let answers = |port: u16| format!("{}:{port}", saved.ip).parse::<SocketAddr>().is_ok_and(|at| TcpStream::connect_timeout(&at, Duration::from_millis(700)).is_ok());
    let port = Some(saved.port).filter(|p| answers(*p)).or_else(|| PORTS.clone().find(|p| answers(*p)))
        .ok_or_else(|| format!("{} ({}) doesn't answer: is it on Wi‑Fi, unlocked once since it started, and connected in Tailscale? (on cellular alone it refuses)", saved.name, saved.ip))?;
    let opened = match (&saved.signer, &saved.identifier) {
        // The key is kept on another machine: it is asked for the one signature a connection takes.
        (Some(signer), Some(identifier)) => {
            let refused = std::sync::Mutex::new(None);
            let opened = Device::open_signed(&saved.ip, port, saved.pairing.as_bytes(), |what| {
                crate::sign::ask(signer, identifier, what).map_err(|why| *refused.lock().unwrap_or_else(|e| e.into_inner()) = Some(why)).ok()
            });
            // Why it wasn't signed, in the signer's words, where that is why it didn't open.
            match refused.into_inner().unwrap_or_else(|e| e.into_inner()) {
                Some(why) => Err(format!("{signer}, which keeps its key, didn't sign: {why}")),
                None => opened,
            }
        }
        _ => Device::open(&saved.ip, port, saved.pairing.as_bytes()),
    };
    opened.map_err(|why| format!("{}: {}", saved.name, roamrun_device::safe::readable(&why)))
}

/// Whether an answer of the library's says it went well; its words otherwise.
pub fn said(answer: String) -> Result<serde_json::Value, String> {
    let value: serde_json::Value = serde_json::from_str(&answer).map_err(|_| answer.clone())?;
    if value["ok"] == true { Ok(value) } else { Err(roamrun_device::safe::readable(value["error"].as_str().unwrap_or(&answer))) }
}

/// The device's picture, its longer side LONGER at most, as `format`; and its size.
pub fn fitted(png: &[u8], format: image::ImageFormat) -> Result<(Vec<u8>, u32, u32), String> {
    let image = image::load_from_memory_with_format(png, image::ImageFormat::Png).map_err(|e| format!("the device's picture couldn't be read: {e}"))?;
    let longer = image.width().max(image.height());
    let image = if longer > LONGER { image.resize(LONGER, LONGER, image::imageops::FilterType::Triangle) } else { image };
    let mut out = std::io::Cursor::new(Vec::new());
    // No alpha in a JPEG.
    image::DynamicImage::ImageRgb8(image.to_rgb8()).write_to(&mut out, format).map_err(|e| e.to_string())?;
    Ok((out.into_inner(), image.width(), image.height()))
}

/// Whether `name` can be a device's here, and none is saved under it.
pub fn free(name: &str) -> Result<(), String> {
    named(name)?;
    if kept(name)?.is_some() {
        return Err(format!("a device “{name}” is saved here already: `roamrunctl devices remove {name}` first, or --as another name"));
    }
    Ok(())
}

/// Tries a pairing just made over the tailnet and saves it; says where it is kept and how.
pub fn keep(name: &str, ip: std::net::Ipv4Addr, port: u16, pairing: &str, passphrase: Option<&str>) -> Result<String, String> {
    let saved = Saved { v: 1, name: name.to_string(), ip: ip.to_string(), port, pairing: pairing.to_string(), signer: None, identifier: None };
    open(&saved)?;
    let path = save(&saved, passphrase)?;
    Ok(match passphrase {
        Some(_) => format!("Its pairing is kept under the passphrase, in {}.", path.display()),
        None => format!("The key is {}, as it is: whoever can read it and reach the device can see and operate it.", path.display()),
    })
}

pub const HELD_PREFIX: &str = "rr-held-v1:";

/// A saved device as a line for a machine that is to use it without its key.
fn export(name: &str) -> Result<String, String> {
    let mut saved = load(name)?;
    if saved.signer.is_some() { return Err(format!("{name}'s key isn't kept here: export it on the machine that keeps it")); }
    let (bare, identifier) = crate::sign::without_key(&saved.pairing)?;
    let me = crate::tailscale::status()?.this.dns_name.trim_end_matches('.').to_string();
    if me.is_empty() { return Err("Tailscale gives this machine no name to be asked by".into()); }
    saved.pairing = bare;
    saved.signer = Some(me);
    saved.identifier = Some(identifier);
    let json = serde_json::to_vec(&saved).map_err(|e| e.to_string())?;
    use base64::Engine;
    Ok(format!("{HELD_PREFIX}{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json)))
}

/// The device a line holds, as it would be saved: what a line may say is checked, and no key is taken from one.
pub fn held(line: &str, name: Option<String>) -> Result<Saved, String> {
    use base64::Engine;
    let not = || "that isn't a line `roamrunctl devices export` printed".to_string();
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(line.trim().strip_prefix(HELD_PREFIX).ok_or_else(not)?).map_err(|_| not())?;
    let mut saved: Saved = serde_json::from_slice(&json).map_err(|_| not())?;
    let fits = saved.v == 1 && saved.ip.parse::<std::net::Ipv4Addr>().is_ok() && !saved.pairing.is_empty()
        && saved.signer.as_deref().is_some_and(|s| !s.is_empty() && s.len() <= 253 && s.chars().all(|c| c.is_ascii_alphanumeric() || "-.".contains(c)))
        && saved.identifier.as_deref().is_some_and(crate::lines::is_uuid);
    if !fits { return Err(not()); }
    if let Some(name) = name { saved.name = name; }
    named(&saved.name)?;
    Ok(saved)
}

fn add(line: &str, name: Option<String>) -> Result<String, String> {
    let saved = held(line, name)?;
    free(&saved.name)?;
    let signer = saved.signer.clone().unwrap_or_default();
    // Tried before it is kept: which asks the machine that keeps the key, so that one has to be signing.
    open(&saved).map_err(|why| format!("{why}\nNothing was saved. On {signer}: roamrunctl sign --for <this machine>; then run this again"))?;
    // No key in it: kept as it is.
    let path = save(&saved, None)?;
    Ok(format!("Saved {} ({}), and it connects. Its key stays on {signer}, which is asked at each connection: {} holds none.", saved.name, saved.ip, path.display()))
}

/// The pairings saved here with their keys, by their identifiers: what `roamrunctl sign` signs with.
pub fn keys() -> Result<std::collections::HashMap<String, (String, ed25519_dalek::SigningKey)>, String> {
    let mut keys = std::collections::HashMap::new();
    for name in names()? {
        match load(&name) {
            Ok(saved) if saved.signer.is_none() => { if let Some((identifier, key)) = crate::sign::key(&saved.pairing) { keys.insert(identifier, (name, key)); } }
            Ok(_) => {}
            Err(why) => eprintln!("{name} is left out: {why}"),
        }
    }
    Ok(keys)
}

/// The device saved under `name`, opened.
pub fn opened(name: &str) -> Result<Device, String> {
    open(&load(name)?)
}

/// The names of the devices saved here.
pub fn names() -> Result<Vec<String>, String> {
    let mut names: Vec<String> = std::fs::read_dir(folder()?).map_err(|e| e.to_string())?
        .filter_map(|entry| { let name = entry.ok()?.file_name(); let name = name.to_str()?; name.strip_suffix(".age").or(name.strip_suffix(".json")).map(str::to_string) }).collect();
    names.sort();
    names.dedup();
    Ok(names)
}

fn look(name: &str, file: Option<PathBuf>) -> Result<String, String> {
    let device = open(&load(name)?)?;
    let (png, width, height) = fitted(&device.screenshot()?, image::ImageFormat::Png)?;
    let path = file.unwrap_or_else(|| std::env::temp_dir().join(format!("roamrunctl-{}-{}.png", named(name).unwrap_or("device"), std::process::id())));
    // Whatever is on the screen is in it: the owner's only.
    let _ = std::fs::remove_file(&path);
    let mut out = own_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    out.write_all(&png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{}\n{width} x {height}", path.display()))
}

fn list() -> Result<String, String> {
    let names = names()?;
    if names.is_empty() { return Ok("No device is saved here. `roamrunctl key import <file>` saves one from a file `roamrun key create` wrote.".into()); }
    // Named only: what else is saved of one may be under a passphrase, which a list doesn't ask for.
    Ok(names.iter().map(|name| match kept(name) {
        Ok(Some((_, true))) => format!("{name}\tunder a passphrase"),
        // Read to say which: a file without a key in it says so itself.
        _ => match load(name) {
            Ok(Saved { signer: Some(signer), .. }) => format!("{name}\tits key is kept by {signer}"),
            _ => format!("{name}\tas it is"),
        },
    }).collect::<Vec<_>>().join("\n"))
}

pub fn run(command: Command) -> i32 {
    let done = match command {
        Command::Devices { command: None } => list(),
        Command::Devices { command: Some(Devices::Remove { name }) } => named(&name).and_then(|name| {
            let (path, _) = kept(name)?.ok_or_else(|| format!("no device “{name}” here"))?;
            std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            Ok(format!("Removed {name} and its pairing here. On the device, remove this machine in its list too (Settings › Privacy & Security › Developer Mode)."))
        }),
        Command::Key { command: Key::Import { file, name, plain } } => import(&file, name, plain),
        Command::Look { name, file } => look(&name, file),
        Command::Install { name, path } => load(&name).and_then(|saved| open(&saved)).and_then(|device| {
            said(device.install(&path.to_string_lossy())).map(|_| format!("Installed {} on {name}.", path.display()))
        }),
        Command::Launch { name, bundle } => load(&name).and_then(|saved| open(&saved)).and_then(|device| {
            said(device.launch(&bundle)).map(|value| format!("Launched {bundle} on {name} (pid {}).", value["pid"]))
        }),
        Command::Mcp => return crate::mcp::Server::default().serve(),
        Command::Sign { machine } => keys().and_then(|keys| crate::sign::serve(&machine, keys)),
        Command::Devices { command: Some(Devices::Export { name }) } => export(&name),
        Command::Devices { command: Some(Devices::Add { line, name }) } => add(&line, name),
        Command::Pair { .. } => unreachable!("handled by main"),
    };
    match done {
        Ok(text) => { println!("{text}"); 0 }
        Err(why) => { eprintln!("roamrunctl: {why}"); 1 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_is_a_files_name_and_nothing_else() {
        assert!(named("iPhone-2").is_ok() && named("a.b_c").is_ok());
        for bad in ["", "../x", ".hidden", "a/b", "a b", "é"] { assert!(named(bad).is_err(), "{bad}"); }
    }

    #[test]
    fn a_picture_is_fitted_to_the_longer_side_and_a_small_one_left() {
        let png = |w, h| { let mut out = std::io::Cursor::new(Vec::new()); image::DynamicImage::new_rgb8(w, h).write_to(&mut out, image::ImageFormat::Png).unwrap(); out.into_inner() };
        let (_, w, h) = fitted(&png(1179, 2556), image::ImageFormat::Png).unwrap();
        assert_eq!((w, h), (590, 1280));
        let (_, w, h) = fitted(&png(2556, 1179), image::ImageFormat::Jpeg).unwrap();
        assert_eq!((w, h), (1280, 590));
        let (_, w, h) = fitted(&png(300, 200), image::ImageFormat::Png).unwrap();
        assert_eq!((w, h), (300, 200));
        assert!(fitted(b"not a picture", image::ImageFormat::Png).is_err());
    }

    #[test]
    fn what_the_library_says_is_ok_or_its_error() {
        assert!(said("{\"ok\":true,\"pid\":7}".into()).is_ok_and(|v| v["pid"] == 7));
        assert_eq!(said("{\"ok\":false,\"error\":\"no\"}".into()).unwrap_err(), "no");
        assert!(said("garbage".into()).is_err());
    }
}
