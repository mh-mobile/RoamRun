# What a device plays and hears while it is looked at

A record of one sitting, not a rule. Each `look` and each action runs a screen-sharing session on
the device, kept for about five seconds after the last one. What the device then does with its
sound and its microphone is the device's and each app's own doing; this is what was heard, app by
app, with what wasn't tried.

Listened to on 2026-10-12: an iPhone 15 Pro on iOS 27.0, RoamRun 0.5.0 as released and a build of
0.6.0, over Tailscale, with and without a cable. Each row is one to three runs of a look every two
seconds for 25 to 50 seconds, a person at the device listening. Apps as they were that day.

## What was heard

| What ran on the device | While it was looked at |
|---|---|
| YouTube, Spotify | Went on sounding. |
| Netflix | Went on sounding. Its picture arrived black in a look; the player's controls showed. |
| Apple Music, the Apple TV app | Went on playing, unheard from the first look; heard again by themselves within seconds of the last one. |
| Prime Video | Played for a while, then stopped, saying the device doesn't meet its content protection. |
| Dictation in ChatGPT, switched on during a session | Took nothing, by the iPhone's microphone and by AirPods. |
| A voice conversation in ChatGPT, already running | The device refused the session: the look failed, with "A phone or VoIP call is currently in progress on the device." |

A tap during a session (Netflix's ten seconds forward) didn't interrupt the sound either.

## What was tried to change it

For Apple Music, three other ways of starting the session left it silent all the same: the video
without the audio stream (it does start that way on this iOS), other features said to be supported
(132 for 140), and the stream as [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
11.23.1 starts it. For dictation, the video without the audio stream alone was tried: it still took
nothing. Nothing was found that RoamRun could send differently, so nothing in RoamRun was changed.

Apple's page on Device Hub says as much for the microphone: while it interacts with a device, other
apps [may record silence](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub#Handle-camera-and-microphone-access-conflicts-on-physical-devices).

## Not tried

- Whether Prime Video plays again once the looking stops.
- The system's own dictation keyboard, Siri, a phone call, FaceTime.
- Any other app, another device, another iOS version, an iPad.
- Sound through AirPods or a speaker (only the iPhone's own).

## Seen on the way

- A refusal such as the one above prints as the bytes of its message, not as the sentence.
- A control that hides by itself after a few seconds was pressed only when the tap came right
  after the one that showed it; a tap a moment later showed it again and no more.
