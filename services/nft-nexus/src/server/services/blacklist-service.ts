import {isBlacklistedCollection} from '@/lib/market-provider/collections';
import {normalizeTicker} from '@/lib/market-provider/collections';
import {prisma} from '@/lib/db/prisma';
export const BLACKLIST_MESSAGE='This collection is not supported.';
export async function isCollectionBlacklisted(collectionId:string) {
  return isBlacklistedCollection(collectionId) || Boolean(await prisma.blacklistedCollection.findUnique({where:{ticker:normalizeTicker(collectionId)}}));
}
