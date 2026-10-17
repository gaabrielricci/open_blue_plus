#include "include/open_blue_plus/open_blue_plus_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "open_blue_plus_plugin.h"

void OpenBluePlusPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  open_blue_plus::OpenBluePlusPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
