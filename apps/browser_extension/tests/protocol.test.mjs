import test from "node:test";import assert from "node:assert/strict";import{isProviderRequest,PROVIDER_CHANNEL}from"./generated/protocol.mjs";
test("accepts a bounded declared provider request",()=>assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"1",method:"sendKaspa",params:{}}),true));
test("rejects empty request identifiers",()=>assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"",method:"getAccounts"}),false));
test("rejects undeclared methods",()=>assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"1",method:"signAnything"}),false));
test("rejects oversized hostile payloads",()=>assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"1",method:"signMessage",params:{message:"x".repeat(1_048_576)}}),false));
test("rejects unknown methods and oversized ids",()=>{assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"1",method:"blindSign"}),false);assert.equal(isProviderRequest({channel:PROVIDER_CHANNEL,direction:"request",id:"x".repeat(129),method:"getAccounts"}),false)});
