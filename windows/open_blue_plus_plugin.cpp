#include "open_blue_plus_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <winerror.h>
#include <winrt/Windows.Foundation.Metadata.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <iterator>
#include <utility>

#include "ble_codec.h"

namespace open_blue_plus {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Foundation::IInspectable;
using winrt::Windows::Foundation::IReference;
using winrt::Windows::Foundation::Collections::IMapView;

constexpr uint32_t kPropertyNotify = 0x10;
constexpr uint32_t kPropertyIndicate = 0x20;
constexpr char kCccdUuid[] = "00002902-0000-1000-8000-00805f9b34fb";

constexpr int kLogError = 1;
constexpr int kLogInfo = 3;
constexpr int kLogDebug = 4;

constexpr wchar_t kAepDeviceAddress[] = L"System.Devices.Aep.DeviceAddress";
constexpr wchar_t kAepIsPaired[] = L"System.Devices.Aep.IsPaired";

// Ids are accepted in any case and kept (and emitted) upper-case.
std::string DeviceId(const EncodableMap& args) {
  const std::string id = GetString(args, "id");
  const auto address = ParseAddress(id);
  return address ? FormatAddress(*address) : id;
}

// Call only from inside a catch handler.
Failure CurrentFailure(const char* code) {
  try {
    throw;
  } catch (const winrt::hresult_error& e) {
    const int32_t hr = e.code();
    // RO_E_CLOSED: the WinRT object was closed because the device went away.
    const bool closed = hr == RO_E_CLOSED ||
                        hr == HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
    return {closed ? "not_connected" : code, winrt::to_string(e.message()),
            EncodableValue(hr)};
  } catch (...) {
    return {code, "Unexpected error", EncodableValue()};
  }
}

Failure GattStatusFailure(const std::string& operation,
                          wgatt::GattCommunicationStatus status,
                          const IReference<uint8_t>& protocol_error) {
  std::string message = operation + " failed: ";
  EncodableValue details(static_cast<int32_t>(status));
  switch (status) {
    case wgatt::GattCommunicationStatus::Unreachable:
      message += "device unreachable";
      break;
    case wgatt::GattCommunicationStatus::AccessDenied:
      message += "access denied";
      break;
    case wgatt::GattCommunicationStatus::ProtocolError:
      message += "ATT protocol error";
      break;
    default:
      message += "status " + std::to_string(static_cast<int32_t>(status));
      break;
  }
  if (protocol_error) {
    const uint8_t att_error = protocol_error.Value();
    char hex[8];
    std::snprintf(hex, sizeof(hex), " 0x%02x", static_cast<unsigned int>(att_error));
    message += hex;
    details = EncodableValue(static_cast<int32_t>(att_error));
  }
  return {"gatt_error", message, details};
}

template <typename T>
void CloseQuietly(const T& closable) {
  if (!closable) return;
  try {
    closable.Close();
  } catch (...) {
  }
}

EncodableValue OptionalString(const std::optional<std::string>& value) {
  return value ? EncodableValue(*value) : EncodableValue();
}

EncodableValue NameValue(const std::string& name) {
  return name.empty() ? EncodableValue() : EncodableValue(name);
}

// Adds the service data of an AD structure of type 0x16, 0x20 or 0x21.
void AddServiceData(uint8_t type, const std::vector<uint8_t>& data,
                    std::map<std::string, std::vector<uint8_t>>& out) {
  const size_t uuid_size = type == 0x16   ? size_t{2}
                           : type == 0x20 ? size_t{4}
                           : type == 0x21 ? size_t{16}
                                          : size_t{0};
  if (uuid_size == 0 || data.size() < uuid_size) return;
  winrt::guid uuid{};
  if (uuid_size == 16) {
    uint8_t big_endian[16];
    for (size_t i = 0; i < 16; ++i) {
      big_endian[i] = data[15 - i];  // AD fields are little-endian
    }
    uuid = UuidFromBigEndian(big_endian);
  } else {
    uint32_t value = 0;
    for (size_t i = uuid_size; i > 0; --i) {
      value = (value << 8) | data[i - 1];
    }
    uuid = UuidFromShort(value);
  }
  out[FormatUuid(uuid)] = std::vector<uint8_t>(
      data.begin() + static_cast<std::ptrdiff_t>(uuid_size), data.end());
}

// IsConnectable, IsScannable, BluetoothAddressType and TransmitPowerLevelInDBm
// only exist from Windows 10 2004 (UniversalApiContract 10). Without them every
// property read would throw, so older systems use AdvertisementType instead.
bool HasExtendedAdvertisementArgs() {
  static const bool present = [] {
    try {
      return winrt::Windows::Foundation::Metadata::ApiInformation::
          IsApiContractPresent(L"Windows.Foundation.UniversalApiContract", 10);
    } catch (...) {
      return false;
    }
  }();
  return present;
}

// Runs on a WinRT thread-pool thread; touches only the event args.
ScanRecord ParseAdvertisement(
    const wdba::BluetoothLEAdvertisementReceivedEventArgs& args) {
  ScanRecord record;
  record.address = args.BluetoothAddress();
  record.rssi = args.RawSignalStrengthInDBm();
  const auto type = args.AdvertisementType();
  record.scan_response = type == wdba::BluetoothLEAdvertisementType::ScanResponse;
  if (HasExtendedAdvertisementArgs()) {
    record.address_type = args.BluetoothAddressType();
    record.connectable = args.IsConnectable();
    record.scannable = args.IsScannable();
    if (const auto tx = args.TransmitPowerLevelInDBm()) {
      record.tx_power = tx.Value();
    }
  } else {
    record.connectable =
        type == wdba::BluetoothLEAdvertisementType::ConnectableUndirected ||
        type == wdba::BluetoothLEAdvertisementType::ConnectableDirected;
    record.scannable =
        type == wdba::BluetoothLEAdvertisementType::ConnectableUndirected ||
        type == wdba::BluetoothLEAdvertisementType::ScannableUndirected;
  }
  const auto advertisement = args.Advertisement();
  const auto name = advertisement.LocalName();
  if (!name.empty()) {
    record.local_name = winrt::to_string(name);
  }
  for (const auto& uuid : advertisement.ServiceUuids()) {
    record.service_uuids.push_back(FormatUuid(uuid));
  }
  for (const auto& data : advertisement.ManufacturerData()) {
    record.manufacturer_data[static_cast<int32_t>(data.CompanyId())] =
        ToBytes(data.Data());
  }
  for (const auto& section : advertisement.DataSections()) {
    AddServiceData(section.DataType(), ToBytes(section.Data()),
                   record.service_data);
  }
  return record;
}

void Merge(ScanRecord& into, const ScanRecord& from) {
  into.address = from.address;
  into.address_type = from.address_type;
  into.rssi = from.rssi;
  into.scannable = from.scannable;
  into.scan_response = from.scan_response;
  // Scan responses are flagged non-connectable; keep what the advertisement said.
  into.connectable = into.connectable || from.connectable;
  if (from.local_name) into.local_name = from.local_name;
  if (from.tx_power) into.tx_power = from.tx_power;
  for (const auto& uuid : from.service_uuids) {
    if (std::find(into.service_uuids.begin(), into.service_uuids.end(), uuid) ==
        into.service_uuids.end()) {
      into.service_uuids.push_back(uuid);
    }
  }
  for (const auto& entry : from.manufacturer_data) {
    into.manufacturer_data[entry.first] = entry.second;
  }
  for (const auto& entry : from.service_data) {
    into.service_data[entry.first] = entry.second;
  }
}

EncodableMap ScanResultEvent(const ScanRecord& record) {
  EncodableMap manufacturer;
  for (const auto& entry : record.manufacturer_data) {
    manufacturer[EncodableValue(entry.first)] = EncodableValue(entry.second);
  }
  EncodableMap service_data;
  for (const auto& entry : record.service_data) {
    service_data[EncodableValue(entry.first)] = EncodableValue(entry.second);
  }
  EncodableList service_uuids;
  for (const auto& uuid : record.service_uuids) {
    service_uuids.push_back(EncodableValue(uuid));
  }
  return EncodableMap{
      {EncodableValue("type"), EncodableValue("scanResult")},
      {EncodableValue("id"), EncodableValue(FormatAddress(record.address))},
      // Windows has no separate cached device name while scanning.
      {EncodableValue("name"), OptionalString(record.local_name)},
      {EncodableValue("rssi"), EncodableValue(record.rssi)},
      {EncodableValue("connectable"), EncodableValue(record.connectable)},
      {EncodableValue("localName"), OptionalString(record.local_name)},
      {EncodableValue("txPowerLevel"),
       record.tx_power ? EncodableValue(*record.tx_power) : EncodableValue()},
      {EncodableValue("manufacturerData"), EncodableValue(manufacturer)},
      {EncodableValue("serviceData"), EncodableValue(service_data)},
      {EncodableValue("serviceUuids"), EncodableValue(service_uuids)},
  };
}

// Windows reports no disconnect reason, so `reason` is never set.
EncodableMap ConnectionStateEvent(const std::string& id, bool connected) {
  return EncodableMap{
      {EncodableValue("type"), EncodableValue("connectionState")},
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("connected"), EncodableValue(connected)},
  };
}

