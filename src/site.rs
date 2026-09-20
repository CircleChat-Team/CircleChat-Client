//! 站点身份校验。
//!
//! 保存地址前，客户端会先拉取 `{URL}/api/app-manifest`，核对三项：
//! app_id、`sha256(app_id + version + timestamp + SECRET)` 签名、时间戳偏差。
//! 全过才允许保存并进入 WebView。
//!
//! SECRET 只从环境变量 `APP_SECRET` 读，不写死在代码里。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use sha2::{Digest, Sha256};

/// 站点必须声明的应用 ID。
const EXPECTED_APP_ID: &str = "com.example.myapp";
/// 身份信息的接口路径。
const MANIFEST_PATH: &str = "/api/app-manifest";
/// 时间戳允许的偏差（秒）。
const TIMESTAMP_TOLERANCE_SECS: i64 = 300;
/// 校验请求的超时。
const MANIFEST_TIMEOUT: Duration = Duration::from_secs(8);
/// SECRET 所在的环境变量名。
const SECRET_ENV: &str = "APP_SECRET";

#[derive(Debug, Deserialize)]
struct AppManifest {
    app_id: String,
    version: String,
    timestamp: i64,
    signature: String,
}

/// SECRET 只在进程内读一次。
fn app_secret() -> Option<&'static str> {
    static SECRET: OnceLock<Option<String>> = OnceLock::new();

    SECRET
        .get_or_init(|| {
            std::env::var(SECRET_ENV)
                .ok()
                .map(|secret| secret.trim().to_string())
                .filter(|secret| !secret.is_empty())
        })
        .as_deref()
}

/// 会话内的校验结果缓存：同一个 URL 只真正请求一次（成功、失败都缓存）。
fn site_cache() -> &'static Mutex<HashMap<String, Result<(), String>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Result<(), String>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 把配置里的地址归一化成缓存 key（去掉首尾空白和结尾斜杠）。
fn site_key(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

/// 带缓存的校验入口。
///
/// 注意：**失败结果也会被缓存**，所以服务端修好后要让用户重启客户端才能重试。
pub(crate) fn verify_site_cached(base_url: &str) -> Result<(), String> {
    let key = site_key(base_url);

    if let Some(cached) = site_cache()
        .lock()
        .ok()
        .and_then(|cache| cache.get(&key).cloned())
    {
        println!("站点校验命中内存缓存：{key}");
        return cached;
    }

    let result = verify_site(&key);
    if let Ok(mut cache) = site_cache().lock() {
        cache.insert(key, result.clone());
    }
    result
}

/// 校验站点身份：拉取身份信息，再逐项核对。
fn verify_site(base_url: &str) -> Result<(), String> {
    let secret = app_secret().ok_or_else(|| format!("未设置环境变量 {SECRET_ENV}"))?;

    let manifest = fetch_manifest(&format!("{base_url}{MANIFEST_PATH}"))?;
    println!(
        "站点声明：app_id={} version={} timestamp={}",
        manifest.app_id, manifest.version, manifest.timestamp
    );

    verify_manifest(&manifest, secret, unix_timestamp()?)
}

/// 纯校验逻辑（不碰网络、不读环境变量），方便单测。
fn verify_manifest(manifest: &AppManifest, secret: &str, now: i64) -> Result<(), String> {
    if manifest.app_id != EXPECTED_APP_ID {
        return Err(format!("app_id 不匹配（{}）", manifest.app_id));
    }

    let drift = (now - manifest.timestamp).abs();
    if drift > TIMESTAMP_TOLERANCE_SECS {
        return Err(format!("时间戳偏差 {drift} 秒"));
    }

    let expected = manifest_signature(EXPECTED_APP_ID, &manifest.version, manifest.timestamp, secret);
    if !constant_time_eq(
        expected.as_bytes(),
        normalize_signature(&manifest.signature).as_bytes(),
    ) {
        return Err("签名不匹配".to_string());
    }

    Ok(())
}

fn unix_timestamp() -> Result<i64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .map_err(|err| format!("读取系统时间失败：{err}"))
}

/// `sha256(app_id + version + timestamp + SECRET)`，返回小写 hex。
fn manifest_signature(app_id: &str, version: &str, timestamp: i64, secret: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{app_id}{version}{timestamp}{secret}").as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// 容错处理：服务端可能带 `sha256=` / `sha256:` 前缀，统一成小写 hex 再比。
fn normalize_signature(signature: &str) -> String {
    let trimmed = signature.trim().to_ascii_lowercase();

    trimmed
        .strip_prefix("sha256=")
        .or_else(|| trimmed.strip_prefix("sha256:"))
        .unwrap_or(&trimmed)
        .to_string()
}

/// 定长比较，避免签名比对时提前返回。
fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    left.iter()
        .zip(right.iter())
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

fn fetch_manifest(url: &str) -> Result<AppManifest, String> {
    let mut response = ureq::get(url)
        .config()
        .timeout_global(Some(MANIFEST_TIMEOUT))
        .build()
        .call()
        .map_err(|err| format!("请求 {url} 失败：{err}"))?;

    let status = response.status();
    if !status.is_success() {
        return Err(format!("{url} 返回 {status}"));
    }

    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|err| format!("读取响应内容失败：{err}"))?;

    serde_json::from_str::<AppManifest>(&body).map_err(|err| format!("响应解析失败：{err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "s3cr3t";

    fn manifest(version: &str, timestamp: i64, signature: String) -> AppManifest {
        AppManifest {
            app_id: EXPECTED_APP_ID.to_string(),
            version: version.to_string(),
            timestamp,
            signature,
        }
    }

    fn signature(version: &str, timestamp: i64, secret: &str) -> String {
        manifest_signature(EXPECTED_APP_ID, version, timestamp, secret)
    }

    #[test]
    fn signature_vector_matches_coreutils() {
        // 真值来自：printf 'com.example.myapp1.0.01700000000s3cr3t' | sha256sum
        assert_eq!(
            signature("1.0.0", 1700000000, SECRET),
            "db404ccf3c5e8457a6a1a6f0f7288722692fd66955f65312d249fe2677541429"
        );
    }

    #[test]
    fn valid_manifest_passes() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));

        assert!(verify_manifest(&item, SECRET, 1700000100).is_ok());
        // 边界：正好 300 秒也算通过
        assert!(verify_manifest(&item, SECRET, 1700000300).is_ok());
    }

    #[test]
    fn wrong_app_id_is_rejected() {
        let mut item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));
        item.app_id = "com.evil.app".to_string();

        assert!(verify_manifest(&item, SECRET, 1700000000).is_err());
    }

    #[test]
    fn stale_timestamp_is_rejected() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, SECRET));

        assert!(verify_manifest(&item, SECRET, 1700000301).is_err());
    }

    #[test]
    fn wrong_secret_is_rejected() {
        let item = manifest("1.0.0", 1700000000, signature("1.0.0", 1700000000, "wrong"));

        assert!(verify_manifest(&item, SECRET, 1700000000).is_err());
    }

    #[test]
    fn sha256_prefix_is_tolerated() {
        let item = manifest(
            "1.0.0",
            1700000000,
            format!("sha256:{}", signature("1.0.0", 1700000000, SECRET)),
        );

        assert!(verify_manifest(&item, SECRET, 1700000000).is_ok());
    }

    #[test]
    fn site_key_normalizes_trailing_slash() {
        assert_eq!(site_key("  https://chat.example.com/  "), "https://chat.example.com");
    }
}
