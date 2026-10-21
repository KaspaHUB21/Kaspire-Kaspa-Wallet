//! Pinned KCC20 reference actor. No indexer-supplied program is trusted.
use crate::{CoreError, Result, KronTransferRequest, PreparedKronTransfer, PsktRequest};
use crate::transaction::parse_utxos;
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::{config::params::MAINNET_PARAMS, mass::MassCalculator,
    hashing::sighash::{calc_schnorr_signature_hash, SigHashReusedValuesUnsync},
    hashing::sighash_type::SIG_HASH_ALL,
    subnets::SUBNETWORK_ID_NATIVE, tx::{Transaction,TransactionInput,TransactionOutput,
    TransactionOutpoint,UtxoEntry,CovenantBinding,ComputeCommit,PopulatedTransaction}, Hash};
use kaspa_txscript::{pay_to_address_script,pay_to_script_hash_script,script_builder::ScriptBuilder};
use serde_json::Value;
use std::{collections::HashSet,str::FromStr};
pub const TEMPLATE_ID: &str = "argent-kcc20-c8a0871";
const DEPOSIT:u64=100_000_000;
fn bad(message:&str)->CoreError {CoreError::InvalidRequest(message.into())}
fn template()->Result<(Vec<u8>,Vec<u8>)>{
    let v:Value=serde_json::from_str(include_str!("kcc20_standard_template.json")).map_err(|_|CoreError::Serialization)?;
    Ok((hex::decode(v["prefix"].as_str().unwrap()).map_err(|_|CoreError::Serialization)?,hex::decode(v["suffix"].as_str().unwrap()).map_err(|_|CoreError::Serialization)?))
}
fn owner(address:&str)->Result<[u8;32]>{
    let a=Address::try_from(address).map_err(|_|CoreError::InvalidAddress)?;
    if a.prefix!=Prefix::Mainnet||a.version!=Version::PubKey {return Err(bad("Standard KCC20 test transfers currently require mainnet Schnorr P2PK addresses"));}
    a.payload.as_slice().try_into().map_err(|_|CoreError::InvalidAddress)
}
#[derive(Clone)]
struct State{amount:u64,owner:[u8;32],borrow:u8,guard:[u8;32],extension:[u8;32]}
fn state_bytes(s:&State)->Vec<u8>{
    let mut v=vec![8];v.extend(s.amount.to_le_bytes());v.push(32);v.extend(s.owner);
    v.extend([1,0,1,s.borrow,32]);v.extend(s.guard);v.push(32);v.extend(s.extension);v
}
fn redeem(s:&State)->Result<Vec<u8>>{let(p,q)=template()?;Ok([p,state_bytes(s),q].concat())}
fn decode(bytes:&[u8])->Result<State>{
    let(p,q)=template()?;
    if bytes.len()!=p.len()+112+q.len()||!bytes.starts_with(&p)||!bytes.ends_with(&q){return Err(bad("KCC20 program is not the pinned KCC20 reference actor"));}
    let v=&bytes[p.len()..p.len()+112];
    if v[0]!=8||v[9]!=32||v[42]!=1||v[43]!=0||v[44]!=1||v[46]!=32||v[79]!=32||v[45]>3{return Err(bad("Unsupported KCC20 state or owner scheme (this test supports scheme 0)"));}
    let amount=u64::from_le_bytes(v[1..9].try_into().unwrap());
    if amount>i64::MAX as u64{return Err(bad("KCC20 amount exceeds signed integer range"));}
    Ok(State{amount,owner:v[10..42].try_into().unwrap(),borrow:v[45],guard:v[47..79].try_into().unwrap(),extension:v[80..112].try_into().unwrap()})
}
fn push(builder:&mut ScriptBuilder,data:&[u8])->Result<()> {builder.add_data(data).map_err(|e|CoreError::Transaction(e.to_string()))?;Ok(())}
fn witness(states:&[State],script:&[u8],leader:bool)->Result<(Vec<u8>,usize)>{
    let mut b=ScriptBuilder::new();
    if leader {
        for column in 0..6 {
            let data=states.iter().flat_map(|s|match column {0=>s.amount.to_le_bytes().to_vec(),1=>s.owner.to_vec(),2=>vec![0],3=>vec![s.borrow],4=>s.guard.to_vec(),_=>s.extension.to_vec()}).collect::<Vec<_>>();
            push(&mut b,&data)?;
        }
    }
    let offset=b.script().len()+1+usize::from(leader);
    push(&mut b,&vec![0;if leader{66}else{65}])?;
    push(&mut b,&hex::decode(if leader{"79c71c23"}else{"fd3ef14a"}).unwrap())?;
    push(&mut b,script)?;Ok((b.drain(),offset))
}
pub fn prepare(request:&KronTransferRequest)->Result<PreparedKronTransfer>{
    if request.template_hash!=TEMPLATE_ID||request.amount==0||request.cells.is_empty()||request.cells.len()>3||request.decimals>18||!request.fee_rate.is_finite()||!(100.0..=10_000.0).contains(&request.fee_rate){return Err(bad("Invalid standard KCC20 transfer parameters"));}
    let sender=owner(&request.sender)?;let recipient=owner(&request.recipient)?;
    let cid=Hash::from_str(&request.covenant_id).map_err(|_|bad("Invalid covenant ID"))?;
    let mut seen=HashSet::new();let mut states=Vec::new();let mut scripts=Vec::new();let mut entries=Vec::new();let mut total=0u64;let mut locked=0u64;
    for cell in &request.cells {
        if !seen.insert((cell.transaction_id.clone(),cell.index)){return Err(bad("Duplicate KCC20 input"));}
        let script=hex::decode(&cell.redeem_script).map_err(|_|bad("Malformed KCC20 redeem script"))?;
        let state=decode(&script)?;
        let spk=pay_to_script_hash_script(&script);
        if state.owner!=sender||state.amount!=cell.token_amount||hex::encode(spk.script())!=cell.script_public_key.strip_prefix("0000").unwrap_or(&cell.script_public_key){return Err(bad("KCC20 owner, amount or live script differs"));}
        if states.first().is_some_and(|s:&State|s.extension!=state.extension){return Err(bad("Different extended token identities cannot be combined"));}
        total=total.checked_add(state.amount).filter(|v|*v<=i64::MAX as u64).ok_or_else(||bad("KCC20 token total overflow"))?;
        locked=locked.checked_add(cell.value_sompi).ok_or(CoreError::Serialization)?;
        entries.push(UtxoEntry::new(cell.value_sompi,spk,cell.block_daa_score,false,Some(cid)));
        states.push(state);scripts.push(script);
    }
    if total<request.amount {return Err(bad("Insufficient KCC20 token balance"));}
    let change=total-request.amount;
    let mut next=vec![State{amount:request.amount,owner:recipient,borrow:0,guard:[0;32],extension:states[0].extension}];
    if change>0{let mut s=states[0].clone();s.amount=change;next.push(s);}
    let address=Address::try_from(request.sender.as_str()).map_err(|_|CoreError::InvalidAddress)?;
    let mut funding=parse_utxos(&request.funding_utxos_json,&address)?;
    funding.retain(|u|!seen.contains(&(u.outpoint.transaction_id.to_string(),u.outpoint.index))&&u.entry.covenant_id.is_none());
    funding.sort_by_key(|u|std::cmp::Reverse(u.entry.amount));
    let mut selected=Vec::new();let mut input_total=locked;
    for u in funding {input_total=input_total.checked_add(u.entry.amount).ok_or(CoreError::Serialization)?;selected.push(u);if input_total>=DEPOSIT*next.len() as u64+50_000_000{break;}}
    if selected.is_empty(){return Err(CoreError::InsufficientFunds);}
    let mut inputs=Vec::new();let mut instructions=Vec::new();
    for(i,(cell,script))in request.cells.iter().zip(&scripts).enumerate(){
        let(sig,offset)=witness(&next,script,i==0)?;
        instructions.push(crate::pskt::PsktScriptInput{input_index:i,script_hex:String::new(),sign_type:Some(1),signature_script:None,prebuilt_signature_script:Some(hex::encode(&sig)),signature_offsets:vec![offset],expected_sighash:None});
        inputs.push(TransactionInput::new_with_mass(TransactionOutpoint::new(cell.transaction_id.parse().map_err(|_|bad("Invalid input ID"))?,cell.index),sig,0,ComputeCommit::ComputeBudget(100.into())));
    }
    let n=inputs.len();
    for u in &selected{inputs.push(TransactionInput::new_with_mass(u.outpoint.clone(),vec![],0,ComputeCommit::ComputeBudget(10.into())));entries.push(u.entry.clone());}
    let make=|fee:u64,storage:u64|->Result<Transaction>{
        let mut outputs=next.iter().map(|s|Ok(TransactionOutput::with_covenant(DEPOSIT,pay_to_script_hash_script(&redeem(s)?),Some(CovenantBinding::new(0,cid))))).collect::<Result<Vec<_>>>()?;
        let kas_change=input_total.checked_sub(DEPOSIT*next.len() as u64+fee).filter(|v|*v>=10_000).ok_or(CoreError::InsufficientFunds)?;
        outputs.push(TransactionOutput::new(kas_change,pay_to_address_script(&address)));
        let tx=Transaction::new(1,inputs.clone(),outputs,0,SUBNETWORK_ID_NATIVE,0,vec![]);tx.set_storage_mass(storage);Ok(tx)
    };
    let calc=MassCalculator::new(MAINNET_PARAMS.mass_per_tx_byte,MAINNET_PARAMS.mass_per_script_pub_key_byte,MAINNET_PARAMS.storage_mass_parameter);
    let mut fee=10_000;let mut masses=(0,0,0,0);
    for _ in 0..8 {
        let mut estimate=make(fee,0)?;for i in n..estimate.inputs.len(){estimate.inputs[i].signature_script=vec![0;66];}
        let non=calc.calc_non_contextual_masses(&estimate);let ctx=calc.calc_contextual_masses(&PopulatedTransaction::new(&estimate,entries.clone())).ok_or_else(||bad("KCC20 storage mass unavailable"))?;
        let cf=MAINNET_PARAMS.block_mass_cofactors();let transient=(non.transient_mass as f64*cf.transient).ceil()as u64;
        let storage=(ctx.storage_mass as f64*cf.storage).ceil()as u64;
        let effective=non.compute_mass.max(transient).max(storage);
        if non.compute_mass>500_000||ctx.storage_mass>100_000||non.transient_mass>1_000_000{return Err(bad("KCC20 transaction exceeds network mass limits; reduce input count"));}
        masses=(non.compute_mass,transient,effective,ctx.storage_mass);
        let next_fee=((effective as f64*request.fee_rate*1.1).ceil()as u64).max(10_000);
        if next_fee==fee{break;}fee=next_fee;
    }
    let tx=make(fee,masses.3)?;
    let populated=PopulatedTransaction::new(&tx,entries.clone());
    let reused=SigHashReusedValuesUnsync::new();
    for instruction in &mut instructions {
        instruction.expected_sighash=Some(calc_schnorr_signature_hash(&populated,instruction.input_index,SIG_HASH_ALL,&reused).to_string());
    }
    let raw:Value=serde_json::from_str(&crate::kcc20::wrpc_safe_json(&tx,&entries)?).map_err(|_|CoreError::Serialization)?;
    let pskt=PsktRequest{sender:request.sender.clone(),profile:Some("kcc20-standard-transfer-v1".into()),token_id:Some(request.covenant_id.clone()),lp_covenant_id:None,ticker:Some(request.ticker.clone()),side:Some("transfer".into()),trade_summary:Some(serde_json::to_value(request).map_err(|_|CoreError::Serialization)?),tx_json_string:raw.to_string(),sign_inputs:(n..inputs.len()).map(|index|crate::PsktSignInput{index,sighash_type:1,expected_sighash:None}).collect(),scripts:instructions};
    Ok(PreparedKronTransfer{pskt_request:pskt,transaction_id:tx.id().to_string(),fee_sompi:fee,input_total_sompi:input_total,output_total_sompi:input_total-fee,token_change:change,locked_kas_sompi:locked,locked_kas_top_up_sompi:(DEPOSIT*next.len()as u64).saturating_sub(locked),locked_kas_released_sompi:locked.saturating_sub(DEPOSIT*next.len()as u64),locked_kas_output_sompi:DEPOSIT*next.len()as u64,covenant_input_count:n,covenant_output_count:next.len(),compute_budget:n as u64*100+selected.len()as u64*10,compute_mass:masses.0,transient_mass:masses.1,fee_mass:masses.2,template_hash:TEMPLATE_ID.into(),raw_json:raw})
}
pub(crate) fn validate(request:&PsktRequest)->Result<()> {
    let source:KronTransferRequest=serde_json::from_value(request.trade_summary.clone().ok_or_else(||bad("Missing KCC20 transfer terms"))?).map_err(|_|bad("Malformed KCC20 transfer terms"))?;
    let expected=prepare(&source)?.pskt_request;
    // Android JSONObject serializes integral doubles as integers (100.0 -> 100).
    // Parse the strict typed terms first, then compare their canonical form.
    // Transaction bytes, scripts, selected inputs and sighashes remain exact.
    let mut canonical=request.clone();
    canonical.trade_summary=Some(serde_json::to_value(&source).map_err(|_|CoreError::Serialization)?);
    if serde_json::to_value(&expected).map_err(|_|CoreError::Serialization)?!=serde_json::to_value(&canonical).map_err(|_|CoreError::Serialization)?{return Err(bad("KCC20 signing request differs from locally rebuilt transfer"));}Ok(())
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn synthetic_transfer_signs_and_executes_local_vm() {
        let secret=format!("private:{}","11".repeat(32));
        let sender=crate::derive_address(&secret).unwrap();
        let recipient=crate::derive_address(&format!("private:{}","22".repeat(32))).unwrap();
        let state=State{amount:100_000_000_000_000,owner:owner(&sender.to_string()).unwrap(),borrow:0,guard:[0;32],extension:[0;32]};
        let script=redeem(&state).unwrap();
        let spk=pay_to_script_hash_script(&script);
        let funding=serde_json::json!([{"address":sender.to_string(),"outpoint":{"transactionId":"bb".repeat(32),"index":0},"utxoEntry":{"amount":2_000_000_000u64,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&sender).script())},"blockDaaScore":123,"isCoinbase":false}}]);
        let request=KronTransferRequest{sender:sender.to_string(),recipient:recipient.to_string(),covenant_id:"cc".repeat(32),ticker:"WALLET".into(),amount:10_000_000_000_000,decimals:8,fee_rate:100.0,template_hash:TEMPLATE_ID.into(),cells:vec![crate::kron::KronCell{transaction_id:"aa".repeat(32),index:0,value_sompi:DEPOSIT,block_daa_score:123,script_public_key:hex::encode(spk.script()),token_amount:state.amount,redeem_script:hex::encode(script)}],funding_utxos_json:funding.to_string()};
        let prepared=crate::prepare_kron_transfer(&request).unwrap();
        assert_eq!(prepared.pskt_request.profile.as_deref(),Some("kcc20-standard-transfer-v1"));
        let review=crate::prepare_pskt(&prepared.pskt_request).unwrap();
        crate::sign_pskt(&secret,&prepared.pskt_request,&review.review_hash).unwrap();
        let mut android_roundtrip:PsktRequest=serde_json::from_str(&serde_json::to_string(&prepared.pskt_request).unwrap()).unwrap();
        android_roundtrip.trade_summary.as_mut().unwrap()["feeRate"]=serde_json::json!(100);
        assert_ne!(serde_json::to_value(&prepared.pskt_request).unwrap(),serde_json::to_value(&android_roundtrip).unwrap());
        let android_review=crate::prepare_pskt(&android_roundtrip).unwrap();
        crate::sign_pskt(&secret,&android_roundtrip,&android_review.review_hash).unwrap();
        android_roundtrip.trade_summary.as_mut().unwrap()["feeRate"]=serde_json::json!(101);
        assert!(crate::prepare_pskt(&android_roundtrip).is_err());
        android_roundtrip.trade_summary.as_mut().unwrap()["feeRate"]=serde_json::json!(100);
        android_roundtrip.trade_summary.as_mut().unwrap()["unknownTerm"]=serde_json::json!(true);
        assert!(crate::prepare_pskt(&android_roundtrip).is_err());
        for count in 1..=3 {
            let mut multi=request.clone();
            multi.cells=(0..count).map(|i| {let mut c=request.cells[0].clone();c.transaction_id=format!("{:02x}",160+i).repeat(32);c}).collect();
            multi.amount=state.amount * count as u64;
            let full=crate::prepare_kron_transfer(&multi).unwrap();
            let reviewed=crate::prepare_pskt(&full.pskt_request).unwrap();
            crate::sign_pskt(&secret,&full.pskt_request,&reviewed.review_hash).unwrap();
            // A compound consumes the whole selected quantity into one cell
            // owned by the sender, using the same real covenant/VM validation.
            multi.recipient=multi.sender.clone();
            let compounded=crate::prepare_kron_transfer(&multi).unwrap();
            assert_eq!(compounded.covenant_output_count,1);
            assert_eq!(compounded.token_change,0);
            let reviewed=crate::prepare_pskt(&compounded.pskt_request).unwrap();
            crate::sign_pskt(&secret,&compounded.pskt_request,&reviewed.review_hash).unwrap();
        }
        let mut changed=prepared.pskt_request.clone();
        changed.trade_summary.as_mut().unwrap()["amount"]=serde_json::json!(1);
        assert!(crate::prepare_pskt(&changed).is_err());
        let mut wrong_owner=request.clone();
        wrong_owner.sender=recipient.to_string();
        assert!(prepare(&wrong_owner).is_err());
    }
    #[test] fn pinned_state_roundtrip_and_tampering(){let s=State{amount:100_000_000_000_000,owner:[7;32],borrow:0,guard:[0;32],extension:[0;32]};let mut r=redeem(&s).unwrap();assert_eq!(decode(&r).unwrap().amount,s.amount);r[0]^=1;assert!(decode(&r).is_err());}
    #[test] fn witness_matches_confirmed_reference_shape(){let s=State{amount:1_000_000,owner:[7;32],borrow:0,guard:[0;32],extension:[0;32]};let(sig,off)=witness(&[s.clone(),s.clone()],&redeem(&s).unwrap(),true).unwrap();assert_eq!(sig[0],16);assert_eq!(&sig[off-2..off],&[66,0]);assert_eq!(&sig[off..off+65],&[0;65]);}
}
