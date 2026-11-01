# switch-remote

<p align="center"><img src="build/icons/icon.png" width="160" height="160" alt="switch-remote icon"></p>

[한국어 사용 설명서](README.ko.md) · [Download](https://github.com/hada0127/switch-remote/releases/latest)

Play your Switch on your Mac through a capture card. Add a Raspberry Pi Zero W if you also want to use a controller connected to your Mac.

Previously called Video Game Filter. Your saved settings and presets carry over. After installing switch-remote, remove the old app from Applications to avoid opening it by mistake.

## What you need

- An Apple Silicon Mac with macOS 14 or later.
- A capture card that works with macOS, an HDMI cable, and your Switch dock.
- For controller forwarding: a Raspberry Pi Zero W, a microSD card, and a USB data cable.

You can watch and hear the Switch without a Pi. The Pi is only needed to send controller input to the console.

## Get started

1. [Download the latest release](https://github.com/hada0127/switch-remote/releases/latest) and unzip it.
2. Move `switch-remote.app` to Applications and open it.
3. Connect the Switch dock's HDMI output to the capture card, then connect the card to your Mac.
4. Allow camera and microphone access when macOS asks. These permissions let the app receive the card's picture and sound.
5. Click the picture to open settings.

The app has three tabs. The tab names are currently shown in Korean.

## Basic settings (기본)

Choose your video device, audio device, and resolution/frame rate. If you see a picture but hear nothing, check the audio device first.

The available resolutions depend on your capture card. A card that passes 4K60 through to a TV may capture at a lower resolution or frame rate. For example, Elgato HD60 X captures up to 4K30.

Press **Control–Command–F** for full screen. Click **×** to close settings; click the picture to open them again. The pointer hides after three seconds without movement and returns when you move it.

## Retro effects (레트로 효과)

Start with a preset:

- **Original (원본):** no effects.
- **CRT · 기본:** the default CRT look.
- **CRT · 기본 (세로):** the same look with vertical scanlines.
- **CRT · 선명하게:** a lighter CRT effect.
- **가로 스캔라인 25% / 그리드 27%:** horizontal lines or a grid.

You can change horizontal and vertical line strength, thickness, and spacing separately. CRT adds screen curvature, glow, darker edges, and an RGB mask. Antialiasing softens the game picture while leaving the scanlines and mask intact. Sharp enlargement is also available.

Use **새 프리셋 저장** to save your own look. **덮어쓰기** updates a selected custom preset; **삭제** removes it. Built-in presets cannot be overwritten or deleted. New installations start with CRT · 기본; existing settings are kept.

## Controller settings (컨트롤러)

The Pi sends your Mac controller's input to the Switch. USB from the Pi to the dock is the preferred connection; Bluetooth is also supported. An optional FTDI USB serial cable carries input from the Mac to the Pi, with automatic Wi-Fi fallback; see the [Pi guide](controller/README.md).

1. Use Raspberry Pi Imager to write **Raspberry Pi OS Lite, 32-bit (Bookworm or newer)** to the card. Set up the Pi's **2.4 GHz Wi-Fi**.
2. With the card still connected to your Mac, choose **새 파이 SD 준비…** in the Controller tab and select its `bootfs` volume.
3. Eject the card, put it in the Pi, and connect the Pi's **USB data port** to the Switch dock with a data cable. The other micro-USB port is power only.
4. Give the first boot a few minutes and allow local network access on the Mac. The Pi needs internet access for its first setup. Keep the Mac and Pi on the same network.
5. Connect a gamepad to the Mac and select it under **입력 장치**. Leave automatic connection enabled to reconnect to the saved Pi later.

If A/B and X/Y feel reversed, turn on **A/B · X/Y 맞바꾸기**. Local controllers send input while the Mac app is active. HOME, Capture, and L+R are available above every settings tab.

For first-time Bluetooth pairing, open **Controllers → Change Grip/Order** on the Switch. For USB setup details or troubleshooting, see the [Pi guide](controller/README.md).

Switch 2 wake from sleep, rumble, motion controls, and NFC are not supported. Turn on the Switch before connecting.

## Moonlight, briefly

Moonlight can show your Mac's screen on an iPhone or Android device. Remote controller input needs the [modified Sunshine helper](controller/sunshine/README.md), which is a separate setup and is not bundled with this download. In the app, select **문라이트 · 선샤인** as the input device.

For access away from home, connect both devices to Tailscale and add the Mac's Tailscale address in Moonlight. Leave the Mac, app, Pi, and Switch on. Test away-from-home video and controls separately; a test on home Wi-Fi does not verify that connection.

## More

- [Build the Mac app and learn about its effects](macOS/README.md)
- [Report a problem](https://github.com/hada0127/switch-remote/issues)
- [Older Electron version for macOS and Windows](https://github.com/hada0127/switch-remote/releases/tag/v0.2)

Built with SwiftUI and Metal, with Hada Sans included. This release is for Apple Silicon Macs. The app does not record video. It is [MIT licensed](LICENSE.md); bundled fonts and controller/shader sources have their own license notices.
