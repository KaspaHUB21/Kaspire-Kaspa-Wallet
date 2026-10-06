// Read-only Nexus rank cache export. No provider calls, owner data or secrets.
const {createRequire} = require('node:module');
const {mkdir, writeFile, rename} = require('node:fs/promises');
const {join} = require('node:path');
async function main() {
  const modulePath = process.env.KRC721_PRISMA_MODULE;
  const directory = process.env.KRC721_RARITY_DIR;
  if (!modulePath || !directory) throw Error('Explicit local client module and output directory required');
  const {PrismaClient} = createRequire(__filename)(modulePath);
  const db = new PrismaClient();
  try {
    const rows = await db.$transaction(async tx => {
      await tx.$executeRawUnsafe('SET TRANSACTION READ ONLY');
      return tx.nftRarityCache.findMany({select:{collectionId:true,tokenId:true,rarityRank:true}});
    });
    const collections = new Map();
    for (const row of rows) {
      const tick = row.collectionId.toUpperCase();
      if (!/^[A-Z0-9]{1,10}$/.test(tick) || !/^\d{1,20}$/.test(row.tokenId)) continue;
      if (!collections.has(tick)) collections.set(tick, {});
      if (!Number.isInteger(row.rarityRank) || (row.rarityRank !== -1 && row.rarityRank <= 0)) continue;
      collections.get(tick)[row.tokenId] = row.rarityRank;
    }
    // A known collection with no published rank is not an unreachable file.
    // Export an explicit empty rank map; never initiate an external rank probe.
    try {
      const response=await fetch('http://127.0.0.1:18801/v1/collections', {
        headers:process.env.KRC721_PRIVATE_API_KEY?{'X-KRC721-Key':process.env.KRC721_PRIVATE_API_KEY}:{},
        signal:AbortSignal.timeout(3000),redirect:'error'});
      if(response.ok)for(const row of (await response.json()).result||[]){
        const tick=String(row.tick||'').toUpperCase();
        if(/^[A-Z0-9]{1,10}$/.test(tick)&&!collections.has(tick))collections.set(tick,{});
      }
    } catch { /* Preserve existing rank exports while the catalog is offline. */ }
    await mkdir(directory, {recursive:true, mode:0o755});
    for (const [tick, ranks] of collections) {
      const file = join(directory, tick+'.json');
      await writeFile(file+'.pending', JSON.stringify({ticker:tick,observedAt:Date.now(),ranks}), {mode:0o644});
      await rename(file+'.pending', file);
    }
    console.log(`Exported local ranks for ${collections.size} collections`);
  } finally { await db.$disconnect(); }
}
main().catch(() => { console.error('Local rarity export failed; existing rank files preserved'); process.exitCode=1; });