EncodableMap MtuEvent(const std::string& id, int mtu) {
  return EncodableMap{
      {EncodableValue("type"), EncodableValue("mtu")},
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("mtu"), EncodableValue(mtu)},
  };
}

EncodableValue DeviceEntry(const std::string& id, const std::string& name) {
  return EncodableValue(EncodableMap{
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("name"), NameValue(name)},
  });
}

bool IsGattMethod(const std::string& method) {
  static const char* const kMethods[] = {
      "discoverServices", "clearGattCache",  "read",
      "write",            "setNotify",       "readDescriptor",
      "writeDescriptor",  "requestMtu",      "readRssi"};
  for (const char* name : kMethods) {
    if (method == name) return true;
  }
  return false;
}

// Remembers [reply] so a disconnect can fail it; drops finished ones.
void Track(DeviceSession& device, const ReplyPtr& reply) {
  auto& pending = device.pending;
  pending.erase(std::remove_if(pending.begin(), pending.end(),
                               [](const std::weak_ptr<Reply>& weak) {
                                 return weak.expired();
                               }),
                pending.end());
  pending.push_back(reply);
}

// Finishes a write or writeDescriptor request.
auto FinishWrite(std::string operation) {
  return [operation](const wgatt::GattWriteResult& result, Reply& out) {
    if (result.Status() == wgatt::GattCommunicationStatus::Success) {
      out.Success();
    } else {
      out.Fail(GattStatusFailure(operation, result.Status(), result.ProtocolError()));
    }
  };
}

std::optional<CharacteristicAddress> CharacteristicArgs(const EncodableMap& args) {
  const auto service = NormalizeUuid(GetString(args, "service"));
  const auto characteristic = NormalizeUuid(GetString(args, "characteristic"));
  if (!service || !characteristic) return std::nullopt;
  return CharacteristicAddress{*service, GetInt(args, "serviceIndex", 0),
                               *characteristic,
                               GetInt(args, "characteristicIndex", 0)};
}

// Resolves the indices against the order discoverServices returned.
const DiscoveredCharacteristic* FindCharacteristic(
    const DeviceSession& device, const CharacteristicAddress& address) {
  int64_t service_seen = 0;
  for (const auto& service : device.gatt) {
    if (service.uuid != address.service) continue;
    if (service_seen++ != address.service_index) continue;
    int64_t characteristic_seen = 0;
    for (const auto& chr : service.characteristics) {
      if (chr.uuid != address.characteristic) continue;
      if (characteristic_seen++ == address.characteristic_index) return &chr;
    }
    return nullptr;
  }
  return nullptr;
}

// Returns the position of [service] in [table], appending it when new. The
// same service object comes back from several queries; the handle tells.
int32_t AddService(std::vector<DiscoveredService>& table,
                   const wgatt::GattDeviceService& service, bool primary) {
  const uint16_t handle = service.AttributeHandle();
  for (size_t i = 0; i < table.size(); ++i) {
    if (table[i].handle == handle) return static_cast<int32_t>(i);
  }
  DiscoveredService entry;
  entry.service = service;
  entry.uuid = FormatUuid(service.Uuid());
  entry.handle = handle;
  entry.primary = primary;
  table.push_back(std::move(entry));
  return static_cast<int32_t>(table.size() - 1);
}

IAsyncOperation<wdb::BluetoothLEDevice> OpenDevice(
    uint64_t address, const std::optional<wdb::BluetoothAddressType>& type) {
  return type ? wdb::BluetoothLEDevice::FromBluetoothAddressAsync(address, *type)
              : wdb::BluetoothLEDevice::FromBluetoothAddressAsync(address);
}

std::string PropertyString(const IMapView<winrt::hstring, IInspectable>& properties,
                           const wchar_t* key) {
  if (!properties.HasKey(key)) return {};
  return winrt::to_string(
      winrt::unbox_value_or<winrt::hstring>(properties.Lookup(key), winrt::hstring()));
}

// Association endpoint ids end with the remote address:
// "BluetoothLE#BluetoothLE<local address>-<remote address>".
std::optional<uint64_t> AddressFromEndpointId(const std::string& id) {
  if (id.size() < 17) return std::nullopt;
  return ParseAddress(id.substr(id.size() - 17));
}

}  // namespace

// ---- Reply -------------------------------------------------------------------

Reply::Reply(std::unique_ptr<flutter::MethodResult<EncodableValue>> result)
    : result_(std::move(result)) {}

Reply::~Reply() {
  // Every request is answered while the plugin is alive. A reply left
  // unanswered can only belong to an engine that is shutting down, and
  // destroying it would answer through a dead messenger, so leak it.
  if (result_) {
    [[maybe_unused]] auto* leaked = result_.release();
  }
}

void Reply::Success(const EncodableValue& value) {
  if (!result_) return;
  auto result = std::move(result_);
  result->Success(value);
}

void Reply::Error(const std::string& code, const std::string& message,
                  const EncodableValue& status) {
  if (!result_) return;
  auto result = std::move(result_);
  result->Error(code, message, status);
}

void Reply::Fail(const Failure& failure) {
  Error(failure.code, failure.message, failure.status);
}

void Reply::NotImplemented() {
  if (!result_) return;
  auto result = std::move(result_);
  result->NotImplemented();
}

// ---- lifecycle -----------------------------------------------------------------

// static
void OpenBluePlusPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(
      std::make_unique<OpenBluePlusPlugin>(registrar->messenger()));
}

OpenBluePlusPlugin::OpenBluePlusPlugin(
    flutter::BinaryMessenger* messenger)
    : dispatcher_(UiDispatcher::Create()) {
  methods_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "open_blue_plus/methods",
      &flutter::StandardMethodCodec::GetInstance());
  methods_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        auto reply = std::make_shared<Reply>(std::move(result));
        const auto* map = std::get_if<EncodableMap>(call.arguments());
        EncodableMap args = map != nullptr ? *map : EncodableMap();
        if (!adapter_ready_) {
          deferred_.push_back([this, method = call.method_name(), args, reply]() {
            HandleMethodCall(method, args, reply);
          });
          return;
        }
        HandleMethodCall(call.method_name(), args, reply);
      });

  // A hot restart cancels and re-listens: only the sink changes, so
  // connections and subscriptions survive and the new Dart side adopts them.
  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "open_blue_plus/events",
      &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = std::move(sink);
            return nullptr;
          },
          [this](const EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_.reset();
            return nullptr;
          }));

  InitAdapter();
}

OpenBluePlusPlugin::~OpenBluePlusPlugin() {
  methods_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
  // From here on no queued task or coroutine continuation touches `this`.
  dispatcher_->Close();
  sink_.reset();
  deferred_.clear();
  radio_revoker_.revoke();
  StopScan();
  bond_added_revoker_.revoke();
  bond_updated_revoker_.revoke();
  bond_removed_revoker_.revoke();
  bond_enumerated_revoker_.revoke();
  if (bond_watcher_) {
    try {
      bond_watcher_.Stop();
    } catch (...) {
    }
    bond_watcher_ = nullptr;
  }
  for (auto& entry : bonds_) {
    if (entry.second->operation) {
      try {
        entry.second->operation.Cancel();
      } catch (...) {
      }
    }
  }
  bonds_.clear();
  for (auto& entry : devices_) {
    DeviceSession& device = *entry.second;
    device.status_revoker.revoke();
    device.services_revoker.revoke();
    device.name_revoker.revoke();
    device.mtu_revoker.revoke();
    device.notifications.clear();
    device.gatt.clear();
    for (const auto& service : device.services) CloseQuietly(service);
    CloseQuietly(device.session);
    CloseQuietly(device.device);
  }
  devices_.clear();
}

void OpenBluePlusPlugin::Emit(EncodableMap event) {
  if (sink_) {
    sink_->Success(EncodableValue(std::move(event)));
  }
}

void OpenBluePlusPlugin::Log(int level, const std::string& message) {
  if (level > log_level_ || !sink_) return;
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("log")},
      {EncodableValue("level"), EncodableValue(level)},
      {EncodableValue("message"), EncodableValue(message)},
  });
}

