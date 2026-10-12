//! Holding a pairing with a device and using it: what is saved here, and the commands on it.
//! Not built for Windows.

use std::io::Write;
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
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
}

#[derive(Subcommand)]
pub enum Key {
    /// Save the device and the pairing of a file `roamrun key create` wrote; the file is removed
    Import {
        file: PathBuf,
        /// The name to save it under here
        #[arg(long = "as")]
        name: Option<String>,
    },
}

/// A device as it is saved: where it is on the tailnet, and the pairing that opens it.
#[derive(Serialize, Deserialize)]
struct Saved {
    v: u32,
    name: String,
    ip: String,
    port: u16,
    /// The pairing itself, a property list's text: the key to the device.
    pairing: String,
}

/// The looks' longer side, as on the Mac.
const LONGER: u32 = 1280;
/// Where the device's pairing port has been found: it isn't announced across a tailnet.
const PORTS: std::ops::Range<u16> = 49152..49168;

fn folder() -> Result<PathBuf, String> {
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .ok_or("no home folder to keep devices in")?;
    let folder = base.join("roamrunctl").join("devices");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    Ok(folder)
}

/// A name that is a file's name and nothing else.
fn named(name: &str) -> Result<&str, String> {
    let fits = !name.is_empty() && name.len() <= 63 && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    fits.then_some(name).ok_or_else(|| format!("“{name}” can't be a device's name here: letters, digits, - _ . only"))
}

fn load(name: &str) -> Result<Saved, String> {
    let path = folder()?.join(format!("{}.json", named(name)?));
    let meta = std::fs::metadata(&path).map_err(|_| format!("no device “{name}” here: `roamrunctl devices` lists them"))?;
    // The file is a key: as ssh does, one that others can read isn't used.
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!("{} can be read by others (mode {:o}): `chmod 600` it, or pair again", path.display(), meta.permissions().mode() & 0o777));
    }
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

fn save(saved: &Saved) -> Result<PathBuf, String> {
    let path = folder()?.join(format!("{}.json", named(&saved.name)?));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)
        .map_err(|e| if e.kind() == std::io::ErrorKind::AlreadyExists { format!("a device “{}” is saved here already: `roamrunctl devices remove {}` first, or --as another name", saved.name, saved.name) } else { format!("{}: {e}", path.display()) })?;
    file.write_all(serde_json::to_string_pretty(saved).map_err(|e| e.to_string())?.as_bytes()).map_err(|e| format!("{}: {e}", path.display()))?;
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

fn import(file: &Path, name: Option<String>) -> Result<String, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let shared: Shared = serde_json::from_str(&text).map_err(|_| format!("{} isn't a file `roamrun key create` wrote", file.display()))?;
    if shared.version != 1 || shared.pairing.is_empty() || shared.device.ip.parse::<std::net::Ipv4Addr>().is_err() {
        return Err(format!("{} isn't a file `roamrun key create` wrote", file.display()));
    }
    let name = name.unwrap_or_else(|| shared.device.name.chars().map(|c| if c.is_ascii_alphanumeric() || "-_.".contains(c) { c } else { '-' }).collect());
    let saved = Saved { v: 1, name, ip: shared.device.ip, port: shared.device.port.unwrap_or(PORTS.start), pairing: shared.pairing };
    // Tried before it is kept, and the file goes only once it is: a key that doesn't open the device isn't one.
    open(&saved)?;
    let path = save(&saved)?;
    std::fs::remove_file(file).map_err(|e| format!("saved, but {} couldn't be removed ({e}): remove it yourself, it is a key", file.display()))?;
    Ok(format!("Saved {} ({}), and it connects. The key is {}: whoever can read it and reach the device can see and operate it.", saved.name, saved.ip, path.display()))
}

fn open(saved: &Saved) -> Result<Device, String> {
    let answers = |port: u16| format!("{}:{port}", saved.ip).parse::<SocketAddr>().is_ok_and(|at| TcpStream::connect_timeout(&at, Duration::from_millis(700)).is_ok());
    let port = Some(saved.port).filter(|p| answers(*p)).or_else(|| PORTS.clone().find(|p| answers(*p)))
        .ok_or_else(|| format!("{} ({}) doesn't answer: is it on Wi‑Fi, unlocked once since it started, and connected in Tailscale? (on cellular alone it refuses)", saved.name, saved.ip))?;
    Device::open(&saved.ip, port, saved.pairing.as_bytes()).map_err(|why| format!("{}: {why}", saved.name))
}

