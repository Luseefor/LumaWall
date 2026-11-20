# Terms of Use

> **DRAFT FOR LEGAL REVIEW** — These end-user terms are a draft prepared for legal review prior to public distribution.

By installing or using LumaWall, you agree to these terms and the [Apache License 2.0](LICENSE).

## 1. Non-affiliation

LumaWall is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc. macOS is a trademark of Apple Inc.

## 2. Safe mode and optional native wallpaper mode

- **Safe mode (default)**: By default, LumaWall renders video wallpapers in a desktop-level overlay window using documented macOS APIs and sets a static poster image through the standard workspace wallpaper interface. It does not modify internal system wallpaper databases.
- **Native wallpaper mode (optional, experimental)**: On macOS 26 and newer, you can opt in to an experimental native mode. Native mode uses undocumented macOS wallpaper extension interfaces and edits the user's system wallpaper settings file (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`), then restarts `WallpaperAgent` to apply changes.
- **Assumption of risk and fallback**: Because native mode relies on undocumented macOS behavior, any macOS update may break it or reset your desktop wallpaper configuration. You enable and use native mode at your own risk. If native assignment fails, LumaWall automatically falls back to standard Safe mode (overlay) and provides an option to restore your previous wallpaper settings from its local backup.

## 3. Rights to imported media

LumaWall does not bundle third-party video wallpapers. You are solely responsible for ensuring that you own or hold the necessary rights and permissions for any video or image files you import and display with LumaWall.

## 4. Privacy

LumaWall operates locally on your Mac and collects no personal data or telemetry. See [PRIVACY.md](PRIVACY.md) for what stays on your device.

## 5. No warranty

As stated in Section 7 of the [Apache License 2.0](LICENSE), LumaWall is provided on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE.

## 6. Limitation of liability

As stated in Section 8 of the [Apache License 2.0](LICENSE), in no event and under no legal theory shall the copyright holder or contributors be liable to you for damages, including any direct, indirect, special, incidental, or consequential damages of any character arising as a result of these terms or out of the use or inability to use the software (including loss of data, wallpaper configuration changes, or system instability).
