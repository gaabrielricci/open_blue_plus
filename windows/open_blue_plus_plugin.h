#ifndef FLUTTER_PLUGIN_OPEN_BLUE_PLUS_PLUGIN_H_
#define FLUTTER_PLUGIN_OPEN_BLUE_PLUS_PLUGIN_H_

// Must come before the WinRT headers.
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "scan_filter.h"
#include "ui_dispatcher.h"

namespace open_blue_plus {

namespace wdb = winrt::Windows::Devices::Bluetooth;
namespace wdba = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace wenum = winrt::Windows::Devices::Enumeration;
namespace wgatt = winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
namespace wradio = winrt::Windows::Devices::Radios;

// Error reported to Dart: protocol code, message, platform status (or null).
struct Failure {
  std::string code;
  std::string message;
  flutter::EncodableValue status;
};

// A method result that can be completed at most once (later calls are
// ignored), so a request can race with a disconnect safely.
class Reply {
 public:
  explicit Reply(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  ~Reply();

  Reply(const Reply&) = delete;
  Reply& operator=(const Reply&) = delete;

  void Success(const flutter::EncodableValue& value = flutter::EncodableValue());
  void Error(const std::string& code, const std::string& message,
             const flutter::EncodableValue& status = flutter::EncodableValue());
  void Fail(const Failure& failure);
  void NotImplemented();
  bool done() const { return !result_; }

 private:
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result_;
};

using ReplyPtr = std::shared_ptr<Reply>;

// Where a characteristic sits in the last discoverServices result
// (PROTOCOL.md, "Attribute addressing").
struct CharacteristicAddress {
  std::string service;
  int64_t service_index = 0;
  std::string characteristic;
  int64_t characteristic_index = 0;
};

struct DiscoveredCharacteristic {
  wgatt::GattCharacteristic characteristic{nullptr};
  std::string uuid;
  uint32_t properties = 0;  // protocol bit layout
  // In discovery order; descriptors are addressed by UUID (first match).
  std::vector<std::pair<std::string, wgatt::GattDescriptor>> descriptors;
};

// One entry of the flattened discoverServices list, in the same order.
struct DiscoveredService {
  wgatt::GattDeviceService service{nullptr};
  std::string uuid;
  uint16_t handle = 0;
  bool primary = true;
  std::vector<int32_t> included;  // positions in the list
  std::vector<DiscoveredCharacteristic> characteristics;
};

// An enabled notification. The characteristic is held strongly because the
// revoker only keeps a weak reference and the event dies with the object.
struct Subscription {
  wgatt::GattCharacteristic characteristic{nullptr};
  CharacteristicAddress address;  // reported in value events
  wgatt::GattCharacteristic::ValueChanged_revoker revoker;
};

// State of one connection (or connection attempt). Platform thread only.
struct DeviceSession {
  std::string id;
  uint64_t generation = 0;  // tells this attempt apart from later ones
  bool auto_connect = false;
  bool connected = false;
  int mtu = 23;
  std::string name;
  wdb::BluetoothLEDevice device{nullptr};
  wgatt::GattSession session{nullptr};
  ReplyPtr connect_reply;
  // In-flight GATT requests, failed with not_connected on disconnect.
  std::vector<std::weak_ptr<Reply>> pending;
  // Every service object opened. Windows keeps the link up while any of them
  // (or the session/device) is alive, so all are closed on disconnect.
  std::vector<wgatt::GattDeviceService> services;
  bool discovering = false;
  bool uncached_discovery = false;  // requested by clearGattCache
  // Last discoverServices result; cleared when the GATT database changes.
  std::vector<DiscoveredService> gatt;
  // Keyed by characteristic attribute handle (unique even when UUIDs repeat).
  std::map<uint16_t, Subscription> notifications;
  wdb::BluetoothLEDevice::ConnectionStatusChanged_revoker status_revoker;
  wdb::BluetoothLEDevice::GattServicesChanged_revoker services_revoker;
  wdb::BluetoothLEDevice::NameChanged_revoker name_revoker;
  wgatt::GattSession::MaxPduSizeChanged_revoker mtu_revoker;
};

// A createBond in progress. Platform thread only.
struct BondAttempt {
  ReplyPtr reply;
  winrt::Windows::Foundation::IAsyncOperation<wenum::DevicePairingResult>
      operation{nullptr};
};

class OpenBluePlusPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit OpenBluePlusPlugin(flutter::BinaryMessenger* messenger);
  ~OpenBluePlusPlugin() override;

