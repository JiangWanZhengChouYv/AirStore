import { useCallback, useEffect, useRef, useState } from "react";
import "./App.css";
import { AppleID } from "./AppleID";
import { Device, DeviceInfo } from "./Device";
import { invoke } from "@tauri-apps/api/core";
import { open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  sideloadOperation,
  installSideStoreOperation,
  Operation,
  OperationState,
  OperationUpdate,
} from "./components/operations";
import { listen } from "@tauri-apps/api/event";
import OperationView from "./components/OperationView";
import { toast } from "sonner";
import { Modal } from "./components/Modal";
import { Certificates } from "./pages/Certificates";
import { AppIds } from "./pages/AppIds";
import { Settings } from "./pages/Settings";
import { Pairing } from "./pages/Pairing";
import { getVersion } from "@tauri-apps/api/app";
import logo from "./airstore.png";
import { GlassCard } from "./components/GlassCard";
import { useTranslation } from "react-i18next";
import { usePlatform } from "./PlatformContext";

type InstalledAirStore = {
  installed: boolean;
  version: string | null;
  bundleId: string | null;
};

type ReleaseInfo = {
  track: string;
  version: string;
  date: string;
  downloadUrl: string;
};

type HelperReleaseInfo = {
  publishedAt: string;
  releaseUrl: string;
  assets: string[];
};

