# Platform parity and release handoff

When the user asks to bring Android changes into the browser extension (or the
reverse), port the complete applicable behavior, not just screens or API names.
Compare against the last released version of each platform and account for:

- discovery, positive/zero/unavailable balances, progress, paging and fallbacks;
- verified token units, activity identity/merging and asset metadata/images;
- sending, recipient policies, consolidation, reviews, signing and recovery;
- navigation, all themes, narrow layouts and platform-specific approval surfaces.

Record intentional platform differences and user-requested exclusions explicitly.
Do not silently broaden signing support to claim parity. Test the actual built
package as well as unit tests; a mocked parser passing is not an end-to-end check.
For asynchronous discovery, include slow/failing sources, reopening and results
arriving after ordinary UI deadlines. Unknown or partial state must not mean zero.

For a requested public release, include complete cumulative release notes since
each platform's last public release, GitHub releases (not only a commit), website
version/checksum/download changes and the Android signed update manifest when
Android is in scope. Preserve signing identity, update trust and other platforms'
channels. Do not imply Chrome Web Store approval merely because a ZIP is public.
When releasing Android and extension together, the GitHub Latest release title
and body must cover BOTH platforms with their versions and cumulative changes.
A separate extension release/link alone does not satisfy this requirement.
Stage explicit relevant paths only; unrelated dirty files and private experiment
directories must never be added wholesale. Do not add Codex co-author trailers.
