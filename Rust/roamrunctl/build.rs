// `--version` is RoamRun's: one number for the pair that has to go together, kept in Info.plist.
fn main() {
    let plist = std::fs::read_to_string("../../Info.plist").expect("Info.plist at the repository's top");
    let version = plist
        .split("<key>CFBundleShortVersionString</key>")
        .nth(1)
        .and_then(|after| after.split("<string>").nth(1))
        .and_then(|value| value.split("</string>").next())
        .expect("CFBundleShortVersionString in Info.plist");
    println!("cargo:rustc-env=ROAMRUN_VERSION={version}");
    println!("cargo:rerun-if-changed=../../Info.plist");
}
