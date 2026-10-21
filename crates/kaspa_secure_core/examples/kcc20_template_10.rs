//! Offline deterministic template exporter; no wallet, RPC or signing.
use silverscript_v1::{ast::Expr, compiler::{compile_contract, CompileOptions}};
fn main() {
    let source=include_str!("../src/kcc20_reference_10.sil");
    let mut args=vec![Expr::bytes(vec![0;32]),Expr::int(1000),Expr::bytes(vec![0x11;32]),Expr::int(0),Expr::int(0),Expr::bytes(vec![0;32]),Expr::bytes(vec![0;32])];
    let first=compile_contract(source,&args,CompileOptions::default()).unwrap();
    let hash=first.template_hash();
    args[0]=Expr::bytes(hash.to_vec());
    let c=compile_contract(source,&args,CompileOptions::default()).unwrap();
    assert_eq!(c.template_hash(),hash);
    let start=c.state_layout.start+33;let end=c.state_layout.start+c.state_layout.len;
    let prefix=&c.bytecode[..start];let suffix=&c.bytecode[end..];
    assert_eq!(c.state_layout.len,145);assert_eq!(end-start,112);
    assert_eq!(suffix.len(),0x2c30);
    assert_eq!(c.dispatch_tags["transfer"],[0x79,0xc7,0x1c,0x23]);
    assert_eq!(c.dispatch_tags["transfer_delegator"],[0xfd,0x3e,0xf1,0x4a]);
    println!("{}",serde_json::json!({"referenceCommit":"c8a087117735a1f87c5c6d115fcddeaf2562c784","compilerCommit":"3ed973335b59269293564805cc2c58a14595ec03","configuration":"10x10","templateHash":hex::encode(hash),"maxTokenInputs":10,"maxTokenOutputs":10,"prefix":hex::encode(prefix),"suffix":hex::encode(suffix),"transferTag":"79c71c23","delegatorTag":"fd3ef14a"}));
}
