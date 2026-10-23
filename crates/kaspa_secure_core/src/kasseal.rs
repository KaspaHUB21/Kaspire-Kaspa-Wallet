//! Kasseal TN10 swaps: pinned program bytes, wallet ownership and exact economic bounds.
//! The remote SDK planner is not a signing authority. Every signed contract runs locally.
use crate::{CoreError, Result, pskt::{PsktRequest, PsktScriptInput}};
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{hashing::sighash_type::SigHashType, tx::{Transaction, UtxoEntry}, Hash};
use kaspa_txscript::{pay_to_address_script, pay_to_script_hash_script};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::{HashMap, HashSet}, str::FromStr, sync::OnceLock};

fn bad(s: &str) -> CoreError { CoreError::InvalidRequest(format!("Kasseal: {s}")) }
#[derive(Deserialize)]
#[serde(rename_all="camelCase")]
struct Pin { length: usize, state_offset: usize, state_length: usize, creator_offsets: Vec<usize>, sha256: String }
#[derive(Deserialize)]
struct Pins { curves: Vec<Pin>, pool: Pin, token: Pin }
fn pins(mainnet: bool) -> &'static Pins {
    static MAINNET: OnceLock<Pins> = OnceLock::new();
    if mainnet {return MAINNET.get_or_init(||serde_json::from_str(include_str!("kasseal_mainnet_templates.json")).expect("bundled Mainnet Kasseal pins"));}
    static PINS: OnceLock<Pins> = OnceLock::new();
    PINS.get_or_init(|| serde_json::from_str(include_str!("kasseal_tn10_templates.json")).expect("bundled Kasseal pins"))
}
fn network(request:&PsktRequest,kind:&str)->Result<(&'static str,Prefix,&'static Pins)>{
    if request.profile.as_deref()==Some(format!("kasseal-mainnet-{kind}-v1").as_str()) {Ok(("mainnet",Prefix::Mainnet,pins(true)))}
    else if request.profile.as_deref()==Some(format!("kasseal-tn10-{kind}-v1").as_str()) {Ok(("testnet-10",Prefix::Testnet,pins(false)))}
    else {Err(bad("unsupported network profile"))}
}
fn matches(program: &[u8], pin: &Pin) -> bool {
    if program.len()!=pin.length || pin.state_offset+pin.state_length>program.len() { return false; }
    let mut normalized=program.to_vec();
    normalized[pin.state_offset..pin.state_offset+pin.state_length].fill(0);
    let mut creator=None;
    for offset in &pin.creator_offsets {
        let Some(spk)=program.get(*offset..*offset+36) else {return false};
        if spk[..3]!=[0,0,32] || spk[35]!=0xac || creator.is_some_and(|old:&[u8]|old!=spk) {return false;}
        creator=Some(spk); normalized[*offset..*offset+36].fill(0);
    }
    hex::encode(Sha256::digest(normalized))==pin.sha256
}
/// Recover the last pushed redeem script, not a caller's claimed program.
fn redeem(script: &[u8]) -> Result<Vec<u8>> {
    let mut pos=0usize; let mut last=Vec::new();
    while pos<script.len() {
        let op=script[pos];pos+=1;
        let len=match op {
            0=>{last.clear();continue},
            1..=75=>op as usize,
            76=>{let n=*script.get(pos).ok_or_else(||bad("truncated sigscript"))? as usize;pos+=1;n},
            77=>{let b=script.get(pos..pos+2).ok_or_else(||bad("truncated sigscript"))?;pos+=2;u16::from_le_bytes(b.try_into().unwrap()) as usize},
            78=>{let b=script.get(pos..pos+4).ok_or_else(||bad("truncated sigscript"))?;pos+=4;u32::from_le_bytes(b.try_into().unwrap()) as usize},
            79|81..=96=>{last.clear();continue},
            _=>return Err(bad("non-push signature script")),
        };
        last=script.get(pos..pos.checked_add(len).ok_or_else(||bad("sigscript overflow"))?).ok_or_else(||bad("truncated redeem script"))?.to_vec();pos+=len;
    }
    if last.is_empty(){return Err(bad("missing redeem script"));}Ok(last)
}
fn token(program:&[u8]) -> Result<(u64, [u8;32], u8)> {
    if !matches(program,&pins(false).token) {return Err(bad("token is not the pinned KCC20 reference program"));}
    let s=&program[34..146];
    if s[0]!=8 || s[9]!=32 || s[42]!=1 || ![0,4].contains(&s[43]) || s[44]!=1 || s[45]!=0 || s[46]!=32 || s[79]!=32 || s[47..112].iter().enumerate().any(|(i,b)|i!=32&&*b!=0) {
        return Err(bad("unsupported token ownership, borrowing or extension"));
    }
    let amount=u64::from_le_bytes(s[1..9].try_into().unwrap());
    if amount>1_200_000_000 {return Err(bad("token amount exceeds fixed supply"));}
    Ok((amount,s[10..42].try_into().unwrap(),s[43]))
}
fn number(value:&Value,key:&str)->Result<u64>{
    value.get(key).and_then(Value::as_str).and_then(|s|s.parse().ok()).ok_or_else(||bad("missing decimal trade limit"))
}
pub(crate) fn validate(request:&PsktRequest, tx:&Transaction, entries:&[UtxoEntry], signatures:&[(usize,SigHashType)], scripts:&HashMap<usize,PsktScriptInput>) -> Result<()> {
    let (network,prefix,pins)=network(request,"swap")?;
    let sender=Address::try_from(request.sender.as_str()).map_err(|_|bad("invalid wallet address"))?;
    if sender.prefix!=prefix || sender.version!=Version::PubKey || tx.version!=1 || !tx.payload.is_empty() || tx.inputs.len()>32 || tx.outputs.len()>16 || signatures.iter().any(|(_,s)|s.to_u8()!=1) {
        return Err(bad("requires a TN10 Schnorr wallet, version 1 and SIGHASH_ALL"));
    }
    let summary=request.trade_summary.as_ref().ok_or_else(||bad("missing reviewed terms"))?;
    let id=|s:Option<&str>|Hash::from_str(s.ok_or_else(||bad("missing covenant ID"))?).map_err(|_|bad("invalid covenant ID"));
    let tid=id(request.token_id.as_deref())?;let mid=id(request.lp_covenant_id.as_deref())?;
    if tid==mid || summary["network"]!=network || summary["tokenId"]!=tid.to_string() || summary["marketId"]!=mid.to_string() || summary["side"].as_str()!=request.side.as_deref() {return Err(bad("trade identity or network mismatch"));}
    let buy=match request.side.as_deref(){Some("buy")=>true,Some("sell")=>false,_=>return Err(bad("invalid direction"))};
    let owner:&[u8]=sender.payload.as_slice();let wallet=pay_to_address_script(&sender);
    let selected=signatures.iter().map(|(i,_)|*i).collect::<HashSet<_>>();
    let mut token_in=0u64;let mut token_out=0u64;let mut locked_in=0u64;let mut locked_out=0u64;
    let mut plain_in=0u64;let mut plain_out=0u64;let mut market_in=None;let mut market_out=None;
    for (i,entry) in entries.iter().enumerate() {
        if entry.covenant_id.is_none() {
            if entry.script_public_key!=wallet || !selected.contains(&i) {return Err(bad("funding must be controlled by the selected wallet"));}
            plain_in=plain_in.checked_add(entry.amount).ok_or_else(||bad("amount overflow"))?;continue;
        }
        let script=match scripts.get(&i).and_then(|s|s.prebuilt_signature_script.as_ref()) {Some(s)=>hex::decode(s).map_err(|_|bad("invalid prebuilt script"))?,None=>tx.inputs[i].signature_script.clone()};
        let program=redeem(&script)?;
        if pay_to_script_hash_script(&program)!=entry.script_public_key {return Err(bad("input program differs from live script"));}
        if entry.covenant_id==Some(tid) {
            let(amount,key,scheme)=token(&program)?;
            if scheme==0 && key.as_slice()==owner {
                if !selected.contains(&i) {return Err(bad("owned token input is not selected"));}
                token_in=token_in.checked_add(amount).ok_or_else(||bad("token overflow"))?;locked_in+=entry.amount;
            } else if scheme!=4 || key!=mid.as_bytes() || selected.contains(&i) {return Err(bad("unexpected token owner or signing a venue input"));}
        } else if entry.covenant_id==Some(mid) && !selected.contains(&i) && market_in.is_none() {
            let pinned=if summary["venue"]=="pool" {matches(&program,&pins.pool)} else if summary["venue"]=="curve" {pins.curves.iter().any(|p|matches(&program,p))} else {false};
            if !pinned || program.get(1)!=Some(&32) || program.get(2..34)!=Some(tid.as_bytes().as_slice()) {return Err(bad("venue is not a pinned TN10 program for this token"));}
            market_in=Some(entry.amount);
        } else {return Err(bad("unexpected covenant input"));}
    }
    let programs=summary["outputPrograms"].as_object().ok_or_else(||bad("missing output programs"))?;
    for (i,output) in tx.outputs.iter().enumerate() {
        let Some(binding)=output.covenant else {
            if output.script_public_key!=wallet {return Err(bad("unexpected external KAS payout"));}
            plain_out=plain_out.checked_add(output.value).ok_or_else(||bad("amount overflow"))?;continue;
        };
        let program=hex::decode(programs.get(&i.to_string()).and_then(Value::as_str).ok_or_else(||bad("missing output redeem script"))?).map_err(|_|bad("invalid output redeem script"))?;
        if pay_to_script_hash_script(&program)!=output.script_public_key {return Err(bad("output program differs from its commitment"));}
        if binding.covenant_id==tid {
            let(amount,key,scheme)=token(&program)?;
            if scheme==0 && key.as_slice()==owner {token_out=token_out.checked_add(amount).ok_or_else(||bad("token overflow"))?;locked_out+=output.value;}
            else if scheme!=4 || key!=mid.as_bytes() {return Err(bad("tokens leave the wallet/venue ownership boundary"));}
        } else if binding.covenant_id==mid && market_out.is_none() {
            let pinned=if summary["venue"]=="pool" {matches(&program,&pins.pool)}else{pins.curves.iter().any(|p|matches(&program,p))};
            if !pinned || program.get(2..34)!=Some(tid.as_bytes().as_slice()) {return Err(bad("unexpected venue continuation"));}
            market_out=Some(output.value);
        } else {return Err(bad("unexpected covenant output"));}
    }
    let market_in=market_in.ok_or_else(||bad("missing venue input"))? as i128;
    let market_out=market_out.ok_or_else(||bad("missing venue continuation"))? as i128;
    let delta=token_out as i128-token_in as i128;
    let amount=number(summary,"tokenAmount")? as i128;
    let minimum=number(summary,"minimumReceive")? as i128;
    let raw=number(summary,"rawAmount")? as i128;
    let max=number(summary,"maxSpendSompi")? as i128;
    let kas=number(summary,"kasSompi")? as i128;
    let total_in: u128=entries.iter().map(|e|e.amount as u128).sum();
    let total_out: u128=tx.outputs.iter().map(|o|o.value as u128).sum();
    let fee=total_in.checked_sub(total_out).ok_or_else(||bad("unfunded transaction"))?;
    if fee>200_000_000 || fee!=number(summary,"networkFeeSompi")? as u128 {return Err(bad("network fee differs from reviewed terms or exceeds 2 KAS"));}
    let debit=plain_in as i128-plain_out as i128;
    if let Some(net)=summary["walletNetSompi"].as_str() {
        if net.parse::<i128>().ok()!=Some(-debit) || number(summary,"walletChangeSompi")?!=plain_out {return Err(bad("wallet net payout or change differs from locally rebuilt transaction"));}
        if !buy && summary.get("depositRefundSompi").is_some() && number(summary,"depositRefundSompi")? as i128!=locked_in as i128-locked_out as i128 {return Err(bad("deposit refund differs from locally rebuilt transaction"));}
    }
    if buy {
        if token_in!=0 || delta!=amount || delta<minimum || amount<=0 || kas<=0 || kas>raw || market_out-market_in!=kas || debit!=kas+locked_out as i128+fee as i128 || debit>max {return Err(bad("buy amounts or maximum all-in cost differ from reviewed terms"));}
    } else if token_in==0 || -delta!=amount || amount!=raw || market_in-market_out!=kas || kas<minimum || -debit!=kas+locked_in as i128-locked_out as i128-fee as i128 || -debit<minimum {
        return Err(bad("sell amount or minimum net payout differs from reviewed terms"));
    }
    Ok(())
}

