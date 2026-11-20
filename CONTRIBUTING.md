# Contributing to LumaWall

Contributions are welcome under the terms below. Please also read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License and Developer Certificate of Origin (DCO)

LumaWall is licensed under the [Apache License 2.0](LICENSE). Under Section 5 of the Apache License 2.0, any contribution you submit for inclusion in LumaWall is licensed under the Apache License 2.0 unless you explicitly state otherwise.

Every commit must carry a Developer Certificate of Origin ([DCO 1.1](https://developercertificate.org/)) sign-off certifying that you wrote the contribution or otherwise have the right to submit it under the project's license:

```sh
git commit -s
```

This adds a `Signed-off-by: Your Name <you@example.com>` trailer to your commit message. Do not submit third-party code or media unless its license is compatible with Apache 2.0 and its attribution is added to `NOTICE` and `THIRD_PARTY_NOTICES.md`.

## Development setup and checks

See [AGENTS.md](AGENTS.md) for the full build, formatting, and live-wallpaper safety rules. In short:

```sh
./ci/bootstrap.sh                     # installs XcodeGen 2.46.0 into .tools/
./ci/format.sh                        # formats Swift sources in place
./ci/test.sh <TestClassOrSuite>       # runs one test class or suite
./ci/check.sh                         # runs all tests, lint, and Release build
```

- If you add, remove, or move source files, run `./ci/xcodegen.sh generate` and commit the updated `LumaWall.xcodeproj`.
- Compiler warnings are treated as errors in all targets.
- Keep source files under 1,500 lines.
- Do not bundle or commit third-party copyrighted videos or images.

## Security issues

Do not open public issues or pull requests for security vulnerabilities. Follow [SECURITY.md](SECURITY.md) to report them privately.
