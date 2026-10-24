import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/agent/agent_mode.dart';
import 'package:private_agent/agent/json_utils.dart';
import 'package:private_agent/agent/memory_service.dart';
import 'package:private_agent/agent/plan.dart';
import 'package:private_agent/agent/scheduler_service.dart';
import 'package:private_agent/agent/skills_service.dart';

void main() {
  group('JsonUtils', () {
    test('extracts an object from chatter and code fences', () {
      final json = JsonUtils.extractObject(
        'Sure! ```json\n{"a": 1, "b": {"c": [1, 2]}}\n``` done',
      );
      expect(json, isNotNull);
      expect(json!['a'], 1);
    });

    test('repairs a truncated object', () {
      final json = JsonUtils.extractObject('{"action":"x","params":{"a":1}');
      expect(json, isNotNull);
      expect(json!['action'], 'x');
    });

    test('strips think blocks', () {
      expect(JsonUtils.stripThinking('<think>hidden</think>Hello'), 'Hello');
    });

    test('makes markdown speakable', () {
      expect(
        JsonUtils.forSpeech('**Hello** [link](http://x.com) `code`'),
        'Hello link code',
      );
    });
  });

  group('ThinkParser', () {
    test('splits reasoning from the answer', () {
      final split = ThinkParser.split('<thinking>step one</thinking>The answer is 4.');
      expect(split.reasoning, 'step one');
      expect(split.answer, 'The answer is 4.');
      expect(split.thinkingOpen, isFalse);
    });

    test('reports an unfinished thought while streaming', () {
      final split = ThinkParser.split('<thinking>still going');
      expect(split.reasoning, 'still going');
      expect(split.answer, '');
      expect(split.thinkingOpen, isTrue);
    });

    test('handles a closing tag without an opening one', () {
      final split = ThinkParser.split('hidden reasoning</think>Final');
      expect(split.reasoning, 'hidden reasoning');
      expect(split.answer, 'Final');
    });
  });

  group('AgentMode', () {
    test('round-trips ids and defaults to auto', () {
      expect(AgentModeInfo.fromId('think'), AgentMode.think);
      expect(AgentModeInfo.fromId('planExecute'), AgentMode.planExecute);
      expect(AgentModeInfo.fromId(null), AgentMode.auto);
      expect(AgentMode.chat.canControlDevice, isFalse);
      expect(AgentMode.auto.canControlDevice, isTrue);
    });
  });

  group('MemoryService helpers', () {
    test('detects explicit remember requests', () {
      expect(
        MemoryService.explicitFact('Remember that my sister is called Ana'),
        'my sister is called Ana',
      );
      expect(MemoryService.explicitFact('What should I remember?'), isNull);
    });

    test('flags secrets', () {
      expect(MemoryService.looksSensitive('my password is hunter2'), isTrue);
      expect(MemoryService.looksSensitive('Likes jazz'), isFalse);
    });

    test('parses sections and free text', () {
      final map = MemoryService.parse(
        '# T\n\n## About the user\n- Name is Sam\n\n## Preferences\n- Dark mode\nfree text\n',
      );
      expect(map['About the user'], ['Name is Sam']);
      expect(map['Preferences'], ['Dark mode', 'free text']);
    });

    test('maps loose section names', () {
      expect(MemoryService.canonicalSection('preferences'), 'Preferences');
      expect(MemoryService.canonicalSection('about'), 'About the user');
      expect(MemoryService.canonicalSection('random'), 'Facts & notes');
    });
  });

  group('Plan', () {
    test('builds steps from model JSON and normalises them', () {
      final plan = Plan.fromLlm('goal', {
        'summary': 'S',
        'steps': [
          {'title': 'Open WhatsApp and send hello to John', 'kind': 'ui'},
          {'title': 'Tell the user', 'kind': 'respond'},
          {
            'title': 'Dial',
            'kind': 'action',
            'action': 'make_call',
            'params': {'contact_name': 'Mom'},
          },
          {'title': 'Nope', 'kind': 'action', 'action': 'launch_missiles'},
        ],
      });
      expect(plan.steps.length, 4);
      expect(plan.summary, 'S');
      expect(plan.steps[0].sensitive, isTrue);
      expect(plan.steps[1].sensitive, isFalse);
      expect(plan.steps[2].kind, 'action');
      expect(plan.steps[2].sensitive, isTrue);
      expect(plan.steps[3].kind, 'ui');
      expect(plan.steps[3].action, '');
    });

    test('never returns an empty plan', () {
      final plan = Plan.fromLlm('do it', null);
      expect(plan.steps.length, 1);
      expect(plan.steps.first.title, 'do it');
    });

    test('survives a JSON round trip', () {
      final plan = Plan.single('goal');
      plan.steps.first.status = StepStatus.done;
      plan.state = PlanState.done;
      final copy = Plan.fromJson(plan.toJson());
      expect(copy.steps.length, 1);
      expect(copy.steps.first.status, StepStatus.done);
      expect(copy.state, PlanState.done);
    });
  });

  group('ScheduledTask', () {
    ScheduledTask task(String repeat, DateTime anchor) =>
        ScheduledTask(id: '1', goal: 'g', repeat: repeat, anchor: anchor);

    test('daily runs at the same time of day', () {
      final t = task('daily', DateTime(2026, 9, 21, 8, 30));
      expect(t.computeNextRun(DateTime(2026, 9, 21, 9, 0)), DateTime(2026, 9, 22, 8, 30));
      expect(t.computeNextRun(DateTime(2026, 9, 21, 7, 0)), DateTime(2026, 9, 21, 8, 30));
    });

    test('weekdays skip the weekend', () {
      final t = task('weekdays', DateTime(2026, 9, 21, 8, 30));
      // 25 September 2026 is a Friday.
      expect(t.computeNextRun(DateTime(2026, 9, 25, 9, 0)), DateTime(2026, 9, 28, 8, 30));
    });

    test('weekly keeps the weekday of the anchor', () {
      final anchor = DateTime(2026, 9, 23, 10, 0);
      final t = task('weekly', anchor);
      final next = t.computeNextRun(DateTime(2026, 9, 21, 9, 0));
      expect(next, DateTime(2026, 9, 23, 10, 0));
      expect(next!.weekday, anchor.weekday);
    });

    test('one-off tasks finish after their time', () {
      final t = task('none', DateTime(2026, 9, 21, 8, 30));
      expect(t.computeNextRun(DateTime(2026, 9, 21, 7, 0)), DateTime(2026, 9, 21, 8, 30));
      expect(t.computeNextRun(DateTime(2026, 9, 21, 9, 0)), isNull);
    });

    test('keeps its own model and confirmation setting', () {
      final t = ScheduledTask(
        id: '1',
        goal: 'g',
        anchor: DateTime(2026, 9, 21, 8),
        model: 'gpt-4o-mini',
        askFirst: true,
      );
      final copy = ScheduledTask.fromJson(t.toJson());
      expect(copy.model, 'gpt-4o-mini');
      expect(copy.askFirst, isTrue);
      final old = ScheduledTask.fromJson({
        'id': '2',
        'goal': 'g',
        'anchor': '2026-09-21T08:00:00.000',
      });
      expect(old.model, '');
      expect(old.askFirst, isFalse);
    });

    test('parses the time format the model uses', () {
      expect(SchedulerService.parseWhen('2026-09-22 09:15'), DateTime(2026, 9, 22, 9, 15));
      expect(SchedulerService.parseWhen('not a date'), isNull);
    });
  });

  group('Skills matching', () {
    final skill = AgentSkill(
      id: '1',
      name: 'Send a WhatsApp message',
      triggers: ['whatsapp'],
      instructions: 'steps',
    );

    test('scores relevant requests higher than unrelated ones', () {
      expect(SkillsService.score(skill, 'send a whatsapp message to John'), greaterThanOrEqualTo(5));
      expect(SkillsService.score(skill, 'what is the weather'), 0);
    });
  });
}
