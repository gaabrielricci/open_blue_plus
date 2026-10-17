#include "ble_codec.h"

#include <cstdio>
#include <variant>

namespace open_blue_plus {

namespace {

using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::DataWriter;
using winrt::Windows::Storage::Streams::IBuffer;

int HexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Parses an even number of hex digits into bytes.
bool ParseHexBytes(const std::string& hex, std::vector<uint8_t>& out) {
  if (hex.size() % 2 != 0) return false;
  out.clear();
  for (size_t i = 0; i < hex.size(); i += 2) {
    const int high = HexValue(hex[i]);
    const int low = HexValue(hex[i + 1]);
    if (high < 0 || low < 0) return false;
    out.push_back(static_cast<uint8_t>((high << 4) | low));
  }
  return true;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& args,
                                    const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

}  // namespace

std::string FormatUuid(const winrt::guid& uuid) {
  char text[37];
  std::snprintf(text, sizeof(text),
                "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                static_cast<unsigned long>(uuid.Data1),
                static_cast<unsigned int>(uuid.Data2),
                static_cast<unsigned int>(uuid.Data3),
                static_cast<unsigned int>(uuid.Data4[0]),
                static_cast<unsigned int>(uuid.Data4[1]),
                static_cast<unsigned int>(uuid.Data4[2]),
                static_cast<unsigned int>(uuid.Data4[3]),
                static_cast<unsigned int>(uuid.Data4[4]),
                static_cast<unsigned int>(uuid.Data4[5]),
                static_cast<unsigned int>(uuid.Data4[6]),
                static_cast<unsigned int>(uuid.Data4[7]));
  return text;
}

winrt::guid UuidFromShort(uint32_t value) {
  static const uint8_t kBase[16] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                    0x10, 0x00, 0x80, 0x00, 0x00, 0x80,
                                    0x5f, 0x9b, 0x34, 0xfb};
  winrt::guid uuid = UuidFromBigEndian(kBase);
  uuid.Data1 = value;
  return uuid;
}

winrt::guid UuidFromBigEndian(const uint8_t bytes[16]) {
  winrt::guid uuid{};
  uuid.Data1 = (static_cast<uint32_t>(bytes[0]) << 24) |
               (static_cast<uint32_t>(bytes[1]) << 16) |
               (static_cast<uint32_t>(bytes[2]) << 8) |
               static_cast<uint32_t>(bytes[3]);
  uuid.Data2 = static_cast<uint16_t>((bytes[4] << 8) | bytes[5]);
  uuid.Data3 = static_cast<uint16_t>((bytes[6] << 8) | bytes[7]);
  for (int i = 0; i < 8; ++i) {
    uuid.Data4[i] = bytes[8 + i];
  }
  return uuid;
}

std::optional<winrt::guid> ParseUuid(const std::string& text) {
  std::string s = text;
  if (s.size() >= 2 && s.front() == '{' && s.back() == '}') {
    s = s.substr(1, s.size() - 2);
  }
  std::vector<uint8_t> bytes;
  if (s.size() == 4 || s.size() == 8) {
    if (!ParseHexBytes(s, bytes)) return std::nullopt;
    uint32_t value = 0;
    for (const uint8_t b : bytes) {
      value = (value << 8) | b;
    }
    return UuidFromShort(value);
  }
  if (s.size() != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' ||
      s[23] != '-') {
    return std::nullopt;
  }
  const std::string hex = s.substr(0, 8) + s.substr(9, 4) + s.substr(14, 4) +
                          s.substr(19, 4) + s.substr(24, 12);
  if (!ParseHexBytes(hex, bytes) || bytes.size() != 16) return std::nullopt;
  return UuidFromBigEndian(bytes.data());
}

std::optional<std::string> NormalizeUuid(const std::string& text) {
  const auto uuid = ParseUuid(text);
  if (!uuid) return std::nullopt;
  return FormatUuid(*uuid);
}

std::string FormatAddress(uint64_t address) {
  char text[18];
  std::snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X",
                static_cast<unsigned int>((address >> 40) & 0xFF),
                static_cast<unsigned int>((address >> 32) & 0xFF),
                static_cast<unsigned int>((address >> 24) & 0xFF),
                static_cast<unsigned int>((address >> 16) & 0xFF),
                static_cast<unsigned int>((address >> 8) & 0xFF),
                static_cast<unsigned int>(address & 0xFF));
  return text;
}

std::optional<uint64_t> ParseAddress(const std::string& text) {
  if (text.size() != 17) return std::nullopt;
  std::string hex;
  for (size_t i = 0; i < text.size(); ++i) {
    if (i % 3 == 2) {
      if (text[i] != ':') return std::nullopt;
    } else {
      hex.push_back(text[i]);
    }
  }
  std::vector<uint8_t> bytes;
  if (!ParseHexBytes(hex, bytes)) return std::nullopt;
  uint64_t address = 0;
  for (const uint8_t b : bytes) {
    address = (address << 8) | b;
  }
  return address;
}

std::vector<uint8_t> ToBytes(const IBuffer& buffer) {
  if (!buffer) return {};
  std::vector<uint8_t> bytes(buffer.Length());
  if (!bytes.empty()) {
    DataReader::FromBuffer(buffer).ReadBytes(bytes);
  }
  return bytes;
}

IBuffer ToBuffer(const std::vector<uint8_t>& bytes) {
  DataWriter writer;
  writer.WriteBytes(bytes);
  return writer.DetachBuffer();
}

std::string GetString(const flutter::EncodableMap& args, const char* key) {
  const auto* value = Find(args, key);
  if (value == nullptr) return {};
  const auto* s = std::get_if<std::string>(value);
  return s == nullptr ? std::string() : *s;
}

bool GetBool(const flutter::EncodableMap& args, const char* key, bool fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  const auto* b = std::get_if<bool>(value);
  return b == nullptr ? fallback : *b;
}

int64_t GetInt(const flutter::EncodableMap& args, const char* key,
               int64_t fallback) {
  const auto* value = Find(args, key);
  if (value == nullptr) return fallback;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) return *l;
  return fallback;
}

std::vector<uint8_t> GetBytes(const flutter::EncodableMap& args, const char* key) {
  const auto* value = Find(args, key);
  if (value == nullptr) return {};
  const auto* bytes = std::get_if<std::vector<uint8_t>>(value);
  return bytes == nullptr ? std::vector<uint8_t>() : *bytes;
}

std::vector<std::string> GetStringList(const flutter::EncodableMap& args,
                                       const char* key) {
  std::vector<std::string> out;
  const auto* value = Find(args, key);
  if (value == nullptr) return out;
  const auto* list = std::get_if<flutter::EncodableList>(value);
  if (list == nullptr) return out;
  for (const auto& item : *list) {
    if (const auto* s = std::get_if<std::string>(&item)) {
      out.push_back(*s);
    }
  }
  return out;
}

std::vector<flutter::EncodableMap> GetMapList(const flutter::EncodableMap& args,
                                              const char* key) {
  std::vector<flutter::EncodableMap> out;
  const auto* value = Find(args, key);
  if (value == nullptr) return out;
  const auto* list = std::get_if<flutter::EncodableList>(value);
  if (list == nullptr) return out;
  for (const auto& item : *list) {
    if (const auto* map = std::get_if<flutter::EncodableMap>(&item)) {
      out.push_back(*map);
    }
  }
  return out;
}

}  // namespace open_blue_plus