  OpenBluePlusPlugin(const OpenBluePlusPlugin&) = delete;
  OpenBluePlusPlugin& operator=(const OpenBluePlusPlugin&) = delete;

 private:
  void HandleMethodCall(const std::string& method,
                        const flutter::EncodableMap& args,
                        const ReplyPtr& reply);
  void Emit(flutter::EncodableMap event);
  // Emits a log event when [level] is enabled by setLogLevel.
  void Log(int level, const std::string& message);
  // Queues [task] on the platform thread; safe from any thread. Tasks may use
  // `this`: they never run after the destructor closed the dispatcher.
  static void PostTask(const std::weak_ptr<UiDispatcher>& dispatcher,
                       std::function<void()> task);

  // Adapter.
  winrt::fire_and_forget InitAdapter();
  std::string AdapterStateName() const;
  std::string AdapterName() const;
  void OnRadioStateChanged();
  winrt::fire_and_forget SetRadioState(wradio::RadioState target, ReplyPtr reply);

  // Scanning.
  void StartScan(const flutter::EncodableMap& args, const ReplyPtr& reply);
  void StopScan();
  void OnAdvertisement(uint64_t generation, const ScanRecord& record);
  void OnScanStopped(uint64_t generation, int error);

  // Connections.
  void Connect(const flutter::EncodableMap& args, const ReplyPtr& reply);
  winrt::fire_and_forget ConnectAsync(
      std::string id, uint64_t generation, uint64_t address,
      std::optional<wdb::BluetoothAddressType> address_type);
  void OnConnectionStatus(const std::string& id, uint64_t generation,
                          bool connected);
  void OnMtuChanged(const std::string& id, uint64_t generation, int mtu);
  void OnServicesChanged(const std::string& id, uint64_t generation);
  void OnNameChanged(const std::string& id, uint64_t generation,
                     const std::string& name);
  void MarkConnected(DeviceSession& device);
  // Link lost with autoConnect: reported as a disconnection, session kept.
  void LinkLost(DeviceSession& device);
  // [connect_code] is the error a pending connect() fails with.
  void CloseDevice(const std::string& id, const std::string& reason,
                   const flutter::EncodableValue& status,
                   const char* connect_code = "connect_failed");
  DeviceSession* FindDevice(const std::string& id, uint64_t generation);
  flutter::EncodableList ConnectedDevices() const;
  std::optional<wdb::BluetoothAddressType> KnownAddressType(uint64_t address) const;

  // System devices and bonding.
  winrt::fire_and_forget ListSystemDevices(winrt::hstring selector,
                                           ReplyPtr reply);
  winrt::fire_and_forget GetBondState(std::string id, uint64_t address,
                                      ReplyPtr reply);
  winrt::fire_and_forget CreateBond(std::string id, uint64_t address,
                                    std::string pin,
                                    std::shared_ptr<BondAttempt> attempt);
  winrt::fire_and_forget BondTimeout(std::string id,
                                     std::weak_ptr<BondAttempt> attempt,
                                     int64_t timeout_ms);
  void FinishBond(const std::string& id,
                  const std::shared_ptr<BondAttempt>& attempt,
                  const std::optional<Failure>& failure);
  winrt::fire_and_forget RemoveBond(std::string id, uint64_t address,
                                    ReplyPtr reply);
  void StartBondWatcher();
  void OnBondWatcherDevice(const std::string& watcher_id,
                           const std::string& address, bool paired);
  void OnBondWatcherRemoved(const std::string& watcher_id);
  // Emits bondState when it differs from the last state emitted for [id].
  void EmitBondState(const std::string& id, const std::string& state);

