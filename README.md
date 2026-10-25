# XKLStudy source-only build candidate

Version 1.17.0 (32). Bundle identifier: `local.xkl.study`.

This review package contains app source, synthetic unit tests, existing third-party license notices, and an unsigned iOS build workflow. It contains no study content packages or device backups. Tests requiring private fixtures skip when those fixtures are absent.

On macOS with Xcode installed:

```sh
bash tools/build_unsigned_ios.sh
```

The script generates the Xcode project, runs `swift test`, and builds an unsigned IPA. The IPA requires personal signing before installation. Preserve the existing app and its records; do not uninstall it. Keeping the bundle identifier is necessary but does not alone guarantee an in-place upgrade: signing identity and provisioning must also allow it. Back up and verify records before a device upgrade.

A separate public repository using standard GitHub-hosted macOS runners is an optional build route. No repository has been created or published by preparing this package. Public-source approval and licensing review remain required. Account-level restrictions may still prevent a run; successful Apple compilation is not established by this local package.

## License notices

Retained notices: `Sources/CPocket/UPSTREAM-LICENSE.txt` (FoloToy MIT) and `docs/FSRS-LICENSE.txt` (Open Spaced Repetition MIT). These notices do not establish a license for all original app code or assets. No new blanket license is granted in this candidate. Confirm ownership and publication permission before publishing.

## Mathematics experience v2

The mathematics tab uses a separate transactional MathExperience store. The previous MathPractice archive remains an immutable baseline. A matching locally validated guide is required before practice; no private question banks are bundled. Hints and card browsing mark assistance. Independent correct maps to Good; assisted correct and incorrect map to Again. Familiar skipping creates no question or card score. Cards use a separate recall queue.

DEBUG builds support --math-experience-preview with synthetic examples only; no real store is initialized on that route. The normal production route retains app-owned stores.