// static
void OpenBluePlusPlugin::PostTask(
    const std::weak_ptr<UiDispatcher>& dispatcher, std::function<void()> task) {
  if (auto ui = dispatcher.lock()) {
    ui->Post(std::move(task));
  }
}

// ---- method calls --------------------------------------------------------------

void OpenBluePlusPlugin::HandleMethodCall(const std::string& method,
                                                 const EncodableMap& args,
                                                 const ReplyPtr& reply) {
  try {
    if (method == "isSupported") {
      reply->Success(EncodableValue(adapter_present_));
    } else if (method == "setOptions") {
      reply->Success(EncodableValue(false));
    } else if (method == "setLogLevel") {
      log_level_ = GetInt(args, "level", 0);
      reply->Success();
    } else if (method == "getAdapterState") {
      reply->Success(EncodableValue(AdapterStateName()));
    } else if (method == "getAdapterName") {
      reply->Success(EncodableValue(AdapterName()));
    } else if (method == "requestPermissions") {
      // Desktop apps need no runtime permission for Bluetooth LE.
      reply->Success(EncodableValue(true));
    } else if (method == "turnOn") {
      SetRadioState(wradio::RadioState::On, reply);
    } else if (method == "turnOff") {
      SetRadioState(wradio::RadioState::Off, reply);
    } else if (method == "startScan") {
      StartScan(args, reply);
    } else if (method == "stopScan") {
      StopScan();
      reply->Success();
    } else if (method == "getConnectedDevices") {
      reply->Success(EncodableValue(ConnectedDevices()));
    } else if (method == "getSystemDevices") {
      // Services are not needed to find connected LE devices on Windows.
      ListSystemDevices(wdb::BluetoothLEDevice::GetDeviceSelectorFromConnectionStatus(
                            wdb::BluetoothConnectionStatus::Connected),
                        reply);
    } else if (method == "getBondedDevices") {
      ListSystemDevices(
          wdb::BluetoothLEDevice::GetDeviceSelectorFromPairingState(true), reply);
    } else if (method == "getBondState" || method == "createBond" ||
               method == "removeBond") {
      const std::string id = DeviceId(args);
      const auto address = ParseAddress(id);
      if (!address) {
        reply->Error("invalid_argument", "Invalid device address: " + id);
      } else if (method == "getBondState") {
        GetBondState(id, *address, reply);
      } else if (method == "removeBond") {
        RemoveBond(id, *address, reply);
      } else if (!adapter_present_ || (radio_ && AdapterStateName() != "on")) {
        reply->Error("adapter_off", "Bluetooth is off");
      } else if (bonds_.count(id) != 0) {
        reply->Error("busy", "Pairing with " + id + " is already in progress");
      } else {
        auto attempt = std::make_shared<BondAttempt>();
        attempt->reply = reply;
        bonds_[id] = attempt;
        const int64_t timeout_ms = GetInt(args, "timeoutMs", 0);
        if (timeout_ms > 0) BondTimeout(id, attempt, timeout_ms);
        CreateBond(id, *address, GetString(args, "pin"), attempt);
      }
    } else if (method == "connect") {
      Connect(args, reply);
    } else if (method == "disconnect") {
      const std::string id = DeviceId(args);
      const auto it = devices_.find(id);
      if (it != devices_.end()) {
        CloseDevice(id,
                    it->second->connected ? "Disconnected"
                                          : "Connection attempt cancelled",
                    EncodableValue());
      }
      reply->Success();
    } else if (method == "getPhySupport") {
      reply->Success(EncodableValue(EncodableMap{
          {EncodableValue("le2M"), EncodableValue(false)},
          {EncodableValue("leCoded"), EncodableValue(false)},
      }));
    } else if (method == "requestConnectionPriority" ||
               method == "setPreferredPhy") {
      // Not available to Windows apps: no-op, even when not connected.
      reply->Success();
    } else if (IsGattMethod(method)) {
      HandleGatt(method, args, reply);
    } else {
      reply->NotImplemented();
    }
  } catch (...) {
    reply->Fail(CurrentFailure("gatt_error"));
  }
}

// ---- adapter -------------------------------------------------------------------

winrt::fire_and_forget OpenBluePlusPlugin::InitAdapter() {
  auto ui = dispatcher_;
  bool present = false;
  wradio::Radio radio{nullptr};
  try {
    const auto adapter = co_await wdb::BluetoothAdapter::GetDefaultAsync();
    if (adapter && adapter.IsLowEnergySupported() &&
        adapter.IsCentralRoleSupported()) {
      present = true;
      radio = co_await adapter.GetRadioAsync();
    }
  } catch (...) {
    // Treated as "no adapter".
  }
  if (!co_await ResumeOnUi{ui}) co_return;

  adapter_present_ = present;
  radio_ = radio;
  if (radio_) {
    try {
      std::weak_ptr<UiDispatcher> weak = dispatcher_;
      radio_revoker_ = radio_.StateChanged(
          winrt::auto_revoke,
          [this, weak](const wradio::Radio&, const IInspectable&) {
            PostTask(weak, [this]() { OnRadioStateChanged(); });
          });
    } catch (...) {
      // State changes won't be reported; getAdapterState still works.
    }
  }
  if (adapter_present_) StartBondWatcher();
  last_adapter_state_ = AdapterStateName();
  adapter_ready_ = true;
  auto deferred = std::move(deferred_);
  deferred_.clear();
  for (auto& call : deferred) {
    call();
  }
}

std::string OpenBluePlusPlugin::AdapterStateName() const {
  if (!adapter_present_) return "unavailable";
  if (!radio_) return "unknown";
  try {
    switch (radio_.State()) {
      case wradio::RadioState::On:
        return "on";
      case wradio::RadioState::Off:
      case wradio::RadioState::Disabled:  // e.g. airplane mode
        return "off";
      default:
        return "unknown";
    }
  } catch (...) {
    return "unknown";
  }
}

std::string OpenBluePlusPlugin::AdapterName() const {
  if (!adapter_present_) return "";
  // Windows advertises the computer name as its Bluetooth name; the radio's
  // own name is a generic "Bluetooth".
  wchar_t buffer[256];
  DWORD size = static_cast<DWORD>(std::size(buffer));
  if (GetComputerNameExW(ComputerNamePhysicalDnsHostname, buffer, &size) &&
      size > 0) {
    return winrt::to_string(std::wstring_view(buffer, size));
  }
  try {
    if (radio_) return winrt::to_string(radio_.Name());
  } catch (...) {
  }
  return "";
}

void OpenBluePlusPlugin::OnRadioStateChanged() {
  const std::string state = AdapterStateName();
  if (state == last_adapter_state_) return;
  last_adapter_state_ = state;
  Log(kLogInfo, "Adapter state: " + state);
  if (state != "on") {
    StopScan();
    std::vector<std::string> ids;
    for (const auto& entry : devices_) ids.push_back(entry.first);
    for (const auto& id : ids) {
      CloseDevice(id, "Bluetooth turned off", EncodableValue());
    }
    const auto bonds = bonds_;
    for (const auto& entry : bonds) {
      FinishBond(entry.first, entry.second,
                 Failure{"not_connected", "Bluetooth turned off", EncodableValue()});
    }
  }
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("adapterState")},
      {EncodableValue("state"), EncodableValue(state)},
  });
}

