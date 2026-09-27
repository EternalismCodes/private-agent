import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../services/ai_service.dart';
import 'json_utils.dart';

/// One streamed fragment of a model response.
class LlmDelta {
  final String content;
  final String reasoning;
  const LlmDelta({this.content = '', this.reasoning = ''});
}

/// Thin OpenAI-compatible chat-completions client built on the settings the
/// user configured in [AiService] (Base URL + API key + model).
///
/// It deliberately does not touch [AiService]'s own conversation state so the
/// original phone-control loop keeps working exactly as before. Every request
/// can be aborted instantly with [abortAll] (the Stop button).
class LlmClient {
  final AiService ai;
  LlmClient(this.ai);

  static int _epoch = 0;
  static final Set<http.Client> _open = <http.Client>{};

  /// Cancels every request that is in flight and makes older ones fail fast.
  static void abortAll() {
    _epoch++;
    for (final c in List<http.Client>.from(_open)) {
      try {
        c.close();
      } catch (_) {}
    }
    _open.clear();
  }

  static String endpoint(String baseUrl) {
    final u = baseUrl.trim();
    if (u.endsWith('/chat/completions')) return u;
    if (u.endsWith('/')) return '${u}chat/completions';
    return '$u/chat/completions';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${ai.apiKey}',
        'HTTP-Referer': 'https://github.com/orailnoor/private-agent',
        'X-Title': 'PrivateAgent',
      };

  int _tokens(int? override) {
    var t = override ?? ai.maxTokens;
    // Reasoning models can burn a small budget before producing any answer.
    if (AiService.isNvidiaBaseUrl(ai.baseUrl) &&
        ai.model == AiService.nvidiaDefaultModel &&
        t < 4096) {
      t = 4096;
    }
    return t;
  }

  static String _errorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) return err['message'].toString();
        if (err is String) return err;
      }
    } catch (_) {}
    return body.length > 300 ? body.substring(0, 300) : body;
  }

  void _requireKey() {
    if (!ai.isConfigured) {
      throw Exception('API Key is not configured. Please go to Settings.');
    }
  }

  static Exception _cancelled() => Exception('Cancelled');

  /// Single, non-streamed completion. Retries transient failures.
  Future<AiResponse> complete(
    List<Map<String, String>> messages, {
    double? temperature,
    int? maxTokens,
    int retries = 2,
  }) async {
    _requireKey();
    final epoch = _epoch;
    var attempt = 0;
    while (true) {
      attempt++;
      if (_epoch != epoch) throw _cancelled();
      final client = http.Client();
      _open.add(client);
      try {
        final response = await client
            .post(
              Uri.parse(endpoint(ai.baseUrl)),
              headers: _headers,
              body: jsonEncode({
                'model': ai.model,
                'messages': messages,
                'temperature': temperature ?? ai.temperature,
                'max_tokens': _tokens(maxTokens),
              }),
            )
            .timeout(const Duration(minutes: 2));

        if (response.statusCode != 200) {
          final msg = _errorMessage(response.body);
          final transient = response.statusCode == 429 || response.statusCode >= 500;
          if (transient && attempt <= retries) {
            await Future<void>.delayed(Duration(seconds: 2 * attempt));
            continue;
          }
          throw Exception('API error (${response.statusCode}): $msg');
        }

        final data = jsonDecode(response.body);
        if (data is! Map || data['choices'] is! List || (data['choices'] as List).isEmpty) {
          throw Exception('Unexpected API response format.');
        }
        final message = (data['choices'] as List).first['message'];
        var content = message is Map ? (message['content'] ?? '').toString() : '';
        content = JsonUtils.stripThinking(content);
        if (content.isEmpty) {
          throw Exception(
            'The model returned an empty answer. Try again or raise Max Tokens in Settings.',
          );
        }
        var tokens = 0;
        final usage = data['usage'];
        if (usage is Map && usage['total_tokens'] is num) {
          tokens = (usage['total_tokens'] as num).toInt();
        }
        return AiResponse(content, tokens);
      } on TimeoutException {
        if (_epoch != epoch) throw _cancelled();
        if (attempt <= retries) continue;
        throw Exception('The model took too long to respond.');
      } catch (e) {
        if (_epoch != epoch) throw _cancelled();
        final text = e.toString();
        if (text.contains('API error') ||
            text.contains('API Key') ||
            text.contains('empty answer') ||
            text.contains('Unexpected API response')) {
          rethrow;
        }
        if (attempt <= retries) {
          developer.log('LLM call failed ($e), retrying', name: 'PrivateAgent');
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
          continue;
        }
        throw Exception('Network error: $e');
      } finally {
        _open.remove(client);
        client.close();
      }
    }
  }

  /// Streams a completion. Reasoning tokens (`reasoning_content`) that some
  /// providers send separately are surfaced through [LlmDelta.reasoning].
  Stream<LlmDelta> stream(
    List<Map<String, String>> messages, {
    double? temperature,
    int? maxTokens,
  }) async* {
    _requireKey();
    final epoch = _epoch;
    final client = http.Client();
    _open.add(client);
    try {
      final request = http.Request('POST', Uri.parse(endpoint(ai.baseUrl)));
      request.headers.addAll(_headers);
      request.body = jsonEncode({
        'model': ai.model,
        'messages': messages,
        'temperature': temperature ?? ai.temperature,
        'max_tokens': _tokens(maxTokens),
        'stream': true,
      });

      final http.StreamedResponse response;
      try {
        response = await client.send(request).timeout(const Duration(seconds: 90));
      } catch (e) {
        if (_epoch != epoch) throw _cancelled();
        rethrow;
      }
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw Exception('API error (${response.statusCode}): ${_errorMessage(body)}');
      }

      final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (_epoch != epoch) throw _cancelled();
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final json = jsonDecode(payload);
          if (json is! Map || json['choices'] is! List) continue;
          final choices = json['choices'] as List;
          if (choices.isEmpty) continue;
          final choice = choices.first;
          if (choice is! Map) continue;
          final delta = choice['delta'];
          if (delta is Map) {
            final content = delta['content'];
            final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
            final c = content is String ? content : '';
            final r = reasoning is String ? reasoning : '';
            if (c.isNotEmpty || r.isNotEmpty) {
              yield LlmDelta(content: c, reasoning: r);
            }
          }
          if (choice['finish_reason'] != null) break;
        } catch (_) {
          // Ignore partial / non-JSON keep-alive lines.
        }
      }
    } catch (e) {
      if (_epoch != epoch) throw _cancelled();
      rethrow;
    } finally {
      _open.remove(client);
      client.close();
    }
  }
}
