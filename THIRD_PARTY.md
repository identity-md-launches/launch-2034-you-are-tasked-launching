# Included dependencies and attribution

| Files | Origin / version | License |
| --- | --- | --- |
| `lib/forge-std/src/` | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | MIT / Apache-2.0, included beside `src` |
| `site/vendor/ethers.min.js` | [ethers.js v6.15.0](https://github.com/ethers-io/ethers.js/tree/v6.15.0) standalone ESM distribution | MIT, `site/vendor/ethers.LICENSE.md` |
| `site/fonts/Anton-Regular.ttf` | [Google Fonts / Anton](https://github.com/google/fonts/tree/main/ofl/anton), fetched 2026-10-16 | SIL Open Font License, `Anton-OFL.txt` |
| `site/fonts/SpaceGrotesk.ttf` | [Google Fonts / Space Grotesk](https://github.com/google/fonts/tree/main/ofl/spacegrotesk), fetched 2026-10-16 | SIL Open Font License, `SpaceGrotesk-OFL.txt` |

The fonts and JavaScript are served locally, without a CDN. The vinyl illustration, brand mark, chart and layout are original HTML/CSS/SVG assets.

`test/fixtures/MainnetState.sol` contains historical public Ethereum runtime bytecode for integration testing, not source libraries licensed by this project. Original rights remain with each protocol's authors. Its `UNLICENSED` identifier avoids assigning an invented license to those bytes. Addresses, hashes, storage provenance and the capture procedure are documented in `test/fixtures/provenance.json` and `docs/EVIDENCE.md`. The bytecode fixtures are test-only; they are neither deployment artifacts nor replacement mainnet contracts.

The task’s pinned ethskills references informed the review. Their licenses and inputs are not redistributed as application dependencies; no code was copied from their examples.
