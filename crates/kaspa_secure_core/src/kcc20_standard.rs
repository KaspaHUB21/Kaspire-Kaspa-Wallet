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
pub const TEMPLATE_10_ID: &str = "argent-kcc20-c8a0871-10x10";
pub fn is_template(id:&str)->bool { matches!(id,TEMPLATE_ID|TEMPLATE_10_ID) }
pub fn input_limit(id:&str)->Result<usize> { match id {TEMPLATE_ID=>Ok(3),TEMPLATE_10_ID=>Ok(10),_=>Err(bad("Unsupported KCC20 program configuration"))} }
const DEPOSIT:u64=100_000_000;
fn bad(message:&str)->CoreError {CoreError::InvalidRequest(message.into())}
fn template_for(id:&str)->Result<(Vec<u8>,Vec<u8>)>{
    let source=match id {TEMPLATE_ID=>include_str!("kcc20_standard_template.json"),TEMPLATE_10_ID=>include_str!("kcc20_reference_10_template.json"),_=>return Err(bad("Unsupported KCC20 program configuration"))};
    let v:Value=serde_json::from_str(source).map_err(|_|CoreError::Serialization)?;
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
fn redeem_for(s:&State,id:&str)->Result<Vec<u8>>{let(p,q)=template_for(id)?;Ok([p,state_bytes(s),q].concat())}
#[cfg(test)] fn redeem(s:&State)->Result<Vec<u8>>{redeem_for(s,TEMPLATE_ID)}
#[cfg(test)] fn decode(bytes:&[u8])->Result<State>{decode_for(bytes,TEMPLATE_ID)}
fn decode_for(bytes:&[u8],id:&str)->Result<State>{
    let(p,q)=template_for(id)?;
    if bytes.len()!=p.len()+112+q.len()||!bytes.starts_with(&p)||!bytes.ends_with(&q){return Err(bad("KCC20 program is not the pinned KCC20 reference actor"));}
    let v=&bytes[p.len()..p.len()+112];
    if v[0]!=8||v[9]!=32||v[42]!=1||v[43]!=0||v[44]!=1||v[46]!=32||v[79]!=32||v[45]>3{return Err(bad("Unsupported KCC20 state or owner scheme (this test supports scheme 0)"));}
    let amount=u64::from_le_bytes(v[1..9].try_into().unwrap());
    if amount>i64::MAX as u64{return Err(bad("KCC20 amount exceeds signed integer range"));}
    Ok(State{amount,owner:v[10..42].try_into().unwrap(),borrow:v[45],guard:v[47..79].try_into().unwrap(),extension:v[80..112].try_into().unwrap()})
}
fn push(builder:&mut ScriptBuilder,data:&[u8])->Result<()> {builder.add_data(data).map_err(|e|CoreError::Transaction(e.to_string()))?;Ok(())}
fn witness_with_path(states:&[State],script:&[u8],leader:bool,borrowed:bool)->Result<(Vec<u8>,usize)>{
    let mut b=ScriptBuilder::new();
    if leader {
        for column in 0..6 {
            let data=states.iter().flat_map(|s|match column {0=>s.amount.to_le_bytes().to_vec(),1=>s.owner.to_vec(),2=>vec![0],3=>vec![s.borrow],4=>s.guard.to_vec(),_=>s.extension.to_vec()}).collect::<Vec<_>>();
            push(&mut b,&data)?;
        }
    }
    let offset=b.script().len()+1+usize::from(leader);
    push(&mut b,&if borrowed {vec![1]} else {vec![0;if leader{66}else{65}]})?;
    push(&mut b,&hex::decode(if leader{"79c71c23"}else{"fd3ef14a"}).unwrap())?;
    push(&mut b,script)?;Ok((b.drain(),offset))
}
#[cfg(test)] fn witness(states:&[State],script:&[u8],leader:bool)->Result<(Vec<u8>,usize)>{witness_with_path(states,script,leader,false)}
fn threshold(guard:&[u8;32])->u64 {
    let encoded=u64::from_le_bytes(guard[..8].try_into().unwrap());
    if encoded>>63!=0 {0} else {encoded}
}
fn borrowed_state(request:&KronTransferRequest)->Result<Option<State>> {
    let Some(cell)=&request.borrowed_receive else {return Ok(None)};
    let script=hex::decode(&cell.redeem_script).map_err(|_|bad("Malformed borrowed KCC20 script"))?;
    let state=decode_for(&script,&request.template_hash)?;
    if request.sender==request.recipient || state.owner!=owner(&request.recipient)? || state.amount!=cell.token_amount ||
        state.borrow!=1 || request.amount<=threshold(&state.guard) ||
        hex::encode(pay_to_script_hash_script(&script).script())!=cell.script_public_key.strip_prefix("0000").unwrap_or(&cell.script_public_key) {
        return Err(bad("Recipient KCC20 cell does not authorize this borrowed receive"));
    }
    state.amount.checked_add(request.amount).filter(|v|*v<=i64::MAX as u64).ok_or_else(||bad("Borrowed KCC20 amount overflow"))?;
    Ok(Some(state))
}
pub fn prepare(request:&KronTransferRequest)->Result<PreparedKronTransfer>{
    let limit=input_limit(&request.template_hash)?;
    let borrowed=borrowed_state(request)?;
    if request.amount==0||request.cells.is_empty()||request.cells.len()+usize::from(borrowed.is_some())>limit||request.decimals>18||!request.fee_rate.is_finite()||!(100.0..=10_000.0).contains(&request.fee_rate){return Err(bad("Invalid standard KCC20 transfer parameters"));}
    let sender=owner(&request.sender)?;let recipient=owner(&request.recipient)?;
    let cid=Hash::from_str(&request.covenant_id).map_err(|_|bad("Invalid covenant ID"))?;
    let mut seen=HashSet::new();let mut states=Vec::new();let mut scripts=Vec::new();let mut entries=Vec::new();let mut total=0u64;let mut locked=0u64;
    let all_cells:Vec<_>=request.borrowed_receive.iter().chain(request.cells.iter()).collect();
    for (position,cell) in all_cells.iter().enumerate() {
        if Hash::from_str(&cell.transaction_id).map_err(|_|bad("Invalid KCC20 plan outpoint"))?.to_string()!=cell.transaction_id {
            return Err(bad("Non-canonical KCC20 plan outpoint"));
        }
        if !seen.insert((cell.transaction_id.clone(),cell.index)){return Err(bad("Duplicate KCC20 input"));}
        let script=hex::decode(&cell.redeem_script).map_err(|_|bad("Malformed KCC20 redeem script"))?;
        let state=decode_for(&script,&request.template_hash)?;
        let spk=pay_to_script_hash_script(&script);
        if state.owner!=if position==0&&borrowed.is_some(){recipient}else{sender}||state.amount!=cell.token_amount||hex::encode(spk.script())!=cell.script_public_key.strip_prefix("0000").unwrap_or(&cell.script_public_key){return Err(bad("KCC20 owner, amount or live script differs"));}
        if states.first().is_some_and(|s:&State|s.extension!=state.extension){return Err(bad("Different extended token identities cannot be combined"));}
        if position!=0||borrowed.is_none(){total=total.checked_add(state.amount).filter(|v|*v<=i64::MAX as u64).ok_or_else(||bad("KCC20 token total overflow"))?;}
        locked=locked.checked_add(cell.value_sompi).ok_or(CoreError::Serialization)?;
        entries.push(UtxoEntry::new(cell.value_sompi,spk,cell.block_daa_score,false,Some(cid)));
        states.push(state);scripts.push(script);
    }
    if total<request.amount {return Err(bad("Insufficient KCC20 token balance"));}
    let change=total-request.amount;
    let mut destination=borrowed.clone().unwrap_or(State{amount:0,owner:recipient,borrow:1,guard:[0;32],extension:states[0].extension});
    destination.amount=destination.amount.checked_add(request.amount).ok_or_else(||bad("Borrowed KCC20 amount overflow"))?;
    total.checked_add(borrowed.as_ref().map_or(0,|s|s.amount)).filter(|v|*v<=i64::MAX as u64).ok_or_else(||bad("KCC20 token total overflow"))?;
    let mut next=vec![destination];
    if change>0{let mut s=states[usize::from(borrowed.is_some())].clone();s.amount=change;if s.borrow==0{s.borrow=1;s.guard=[0;32];}next.push(s);}
    // A borrowed deposit belongs to the receiver: never release it as sender change.
    let mut values=vec![request.borrowed_receive.as_ref().map_or(DEPOSIT,|c|c.value_sompi.max(DEPOSIT))];
    if change>0 {values.push(DEPOSIT);}
    let output_locked=values.iter().try_fold(0u64,|sum,v|sum.checked_add(*v)).ok_or(CoreError::Serialization)?;
    let address=Address::try_from(request.sender.as_str()).map_err(|_|CoreError::InvalidAddress)?;
    let mut funding=parse_utxos(&request.funding_utxos_json,&address)?;
    funding.retain(|u|!seen.contains(&(u.outpoint.transaction_id.to_string(),u.outpoint.index))&&u.entry.covenant_id.is_none());
    funding.sort_by_key(|u|std::cmp::Reverse(u.entry.amount));
    let mut selected=Vec::new();let mut input_total=locked;
    for u in funding {input_total=input_total.checked_add(u.entry.amount).ok_or(CoreError::Serialization)?;selected.push(u);if input_total>=output_locked.saturating_add(50_000_000){break;}}
    if selected.is_empty(){return Err(CoreError::InsufficientFunds);}
    let mut inputs=Vec::new();let mut instructions=Vec::new();
    for(i,(cell,script))in all_cells.iter().zip(&scripts).enumerate(){
        let is_borrowed=i==0&&borrowed.is_some();
        let(sig,offset)=witness_with_path(&next,script,i==0,is_borrowed)?;
        if !is_borrowed {instructions.push(crate::pskt::PsktScriptInput{input_index:i,script_hex:String::new(),sign_type:Some(1),signature_script:None,prebuilt_signature_script:Some(hex::encode(&sig)),signature_offsets:vec![offset],expected_sighash:None});}
        inputs.push(TransactionInput::new_with_mass(TransactionOutpoint::new(cell.transaction_id.parse().map_err(|_|bad("Invalid input ID"))?,cell.index),sig,0,ComputeCommit::ComputeBudget(100.into())));
    }
    let n=inputs.len();
    for u in &selected{inputs.push(TransactionInput::new_with_mass(u.outpoint.clone(),vec![],0,ComputeCommit::ComputeBudget(10.into())));entries.push(u.entry.clone());}
    let make=|fee:u64,storage:u64|->Result<Transaction>{
        let mut outputs=next.iter().zip(&values).map(|(s,v)|Ok(TransactionOutput::with_covenant(*v,pay_to_script_hash_script(&redeem_for(s,&request.template_hash)?),Some(CovenantBinding::new(0,cid))))).collect::<Result<Vec<_>>>()?;
        let kas_change=input_total.checked_sub(output_locked.checked_add(fee).ok_or(CoreError::Serialization)?).filter(|v|*v>=10_000).ok_or(CoreError::InsufficientFunds)?;
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
    Ok(PreparedKronTransfer{pskt_request:pskt,transaction_id:tx.id().to_string(),fee_sompi:fee,input_total_sompi:input_total,output_total_sompi:input_total-fee,token_change:change,locked_kas_sompi:locked,locked_kas_top_up_sompi:output_locked.saturating_sub(locked),locked_kas_released_sompi:locked.saturating_sub(output_locked),locked_kas_output_sompi:output_locked,covenant_input_count:n,covenant_output_count:next.len(),compute_budget:n as u64*100+selected.len()as u64*10,compute_mass:masses.0,transient_mass:masses.1,fee_mass:masses.2,template_hash:request.template_hash.clone(),raw_json:raw})
}
pub(crate) fn validate_plan_cells(request:&KronTransferRequest)->Result<()> {
    let borrowed=borrowed_state(request)?;
    let expected_owner=owner(&request.sender)?;
    let mut extension=None;
    for cell in &request.cells {
        let script=hex::decode(&cell.redeem_script).map_err(|_|bad("Malformed KCC20 plan script"))?;
        let s=decode_for(&script,&request.template_hash)?;
        let spk=pay_to_script_hash_script(&script);
        if s.owner!=expected_owner || s.amount!=cell.token_amount || borrowed.as_ref().is_some_and(|b|b.extension!=s.extension) ||
            hex::encode(spk.script())!=cell.script_public_key.strip_prefix("0000").unwrap_or(&cell.script_public_key) ||
            extension.is_some_and(|e|e!=s.extension) {
            return Err(bad("KCC20 plan cells differ in owner, token identity or script"));
        }
        extension=Some(s.extension);
    }
    Ok(())
}
pub(crate) fn plan_output(first:&crate::KronCell,txid:&str,amount:u64,id:&str)->Result<crate::KronCell> {
    let mut s=decode_for(&hex::decode(&first.redeem_script).map_err(|_|bad("Malformed KCC20 script"))?,id)?;
    s.amount=amount;s.borrow=1;s.guard=[0;32];
    let script=redeem_for(&s,id)?;
    Ok(crate::KronCell {transaction_id:txid.into(),index:0,value_sompi:DEPOSIT,block_daa_score:0,
        script_public_key:hex::encode(pay_to_script_hash_script(&script).script()),token_amount:amount,redeem_script:hex::encode(script)})
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
    fn ten_request(count:usize)->(String,KronTransferRequest) {
        let secret=format!("private:{}","11".repeat(32));
        let sender=crate::derive_address(&secret).unwrap();
        let recipient=crate::derive_address(&format!("private:{}","22".repeat(32))).unwrap();
        let s=State{amount:1000,owner:owner(&sender.to_string()).unwrap(),borrow:0,guard:[0;32],extension:[0;32]};
        let script=redeem_for(&s,TEMPLATE_10_ID).unwrap();
        let spk=hex::encode(pay_to_script_hash_script(&script).script());
        let cells=(0..count).map(|i|crate::KronCell{transaction_id:format!("{:064x}",100+i),index:0,value_sompi:DEPOSIT,block_daa_score:123,script_public_key:spk.clone(),token_amount:1000,redeem_script:hex::encode(&script)}).collect();
        let funding=serde_json::json!([{"address":sender.to_string(),"outpoint":{"transactionId":"bb".repeat(32),"index":0},"utxoEntry":{"amount":100_000_000_000u64,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&sender).script())},"blockDaaScore":123,"isCoinbase":false}}]);
        (secret,KronTransferRequest{sender:sender.to_string(),recipient:recipient.to_string(),covenant_id:"cc".repeat(32),ticker:"TEN".into(),amount:count as u64*1000-1,decimals:0,fee_rate:100.0,template_hash:TEMPLATE_10_ID.into(),cells,borrowed_receive:None,funding_utxos_json:funding.to_string()})
    }
    #[test] fn ten_inputs_sign_and_execute_without_compound_and_eleven_require_a_plan() {
        for count in [1,4,7,10] {
            let (secret,request)=ten_request(count);
            let prepared=prepare(&request).unwrap();
            assert_eq!(prepared.covenant_input_count,count);
            assert_eq!(prepared.template_hash,TEMPLATE_10_ID);
            let review=crate::prepare_pskt(&prepared.pskt_request).unwrap();
            crate::sign_pskt(&secret,&prepared.pskt_request,&review.review_hash).unwrap();
            assert_eq!(crate::prepare_kcc20_plan(&request).unwrap().transaction_count,1);
        }
        let(secret,source)=ten_request(11);
        assert!(prepare(&source).is_err());
        let plan=crate::prepare_kcc20_plan(&source).unwrap();
        assert_eq!(plan.transaction_count,2);
        assert_eq!(plan.steps[0].covenant_input_count,10);
        assert_eq!(plan.steps[0].pskt_request.trade_summary.as_ref().unwrap()["recipient"],source.sender);
        assert_eq!(plan.steps[1].pskt_request.trade_summary.as_ref().unwrap()["recipient"],source.recipient);
        crate::sign_kcc20_plan(&secret,&source,&plan.review_hash).unwrap();
        let mut changed=source.clone();changed.template_hash=TEMPLATE_ID.into();
        assert!(crate::prepare_kcc20_plan(&changed).is_err());
        assert!(crate::sign_kcc20_plan(&secret,&changed,&plan.review_hash).is_err());
    }
    #[test] fn ten_template_matches_pinned_compiler_and_does_not_upgrade_three_input_cells() {
        use silverscript_v1::{ast::Expr,compiler::{compile_contract,CompileOptions}};
        let data:Value=serde_json::from_str(include_str!("kcc20_reference_10_template.json")).unwrap();
        let hash=hex::decode(data["templateHash"].as_str().unwrap()).unwrap();
        let args=vec![Expr::bytes(hash),Expr::int(1000),Expr::bytes(vec![0x11;32]),Expr::int(0),Expr::int(0),Expr::bytes(vec![0;32]),Expr::bytes(vec![0;32])];
        let c=compile_contract(include_str!("kcc20_reference_10.sil"),&args,CompileOptions::default()).unwrap();
        let (prefix,suffix)=template_for(TEMPLATE_10_ID).unwrap();
        assert_eq!(hex::encode(c.template_hash()),data["templateHash"]);
        assert_eq!(&c.bytecode[..c.state_layout.start+33],&prefix);
        assert_eq!(&c.bytecode[c.state_layout.start+c.state_layout.len..],&suffix);
        let(_,mut request)=ten_request(4);
        request.template_hash=TEMPLATE_ID.into();
        assert!(prepare(&request).is_err());
        request.cells.truncate(1);
        assert!(prepare(&request).is_err());
        assert!(input_limit("indexer-says-ten").is_err());
    }
    #[test] fn ten_output_contract_executes_and_rejects_eleven_continuations() {
        use secp256k1::{Keypair,Message,SecretKey,SECP256K1};
        let(secret,request)=ten_request(1);
        let key=crate::derive_key(&secret).unwrap();
        let pair=Keypair::from_secret_key(SECP256K1,&SecretKey::from_slice(key.as_ref()).unwrap());
        let cid:Hash=request.covenant_id.parse().unwrap();
        let script=hex::decode(&request.cells[0].redeem_script).unwrap();
        let sender=Address::try_from(request.sender.as_str()).unwrap();
        for count in [10usize,11] {
            let next:Vec<_>=(0..count).map(|i|State{amount:if i+1==count {1000-90*(count as u64-1)}else{90},owner:owner(&request.recipient).unwrap(),borrow:0,guard:[0;32],extension:[0;32]}).collect();
            let(mut leader,offset)=witness(&next,&script,true).unwrap();
            let inputs=vec![
                TransactionInput::new_with_mass(TransactionOutpoint::new("aa".repeat(32).parse().unwrap(),0),leader.clone(),0,ComputeCommit::ComputeBudget(100.into())),
                TransactionInput::new_with_mass(TransactionOutpoint::new("bb".repeat(32).parse().unwrap(),0),vec![],0,ComputeCommit::ComputeBudget(10.into()))];
            let entries=vec![UtxoEntry::new(DEPOSIT,pay_to_script_hash_script(&script),123,false,Some(cid)),UtxoEntry::new(100_000_000_000,pay_to_address_script(&sender),123,false,None)];
            let mut outputs:Vec<_>=next.iter().map(|s|TransactionOutput::with_covenant(DEPOSIT,pay_to_script_hash_script(&redeem_for(s,TEMPLATE_10_ID).unwrap()),Some(CovenantBinding::new(0,cid)))).collect();
            outputs.push(TransactionOutput::new(100_000_000_000+DEPOSIT-DEPOSIT*count as u64-1_000_000,pay_to_address_script(&sender)));
            let mut tx=Transaction::new(1,inputs,outputs,0,SUBNETWORK_ID_NATIVE,0,vec![]);
            for index in 0..2 {
                let populated=PopulatedTransaction::new(&tx,entries.clone());
                let digest=calc_schnorr_signature_hash(&populated,index,SIG_HASH_ALL,&SigHashReusedValuesUnsync::new());
                let mut signature=pair.sign_schnorr(Message::from_digest(digest.as_bytes())).as_ref().to_vec();signature.push(1);
                tx.inputs[index].signature_script=if index==0 {leader[offset..offset+65].copy_from_slice(&signature);leader.clone()}else{let mut b=ScriptBuilder::new();push(&mut b,&signature).unwrap();b.drain()};
            }
            let result=crate::kcc20::simulate_all(&tx,&entries);
            if count==10 {result.unwrap();}else{assert!(result.is_err());}
        }
    }
    #[test] fn synthetic_transfer_signs_and_executes_local_vm() {
        let secret=format!("private:{}","11".repeat(32));
        let sender=crate::derive_address(&secret).unwrap();
        let recipient=crate::derive_address(&format!("private:{}","22".repeat(32))).unwrap();
        let state=State{amount:100_000_000_000_000,owner:owner(&sender.to_string()).unwrap(),borrow:0,guard:[0;32],extension:[0;32]};
        let script=redeem(&state).unwrap();
        let spk=pay_to_script_hash_script(&script);
        let funding=serde_json::json!([{"address":sender.to_string(),"outpoint":{"transactionId":"bb".repeat(32),"index":0},"utxoEntry":{"amount":2_000_000_000u64,"scriptPublicKey":{"version":0,"scriptPublicKey":hex::encode(pay_to_address_script(&sender).script())},"blockDaaScore":123,"isCoinbase":false}}]);
        let request=KronTransferRequest{sender:sender.to_string(),recipient:recipient.to_string(),covenant_id:"cc".repeat(32),ticker:"WALLET".into(),amount:10_000_000_000_000,decimals:8,fee_rate:100.0,template_hash:TEMPLATE_ID.into(),cells:vec![crate::kron::KronCell{transaction_id:"aa".repeat(32),index:0,value_sompi:DEPOSIT,block_daa_score:123,script_public_key:hex::encode(spk.script()),token_amount:state.amount,redeem_script:hex::encode(script)}],borrowed_receive:None,funding_utxos_json:funding.to_string()};
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
        for count in [4usize,7] {
            let mut source=request.clone();
            source.cells=(0..count).map(|i|{let mut c=request.cells[0].clone();c.transaction_id=format!("{:02x}",160+i).repeat(32);c}).collect();
            source.amount=state.amount * count as u64 - 1;
            let plan=crate::prepare_kcc20_plan(&source).unwrap();
            let mut android_value=serde_json::to_value(&source).unwrap();
            android_value["feeRate"]=serde_json::json!(100);
            let android_source:KronTransferRequest=serde_json::from_value(android_value).unwrap();
            assert_eq!(crate::prepare_kcc20_plan(&android_source).unwrap().review_hash,plan.review_hash);
            let mut variant=source.clone();
            let mut funding:Value=serde_json::from_str(&variant.funding_utxos_json).unwrap();
            funding[0]["outpoint"]["index"]=serde_json::json!("0");
            funding[0]["outpoint"]["transactionId"]=serde_json::json!("BB".repeat(32));
            variant.funding_utxos_json=funding.to_string();
            let canonical=crate::prepare_kcc20_plan(&variant).unwrap();
            assert_eq!(canonical.steps.iter().map(|s|&s.transaction_id).collect::<Vec<_>>(),plan.steps.iter().map(|s|&s.transaction_id).collect::<Vec<_>>());
            assert_eq!(plan.transaction_count,(count-1).div_ceil(2));
            assert_eq!(plan.total_fee_sompi,plan.steps.iter().map(|s|s.fee_sompi).sum::<u64>());
            let signed=crate::sign_kcc20_plan(&secret,&source,&plan.review_hash).unwrap();
            assert_eq!(signed.transactions.len(),plan.transaction_count);
            for (i,step) in plan.steps.iter().enumerate() {
                let terms=&step.pskt_request.trade_summary.as_ref().unwrap();
                assert_eq!(terms["recipient"].as_str().unwrap(),if i+1==plan.transaction_count {source.recipient.as_str()}else{source.sender.as_str()});
                assert!(step.covenant_input_count<=3);
            }
            let mut changed=source.clone();changed.recipient=source.sender.clone();
            assert!(crate::sign_kcc20_plan(&secret,&changed,&plan.review_hash).is_err());
            changed=source.clone();changed.amount-=1;
            assert!(crate::sign_kcc20_plan(&secret,&changed,&plan.review_hash).is_err());
            changed=source.clone();changed.fee_rate=101.0;
            assert!(crate::sign_kcc20_plan(&secret,&changed,&plan.review_hash).is_err());
            changed=source.clone();changed.cells[1]=changed.cells[0].clone();
            assert!(crate::prepare_kcc20_plan(&changed).is_err());
            changed=source.clone();changed.cells[3].token_amount+=1;
            assert!(crate::prepare_kcc20_plan(&changed).is_err());
        }
        let mut changed=prepared.pskt_request.clone();
        changed.trade_summary.as_mut().unwrap()["amount"]=serde_json::json!(1);
        assert!(crate::prepare_pskt(&changed).is_err());
        let mut wrong_owner=request.clone();
        wrong_owner.sender=recipient.to_string();
        assert!(prepare(&wrong_owner).is_err());
    }
    fn borrow_request(count:usize)->(String,KronTransferRequest) {
        let(secret,mut request)=ten_request(count);
        let s=State{amount:5000,owner:owner(&request.recipient).unwrap(),borrow:1,guard:[0;32],extension:[0;32]};
        let script=redeem_for(&s,TEMPLATE_10_ID).unwrap();
        request.borrowed_receive=Some(crate::KronCell{transaction_id:"dd".repeat(32),index:0,value_sompi:5*DEPOSIT,block_daa_score:123,script_public_key:hex::encode(pay_to_script_hash_script(&script).script()),token_amount:s.amount,redeem_script:hex::encode(script)});
        (secret,request)
    }
    #[test] fn kasseal_pinned_token_program_is_the_identical_standard_three_cell_program() {
        use sha2::{Digest,Sha256};
        let(prefix,suffix)=template_for(TEMPLATE_ID).unwrap();
        let normalized=[prefix,vec![0;112],suffix].concat();
        for text in [include_str!("kasseal_mainnet_templates.json"),include_str!("kasseal_tn10_templates.json")] {
            let pins:Value=serde_json::from_str(text).unwrap();
            assert_eq!(pins["token"]["length"].as_u64().unwrap() as usize,normalized.len());
            assert_eq!(pins["token"]["stateOffset"],34);
            assert_eq!(pins["token"]["stateLength"],112);
            assert_eq!(pins["token"]["sha256"],hex::encode(Sha256::digest(&normalized)));
        }
    }
    #[test] fn three_cell_borrowed_receive_executes_the_unchanged_reference_contract() {
        let(secret,mut request)=borrow_request(1);
        request.template_hash=TEMPLATE_ID.into();
        let recipient_owner=owner(&request.recipient).unwrap();
        for (cell,who,borrow) in request.cells.iter_mut().map(|c|(c,owner(&request.sender).unwrap(),0)).chain(request.borrowed_receive.iter_mut().map(|c|(c,recipient_owner,1))) {
            let state=State{amount:cell.token_amount,owner:who,borrow,guard:[0;32],extension:[0;32]};
            let script=redeem_for(&state,TEMPLATE_ID).unwrap();cell.redeem_script=hex::encode(&script);cell.script_public_key=hex::encode(pay_to_script_hash_script(&script).script());
        }
        let prepared=prepare(&request).unwrap();
        let review=crate::prepare_pskt(&prepared.pskt_request).unwrap();
        crate::sign_pskt(&secret,&prepared.pskt_request,&review.review_hash).unwrap();
    }
    #[test] fn borrowed_receive_signs_only_sender_and_preserves_receiver_deposit() {
        let(secret,request)=borrow_request(1);
        let prepared=prepare(&request).unwrap();
        assert_eq!(prepared.covenant_input_count,2);
        assert!(prepared.pskt_request.scripts.iter().all(|s|s.input_index!=0));
        assert!(prepared.pskt_request.sign_inputs.iter().all(|s|s.index!=0));
        let review=crate::prepare_pskt(&prepared.pskt_request).unwrap();
        assert_eq!(review.outputs[0].amount_sompi,5*DEPOSIT);
        let signed=crate::sign_pskt(&secret,&prepared.pskt_request,&review.review_hash).unwrap();
        assert!(!signed.signed_input_indexes.contains(&0));
        let mut changed=prepared.pskt_request.clone();
        changed.tx_json_string=changed.tx_json_string.replace("500000000","499999999");
        assert!(crate::prepare_pskt(&changed).is_err());
    }
    #[test] fn borrowed_receive_reserves_an_input_slot_and_only_borrows_in_final_step() {
        let(secret,request)=borrow_request(10);
        assert!(prepare(&request).is_err());
        let plan=crate::prepare_kcc20_plan(&request).unwrap();
        assert_eq!(plan.transaction_count,2);
        assert!(plan.steps[0].pskt_request.trade_summary.as_ref().unwrap().get("borrowedReceive").is_none());
        assert!(plan.steps[1].pskt_request.trade_summary.as_ref().unwrap().get("borrowedReceive").is_some());
        crate::sign_kcc20_plan(&secret,&request,&plan.review_hash).unwrap();
    }
    #[test] fn borrowing_requires_exact_recipient_identity_and_strict_threshold() {
        let(_,request)=borrow_request(1);
        for variant in 0..6 {
            let mut changed=request.clone();
            let cell=changed.borrowed_receive.as_mut().unwrap();
            let mut state=decode_for(&hex::decode(&cell.redeem_script).unwrap(),TEMPLATE_10_ID).unwrap();
            match variant {0=>state.borrow=0,1=>state.borrow=2,2=>state.owner=[7;32],3=>state.extension=[8;32],4=>state.guard[..8].copy_from_slice(&request.amount.to_le_bytes()),_=>cell.token_amount+=1};
            let script=redeem_for(&state,TEMPLATE_10_ID).unwrap();cell.redeem_script=hex::encode(&script);cell.script_public_key=hex::encode(pay_to_script_hash_script(&script).script());
            assert!(prepare(&changed).is_err(),"variant {variant}");
        }
        let mut changed=request.clone();
        let cell=changed.borrowed_receive.as_mut().unwrap();
        let mut state=decode_for(&hex::decode(&cell.redeem_script).unwrap(),TEMPLATE_10_ID).unwrap();
        state.guard[31]=42; // All guard bytes survive, not only the threshold.
        state.guard[..8].copy_from_slice(&(request.amount-1).to_le_bytes());
        let script=redeem_for(&state,TEMPLATE_10_ID).unwrap();cell.redeem_script=hex::encode(&script);cell.script_public_key=hex::encode(pay_to_script_hash_script(&script).script());
        let prepared=prepare(&changed).unwrap();
        let review=crate::prepare_pskt(&prepared.pskt_request).unwrap();
        crate::sign_pskt(&ten_request(1).0,&prepared.pskt_request,&review.review_hash).unwrap();
    }
    #[test] fn pinned_state_roundtrip_and_tampering(){let s=State{amount:100_000_000_000_000,owner:[7;32],borrow:0,guard:[0;32],extension:[0;32]};let mut r=redeem(&s).unwrap();assert_eq!(decode(&r).unwrap().amount,s.amount);r[0]^=1;assert!(decode(&r).is_err());}
    #[test] fn witness_matches_confirmed_reference_shape(){let s=State{amount:1_000_000,owner:[7;32],borrow:0,guard:[0;32],extension:[0;32]};let(sig,off)=witness(&[s.clone(),s.clone()],&redeem(&s).unwrap(),true).unwrap();assert_eq!(sig[0],16);assert_eq!(&sig[off-2..off],&[66,0]);assert_eq!(&sig[off..off+65],&[0;65]);}
}
