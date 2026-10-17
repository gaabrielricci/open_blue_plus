#include "scan_filter.h"

#include <algorithm>

#include "ble_codec.h"

namespace open_blue_plus {

namespace {

bool MaskedMatch(const std::vector<uint8_t>& payload,
                 const std::vector<uint8_t>& data,
                 const std::vector<uint8_t>& mask) {
  if (payload.size() < data.size()) return false;
  for (size_t i = 0; i < data.size(); ++i) {
    const uint8_t m = i < mask.size() ? mask[i] : 0xFF;
    if ((payload[i] & m) != (data[i] & m)) return false;
  }
  return true;
}

template <typename T>
bool Contains(const std::vector<T>& list, const T& value) {
  return std::find(list.begin(), list.end(), value) != list.end();
}

}  // namespace

std::optional<std::string> ScanFilter::Parse(const flutter::EncodableMap& args) {
  *this = ScanFilter();
  for (const auto& text : GetStringList(args, "services")) {
    const auto uuid = NormalizeUuid(text);
    if (!uuid) return "Invalid service UUID: " + text;
    services_.push_back(*uuid);
  }
  names_ = GetStringList(args, "names");
  keywords_ = GetStringList(args, "keywords");
  const auto ids = GetStringList(args, "remoteIds");
  has_remote_ids_ = !ids.empty();
  for (const auto& id : ids) {
    // Ids that are not MAC addresses can never match on Windows.
    if (const auto address = ParseAddress(id)) remote_ids_.push_back(*address);
  }
  for (const auto& entry : GetMapList(args, "manufacturerData")) {
    manufacturer_data_.push_back(
        {GetInt(entry, "id", -1),
         Pattern{GetBytes(entry, "data"), GetBytes(entry, "mask")}});
  }
  for (const auto& entry : GetMapList(args, "serviceData")) {
    const std::string text = GetString(entry, "service");
    const auto uuid = NormalizeUuid(text);
    if (!uuid) return "Invalid service data UUID: " + text;
    service_data_.push_back(
        {*uuid, Pattern{GetBytes(entry, "data"), GetBytes(entry, "mask")}});
  }
  has_lists_ = !services_.empty() || !names_.empty() || !keywords_.empty() ||
               has_remote_ids_ || !manufacturer_data_.empty() ||
               !service_data_.empty();
  prefix_ = GetString(args, "namePrefix");
  return std::nullopt;
}

bool ScanFilter::Matches(const ScanRecord& record) const {
  // Windows has no cached device name while scanning: name == localName.
  const std::string* name = record.local_name ? &*record.local_name : nullptr;
  if (!prefix_.empty() &&
      (name == nullptr || name->compare(0, prefix_.size(), prefix_) != 0)) {
    return false;
  }
  if (!has_lists_) return true;
  for (const auto& uuid : services_) {
    if (Contains(record.service_uuids, uuid)) return true;
  }
  if (name != nullptr) {
    if (Contains(names_, *name)) return true;
    for (const auto& keyword : keywords_) {
      if (name->find(keyword) != std::string::npos) return true;
    }
  }
  if (Contains(remote_ids_, record.address)) return true;
  for (const auto& entry : manufacturer_data_) {
    const auto it = record.manufacturer_data.find(static_cast<int32_t>(entry.first));
    if (it != record.manufacturer_data.end() && entry.first >= 0 &&
        MaskedMatch(it->second, entry.second.data, entry.second.mask)) {
      return true;
    }
  }
  for (const auto& entry : service_data_) {
    const auto it = record.service_data.find(entry.first);
    if (it != record.service_data.end() &&
        MaskedMatch(it->second, entry.second.data, entry.second.mask)) {
      return true;
    }
  }
  return false;
}

}  // namespace open_blue_plus
