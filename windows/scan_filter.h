#ifndef FLUTTER_PLUGIN_OPEN_BLUE_PLUS_SCAN_FILTER_H_
#define FLUTTER_PLUGIN_OPEN_BLUE_PLUS_SCAN_FILTER_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <winrt/Windows.Devices.Bluetooth.h>

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace open_blue_plus {

// One advertisement (or, in the scan cache, everything merged so far for a
// device: Windows reports advertising data and scan responses separately).
struct ScanRecord {
  uint64_t address = 0;
  std::optional<winrt::Windows::Devices::Bluetooth::BluetoothAddressType>
      address_type;
  int rssi = 0;
  bool connectable = false;
  bool scannable = false;      // a scan response may follow
  bool scan_response = false;  // this packet is a scan response
  std::optional<std::string> local_name;
  std::optional<int> tx_power;
  std::vector<std::string> service_uuids;
  std::map<int32_t, std::vector<uint8_t>> manufacturer_data;
  std::map<std::string, std::vector<uint8_t>> service_data;
};

// startScan filters (PROTOCOL.md, "Scan filtering"), checked in software.
//
// No native BluetoothLEAdvertisementFilter is used: it ANDs its conditions
// and is applied per packet, so it would drop the scan responses that carry
// the name and cannot express the OR of different filter kinds.
class ScanFilter {
 public:
  // Reads the filter arguments of startScan. Returns an error message when
  // one is invalid (the filter is then unusable).
  std::optional<std::string> Parse(const flutter::EncodableMap& args);

  bool Matches(const ScanRecord& record) const;

 private:
  struct Pattern {
    std::vector<uint8_t> data;
    std::vector<uint8_t> mask;  // empty = all 0xFF
  };

  std::vector<std::string> services_;
  std::vector<std::string> names_;
  std::vector<std::string> keywords_;
  bool has_remote_ids_ = false;
  std::vector<uint64_t> remote_ids_;
  std::vector<std::pair<int64_t, Pattern>> manufacturer_data_;
  std::vector<std::pair<std::string, Pattern>> service_data_;
  bool has_lists_ = false;
  std::string prefix_;
};

}  // namespace open_blue_plus

#endif  // FLUTTER_PLUGIN_OPEN_BLUE_PLUS_SCAN_FILTER_H_
