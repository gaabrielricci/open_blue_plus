# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "open_blue_plus")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "open_blue_plus_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "ble_codec.cpp"
  "ble_codec.h"
  "open_blue_plus_plugin.cpp"
  "open_blue_plus_plugin.h"
  "scan_filter.cpp"
  "scan_filter.h"
  "ui_dispatcher.cpp"
  "ui_dispatcher.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/open_blue_plus/open_blue_plus_plugin_c_api.h"
  "open_blue_plus_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# C++/WinRT coroutines (co_await on WinRT async operations) use the standard
# C++20 coroutines; /bigobj because the WinRT projections are large.
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_20)
target_compile_options(${PLUGIN_NAME} PRIVATE /bigobj)

# apply_standard_settings() defines _HAS_EXCEPTIONS=0, but C++/WinRT reports
# every failure by throwing (winrt::hresult_error) and this plugin catches
# them, so the STL must be in exception mode (/EHsc is already set). Remove the
# definition instead of adding _HAS_EXCEPTIONS=1 next to it: two values for one
# macro is warning C4005, an error under /WX.
get_target_property(_fbpo_definitions ${PLUGIN_NAME} COMPILE_DEFINITIONS)
if(_fbpo_definitions)
  list(REMOVE_ITEM _fbpo_definitions "_HAS_EXCEPTIONS=0")
  set_property(TARGET ${PLUGIN_NAME} PROPERTY COMPILE_DEFINITIONS
    ${_fbpo_definitions})
endif()

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
# windowsapp: Windows Runtime (Windows.Devices.Bluetooth, .Enumeration, .Radios).
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin windowsapp)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(open_blue_plus_bundled_libraries
  ""
  PARENT_SCOPE
)
