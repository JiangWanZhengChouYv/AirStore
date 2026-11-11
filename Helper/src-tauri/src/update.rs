//! Helper <-> on-device AirStore linkage and update checking.
//!
//! The Helper inherited iLoader's install flow: it can push an IPA and place a pairing file, but it
//! never knows which AirStore build is actually on the phone, nor whether a newer one exists. These
//! commands give the UI that information using the same installation proxy and the same source feed
//! the app itself reads, so the Helper stops being a re-skin with hard-coded URLs.

use std::time::Duration;

use idevice::{IdeviceService, installation_proxy::InstallationProxyClient};
use serde::Serialize;
use tauri::State;

use crate::{
    device::{DeviceInfoMutex, get_provider},
    error::AppError,
};

const SOURCE_FEED: &str = "https://raw.githubusercontent.com/JiangWanZhengChouYv/AirStore/develop-source/source/airstore-source.json";
const AIRSTORE_BUNDLE_ID: &str = "com.JiangWanZhengChouYv.AirStore";
const HELPER_RELEASE_API: &str = "https://api.github.com/repos/JiangWanZhengChouYv/AirStore/releases/tags/helper-latest";
const HELPER_RELEASE_PAGE: &str = "https://github.com/JiangWanZhengChouYv/AirStore/releases/tag/helper-latest";

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct InstalledAirStore {
    pub installed: bool,
    pub version: Option<String>,
    pub bundle_id: Option<String>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AirStoreRelease {
    pub track: String,
    pub version: String,
    pub date: String,
    pub download_url: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct HelperRelease {
    /// `updated_at`, not `published_at`: `helper-latest` is a rolling tag whose assets are
    /// re-uploaded with `--clobber`, so `published_at` stays at the day the release was created
    /// while `updated_at` moves with every build.
    pub updated_at: String,
    pub release_url: String,
    pub assets: Vec<String>,
}

/// Both version checks run on app launch, so they get a deadline: a stalled connection must not
/// leave the UI waiting forever.
fn http_client() -> Result<reqwest::Client, AppError> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| AppError::Download(format!("Could not create an HTTP client: {e}")))
}

/// Which AirStore build is installed on the selected device. `CFBundleShortVersionString` is what
/// the app shows in Settings, so comparing it with the feed is comparing like with like.
#[tauri::command]
pub async fn installed_airstore(
    device_state: State<'_, DeviceInfoMutex>,
) -> Result<InstalledAirStore, AppError> {
    let device = {
        let guard = device_state.lock().unwrap();
        match &*guard {
            Some(d) => d.clone(),
            None => return Err(AppError::NoDeviceSelected),
        }
    };

    let provider = get_provider(&device.info).await?;
    let mut proxy = InstallationProxyClient::connect(&provider)
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage(
                "Failed to connect to installation proxy".into(),
                e.to_string(),
            )
        })?;
    let apps = proxy
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| {
            AppError::DeviceComsWithMessage("Failed to get installed apps".into(), e.to_string())
        })?;

    for (bundle_id, app) in apps {
        let Some(dict) = app.as_dictionary() else { continue };
        let display_name = dict
            .get("CFBundleDisplayName")
            .and_then(|value| value.as_string());
        if bundle_id != AIRSTORE_BUNDLE_ID && display_name != Some("AirStore") {
            continue;
        }

        let version = dict
            .get("CFBundleShortVersionString")
            .and_then(|value| value.as_string())
            .map(str::to_string);
        return Ok(InstalledAirStore {
            installed: true,
            version,
            bundle_id: Some(bundle_id),
        });
    }

    Ok(InstalledAirStore {
        installed: false,
        version: None,
        bundle_id: None,
    })
}

/// Latest AirStore build on the requested track, straight from the feed the phone subscribes to.
/// Both tracks live in the same generated `develop-source` JSON.
#[tauri::command]
pub async fn latest_airstore_release(track: String) -> Result<AirStoreRelease, AppError> {
    let client = http_client()?;
    let body = client
        .get(SOURCE_FEED)
        .send()
        .await
        .map_err(|e| AppError::Download(format!("Could not read the AirStore source: {e}")))?
        .text()
        .await
        .map_err(|e| AppError::Download(format!("Could not read the AirStore source: {e}")))?;
    let json: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| AppError::Download(format!("Could not parse the AirStore source: {e}")))?;

    let release = json["apps"]
        .as_array()
        .and_then(|apps| {
            apps.iter()
                .find(|app| app["bundleIdentifier"] == AIRSTORE_BUNDLE_ID)
        })
        .and_then(|app| app["releaseChannels"].as_array())
        .and_then(|channels| channels.iter().find(|channel| channel["track"] == track))
        .and_then(|channel| channel["releases"].as_array())
        .and_then(|releases| releases.first())
        .cloned()
        .ok_or_else(|| {
            AppError::Download(format!("The AirStore source has no {track} release"))
        })?;

    Ok(AirStoreRelease {
        track,
        version: release["version"].as_str().unwrap_or("").to_string(),
        date: release["date"].as_str().unwrap_or("").to_string(),
        download_url: release["downloadURL"].as_str().unwrap_or("").to_string(),
    })
}

/// The rolling `helper-latest` prerelease. The Helper's own version is a fixed 0.1.0, so the UI
/// compares this release's last-updated timestamp with the one it saw previously instead of
/// pretending a semantic version bump happened. GitHub's API requires a User-Agent.
#[tauri::command]
pub async fn check_helper_update() -> Result<HelperRelease, AppError> {
    let client = http_client()?;
    let response = client
        .get(HELPER_RELEASE_API)
        .header("User-Agent", "AirStore-Helper")
        .send()
        .await
        .map_err(|e| AppError::Download(format!("Could not check for Helper updates: {e}")))?;
    if !response.status().is_success() {
        return Err(AppError::Download(format!(
            "Helper update check returned HTTP {}",
            response.status()
        )));
    }
    let body = response
        .text()
        .await
        .map_err(|e| AppError::Download(format!("Could not read the Helper release: {e}")))?;
    let json: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| AppError::Download(format!("Could not parse the Helper release: {e}")))?;

    let assets = json["assets"]
        .as_array()
        .map(|assets| {
            assets
                .iter()
                .filter_map(|asset| asset["name"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();

    let updated_at = json["updated_at"]
        .as_str()
        .or_else(|| json["published_at"].as_str())
        .unwrap_or("")
        .to_string();

    Ok(HelperRelease {
        updated_at,
        release_url: json["html_url"]
            .as_str()
            .unwrap_or(HELPER_RELEASE_PAGE)
            .to_string(),
        assets,
    })
}
