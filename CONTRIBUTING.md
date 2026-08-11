# Contributing to CopyClip Lite

Thanks for helping improve CopyClip Lite.

## Before opening an issue

Search existing issues first. When reporting a bug, use synthetic clipboard
content and remove personal paths, application names, images, and clipboard
history exports. Public issues and build logs must not contain private clipboard
data.

Security vulnerabilities should follow [SECURITY.md](SECURITY.md), not the
public issue tracker.

## Development setup

CopyClip Lite requires macOS 14 or later, Xcode Command Line Tools with
Swift 5.9 or later, and `jq` for coverage-report validation. Install `jq` with
`brew install jq` if it is not already available.

```bash
swift test
swift build
./script/build_and_run.sh
```

## Before submitting a change

Run the checks that cover your change. The complete local validation set is:

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./script/check_coverage.sh
./script/tests/installer_process_harness.sh
bash ./script/tests/release_contract_harness.sh
```

Changes to packaging should also run `./script/package_release.sh`. Changes to
keyboard interaction, focus, or motion should be checked against the
[accessibility test matrix](docs/accessibility-testing.md).

Keep pull requests focused, include regression tests for behavioral fixes, and
describe any privacy, persistence, compatibility, or release impact.
