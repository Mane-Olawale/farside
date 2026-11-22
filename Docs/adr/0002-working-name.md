# Working name

The product name is Farside: the Mac on the far side of the network. The repository is `farside`.

| Item | Value |
| --- | --- |
| iPad app | Farside, bundle suffix `.client` |
| Mac app | Farside Host, bundle suffix `.host` |
| Latency rig | TestPattern, bundle suffix `.testpattern` |
| Bonjour service | `_farside._tcp` |

The bundle prefix and team id live in `Config/Local.xcconfig`, which is not committed. `Config/Shared.xcconfig` holds a placeholder prefix.

The name does not include Mac, iPad, Apple, VNC or RustDesk. A subtitle may say the app is a remote desktop for your Mac.
