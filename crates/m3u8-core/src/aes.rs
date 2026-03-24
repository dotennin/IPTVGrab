use crate::error::DownloadError;
use aes::Aes128;
use cbc::Decryptor;
use cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};

type Aes128CbcDec = Decryptor<Aes128>;

/// Decrypt AES-128 CBC encrypted segment data.
/// `key` must be 16 bytes; `iv` is hex string (e.g. "0x00000000000000000000000000000001")
/// or None (defaults to 16 zero bytes).
pub fn decrypt_aes128(
    data: &[u8],
    key: &[u8],
    iv_hex: Option<&str>,
) -> Result<Vec<u8>, DownloadError> {
    let iv_bytes: Vec<u8> = match iv_hex {
        Some(s) => {
            let stripped = s.trim_start_matches("0x").trim_start_matches("0X");
            let padded = format!("{:0>32}", stripped); // pad to 32 hex chars = 16 bytes
            hex::decode(&padded).map_err(|e| DownloadError::Decryption(e.to_string()))?
        }
        None => vec![0u8; 16],
    };

    if key.len() < 16 || iv_bytes.len() < 16 {
        return Err(DownloadError::Decryption("Key or IV too short".into()));
    }

    let decryptor = Aes128CbcDec::new_from_slices(&key[..16], &iv_bytes[..16])
        .map_err(|e| DownloadError::Decryption(e.to_string()))?;

    let mut buf = data.to_vec();
    decryptor
        .decrypt_padded_vec_mut::<Pkcs7>(&mut buf)
        .map_err(|e| DownloadError::Decryption(e.to_string()))
}