winrt::fire_and_forget OpenBluePlusPlugin::SetRadioState(
    wradio::RadioState target, ReplyPtr reply) {
  auto ui = dispatcher_;
  if (!adapter_present_ || !radio_) {
    reply->Success(EncodableValue(false));
    co_return;
  }
  const wradio::Radio radio = radio_;
  bool done = false;
  try {
    if (radio.State() == target) {
      done = true;
    } else if ((co_await wradio::Radio::RequestAccessAsync()) ==
               wradio::RadioAccessStatus::Allowed) {
      done = (co_await radio.SetStateAsync(target)) ==
             wradio::RadioAccessStatus::Allowed;
    }
  } catch (...) {
    done = false;
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  reply->Success(EncodableValue(done));
}

// ---- scanning ------------------------------------------------------------------

void OpenBluePlusPlugin::StartScan(const EncodableMap& args,
                                          const ReplyPtr& reply) {
  if (!adapter_present_) {
    reply->Error("unavailable", "No Bluetooth LE adapter");
    return;
  }
  if (radio_ && AdapterStateName() != "on") {
    reply->Error("adapter_off", "Bluetooth is off");
    return;
  }
  ScanFilter filter;
  if (const auto error = filter.Parse(args)) {
    reply->Error("invalid_argument", *error);
    return;
  }
  StopScan();
  scan_filter_ = std::move(filter);
  scan_allow_duplicates_ = GetBool(args, "allowDuplicates", false);
  scan_divisor_ = std::max<int64_t>(1, GetInt(args, "continuousDivisor", 1));
  const uint64_t generation = scan_generation_;

  try {
    watcher_ = wdba::BluetoothLEAdvertisementWatcher();
    // Active scanning also delivers scan responses (usually the name).
    watcher_.ScanningMode(wdba::BluetoothLEScanningMode::Active);
    std::weak_ptr<UiDispatcher> weak = dispatcher_;
    received_revoker_ = watcher_.Received(
        winrt::auto_revoke,
        [this, weak, generation](
            const wdba::BluetoothLEAdvertisementWatcher&,
            const wdba::BluetoothLEAdvertisementReceivedEventArgs& event_args) {
          ScanRecord record;
          try {
            record = ParseAdvertisement(event_args);
          } catch (...) {
            return;
          }
          PostTask(weak, [this, generation, parsed = std::move(record)]() {
            OnAdvertisement(generation, parsed);
          });
        });
    stopped_revoker_ = watcher_.Stopped(
        winrt::auto_revoke,
        [this, weak, generation](
            const wdba::BluetoothLEAdvertisementWatcher&,
            const wdba::BluetoothLEAdvertisementWatcherStoppedEventArgs& event_args) {
          int error = 0;
          try {
            error = static_cast<int>(event_args.Error());
          } catch (...) {
          }
          PostTask(weak, [this, generation, error]() {
            OnScanStopped(generation, error);
          });
        });
    watcher_.Start();
  } catch (...) {
    StopScan();
    reply->Fail(CurrentFailure("gatt_error"));
    return;
  }
  Log(kLogInfo, "Scan started");
  reply->Success();
}

void OpenBluePlusPlugin::StopScan() {
  // Invalidates callbacks already queued for the previous watcher.
  ++scan_generation_;
  received_revoker_.revoke();
  stopped_revoker_.revoke();
  if (watcher_) {
    try {
      watcher_.Stop();
    } catch (...) {
    }
    watcher_ = nullptr;
    Log(kLogInfo, "Scan stopped");
  }
  scan_cache_.clear();
}

void OpenBluePlusPlugin::OnAdvertisement(uint64_t generation,
                                                const ScanRecord& record) {
  if (generation != scan_generation_ || !watcher_) return;
  if (record.address_type) {
    address_types_[record.address] = *record.address_type;
  }
  auto& cached = scan_cache_[record.address];
  // Hot path: an already reported device needs no more merging.
  if (!scan_allow_duplicates_ && cached.reported) return;
  Merge(cached.merged, record);
  if (!scan_allow_duplicates_) {
    // Windows delivers advertising data and scan response (usually holding
    // the name) separately. Report a scannable device once its scan response
    // arrived, or at its next advertisement if it never answers.
    if (!record.scan_response && record.scannable && !cached.held) {
      cached.held = true;
      return;
    }
  }
  // Checked on the merged record before de-duplicating, so a first packet
  // without the name or data the filter needs does not hide the device.
  if (!scan_filter_.Matches(cached.merged)) return;
  if (scan_allow_duplicates_) {
    const bool report = cached.matches % static_cast<uint64_t>(scan_divisor_) == 0;
    ++cached.matches;
    if (!report) return;
  }
  cached.reported = true;
  Emit(ScanResultEvent(cached.merged));
}

void OpenBluePlusPlugin::OnScanStopped(uint64_t generation, int error) {
  // Only reached when the system stopped the watcher (StopScan revokes first).
  if (generation != scan_generation_ || !watcher_) return;
  StopScan();
  Log(kLogError, "Scan stopped by the system, error " + std::to_string(error));
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("scanFailed")},
      {EncodableValue("code"), EncodableValue(error)},
  });
}

// ---- connections -----------------------------------------------------------------

void OpenBluePlusPlugin::Connect(const EncodableMap& args,
                                        const ReplyPtr& reply) {
  const std::string id = DeviceId(args);
  const auto address = ParseAddress(id);
  if (!address) {
    reply->Error("invalid_argument", "Invalid device address: " + id);
    return;
  }
  if (!adapter_present_ || (radio_ && AdapterStateName() != "on")) {
    reply->Error("adapter_off", "Bluetooth is off");
    return;
  }
  const auto existing = devices_.find(id);
  if (existing != devices_.end()) {
    DeviceSession& session = *existing->second;
    if (session.connected) {
      reply->Success();
    } else if (!session.connect_reply) {
      // autoConnect is reconnecting after a link loss: this call waits for it.
      session.auto_connect = GetBool(args, "autoConnect", false);
      session.connect_reply = reply;
    } else {
      reply->Error("busy", "A connection attempt is already in progress");
    }
    return;
  }
  auto device = std::make_unique<DeviceSession>();
  device->id = id;
  device->generation = ++next_generation_;
  device->auto_connect = GetBool(args, "autoConnect", false);
  device->connect_reply = reply;
  const uint64_t generation = device->generation;
  devices_[id] = std::move(device);
  Log(kLogInfo, id + ": connecting");
  ConnectAsync(id, generation, *address, KnownAddressType(*address));
}

winrt::fire_and_forget OpenBluePlusPlugin::ConnectAsync(
    std::string id, uint64_t generation, uint64_t address,
    std::optional<wdb::BluetoothAddressType> address_type) {
  auto ui = dispatcher_;
  std::optional<Failure> failure;
  wdb::BluetoothLEDevice device{nullptr};
  wgatt::GattSession session{nullptr};
  try {
    device = co_await OpenDevice(address, address_type);
    if (device) {
      session = co_await wgatt::GattSession::FromDeviceIdAsync(
          device.BluetoothDeviceId());
      if (!session) {
        failure = Failure{"connect_failed", "Could not open a GATT session",
                          EncodableValue()};
      }
    } else {
      failure = Failure{"not_found", "Device " + id + " not found",
                        EncodableValue()};
    }
  } catch (...) {
    failure = CurrentFailure("connect_failed");
  }
  if (!co_await ResumeOnUi{ui}) co_return;

  DeviceSession* entry = FindDevice(id, generation);
  if (entry == nullptr) {
    // Cancelled by disconnect() meanwhile.
    CloseQuietly(session);
    CloseQuietly(device);
    co_return;
  }
  if (!failure) {
    try {
      entry->device = device;
      entry->session = session;
      std::weak_ptr<UiDispatcher> weak = dispatcher_;
      entry->status_revoker = device.ConnectionStatusChanged(
          winrt::auto_revoke,
          [this, weak, id, generation](const wdb::BluetoothLEDevice& sender,
                                       const IInspectable&) {
            bool is_connected = false;
            try {
              is_connected = sender.ConnectionStatus() ==
                             wdb::BluetoothConnectionStatus::Connected;
            } catch (...) {
              return;
            }
            PostTask(weak, [this, id, generation, is_connected]() {
              OnConnectionStatus(id, generation, is_connected);
            });
          });
      entry->services_revoker = device.GattServicesChanged(
          winrt::auto_revoke,
          [this, weak, id, generation](const wdb::BluetoothLEDevice&,
                                       const IInspectable&) {
            PostTask(weak, [this, id, generation]() {
              OnServicesChanged(id, generation);
            });
          });
      entry->name_revoker = device.NameChanged(
          winrt::auto_revoke,
          [this, weak, id, generation](const wdb::BluetoothLEDevice& sender,
                                       const IInspectable&) {
            std::string name;
            try {
              name = winrt::to_string(sender.Name());
            } catch (...) {
              return;
            }
            PostTask(weak, [this, id, generation, name]() {
              OnNameChanged(id, generation, name);
            });
          });
      entry->mtu_revoker = session.MaxPduSizeChanged(
          winrt::auto_revoke,
          [this, weak, id, generation](const wgatt::GattSession& sender,
                                       const IInspectable&) {
            int mtu = 0;
            try {
              mtu = sender.MaxPduSize();
            } catch (...) {
              return;
            }
            PostTask(weak, [this, id, generation, mtu]() {
              OnMtuChanged(id, generation, mtu);
            });
          });
      // Windows then (re)connects on its own and keeps the link up.
      session.MaintainConnection(true);
    } catch (...) {
      failure = CurrentFailure("connect_failed");
    }
  }
  if (failure) {
    CloseQuietly(session);
    CloseQuietly(device);
    entry->device = nullptr;
    entry->session = nullptr;
    CloseDevice(id, failure->message, failure->status,
                failure->code == "not_found" ? "not_found" : "connect_failed");
    co_return;
  }

  // Opening the GATT services makes Windows connect right away; an
  // unreachable device fails here after the system's own timeout. Uncached
  // also refreshes the system's service list for the discovery that follows.
  wgatt::GattDeviceServicesResult services{nullptr};
  try {
    services = co_await device.GetGattServicesAsync(wdb::BluetoothCacheMode::Uncached);
    if (services.Status() != wgatt::GattCommunicationStatus::Success) {
      failure = GattStatusFailure("connect", services.Status(),
                                  services.ProtocolError());
    }
  } catch (...) {
    failure = CurrentFailure("connect_failed");
  }
  if (!co_await ResumeOnUi{ui}) co_return;

  entry = FindDevice(id, generation);
  if (entry == nullptr) {
    if (services && !failure) {
      try {
        for (const auto& service : services.Services()) CloseQuietly(service);
      } catch (...) {
        // An exception must not leave a fire_and_forget (std::terminate).
      }
    }
    co_return;
  }
  try {
    if (!failure) {
      for (const auto& service : services.Services()) {
        entry->services.push_back(service);
      }
    }
    if (entry->connected) co_return;
    if (failure) {
      // With autoConnect Windows keeps trying (MaintainConnection) and the
      // ConnectionStatusChanged handler completes the attempt.
      if (entry->auto_connect) co_return;
      CloseDevice(id, failure->message, failure->status);
      co_return;
    }
    if (device.ConnectionStatus() == wdb::BluetoothConnectionStatus::Connected) {
      MarkConnected(*entry);
    }
    // Otherwise the ConnectionStatusChanged handler completes the attempt.
  } catch (...) {
    const Failure error = CurrentFailure("connect_failed");
    CloseDevice(id, error.message, error.status);
  }
}