function App() {
  const { t } = useTranslation();

  const [operationState, setOperationState] = useState<OperationState | null>(
    null,
  );
  const [loggedInAs, setLoggedInAs] = useState<string | null>(null);
  const [selectedDevice, setSelectedDevice] = useState<DeviceInfo | null>(null);
  const [openModal, setOpenModal] = useState<
    null | "certificates" | "appids" | "pairing"
  >(null);
  const [version, setVersion] = useState<string>("");
  // The Helper used to install AirStore without ever knowing which build was on the phone.
  const [deviceAirStore, setDeviceAirStore] = useState<InstalledAirStore | null>(null);
  const [latestReleases, setLatestReleases] = useState<
    Partial<Record<"stable" | "develop", ReleaseInfo>>
  >({});
  const [checkingHelperUpdate, setCheckingHelperUpdate] = useState(false);
  // Bumped after an install so the build shown for the device is read again.
  const [deviceBuildKey, setDeviceBuildKey] = useState(0);

  const refreshDevicesRef = useRef<(() => void) | null>(null);

  const [noKeyringAvailable, setNoKeyringAvailable] = useState<boolean>(false);
  const { platform } = usePlatform();

  const checkKeyring = useCallback(async () => {
    try {
      let available = await invoke<boolean>("keyring_available");
      setNoKeyringAvailable(!available);
    } catch (e) {
      console.error("Unable to check keyring availability:", e);
      setNoKeyringAvailable(true);
    }
  }, []);

  useEffect(() => {
    checkKeyring();
  }, [checkKeyring]);

  useEffect(() => {
    const fetchVersion = async () => {
      const version = await getVersion();
      setVersion(version);
    };
    fetchVersion();
  }, []);

  // Link with the phone: read the AirStore build actually installed, and the newest build on each
  // track from the same feed the app subscribes to.
  useEffect(() => {
    if (!selectedDevice) {
      setDeviceAirStore(null);
      return;
    }
    invoke<InstalledAirStore>("installed_airstore")
      .then(setDeviceAirStore)
      .catch((e) => {
        console.error("Unable to read the installed AirStore build:", e);
        setDeviceAirStore(null);
      });
  }, [selectedDevice, deviceBuildKey]);

  useEffect(() => {
    (["stable", "develop"] as const).forEach((track) => {
      invoke<ReleaseInfo>("latest_airstore_release", { track })
        .then((release) =>
          setLatestReleases((old) => ({ ...old, [track]: release })),
        )
        .catch((e) =>
          console.error(`Unable to read the ${track} AirStore release:`, e),
        );
    });
  }, []);

  const checkForHelperUpdate = useCallback(
    async (silent: boolean) => {
      setCheckingHelperUpdate(true);
      try {
        const release = await invoke<HelperReleaseInfo>("check_helper_update");
        const previous = localStorage.getItem("helper-last-release-date");
        localStorage.setItem("helper-last-release-date", release.publishedAt);
        if (previous && previous !== release.publishedAt) {
          toast(
            t("update.new_version_available", {
              version: release.publishedAt.slice(0, 10),
              defaultValue: "A new Helper build is available: {{version}}",
            }),
            {
              action: {
                label: t("update.download", { defaultValue: "Download" }),
                onClick: () => openUrl(release.releaseUrl),
              },
            },
          );
        } else if (!silent) {
          toast.success(
            t("update.up_to_date", { defaultValue: "You're up to date." }),
          );
        }
      } catch (e) {
        console.error("Helper update check failed:", e);
        if (!silent) {
          toast.error(
            t("update.failed_check", {
              defaultValue: "Could not check for updates.",
            }),
          );
        }
      } finally {
        setCheckingHelperUpdate(false);
      }
    },
    [t],
  );

  useEffect(() => {
    // Silent on launch; the header button is the explicit check.
    checkForHelperUpdate(true);
  }, [checkForHelperUpdate]);

  const shortcutLabel = useCallback(
    (mac: string, windows: string, linux?: string) => {
      if (platform === "mac") return mac;
      if (platform === "linux") return linux ?? windows;
      return windows;
    },
    [platform],
  );

  const startOperation = useCallback(
    async (
      operation: Operation,
      params: { [key: string]: any },
    ): Promise<void> => {
      setOperationState({
        current: operation,
        started: [],
        failed: [],
        completed: [],
      });
      return new Promise<void>(async (resolve, reject) => {
        const unlistenFn = await listen<OperationUpdate>(
          "operation_" + operation.id,
          (event) => {
            setOperationState((old) => {
              if (old == null) return null;
              if (event.payload.updateType === "started") {
                return {
                  ...old,
                  started: [...old.started, event.payload.stepId],
                };
              } else if (event.payload.updateType === "finished") {
                return {
                  ...old,
                  completed: [...old.completed, event.payload.stepId],
                };
              } else if (event.payload.updateType === "failed") {
                return {
                  ...old,
                  failed: [
                    ...old.failed,
                    {
                      stepId: event.payload.stepId,
                      extraDetails: event.payload.extraDetails,
                    },
                  ],
                };
              }
              return old;
            });
          },
        );
        try {
          await invoke(operation.id + "_operation", params);
          unlistenFn();
          setDeviceBuildKey((key) => key + 1);
          resolve();
        } catch (e) {
          unlistenFn();
          reject(e);
        }
      });
    },
    [setOperationState],
  );

  const ensuredLoggedIn = useCallback((): boolean => {
    if (loggedInAs) return true;
    toast.error(t("app.must_be_logged_in"));
    return false;
  }, [loggedInAs, t]);

  const ensureSelectedDevice = useCallback((): boolean => {
    if (selectedDevice) return true;
    toast.error(t("app.must_select_device"));
    return false;
  }, [selectedDevice, t]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === undefined) return;
      const key = event.key.toLowerCase();
      const primaryPressed = platform === "mac" ? event.metaKey : event.ctrlKey;
      if (!primaryPressed) return;

      if (!event.shiftKey && key === "p") {
        event.preventDefault();
        if (!ensureSelectedDevice()) return;
        setOpenModal("pairing");
      } else if (event.shiftKey && key === "c") {
        event.preventDefault();
        if (!ensuredLoggedIn()) return;
        setOpenModal("certificates");
      } else if (event.shiftKey && key === "a") {
        event.preventDefault();
        if (!ensuredLoggedIn()) return;
        setOpenModal("appids");
      } else if (!event.shiftKey && key === "r") {
        event.preventDefault();
        refreshDevicesRef.current?.();
      }
    };

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [platform, ensureSelectedDevice, ensuredLoggedIn]);

  return (
    <main className="workspace">
      <header className="workspace-header">
        <div className="header-left">
          <div className="title-block">
            <img src={logo} alt={t("app.logo_alt")} className="logo" />
            <div>
              <h1 className="title">AirStore Helper</h1>
              <p className="subtitle">{t("subtitle")}</p>
            </div>
          </div>
          <span className="version-pill">
            {t("version")} {version}
          </span>
        </div>
        <div className="header-actions">
          <button
            className="toolbar-button"
            disabled={checkingHelperUpdate}
            onClick={() => checkForHelperUpdate(false)}
          >
            {t("app.check_updates", { defaultValue: "Check for updates" })}
          </button>
          <button
            className="toolbar-button"
            onClick={async () => {
              try {
                await openUrl("https://github.com/JiangWanZhengChouYv/AirStore");
              } catch (error) {
                console.error("Failed to open GitHub link", error);
                toast.error(t("app.open_github_failed"));
              }
            }}
          >
            {t("app.github")}
          </button>
        </div>
      </header>
      <div className="workspace-body">
        <aside className="workspace-sidebar">
          <section className="workspace-section">
            <div className="section-header">
              <p className="section-label">{t("app.section_account")}</p>
              {/* here to ensure spacing and stuff is correct */}
              <span className="section-hint placeholder" aria-hidden="true">
                Placeholder
              </span>
            </div>
            <GlassCard className="panel">
              <AppleID
                loggedInAs={loggedInAs}
                setLoggedInAs={setLoggedInAs}
                noKeyringAvailable={noKeyringAvailable}
              />
            </GlassCard>
          </section>
          <section className="workspace-section">
            <p className="section-label">{t("app.section_management")}</p>
            <div className="workspace-list">
              <button
                className="workspace-list-item"
                onClick={() => {
                  if (!ensureSelectedDevice()) return;
                  setOpenModal("pairing");
                }}
              >
                {t("app.manage_pairing_file")}{" "}
                <span aria-hidden="true">{shortcutLabel("⌘P", "Ctrl+P")}</span>
              </button>
              <button
                className="workspace-list-item"
                onClick={() => {
                  refreshDevicesRef.current?.();
                }}
              >
                {t("app.refresh_devices")}{" "}
                <span aria-hidden="true">{shortcutLabel("⌘R", "Ctrl+R")}</span>
              </button>
              <button
                className="workspace-list-item"
                onClick={() => {
                  if (!ensuredLoggedIn()) return;
                  setOpenModal("certificates");
                }}
              >
                {t("app.certificates")}{" "}
                <span aria-hidden="true">
                  {shortcutLabel("⌘⇧C", "Ctrl+Shift+C")}
                </span>
              </button>
              <button
                className="workspace-list-item"
                onClick={() => {
                  if (!ensuredLoggedIn()) return;
                  setOpenModal("appids");
                }}
              >
                {t("app.app_ids")}{" "}
                <span aria-hidden="true">
                  {shortcutLabel("⌘⇧A", "Ctrl+Shift+A")}
                </span>
              </button>
            </div>
          </section>
        </aside>
        <section className="workspace-content">
          <section className="workspace-section">
            <div className="section-header">
              <p className="section-label">{t("app.devices")}</p>
              <span className="section-hint">
                {selectedDevice
                  ? t("app.active_device", {
                      name: `${selectedDevice.name} (${selectedDevice.version})`,
                    })
                  : t("app.select_device")}
              </span>
            </div>
            <GlassCard className="panel">
              <Device
                selectedDevice={selectedDevice}
                setSelectedDevice={setSelectedDevice}
                registerRefresh={(fn) => {
                  refreshDevicesRef.current = fn ?? null;
                }}
              />
            </GlassCard>
          </section>
          <section className="workspace-section">
            <div className="section-header">
              <p className="section-label">{t("app.installers")}</p>
              <span className="section-hint">{t("app.choose_build")}</span>
            </div>
            <GlassCard className="panel">
              <div className="device-build-status">
                <p className="section-label">
                  {t("app.on_device", { defaultValue: "On this device" })}
                </p>
                <p className="section-hint">
                  {deviceAirStore === null
                    ? t("app.select_device_for_build", {
                        defaultValue: "Select a device to see its AirStore build.",
                      })
                    : deviceAirStore.installed
                      ? t("app.installed_build", {
                          version:
                            deviceAirStore.version ??
                            t("app.unknown_version", { defaultValue: "unknown" }),
                          defaultValue: "Installed: {{version}}",
                        })
                      : t("app.not_installed", {
                          defaultValue: "AirStore is not installed on this device.",
                        })}
                </p>
                <p className="section-hint">
                  {t("app.latest_builds", {
                    stable: latestReleases.stable?.version ?? "–",
                    develop: latestReleases.develop?.version ?? "–",
                    defaultValue:
                      "Latest stable: {{stable}} · Latest develop: {{develop}}",
                  })}
                </p>
                {deviceAirStore?.installed &&
                  latestReleases.develop &&
                  deviceAirStore.version !== latestReleases.develop.version && (
                    <button
                      onClick={() => {
                        if (!ensuredLoggedIn() || !ensureSelectedDevice()) return;
                        startOperation(installSideStoreOperation, {
                          nightly: false,
                          liveContainer: false,
                          develop: true,
                        }).catch((e) => console.error(e));
                      }}
                    >
                      {t("app.update_to_develop", {
                        defaultValue: "Update to the latest develop build",
                      })}
                    </button>
                  )}
              </div>
              <div className="action-row single-row">
                <button
                  onClick={() => {
                    if (!ensuredLoggedIn() || !ensureSelectedDevice()) return;
                    startOperation(installSideStoreOperation, {
                      nightly: false,
                      liveContainer: false,
                      develop: false,
                    }).catch((e) => {
                      console.log(e.type);
                      console.error(e.message);
                    });
                  }}
                >
                  {t("app.sidestore_stable")}
                </button>
                <button
                  onClick={() => {
                    if (!ensuredLoggedIn() || !ensureSelectedDevice()) return;
                    startOperation(installSideStoreOperation, {
                      nightly: false,
                      liveContainer: false,
                      develop: true,
                    }).catch((e) => {
                      console.log(e.type);
                      console.error(e.message);
                    });
                  }}
                >
                  {t("app.sidestore_develop")}
                </button>
                <button
                  onClick={async () => {
                    if (!ensuredLoggedIn() || !ensureSelectedDevice()) return;
                    let path = await openFileDialog({
                      multiple: false,
                      filters: [
                        { name: t("app.ipa_files"), extensions: ["ipa"] },
                      ],
                    });
                    if (!path) return;
                    startOperation(sideloadOperation, {
                      appPath: path as string,
                    }).catch((e) => {
                      console.log(e.type);
                      console.error(e.message);
                    });
                  }}
                >
                  {t("app.import_ipa")}
                </button>
              </div>
            </GlassCard>
          </section>
          <section className="workspace-section">
            <p className="section-label">{t("app.settings")}</p>
            <GlassCard className="panel settings-panel">
              <Settings
                ensureSelectedDevice={ensureSelectedDevice}
                setSelectedDevice={setSelectedDevice}
                platform={platform}
                shortcutLabel={shortcutLabel}
                checkKeyring={checkKeyring}
              />
            </GlassCard>
          </section>
          {operationState && (
            <OperationView
              operationState={operationState}
              closeMenu={() => setOperationState(null)}
            />
          )}
        </section>
      </div>
      <Modal
        isOpen={openModal === "certificates"}
        close={() => setOpenModal(null)}
      >
        <Certificates />
      </Modal>
      <Modal isOpen={openModal === "appids"} close={() => setOpenModal(null)}>
        <AppIds />
      </Modal>
      <Modal isOpen={openModal === "pairing"} close={() => setOpenModal(null)}>
        <Pairing />
      </Modal>
    </main>
  );
}

export default App;
