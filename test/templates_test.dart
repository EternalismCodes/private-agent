import 'package:flutter_test/flutter_test.dart';
import 'package:private_agent/models/saved_skill.dart';
import 'package:private_agent/services/skill_memory_service.dart';

ActionStep typeStep(String text) => ActionStep(action: 'type_text', params: {'text': text});
ActionStep tapStep() => ActionStep(action: 'click_text', params: {'text': 'Search'});

void main() {
  group('Template detection', () {
    test('detects a searchable template from a youtube search goal', () {
      final tpl = SkillMemoryService.detectTemplate(
        'open youtube and search for cats videos',
        [tapStep(), typeStep('cats videos'), tapStep()],
      );
      expect(tpl, isNotNull);
      expect(tpl!.example, 'cats videos');
      expect(tpl.skeleton, containsAll(['youtube', 'search']));
      expect(tpl.skeleton, isNot(contains('cat')));
    });

    test('returns null when there is no typed text', () {
      final tpl = SkillMemoryService.detectTemplate('open youtube', [tapStep()]);
      expect(tpl, isNull);
    });

    test('returns null when two different things were typed', () {
      final tpl = SkillMemoryService.detectTemplate(
        'log in with username and password',
        [typeStep('bob'), typeStep('hunter2')],
      );
      expect(tpl, isNull);
    });

    test('returns null when the typed text does not overlap the goal', () {
      final tpl = SkillMemoryService.detectTemplate(
        'reply to the message',
        [typeStep('sounds good, see you then')],
      );
      expect(tpl, isNull);
    });
  });

  group('Template value extraction', () {
    final skeleton = ['youtube', 'search'];

    test('extracts the new value for a matching request', () {
      expect(
        SkillMemoryService.extractValue('search dogs on youtube', skeleton),
        'dogs',
      );
      expect(
        SkillMemoryService.extractValue('on youtube search for slippers', skeleton),
        'slippers',
      );
      expect(
        SkillMemoryService.extractValue('open youtube and search for funny cat videos', skeleton),
        'funny cat videos',
      );
    });

    test('rejects a request missing a skeleton word', () {
      expect(SkillMemoryService.extractValue('search dogs on google', skeleton), isNull);
    });

    test('rejects a request that adds another action', () {
      expect(
        SkillMemoryService.extractValue('search dogs on youtube and subscribe', skeleton),
        isNull,
      );
    });

    test('rejects an empty value', () {
      expect(SkillMemoryService.extractValue('open youtube and search', skeleton), isNull);
    });

    test('rejects an absurdly long value', () {
      expect(
        SkillMemoryService.extractValue(
          'search for apple banana cherry date fig grape kiwi lemon mango nectar on youtube',
          skeleton,
        ),
        isNull,
      );
    });
  });

  group('Word canonicalisation', () {
    test('folds synonyms, plurals and filler to the same token', () {
      expect(SkillMemoryService.canon('YouTube'), 'youtube');
      expect(SkillMemoryService.canon('videos'), 'video');
      expect(SkillMemoryService.canon('lookup'), 'search');
      expect(SkillMemoryService.canon('open'), '');
      expect(SkillMemoryService.canon('the'), '');
    });
  });
}