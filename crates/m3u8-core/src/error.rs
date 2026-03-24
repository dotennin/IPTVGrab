use thiserror::Error;

#[derive(Error, Debug, Clone)]
pub enum DownloadError {
    #[error("Network error: {0}")]
    Network(String),

    #[error("M3U8 parse error: {0}")]
    Parse(String),

    #[error("AES decryption error: {0}")]
    Decryption(String),

    #[error("I/O error: {0}")]
    Io(String),

    #[error("ffmpeg error: {0}")]
    Merge(String),

    #[error("Cancelled")]
    Cancelled,

    #[error("{0}")]
    Other(String),
}

impl From<reqwest::Error> for DownloadError {
    fn from(e: reqwest::Error) -> Self {
        Self::Network(e.to_string())
    }
}

impl From<std::io::Error> for DownloadError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}
