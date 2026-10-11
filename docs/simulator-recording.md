# Recording a simulator an agent drives, and watching it on an iPhone

Not a RoamRun feature: a way through Xcode 27's own tools and Tailscale, written down as it was
tried. An agent (or a test) works a simulator on a Mac; the screen is recorded as it goes; the
recording is sent to an iPhone over the tailnet and watched there, afterwards.

Tried on Xcode 27.0 with iOS 27.0 simulators (and recording alone on an iOS 18.0 one), sending to an
iPhone on iOS 27 with Tailscale's app. Nothing here is live: see [What doesn't work](#what-doesnt-work).

## The three steps

### 1. Record

```sh
xcrun devicectl device capture screen-record --device <simulator> \
    --destination run.mp4 --codec hevc &
RECORDING=$!
# ... the agent or the test works the simulator here ...
kill -INT $RECORDING; wait $RECORDING
```

- `<simulator>` is a name or UDID from `xcrun devicectl list devices` (simulators are the rows marked
  `simulated`). A simulator booted with `xcrun simctl boot`, with no window anywhere, records too.
- Without `--duration` it records until SIGINT (what Control-C sends) and then closes the file:
  about 0.3 s, exit status 0. `--duration <seconds>` stops by itself.
- The file appears only when the recording ends. Only one recording of a simulator runs at a time
  (a second is refused: "Host recording is already in progress").
- HEVC at the simulator's own size (1206×2622 for an iPhone 17). A frame is written when the screen
  changes, so size follows movement: 0.4 to 0.7 Mbps for a mostly still app, 4 to 5 Mbps for maps,
  web pages or a moving 3D scene (one of each). A still screen costs next to nothing.

### 2. Operate, through Xcode's MCP server

`xcrun mcpbridge` speaks the Model Context Protocol on stdin and stdout, and passes tool calls to
Xcode. Three of its tools work a simulator:

| Tool | What it does |
|---|---|
| `DeviceInteractionStartSession` | Takes `deviceIdentifier` and a `sessionIdentifier` of your choosing; boots the simulator if need be. The key it returns is that `sessionIdentifier`. |
| `DeviceInteractionSynthesize` | Takes `interactSessionKey`, and optionally `interactionCommand` and `activationBundleId`. Does the command, then returns paths to a screenshot and to a text file of the screen's elements with a `hitPoint` each. With no command it only looks. |
| `DeviceInteractionEndSession` | Takes `interactionSessionKey`. Call it when done: an open session costs. |

Commands that were tried, in points (a 1206×2622 screen is 402×874 points):

| Command | Does |
|---|---|
| `t 200 436` | tap |
| `t 320 436 f 80 436 0.4` | swipe, here to the left over 0.4 s |
| `d 200 436` | double tap |
| `w 2.5` | wait; chains after another command, as in `t 200 436 w 3` |

The session outlives the `mcpbridge` process that opened it: a later process uses it by its key.
Recording and operating run side by side.

Before any of this works:

- Xcode › Settings › Intelligence › Model Context Protocol: allow external agents to use Xcode's tools
  (where the setting is said to be; whether it was already on here wasn't looked at).
- The first tool call has to be `XcodeOpenWorkspace` (or `XcodeNewProject`): that is what makes Xcode
  ask its user to approve the agent, along with access to that project's folder. Any project does,
  a throwaway one included. Until then every other tool answers that the agent isn't approved.
- The app has to be on the simulator already (`xcrun simctl install`), or use
  `DeviceInteractionStartWorkspaceSession` and `DeviceInteractionInstallAndRun`, which build it
  (not tried here).

What to know about where to tap:

- Use the `hitPoint` of an element from the element file when it has one.
- A system alert (the photo library's permission sheet, for one) isn't in the element file. Its
  buttons were tapped at positions read off the screenshot.
- Inside a 3D view there are no elements either: positions come from the screenshot. Taps and swipes
  reach it all the same. (One app's RealityKit view is all this was tried on: SceneKit, or Metal
  drawn directly, may differ.)
- An app built for a much older iOS and installed on an iOS 27 simulator reported its elements as if
  on a 320×480 screen, so its `hitPoint`s missed, and its 3D view drew wrong and took no taps (one
  app, once). Build for the simulator you operate.
- Only iOS 27 simulators were offered as devices to start a session with; an iOS 18.0 one was refused.

### 3. Send

```sh
tailscale file cp run.mp4 <the iPhone's name on the tailnet>:
```

The iPhone shows a notification (or the file waits in Tailscale's app); saved to Files, it plays as it
is: `hvc1`, no conversion. 2 MB went in one to two seconds, 19 MB in 14 to 22 s (the slower of those
over a direct connection on one Wi‑Fi).

## What doesn't work

- **Live video.** The recording can't be read while it is being made, and recording in short pieces
  one after another loses 0.4 to 1.7 s at each join (a piece takes that much longer than its
  `--duration`). `devicectl device capture screenshot` takes about half a second a picture.
- **A physical device.** `screen-record` answers "The capability “Screen Recording” is not supported
  by this device" for an iPhone on iOS 27; this page is about simulators only.
- **`xcrun simctl privacy <simulator> grant photos <bundle id>`** didn't get an app past its own
  "allow access" screen on an iOS 18.0 simulator. On iOS 27 the permission sheet was tapped instead.

Not tried: typing (`sender keyboard kbd <text>`), recordings of ten minutes and more, an iPad or
another platform's simulator, and `xcrun mcp-server`, the form that runs without Xcode open.
