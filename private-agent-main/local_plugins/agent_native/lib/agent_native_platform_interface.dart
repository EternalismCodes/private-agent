import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'agent_native_method_channel.dart';

abstract class AgentNativePlatform extends PlatformInterface {
  /// Constructs a AgentNativePlatform.
  AgentNativePlatform() : super(token: _token);

  static final Object _token = Object();

  static AgentNativePlatform _instance = MethodChannelAgentNative();

  /// The default instance of [AgentNativePlatform] to use.
  ///
  /// Defaults to [MethodChannelAgentNative].
  static AgentNativePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [AgentNativePlatform] when
  /// they register themselves.
  static set instance(AgentNativePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
