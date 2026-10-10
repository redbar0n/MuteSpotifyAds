# Bringing Mutefy's Windows features to macOS

Written while doing it, August 2026. The point of this document is to record *why* two thirds
of the Windows implementation did not come across, so nobody later assumes it was lost by
accident.

## The short version

The Windows build of Mutefy is about 4,000 lines. Roughly 1,000 of those exist solely to work
around things Windows does not give you and macOS does. They were not ported because on macOS
they would be dead code.

| Windows source | Lines | macOS equivalent |
|---|---:|---|
| `SmtcProbe.cs` — pick Spotify's SMTC session, subscribe, poll | 224 | `get spotify url of current track` |
| `SpotifyMuter.cs` — Core Audio, mute every session owned by a Spotify PID | 197 | `set sound volume to 0` |
| `FadeSampleProvider.cs` — raised-cosine fade, hand-written | 172 | `AVAudioPlayer.setVolume(_:fadeDuration:)` |
| `AdClassifier.cs` + `AdSignature.cs` — localised string tables, tray-taught rules | 208 | not needed |
| `WindowTitleProbe.cs` + `ProbeMerger.cs` — compensate for SMTC lag | 187 | not needed |
| `SpotifyPaths.cs` — MSIX vs classic install layout | 101 | one fixed path |

### Why detection collapses to one line

Windows has no way to ask Spotify "is this an ad?". The Windows build infers it, and the
inference is fragile enough to need a tray menu for teaching it new ad strings when it guesses
wrong. On a Korean free account the ad arrives as
`title='광고 없이 음악을 감상하세요.' artist='Spotify' album=''`, so title matching is useless and
`artist == "Spotify"` ends up load-bearing.

macOS just tells you. `spotify url of current track` returns `spotify:ad:<hex>` during an ad and
`spotify:track:<id>` otherwise. Exact, unlocalised, no heuristics.

Worth noting: the same ad on macOS reports **`artist` as an empty string**, not `"Spotify"`. Had
the port carried the Windows string tables across, they would have silently failed here. That is
a good argument for having deleted them rather than kept them "just in case".

### Why the filler needed no plumbing

On Windows, muting Spotify means muting its Core Audio sessions. Filler music playing through
the same device would be fine, but getting the separation right required giving the filler its
own dedicated `WasapiOut` session, and verifying in the volume mixer after every change that
the two had not merged.

On macOS, Mutefy lowers **Spotify's own volume**, a property of the Spotify application. Nothing
else on the machine is touched. The filler is simply a separate `AVAudioPlayer` and the
separation is free.

### Why the fade shrank

`FadeSampleProvider.cs` exists because NAudio's built-in fade is linear and audibly wrong, and
because tearing down a `WasapiOut` mid-fade cuts the tail off — the Windows build measures
1424 ms of real teardown for a 1200 ms fade and waits for the render thread to actually finish.

`AVAudioPlayer.setVolume(_:fadeDuration:)` does the fade natively. Stop after the duration plus
a small tail and you are done.

## What was ported

Two things, both because they were learned the hard way on Windows and neither exists in the
macOS app this forks from:

**`AdStateMachine.swift`** — entry debounce and safety ceiling, transliterated from
`AdStateMachine.cs`. Both projects are GPL-3.0, so this is a straight port rather than a
reimplementation.

**`FillerPlayer.swift`** — the *behaviour* of `FillerPlayer.cs`: shuffle bag, folder
cache (now 600 seconds on macOS), start delay, auto-advance when a track ends before the ad does, and cancelling a
fade-out if a second ad starts during it. The implementation is new because the audio stack is.

The tuned constants came across unchanged, since they were chosen by listening: filler volume
60%, fade in 400 ms, fade out 1200 ms, start delay 250 ms.

## What was measured on this Mac

MacBook Air (M1), macOS 26.5, Spotify desktop, Korean free account, 1 August 2026.

**A full ad break, from the probe:**

```
18:13:30  spotify:ad:0bd1c59f…  dur=28107  name='광고 없이 음악을 감상하세요.' artist='' album=''
18:13:58  spotify:ad:c23f6917…  dur=26174  name='광고 없이 음악을 감상하세요.' artist='' album=''
18:14:26  spotify:track:143Cfw…  — music returns
```

- **Two ads, back to back, 56 seconds total.** This matches the 55 s and 58 s measured on
  Windows, confirming those numbers were whole breaks rather than single ads. A 90-second
  safety ceiling would be uncomfortably close; the default is 180.
- **No gap between the ads.** `player state` never leaves `playing`. The Android build needed a
  `PauseHold` to survive a 1.3-second silence between ads; macOS does not, so it was not built.
