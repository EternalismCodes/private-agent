import 'package:flutter_test/flutter_test.dart';
import 'package:agent_native/agent_native.dart';
import 'package:agent_native/agent_native_platform_interface.dart';
import 'package:agent_native/agent_native_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAgentNativePlatform
    with MockPlatformInterfaceMixin
    implements AgentNativePlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final AgentNativePlatform initialPlatform = AgentNativePlatform.instance;

  test('$MethodChannelAgentNative is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAgentNative>());
  });

  test('getPlatformVersion', () async {
    AgentNative agentNativePlugin = AgentNative();
    MockAgentNativePlatform fakePlatform = MockAgentNativePlatform();
    AgentNativePlatform.instance = fakePlatform;

    expect(await agentNativePlugin.getPlatformVersion(), '42');
  });
}