  // GATT.
  void HandleGatt(const std::string& method, const flutter::EncodableMap& args,
                  const ReplyPtr& reply);
  void SetNotify(DeviceSession& device, const CharacteristicAddress& address,
                 const wgatt::GattCharacteristic& chr, bool enable,
                 bool force_indications, const ReplyPtr& reply);
  winrt::fire_and_forget DiscoverServices(std::string id, uint64_t generation,
                                          wdb::BluetoothLEDevice device,
                                          wdb::BluetoothCacheMode mode,
                                          ReplyPtr reply);
  // Runs the WinRT request created by `start` (on the platform thread) and
  // hands its result to `finish(result, reply)` back on the platform thread,
  // unless the device was closed meanwhile (the reply is then already failed).
  template <typename Start, typename Finish>
  winrt::fire_and_forget RunGatt(ReplyPtr reply, Start start, Finish finish);
  void EmitValue(const std::string& id, const CharacteristicAddress& address,
                 const std::vector<uint8_t>& value);

  std::shared_ptr<UiDispatcher> dispatcher_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> methods_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  // Replaced on every listen (e.g. after a hot restart); sessions, scans and
  // subscriptions are independent of it.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  int64_t log_level_ = 0;

  // Calls received before the adapter lookup finished run once it has.
  bool adapter_ready_ = false;
  std::vector<std::function<void()>> deferred_;
  bool adapter_present_ = false;
  wradio::Radio radio_{nullptr};
  wradio::Radio::StateChanged_revoker radio_revoker_;
  std::string last_adapter_state_;

  wdba::BluetoothLEAdvertisementWatcher watcher_{nullptr};
  wdba::BluetoothLEAdvertisementWatcher::Received_revoker received_revoker_;
  wdba::BluetoothLEAdvertisementWatcher::Stopped_revoker stopped_revoker_;
  uint64_t scan_generation_ = 0;
  ScanFilter scan_filter_;
  bool scan_allow_duplicates_ = false;
  int64_t scan_divisor_ = 1;
  struct CachedAdvertisement {
    ScanRecord merged;
    bool reported = false;
    bool held = false;     // first advertisement kept back for its scan response
    uint64_t matches = 0;  // matching advertisements, for continuousDivisor
  };
  std::unordered_map<uint64_t, CachedAdvertisement> scan_cache_;
  // Address types seen while scanning or listing system devices; needed to
  // open random-address devices.
  std::unordered_map<uint64_t, wdb::BluetoothAddressType> address_types_;

  uint64_t next_generation_ = 0;
  std::map<std::string, std::unique_ptr<DeviceSession>> devices_;

  std::map<std::string, std::shared_ptr<BondAttempt>> bonds_;
  std::map<std::string, std::string> bond_states_;  // last emitted, by id
  // Paired LE devices, to report pairing changes made outside the plugin.
  wenum::DeviceWatcher bond_watcher_{nullptr};
  wenum::DeviceWatcher::Added_revoker bond_added_revoker_;
  wenum::DeviceWatcher::Updated_revoker bond_updated_revoker_;
  wenum::DeviceWatcher::Removed_revoker bond_removed_revoker_;
  wenum::DeviceWatcher::EnumerationCompleted_revoker bond_enumerated_revoker_;
  bool bond_watcher_enumerated_ = false;
  std::map<std::string, std::string> bond_watcher_ids_;  // watcher id -> id
};

}  // namespace open_blue_plus

#endif  // FLUTTER_PLUGIN_OPEN_BLUE_PLUS_PLUGIN_H_
