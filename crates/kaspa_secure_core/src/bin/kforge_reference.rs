//! Offline compilation diagnostic. Contract sources are supplied privately at
//! runtime and are never embedded in the signing core or this executable.
use silverscript_v1::{ast::Expr,compiler::{compile_contract,CompileOptions}};
use std::io::{self,Read};
fn hex(b:&[u8])->String{b.iter().map(|v|format!("{v:02x}")).collect()}
fn expr(v:&serde_json::Value)->Expr<'static>{
 if let Some(n)=v["int"].as_i64(){Expr::int(n)}else if let Some(n)=v["byte"].as_u64(){Expr::byte(n.try_into().unwrap())}else{
 let h=v["bytes"].as_str().unwrap();assert!(h.len()%2==0&&h.len()<1_000_000);Expr::bytes((0..h.len()).step_by(2).map(|i|u8::from_str_radix(&h[i..i+2],16).unwrap()).collect())
 }
}
fn main(){
 let mut raw=String::new();io::stdin().take(2_000_000).read_to_string(&mut raw).unwrap();let r:serde_json::Value=serde_json::from_str(&raw).unwrap();
 let file=r["file"].as_str().unwrap();assert!(["saleshard_prod5.sil","amm_pool6.sil","kcc20_argent.sil"].contains(&file));
 let source=std::fs::read_to_string(format!("/workspace/kit/{file}")).unwrap();
 let args=r["args"].as_array().unwrap().iter().map(expr).collect::<Vec<_>>();
 let compiled=compile_contract(&source,&args,CompileOptions::default()).unwrap();
 println!("{}",serde_json::json!({"bytecode":hex(&compiled.bytecode),"stateLayout":compiled.state_layout,"dispatchTags":compiled.dispatch_tags,"templateHash":hex(&compiled.template_hash())}));
}
