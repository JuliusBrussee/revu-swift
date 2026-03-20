# Revu

Revu is a polished, local-first macOS study app for decks, cards, exams, study guides, and FSRS-based review sessions. It is opinionated in a good way: fast keyboard-friendly workflows, a dense but calm desktop UI, strong study primitives, and a structure that makes serious studying feel organized instead of chaotic.

This public repository contains the standalone macOS application and its tests. It is an older branch of the product that I decided to open source because it is still a genuinely useful app and a solid codebase for people who care about local-first software, SwiftUI desktop apps, and spaced-repetition tooling.

## A Note From The Company

Revu is my company. The current product continues to evolve separately, and the newer version lives at [revu.cards](https://revu.cards).

This repository is an older version of the app, published deliberately as a gift to the open-source community. I did not want this work to disappear into a private archive when there was still a lot here that could be useful, interesting, or inspiring to other builders. If you want the newest commercial product, go to [revu.cards](https://revu.cards). If you want a capable local-first macOS study app that you can inspect, modify, and learn from, this repo is for you.

## Why This App Is Cool

- It is built around real study workflows instead of toy flashcard demos.
- It combines decks, cards, exams, study guides, folders, review history, and forecasting in one coherent desktop app.
- It uses FSRS-based scheduling, so the review engine is not just cosmetic.
- It is local-first, which means the app is fast, self-contained, and usable without hosted infrastructure.
- It has a thoughtful SwiftUI macOS interface with a real design system behind it.
- It is the kind of app that feels substantial: not just a single feature, but a full study workspace.

## What’s Included

- Deck and card management with nested folders
- FSRS-based study sessions with review history and forecasting
- Local course, exam, and study-guide workflows
- Import support for Anki, Revu JSON, CSV/TSV, and Markdown blocks
- Export support for Revu JSON backups
- A SwiftUI design system used across the macOS app

## What’s Not Included

- Website code
- Hosted backend infrastructure
- Authentication, billing, subscriptions, or account sync
- AI generation, AI tutoring, external tool integrations, or provider configuration
- Internal planning files and private repo history

## Screenshots

These screenshots come from the earlier Revu product materials and still do a good job showing the feel of the macOS app.

### Study Session

![Revu study session](docs/screenshots/lifelong.png)

### Import Workflow

![Revu import workflow](docs/screenshots/certifications.png)

### Desktop Workspace

![Revu workspace](docs/screenshots/med.png)

## Requirements

- macOS 14 or later
- Xcode 16 or later

## Build

Open `Revu.xcodeproj` in Xcode and run the `Revu` scheme.

CLI build:

```bash
xcodebuild -project Revu.xcodeproj -scheme Revu -destination 'platform=macOS' build
```

CLI tests:

```bash
xcodebuild test -project Revu.xcodeproj -scheme RevuTests -destination 'platform=macOS'
```

## App Data Location

By default Revu stores data in:

```text
~/Library/Application Support/revu/v1/
```

Key paths inside that directory:

- `revu.sqlite3`: local database
- `attachments/`: imported media and study-guide attachments
- `backups/`: local backup/export staging

## Repo Layout

- `Revu/`: macOS app target resources and source tree
- `RevuTests/`: Swift Testing suite
- `docs/architecture.md`: module and storage overview
- `docs/import-export.md`: supported formats and merge behavior
- `docs/ui-design-system.md`: canonical UI rules and tokens

## Development Notes

- The app is local-first. It should build and run without environment variables.
- Public-safe bundle identifiers and URL handling are already stripped of private auth flows.
- If you add new UI, use the design tokens in `Revu/Revu/Support/DesignSystem.swift`.

## Open-Source Scope

This repo is intentionally the macOS app only. The hosted product, website, backend systems, authentication, billing, sync, and newer commercial product work are not part of this repository. The goal here is to preserve and share a strong standalone version of Revu that can live on its own as open-source software.

## License

The code in this directory is licensed under `GPL-3.0-only`. See `LICENSE`.

The Revu name, logo, and other brand assets are not licensed for reuse as
trademarks. GPL covers copyright licensing; it does not grant trademark
rights.
