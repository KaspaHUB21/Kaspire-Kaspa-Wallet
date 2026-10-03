# Kaspire Extension 0.5.6

This update restores access to unfinished KRC20, KRC721 and KNS commit/reveal transfers.

- Show a saved pending reveal on the wallet dashboard and send screen.
- Open a dedicated recovery screen with the original wallet, recipient, asset and commit transaction ID.
- Resume the existing commit without creating another commit or discarding recovery data.
- Review the reveal fee and complete transaction JSON before authorization.
- Preserve pending transfers across popup closure, browser restarts and normal extension updates.
- Keep recovery visible after an interrupted transfer and allow retry after an error.
- Allow sufficient time to wait for the committed output and approve the reveal.
- Reject signing if the wallet is locked or its account or network changes during recovery.

Android remains at 0.11.46 (build 136). Chrome Web Store publication requires submission and approval of this extension package.