/// Token-only self preparation. No venue, recipient or arbitrary template can be signed.
pub(crate) fn validate_preparation(request:&PsktRequest,tx:&Transaction,entries:&[UtxoEntry],signatures:&[(usize,SigHashType)],scripts:&HashMap<usize,PsktScriptInput>)->Result<()> {
    let (network,prefix,_)=network(request,"prepare")?;
    let sender=Address::try_from(request.sender.as_str()).map_err(|_|bad("invalid preparation owner"))?;
    if sender.prefix!=prefix || sender.version!=Version::PubKey || tx.version!=1 || !tx.payload.is_empty() || tx.inputs.len()>32 || tx.outputs.len()>4 || signatures.iter().any(|(_,s)|s.to_u8()!=1) {return Err(bad("invalid network preparation envelope"));}
    let summary=request.trade_summary.as_ref().ok_or_else(||bad("missing preparation terms"))?;
    let tid=Hash::from_str(request.token_id.as_deref().ok_or_else(||bad("missing token ID"))?).map_err(|_|bad("invalid token ID"))?;
    if request.side.as_deref()!=Some("sell") || summary["side"]!="sell" || summary["network"]!=network || summary["tokenId"]!=tid.to_string() || summary["stage"]!="preparation" {return Err(bad("preparation identity differs"));}
    let target=number(summary,"rawAmount")?;
    if target==0 || target>1_200_000_000 || target!=number(summary,"tokenAmount")? || number(summary,"maxPreparationDebitSompi")?!=700_000_000 {return Err(bad("preparation limits differ"));}
    let wallet=pay_to_address_script(&sender);let owner=sender.payload.as_slice();
    let selected=signatures.iter().map(|(i,_)|*i).collect::<HashSet<_>>();
    let(mut token_in,mut token_out,mut locked_in,mut locked_out,mut plain_in,mut plain_out)=(0u64,0u64,0u64,0u64,0u64,0u64);
    let(mut count_in,mut count_out,mut carved)=(0usize,0usize,false);
    for (i,e) in entries.iter().enumerate(){
        if !selected.contains(&i){return Err(bad("all preparation inputs must be wallet-controlled"));}
        if e.covenant_id.is_none(){if e.script_public_key!=wallet{return Err(bad("foreign preparation funding"));}plain_in=plain_in.checked_add(e.amount).ok_or_else(||bad("overflow"))?;continue;}
        if e.covenant_id!=Some(tid){return Err(bad("foreign preparation covenant"));}
        let script=match scripts.get(&i).and_then(|s|s.prebuilt_signature_script.as_ref()){Some(s)=>hex::decode(s).map_err(|_|bad("invalid preparation script"))?,None=>tx.inputs[i].signature_script.clone()};
        let program=redeem(&script)?;let(amount,key,scheme)=token(&program)?;
        if scheme!=0 || key.as_slice()!=owner || pay_to_script_hash_script(&program)!=e.script_public_key{return Err(bad("preparation token is not wallet owned"));}
        token_in=token_in.checked_add(amount).ok_or_else(||bad("overflow"))?;locked_in=locked_in.checked_add(e.amount).ok_or_else(||bad("overflow"))?;count_in+=1;
    }
    let programs=summary["outputPrograms"].as_object().ok_or_else(||bad("missing preparation output programs"))?;
    for (i,o) in tx.outputs.iter().enumerate(){
        let Some(binding)=o.covenant else{if o.script_public_key!=wallet{return Err(bad("external preparation payout"));}plain_out=plain_out.checked_add(o.value).ok_or_else(||bad("overflow"))?;continue;};
        if binding.covenant_id!=tid{return Err(bad("foreign preparation output"));}
        let program=hex::decode(programs.get(&i.to_string()).and_then(Value::as_str).ok_or_else(||bad("missing preparation output script"))?).map_err(|_|bad("invalid preparation output script"))?;
        let(amount,key,scheme)=token(&program)?;
        if scheme!=0 || key.as_slice()!=owner || pay_to_script_hash_script(&program)!=o.script_public_key{return Err(bad("preparation sends tokens outside the wallet"));}
        if o.value<250_000_000{return Err(bad("preparation token deposit below safe storage mass floor"));}
        token_out=token_out.checked_add(amount).ok_or_else(||bad("overflow"))?;locked_out=locked_out.checked_add(o.value).ok_or_else(||bad("overflow"))?;count_out+=1;carved|=amount==target;
    }
    let shape=match summary["operation"].as_str(){Some("split")=>count_in==1&&count_out==2&&carved,Some("merge")=>(2..=3).contains(&count_in)&&count_out==1,_=>false};
    if !shape || token_in==0 || token_in!=token_out{return Err(bad("preparation shape or token conservation differs"));}
    let total_in: u128=entries.iter().map(|e|e.amount as u128).sum();let total_out:u128=tx.outputs.iter().map(|o|o.value as u128).sum();
    let fee=total_in.checked_sub(total_out).ok_or_else(||bad("unfunded preparation"))?;
    let debit=plain_in as i128-plain_out as i128;
    if fee>200_000_000 || fee!=number(summary,"networkFeeSompi")? as u128 || locked_out as i128-locked_in as i128>500_000_000 || debit>700_000_000 || debit!=locked_out as i128-locked_in as i128+fee as i128 || summary["walletNetSompi"].as_str().and_then(|s|s.parse::<i128>().ok())!=Some(-debit) || number(summary,"walletChangeSompi")?!=plain_out {return Err(bad("preparation fee, deposits or wallet debit differs"));}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn kasseal_mainnet_curve_pool_and_preparation_execute_and_reject_cross_network() {
        for raw in [include_str!("fixtures/kasseal-mainnet-curve-buy.json"),include_str!("fixtures/kasseal-mainnet-pool-buy.json"),include_str!("fixtures/kasseal-mainnet-pool-sell.json"),include_str!("fixtures/kasseal-mainnet-split.json"),include_str!("fixtures/kasseal-mainnet-merge.json")] {
            let request:PsktRequest=serde_json::from_str(raw).unwrap();
            let review=crate::prepare_pskt(&request).unwrap();
            let signed=crate::sign_pskt(&format!("private:{:064x}",1),&request,&review.review_hash).unwrap();
            assert_eq!(signed.transaction_id,review.transaction_id);
            let mut wrong=request.clone();wrong.trade_summary.as_mut().unwrap()["network"]="testnet-10".into();
            assert!(crate::prepare_pskt(&wrong).is_err());
            let mut wrong=request.clone();wrong.profile=wrong.profile.map(|p|p.replace("mainnet","tn10"));
            assert!(crate::prepare_pskt(&wrong).is_err());
        }
        // The owner token is the same reference program on both networks.
        assert_eq!(pins(true).token.sha256,pins(false).token.sha256);
        assert_ne!(pins(true).pool.sha256,pins(false).pool.sha256);
    }
    fn fixture()->PsktRequest {serde_json::from_str(include_str!("fixtures/kasseal-tn10-buy.json")).unwrap()}
    #[test]
    fn kasseal_real_tn10_curve_buy_signs_and_executes_every_contract() {
        let request=fixture();
        let review=crate::prepare_pskt(&request).unwrap();
        assert_eq!(review.profile,"kasseal-tn10-swap-v1");
        let signed=crate::sign_pskt(&format!("private:{:064x}",1),&request,&review.review_hash).unwrap();
        assert_eq!(signed.transaction_id,review.transaction_id);
        assert!(signed.wrpc_json.is_some());
    }
    #[test]
    fn kasseal_pool_buy_and_sell_sign_and_execute_all_contracts() {
        for raw in [include_str!("fixtures/kasseal-tn10-pool-buy.json"),include_str!("fixtures/kasseal-tn10-pool-sell.json")] {
            let request:PsktRequest=serde_json::from_str(raw).unwrap();
            let review=crate::prepare_pskt(&request).unwrap();
            let signed=crate::sign_pskt(&format!("private:{:064x}",1),&request,&review.review_hash).unwrap();
            assert_eq!(signed.transaction_id,review.transaction_id);
        }
    }
    #[test]
    fn kasseal_rejects_other_network_limits_covenants_and_output_programs() {
        let original=fixture();
        for mutation in 0..6 {
            let mut request=original.clone();let s=request.trade_summary.as_mut().unwrap();
            match mutation {
                0=>s["network"]="mainnet".into(),
                1=>s["minimumReceive"]="1200000001".into(),
                2=>s["maxSpendSompi"]="1".into(),
                3=>request.lp_covenant_id=Some("bb".repeat(32)),
                4=>{let key=s["outputPrograms"].as_object().unwrap().keys().next().unwrap().clone();s["outputPrograms"][key]="00".into();},
                _=>request.sign_inputs[0].sighash_type=132,
            }
            assert!(crate::prepare_pskt(&request).is_err(),"mutation {mutation}");
        }
    }
    #[test]
    fn kasseal_preserves_review_binding() {
        let request=fixture();let review=crate::prepare_pskt(&request).unwrap();
        let mut changed=request.clone();changed.ticker=Some("CHANGED".into());
        assert!(crate::sign_pskt(&format!("private:{:064x}",1),&changed,&review.review_hash).is_err());
    }
    #[test]
    fn kasseal_self_preparation_split_and_merge_execute_all_scripts() {
        for raw in [include_str!("fixtures/kasseal-tn10-split.json"),include_str!("fixtures/kasseal-tn10-merge.json")] {
            let request:PsktRequest=serde_json::from_str(raw).unwrap();
            let review=crate::prepare_pskt(&request).unwrap();
            let signed=crate::sign_pskt(&format!("private:{:064x}",1),&request,&review.review_hash).unwrap();
            assert_eq!(signed.transaction_id,review.transaction_id);
            for mutation in 0..5 {
                let mut changed=request.clone();let summary=changed.trade_summary.as_mut().unwrap();
                match mutation {
                    0=>summary["network"]="mainnet".into(),
                    1=>summary["maxPreparationDebitSompi"]="99999999999".into(),
                    2=>summary["operation"]="withdraw".into(),
                    3=>summary["walletNetSompi"]="9999999".into(),
                    _=>changed.sign_inputs[0].sighash_type=132,
                }
                assert!(crate::prepare_pskt(&changed).is_err(),"preparation mutation {mutation}");
            }
        }
    }
    #[test]
    fn kasseal_curve_sale_verifies_trade_deposit_fee_and_true_wallet_net() {
        let request:PsktRequest=serde_json::from_str(include_str!("fixtures/kasseal-tn10-curve-sell.json")).unwrap();
        let review=crate::prepare_pskt(&request).unwrap();
        crate::sign_pskt(&format!("private:{:064x}",1),&request,&review.review_hash).unwrap();
        for field in ["walletNetSompi","walletChangeSompi","depositRefundSompi"] {
            let mut changed=request.clone();changed.trade_summary.as_mut().unwrap()[field]="99999999999999".into();
            assert!(crate::prepare_pskt(&changed).is_err(),"wrong {field}");
        }
        let mut changed=request.clone();
        let s=changed.trade_summary.as_mut().unwrap();
        s["minimumReceive"]=(number(s,"kasSompi").unwrap()+1).to_string().into();
        assert!(crate::prepare_pskt(&changed).is_err(),"a returned deposit must not mask a trade below the minimum");
    }
}