void OpenBluePlusPlugin::OnConnectionStatus(const std::string& id,
                                                   uint64_t generation,
                                                   bool connected) {
  DeviceSession* device = FindDevice(id, generation);
  if (device == nullptr) return;
  if (connected) {
    if (!device->connected) MarkConnected(*device);
  } else if (device->connected) {
    if (device->auto_connect) {
      LinkLost(*device);
    } else {
      CloseDevice(id, "Device disconnected", EncodableValue());
    }
  }
  // Disconnected while still connecting: Windows keeps trying.
}

void OpenBluePlusPlugin::LinkLost(DeviceSession& device) {
  // The session (MaintainConnection) stays open, so Windows reconnects on its
  // own and ConnectionStatusChanged reports it; the attributes must be
  // discovered again, as after any disconnection.
  device.connected = false;
  device.notifications.clear();
  device.gatt.clear();
  const auto pending = std::move(device.pending);
  device.pending.clear();
  for (const auto& weak : pending) {
    if (auto reply = weak.lock()) reply->Error("not_connected", "Device disconnected");
  }
  Log(kLogInfo, device.id + ": disconnected, reconnecting (autoConnect)");
  Emit(ConnectionStateEvent(device.id, false));
}

void OpenBluePlusPlugin::OnMtuChanged(const std::string& id,
                                             uint64_t generation, int mtu) {
  DeviceSession* device = FindDevice(id, generation);
  if (device == nullptr || !device->connected || device->mtu == mtu) return;
  device->mtu = mtu;
  Emit(MtuEvent(id, mtu));
}

void OpenBluePlusPlugin::OnServicesChanged(const std::string& id,
                                                  uint64_t generation) {
  DeviceSession* device = FindDevice(id, generation);
  if (device == nullptr || !device->connected) return;
  // Windows also raises it when it (re)reads the database for our own
  // requests (connect, uncached discovery); nothing is invalid then.
  if (device->discovering || device->gatt.empty()) return;
  // Subscriptions stay: their objects keep working if the attribute survived,
  // and setNotify replaces them by handle after the next discovery.
  device->gatt.clear();
  Log(kLogInfo, id + ": GATT database changed");
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("servicesReset")},
      {EncodableValue("id"), EncodableValue(id)},
  });
}

void OpenBluePlusPlugin::OnNameChanged(const std::string& id,
                                              uint64_t generation,
                                              const std::string& name) {
  DeviceSession* device = FindDevice(id, generation);
  if (device == nullptr || !device->connected || device->name == name) return;
  device->name = name;
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("name")},
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("name"), EncodableValue(name)},
  });
}

void OpenBluePlusPlugin::MarkConnected(DeviceSession& device) {
  device.connected = true;
  try {
    device.mtu = device.session.MaxPduSize();
  } catch (...) {
  }
  try {
    device.name = winrt::to_string(device.device.Name());
  } catch (...) {
  }
  Log(kLogInfo, device.id + ": connected");
  Emit(ConnectionStateEvent(device.id, true));
  Emit(MtuEvent(device.id, device.mtu));
  if (device.connect_reply) {
    auto reply = std::move(device.connect_reply);
    device.connect_reply = nullptr;
    reply->Success();
  }
}

void OpenBluePlusPlugin::CloseDevice(const std::string& id,
                                            const std::string& reason,
                                            const EncodableValue& status,
                                            const char* connect_code) {
  const auto it = devices_.find(id);
  if (it == devices_.end()) return;
  std::unique_ptr<DeviceSession> device = std::move(it->second);
  devices_.erase(it);

  device->status_revoker.revoke();
  device->services_revoker.revoke();
  device->name_revoker.revoke();
  device->mtu_revoker.revoke();
  device->notifications.clear();
  for (const auto& weak : device->pending) {
    if (auto reply = weak.lock()) reply->Error("not_connected", reason, status);
  }
  if (device->connect_reply) {
    device->connect_reply->Error(connect_code, reason, status);
  }
  // Windows only drops the link once every GATT object is released.
  device->gatt.clear();
  for (const auto& service : device->services) CloseQuietly(service);
  CloseQuietly(device->session);
  CloseQuietly(device->device);
  Log(device->connected ? kLogInfo : kLogError, id + ": " + reason);
  Emit(ConnectionStateEvent(id, false));
}

DeviceSession* OpenBluePlusPlugin::FindDevice(const std::string& id,
                                                     uint64_t generation) {
  const auto it = devices_.find(id);
  if (it == devices_.end() || it->second->generation != generation) return nullptr;
  return it->second.get();
}

EncodableList OpenBluePlusPlugin::ConnectedDevices() const {
  EncodableList list;
  for (const auto& entry : devices_) {
    const DeviceSession& device = *entry.second;
    if (device.connected) list.push_back(DeviceEntry(device.id, device.name));
  }
  return list;
}

std::optional<wdb::BluetoothAddressType> OpenBluePlusPlugin::KnownAddressType(
    uint64_t address) const {
  const auto it = address_types_.find(address);
  if (it == address_types_.end()) return std::nullopt;
  return it->second;
}

// ---- system devices and bonding ----------------------------------------------------

