# Security Policy

## Supported versions

Security fixes apply to the latest release on `main` (targeting macOS 15 and macOS 26). Older commits and unnotarized development builds are not supported.

| Version | Supported |
| --- | --- |
| `main` / latest release | Yes |
| Older commits | No |

## Reporting a vulnerability

Do not open a public GitHub issue for security vulnerabilities.

Report vulnerabilities privately through [GitHub Private Vulnerability Reporting](https://github.com/Luseefor/LumaWall/security/advisories/new) on this repository. Include:

- The macOS version and LumaWall commit or release version
- Whether you are running Safe mode (overlay) or the experimental native wallpaper mode
- Steps or a proof-of-concept to reproduce the issue
- What local boundary is crossed (for example: XPC validation between the app and `LumaWallWallpaper.appex`, file handling in `~/Library/Application Support/LumaWall`, or plist handling in native mode)

You can expect an initial response within 7 days. Once a fix is verified, we will publish a security advisory on GitHub and credit you unless you prefer to remain anonymous.
