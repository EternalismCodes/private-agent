import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/agent/plan.dart';
import 'package:private_agent/agent/plan_cache.dart';
import 'package:private_agent/agent/workflow.dart';
import 'package:private_agent/models/saved_skill.dart';

Map<String, dynamic> node(
  String text, {
  bool clickable = true,
  int left = 0,
  int top = 0,
  int right = 100,
  int bottom = 50,
  String desc = '',
}) =>
    {
      'text': text,
      'contentDescription': desc,
      'className': 'android.widget.Button',
      'isClickable': clickable,
      'isEditable': false,
      'isScrollable': false,
      'bounds': {'left': left, 'top': top, 'right': right, 'bottom': bottom},
    };

void main() {
  group('WorkflowKit screen signatures', () {
    test('keeps stable labels and drops dynamic ones', () {
      final labels = WorkflowKit.labels([
        node('Home'),
        node('Search'),
        node('12:45', clickable: false),
        node('Battery 87 percent', clickable: false),
        node('x'),
        node('', desc: 'Reels'),
        node('A very long paragraph of static text that is not interactive', clickable: false),
        node('Home'),
      ]);
      expect(labels, ['home', 'search', 'reels']);
    });

    test('matches when most recorded labels are visible', () {
      final recorded = ['home', 'search', 'reels'];
      expect(WorkflowKit.matches(recorded, ['home', 'search', 'x']), isTrue);
      expect(WorkflowKit.matches(recorded, ['home']), isFalse);
      expect(WorkflowKit.matches(['home'], []), isTrue);
    });
  });

  group('WorkflowKit targets', () {
    test('finds the nearest node with the recorded label', () {
      final a = node('Send', left: 50, top: 50, right: 150, bottom: 150);
      final b = node('Send', left: 450, top: 850, right: 550, bottom: 950);
      final found = WorkflowKit.findByLabel([a, b], 'send', cx: 480, cy: 880);
      expect(found, isNotNull);
      expect(WorkflowKit.centerX(found!), 500);
      expect(WorkflowKit.centerY(found), 900);
    });

    test('finds the smallest clickable node at a point', () {
      final container = node('', clickable: false, left: 0, top: 0, right: 1000, bottom: 2000);
      final button = node('Play', left: 400, top: 800, right: 600, bottom: 1000);
      final hit = WorkflowKit.nodeAt([container, button], 500, 900);
      expect(hit, isNotNull);
      expect(hit!['text'], 'Play');
    });

    test('records the tapped target with the step', () {
      final send = node('Send', left: 50, top: 50, right: 150, bottom: 150);
      final meta = WorkflowKit.stepMeta(
        'click_text',
        {'text': 'Send'},
        ScreenSnap('com.example.chat', [send, node('Back')]),
      );
      expect(meta['pkg'], 'com.example.chat');
      expect(meta['tx'], 'Send');
      expect(meta['cx'], 100);
      expect(meta['cy'], 100);
      expect(meta['sig'], contains('send'));
    });

    test('recording without a snapshot yields no meta', () {
      expect(WorkflowKit.stepMeta('click_text', {'text': 'x'}, null), isEmpty);
    });
  });

  group('WorkflowKit.compact', () {
    ActionStep step(String action, List<String> sig, {Map<String, dynamic>? params}) => ActionStep(
          action: action,
          params: params ?? {},
          meta: {'pkg': 'p', 'sig': sig},
        );

    test('removes a detour that ends where it started', () {
      final home = ['home', 'search', 'reels'];
      final steps = [
        step('click_text', home, params: {'text': 'Menu'}),
        step('press_back', ['menu', 'settings']),
        step('click_text', home, params: {'text': 'Search'}),
      ];
      final out = WorkflowKit.compact(steps);
      expect(out.length, 1);
      expect(out.first.params['text'], 'Search');
    });

    test('keeps normal steps and drops waits', () {
      final steps = [
        step('click_text', ['home', 'search']),
        step('wait', ['home', 'search']),
        step('click_text', ['results', 'filters']),
      ];
      expect(WorkflowKit.compact(steps).length, 2);
    });
  });

  group('Stored workflows', () {
    test('keep their exact-replay data through a JSON round trip', () {
      final skill = SavedSkill(
        id: '1',
        task: 'open instagram',
        taskKeywords: ['instagram'],
        lastUsed: DateTime(2026, 1, 1),
        steps: [
          ActionStep(
            action: 'click_at',
            params: {'x': 1, 'y': 2},
            meta: {'pkg': 'p', 'cx': 5},
          ),
        ],
        finalPkg: 'p',
        finalSig: ['a', 'b'],
      );
      final copy = SavedSkill.fromJson(skill.toJson());
      expect(copy.steps.first.meta['cx'], 5);
      expect(copy.finalPkg, 'p');
      expect(copy.finalSig, ['a', 'b']);
      expect(copy.isExact, isTrue);
    });

    test('older workflows without meta still load and are not "exact"', () {
      final copy = SavedSkill.fromJson({
        'id': '2',
        'task': 't',
        'task_keywords': ['t'],
        'last_used': '2026-01-01T00:00:00.000',
        'steps': [
          {'action': 'click_text', 'params': {'text': 'Go'}},
        ],
      });
      expect(copy.steps.first.meta, isEmpty);
      expect(copy.isExact, isFalse);
    });
  });

  group('PlanCache', () {
    test('fingerprints requests regardless of filler words and order', () {
      expect(PlanCache.keyOf('Please open Instagram'), 'instagram open');
      expect(PlanCache.keyOf('open instagram, please!'), 'instagram open');
      expect(PlanCache.keyOf('instagram open'), PlanCache.keyOf('Open Instagram'));
    });

    test('rebuilds a fresh plan from saved steps', () {
      final routine = CachedRoutine(
        key: 'k',
        goal: 'open instagram',
        steps: [
          {
            'id': 's1',
            'title': 'Open Instagram',
            'kind': 'action',
            'action': 'open_app',
            'params': {'app_name': 'Instagram'},
            'status': 'done',
            'result': 'Opened',
          },
        ],
      );
      final plan = routine.toPlan('auto');
      expect(plan.steps.length, 1);
      expect(plan.steps.first.status, StepStatus.pending);
      expect(plan.steps.first.result, '');
      expect(plan.steps.first.params['app_name'], 'Instagram');
    });
  });
}
