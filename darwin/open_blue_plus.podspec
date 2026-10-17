#
# Shared iOS + macOS implementation (sharedDarwinSource).
# Run `pod lib lint open_blue_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'open_blue_plus'
  s.version          = '1.0.0'
  s.summary          = 'Bluetooth Low Energy plugin for Flutter.'
  s.description      = <<-DESC
Bluetooth Low Energy (central role) plugin for Flutter.
                       DESC
  s.homepage         = 'https://pub.dev/packages/open_blue_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ricci Mobile' => 'riccimobileltda@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'open_blue_plus/Sources/open_blue_plus/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks = 'CoreBluetooth'
  s.osx.frameworks = 'SystemConfiguration'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {
    'open_blue_plus_privacy' => ['open_blue_plus/Sources/open_blue_plus/PrivacyInfo.xcprivacy']
  }
end
