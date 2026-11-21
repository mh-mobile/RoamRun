# Limitations and known issues

<p align="center">English | <a href="troubleshooting.ja.md">日本語</a></p>

What to check when something doesn't work, and the limits known so far.

When in trouble, run `roamrun doctor` first.

## What it rests on

- **RoamRun depends on Apple's private protocols**: how CoreDevice and RemotePairing have behaved
  since iOS 17. A new iOS, macOS or Xcode may break it. When in trouble, run `roamrun doctor`
  first.
- **The device must be on a Wi-Fi to connect**, and stay awake: when the device sleeps, Tailscale
  on it pauses too. While debugging, keep it unlocked with its screen on.
- **The bridge uses one network interface**: en0, or another en* port when en0 has no address,
  unless you choose one under Open RoamRun › Settings › Network. On a Mac that reaches its LAN
  through Ethernet, choose that.
- **Introducing a far Mac needs iOS 27 and Xcode 27**, and rests on how they pair. An update of
  either may need an update of RoamRun.

## Security and privacy

- **While bridging, RoamRun advertises the device's Bonjour identifiers on that interface's
  network.** These values are fixed, so someone on the same network could notice the device's
  presence — also on a network a laptop joins while bridging, such as a café's. The relay drops any
  connection that does not come from this Mac.
- **Other members of your tailnet can reach the device's pairing port.** Pairing verification
  rejects them, but on a shared tailnet, restrict access with Tailscale's rules.
- **If another Mac is on the same network**, the device may briefly show up in that Mac's Xcode
  too. The relay refuses that Mac's connections.
- **Seeing or operating the device runs a screen-sharing session on it**, which lasts until about
  five seconds after the last look or action.

## Known problems

- **If macOS blocks RoamRun's local-network access, the device always looks "away"**, and RoamRun
  goes on bridging a device that sits beside it. RoamRun says so in its window, its log,
  `roamrun status` and `roamrun doctor`. Allow RoamRun under System Settings › Privacy & Security ›
  Local Network. If the switch is already on, the permission is stuck. The only way found to clear
  it was to uninstall with `brew uninstall --zap` and install again
  ([#23](https://github.com/mh-mobile/RoamRun/issues/23)). `--zap` deletes the folder
  `~/Library/Application Support/RoamRun`, with your saved devices and device control's pairings in
  it. To keep them: stop the bridges `roamrun up` started, with `-d` or in a terminal
  (`roamrun down <name>`), and quit RoamRun; copy that folder aside; run `brew uninstall --zap --cask roamrun` and install
  again; then put the folder back before you open RoamRun or run `roamrun`. Whether the
  permission stays cleared with the folder put back hasn't been tried, nor whether device control
  then opens its devices as before.
- **Tailscale on iOS has been seen to stop passing traffic** after sleep or a network change while
  it still looks connected ("MagicSock function ReceiveIPv4 is not running"). Turn the VPN off and
  on.
- **A device plugged in over USB can keep a bridged one from becoming Ready.** Unplug it.
- **Xcode's session does not survive the Mac sleeping for minutes.** Run again afterwards.
- **After the device restarts**, its pairing port may have changed: use Find RemotePairing Port on
  the device's page. Xcode has also needed the device on USB once after a restart, to prepare it
  again.
- **If the device's Bonjour record changes** (its identifier or authTag), add the device again on
  the same Wi-Fi.
- **Safari's Web Inspector keeps dropping over the bridge.** Tried over tethering, the device was
  listed under Safari › Develop and a page opened in the inspector, but the connection dropped
  often. The cause wasn't pinned down. macOS's pairing service drops its link to the bridge about
  every 42 seconds and reconnects within half a second, which Xcode's session survives; the log
  showed the inspector active right after one such drop. The try had Web Inspector on in the
  device's Safari settings, and Connect via Network turned on once in the device's submenu of the
  Develop menu, with the device on a cable.

## Not tried

- **Tested with Xcode and `devicectl`.** Flutter and React Native have not been tried
  ([#5](https://github.com/mh-mobile/RoamRun/issues/5)).