/// Whether an answer of the library's says it went well; its words otherwise.
fn said(answer: String) -> Result<serde_json::Value, String> {
    let value: serde_json::Value = serde_json::from_str(&answer).map_err(|_| answer.clone())?;
    if value["ok"] == true { Ok(value) } else { Err(value["error"].as_str().unwrap_or(&answer).to_string()) }
}

/// The device's picture, its longer side LONGER at most, as PNG; and its size.
fn fitted(png: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    let image = image::load_from_memory_with_format(png, image::ImageFormat::Png).map_err(|e| format!("the device's picture couldn't be read: {e}"))?;
    let longer = image.width().max(image.height());
    let image = if longer > LONGER { image.resize(LONGER, LONGER, image::imageops::FilterType::Triangle) } else { image };
    let mut out = std::io::Cursor::new(Vec::new());
    image.write_to(&mut out, image::ImageFormat::Png).map_err(|e| e.to_string())?;
    Ok((out.into_inner(), image.width(), image.height()))
}

fn look(name: &str, file: Option<PathBuf>) -> Result<String, String> {
    let device = open(&load(name)?)?;
    let (png, width, height) = fitted(&device.screenshot()?)?;
    let path = file.unwrap_or_else(|| std::env::temp_dir().join(format!("roamrunctl-{}-{}.png", named(name).unwrap_or("device"), std::process::id())));
    // Whatever is on the screen is in it: the owner's only.
    let _ = std::fs::remove_file(&path);
    let mut out = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    out.write_all(&png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{}\n{width} x {height}", path.display()))
}

fn list() -> Result<String, String> {
    let mut names: Vec<String> = std::fs::read_dir(folder()?).map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.strip_suffix(".json").map(str::to_string)).collect();
    names.sort();
    if names.is_empty() { return Ok("No device is saved here. `roamrunctl key import <file>` saves one from a file `roamrun key create` wrote.".into()); }
    Ok(names.iter().map(|name| match load(name) {
        Ok(saved) => format!("{name}\t{}", saved.ip),
        Err(why) => format!("{name}\t({why})"),
    }).collect::<Vec<_>>().join("\n"))
}

pub fn run(command: Command) -> i32 {
    let done = match command {
        Command::Devices { command: None } => list(),
        Command::Devices { command: Some(Devices::Remove { name }) } => named(&name).and_then(|name| {
            let path = folder()?.join(format!("{name}.json"));
            std::fs::remove_file(&path).map_err(|_| format!("no device “{name}” here"))?;
            Ok(format!("Removed {name} and its pairing here. On the device, remove this machine in its list too (Settings › Privacy & Security › Developer Mode)."))
        }),
        Command::Key { command: Key::Import { file, name } } => import(&file, name),
        Command::Look { name, file } => look(&name, file),
        Command::Install { name, path } => load(&name).and_then(|saved| open(&saved)).and_then(|device| {
            said(device.install(&path.to_string_lossy())).map(|_| format!("Installed {} on {name}.", path.display()))
        }),
        Command::Launch { name, bundle } => load(&name).and_then(|saved| open(&saved)).and_then(|device| {
            said(device.launch(&bundle)).map(|value| format!("Launched {bundle} on {name} (pid {}).", value["pid"]))
        }),
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
        let (_, w, h) = fitted(&png(1179, 2556)).unwrap();
        assert_eq!((w, h), (590, 1280));
        let (_, w, h) = fitted(&png(2556, 1179)).unwrap();
        assert_eq!((w, h), (1280, 590));
        let (_, w, h) = fitted(&png(300, 200)).unwrap();
        assert_eq!((w, h), (300, 200));
        assert!(fitted(b"not a picture").is_err());
    }

    #[test]
    fn what_the_library_says_is_ok_or_its_error() {
        assert!(said("{\"ok\":true,\"pid\":7}".into()).is_ok_and(|v| v["pid"] == 7));
        assert_eq!(said("{\"ok\":false,\"error\":\"no\"}".into()).unwrap_err(), "no");
        assert!(said("garbage".into()).is_err());
    }
}
