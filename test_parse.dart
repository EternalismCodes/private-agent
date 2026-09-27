import 'dart:convert';

void main() {
  String jsonStr = """{
  "action": "set_brightness",
  "params": {
    "level": 50
  },
  "response": "Brightness set to 50 percent."
""";
  
  if (jsonStr.startsWith('{') && !jsonStr.endsWith('}')) {
    jsonStr += '\n}';
  }
  
  try {
    final json = jsonDecode(jsonStr);
    print('Success: ${json["action"]}');
  } catch (e) {
    if (e.toString().contains('Unexpected end of input')) {
      jsonStr += '\n}';
      final json = jsonDecode(jsonStr);
      print('Success after 2 braces: ${json["action"]}');
    } else {
      print('Failed: $e');
    }
  }
}