winrt::fire_and_forget OpenBluePlusPlugin::ListSystemDevices(
    winrt::hstring selector, ReplyPtr reply) {
  auto ui = dispatcher_;
  struct Found {
    uint64_t address;
    wdb::BluetoothAddressType type;
    std::string name;
  };
  std::vector<Found> found;
  std::optional<Failure> failure;
  try {
    const auto infos = co_await wenum::DeviceInformation::FindAllAsync(selector);
    for (const auto& info : infos) {
      try {
        const auto device = co_await wdb::BluetoothLEDevice::FromIdAsync(info.Id());
        if (!device) continue;
        Found entry{device.BluetoothAddress(), device.BluetoothAddressType(),
                    winrt::to_string(device.Name())};
        if (entry.name.empty()) entry.name = winrt::to_string(info.Name());
        CloseQuietly(device);
        found.push_back(std::move(entry));
      } catch (...) {
        // Removed meanwhile; skip it.
      }
    }
  } catch (...) {
    failure = CurrentFailure("gatt_error");
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  if (failure) {
    reply->Fail(*failure);
    co_return;
  }
  EncodableList list;
  std::vector<uint64_t> listed;
  for (const auto& entry : found) {
    if (std::find(listed.begin(), listed.end(), entry.address) != listed.end()) {
      continue;
    }
    listed.push_back(entry.address);
    // Lets connect() open random-address devices that were never scanned.
    address_types_[entry.address] = entry.type;
    list.push_back(DeviceEntry(FormatAddress(entry.address), entry.name));
  }
  reply->Success(EncodableValue(std::move(list)));
}

winrt::fire_and_forget OpenBluePlusPlugin::GetBondState(std::string id,
                                                               uint64_t address,
                                                               ReplyPtr reply) {
  auto ui = dispatcher_;
  const auto type = KnownAddressType(address);
  std::string state = "unknown";
  try {
    const auto device = co_await OpenDevice(address, type);
    if (device) {
      state = device.DeviceInformation().Pairing().IsPaired() ? "bonded" : "none";
      CloseQuietly(device);
    } else {
      state = "none";  // unknown to the system, so not paired
    }
  } catch (...) {
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  if (bonds_.count(id) != 0) state = "bonding";
  reply->Success(EncodableValue(state));
}

winrt::fire_and_forget OpenBluePlusPlugin::CreateBond(
    std::string id, uint64_t address, std::string pin,
    std::shared_ptr<BondAttempt> attempt) {
  auto ui = dispatcher_;
  const auto type = KnownAddressType(address);
  std::optional<Failure> failure;
  bool paired = false;
  wdb::BluetoothLEDevice device{nullptr};
  wenum::DeviceInformationCustomPairing custom{nullptr};
  try {
    device = co_await OpenDevice(address, type);
    if (!device) {
      failure = Failure{"not_found", "Device " + id + " not found", EncodableValue()};
    } else {
      const auto pairing = device.DeviceInformation().Pairing();
      paired = pairing.IsPaired();
      if (!paired) custom = pairing.Custom();
    }
  } catch (...) {
    failure = CurrentFailure("bond_failed");
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  if (attempt->reply->done() || failure || paired) {
    CloseQuietly(device);
    FinishBond(id, attempt, failure);
    co_return;
  }

  EmitBondState(id, "bonding");
  Log(kLogInfo, id + ": pairing");
  auto kinds = wenum::DevicePairingKinds::ConfirmOnly |
               wenum::DevicePairingKinds::DisplayPin |
               wenum::DevicePairingKinds::ConfirmPinMatch;
  if (!pin.empty()) kinds = kinds | wenum::DevicePairingKinds::ProvidePin;
  std::optional<wenum::DevicePairingResultStatus> status;
  try {
    // Raised on a thread-pool thread; answered synchronously, so no deferral.
    const auto revoker = custom.PairingRequested(
        winrt::auto_revoke,
        [pin_text = winrt::to_hstring(pin)](
            const wenum::DeviceInformationCustomPairing&,
            const wenum::DevicePairingRequestedEventArgs& args) {
          try {
            switch (args.PairingKind()) {
              case wenum::DevicePairingKinds::ConfirmOnly:
              case wenum::DevicePairingKinds::DisplayPin:
              case wenum::DevicePairingKinds::ConfirmPinMatch:
                args.Accept();
                break;
              case wenum::DevicePairingKinds::ProvidePin:
                if (!pin_text.empty()) args.Accept(pin_text);
                break;
              default:
                break;  // left unanswered: the pairing is rejected
            }
          } catch (...) {
          }
        });
    // Just Works peripherals cannot authenticate: retry with encryption only.
    const wenum::DevicePairingProtectionLevel levels[] = {
        wenum::DevicePairingProtectionLevel::EncryptionAndAuthentication,
        wenum::DevicePairingProtectionLevel::Encryption};
    for (const auto level : levels) {
      attempt->operation = custom.PairAsync(kinds, level);
      const auto result = co_await attempt->operation;
      if (!co_await ResumeOnUi{ui}) co_return;
      status = result.Status();
      if (attempt->reply->done() ||
          *status != wenum::DevicePairingResultStatus::ProtectionLevelCouldNotBeMet) {
        break;
      }
    }
  } catch (...) {
    // Also reached when a timeout cancelled the operation.
    failure = CurrentFailure("bond_failed");
  }
  CloseQuietly(device);
  if (!co_await ResumeOnUi{ui}) co_return;
  if (attempt->reply->done()) co_return;
  if (!failure && status != wenum::DevicePairingResultStatus::Paired &&
      status != wenum::DevicePairingResultStatus::AlreadyPaired) {
    const int32_t code = status ? static_cast<int32_t>(*status) : -1;
    failure = Failure{"bond_failed",
                      "Pairing failed: status " + std::to_string(code),
                      EncodableValue(code)};
  }
  FinishBond(id, attempt, failure);
}

winrt::fire_and_forget OpenBluePlusPlugin::BondTimeout(
    std::string id, std::weak_ptr<BondAttempt> attempt, int64_t timeout_ms) {
  auto ui = dispatcher_;
  co_await winrt::resume_after(std::chrono::milliseconds(timeout_ms));
  if (!co_await ResumeOnUi{ui}) co_return;
  const auto current = attempt.lock();
  if (!current || current->reply->done()) co_return;
  FinishBond(id, current,
             Failure{"timeout", "Pairing did not complete in time", EncodableValue()});
}

void OpenBluePlusPlugin::FinishBond(const std::string& id,
                                           const std::shared_ptr<BondAttempt>& attempt,
                                           const std::optional<Failure>& failure) {
  const auto it = bonds_.find(id);
  if (it != bonds_.end() && it->second == attempt) bonds_.erase(it);
  if (attempt->reply->done()) return;
  if (failure) {
    if (attempt->operation) {
      try {
        attempt->operation.Cancel();
      } catch (...) {
      }
    }
    Log(kLogError, id + ": " + failure->message);
    const auto last = bond_states_.find(id);
    if (last != bond_states_.end() && last->second == "bonding") {
      EmitBondState(id, "none");
    }
    attempt->reply->Fail(*failure);
  } else {
    Log(kLogInfo, id + ": bonded");
    EmitBondState(id, "bonded");
    attempt->reply->Success();
  }
}

winrt::fire_and_forget OpenBluePlusPlugin::RemoveBond(std::string id,
                                                             uint64_t address,
                                                             ReplyPtr reply) {
  auto ui = dispatcher_;
  const auto type = KnownAddressType(address);
  std::optional<Failure> failure;
  bool unpaired = false;
  try {
    const auto device = co_await OpenDevice(address, type);
    if (device) {
      const auto pairing = device.DeviceInformation().Pairing();
      if (pairing.IsPaired()) {
        const auto result = co_await pairing.UnpairAsync();
        const auto status = result.Status();
        if (status == wenum::DeviceUnpairingResultStatus::Unpaired ||
            status == wenum::DeviceUnpairingResultStatus::AlreadyUnpaired) {
          unpaired = true;
        } else {
          const int32_t code = static_cast<int32_t>(status);
          failure = Failure{"bond_failed",
                            "Unpairing failed: status " + std::to_string(code),
                            EncodableValue(code)};
        }
      }
      CloseQuietly(device);
    }
  } catch (...) {
    failure = CurrentFailure("bond_failed");
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  if (failure) {
    Log(kLogError, id + ": " + failure->message);
    reply->Fail(*failure);
    co_return;
  }
  if (unpaired) EmitBondState(id, "none");
  reply->Success();
}

void OpenBluePlusPlugin::StartBondWatcher() {
  // The paired-devices selector issues no inquiry: this only follows the
  // system's device store, so it costs no radio time.
  try {
    std::vector<winrt::hstring> properties{kAepDeviceAddress, kAepIsPaired};
    bond_watcher_ = wenum::DeviceInformation::CreateWatcher(
        wdb::BluetoothLEDevice::GetDeviceSelectorFromPairingState(true),
        std::move(properties), wenum::DeviceInformationKind::AssociationEndpoint);
    std::weak_ptr<UiDispatcher> weak = dispatcher_;
    bond_added_revoker_ = bond_watcher_.Added(
        winrt::auto_revoke,
        [this, weak](const wenum::DeviceWatcher&, const wenum::DeviceInformation& info) {
          std::string watcher_id;
          std::string address;
          bool paired = true;
          try {
            watcher_id = winrt::to_string(info.Id());
            address = PropertyString(info.Properties(), kAepDeviceAddress);
            paired = info.Pairing().IsPaired();
          } catch (...) {
            return;
          }
          PostTask(weak, [this, watcher_id, address, paired]() {
            OnBondWatcherDevice(watcher_id, address, paired);
          });
        });
    bond_updated_revoker_ = bond_watcher_.Updated(
        winrt::auto_revoke,
        [this, weak](const wenum::DeviceWatcher&,
                     const wenum::DeviceInformationUpdate& update) {
          std::string watcher_id;
          bool paired = false;
          try {
            const auto values = update.Properties();
            if (!values.HasKey(kAepIsPaired)) return;
            paired = winrt::unbox_value_or<bool>(values.Lookup(kAepIsPaired), false);
            watcher_id = winrt::to_string(update.Id());
          } catch (...) {
            return;
          }
          PostTask(weak, [this, watcher_id, paired]() {
            OnBondWatcherDevice(watcher_id, std::string(), paired);
          });
        });
    bond_removed_revoker_ = bond_watcher_.Removed(
        winrt::auto_revoke,
        [this, weak](const wenum::DeviceWatcher&,
                     const wenum::DeviceInformationUpdate& update) {
          std::string watcher_id;
          try {
            watcher_id = winrt::to_string(update.Id());
          } catch (...) {
            return;
          }
          PostTask(weak, [this, watcher_id]() { OnBondWatcherRemoved(watcher_id); });
        });
    bond_enumerated_revoker_ = bond_watcher_.EnumerationCompleted(
        winrt::auto_revoke,
        [this, weak](const wenum::DeviceWatcher&, const IInspectable&) {
          PostTask(weak, [this]() { bond_watcher_enumerated_ = true; });
        });
    bond_watcher_.Start();
  } catch (...) {
    // Pairing changes made outside the plugin won't be reported.
    bond_added_revoker_.revoke();
    bond_updated_revoker_.revoke();
    bond_removed_revoker_.revoke();
    bond_enumerated_revoker_.revoke();
    bond_watcher_ = nullptr;
  }
}

void OpenBluePlusPlugin::OnBondWatcherDevice(const std::string& watcher_id,
                                                    const std::string& address,
                                                    bool paired) {
  std::string id;
  const auto known = bond_watcher_ids_.find(watcher_id);
  if (known != bond_watcher_ids_.end()) {
    id = known->second;
  } else {
    auto parsed = ParseAddress(address);
    if (!parsed) parsed = AddressFromEndpointId(watcher_id);
    if (!parsed) return;
    id = FormatAddress(*parsed);
    bond_watcher_ids_[watcher_id] = id;
  }
  const std::string state = paired ? "bonded" : "none";
  if (!bond_watcher_enumerated_) {
    // Initial enumeration: the current state, not a change.
    bond_states_[id] = state;
    return;
  }
  // createBond reports its own outcome.
  if (bonds_.count(id) != 0) return;
  EmitBondState(id, state);
}

void OpenBluePlusPlugin::OnBondWatcherRemoved(const std::string& watcher_id) {
  const auto known = bond_watcher_ids_.find(watcher_id);
  if (known == bond_watcher_ids_.end()) return;
  const std::string id = known->second;
  bond_watcher_ids_.erase(known);
  if (bond_watcher_enumerated_ && bonds_.count(id) == 0) {
    EmitBondState(id, "none");
  }
}

void OpenBluePlusPlugin::EmitBondState(const std::string& id,
                                              const std::string& state) {
  auto& last = bond_states_[id];
  if (last == state) return;
  last = state;
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("bondState")},
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("state"), EncodableValue(state)},
  });
}

