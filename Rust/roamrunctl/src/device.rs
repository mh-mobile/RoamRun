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

}

#[derive(Subcommand)]
pub enum Key {
    /// Save the device and the pairing of a file `roamrun key create` wrote; the file is removed
    Import {
        file: PathBuf,
        /// The name to save it under here
        #[arg(long = "as")]
        name: Option<String>,
        /// Keep it under a passphrase (typed here, or given as the README says), not as a file only its owner can read
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
    // Not led by what a command reads as an option, or hides as a file.
    let fits = !name.is_empty() && name.len() <= 63 && !name.starts_with(['.', '-'])
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
    let Some((path, sealed)) = kept(name)? else {
        // Not saved here: one another machine keeps the key of, and signs for this one.
        return offered()?.into_iter().find(|saved| saved.name == name).ok_or_else(|| format!(
            "no device “{name}” is saved here, and no machine was found that signs for this one with it.\n{}", sign_how(name)));
    };
    let meta = std::fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    // The file is a key: as ssh does, one that others can read isn't used.
    if let Some(mode) = open_to_others(&meta) {
        return Err(format!("{} can be read by others (mode {mode:o}): `chmod 600` it, or pair again", path.display()));
    }
    let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let bytes = if sealed { crate::secret::opened(&bytes, &crate::secret::passphrase(name, false)?).map_err(|why| format!("{name}: {why}"))? } else { bytes };
    serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// How a machine that keeps a key comes to sign for this one, and how this one finds it.
fn sign_how(name: &str) -> String {
    let me = crate::tailscale::status().map(|status| crate::tailscale::short(&status.this.dns_name).to_string()).unwrap_or_else(|_| "<this machine>".into());
    format!("On the machine that keeps its key: roamrunctl sign {name} --for {me}\nIt is found where it is this user's own, online, and lets this machine in on TCP port {}; where this machine is tagged or another user's, set {}=<its Tailscale name> here.", crate::sign::PORT, crate::sign::SIGNER)
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

fn import(file: &Path, name: Option<String>, sealed: bool) -> Result<String, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let shared: Shared = serde_json::from_str(&text).map_err(|_| format!("{} isn't a file `roamrun key create` wrote", file.display()))?;
    if shared.version != 1 || shared.pairing.is_empty() || shared.device.ip.parse::<std::net::Ipv4Addr>().is_err() {
        return Err(format!("{} isn't a file `roamrun key create` wrote", file.display()));
    }
    let name = name.unwrap_or_else(|| crate::hold::filed(&shared.device.name));
    let saved = Saved { v: 1, name, ip: shared.device.ip, port: shared.device.port.unwrap_or(PORTS.start), pairing: shared.pairing, signer: None };
    named(&saved.name)?;
    if kept(&saved.name)?.is_some() {
        return Err(format!("a device “{}” is saved here already: `roamrunctl devices remove {}` first, or --as another name", saved.name, saved.name));
    }
    // Tried before it is kept, and the file goes only once it is: a key that doesn't open the device isn't one.
    open(&saved)?;
    let passphrase = if sealed { Some(crate::secret::passphrase(&saved.name, true)?) } else { None };
    let path = save(&saved, passphrase.as_deref())?;
    std::fs::remove_file(file).map_err(|e| format!("saved, but {} couldn't be removed ({e}): remove it yourself, it is a key", file.display()))?;
    Ok(match passphrase {
        Some(_) => format!("Saved {} ({}), and it connects. Its pairing is kept under the passphrase, in {}: that keeps the file from being a key on its own, not from whoever has both.", saved.name, saved.ip, path.display()),
        None => format!("Saved {} ({}), and it connects. The key is {}, as it is: whoever can read it and reach the device can see and operate it.", saved.name, saved.ip, path.display()),
    })
}

fn open(saved: &Saved) -> Result<Device, String> {
    let answers = |port: u16, within: u64| format!("{}:{port}", saved.ip).parse::<SocketAddr>().is_ok_and(|at| TcpStream::connect_timeout(&at, Duration::from_millis(within)).is_ok());
    // The port it was saved with is given the time a device that slept takes; the others are asked together.
    let ports: Vec<u16> = if answers(saved.port, 2500) { vec![saved.port] } else {
        std::thread::scope(|all| PORTS.map(|p| all.spawn(move || answers(p, 1500).then_some(p))).collect::<Vec<_>>().into_iter().filter_map(|one| one.join().ok().flatten()).collect())
    };
    // Whatever answers on one of them needn't be the pairing: the next is tried.
    let mut last = Err(format!("{} ({}) doesn't answer: is it on Wi‑Fi, unlocked once since it started, and connected in Tailscale? (on cellular alone it refuses) If it restarted since it was saved, its pairing port may have moved out of reach: pair again", saved.name, saved.ip));
    for port in ports {
        last = open_at(saved, port);
        if last.is_ok() { break }
    }
    last
}

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
/// An error only where the machine `ROAMRUNCTL_SIGNER` names isn't one: said, not taken for none signing.
fn offered() -> Result<Vec<Saved>, String> {
    if cfg!(test) { return Ok(Vec::new()) }
    let Ok(status) = crate::tailscale::status() else { return Ok(Vec::new()) };
    let on_tailnet: std::collections::HashSet<&str> = status.peers.values().flat_map(|p| p.ips.iter().map(String::as_str)).collect();
    let said = crate::sign::signers(&status, std::env::var(crate::sign::SIGNER).ok().filter(|s| !s.is_empty()))?;
    Ok(taken(&said, &on_tailnet))
}

/// What a saved device's file is, to tell it later from another saved under its name.
type Mark = (PathBuf, std::time::SystemTime, u64);

fn mark(name: &str) -> Option<Mark> {
    let (path, _) = kept(name).ok()??;
    let meta = std::fs::metadata(&path).ok()?;
    Some((path, meta.modified().ok()?, meta.len()))
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
type Signing = (crate::sign::Keys, Vec<Saved>, std::collections::HashMap<String, Mark>);

fn keys(names: &[String]) -> Result<Signing, String> {
    if names.is_empty() {
        let saved: Vec<String> = self::names_here()?.into_iter().filter(|name| matches!(kept(name), Ok(Some(_)))).collect();
        return Err(format!("which devices: roamrunctl sign <name>… --for <machine>   (saved here: {})", if saved.is_empty() { "none".to_string() } else { saved.join(", ") }));
    }
    let (mut keys, mut told, mut marks) = (crate::sign::Keys::new(), Vec::new(), std::collections::HashMap::new());
    for name in names {
        if kept(name)?.is_none() { return Err(format!("no device “{name}” is saved here: `roamrunctl devices` lists them")); }
        let saved = load(name)?;
        let (identifier, key) = crate::sign::key(&saved.pairing).filter(|_| saved.signer.is_none())
            .ok_or_else(|| format!("{name}'s key isn't kept here: there is nothing to sign with"))?;
        // The other machine asks by the name it is told: the file's, which is this one unless it was renamed by hand.
        if saved.name != *name { return Err(format!("“{name}” is saved here as “{}”: name it so", saved.name)); }
        marks.insert(name.clone(), mark(name).ok_or_else(|| format!("{name} went away just now"))?);
        keys.insert(name.clone(), (identifier, key));
        told.push(bare(saved)?);
    }
    Ok((keys, told, marks))
}

/// The device named, opened. One another machine signs for is saved here the first time it opens, without
/// its key: from then on only that machine is asked, and only that device is taken for it.
pub fn opened(name: &str) -> Result<Device, String> {
    let here = kept(name)?.is_some();
    let saved = load(name)?;
    let device = open(&saved)?;
    if !here {
        let said = match save(&saved, None) {
            Ok(path) => format!("{name} is used for the first time here: {} signs for it, and that is held to from now on ({}). `roamrunctl devices remove {name}` forgets it.", saved.signer.as_deref().unwrap_or("another machine"), path.display()),
            // Another command saved it meanwhile: held to all the same.
            Err(_) if kept(name).is_ok_and(|kept| kept.is_some()) => return Ok(device),
            Err(why) => format!("{name} is open, but which machine signs for it couldn't be saved ({why}): it is asked for anew next time"),
        };
        let _ = writeln!(std::io::stderr(), "roamrunctl: {said}");
    }
    Ok(device)
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
    names.extend(offered()?.into_iter().map(|saved| saved.name));
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

fn look(name: &str, file: Option<PathBuf>) -> Result<String, String> {
    let device = opened(name)?;
    let (png, width, height) = fitted(&device.screenshot()?, image::ImageFormat::Png)?;
    let path = file.unwrap_or_else(|| std::env::temp_dir().join(format!("roamrunctl-{}-{}.png", named(name).unwrap_or("device"), std::process::id())));
    // Whatever is on the screen is in it: the owner's only.
    let _ = std::fs::remove_file(&path);
    let mut out = own_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    out.write_all(&png).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("{}\n{width} x {height}", path.display()))
}

pub fn list() -> Result<String, String> {
    let (names, offered) = (names_here()?, offered()?);
    if names.is_empty() && offered.is_empty() {
        return Ok(format!("No device is saved here, and no machine was found that signs for this one.\nTo pair with one: roamrunctl pair control --to <device> (on its Wi‑Fi), or --with <a machine on its Wi‑Fi>.\nTo use one whose key another machine keeps:\n{}", sign_how("<device>")));
    }
    // Named only: what else is saved of one may be under a passphrase, which a list doesn't ask for.
    Ok(names.iter().map(|name| match (kept(name), signer_of(name)) {
        (_, Some(signer)) => format!("{name}\tits key is kept by {signer}, which signs for this machine"),
        (Ok(Some((_, true))), _) => format!("{name}\tunder a passphrase"),
        _ => format!("{name}\tas it is"),
    }).chain(offered.iter().filter(|saved| !names.contains(&saved.name)).map(|saved| {
        format!("{}\tits key is kept by {}, which signs for this machine (not used here yet)", saved.name, saved.signer.as_deref().unwrap_or("another machine"))
    })).collect::<Vec<_>>().join("\n"))
}

pub fn run(command: Command) -> i32 {
    let done = match command {
        Command::Devices { command: None } => list(),
        Command::Devices { command: Some(Devices::Remove { name }) } => named(&name).and_then(|name| {
            let signer = signer_of(name);
            if kept(name)?.is_none() {
                return Err(match offered().unwrap_or_default().into_iter().find(|saved| saved.name == name) {
                    Some(saved) => format!("{name} isn't saved here: {} offers it. It goes when `roamrunctl sign` ends there, or the device is removed there", saved.signer.as_deref().unwrap_or("another machine")),
                    None => format!("no device “{name}” here"),
                });
            }
            while let Some((path, _)) = kept(name)? { std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?; }
            Ok(match signer {
                Some(signer) => format!("Forgot {name} here. Its key is kept by {signer}: it is asked again the next time {name} is used, for as long as `roamrunctl sign` there names it."),
                None => format!("Removed {name} and its pairing here: a `roamrunctl sign` running here signs for it no more. On the device, remove this machine in its list too (Settings › Privacy & Security › Developer Mode)."),
            })
        }),
        Command::Key { command: Key::Import { file, name, passphrase } } => import(&file, name, passphrase),
        Command::Look { name, file } => look(&name, file),
        Command::Install { name, path } => opened(&name).and_then(|device| {
            said(device.install(&path.to_string_lossy())).map(|_| format!("Installed {} on {name}.", path.display()))
        }),
        Command::Launch { name, bundle } => opened(&name).and_then(|device| {
            said(device.launch(&bundle)).map(|value| format!("Launched {bundle} on {name} (pid {}).", value["pid"]))
        }),
        Command::Mcp => return crate::mcp::Server::default().serve(),
        Command::Sign { names, machine } => keys(&names).and_then(|(keys, told, marks)| {
            // The file it was read from, still: not another saved under the name since.
            let held = |name: &str| marks.get(name).is_some_and(|was| mark(name).as_ref() == Some(was));
            let list = |held: crate::sign::Held| serde_json::to_string(&told.iter().filter(|saved| held(&saved.name)).collect::<Vec<_>>()).unwrap_or_else(|_| "[]".into());
            crate::sign::serve(&machine, keys, &list, &held)
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
        for bad in ["", "../x", ".hidden", "a/b", "a b", "é", "-x", "---iPhone"] { assert!(named(bad).is_err(), "{bad}"); }
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
        for (name, key) in [("keys-phone", 1), ("keys-pad", 2)] {
            let _ = std::fs::remove_file(folder().unwrap().join(format!("{name}.json")));
            save(&Saved { v: 1, name: name.into(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(key), signer: None }, None).unwrap();
        }
        let (keys, told, marks) = keys(&["keys-phone".to_string(), "keys-pad".to_string()]).unwrap();
        assert_eq!((keys["keys-phone"].1.to_bytes(), keys["keys-pad"].1.to_bytes()), ([1; 32], [2; 32]));
        // What the other machine is told has neither key in it.
        assert!(told.iter().all(|saved| crate::sign::key(&saved.pairing).is_some_and(|(_, key)| ![[1; 32], [2; 32]].contains(&key.to_bytes()))));
        // One whose key is elsewhere isn't signed with, and is listed as that.
        let _ = std::fs::remove_file(folder().unwrap().join("keys-far.json"));
        save(&Saved { v: 1, name: "keys-far".into(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(3), signer: Some("laptop".into()) }, None).unwrap();
        assert!(super::keys(&["keys-far".to_string()]).is_err());
        assert_eq!(signer_of("keys-far").as_deref(), Some("laptop"));
        assert_eq!(signer_of("keys-phone"), None);
        // Removed, and another saved under its name: not the file that was read.
        assert_eq!(mark("keys-phone").as_ref(), Some(&marks["keys-phone"]));
        std::fs::remove_file(folder().unwrap().join("keys-phone.json")).unwrap();
        assert_eq!(mark("keys-phone"), None);
        std::thread::sleep(Duration::from_millis(20));
        save(&Saved { v: 1, name: "keys-phone".into(), ip: "100.64.0.10".into(), port: 49152, pairing: pairing(9), signer: None }, None).unwrap();
        assert_ne!(mark("keys-phone").as_ref(), Some(&marks["keys-phone"]));
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
