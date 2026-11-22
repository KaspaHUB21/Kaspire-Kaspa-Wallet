use super::*;
#[test]fn trestly_official_mainnet_pool_script_matches_published_artifact(){
 let v:Value=serde_json::from_str(include_str!("trestly_mainnet_pool_fixture.json")).unwrap();
 let d=describe(&json!({"poolState":v["pool"]["state"]}).to_string()).unwrap();
 assert_eq!(d["profile"],PROFILE);
 assert_eq!(d["poolScript"],v["pool"]["utxo"]["scriptPublicKey"]);
 assert_eq!(d["reserveScript"],v["reserve"]["utxo"]["scriptPublicKey"]);
 assert_eq!(d["poolAmount"].as_str().unwrap().parse::<u64>().unwrap(),v["pool"]["utxo"]["amount"].as_u64().unwrap());
}
#[test]fn trestly_pool_base_is_not_the_token_cell_reserve(){
 let mut p=fixture("buy").pool.state;
 for base in [1,100_000_000,149_999_999,150_000_000]{p.base_value=base;checked_pool(&p).unwrap();}
 p.base_value=0;assert!(checked_pool(&p).is_err());
 p.base_value=-1;assert!(checked_pool(&p).is_err());
 p.base_value=100_000_000;p.max_out_bps=0;assert!(checked_pool(&p).is_err());
 p.max_out_bps=10_001;assert!(checked_pool(&p).is_err());
 p.max_out_bps=1000;p.window_out=-9_995_000_000;checked_pool(&p).unwrap();
 p.window_out=i64::MIN;assert!(checked_pool(&p).is_err());
}
#[test]fn trestly_mainnet_state_builds_buy_and_sell_in_the_real_script_engine(){
 let v:Value=serde_json::from_str(include_str!("trestly_mainnet_pool_fixture.json")).unwrap();
 for side in ["buy","sell"]{
  let mut r=fixture(side);
  r.pool.state=serde_json::from_value(v["pool"]["state"].clone()).unwrap();
  let d=describe(&json!({"poolState":r.pool.state}).to_string()).unwrap();
  r.pool.utxo.amount=r.pool.state.value();r.pool.utxo.script_public_key=d["poolScript"].as_str().unwrap().into();
  r.reserve.state=pool::reserve_state(POOL,r.pool.state.reserve_amount());
  r.reserve.utxo.script_public_key=d["reserveScript"].as_str().unwrap().into();
  let raw=serde_json::to_string(&r).unwrap();let review=prepare(&raw).unwrap();
  assert_eq!(review["profile"],PROFILE);
  let signed=sign(SECRET,&raw,review["reviewHash"].as_str().unwrap()).unwrap();
  assert_eq!(signed["transactionId"].as_str().unwrap().len(),64);
  assert!(signed["feeSompi"].as_str().unwrap().parse::<u64>().unwrap()<=100_000_000);
 }
}
const SECRET:&str="private:0000000000000000000000000000000000000000000000000000000000000001";
#[test]fn trestly_sell_max_executes_and_leaves_no_token_change_cell(){
 for amount in [1_234_567,100_000_000]{
  let mut r=fixture("sell");
  let payer=r.payer.as_mut().unwrap();payer.state.amount=amount;
  payer.utxo.script_public_key=script("KCC20",serde_json::to_value(&payer.state).unwrap()).unwrap();
  r.amount_in=amount.to_string();
  let raw=serde_json::to_string(&r).unwrap();let review=prepare(&raw).unwrap();
  assert_eq!(review["amountIn"],r.amount_in);
  let signed=sign(SECRET,&raw,review["reviewHash"].as_str().unwrap()).unwrap();
  let tx:Value=serde_json::from_str(signed["wrpcJson"].as_str().unwrap()).unwrap();
  assert_eq!(tx["outputs"].as_array().unwrap().iter().filter(|o|o["covenant"]["covenantId"]==TOKEN).count(),1,"Only the pool reserve token cell remains");
 }
}
fn fixture(side:&str)->Request{
 let sender=crate::derive_address(SECRET).unwrap().to_string();let owner=crate::public_key(SECRET).unwrap();
 let state:PoolState=serde_json::from_value(json!({"tokenCovid":TOKEN,"kasReserve":"1000000000000","tokenReserve":"50000000000","totalShares":"1000000000","protocolKas":0,"protocolTokens":0,"baseValue":150000000,"admin":owner,"maxOutBps":1000,"windowLen":36000,"windowCredit":0,"windowRef":"1000000000000","windowOut":0,"paused":false,"guardian":owner})).unwrap();
 let d=describe(&json!({"poolState":state}).to_string()).unwrap();
 let u=|id:&str,amount:u64,spk:String,cid:Option<&str>|Utxo{transaction_id:id.repeat(32),index:0,amount,script_public_key:spk,block_daa_score:1000,is_coinbase:false,covenant_id:cid.map(str::to_owned)};
 let reserve=pool::reserve_state(POOL,state.reserve_amount());
 let payer=TokenState{amount:100_000_000,owner,owner_scheme:0,borrow_scheme:0,borrow_guard:"00".repeat(32),extension_commitment:"00".repeat(32)};
 let ps=script("KCC20",serde_json::to_value(&payer).unwrap()).unwrap();
 Request{sender:sender.clone(),side:side.into(),amount_in:if side=="buy"{"100000000"}else{"1000000"}.into(),min_out:"1".into(),max_fee_sompi:"100000000".into(),feerate:100,now_daa:"2000".into(),pool:Located{utxo:u("11",state.value(),d["poolScript"].as_str().unwrap().into(),Some(POOL)),state},reserve:Located{utxo:u("22",TOKEN_VALUE,d["reserveScript"].as_str().unwrap().into(),Some(TOKEN)),state:reserve},payer:if side=="buy"{None}else{Some(Located{utxo:u("33",TOKEN_VALUE,ps,Some(TOKEN)),state:payer})},funding:vec![u("44",200000000000,sender_script(&sender).unwrap(),None)]}
}
#[test]fn trestly_native_buy_and_sell_execute_all_contracts(){
 for side in ["buy","sell"]{let r=fixture(side);let raw=serde_json::to_string(&r).unwrap();let review=prepare(&raw).unwrap();let result=sign(SECRET,&raw,review["reviewHash"].as_str().unwrap()).unwrap();assert_eq!(result["transactionId"].as_str().unwrap().len(),64);assert!(!result.to_string().contains("secretKey"));assert!(!result.to_string().contains("private:"));let tx:Value=serde_json::from_str(result["wrpcJson"].as_str().unwrap()).unwrap();assert_eq!(tx["version"],1);assert!(tx["inputs"].as_array().unwrap().iter().all(|i|i["computeBudget"].as_u64().unwrap()>0));}
}
#[test]fn trestly_rejects_tampered_review_wrong_key_and_bad_coins(){
 let r=fixture("buy");let raw=serde_json::to_string(&r).unwrap();let review=prepare(&raw).unwrap();assert!(sign(SECRET,&raw,"wrong").is_err());
 for mode in 0..7 {let mut v=serde_json::to_value(&r).unwrap();match mode {0=>v["pool"]["utxo"]["covenantId"]=json!(TOKEN),1=>v["reserve"]["state"]["amount"]=json!(1),2=>v["funding"][0]["isCoinbase"]=json!(true),3=>v["minOut"]=json!("999999999999"),4=>v["sender"]=json!(r.sender.replace("kaspa:","kaspatest:")),5=>v["pool"]["state"]["paused"]=json!(true),_=>v["amountIn"]=json!("9999999999999999999")};assert!(prepare(&v.to_string()).is_err(),"mode {mode}");assert!(sign(SECRET,&v.to_string(),review["reviewHash"].as_str().unwrap()).is_err());}
}
