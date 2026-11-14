# TB M50 Dual Channel Strip (2026 Mac)

Two input channels of the **TASCAM M-50** mixing console and its **stereo master**, as **CLAP, VST3 and
AU (AUv2)** plugins for current Macs: universal (Apple Silicon + Intel), macOS 11 and later, for Reaper,
FL Studio, Tape16, Logic and other hosts. Non-commercial, for personal use.

The sound, panel and presets are the approved 10.8.5 build's
([TB-M50-Dual-Channel-Strip-MOUNTAIN-LION](https://github.com/tonybuzzcock/TB-M50-Dual-Channel-Strip-MOUNTAIN-LION)),
and the output matches it sample for sample. See that README for how the console is modelled and the
estimates to tune.

- A stereo insert for a buss or the mix buss: the left input feeds channel 1, the right channel 2.
- Each channel: INPUT (MIC / D.I. / LINE), TRIM with the OVERLOAD LED (the drive starts rounding just
  under it), EQ BYPASS, three sweep EQ sections (+-15 dB), PAN, fader, VU.
- STEREO MASTER fader with L / R VUs; LINK (channel 1 drives channel 2, pans independent) and BYPASS
  (this plugin only, click-free) above it.
- Right-click (or Control-click) any channel control to see both channels' values in the readout.
- Named presets, shared by all three formats.
- The panel is the 10.8.5 one in its mahogany frame, drawn at **80 % (616 x 774)** so it fits a MacBook
  screen.

## Build

GitHub Actions builds universal binaries on a Mac runner, checks both architectures and macOS 11 as the
minimum, ad-hoc signs them, runs the CLAP host test, the DSP test and the panel test, validates with
auval, clap-validator and pluginval, publishes panel screenshots to `gui-preview` and uploads
`TB-M50-Dual-Channel-Strip-mac.zip`.

Locally: `cmake -B build && cmake --build build`, then `build/preset_test`, `build/m50_test renders`
and `build/clap_host_test "build/plugins/TB M50 Dual Channel Strip.clap"` (Linux builds the CLAP only).

## Install

Actions -> the newest green run -> Artifacts -> `TB-M50-Dual-Channel-Strip-mac`. Unzip, then follow
`INSTALL.txt` inside: copy the plugins into `/Library/Audio/Plug-Ins/` (VST3, Components, CLAP), then in
Terminal, one line at a time:

    cd /Library/Audio/Plug-Ins
    ls */ | grep -i m50
    sudo xattr -cr */"TB M50 Dual Channel Strip".*
    sudo codesign --force --deep --sign - */"TB M50 Dual Channel Strip".*
    killall -9 AudioComponentRegistrar

Then rescan in your DAW (Reaper: Settings > Plug-ins > VST and CLAP > Clear cache/re-scan).
