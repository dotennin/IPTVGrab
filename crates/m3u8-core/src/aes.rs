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

#[cfg(test)]
mod tests {
    use super::*;
    use aes::Aes128;
    use cbc::Encryptor;
    use cipher::{BlockEncryptMut, KeyIvInit};

    type Aes128CbcEnc = Encryptor<Aes128>;

    fn encrypt_aes128_cbc(plaintext: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
        let enc = Aes128CbcEnc::new_from_slices(key, iv).unwrap();
        enc.encrypt_padded_vec_mut::<Pkcs7>(plaintext)
    }

    #[test]
    fn decrypt_roundtrip_with_explicit_iv() {
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let plaintext = b"Hello, AES world";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, iv);
        let iv_hex = hex::encode(iv);
        let result = decrypt_aes128(&ciphertext, key, Some(&iv_hex)).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn decrypt_roundtrip_with_null_iv_defaults_to_zeros() {
        let key = b"0123456789abcdef";
        let iv = [0u8; 16];
        let plaintext = b"Test plaintext!!";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, &iv);
        let result = decrypt_aes128(&ciphertext, key, None).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn decrypt_accepts_0x_prefixed_iv() {
        let key = b"0123456789abcdef";
        let iv = [0u8; 16];
        let plaintext = b"Prefixed IV test";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, &iv);
        let result =
            decrypt_aes128(&ciphertext, key, Some("0x00000000000000000000000000000000")).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn decrypt_accepts_uppercase_0x_prefixed_iv() {
        let key = b"0123456789abcdef";
        let iv = [0u8; 16];
        let plaintext = b"UPPERCASE prefix";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, &iv);
        let result =
            decrypt_aes128(&ciphertext, key, Some("0X00000000000000000000000000000000")).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn decrypt_pads_short_iv_hex_on_left() {
        // "0x1" should be left-padded to "00000000000000000000000000000001"
        let key = b"0123456789abcdef";
        let mut iv = [0u8; 16];
        iv[15] = 1u8;
        let plaintext = b"Short IV padding";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, &iv);
        let result = decrypt_aes128(&ciphertext, key, Some("0x1")).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn decrypt_fails_with_key_too_short() {
        let short_key = b"only8byt";
        let ciphertext = vec![0u8; 16];

        let err = decrypt_aes128(&ciphertext, short_key, None).unwrap_err();
        assert!(err.to_string().contains("too short") || err.to_string().contains("Key"));
    }

    #[test]
    fn decrypt_fails_with_invalid_iv_hex() {
        let key = b"0123456789abcdef";
        let ciphertext = vec![0u8; 16];

        let err = decrypt_aes128(&ciphertext, key, Some("0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
            .unwrap_err();
        assert!(matches!(err, DownloadError::Decryption(_)));
    }

    #[test]
    fn decrypt_fails_with_invalid_padding() {
        let key = b"0123456789abcdef";
        // Random bytes that won't have valid PKCS7 padding after decryption
        let garbled = vec![
            0xdeu8, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
            0xaa, 0xbb,
        ];

        let err = decrypt_aes128(&garbled, key, None).unwrap_err();
        assert!(matches!(err, DownloadError::Decryption(_)));
    }

    #[test]
    fn decrypt_handles_multiblock_plaintext() {
        let key = b"0123456789abcdef";
        let iv = b"abcdefghijklmnop";
        // 48 bytes → 3 AES blocks
        let plaintext = b"This is a longer plaintext that spans 3 blocks!!";

        let ciphertext = encrypt_aes128_cbc(plaintext, key, iv);
        let iv_hex = hex::encode(iv);
        let result = decrypt_aes128(&ciphertext, key, Some(&iv_hex)).unwrap();
        assert_eq!(result, plaintext);
    }
}