// ---- GATT ------------------------------------------------------------------------

template <typename Start, typename Finish>
winrt::fire_and_forget OpenBluePlusPlugin::RunGatt(ReplyPtr reply,
                                                          Start start,
                                                          Finish finish) {
  using Result = decltype(std::declval<Start&>()().GetResults());
  auto ui = dispatcher_;
  std::optional<Failure> failure;
  Result result{nullptr};
  try {
    result = co_await start();
  } catch (...) {
    failure = CurrentFailure("gatt_error");
  }
  if (!co_await ResumeOnUi{ui}) co_return;
  if (reply->done()) co_return;
  if (!failure) {
    try {
      finish(result, *reply);
    } catch (...) {
      failure = CurrentFailure("gatt_error");
    }
  }
  if (failure) reply->Fail(*failure);
}

void OpenBluePlusPlugin::HandleGatt(const std::string& method,
                                           const EncodableMap& args,
                                           const ReplyPtr& reply) {
  const std::string id = DeviceId(args);
  const auto it = devices_.find(id);
  if (it == devices_.end() || !it->second->connected) {
    reply->Error("not_connected", "Device " + id + " is not connected");
    return;
  }
  DeviceSession& device = *it->second;

  if (method == "discoverServices") {
    // Cached by default: connect() already read the service list uncached,
    // and uncached queries make every discovery a full round of ATT requests.
    const auto mode = device.uncached_discovery ? wdb::BluetoothCacheMode::Uncached
                                                : wdb::BluetoothCacheMode::Cached;
    device.uncached_discovery = false;
    device.discovering = true;
    Track(device, reply);
    DiscoverServices(device.id, device.generation, device.device, mode, reply);
    return;
  }
  if (method == "clearGattCache") {
    device.uncached_discovery = true;
    reply->Success();
    return;
  }
  if (method == "requestMtu") {
    // Windows negotiates the MTU itself; report the current one.
    const int mtu = device.session.MaxPduSize();
    if (mtu != device.mtu) {
      // Updating the cache silently would also suppress the event for the
      // MaxPduSizeChanged notification that is still on its way.
      device.mtu = mtu;
      Emit(MtuEvent(device.id, mtu));
    }
    reply->Success(EncodableValue(mtu));
    return;
  }
  if (method == "readRssi") {
    reply->Error("not_supported",
                 "Windows does not expose the RSSI of a connected device");
    return;
  }

  const auto address = CharacteristicArgs(args);
  if (!address) {
    reply->Error("invalid_argument", "Invalid service or characteristic UUID");
    return;
  }
  const DiscoveredCharacteristic* found = FindCharacteristic(device, *address);
  if (found == nullptr) {
    reply->Error("not_found", "No characteristic " + address->characteristic +
                                  " in service " + address->service +
                                  " (did you call discoverServices?)");
    return;
  }
  const wgatt::GattCharacteristic chr = found->characteristic;

  if (method == "read") {
    Track(device, reply);
    RunGatt(
        reply,
        [chr]() { return chr.ReadValueAsync(wdb::BluetoothCacheMode::Uncached); },
        [this, id, target = *address](const wgatt::GattReadResult& result,
                                      Reply& out) {
          if (result.Status() != wgatt::GattCommunicationStatus::Success) {
            out.Fail(GattStatusFailure("read", result.Status(),
                                       result.ProtocolError()));
            return;
          }
          const auto value = ToBytes(result.Value());
          EmitValue(id, target, value);
          out.Success(EncodableValue(value));
        });
  } else if (method == "write") {
    const auto option = GetBool(args, "withoutResponse", false)
                            ? wgatt::GattWriteOption::WriteWithoutResponse
                            : wgatt::GattWriteOption::WriteWithResponse;
    const auto buffer = ToBuffer(GetBytes(args, "value"));
    Track(device, reply);
    RunGatt(
        reply,
        [chr, buffer, option]() { return chr.WriteValueWithResultAsync(buffer, option); },
        FinishWrite("write"));
  } else if (method == "setNotify") {
    SetNotify(device, *address, chr, GetBool(args, "enable", true),
              GetBool(args, "forceIndications", false), reply);
  } else {
    // readDescriptor / writeDescriptor
    const auto descriptor = NormalizeUuid(GetString(args, "descriptor"));
    if (!descriptor) {
      reply->Error("invalid_argument", "Invalid descriptor UUID");
      return;
    }
    if (method == "writeDescriptor" && *descriptor == kCccdUuid) {
      // Same as setNotify, so the ValueChanged handler is registered too.
      const auto bytes = GetBytes(args, "value");
      const bool enable = std::any_of(bytes.begin(), bytes.end(),
                                      [](uint8_t octet) { return octet != 0; });
      // 02 00 asks for indications explicitly.
      const bool indicate =
          !bytes.empty() && bytes[0] == 0x02 &&
          std::all_of(bytes.begin() + 1, bytes.end(),
                      [](uint8_t octet) { return octet == 0; });
      SetNotify(device, *address, chr, enable, indicate, reply);
      return;
    }
    wgatt::GattDescriptor dsc{nullptr};
    for (const auto& entry : found->descriptors) {
      if (entry.first == *descriptor) {
        dsc = entry.second;
        break;
      }
    }
    if (!dsc) {
      reply->Error("not_found", "No descriptor " + *descriptor +
                                    " (did you call discoverServices?)");
      return;
    }
    Track(device, reply);
    if (method == "readDescriptor") {
      RunGatt(
          reply,
          [dsc]() { return dsc.ReadValueAsync(wdb::BluetoothCacheMode::Uncached); },
          [](const wgatt::GattReadResult& result, Reply& out) {
            if (result.Status() == wgatt::GattCommunicationStatus::Success) {
              out.Success(EncodableValue(ToBytes(result.Value())));
            } else {
              out.Fail(GattStatusFailure("readDescriptor", result.Status(),
                                         result.ProtocolError()));
            }
          });
    } else {
      const auto buffer = ToBuffer(GetBytes(args, "value"));
      RunGatt(
          reply, [dsc, buffer]() { return dsc.WriteValueWithResultAsync(buffer); },
          FinishWrite("writeDescriptor"));
    }
  }
}

