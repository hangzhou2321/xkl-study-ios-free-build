# XKLStudy source-only build candidate

Version 1.18.0 (34). Bundle identifier: `local.xkl.study`.

This review package contains app source, synthetic unit tests, existing third-party license notices, and an unsigned iOS build workflow. It contains no study content packages or device backups. Tests requiring private fixtures skip when those fixtures are absent.

On macOS with Xcode installed:

```sh
bash tools/build_unsigned_ios.sh
```

The script generates the Xcode project, runs `swift test`, and builds an unsigned IPA. The IPA requires personal signing before installation. Preserve the existing app and its records; do not uninstall it. Keeping the bundle identifier is necessary but does not alone guarantee an in-place upgrade: signing identity and provisioning must also allow it. Back up and verify records before a device upgrade.

The `validate-professional.yml` workflow runs the synthetic tests, builds an unsigned IPA, and captures native simulator views on a macOS host. A workflow dispatch is not a successful build; inspect the run and artifacts for the exact commit. Private courses, source scans, and device archives remain outside this repository.

## Professional recall

Computer and power courses each open one mainline recall queue. Existing primary and supplemental IDs are combined as a view. A separate optional scope retains extension cards. Both scopes use the vocabulary PocketEngine and its current conservative-policy setting; no mathematics scheduler is substituted.

The professional store backs up legacy recall bytes before activation, retains stable numeric mappings and content-boundary snapshots, and commits both scopes together when cards move. A self-assessment never creates an objective question answer. Source-answer exposure and in-question card assistance are stored separately from objective grading. Synthetic tests cover interrupted writes, duplicate actions/imports, course changes, scope transfers, and held-question recovery.

## License notices

Retained notices: `Sources/CPocket/UPSTREAM-LICENSE.txt` (FoloToy MIT) and `docs/FSRS-LICENSE.txt` (Open Spaced Repetition MIT). These notices do not establish a license for all original app code or assets. No new blanket license is granted in this candidate. Confirm ownership and publication permission before publishing.

## Mathematics experience v2

The mathematics tab uses a separate transactional MathExperience store. The previous MathPractice archive remains an immutable baseline. A matching locally validated guide is required before practice; no private question banks are bundled. Hints and card browsing mark assistance. Independent correct maps to Good; assisted correct and incorrect map to Again. Familiar skipping creates no question or card score. Cards use a separate recall queue.

DEBUG builds support --math-experience-preview with synthetic examples only; no real store is initialized on that route. The normal production route retains app-owned stores.

