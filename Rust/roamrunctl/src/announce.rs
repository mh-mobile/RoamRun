//! The offer's record on this LAN, and the device's own, through mdns-sd.

use mdns_sd::{IfKind, ResolvedService, ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::{BTreeMap, HashMap};
use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

pub const DEVICE_SERVICE: &str = "_remotepairing._tcp.local.";

pub struct Announcement {
    daemon: ServiceDaemon,
    fullname: String,
}

/// A stand-in's host name, under `.roamrun.local` like RoamRun's own.
pub fn host(identifier: &str) -> String {
    format!("rr-intro-{}.roamrun.local.", identifier.chars().take(8).collect::<String>().to_lowercase())
}

/// Announces `txt` as `identifier` of `service_type`, on the interface that has `local` alone.
pub fn start(service_type: &str, identifier: &str, local: Ipv4Addr, port: u16, txt: &BTreeMap<String, String>) -> Result<Announcement, String> {
    let daemon = ServiceDaemon::new().map_err(|e| format!("mDNS couldn't start ({e})"))?;
    // _remotepairing-pairable-host is 28 bytes; the RFC 6763 default cap is 15.
    daemon.set_service_name_len_max(30).map_err(|e| e.to_string())?;
    daemon.disable_interface(IfKind::All).map_err(|e| e.to_string())?;
    daemon.enable_interface(IfKind::Addr(IpAddr::V4(local))).map_err(|e| e.to_string())?;
    let properties: HashMap<String, String> = txt.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let info = ServiceInfo::new(service_type, identifier, &host(identifier), IpAddr::V4(local), port, properties)
        .map_err(|e| format!("the record couldn't be made ({e})"))?;
    let fullname = info.get_fullname().to_string();
    daemon.register(info).map_err(|e| format!("the record couldn't be announced ({e})"))?;
    Ok(Announcement { daemon, fullname })
}

impl Announcement {
    pub fn fullname(&self) -> &str {
        &self.fullname
    }

    /// Resolved services of a type as they come; a fresh call sends the query again.
    pub fn browse(&self, service_type: &str) -> Result<mdns_sd::Receiver<ServiceEvent>, String> {
        self.daemon.browse(service_type).map_err(|e| e.to_string())
    }

    /// Takes the record off the LAN and waits for its goodbye: without that it would linger for
    /// its TTL (75 minutes) and the device would go on offering to pair with it.
    pub async fn unregister(&self) -> bool {
        let Ok(done) = self.daemon.unregister(&self.fullname) else { return false };
        let ok = tokio::time::timeout(Duration::from_secs(3), done.recv_async()).await.is_ok();
        // mdns-sd answers after the first goodbye and repeats it 120 ms later; a shutdown before that drops the repeat.
        tokio::time::sleep(Duration::from_millis(250)).await;
        ok
    }

    pub async fn shutdown(self) {
        if let Ok(done) = self.daemon.shutdown() {
            let _ = tokio::time::timeout(Duration::from_secs(3), done.recv_async()).await;
        }
    }
}

/// The device's own announcement, looked for on the interface that has `local`, for as long as
/// `within`: its host's first label, its port and the TXT keys a line needs. For device control,
/// where the far Mac asks which device it is before it offers anything.
pub fn find_device(local: Ipv4Addr, lan: Ipv4Addr, keys: &[&str], within: Duration) -> Option<(String, u16, BTreeMap<String, String>)> {
    let daemon = ServiceDaemon::new().ok()?;
    daemon.disable_interface(IfKind::All).ok()?;
    daemon.enable_interface(IfKind::Addr(IpAddr::V4(local))).ok()?;
    let rx = daemon.browse(DEVICE_SERVICE).ok()?;
    let until = std::time::Instant::now() + within;
    let mut found = None;
    while found.is_none() {
        let Some(left) = until.checked_duration_since(std::time::Instant::now()).filter(|d| !d.is_zero()) else { break };
        match rx.recv_timeout(left) {
            Ok(ServiceEvent::ServiceResolved(service)) => {
                found = device_among(std::iter::once(&*service), lan, keys)
                    .map(|(s, txt)| (s.host.split('.').next().unwrap_or_default().to_string(), s.port, txt));
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let _ = daemon.shutdown();
    found
}

/// Of the services seen, the one the device at `lan` announces, with the TXT keys a line needs.
pub fn device_among<'a>(seen: impl Iterator<Item = &'a ResolvedService>, lan: Ipv4Addr, keys: &[&str]) -> Option<(&'a ResolvedService, BTreeMap<String, String>)> {
    seen.filter(|s| s.get_addresses_v4().contains(&lan)).find_map(|s| {
        let txt: BTreeMap<String, String> =
            keys.iter().filter_map(|k| s.get_property_val_str(k).map(|v| (k.to_string(), v.to_string()))).collect();
        (txt.len() == keys.len()).then_some((s, txt))
    })
}
