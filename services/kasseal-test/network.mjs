// One immutable network per planner process; caller input cannot change it.
export const NETWORK = process.env.KASPIRE_KASSEAL_NETWORK ?? 'testnet-10';
if (!['mainnet', 'testnet-10'].includes(NETWORK)) throw Error('Unsupported Kasseal network');
export const API = NETWORK === 'mainnet' ? 'https://app.kasseal.com/v1' : 'https://testnet.kasseal.com/v1';
export const PREFIX = NETWORK === 'mainnet' ? 'kaspa:' : 'kaspatest:';
export const profile = kind => `kasseal-${NETWORK === 'mainnet' ? 'mainnet' : 'tn10'}-${kind}-v1`;
