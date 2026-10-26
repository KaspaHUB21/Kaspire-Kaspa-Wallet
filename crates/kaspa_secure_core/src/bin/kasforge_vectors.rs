//! Local, read-only partner-kit verification. Never prints or republishes kit bytes.
//! This is not a signing profile or an approval of the contracts' security.
use kaspa_addresses::{Address, Prefix, Version};
use serde_json::Value;
use std::process::Command;

fn read(zip: &str, file: &str) -> Result<Value, String> {
    let result=Command::new("unzip").args(["-p",zip,&format!("kasforge-orders/{file}")]).output().map_err(|_|"unzip unavailable")?;
    if !result.status.success() || result.stdout.len()>250_000 {return Err("invalid kit member".into());}
    serde_json::from_slice(&result.stdout).map_err(|_|"invalid JSON".into())
}
fn verify(zip:&str)->Result<(),String> {
    let vectors=read(zip,"vectors.json")?;
    if vectors["contractsVersion"]!="3.3" {return Err("unexpected contract version".into());}
    for (name,file,contract) in [
        ("buyOrderTemplate","ForgeBuyOrder.template.json","ForgeBuyOrder"),
        ("buyOrderExample","ForgeBuyOrder.example.json","ForgeBuyOrder"),
        ("sellOrderExample","ForgeSellOrder.example.json","ForgeSellOrder"),
        ("sellOrderV1Example","ForgeSellOrder_v1.example.json","ForgeSellOrder"),
    ] {
        let artifact=read(zip,&format!("artifacts/{file}"))?;
        let compiled=&artifact["contracts"][contract]["compiled"];
        let bytes:Vec<u8>=serde_json::from_value(compiled["bytecode"].clone()).map_err(|_|"invalid bytecode")?;
        let result=if name=="buyOrderTemplate" {&vectors[name]} else {&vectors[name]["result"]};
        if hex::encode(&bytes)!=result["bytecode"].as_str().ok_or("missing vector")? {return Err(format!("{name}: artifact/vector mismatch"));}
        let hash=kaspa_hashes::blake2b_simd::Params::new().hash_length(32).hash(&bytes);
        if hex::encode(hash.as_bytes())!=result["scriptHash"].as_str().ok_or("missing hash")? || format!("aa20{}87",hex::encode(hash.as_bytes()))!=result["p2shScriptPublicKey"].as_str().ok_or("missing P2SH")? {return Err(format!("{name}: P2SH mismatch"));}
        for (prefix,key) in [(Prefix::Mainnet,"mainnetAddress"),(Prefix::Testnet,"testnetAddress")] {
            if Address::new(prefix,Version::ScriptHash,hash.as_bytes()).to_string()!=result[key].as_str().ok_or("missing address")? {return Err(format!("{name}: address mismatch"));}
        }
        let span=&compiled["state_span"];
        let offset=span["offset"].as_u64().unwrap_or(0) as usize;
        let length=span["len"].as_u64().unwrap_or(0) as usize;
        if offset+length>bytes.len(){return Err("invalid state span".into());}
        let prefix=&bytes[..offset];let suffix=&bytes[offset+length..];
        let template=blake3::Hasher::new().update(&(prefix.len() as i64).to_le_bytes()).update(prefix).update(&(suffix.len() as i64).to_le_bytes()).update(suffix).finalize();
        if template.to_hex().as_str()!=result["template"]["templateHash"].as_str().ok_or("missing template")? {return Err(format!("{name}: template mismatch"));}
        println!("{name}: artifact, bytecode, P2SH, addresses and template verified");
    }
    Ok(())
}
fn main(){
    let result=std::env::args().nth(1).ok_or("kit path required".to_owned()).and_then(|zip|verify(&zip));
    if let Err(e)=result {eprintln!("{e}");std::process::exit(1);}
}
