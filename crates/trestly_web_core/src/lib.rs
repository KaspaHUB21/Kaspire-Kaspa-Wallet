//! Separate WASM instance avoids colliding SDK exports without upgrading the
//! upstream pool SDK or changing the existing wallet signing module.
mod keys;
pub use keys::*;
use keys::{derive_key,derive_address,controls_address};
#[path = "../../kaspa_secure_core/src/secret_input.rs"]
mod secret_input;
use wasm_bindgen::prelude::*;
#[path = "../../kaspa_secure_core/src/trestly.rs"]
pub mod trestly;
#[wasm_bindgen(js_name = describeTrestly)]
pub fn describe(request:&str)->std::result::Result<String,JsError>{
    trestly::describe(request).map(|v|v.to_string()).map_err(|e|JsError::new(&e.to_string()))
}
#[wasm_bindgen(js_name = prepareTrestly)]
pub fn prepare(request:&str)->std::result::Result<String,JsError>{
    trestly::prepare(request).map(|v|v.to_string()).map_err(|e|JsError::new(&e.to_string()))
}
#[wasm_bindgen(js_name = signTrestly)]
pub fn sign(secret:Vec<u8>,request:&str,hash:&str)->std::result::Result<String,JsError>{
    let owned=secret_input::SecretInput::new(secret).map_err(JsError::new)?;
    trestly::sign(owned.text(),request,hash).map(|v|v.to_string()).map_err(|e|JsError::new(&e.to_string()))
}
