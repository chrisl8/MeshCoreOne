# MeshCore One (MC1)

A MeshCore client built for Apple devices in Swift.   
Disclaimer: Decisions are made by a human, but almost all code is created with AI.

Download from the App Store or sideload using unsigned IPA files under [Releases](https://github.com/Avi0n/MeshCoreOne/releases).

<a href="https://apps.apple.com/app/meshcore-one/id6757419477">
  <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="50">
</a>

## About this fork (`enhanced`)

This is [chrisl8's fork](https://github.com/chrisl8/MeshCoreOne) of [MeshCore One](https://github.com/Avi0n/MeshCoreOne). The `enhanced` branch is upstream `dev` plus the extras below. Each lives on its own `feature/*` branch too, so it can be taken separately. Everything else is upstream's work and is covered by the sections that follow.

**Enhancements**
- **Why did my DM fail?** A failed DM shows whether a repeater was heard forwarding it ("on mesh") or nothing heard it.
- **DM progress on the Live Activity**: send attempts, retries and waits show on the Lock Screen and Dynamic Island.
- **Persistent retry** (clock-arrow toggle beside the compose field): an armed DM sends twice up front (saved path, then flood), then keeps retrying with growing waits. Late retries are prefixed with the original send time. A waiting retry also fires early once the phone has moved about 200 m (needs "Always" location). A footer icon marks armed messages, and an orange banner in the Chats list shows one that is still retrying.
- **CoreScope check for channel messages**: after you send to a channel, the app polls a CoreScope mesh-analyzer site's public API and shows a globe chip with how many times observers heard it, or a warning or offline icon. Works for any channel the site tracks. Set the site URL under Settings > Chat (blank turns it off).

**Build notes:** `enhanced` uses personal bundle IDs (`net.lofland.mc1`) and compiles out the iOS 27-only swipe-actions API so it builds on Xcode 26.5. Change the bundle IDs in `project.yml` to sign it yourself.

## Features

### Messaging
- Direct messages with delivery status and flood retry
- Channels (public, private, and hashtag)
- Room Server connections with guest/participant modes
- Heard repeats tracking
- Message reactions (emoji)
- View Path Hops (list and map)
- Link/gif previews and inline images
- Coordinate map previews
- @Mentions
- Per-conversation notification levels
- Hashtag channel deep links
- Filtering and blocking

### Contacts
- Auto-discovery on the mesh
- QR code and advert sharing
- Favorites
- Zero-hop ping
- Telemetry fetch
- Edit Out Path

### Map
- Contact positions
- Map layers (standard, satellite, topography)
- Offline download

### Network Tools
- **Trace Path** - Route through specific repeaters with option to save paths
- **Line of Sight** - Terrain analysis with Fresnel zone and RF parameters
- **RX Log** - Live packet capture
- **Noise Floor Monitor** - Live dBm chart with signal quality stats
- **CLI Terminal** - Remote command-line access to repeaters and rooms

### Remote Node Management
- Node status (telemetry such as battery and uptime. Neighbors for repeaters)
- Remote repeater/room configuration (radio, behavior, identity, reboot)
- Telemetry history charts
- Admin and guest authentication for repeaters/rooms

### Companion Device
- Bluetooth and WiFi pairing
- Radio presets and manual tuning (frequency, TX power, spreading factor, bandwidth)
- Battery monitoring with OCV curves
- Repeat mode

### General
- Live Activity
- Themes
- Offline mesh networking (no internet required)
- Push notifications with quick reply
- Location sharing controls
- Config import/export
- App data backup/restore


## Requirements

-   **iOS/iPadOS 18.0+, or Apple Silicon Mac**
-   **MeshCore-compatible hardware**

## Getting Started

1.  Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2.  Run `make generate` (creates a gitignored `dev.yml` — set your Apple team ID there for local signing).
3.  Open `MC1.xcodeproj`.

For more details, see the [Development Guide](docs/Development.md).

## Acknowledgements
Thank you to the MeshCore dev team and all its contributors for contributing their time, money, and energy. This project would not exist without their hard work and dedication.
- [MeshCore](https://github.com/meshcore-dev/meshcore)
- [meshcore_py](https://github.com/meshcore-dev/meshcore_py)

This project uses a fork of [swiftui-messaging-ui](https://github.com/FluidGroup/swiftui-messaging-ui) which has helped tremendously with the chat view experience.

Maps use [MapLibre Native](https://maplibre.org/). Emoji data comes from [Emojibase](https://github.com/milesj/emojibase), through the [emojibase-bindings](https://github.com/matrix-org/emojibase-bindings) package. 

## License

MeshCore One - GNU General Public License v3.0   
Swift MeshCore - MIT
