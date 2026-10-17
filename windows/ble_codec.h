#ifndef FLUTTER_PLUGIN_OPEN_BLUE_PLUS_BLE_CODEC_H_
#define FLUTTER_PLUGIN_OPEN_BLUE_PLUS_BLE_CODEC_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// Conversions between protocol values (PROTOCOL.md) and WinRT types.
namespace open_blue_plus {

// Lowercase 128-bit form: 0000180d-0000-1000-8000-00805f9b34fb.
std::string FormatUuid(const winrt::guid& uuid);

// Accepts the 128-bit form (any case, optional braces) and 16/32-bit short
// forms ("180d", "0000180d"), which are expanded with the Bluetooth base UUID.
std::optional<winrt::guid> ParseUuid(const std::string& text);

// Bluetooth base UUID with [value] in the first 32 bits.
winrt::guid UuidFromShort(uint32_t value);

// 16 bytes in big-endian (string) order.
winrt::guid UuidFromBigEndian(const uint8_t bytes[16]);

// Normalizes a UUID argument to FormatUuid's form.
std::optional<std::string> NormalizeUuid(const std::string& text);

// "AA:BB:CC:DD:EE:FF" <-> 48-bit address.
std::string FormatAddress(uint64_t address);
std::optional<uint64_t> ParseAddress(const std::string& text);

// A null buffer yields an empty vector.
std::vector<uint8_t> ToBytes(const winrt::Windows::Storage::Streams::IBuffer& buffer);
winrt::Windows::Storage::Streams::IBuffer ToBuffer(const std::vector<uint8_t>& bytes);

// Method-call argument accessors; missing or mistyped values yield the fallback.
std::string GetString(const flutter::EncodableMap& args, const char* key);
bool GetBool(const flutter::EncodableMap& args, const char* key, bool fallback);
// Dart ints arrive as int32 or int64 depending on their magnitude.
int64_t GetInt(const flutter::EncodableMap& args, const char* key, int64_t fallback);
std::vector<uint8_t> GetBytes(const flutter::EncodableMap& args, const char* key);
std::vector<std::string> GetStringList(const flutter::EncodableMap& args,
                                       const char* key);
std::vector<flutter::EncodableMap> GetMapList(const flutter::EncodableMap& args,
                                              const char* key);

}  // namespace open_blue_plus

#endif  // FLUTTER_PLUGIN_OPEN_BLUE_PLUS_BLE_CODEC_H_
