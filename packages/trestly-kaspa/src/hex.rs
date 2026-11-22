//! Lowercase hex, without a 0x prefix.

pub fn encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 0x0f) as usize] as char);
    }
    out
}

pub fn decode(text: &str) -> Result<Vec<u8>, String> {
    let text = text.strip_prefix("0x").unwrap_or(text);
    if text.len() % 2 != 0 {
        return Err("hex has an odd number of digits".into());
    }
    let digit = |c: u8| -> Result<u8, String> {
        match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            b'A'..=b'F' => Ok(c - b'A' + 10),
            _ => Err(format!("{:?} is not a hex digit", c as char)),
        }
    };
    text.as_bytes().chunks(2).map(|pair| Ok(digit(pair[0])? << 4 | digit(pair[1])?)).collect()
}
