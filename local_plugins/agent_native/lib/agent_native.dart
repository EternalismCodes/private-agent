
import 'agent_native_platform_interface.dart';

class AgentNative {
  Future<String?> getPlatformVersion() {
    return AgentNativePlatform.instance.getPlatformVersion();
  }
}
