const kasgothsOrder = ['21', '420', '13'];
const isKasgoths = (collection:string) => collection.trim().toLowerCase() === 'kasgoths';

export function nftRarityLabel(collection:string, id:string|number, rank:number|null|undefined, fallback='Unavailable'):string|number {
  if (rank === -1 || isKasgoths(collection) && kasgothsOrder.includes(String(id))) return 'Legendary';
  return typeof rank === 'number' && Number.isFinite(rank) ? rank : fallback;
}

export function compareNftRarity(collection:string, a:{tokenId:string|number;rarityRank?:number|null}, b:{tokenId:string|number;rarityRank?:number|null}) {
  const priority = (id:string|number) => {
    const index = isKasgoths(collection) ? kasgothsOrder.indexOf(String(id)) : -1;
    return index < 0 ? kasgothsOrder.length : index;
  };
  const special = priority(a.tokenId)-priority(b.tokenId);
  if (special) return special;
  const rank = (value:number|null|undefined) => typeof value === 'number' && Number.isFinite(value) ? value : Infinity;
  return rank(a.rarityRank)-rank(b.rarityRank) || String(a.tokenId).localeCompare(String(b.tokenId),undefined,{numeric:true});
}