- Each ad has its own `spotify:ad:` URL, so they are individually distinguishable.
- `duration` is reported and accurate. Windows has no equivalent.

**Volume behaviour:**

- Spotify stores volume with a little loss. Setting 94 reads back 93; setting 90 reads back 89.
  Any read-back check has to tolerate this, hence the ±2 window in `setSpotifyVolume`.
- Writes are not reordered: setting 0 then 90 lands on 90 and stays there across at least 7
  seconds, over three trials.
- **Spotify does not touch its own `sound volume` during an ad.** Verified by running a full ad
  break with Mutefy stopped: volume held at 69 across both ads.

That last control was run because an ad was once observed starting with the volume already at 0
and no Mutefy log line accounting for it. The control ruled out Spotify, other installed apps
(`MuteSpotifyAds.app` and `SpoticaMenu.app` are present on this machine but were not running)
and write reordering. It was never reproduced, and is most likely a leftover from the test
sequence that preceded it. `setSpotifyVolume` now verifies its own writes so that if it does
recur, the log will say so instead of leaving it to inference.

## What the first live ad break found

Everything built cleanly, the unit tests passed, and the mute/unmute path worked on the very
first real ad:

```
18:51:37.354  reading: ad (url=spotify:ad:4b890bfb… volume=84)
18:51:37.960  AD START — muted Spotify (was 84)
18:52:28.587  filler: playing '02 Quiet Town.mp3' at 60%
18:52:32.908  reading: notAd (url=spotify:track:4yNK2ybB… volume=0)
18:52:33.253  AD END — restored Spotify volume to 84
18:52:33.253  filler: fading out over 1200ms
18:52:34.567  filler: stopped '02 Quiet Town.mp3'
```

The filler arrived **50.6 seconds into a 55.5-second break**. It faded in, played for four
seconds, and faded out. No test would have caught this: the code was correct, the fade was
correct, the ordering was correct, and the feature was useless.

The cause was a full recursive folder walk sitting between "ad detected" and "sound comes out".
On `~/Music` with an Apple Music library that walk took **over two minutes** from cold —
`nextObject()` spends its time in `open()` per directory, a few entries per second. The
60-second cache made it worse, not better: it expired before it could ever be used, so every
ad paid the cost again.

Two things about that folder are worth recording, because they cost time to work out:

- **A remote shell and the GUI app see different trees.** Enumerating `~/Music` over SSH found
  3 playable files in 0.3 seconds; the app found 18. The Apple Music library under
  `~/Music/Music` is TCC-protected, and an SSH session without Full Disk Access silently gets
  a smaller tree rather than an error. A file appearing in the app's log that "does not exist"
  according to a remote `find` is the signature of this.
- **A bounded loop needs its bound checked on the right axis.** The first attempt at a
  20-second scan limit checked the clock every 256 entries. With entries this slow, that let
  the "20 second" limit run for minutes. It now checks every entry, which is free next to the
  I/O.

## An observation that was never reproduced

Once, an ad was seen starting with Spotify's volume already at 0 and no Mutefy log line
accounting for it. Ruled out by experiment: no other app was running (`MuteSpotifyAds.app` and
`SpoticaMenu.app` are installed on this machine but were not); Spotify does not zero its own
volume during an ad (a full break ran with Mutefy stopped and the volume held at 69); and
volume writes are not reordered (0 then 90 lands on 90 and stays, across three trials).

It is most likely a leftover from the test sequence immediately before it. `setSpotifyVolume`
now reads back and logs a genuine disagreement, so a recurrence will be recorded rather than
inferred.

## Verification

`swift test` covers the state machine against a synthetic clock — 11 cases including a replay of
the measured 56-second break at the real 500 ms poll rate, checking the ceiling does not trip.
That is the only part testable without a Mac, Spotify and a free account.

Everything else is checked by reading `~/Library/Logs/Mutefy/mutefy.log` while a real ad plays.
The log exists precisely because the failures that matter here are silent: "the volume stayed at
zero" and "the filler never started" produce no crash and no visible symptom to anyone not
listening at the time.

## What was deliberately left out

| | |
|---|---|
| Tray-taught ad strings | `spotify:ad:` is exact. There is nothing to teach. |
| Window-title lead compensation | A Windows-only artefact of SMTC lag. |
| Notarization | Needs a paid Apple Developer account. Ad-hoc signing is enough for personal use. |
| Renaming the Xcode target | The product, bundle ID and Swift module are `Mutefy`; the target and folder are still `MuteSpotifyAds`. Renaming a target by hand-editing `project.pbxproj` risks more than it gains. |
