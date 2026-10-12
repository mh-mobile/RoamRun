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

pub fn folder() -> Result<PathBuf, String> {
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
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!("{} can be read by others (mode {:o}): `chmod 600` it, or pair again", path.display(), meta.permissions().mode() & 0o777));
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
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
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
    let saved = Saved { v: 1, name, ip: shared.device.ip, port: shared.device.port.unwrap_or(PORTS.start), pairing: shared.pairing };
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
    Device::open(&saved.ip, port, saved.pairing.as_bytes()).map_err(|why| format!("{}: {}", saved.name, roamrun_device::safe::readable(&why)))
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
    let saved = Saved { v: 1, name: name.to_string(), ip: ip.to_string(), port, pairing: pairing.to_string() };
    open(&saved)?;
    let path = save(&saved, passphrase)?;
    Ok(match passphrase {
        Some(_) => format!("Its pairing is kept under the passphrase, in {}.", path.display()),
        None => format!("The key is {}, as it is: whoever can read it and reach the device can see and operate it.", path.display()),
    })
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
    let mut out = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    out.write_all(&png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{}\n{width} x {height}", path.display()))
}

fn list() -> Result<String, String> {
    let names = names()?;
    if names.is_empty() { return Ok("No device is saved here. `roamrunctl key import <file>` saves one from a file `roamrun key create` wrote.".into()); }
    // Named only: what else is saved of one may be under a passphrase, which a list doesn't ask for.
    Ok(names.iter().map(|name| match kept(name) {
        Ok(Some((_, true))) => format!("{name}\tunder a passphrase"),
        _ => format!("{name}\tas it is"),
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
