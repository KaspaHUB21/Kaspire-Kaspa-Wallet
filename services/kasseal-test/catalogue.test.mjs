import test from 'node:test';
import assert from 'node:assert/strict';
import {cataloguePath} from './planner.mjs';
test('Search is sent to the global token endpoint, with cursor bound to the same query',()=>{
 const p=new URL(cataloguePath('search-page-2',' unnachod '),'https://example.invalid');
 assert.equal(p.pathname,'/tokens');assert.equal(p.searchParams.get('search'),'unnachod');
 assert.equal(p.searchParams.get('cursor'),'search-page-2');assert.equal(p.searchParams.get('limit'),'20');
 assert.equal(p.searchParams.get('sort'),'active');
});
test('Search text cannot inject another query and exact covenant IDs use direct lookup',()=>{
 const p=new URL(cataloguePath('','x&limit=100#more'),'https://example.invalid');
 assert.equal(p.searchParams.get('search'),'x&limit=100#more');assert.equal(p.searchParams.get('limit'),'20');
 const id='ab'.repeat(32);assert.equal(cataloguePath('',id.toUpperCase()),'/tokens/'+id);
});
test('Unfiltered browsing remains paginated and query bounds are enforced',()=>{
 const p=new URL(cataloguePath('next-page'),'https://example.invalid');
 assert.equal(p.searchParams.get('cursor'),'next-page');assert.equal(p.searchParams.has('search'),false);
 assert.throws(()=>cataloguePath('x'.repeat(1025)));assert.throws(()=>cataloguePath('','x'.repeat(65)));
 assert.throws(()=>cataloguePath('',null));
});
