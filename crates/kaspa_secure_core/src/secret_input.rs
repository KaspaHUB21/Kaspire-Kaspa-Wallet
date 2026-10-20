//! Owned UTF-8 inputs for FFI. Acquire the wiping owner before any fallible
//! validation; malformed encoding, request parsing and signing errors all drop it.
use kaspa_bip32::PrivateKey;
use zeroize::Zeroize;
#[cfg(any(target_arch = "wasm32", test))]
use zeroize::Zeroizing;

#[cfg(any(target_arch = "wasm32", test))]
pub(crate) struct SecretInput(Zeroizing<Vec<u8>>);

#[cfg(any(target_arch = "wasm32", test))]
impl SecretInput {
    pub(crate) fn new(bytes: Vec<u8>) -> Result<Self, &'static str> {
        let owned = Zeroizing::new(bytes);
        std::str::from_utf8(&owned).map_err(|_| "Invalid secret encoding")?;
        Ok(Self(owned))
    }

    pub(crate) fn text(&self) -> &str {
        // Validated at construction; the owned bytes are never mutated/exposed.
        std::str::from_utf8(&self.0).expect("validated secret encoding")
    }
}

// BIP32 drops intermediate extended keys while walking the derivation path.
// Give those secp keys an explicit wiping Drop, not just the final key bytes.
#[derive(Clone)]
pub(crate) struct ErasedKey(pub(crate) kaspa_bip32::SecretKey);
impl Drop for ErasedKey {
    fn drop(&mut self) {
        self.0.non_secure_erase();
    }
}
impl PrivateKey for ErasedKey {
    type PublicKey = <kaspa_bip32::SecretKey as PrivateKey>::PublicKey;
    fn from_bytes(bytes: &[u8; 32]) -> kaspa_bip32::Result<Self> {
        kaspa_bip32::SecretKey::from_bytes(bytes).map(Self)
    }
    fn to_bytes(&self) -> [u8; 32] {
        self.0.to_bytes()
    }
    fn derive_child(&self, mut other: [u8; 32]) -> kaspa_bip32::Result<Self> {
        let result = self.0.derive_child(other).map(Self);
        other.zeroize();
        result
    }
    fn public_key(&self) -> Self::PublicKey {
        <kaspa_bip32::SecretKey as PrivateKey>::public_key(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_input_preserves_exact_utf8_without_normalization() {
        for value in ["", "mnemonic:example", "pásswörd 🔑", "e\u{301}", "\0"] {
            assert_eq!(
                SecretInput::new(value.as_bytes().to_vec()).unwrap().text(),
                value
            );
        }
        assert!(SecretInput::new(vec![0xff, 0x80]).is_err());
        // Do not impose a new password-length limit on existing backups.
        assert_eq!(SecretInput::new(vec![b'x'; 65537]).unwrap().text().len(), 65537);
    }
}
