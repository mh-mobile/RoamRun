//! A saved pairing kept under a passphrase (age's passphrase format), and where the passphrase comes from.
//! Never from the command line: that shows in the process list.

use std::io::{IsTerminal, Read, Write};

use age::secrecy::SecretString;

/// A file holding the passphrase alone (a trailing newline isn't part of it).
pub const FILE: &str = "ROAMRUNCTL_PASSPHRASE_FILE";
/// A command, run by `sh -c` (`cmd /C` on Windows), that prints it: a password manager's, a keychain's.
pub const COMMAND: &str = "ROAMRUNCTL_PASSPHRASE_COMMAND";
/// The passphrase itself. The weakest of the three: any process of this user can read it, and children inherit it.
pub const ITSELF: &str = "ROAMRUNCTL_PASSPHRASE";

fn whole(text: String, from: &str) -> Result<String, String> {
    let text = text.strip_suffix('\n').map(|t| t.strip_suffix('\r').unwrap_or(t)).unwrap_or(&text).to_string();
    if text.is_empty() { Err(format!("{from} gave an empty passphrase")) } else { Ok(text) }
}

/// The passphrase as the environment gives it: by file, else by command, else itself. None when it gives none.
pub fn given(get: impl Fn(&str) -> Option<String>) -> Result<Option<String>, String> {
    if let Some(path) = get(FILE) {
        // Without the mark some editors on Windows put first, which nobody could type.
        return whole(std::fs::read_to_string(&path).map_err(|e| format!("{FILE} ({path}): {e}"))?.trim_start_matches('\u{feff}').to_string(), FILE).map(Some);
    }
    if let Some(command) = get(COMMAND) {
        #[cfg(not(windows))]
        let mut shell = { let mut sh = std::process::Command::new("sh"); sh.arg("-c").arg(&command); sh };
        // As it is, inside one pair of quotes that /S takes off: quoted the usual way, cmd wouldn't read its own.
        #[cfg(windows)]
        let mut shell = { let mut cmd = std::process::Command::new("cmd"); std::os::windows::process::CommandExt::raw_arg(cmd.args(["/S", "/C"]), format!("\"{command}\"")); cmd };
        let ran = shell.stderr(std::process::Stdio::inherit()).output()
            .map_err(|e| format!("{COMMAND}: {e}"))?;
        if !ran.status.success() { return Err(format!("{COMMAND} failed ({})", ran.status)); }
        return whole(String::from_utf8(ran.stdout).map_err(|_| format!("{COMMAND} printed what isn't text"))?, COMMAND).map(Some);
    }
    get(ITSELF).map(|text| whole(text, ITSELF)).transpose()
}

/// The passphrase: as the environment gives it, else asked at the terminal (twice when it is a new one).
pub fn passphrase(what: &str, new: bool) -> Result<String, String> {
    if let Some(given) = given(|name| std::env::var(name).ok())? { return Ok(given); }
    if !std::io::stdin().is_terminal() || !std::io::stderr().is_terminal() {
        return Err(format!("{what} is kept under a passphrase, and none is given: set {FILE}, {COMMAND} or {ITSELF} (the weakest), or run this at a terminal"));
    }
    let typed = rpassword::prompt_password(format!("Passphrase for {what}: ")).map_err(|e| e.to_string())?;
    if typed.is_empty() { return Err("an empty passphrase: nothing was done (without --passphrase a pairing is kept as a file only you can read)".into()); }
    if new && rpassword::prompt_password("Once more: ").map_err(|e| e.to_string())? != typed { return Err("the two don't match: nothing was done".into()); }
    Ok(typed)
}

pub fn sealed(plain: &[u8], passphrase: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut writer = age::Encryptor::with_user_passphrase(SecretString::from(passphrase.to_string())).wrap_output(&mut out).map_err(|e| e.to_string())?;
    writer.write_all(plain).and_then(|()| writer.finish().map(|_| ())).map_err(|e| e.to_string())?;
    Ok(out)
}

pub fn opened(sealed: &[u8], passphrase: &str) -> Result<Vec<u8>, String> {
    let identity = age::scrypt::Identity::new(SecretString::from(passphrase.to_string()));
    let mut reader = age::Decryptor::new(sealed).map_err(|e| format!("not a pairing kept under a passphrase: {e}"))?
        .decrypt(std::iter::once(&identity as &dyn age::Identity))
        .map_err(|e| match e { age::DecryptError::DecryptionFailed | age::DecryptError::KeyDecryptionFailed => "the passphrase isn't the one it was kept under".to_string(), other => other.to_string() })?;
    let mut plain = Vec::new();
    reader.read_to_end(&mut plain).map_err(|e| e.to_string())?;
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn what_is_sealed_opens_with_its_passphrase_and_no_other() {
        let sealed = sealed(b"a pairing", "correct horse").unwrap();
        assert!(sealed.starts_with(b"age-encryption.org/v1"));
        assert!(!sealed.windows(9).any(|w| w == b"a pairing"));
        assert_eq!(opened(&sealed, "correct horse").unwrap(), b"a pairing");
        assert_eq!(opened(&sealed, "wrong").unwrap_err(), "the passphrase isn't the one it was kept under");
        assert!(opened(b"{\"v\":1}", "x").is_err());
    }

    #[test]
    fn the_passphrase_comes_by_file_then_command_then_itself() {
        let file = std::env::temp_dir().join(format!("roamrunctl-test-{}", std::process::id()));
        std::fs::write(&file, "from the file\n").unwrap();
        let path = file.to_string_lossy().to_string();
        let env = |pairs: &[(&str, &str)]| { let pairs: Vec<(String, String)> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(); move |name: &str| pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone()) };
        assert_eq!(given(env(&[(FILE, &path), (COMMAND, "echo no"), (ITSELF, "no")])).unwrap().as_deref(), Some("from the file"));
        assert_eq!(given(env(&[(COMMAND, "echo from the command"), (ITSELF, "no")])).unwrap().as_deref(), Some("from the command"));
        assert_eq!(given(env(&[(ITSELF, "itself")])).unwrap().as_deref(), Some("itself"));
        assert_eq!(given(env(&[])).unwrap(), None);
        // One that fails, or gives nothing, is said: not passed over for the next.
        assert!(given(env(&[(COMMAND, "exit 3"), (ITSELF, "x")])).is_err());
        assert!(given(env(&[(FILE, "/nonexistent/roamrunctl"), (ITSELF, "x")])).is_err());
        assert!(given(env(&[(ITSELF, "")])).is_err());
        std::fs::remove_file(file).unwrap();
    }
}
