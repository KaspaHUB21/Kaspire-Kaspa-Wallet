//! Native-only KasPool integration. No dApp-provided executable code or keys.
//! Upstream builders are pinned; every state is recompiled to its locking script.
#[cfg(test)]
#[path="trestly_tests.rs"]
mod tests;
use crate::{CoreError, Result};
use kusdt_kaspa::{model::{Located, TokenState, Utxo, Funding}, pool::{self, PoolState}, tx::{Common, Network}};
use kaspa_addresses::Address;
use kaspa_txscript::{extract_script_pub_key_address, pay_to_address_script};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;
pub const TOKEN: &str = "50b3477e7368d0c5bfbd64483b4607350ec411377972f33e40b2d4b6d1513fd3";
pub const POOL: &str = "28e7758e6fc0e2054cceb7f87f9da44a53accfa0a1795c8075c80fb99c83aaad";
const TOKEN_VALUE: u64 = 150_000_000;
pub const PROFILE: &str = "trestly-mainnet-v2";
fn fail(s: impl ToString) -> CoreError { CoreError::InvalidRequest(s.to_string()) }
fn parse<T: serde::de::DeserializeOwned>(v: Value) -> Result<T> { serde_json::from_value(v).map_err(fail) }
fn number(s: &str) -> Result<i64> { if s.is_empty()||!s.bytes().all(|b|b.is_ascii_digit()){return Err(fail("Expected integer base units"));}s.parse::<i64>().map_err(fail) }
fn script(actor:&str,state:Value)->Result<String>{
 let result=kusdt_kaspa::api::run("script",&json!({"actor":actor,"state":state}).to_string()).map_err(fail)?;
 result["scriptPublicKey"].as_str().map(str::to_owned).ok_or_else(||fail("Missing compiled script"))
}
fn address(spk:&str)->Result<String>{
 let bytes=hex::decode(spk).map_err(fail)?;if bytes.len()<2{return Err(fail("Invalid script"));}
 let spk=kaspa_consensus_core::tx::ScriptPublicKey::from_vec(u16::from_be_bytes([bytes[0],bytes[1]]),bytes[2..].to_vec());
 extract_script_pub_key_address(&spk,kaspa_addresses::Prefix::Mainnet).map(|a|a.to_string()).map_err(fail)
}
fn checked_pool(p:&PoolState)->Result<()> {
 p.check_open().map_err(fail)?;
 if p.token_covid!=TOKEN||p.paused{return Err(fail("The verified kUSDT pool is paused or trades another token"));}
 for n in [p.kas_reserve,p.token_reserve,p.total_shares,p.base_value,p.protocol_kas,p.protocol_tokens,p.window_credit,p.window_ref] {
  if !(0..=1_000_000_000_000_000).contains(&n){return Err(fail("Pool state is outside supported bounds"));}
 }
 // The pool's own baseValue is independent of the 1.5 KAS token-cell reserve.
 // In particular the pinned Mainnet pool uses a perfectly valid 1 KAS base.
 if p.base_value<=0{return Err(fail("Pool baseValue must be positive"));}
 if !(1..=10_000).contains(&p.max_out_bps){return Err(fail("Pool maxOutBps is outside 1..=10000"));}
 if !(-1_000_000_000_000_000..=1_000_000_000_000_000).contains(&p.window_out){return Err(fail("Pool windowOut is outside supported bounds"));}
 Ok(())
}
/// Public script reconstruction used BEFORE locating UTXOs on our own node.
pub fn describe(raw:&str)->Result<Value>{
 if raw.len()>256*1024{return Err(fail("Pool response too large"));}
 let v:Value=serde_json::from_str(raw).map_err(fail)?;
 let p:PoolState=parse(v["poolState"].clone())?;checked_pool(&p)?;
 let reserve=pool::reserve_state(POOL,p.reserve_amount());
 let ps=script("Pool",serde_json::to_value(&p).map_err(fail)?)?;
 let rs=script("KCC20",serde_json::to_value(&reserve).map_err(fail)?)?;
 let mut result=json!({"profile":PROFILE,"poolScript":ps,"poolAddress":address(&ps)?,"poolAmount":p.value().to_string(),"reserveScript":rs,"reserveAddress":address(&rs)?,"reserveState":reserve,"poolId":POOL,"tokenId":TOKEN});
 if !v["payerState"].is_null(){let s:TokenState=parse(v["payerState"].clone())?;let spk=script("KCC20",serde_json::to_value(s).map_err(fail)?)?;result["payerScript"]=json!(spk);result["payerAddress"]=json!(address(&spk)?);}
 Ok(result)
}
#[derive(Debug,Clone,Serialize,Deserialize)]
#[serde(rename_all="camelCase",deny_unknown_fields)]
pub struct Request {
 pub sender:String,pub side:String,pub amount_in:String,pub min_out:String,pub max_fee_sompi:String,
 pub feerate:u64,pub now_daa:String,pub pool:Located<PoolState>,pub reserve:Located<TokenState>,
 pub payer:Option<Located<TokenState>>,pub funding:Vec<Utxo>,
}
fn read(raw:&str)->Result<Request>{if raw.len()>512*1024{return Err(fail("Swap request too large"));}serde_json::from_str(raw).map_err(fail)}
fn sender_script(sender:&str)->Result<String>{
 if !sender.starts_with("kaspa:"){return Err(fail("Trestly native swaps are Mainnet-only"));}
 let a=Address::try_from(sender).map_err(fail)?;let s=pay_to_address_script(&a);let mut b=s.version().to_be_bytes().to_vec();b.extend(s.script());Ok(hex::encode(b))
}
fn verify_coin(u:&Utxo,spk:&str,cid:Option<&str>)->Result<()> {
 if u.script_public_key!=spk||u.covenant_id.as_deref()!=cid||u.is_coinbase||u.block_daa_score==0||u.block_daa_score==u64::MAX||u.amount==0{return Err(fail("Unconfirmed or mismatching own-node UTXO"));}
 let _=u.outpoint().map_err(fail)?;Ok(())
}
fn check(r:&Request)->Result<(i64,i64,u64)> {
 checked_pool(&r.pool.state)?;
 let input=number(&r.amount_in)?;let minimum=number(&r.min_out)?;let cap=number(&r.max_fee_sompi)?;
 if input<=0||input>1_000_000_000_000_000||minimum<=0||cap<=0||cap>100_000_000||r.feerate<100||r.feerate>333{return Err(fail("Invalid amount, fee allowance or busy network"));}
 let desc=describe(&json!({"poolState":r.pool.state}).to_string())?;
 verify_coin(&r.pool.utxo,desc["poolScript"].as_str().unwrap(),Some(POOL))?;
 verify_coin(&r.reserve.utxo,desc["reserveScript"].as_str().unwrap(),Some(TOKEN))?;
 if r.pool.utxo.amount!=r.pool.state.value()||r.reserve.utxo.amount<TOKEN_VALUE||r.reserve.state!=pool::reserve_state(POOL,r.pool.state.reserve_amount()){return Err(fail("Pool/reserve state mismatch"));}
 let own=sender_script(&r.sender)?;
 let now=number(&r.now_daa)?;
 if now<0||(now as u64)<r.pool.utxo.block_daa_score{return Err(fail("Stale node clock"));}
 let elapsed=pool::claim_for(&r.pool.state,now,r.pool.utxo.block_daa_score).map_err(fail)?;
 let mut points=std::collections::HashSet::new();
 for u in [&r.pool.utxo,&r.reserve.utxo].into_iter().chain(r.payer.iter().map(|p|&p.utxo)).chain(r.funding.iter()) {if !points.insert((u.transaction_id.clone(),u.index)){return Err(fail("Duplicate swap input"));}}
 if points.len()>8||r.funding.is_empty(){return Err(fail("Swap needs 1–6 confirmed plain KAS funding inputs; consolidate first if needed"));}
 for u in &r.funding{verify_coin(u,&own,None)?;}
 let out=if r.side=="buy" {
  if r.payer.is_some(){return Err(fail("Buy cannot consume user tokens"));}
  let total=r.funding.iter().try_fold(0u64,|a,u|a.checked_add(u.amount)).ok_or_else(||fail("Funding overflow"))?;
  if total<(input as u64).checked_add(TOKEN_VALUE+cap as u64+20_000_000).ok_or_else(||fail("Amount overflow"))?{return Err(CoreError::InsufficientFunds);}
  pool::buy_quote(&r.pool.state,input)
 } else if r.side=="sell" {
  let p=r.payer.as_ref().ok_or_else(||fail("Missing owned kUSDT cell"))?;
  let spk=script("KCC20",serde_json::to_value(&p.state).map_err(fail)?)?;verify_coin(&p.utxo,&spk,Some(TOKEN))?;
  let owner=Address::try_from(r.sender.as_str()).map_err(fail)?;
  if p.state.owner_scheme!=0||p.state.owner!=hex::encode(owner.payload.as_slice())||p.state.borrow_scheme!=0||p.state.extension_commitment!="00".repeat(32)||p.state.amount<input{return Err(fail("Unsupported or insufficient owned kUSDT cell; consolidate first"));}
  let q=pool::sell_quote(&r.pool.state,input);pool::breaker_after(&r.pool.state,q,elapsed).map_err(fail)?;q
 } else{return Err(fail("Unknown swap direction"));};
 if out<minimum||out<=0{return Err(fail("Quote changed: refresh and approve the new quote"));}
 Ok((out,input,cap as u64))
}
pub fn prepare(raw:&str)->Result<Value>{
 let r=read(raw)?;let(out,input,cap)=check(&r)?;
 let hash=hex::encode(Sha256::digest(serde_json::to_vec(&r).map_err(fail)?));
 Ok(json!({"reviewHash":hash,"sender":r.sender,"side":r.side,"amountIn":input.to_string(),"amountOut":out.to_string(),"minOut":r.min_out,"maxFeeSompi":cap.to_string(),"tokenValueSompi":TOKEN_VALUE.to_string(),"poolId":POOL,"tokenId":TOKEN,"poolTransactionId":r.pool.utxo.transaction_id,"profile":PROFILE}))
}
pub fn sign(secret:&str,raw:&str,review_hash:&str)->Result<Value>{
 let review=prepare(raw)?;if review["reviewHash"].as_str()!=Some(review_hash){return Err(CoreError::ReviewMismatch);}
 let r=read(raw)?;if !crate::controls_address(secret,&r.sender)?{return Err(fail("Wallet does not control swap sender"));}
 let(out,input,cap)=check(&r)?;
 let key=crate::derive_key(secret)?;let mut key_hex=hex::encode(&*key);
 let common=Common{network:Network::Mainnet,feerate:Some(r.feerate),funding:r.funding.iter().cloned().map(|utxo|Funding{utxo,secret_key:key_hex.clone()}).collect(),change_address:r.sender.clone()};
 let result=if r.side=="buy"{
  let mut req=pool::BuyRequest{common,pool:r.pool.clone(),reserve:r.reserve.clone(),kas_in:input,tokens_out:out,buyer:crate::public_key(secret)?,token_value:TOKEN_VALUE,now_daa:Some(number(&r.now_daa)?)};
  let result=pool::buy(&req);for f in &mut req.common.funding{f.secret_key.zeroize();}result
 }else{
  let p=r.payer.clone().unwrap();let payer=pool::OwnedToken{utxo:p.utxo,state:p.state,secret_key:key_hex.clone()};
  let mut req=pool::SellRequest{common,pool:r.pool.clone(),reserve:r.reserve.clone(),payer,tokens_in:input,kas_out:out,token_value:TOKEN_VALUE,now_daa:number(&r.now_daa)?};
  let result=pool::sell(&req);for f in &mut req.common.funding{f.secret_key.zeroize();}req.payer.secret_key.zeroize();result
 };key_hex.zeroize();let built=result.map_err(fail)?;
 if built.fee>cap{return Err(fail("Actual network fee exceeds approved allowance; nothing broadcast"));}
 Ok(json!({"transactionId":built.txid,"wrpcJson":serde_json::to_string(&built.transaction).map_err(fail)?,"feeSompi":built.fee.to_string(),"review":review}))
}
