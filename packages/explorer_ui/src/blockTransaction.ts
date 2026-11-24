const HASH = /^[a-f0-9]{64}$/i;

function identity(id: string, blockHash: string | null) {
  if (!HASH.test(id)) throw Error('Invalid transaction ID.');
  if (blockHash !== null && !HASH.test(blockHash)) throw Error('Invalid containing block hash.');
  return {id: id.toLowerCase(), blockHash: blockHash?.toLowerCase() ?? null};
}

// Live block transactions may not yet exist in the transaction index. Preserve
// their containing block so the own-node REST API can read them from the block.
export function transactionLink(id: string, blockHash: string | null = null) {
  const value = identity(id, blockHash);
  return '/tx/' + value.id + (value.blockHash ? '?' + new URLSearchParams({blockHash: value.blockHash}) : '');
}

export function transactionReadPath(id: string, blockHashes: string[] = []) {
  if (blockHashes.length > 1) throw Error('Ambiguous containing block hash.');
  const value = identity(id, blockHashes[0] ?? null);
  const query = new URLSearchParams({inputs: 'true', outputs: 'true', resolve_previous_outpoints: 'light'});
  if (value.blockHash) query.set('blockHash', value.blockHash);
  return '/transactions/' + value.id + '?' + query;
}

export function isCoinbase(tx: {subnetwork_id?: string}) {
  return tx.subnetwork_id === '01' + '00'.repeat(19);
}
