# Working away from the Mac

<p align="center">English | <a href="away.ja.md">日本語</a></p>

What you need, and how to work, when the device is with you and the Mac is at home.

You can leave the Mac at home and run the whole build-and-try loop from the device in your hand.

**To start a bridge, the device has to be on a Wi-Fi with internet access.** A café's or hotel's Wi-Fi, a
pocket router, or another phone's hotspot all serve. Cellular alone does not, and neither does the
device's own hotspot, since the device is then not on a Wi-Fi itself.

**To keep a session on cellular**, turn on Settings › Network › Keep debugging on cellular. It is
off by default, because with it on every Run uses the device's mobile data. It applies only from
Ready for Xcode, the bridged state. When the device shows "On this Wi‑Fi", Xcode reaches it over the local network, so leaving
home straight onto cellular ends the session. To avoid that, keep the device on a Wi-Fi that
another device makes even at home — a travel router, or a spare phone sharing its connection — so
that RoamRun bridges it from the start.

A new session needs Wi-Fi again, for example after the device restarts. With the setting off,
RoamRun closes the session when the device leaves Wi-Fi and reconnects when it is back.

On a Wi-Fi with a sign-in page, sign in first. Joining a Wi-Fi marked "No Internet Connection" and
sending traffic over cellular did not work when tried. Where a network blocks UDP, Tailscale goes
through its relay servers: that works, more slowly, and `roamrun doctor` shows the path.

Three ways to drive the Mac from the device:

| Method | On the device | Good for |
|---|---|---|
| An AI agent | A feature for driving an agent on your Mac from your phone, such as Claude Code's [Remote Control](https://code.claude.com/docs/en/remote-control.md) or [Codex](https://learn.chatgpt.com/docs/remote-connections) in the ChatGPT app | Asking "build it and run it on my iPhone", looking at the result, and repeating |
| A terminal over SSH | An SSH client and Tailscale | Using `roamrun`, `xcodebuild`, `devicectl` and `lldb` directly |
| The Mac's screen | Screen Sharing or a VNC client, and Tailscale | Xcode's Run and breakpoints in its window |

Away from home, running with the debugger takes longer than at home: attaching lldb takes hundreds
of round trips. With a 600 KB app over tethering it took about a minute with the debugger and
about 4 seconds without. When you don't need breakpoints, turn off "Debug executable" under Edit
Scheme › Run › Info. When you do, turning off "Queue Debugging" (Options) and "Main Thread
Checker" (Diagnostics) there made it faster.

The agent features in the table send your conversation through each service's servers. Check your
company's policy before using them on a work Mac.