void OpenBluePlusPlugin::SetNotify(DeviceSession& device,
                                          const CharacteristicAddress& address,
                                          const wgatt::GattCharacteristic& chr,
                                          bool enable, bool force_indications,
                                          const ReplyPtr& reply) {
  const auto properties = static_cast<uint32_t>(chr.CharacteristicProperties());
  const uint16_t handle = chr.AttributeHandle();
  auto value = wgatt::GattClientCharacteristicConfigurationDescriptorValue::None;
  if (enable) {
    if (force_indications) {
      if ((properties & kPropertyIndicate) == 0) {
        reply->Error("not_supported", "Characteristic does not support indications");
        return;
      }
      value = wgatt::GattClientCharacteristicConfigurationDescriptorValue::Indicate;
    } else if ((properties & kPropertyNotify) != 0) {
      value = wgatt::GattClientCharacteristicConfigurationDescriptorValue::Notify;
    } else if ((properties & kPropertyIndicate) != 0) {
      value = wgatt::GattClientCharacteristicConfigurationDescriptorValue::Indicate;
    } else {
      reply->Error("not_supported",
                   "Characteristic supports neither notify nor indicate");
      return;
    }
  } else if ((properties & (kPropertyNotify | kPropertyIndicate)) == 0) {
    // Nothing to disable (and possibly no CCCD to write): no-op.
    device.notifications.erase(handle);
    reply->Success();
    return;
  }

  // Revoked first so a notification is never reported twice.
  device.notifications.erase(handle);
  if (enable) {
    // Subscribe before writing the CCCD so no early notification is lost.
    std::weak_ptr<UiDispatcher> weak = dispatcher_;
    auto revoker = chr.ValueChanged(
        winrt::auto_revoke,
        [this, weak, id = device.id, generation = device.generation, handle](
            const wgatt::GattCharacteristic&,
            const wgatt::GattValueChangedEventArgs& event_args) {
          std::vector<uint8_t> bytes;
          try {
            bytes = ToBytes(event_args.CharacteristicValue());
          } catch (...) {
            return;
          }
          PostTask(weak, [this, id, generation, handle, payload = std::move(bytes)]() {
            const DeviceSession* target = FindDevice(id, generation);
            if (target == nullptr || !target->connected) return;
            const auto subscription = target->notifications.find(handle);
            if (subscription != target->notifications.end()) {
              EmitValue(id, subscription->second.address, payload);
            }
          });
        });
    device.notifications[handle] = Subscription{chr, address, std::move(revoker)};
  }

  Track(device, reply);
  RunGatt(
      reply,
      [chr, value]() {
        return chr.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(value);
      },
      [this, id = device.id, generation = device.generation, handle, enable](
          const wgatt::GattWriteResult& result, Reply& out) {
        if (result.Status() == wgatt::GattCommunicationStatus::Success) {
          out.Success();
          return;
        }
        if (enable) {
          if (DeviceSession* target = FindDevice(id, generation)) {
            target->notifications.erase(handle);
          }
        }
        out.Fail(GattStatusFailure("setNotify", result.Status(),
                                   result.ProtocolError()));
      });
}

winrt::fire_and_forget OpenBluePlusPlugin::DiscoverServices(
    std::string id, uint64_t generation, wdb::BluetoothLEDevice device,
    wdb::BluetoothCacheMode mode, ReplyPtr reply) {
  auto ui = dispatcher_;
  std::optional<Failure> failure;
  std::vector<wgatt::GattDeviceService> opened;
  std::vector<DiscoveredService> table;
  try {
    const auto service_result = co_await device.GetGattServicesAsync(mode);
    if (service_result.Status() != wgatt::GattCommunicationStatus::Success) {
      failure = GattStatusFailure("discoverServices", service_result.Status(),
                                  service_result.ProtocolError());
    } else {
      // GetGattServicesAsync only returns primary services.
      for (const auto& service : service_result.Services()) {
        opened.push_back(service);
        AddService(table, service, true);
      }
      // Secondary services are only reachable as included services. The
      // loop also visits the services it appends (nested includes).
      for (size_t i = 0; i < table.size(); ++i) {
        const wgatt::GattDeviceService parent = table[i].service;
        wgatt::GattDeviceServicesResult included{nullptr};
        try {
          included = co_await parent.GetIncludedServicesAsync(mode);
        } catch (...) {
          continue;
        }
        if (included.Status() != wgatt::GattCommunicationStatus::Success) continue;
        for (const auto& child : included.Services()) {
          opened.push_back(child);
          const int32_t position = AddService(table, child, false);
          auto& positions = table[i].included;
          if (std::find(positions.begin(), positions.end(), position) ==
              positions.end()) {
            positions.push_back(position);
          }
        }
      }
      for (auto& entry : table) {
        const auto char_result = co_await entry.service.GetCharacteristicsAsync(mode);
        // Services Windows reserves for itself (e.g. HID) come back
        // AccessDenied; they are reported without characteristics.
        if (char_result.Status() != wgatt::GattCommunicationStatus::Success) continue;
        for (const auto& chr : char_result.Characteristics()) {
          DiscoveredCharacteristic discovered;
          discovered.characteristic = chr;
          discovered.uuid = FormatUuid(chr.Uuid());
          discovered.properties =
              static_cast<uint32_t>(chr.CharacteristicProperties()) & 0xFF;
          const auto desc_result = co_await chr.GetDescriptorsAsync(mode);
          if (desc_result.Status() == wgatt::GattCommunicationStatus::Success) {
            for (const auto& dsc : desc_result.Descriptors()) {
              discovered.descriptors.emplace_back(FormatUuid(dsc.Uuid()), dsc);
            }
          }
          entry.characteristics.push_back(std::move(discovered));
        }
      }
    }
  } catch (...) {
    failure = CurrentFailure("gatt_error");
  }
  if (!co_await ResumeOnUi{ui}) co_return;

  DeviceSession* entry = FindDevice(id, generation);
  if (entry != nullptr) {
    entry->discovering = false;
    if (failure && mode == wdb::BluetoothCacheMode::Uncached) {
      entry->uncached_discovery = true;  // still owed to clearGattCache
    }
  }
  if (entry == nullptr || reply->done() || failure) {
    for (const auto& service : opened) CloseQuietly(service);
    if (failure) {
      Log(kLogError, id + ": " + failure->message);
      reply->Fail(*failure);
    }
    co_return;
  }

  EncodableList result;
  for (const auto& service : table) {
    EncodableList characteristics;
    for (const auto& chr : service.characteristics) {
      EncodableList descriptors;
      for (const auto& dsc : chr.descriptors) {
        descriptors.push_back(EncodableValue(dsc.first));
      }
      characteristics.push_back(EncodableValue(EncodableMap{
          {EncodableValue("uuid"), EncodableValue(chr.uuid)},
          {EncodableValue("properties"),
           EncodableValue(static_cast<int32_t>(chr.properties))},
          {EncodableValue("descriptors"), EncodableValue(std::move(descriptors))},
      }));
    }
    EncodableList included;
    for (const int32_t position : service.included) {
      included.push_back(EncodableValue(position));
    }
    result.push_back(EncodableValue(EncodableMap{
        {EncodableValue("uuid"), EncodableValue(service.uuid)},
        {EncodableValue("primary"), EncodableValue(service.primary)},
        {EncodableValue("included"), EncodableValue(std::move(included))},
        {EncodableValue("characteristics"), EncodableValue(std::move(characteristics))},
    }));
  }
  // Older service objects stay open: active subscriptions may use them.
  entry->services.insert(entry->services.end(), opened.begin(), opened.end());
  entry->gatt = std::move(table);
  Log(kLogDebug, id + ": " + std::to_string(entry->gatt.size()) + " services");
  reply->Success(EncodableValue(std::move(result)));
}

void OpenBluePlusPlugin::EmitValue(const std::string& id,
                                          const CharacteristicAddress& address,
                                          const std::vector<uint8_t>& value) {
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("value")},
      {EncodableValue("id"), EncodableValue(id)},
      {EncodableValue("service"), EncodableValue(address.service)},
      {EncodableValue("serviceIndex"),
       EncodableValue(static_cast<int32_t>(address.service_index))},
      {EncodableValue("characteristic"), EncodableValue(address.characteristic)},
      {EncodableValue("characteristicIndex"),
       EncodableValue(static_cast<int32_t>(address.characteristic_index))},
      {EncodableValue("value"), EncodableValue(value)},
  });
}

}  // namespace open_blue_plus
