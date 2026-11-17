//! Read-only kUSDT interpretation. Never changes the transaction or its signing policy.
//! A ticker/amount supplied by a dApp is not evidence: every decoded state must
//! reproduce the exact P2SH script of the input or output carrying the pinned CID.
use crate::kcc20_standard::KUSDT_COVENANT_ID;
use kaspa_addresses::{Address, Prefix, Version};
use kaspa_consensus_core::tx::{Transaction, UtxoEntry};
use kaspa_txscript::pay_to_script_hash_script;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenCellReview {
    pub index: usize,
    pub amount_raw: String,
    pub owner_scheme: u8,
    pub owner: String,
    pub wallet_owned: bool,
    pub reserve_sompi: String,
    pub signature_bound: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenReview {
    pub covenant_id: String,
    pub ticker: String,
    pub decimals: u8,
    pub complete: bool,
    pub outputs_bound: bool,
    pub wallet_input_raw: Option<String>,
    pub wallet_output_raw: Option<String>,
    pub wallet_net_raw: Option<String>,
    pub inputs: Vec<TokenCellReview>,
    pub outputs: Vec<TokenCellReview>,
    pub undecoded_inputs: Vec<usize>,
    pub undecoded_outputs: Vec<usize>,
}

fn pushes(bytes: &[u8]) -> Option<Vec<Vec<u8>>> {
    let mut result = Vec::new();
    let mut at = 0usize;
    while at < bytes.len() {
        if result.len() >= 512 { return None; }
        let op = bytes[at]; at += 1;
        let len = match op {
            0 => { result.push(vec![]); continue; },
            1..=75 => op as usize,
            76 => { let n = *bytes.get(at)? as usize; at += 1; n },
            77 => { let n = u16::from_le_bytes(bytes.get(at..at+2)?.try_into().ok()?) as usize; at += 2; n },
            78 => { let n = u32::from_le_bytes(bytes.get(at..at+4)?.try_into().ok()?) as usize; at += 4; n },
            79 => { result.push(vec![0x81]); continue; },
            81..=96 => { result.push(vec![op-80]); continue; },
            _ => return None,
        };
        let end = at.checked_add(len)?;
        result.push(bytes.get(at..end)?.to_vec()); at = end;
    }
    Some(result)
}
fn state(program: &[u8], prefix: &[u8], suffix: &[u8]) -> Option<Vec<u8>> {
    if program.len() != prefix.len()+112+suffix.len() || !program.starts_with(prefix) || !program.ends_with(suffix) { return None; }
    let s = &program[prefix.len()..prefix.len()+112];
    if s[0]!=8 || s[9]!=32 || s[42]!=1 || s[44]!=1 || s[46]!=32 || s[79]!=32 ||
        s[43]>4 || s[45]>3 || s[80..]!=[0;32] || i64::from_le_bytes(s[1..9].try_into().ok()?)<0 { return None; }
    Some(s.to_vec())
}
fn successors(p: &[Vec<u8>], prefix: &[u8], suffix: &[u8]) -> Vec<Vec<u8>> {
    if p.len()!=9 || p[7]!=[0x79,0xc7,0x1c,0x23] { return vec![]; }
    let n = p[0].len()/8;
    if n==0 || n>3 || p[0].len()!=n*8 || p[1].len()!=n*32 || p[2].len()!=n || p[3].len()!=n || p[4].len()!=n*32 || p[5].len()!=n*32 { return vec![]; }
    (0..n).filter_map(|i| {
        let mut s=vec![8]; s.extend(&p[0][i*8..i*8+8]); s.push(32); s.extend(&p[1][i*32..i*32+32]);
        s.extend([1,p[2][i],1,p[3][i],32]); s.extend(&p[4][i*32..i*32+32]); s.push(32); s.extend(&p[5][i*32..i*32+32]);
        let program=[prefix,s.as_slice(),suffix].concat(); state(&program,prefix,suffix)?; Some(program)
    }).collect()
}
fn cell(index: usize, s: &[u8], reserve: u64, owner: &[u8], bound: bool) -> TokenCellReview {
    TokenCellReview { index, amount_raw:u64::from_le_bytes(s[1..9].try_into().unwrap()).to_string(),
        owner_scheme:s[43], owner:hex::encode(&s[10..42]), wallet_owned:s[43]==0 && &s[10..42]==owner,
        reserve_sompi:reserve.to_string(), signature_bound:bound }
}
pub(crate) fn review(tx: &Transaction, entries: &[UtxoEntry], witnesses: &[Vec<u8>], sender: &Address, bound: &[bool]) -> Vec<TokenReview> {
    if sender.prefix!=Prefix::Mainnet || sender.version!=Version::PubKey { return vec![]; }
    let cid:kaspa_hashes::Hash=KUSDT_COVENANT_ID.parse().unwrap();
    if !entries.iter().any(|e|e.covenant_id==Some(cid)) && !tx.outputs.iter().any(|o|o.covenant.is_some_and(|c|c.covenant_id==cid)) { return vec![]; }
    let template:serde_json::Value=serde_json::from_str(include_str!("kcc20_standard_template.json")).unwrap();
    let prefix=hex::decode(template["prefix"].as_str().unwrap()).unwrap();
    let suffix=hex::decode(template["suffix"].as_str().unwrap()).unwrap();
    let mut r=TokenReview {covenant_id:KUSDT_COVENANT_ID.into(),ticker:"kUSDT".into(),decimals:6,complete:false,outputs_bound:false,
        wallet_input_raw:None,wallet_output_raw:None,wallet_net_raw:None,inputs:vec![],outputs:vec![],undecoded_inputs:vec![],undecoded_outputs:vec![]};
    let mut candidates:Vec<Vec<u8>>=vec![];
    for (i,e) in entries.iter().enumerate().filter(|(_,e)|e.covenant_id.is_some_and(|c|c.to_string()==KUSDT_COVENANT_ID)) {
        let decoded=pushes(&witnesses[i]).and_then(|p| {
            let program=p.last()?;
            let s=state(program,&prefix,&suffix)?;
            if pay_to_script_hash_script(program)!=e.script_public_key { return None; }
            candidates.extend(successors(&p,&prefix,&suffix)); candidates.push(program.clone()); Some(s)
        });
        if let Some(s)=decoded {
            // Normal wallet addresses use scheme 0, pool contracts use 4.
            // Other ownership schemes need additional identity proofs; don't
            // silently count them as somebody else's funds in the net amount.
            if (1..=3).contains(&s[43]) {r.undecoded_inputs.push(i);}
            r.inputs.push(cell(i,&s,e.amount,sender.payload.as_slice(),true));
        } else {r.undecoded_inputs.push(i);}
    }
    for (i,o) in tx.outputs.iter().enumerate().filter(|(_,o)|o.covenant.is_some_and(|c|c.covenant_id.to_string()==KUSDT_COVENANT_ID)) {
        let decoded=candidates.iter().find(|p|pay_to_script_hash_script(p)==o.script_public_key).and_then(|p|state(p,&prefix,&suffix));
        if let Some(s)=decoded {
            if (1..=3).contains(&s[43]) {r.undecoded_outputs.push(i);}
            r.outputs.push(cell(i,&s,o.value,sender.payload.as_slice(),bound[i]));
        } else {r.undecoded_outputs.push(i);}
    }
    // An unknown state may belong to this wallet: never report zero or a net
    // amount for a partial view. All amounts are exact decimal integer strings.
    let sum=|cells:&[TokenCellReview]| cells.iter().filter(|c|c.wallet_owned).map(|c|c.amount_raw.parse::<i128>().unwrap()).sum::<i128>();
    if r.undecoded_inputs.is_empty() {r.wallet_input_raw=Some(sum(&r.inputs).to_string());}
    if r.undecoded_outputs.is_empty() {r.wallet_output_raw=Some(sum(&r.outputs).to_string());}
    r.complete=r.undecoded_inputs.is_empty()&&r.undecoded_outputs.is_empty();
    r.outputs_bound=r.undecoded_outputs.is_empty()&&r.outputs.iter().all(|c|c.signature_bound);
    if r.complete {r.wallet_net_raw=Some((sum(&r.outputs)-sum(&r.inputs)).to_string());}
    vec![r]
}

#[cfg(test)] mod tests {
    use super::*;
    use kaspa_txscript::script_builder::ScriptBuilder;
    use kaspa_consensus_core::{subnets::SUBNETWORK_ID_NATIVE,tx::{TransactionInput,TransactionOutput,TransactionOutpoint,CovenantBinding}};
    fn fixture() -> (Address,Transaction,Vec<UtxoEntry>,Vec<Vec<u8>>) {
        let sender=crate::derive_address(&format!("private:{}","11".repeat(32))).unwrap();
        let other=crate::derive_address(&format!("private:{}","22".repeat(32))).unwrap();
        let t:serde_json::Value=serde_json::from_str(include_str!("kcc20_standard_template.json")).unwrap();
        let prefix=hex::decode(t["prefix"].as_str().unwrap()).unwrap();let suffix=hex::decode(t["suffix"].as_str().unwrap()).unwrap();
        let program=|amount:u64,owner:&[u8]| {
            let mut s=vec![8];s.extend(amount.to_le_bytes());s.push(32);s.extend(owner);s.extend([1,0,1,0,32]);s.extend([0;32]);s.push(32);s.extend([0;32]);
            [prefix.as_slice(),s.as_slice(),suffix.as_slice()].concat()
        };
        let spent=program(1_000_000,sender.payload.as_slice());
        let mut witness=ScriptBuilder::new();
        let mut amounts=vec![];amounts.extend(1u64.to_le_bytes());amounts.extend(999_999u64.to_le_bytes());
        for p in [amounts,[other.payload.as_slice(),sender.payload.as_slice()].concat(),vec![0,0],vec![0,0],vec![0;64],vec![0;64],vec![0;66],vec![0x79,0xc7,0x1c,0x23],spent.clone()] {witness.add_data(&p).unwrap();}
        let cid=KUSDT_COVENANT_ID.parse().unwrap();
        let outputs=vec![TransactionOutput::with_covenant(150_000_000,pay_to_script_hash_script(&program(1,other.payload.as_slice())),Some(CovenantBinding::new(0,cid))),TransactionOutput::with_covenant(150_000_000,pay_to_script_hash_script(&program(999_999,sender.payload.as_slice())),Some(CovenantBinding::new(0,cid)))];
        let bytes=witness.drain();
        let tx=Transaction::new(1,vec![TransactionInput::new(TransactionOutpoint::new(kaspa_hashes::Hash::from_bytes([1;32]),0),bytes.clone(),0,0)],outputs,0,SUBNETWORK_ID_NATIVE,0,vec![]);
        (sender,tx,vec![UtxoEntry::new(150_000_000,pay_to_script_hash_script(&spent),0,false,Some(cid))],vec![bytes])
    }
    #[test] fn kusdt_decoder_does_not_claim_unknown_or_unbound_results() {
        let(sender,mut tx,entries,w)=fixture();
        let r=review(&tx,&entries,&w,&sender,&[true,true]);assert!(r[0].complete);assert_eq!(r[0].wallet_net_raw.as_deref(),Some("-1"));
        let r=review(&tx,&entries,&w,&sender,&[false,true]);assert!(!r[0].outputs_bound);assert!(!r[0].outputs[0].signature_bound);
        tx.outputs[0].script_public_key=pay_to_script_hash_script(&[42]);
        let r=review(&tx,&entries,&w,&sender,&[true,true]);assert!(!r[0].complete);assert_eq!(r[0].wallet_net_raw,None);assert_eq!(r[0].wallet_output_raw,None);assert_eq!(r[0].undecoded_outputs,vec![0]);
        let r=review(&tx,&entries,&[vec![0]],&sender,&[true,true]);assert_eq!(r[0].wallet_input_raw,None);assert_eq!(r[0].wallet_net_raw,None);
    }
    #[test] fn kusdt_decoder_rejects_lookalike_family_and_wrong_script_preimage() {
        let(sender,mut tx,mut entries,mut w)=fixture();
        entries[0].script_public_key=pay_to_script_hash_script(&[42]);
        let r=review(&tx,&entries,&w,&sender,&[true,true]);assert!(r[0].inputs.is_empty());assert_eq!(r[0].wallet_input_raw,None);
        entries[0].covenant_id=Some(kaspa_hashes::Hash::from_bytes([42;32]));
        for o in &mut tx.outputs {o.covenant.as_mut().unwrap().covenant_id=kaspa_hashes::Hash::from_bytes([42;32]);}
        assert!(review(&tx,&entries,&w,&sender,&[true,true]).is_empty());
        w[0]=vec![78,255,255,255,255];assert!(pushes(&w[0]).is_none());
    }
}
