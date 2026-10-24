//! Holding a pairing with a device and using it: what is saved here, and the commands on it.

use std::io::Write;
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
    /// Save the device and the pairing of a file `roamrun key create` wrote, or one roamrunctl saved for a device on another machine; a file (not one saved here) is removed once it is saved
    Import {
        /// The file, or - for standard input (a CI's secret, say)
        file: PathBuf,
        /// The name to save it under here
        #[arg(long = "as")]
        name: Option<String>,
        /// Keep it under a passphrase (typed here, or given as the README says), not as a file of this user's
        #[arg(long)]
        passphrase: bool,
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
    /// The Tailscale name of the machine that keeps the private key and signs with it, asked by `name`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    signer: Option<String>,
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

/// A new file with all of `bytes` in it, the user's own; one that is there already is an error. Never there
/// half written: it is written beside itself and put in place whole.
pub fn own_whole(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let beside = path.with_extension(format!("{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&beside);
    let put = own_file(&beside).and_then(|mut file| file.write_all(bytes)).and_then(|()| std::fs::hard_link(&beside, path));
    let _ = std::fs::remove_file(&beside);
    match put {
        // Where files can't be put in place so (FAT, some network folders): written where it goes.
        Err(why) if why.kind() != std::io::ErrorKind::AlreadyExists => own_file(path).and_then(|mut file| file.write_all(bytes).inspect_err(|_| { let _ = std::fs::remove_file(path); })),
        put => put,
    }
}

/// As `own_whole`, in place of what is there: that stays until all of `bytes` is written.
fn replace_whole(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let beside = path.with_extension(format!("{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&beside);
    let put = own_file(&beside).and_then(|mut file| file.write_all(bytes)).and_then(|()| std::fs::rename(&beside, path));
    if put.is_err() { let _ = std::fs::remove_file(&beside); }
    put
}

/// The mode of a file that others can read, where the system has modes.
fn open_to_others(meta: &std::fs::Metadata) -> Option<u32> {
    #[cfg(unix)]
    { let mode = std::os::unix::fs::PermissionsExt::mode(&meta.permissions()); (mode & 0o077 != 0).then_some(mode & 0o777) }
    #[cfg(not(unix))]
    { let _ = meta; None }
}

pub fn folder() -> Result<PathBuf, String> {
    // Tests keep nothing among the user's own devices.
    let base = if cfg!(test) {
        Some(std::env::temp_dir().join("roamrunctl-test-devices"))
    } else if cfg!(windows) {
        // Not the folder a roaming profile copies to other machines: a key, and this machine's own id.
        std::env::var_os("LOCALAPPDATA").or_else(|| std::env::var_os("APPDATA")).map(PathBuf::from)
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
    // What Windows keeps for its own devices, whatever follows a dot.
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
        || stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.ends_with(|c: char| c.is_ascii_digit());
    // Not led by what a command reads as an option, or hides as a file.
    let why = if reserved { "it is a name Windows keeps for itself" }
        else if name.len() > 63 { "63 characters at most" }
        else if name.is_empty() || name.starts_with(['.', '-']) { "it begins with a letter or a digit" }
        else if !name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) { "letters, digits, - _ . only" }
        else { return Ok(name) };
    Err(format!("“{name}” can't be a device's name here ({why}): give another with --as"))
}

/// Where a device is kept: under a passphrase (.age), or as it is (.json).
fn kept(name: &str) -> Result<Option<(PathBuf, bool)>, String> {
    let folder = folder()?;
    let name = named(name)?;
    Ok([("age", true), ("json", false)].into_iter().map(|(ending, sealed)| (folder.join(format!("{name}.{ending}")), sealed)).find(|(path, _)| path.exists()))
}

/// The device named, and its file as it was read where it is saved here.
fn load(name: &str) -> Result<(Saved, Option<Vec<u8>>), String> {
    let Some((path, sealed)) = kept(name)? else {
        // Not saved here: one another machine keeps the key of, and signs for this one.
        let offered = offered().map_err(|why| format!("no device “{name}” is saved here, and none is offered: {why}"))?;
        return offered.into_iter().find(|saved| saved.name == name).map(|saved| (saved, None)).ok_or_else(|| format!(
            "no device “{name}” is saved here, and no machine was found that signs for this one with it.\n{}", sign_how(name)));
    };
    read(name, &path, sealed).map(|(saved, file)| (saved, Some(file)))
}

/// A device saved here, and its file as it was read: what tells it later from another saved under its name.
fn read(name: &str, path: &Path, sealed: bool) -> Result<(Saved, Vec<u8>), String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    // The file is a key: as ssh does, one that others can read isn't used.
    if let Some(mode) = open_to_others(&meta) {
        return Err(format!("{} can be read by others (mode {mode:o}): `chmod 600` it, or pair again", path.display()));
    }
    let file = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let opened;
    let bytes = if sealed { opened = opened_once(name, &file, || crate::secret::passphrase(name, false))?; &opened } else { &file };
    let saved: Saved = serde_json::from_slice(bytes).map_err(|e| format!("{} isn't a saved device ({e}): `roamrunctl devices remove {name}` forgets it", path.display()))?;
    // Another's file, found where names differ only by case, or renamed by hand.
    if saved.name != name { return Err(format!("“{name}” is saved here as “{}”: name it so", saved.name)); }
    Ok((saved, file))
}

/// A device's name, its sealed file, and what the file opened to.
type Opened = (String, Vec<u8>, Vec<u8>);

/// What each device's sealed file opened to.
static OPENED: std::sync::Mutex<Vec<Opened>> = std::sync::Mutex::new(Vec::new());

/// What a sealed file opened to, kept for this process while the file is the same: `mcp --http` opens a device
/// again after a failure, on a thread where no terminal can be asked, and a passphrase command isn't run again.
fn opened_once(name: &str, file: &[u8], passphrase: impl FnOnce() -> Result<String, String>) -> Result<Vec<u8>, String> {
    if let Some((_, _, plain)) = OPENED.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(n, sealed, _)| n == name && sealed == file) { return Ok(plain.clone()) }
    forget_opened(name, Some(file));
    let plain = crate::secret::opened(file, &passphrase()?).map_err(|why| format!("{name}: {why}"))?;
    OPENED.lock().unwrap_or_else(|e| e.into_inner()).push((name.to_string(), file.to_vec(), plain.clone()));
    Ok(plain)
}

/// Lets go of what the device's sealed file opened to, unless the file is still `now`: removed, or saved anew.
fn forget_opened(name: &str, now: Option<&[u8]>) {
    OPENED.lock().unwrap_or_else(|e| e.into_inner()).retain(|(n, sealed, _)| n != name || Some(sealed.as_slice()) == now);
}

/// How a machine that keeps a key comes to sign for this one, and how this one finds it.
fn sign_how(name: &str) -> String {
    let me = crate::tailscale::status().map(|status| crate::tailscale::short(&status.this.dns_name).to_string()).unwrap_or_else(|_| "<this machine>".into());
    format!("On the machine that keeps its key: roamrunctl sign {name} --for {me}\nIt is found where it is this user's own, online, and lets this machine in on TCP port {}; where either machine is tagged, or the two are different users', set {}=<its Tailscale name> here.", crate::sign::PORT, crate::sign::SIGNER)
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
    let folder = folder()?;
    let path = folder.join(format!("{}.{ending}", saved.name));
    own_whole(&path, &bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    // Saved at the same moment the other way (under a passphrase, or not): one name, one file.
    let other = folder.join(format!("{}.{}", saved.name, if ending == "age" { "json" } else { "age" }));
    if other.exists() {
        let _ = std::fs::remove_file(&path);
        return Err(format!("a device “{}” was saved here just now by another command: nothing was kept by this one", saved.name));
    }
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

/// What `key import` reads: a file `roamrun key create` wrote, or one saved here for a device on another machine.
fn imported(bytes: &[u8], from: &str, name: Option<String>) -> Result<Saved, String> {
    if bytes.starts_with(b"age-encryption.org/v1") {
        return Err(format!("{from} is a record kept under a passphrase (a .age file): it isn't imported: pair again (`--passphrase` here keeps an imported one encrypted)"));
    }
    let text = std::str::from_utf8(bytes).map_err(|_| format!("{from} isn't text: not a file `roamrun key create` wrote, nor a device roamrunctl saved"))?;
    // Without the mark some editors on Windows put first, as a passphrase file is read.
    let text = text.trim_start_matches('\u{feff}');
    let refused = || format!("{from} isn't a file `roamrun key create` wrote, nor a device roamrunctl saved");
    let saved = if let Ok(shared) = serde_json::from_str::<Shared>(text) {
        if shared.version != 1 || shared.pairing.is_empty() || shared.device.ip.parse::<std::net::Ipv4Addr>().is_err() { return Err(refused()) }
        let name = name.unwrap_or_else(|| crate::hold::filed(&shared.device.name));
        Saved { v: 1, name, ip: shared.device.ip, port: shared.device.port.unwrap_or(PORTS.start), pairing: shared.pairing, signer: None }
    } else {
        let saved: Saved = serde_json::from_str(text).map_err(|_| refused())?;
        if saved.v != 1 || saved.pairing.is_empty() || saved.ip.parse::<std::net::Ipv4Addr>().is_err() { return Err(refused()) }
        if let Some(signer) = &saved.signer { return Err(format!("{from} holds no key: {signer} keeps it, and signs for the machine it was saved on")) }
        Saved { name: name.unwrap_or(saved.name), ..saved }
    };
    named(&saved.name)?;
    Ok(saved)
}

/// Whether an import removes `file` once it is saved: not standard input, nor a file saved here.
fn removed_once_saved(file: &Path) -> bool {
    file != Path::new("-") && !saved_here(file)
}

/// A file in the folder devices are saved in here: an import of it (under another name) leaves it.
fn saved_here(file: &Path) -> bool {
    let parent = |path: &Path| path.parent().map(|p| if p.as_os_str().is_empty() { Path::new(".") } else { p }).and_then(|p| p.canonicalize().ok());
    folder().ok().and_then(|folder| folder.canonicalize().ok()).is_some_and(|folder| parent(file) == Some(folder))
}

/// `ask`: the passphrase, where it is to be `sealed` under one; asked before the device is, which may take a while.
fn import(file: &Path, name: Option<String>, sealed: bool, ask: impl FnOnce(&str) -> Result<String, String>) -> Result<String, String> {
    let stdin = file == Path::new("-");
    let from = if stdin { "standard input".to_string() } else { file.display().to_string() };
    let bytes = if stdin { let mut bytes = Vec::new(); std::io::Read::read_to_end(&mut std::io::stdin(), &mut bytes).map(|_| bytes) } else { std::fs::read(file) }.map_err(|e| format!("{from}: {e}"))?;
    let saved = imported(&bytes, &from, name)?;
    if kept(&saved.name)?.is_some() {
        return Err(format!("a device “{}” is saved here already: `roamrunctl devices remove {}` first, or --as another name", saved.name, saved.name));
    }
    let passphrase = if sealed { Some(ask(&saved.name)?) } else { None };
    // Tried before it is kept, and the file goes only once it is: a key that doesn't open the device isn't one.
    open(&saved)?;
    let path = save(&saved, passphrase.as_deref())?;
    if removed_once_saved(file) { std::fs::remove_file(file).map_err(|e| format!("saved, but {} couldn't be removed ({e}): remove it yourself, it is a key", file.display()))?; }
    Ok(match passphrase {
        Some(_) => format!("Saved {} ({}), and it connects. Its pairing is kept under the passphrase, in {}: that keeps the file from being a key on its own, not from whoever has both.", saved.name, saved.ip, path.display()),
        None => format!("Saved {} ({}), and it connects. The key is {}, as it is: whoever can read it and reach the device can see and operate it.", saved.name, saved.ip, path.display()),
    })
}

fn open(saved: &Saved) -> Result<Device, String> {
    let answers = |port: u16, within: u64| roamrun_device::proxy::reach(&saved.ip, port, Duration::from_millis(within)).is_ok();
    // The port it was saved with is given the time a device that slept takes; the others are asked together.
    let mut first = None;
    if answers(saved.port, 2500) {
        match open_at(saved, saved.port) {
            Ok(device) => return Ok(device),
            // The pairing answered there and its key's keeper refused: no other port would do better.
            Err(why) if why.contains(REFUSED) => return Err(why),
            Err(why) => first = Some(why),
        }
    }
    // Whatever answered there wasn't the pairing, or nothing did: the others, and whatever answers on one needn't be it either.
    let others: Vec<u16> = std::thread::scope(|all| PORTS.filter(|p| *p != saved.port).map(|p| all.spawn(move || answers(p, 1500).then_some(p))).collect::<Vec<_>>().into_iter().filter_map(|one| one.join().ok().flatten()).collect());
    // ponytail: for a minute at most — each that answers and says nothing costs the library's 20 s. A shorter
    // wait there, once it is known what a device has open in that range.
    let began = std::time::Instant::now();
    for port in others {
        if began.elapsed() > Duration::from_secs(60) { break }
        match open_at(saved, port) {
            Ok(device) => return Ok(device),
            Err(why) if why.contains(REFUSED) => return Err(why),
            Err(why) => { first.get_or_insert(why); }
        }
    }
    Err(first.unwrap_or_else(|| format!("{} ({}) doesn't answer: is it on Wi‑Fi, unlocked once since it started, and connected in Tailscale? (on cellular alone it refuses) If it restarted since it was saved, its pairing port may have moved out of reach: pair again", saved.name, saved.ip)))
}

/// In what is said where the machine that keeps a key didn't sign.
const REFUSED: &str = "which keeps its key, didn't sign";

fn open_at(saved: &Saved, port: u16) -> Result<Device, String> {
    let opened = match &saved.signer {
        // The key is kept on another machine: it is asked for the one signature a connection takes.
        Some(signer) => {
            let refused = std::sync::Mutex::new(None);
            let opened = Device::open_signed(&saved.ip, port, saved.pairing.as_bytes(), |what| {
                crate::sign::ask(signer, &saved.name, what).map_err(|why| *refused.lock().unwrap_or_else(|e| e.into_inner()) = Some(why)).ok()
            });
            // Why it wasn't signed, in the signer's words, where that is why it didn't open.
            match refused.into_inner().unwrap_or_else(|e| e.into_inner()) {
                Some(why) => Err(format!("{signer}, {REFUSED}: {why}")),
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
    let saved = Saved { v: 1, name: name.to_string(), ip: ip.to_string(), port, pairing: pairing.to_string(), signer: None };
    open(&saved)?;
    let path = save(&saved, passphrase)?;
    Ok(match passphrase {
        Some(_) => format!("Its pairing is kept under the passphrase, in {}.", path.display()),
        None => format!("The key is {}, as it is: whoever can read it and reach the device can see and operate it.", path.display()),
    })
}

/// A saved device as another machine is told of it: without its key (any key stands in its place).
fn bare(mut saved: Saved) -> Result<Saved, String> {
    saved.pairing = crate::sign::without_key(&saved.pairing)?.0;
    Ok(saved)
}

/// The devices other machines say they keep the keys of and sign for this one. What is said isn't checked
/// beyond its form: it is believed the first time a device is used, and held to from then on (see `opened`).
/// An error where Tailscale can't say (signed out, stopped, not answering) or the machine `ROAMRUNCTL_SIGNER`
/// names isn't one: said, not taken for none signing.
fn offered() -> Result<Vec<Saved>, String> {
    if cfg!(test) { return Ok(Vec::new()) }
    offered_by(crate::tailscale::status())
}

fn offered_by(status: Result<crate::tailscale::Status, String>) -> Result<Vec<Saved>, String> {
    let status = status?;
    let on_tailnet: std::collections::HashSet<&str> = status.peers.values().flat_map(|p| p.ips.iter().map(String::as_str)).collect();
    let said = crate::sign::signers(&status, std::env::var(crate::sign::SIGNER).ok().filter(|s| !s.is_empty()))?;
    Ok(taken(&said, &on_tailnet))
}

/// A saved device's file as it is now: what tells it from another saved under its name since.
pub fn mark(name: &str) -> Option<Vec<u8>> {
    let kept = kept(name);
    let now = kept.as_ref().ok().cloned().flatten().and_then(|(path, _)| std::fs::read(path).ok());
    // What an earlier file under the name opened to isn't kept past it: seen gone, or read and not it. A read that
    // failed says neither, and lets go of nothing.
    match (&kept, &now) {
        (Ok(None), _) => forget_opened(name, None),
        (_, Some(now)) => forget_opened(name, Some(now)),
        _ => {}
    }
    now
}

/// Of what each machine said it signs for (its name, its list), what is taken.
fn taken(said: &[(String, String)], on_tailnet: &std::collections::HashSet<&str>) -> Vec<Saved> {
    let mut found: Vec<Saved> = Vec::new();
    for (signer, list) in said {
        for mut saved in serde_json::from_str::<Vec<Saved>>(list).unwrap_or_default() {
            let fits = saved.v == 1 && named(&saved.name).is_ok() && on_tailnet.contains(saved.ip.as_str()) && !saved.pairing.is_empty();
            // Two that offer one name: the first asked is the one, and the list says whose.
            if fits && !found.iter().any(|have| have.name == saved.name) {
                saved.signer = Some(signer.clone());
                found.push(saved);
            }
        }
    }
    found
}

/// The pairings of `names` (what `roamrunctl sign` signs with), those devices as the other machine is told
/// of them, each without its key, and what their files are now.
type Signing = (crate::sign::Keys, Vec<Saved>, std::collections::HashMap<String, Vec<u8>>);

fn keys(names: &[String]) -> Result<Signing, String> {
    if names.is_empty() {
        let saved: Vec<String> = self::names_here()?.into_iter().filter(|name| matches!(kept(name), Ok(Some(_)))).collect();
        return Err(format!("which devices: roamrunctl sign <name>… --for <machine>   (saved here: {})", if saved.is_empty() { "none".to_string() } else { saved.join(", ") }));
    }
    let (mut keys, mut told, mut marks) = (crate::sign::Keys::new(), Vec::new(), std::collections::HashMap::new());
    for name in names {
        let Some((path, sealed)) = kept(name)? else { return Err(format!("no device “{name}” is saved here: `roamrunctl devices` lists them")) };
        // The file the key was read from, as it was read: not one that took its place while a passphrase was typed.
        let (saved, file) = read(name, &path, sealed)?;
        let (identifier, key) = crate::sign::key(&saved.pairing).filter(|_| saved.signer.is_none())
            .ok_or_else(|| format!("{name}'s key isn't kept here: there is nothing to sign with"))?;
        marks.insert(name.clone(), file);
        keys.insert(name.clone(), (identifier, key));
        told.push(bare(saved)?);
    }
    Ok((keys, told, marks))
}

/// A device saved here — with its key, or held to the machine that signs for it — read as using it reads it:
/// its address on the tailnet, and its file as read (what `mark` gives while it is unchanged). An error
/// where it is only offered by a machine that signs, or can't be read.
pub fn as_saved(name: &str) -> Result<(String, Vec<u8>), String> {
    let (path, sealed) = kept(named(name)?)?.ok_or_else(|| format!("{name} isn't saved here: use it once here first (`roamrunctl look {name}`), or name another"))?;
    read(name, &path, sealed).map(|(saved, file)| (saved.ip, file))
}

/// A device opened, and its saved file as it was then (None: one only a machine that signs offers).
pub type Held = (Device, Option<Vec<u8>>);

pub fn opened(name: &str) -> Result<Device, String> {
    held(name).map(|(device, _)| device)
}

/// The device saved here under `name`, opened, and its file as read; None where none is saved. Never one only a
/// machine that signs offers: `mcp --http` holds to what it offered, and asks no other machine.
pub fn held_here(name: &str) -> Result<Option<Held>, String> {
    let Some((path, sealed)) = kept(name)? else { return Ok(None) };
    let (saved, file) = read(name, &path, sealed)?;
    Ok(Some((open(&saved)?, Some(file))))
}

/// The device named, opened, and the file it was opened from (see `mark`). One another machine signs for is
/// saved here the first time it opens, without its key: from then on only that machine is asked, and only
/// that device is taken for it.
pub fn held(name: &str) -> Result<Held, String> {
    let (saved, mut file) = load(name)?;
    let device = open(&saved)?;
    if file.is_none() {
        match save(&saved, None) {
            Ok(path) => { file = std::fs::read(&path).ok(); note!("roamrunctl: {name} is used for the first time here: {} signs for it, and that is held to from now on ({}). `roamrunctl devices remove {name}` forgets it.", saved.signer.as_deref().unwrap_or("another machine"), path.display()) }
            // Another command saved it meanwhile: what it saved is what is held to, and what is opened.
            Err(_) if kept(name).is_ok_and(|kept| kept.is_some()) => { drop(device); let (saved, file) = load(name)?; return Ok((open(&saved)?, file)) }
            // Not held to, it isn't used: the next command would believe whichever machine offered the name.
            Err(why) => return Err(format!("{name} opened, but which machine signs for it couldn't be saved here, and without that it isn't used: {why}")),
        }
    }
    Ok((device, file))
}

/// The machine that signs for a device saved here without its key; None where its key is here.
fn signer_of(name: &str) -> Option<String> {
    let (path, sealed) = kept(name).ok()??;
    if sealed { return None }
    serde_json::from_slice::<Saved>(&std::fs::read(path).ok()?).ok()?.signer
}

/// The names of the devices this machine can use: those saved here, and those another machine signs for it with.
pub fn names() -> Result<Vec<String>, String> {
    let mut names = names_here()?;
    names.extend(offered().unwrap_or_default().into_iter().map(|saved| saved.name));
    names.sort();
    names.dedup();
    Ok(names)
}

/// The names of the devices saved here.
fn names_here() -> Result<Vec<String>, String> {
    let mut names: Vec<String> = std::fs::read_dir(folder()?).map_err(|e| e.to_string())?
        .filter_map(|entry| { let name = entry.ok()?.file_name(); let name = name.to_str()?; name.strip_suffix(".age").or(name.strip_suffix(".json")).map(str::to_string) }).collect();
    names.sort();
    names.dedup();
    Ok(names)
}

/// `roamrunctl install`: an .ipa is checked before the device is opened, as MCP does. With `launch`, the app is then
/// launched by the bundle identifier in it.
fn install(name: &str, path: &std::path::Path, launch: bool) -> Result<String, String> {
    let path_text = path.to_string_lossy();
    let bundle = if std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?.is_file() { Some(roamrun_device::ipa_checked(&path_text)?) } else { None };
    let bundle = match (launch, bundle) {
        (false, _) => None,
        (true, Some(bundle)) => Some(bundle),
        (true, None) => Some(plist::Value::from_file(path.join("Info.plist")).ok().and_then(|info| Some(info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?.to_string()))
            .ok_or_else(|| format!("{}/Info.plist says no bundle identifier to launch", path.display()))?),
    };
    let device = opened(name)?;
    let (megabytes, given) = roamrun_device::install_given(&path_text);
    note!("Sending {} ({megabytes} MB) to {name}: nothing more is said until it is in, {} minutes at most. A megabyte took three to four seconds on the device's own Wi‑Fi.", path.display(), given.as_secs().div_ceil(60));
    said(device.install(&path_text))?;
    let installed = format!("Installed {} on {name}.", path.display());
    let Some(bundle) = bundle else { return Ok(installed) };
    // In, whatever the launch does.
    let _ = writeln!(std::io::stdout(), "{installed}");
    launched(&device, name, &bundle)
}

fn launched(device: &Device, name: &str, bundle: &str) -> Result<String, String> {
    said(device.launch(bundle)).map(|value| format!("Launched {bundle} on {name} (pid {}).", value["pid"]))
}

fn look(name: &str, file: Option<PathBuf>) -> Result<String, String> {
    let device = opened(name)?;
    let (png, width, height) = fitted(&device.screenshot()?, image::ImageFormat::Png)?;
    let path = file.unwrap_or_else(|| std::env::temp_dir().join(format!("roamrunctl-{}-{}.png", named(name).unwrap_or("device"), std::process::id())));
    // Whatever is on the screen is in it: the owner's only.
    replace_whole(&path, &png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{}\n{width} x {height}", path.display()))
}

/// What this machine can use. What is saved here is listed whoever is named to sign.
/// `agent`: for one — where there is none, nothing it is to run.
pub fn listed(agent: bool) -> Result<String, String> {
    let names = names_here()?;
    let (offered, wrong) = match offered() { Ok(offered) => (offered, None), Err(why) => (Vec::new(), Some(why)) };
    if names.is_empty() && offered.is_empty() {
        let wrong = wrong.map(|why| format!(" ({why})")).unwrap_or_default();
        return Ok(if agent {
            format!("No device this machine can use{wrong}. Coming by one is the user's: `roamrunctl devices`, at a terminal of theirs, says how.")
        } else {
            format!("No device is saved here, and no machine was found that signs for this one{wrong}.\nTo pair with one: roamrunctl pair control --to <device> (on its Wi‑Fi), or --with <a machine on its Wi‑Fi>.\nTo use one whose key another machine keeps:\n{}", sign_how("<device>"))
        });
    }
    Ok(lines(&names, &offered) + &wrong.map(|why| format!("\n({why}: no machine is asked what it signs for)")).unwrap_or_default())
}

pub fn lines(names: &[String], offered: &[Saved]) -> String {
    // Named only: what else is saved of one may be under a passphrase, which a list doesn't ask for.
    names.iter().map(|name| match (kept(name), signer_of(name)) {
        (_, Some(signer)) => format!("{name}\tits key is kept by {signer}, which signs for this machine"),
        (Ok(Some((_, true))), _) => format!("{name}\tunder a passphrase"),
        _ => format!("{name}\tas it is"),
    }).chain(offered.iter().filter(|saved| !names.contains(&saved.name)).map(|saved| {
        format!("{}\tits key is kept by {}, which signs for this machine (not used here yet)", saved.name, saved.signer.as_deref().unwrap_or("another machine"))
    })).collect::<Vec<_>>().join("\n")
}

pub fn run(command: Command) -> i32 {
    let done = match command {
        Command::Devices { command: None } => listed(false),
        Command::Devices { command: Some(Devices::Remove { name }) } => named(&name).and_then(|name| {
            let signer = signer_of(name);
            if kept(name)?.is_none() {
                return Err(match offered().unwrap_or_default().into_iter().find(|saved| saved.name == name) {
                    Some(saved) => format!("{name} isn't saved here: {} offers it. It goes when `roamrunctl sign` ends there, or the device is removed there", saved.signer.as_deref().unwrap_or("another machine")),
                    None => format!("no device “{name}” here"),
                });
            }
            while let Some((path, _)) = kept(name)? { std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?; }
            // What a save that was cut short left beside it (see `own_whole`) is a copy of it.
            for left in std::fs::read_dir(folder()?).into_iter().flatten().flatten().map(|entry| entry.path()) {
                let file = left.file_name().and_then(|n| n.to_str()).unwrap_or("");
                if file.strip_prefix(name).and_then(|rest| rest.strip_prefix('.')).and_then(|rest| rest.strip_suffix(".tmp")).is_some_and(|pid| pid.bytes().all(|b| b.is_ascii_digit())) { let _ = std::fs::remove_file(&left); }
            }
            Ok(match signer {
                Some(signer) => format!("Forgot {name} here. Its key is kept by {signer}: it is asked again the next time {name} is used, for as long as `roamrunctl sign` there names it."),
                None => format!("Removed {name} and its pairing here: a `roamrunctl sign` running here signs for it no more. On the device, remove this machine in its list too (Settings › Privacy & Security › Developer Mode) — unless another pairing with that device is saved here: the entry there is that one's too."),
            })
        }),
        Command::Key { command: Key::Import { file, name, passphrase } } => import(&file, name, passphrase, |name| crate::secret::passphrase(name, true)),
        Command::Look { name, file } => look(&name, file),
        Command::Install { name, path, launch, relay, timeout } => match relay.given() {
            Ok(Some((relay, token_file))) => crate::remote::Relay::new(&relay, token_file.as_deref()).and_then(|relay| {
                let (said, bundle) = relay.install(&name, &path, timeout)?;
                if !launch { return Ok(said) }
                // In, whatever the launch does.
                let _ = writeln!(std::io::stdout(), "{said}");
                relay.call("launch", serde_json::json!({ "device": name, "bundle": bundle }))
            }),
            Ok(None) if timeout.is_some() => Err("--timeout goes with --relay, and ROAMRUNCTL_RELAY is empty".into()),
            Ok(None) => install(&name, &path, launch),
            Err(why) => Err(why),
        },
        Command::Launch { name, bundle, relay } => match relay.given() {
            Ok(Some((relay, token_file))) => crate::remote::Relay::new(&relay, token_file.as_deref())
                .and_then(|relay| relay.call("launch", serde_json::json!({ "device": name, "bundle": bundle }))),
            Ok(None) => opened(&name).and_then(|device| launched(&device, &name, &bundle)),
            Err(why) => Err(why),
        },
        Command::Mcp { http: None, .. } => return crate::mcp::Server::default().serve(),
        Command::Mcp { http: Some(port), allow, token_file, allow_install, max_upload, devices } => allow.iter().map(|a| crate::http::allow(a)).collect::<Result<Vec<_>, _>>()
            .and_then(|allowed| Ok(crate::http::Options { port, allowed, token: token_file.as_deref().map(crate::http::token).transpose()?, devices, uploads: allow_install.then_some(max_upload << 20) }))
            .and_then(crate::http::serve),
        Command::Sign { names, machine } => keys(&names).and_then(|(keys, told, marks)| {
            // The file it was read from, still: not another saved under the name since.
            // Once seen changed, not signed for again until this is run again — though the same file came back.
            let gone = std::cell::RefCell::new(std::collections::HashSet::new());
            let held = |name: &str| {
                if gone.borrow().contains(name) { return false }
                let same = marks.get(name).is_some_and(|was| mark(name).as_ref() == Some(was));
                if !same { gone.borrow_mut().insert(name.to_string()); }
                same
            };
            let list = |held: crate::sign::Held| serde_json::to_string(&told.iter().filter(|saved| held(&saved.name)).collect::<Vec<_>>()).unwrap_or_else(|_| "[]".into());
            crate::sign::serve(&machine, keys, &list, &held)
        }),
        Command::Pair { .. } => unreachable!("handled by main"),
    };
    match done {
        Ok(text) => { let _ = writeln!(std::io::stdout(), "{text}"); 0 }
        Err(why) => { note!("roamrunctl: {why}"); 1 }
    }
}

/// For other modules' tests: a device saved with an address nothing is at, and its removal.
#[cfg(test)]
pub fn stub(name: &str, port: u16) {
    save(&Saved { v: 1, name: name.into(), ip: "nowhere".into(), port, pairing: "<plist/>".into(), signer: None }, None).unwrap();
}
#[cfg(test)]
pub fn unstub(name: &str) {
    std::fs::remove_file(folder().unwrap().join(format!("{name}.json"))).unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What Tailscale couldn't say is passed on (`offered_by`), not taken for no machine signing.
    #[test]
    fn a_tailscale_that_cant_say_is_said_so() {
        let why = offered_by(Err("Tailscale here isn't signed in: `tailscale up`".into())).err().unwrap_or_default();
        assert!(why.contains("isn't signed in"), "{why}");
    }

    #[test]
    fn what_is_imported_is_a_key_create_file_or_a_device_saved_with_its_key() {
        let shared = r#"{"roamrunPairing":1,"device":{"displayName":"Ann's iPhone","providerIP":"100.64.0.7","remotePairingPort":49153},"pairing":"<plist/>"}"#;
        let saved = imported(shared.as_bytes(), "-", None).unwrap();
        assert_eq!((saved.name.as_str(), saved.ip.as_str(), saved.port), ("Ann-s-iPhone", "100.64.0.7", 49153));
        // As roamrunctl saves it, pretty, and as a CI's secret may give it back: its lines run together.
        let kept = serde_json::to_string_pretty(&Saved { v: 1, name: "ci".into(), ip: "100.64.0.8".into(), port: 49152, pairing: "<plist/>".into(), signer: None }).unwrap();
        for text in [kept.clone(), kept.replace('\n', ""), kept.replace('\n', " ")] {
            assert_eq!(imported(text.as_bytes(), "-", None).unwrap().name, "ci");
        }
        assert_eq!(imported(kept.as_bytes(), "-", Some("other".into())).unwrap().name, "other");
        let signed = kept.replace(r#""pairing""#, r#""signer": "mac", "pairing""#);
        assert!(imported(signed.as_bytes(), "-", None).err().unwrap_or_default().contains("holds no key"));
        for text in ["", "{}", r#"{"roamrunPairing":2,"device":{"displayName":"a","providerIP":"100.64.0.7"},"pairing":"x"}"#, &kept.replace("100.64.0.8", "nowhere")] {
            assert!(imported(text.as_bytes(), "standard input", None).err().unwrap_or_default().starts_with("standard input isn't"), "{text}");
        }
        assert!(imported(kept.as_bytes(), "-", Some("../x".into())).is_err());
        // As some editors on Windows save it, led by a byte order mark.
        assert_eq!(imported(format!("\u{feff}{shared}").as_bytes(), "-", None).unwrap().name, "Ann-s-iPhone");
        // One kept under a passphrase is said to be that, not "not text".
        let sealed = crate::secret::sealed(kept.as_bytes(), "pw").unwrap();
        assert!(imported(&sealed, "phone.age", None).err().unwrap_or_default().starts_with("phone.age is a record kept under a passphrase (a .age file): it isn't imported: pair again"));
    }

    #[test]
    fn a_file_saved_here_is_left_by_its_import_and_another_goes() {
        assert!(!removed_once_saved(&folder().unwrap().join("a.json")));
        assert!(removed_once_saved(&std::env::temp_dir().join("a.json")));
        assert!(!removed_once_saved(Path::new("-")));
    }

    #[test]
    fn the_passphrase_is_asked_before_the_device_is() {
        let id = std::process::id();
        let file = std::env::temp_dir().join(format!("rr-import-{id}.json"));
        let saved = Saved { v: 1, name: format!("import-{id}"), ip: "127.0.0.1".into(), port: 1, pairing: "<plist/>".into(), signer: None };
        std::fs::write(&file, serde_json::to_vec(&saved).unwrap()).unwrap();
        assert_eq!(import(&file, None, true, |_| Err("asked".into())), Err("asked".into()));
        assert!(file.exists());
        std::fs::remove_file(file).unwrap();
    }

    #[test]
    fn an_ipa_that_isnt_an_app_is_refused_before_the_device_is_opened() {
        let name = format!("cli-install-{}", std::process::id());
        stub(&name, 49152);
        let file = std::env::temp_dir().join(format!("rr-cli-{}.ipa", std::process::id()));
        std::fs::write(&file, b"not a zip").unwrap();
        // Not "doesn't answer": the device, which isn't there, isn't asked.
        let said = install(&name, &file, false).unwrap_err();
        assert!(said.contains("isn't an app's .ipa"), "{said}");
        // One that isn't there is said so, not taken for an .app folder.
        let said = install(&name, Path::new("/nowhere/at/all.ipa"), false).unwrap_err();
        assert!(said.starts_with("/nowhere/at/all.ipa: "), "{said}");
        std::fs::remove_file(file).unwrap();
        unstub(&name);
    }

    #[test]
    fn a_sealed_file_is_asked_for_once_while_it_is_the_same() {
        let (plain, sealed) = (b"{\"v\":1}", crate::secret::sealed(b"{\"v\":1}", "pw").unwrap());
        assert_eq!(opened_once("d", &sealed, || Ok("pw".into())).unwrap(), plain);
        // Opened again (by `mcp --http`'s worker, after a failure): nothing is asked.
        assert_eq!(opened_once("d", &sealed, || Err("asked again".into())).unwrap(), plain);
        // Another file under the name: asked; a wrong passphrase isn't kept.
        let other = crate::secret::sealed(b"{\"v\":1}", "pw").unwrap();
        assert_eq!(opened_once("d", &other, || Err("asked again".into())).unwrap_err(), "asked again");
        assert!(opened_once("d", &other, || Ok("wrong".into())).unwrap_err().contains("isn't the one"));
        assert_eq!(opened_once("d", &other, || Ok("pw".into())).unwrap(), plain);
        // What the earlier file opened to went with it.
        assert_eq!(opened_once("d", &sealed, || Err("asked again".into())).unwrap_err(), "asked again");
        // Seen removed, or saved anew (by `mark`): let go of too; seen as it was, kept.
        assert_eq!(opened_once("d", &other, || Ok("pw".into())).unwrap(), plain);
        forget_opened("d", Some(&other));
        assert_eq!(opened_once("d", &other, || Err("asked again".into())).unwrap(), plain);
        forget_opened("d", None);
        assert_eq!(opened_once("d", &other, || Err("asked again".into())).unwrap_err(), "asked again");
    }

    #[test]
    fn what_a_sealed_file_opened_to_goes_once_it_is_seen_removed() {
        let name = format!("sealed-{}", std::process::id());
        let path = save(&Saved { v: 1, name: name.clone(), ip: "nowhere".into(), port: 1, pairing: "<plist/>".into(), signer: None }, Some("pw")).unwrap();
        let file = std::fs::read(&path).unwrap();
        opened_once(&name, &file, || Ok("pw".into())).unwrap();
        // Seen as it was: kept.
        assert_eq!(mark(&name).as_deref(), Some(file.as_slice()));
        assert!(opened_once(&name, &file, || Err("asked again".into())).is_ok());
        // A read that failed (here, a file its owner can't read): it says nothing of the file, and nothing goes.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
            // Unless this runs as root, which reads it all the same.
            if std::fs::read(&path).is_err() {
                assert_eq!(mark(&name), None);
                assert!(opened_once(&name, &file, || Err("asked again".into())).is_ok());
            }
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        // Seen saved anew under the name: what the old file opened to goes.
        let anew = crate::secret::sealed(b"{}", "pw").unwrap();
        std::fs::write(&path, &anew).unwrap();
        assert_eq!(mark(&name).as_deref(), Some(anew.as_slice()));
        assert_eq!(opened_once(&name, &file, || Err("asked again".into())).unwrap_err(), "asked again");
        std::fs::write(&path, &file).unwrap();
        opened_once(&name, &file, || Ok("pw".into())).unwrap();
        // Seen removed: let go of.
        std::fs::remove_file(&path).unwrap();
        assert_eq!(mark(&name), None);
        assert_eq!(opened_once(&name, &file, || Err("asked again".into())).unwrap_err(), "asked again");
        // Opened only as saved here, over HTTP: none saved is none, and no machine that signs is asked.
        assert!(matches!(held_here(&name), Ok(None)));
    }

    #[test]
    fn a_look_takes_the_place_of_the_file_named_whole() {
        let path = std::env::temp_dir().join(format!("roamrunctl-replace-{}.png", std::process::id()));
        std::fs::write(&path, b"old").unwrap();
        replace_whole(&path, b"new").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        assert!(!path.with_extension(format!("{}.tmp", std::process::id())).exists());
        // Not written: what was there stays.
        let beside = path.with_extension(format!("{}.tmp", std::process::id()));
        std::fs::create_dir(&beside).unwrap();
        assert!(replace_whole(&path, b"newer").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
        std::fs::remove_dir(&beside).unwrap();
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn what_a_machine_says_it_signs_for_is_taken_only_as_far_as_it_can_be_that() {
        let device = |name: &str, ip: &str, signer: &str| format!(r#"{{"v":1,"name":"{name}","ip":"{ip}","port":49152,"pairing":"<plist/>","signer":"{signer}"}}"#);
        let on_tailnet = std::collections::HashSet::from(["100.64.0.10"]);
        let said = vec![
            ("laptop.tail.ts.net".to_string(), format!("[{},{},{}]", device("phone", "100.64.0.10", "someone-else"), device("../etc", "100.64.0.10", "x"), device("elsewhere", "203.0.113.5", "x"))),
            ("other.tail.ts.net".to_string(), format!("[{}]", device("phone", "100.64.0.10", "other"))),
            ("broken.tail.ts.net".to_string(), "not a list".to_string()),
        ];
        let found = taken(&said, &on_tailnet);
        // The one whose name is a name and whose device is on this tailnet; from the first that offered it;
        // and the key's keeper is the machine that was asked, whatever the record says.
        assert_eq!(found.iter().map(|s| (s.name.as_str(), s.signer.as_deref())).collect::<Vec<_>>(), [("phone", Some("laptop.tail.ts.net"))]);
        assert!(taken(&[], &on_tailnet).is_empty());
    }

    #[test]
    fn a_name_is_a_files_name_and_nothing_else() {
        assert!(named("iPhone-2").is_ok() && named("a.b_c").is_ok());
        for bad in ["", "../x", ".hidden", "a/b", "a b", "é", "-x", "---iPhone", "con", "NUL.x", "com1", "LPT9"] { assert!(named(bad).is_err(), "{bad}"); }
        assert!(named("console").is_ok() && named("com10").is_ok());
        assert!(named("con").unwrap_err().contains("Windows") && named(&"a".repeat(64)).unwrap_err().contains("63") && named("-x").unwrap_err().contains("--as"));
    }

    #[test]
    fn a_file_is_put_in_place_whole_and_never_over_another() {
        let path = folder().unwrap().join(format!("whole-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        own_whole(&path, b"first").unwrap();
        assert_eq!(own_whole(&path, b"second").unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        // Nothing of the writing is left beside it.
        assert!(!path.with_extension(format!("{}.tmp", std::process::id())).exists());
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn one_name_is_one_file_and_under_a_passphrase_it_is_sealed() {
        let name = format!("both-{}", std::process::id());
        let saved = Saved { v: 1, name: name.clone(), ip: "100.64.0.10".into(), port: 49152, pairing: "<plist>a key</plist>".into(), signer: None };
        let sealed = save(&saved, Some("correct horse")).unwrap();
        assert!(sealed.extension().is_some_and(|e| e == "age"));
        let file = std::fs::read(&sealed).unwrap();
        assert!(file.starts_with(b"age-encryption.org") && !file.windows(5).any(|w| w == b"a key"));
        assert_eq!(crate::secret::opened(&file, "correct horse").unwrap(), serde_json::to_vec_pretty(&saved).unwrap());
        // Saved already, either way: not saved again, and what is there stays.
        for passphrase in [None, Some("another")] { assert!(save(&saved, passphrase).err().unwrap().contains("saved here already")); }
        assert_eq!(std::fs::read(&sealed).unwrap(), file);
        assert!(!sealed.with_extension("json").exists());
        std::fs::remove_file(&sealed).unwrap();
        // A name as long as a name can be is one.
        assert!(named(&"a".repeat(63)).is_ok());
    }

    #[test]
    fn two_devices_paired_by_one_machine_are_each_signed_for_with_their_own_key() {
        let pairing = |key: u8| {
            let mut list = plist::Dictionary::new();
            list.insert("identifier".into(), "0F0E0D0C-0B0A-4908-8706-050403020100".into());
            list.insert("private_key".into(), plist::Value::Data(vec![key; 32]));
            let mut out = Vec::new();
            plist::Value::Dictionary(list).to_writer_xml(&mut out).unwrap();
            String::from_utf8(out).unwrap()
        };
        // Names of this run's own: the folder is every run's.
        let (phone, pad, far) = (format!("keys-phone-{}", std::process::id()), format!("keys-pad-{}", std::process::id()), format!("keys-far-{}", std::process::id()));
        for (name, key) in [(&phone, 1), (&pad, 2)] {
            save(&Saved { v: 1, name: name.into(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(key), signer: None }, None).unwrap();
        }
        let (keys, told, marks) = keys(&[phone.clone(), pad.clone()]).unwrap();
        assert_eq!((keys[&phone].1.to_bytes(), keys[&pad].1.to_bytes()), ([1; 32], [2; 32]));
        assert!(super::keys(&[phone.to_uppercase()]).is_err());
        // What the other machine is told has neither key in it.
        assert!(told.iter().all(|saved| crate::sign::key(&saved.pairing).is_some_and(|(_, key)| ![[1; 32], [2; 32]].contains(&key.to_bytes()))));
        // One whose key is elsewhere isn't signed with, and is listed as that.
        save(&Saved { v: 1, name: far.clone(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(3), signer: Some("laptop".into()) }, None).unwrap();
        assert!(super::keys(std::slice::from_ref(&far)).is_err());
        assert_eq!(signer_of(&far).as_deref(), Some("laptop"));
        assert_eq!(signer_of(&phone), None);
        // A key others can read isn't used.
        #[cfg(unix)]
        {
            let file = folder().unwrap().join(format!("{pad}.json"));
            std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o644)).unwrap();
            assert!(super::keys(std::slice::from_ref(&pad)).err().unwrap().contains("read by others"));
            std::fs::set_permissions(&file, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
        }
        // A file under another name than its own (renamed, or found by a name that differs by case) isn't that device.
        let renamed = format!("{phone}-renamed");
        std::fs::copy(folder().unwrap().join(format!("{phone}.json")), folder().unwrap().join(format!("{renamed}.json"))).unwrap();
        assert!(load(&renamed).err().unwrap().contains("is saved here as"));
        std::fs::remove_file(folder().unwrap().join(format!("{renamed}.json"))).unwrap();
        // Removed, and another saved under its name — as long, and at the same moment for all a clock says: not the file that was read.
        assert_eq!(mark(&phone).as_ref(), Some(&marks[&phone]));
        let file = folder().unwrap().join(format!("{phone}.json"));
        std::fs::remove_file(&file).unwrap();
        assert_eq!(mark(&phone), None);
        save(&Saved { v: 1, name: phone.clone(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(9), signer: None }, None).unwrap();
        assert_eq!(std::fs::metadata(&file).unwrap().len() as usize, marks[&phone].len());
        assert_ne!(mark(&phone).as_ref(), Some(&marks[&phone]));
        for name in [&phone, &pad, &far] { std::fs::remove_file(folder().unwrap().join(format!("{name}.json"))).unwrap(); }
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
