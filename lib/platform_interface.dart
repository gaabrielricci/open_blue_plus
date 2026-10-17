/// For platform implementations only: lets a pure Dart backend (Web, Linux)
/// replace the default platform-channel transport.
library;

export 'src/channel.dart' show BleBackend, BleChannel, MethodChannelBackend;
export 'src/exception.dart';
