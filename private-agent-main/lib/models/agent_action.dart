class AgentAction {
  final String action;
  final Map<String, dynamic> params;
  final String response;

  AgentAction({
    required this.action,
    required this.params,
    required this.response,
  });

  factory AgentAction.fromJson(Map<String, dynamic> json) {
    return AgentAction(
      action: json['action']?.toString() ?? 'general_query',
      params: json['params'] is Map ? Map<String, dynamic>.from(json['params'] as Map) : <String, dynamic>{},
      response: json['response']?.toString() ?? '',
    );
  }

  static const List<String> availableActions = [
    'open_app',
    'make_call',
    'send_sms',
    'search_contact',
    'set_alarm',
    'set_timer',
    'play_youtube',
    'play_favorite',
    'play_netflix',
    'play_favorite_netflix',
    'take_photo',
    'get_weather',
    'send_whatsapp',
    'send_ir',
    'save_ir',
    'set_volume',
    'set_brightness',
    'read_notifications',
    'read_screen',
    'run_adb_command',
    'general_query',
  ];
}
