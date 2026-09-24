import 'dart:math' as math;
import 'agent_context.dart';
import 'json_utils.dart';
import 'plan.dart';

/// Turns a goal into an ordered plan, and repairs plans that hit problems.
class Planner {
  final AgentContext ctx;
  Planner(this.ctx);

  int get _budget => math.max(ctx.ai.maxTokens, 3000);

  static const String _planSystem = '''
You are the planning module of PrivateAgent, an autonomous assistant that operates an Android phone through the Accessibility service (it can read the screen, tap, type, scroll, go back and open apps).

Break the user's GOAL into a short ordered plan of 1-6 steps. Use as FEW steps as possible. A "ui" step is a complete sub-task inside one app that ends with a visible result, for example "In YouTube, search for cat videos and open the first result". NEVER make a step for a single tap, click or keystroke (such as "click the search button" or "type cat videos"): the screen agent works out every tap by itself, and tiny steps make it slow and confused.

Each step is an object:
- "title": one imperative sentence saying what to do, including every detail needed (names, text to type, app names).
- "kind": "ui" (operate apps on screen), "action" (a direct device action from the list below) or "respond" (no device interaction: write, answer or summarise using what earlier steps found).
- "expected": what should be true or visible once the step is done (used to verify it).
- "action" and "params": only for kind "action".
- "sensitive": true when the step sends a message, places a call, spends money, deletes or changes important data, posts publicly, or installs/uninstalls something.

Direct actions: open_app {"app_name"}, make_call {"contact_name" or "phone_number"}, send_sms {"contact_name" or "phone_number","message"}, search_contact {"query"}, set_alarm {"hour","minute","label"}, set_timer {"seconds","label"}, play_youtube {"query","rank"}, get_weather {"location","days"}, set_volume {"level"}, set_brightness {"level"}, open_url {"url"}, send_email {"to","subject","body"}, read_screen {}, remember {"fact"}, wait {"seconds"}.

Rules:
- Use "action" only when it exactly fits; otherwise use "ui".
- If the goal needs information from the phone or the web, end with a "respond" step that reports it.
- Never invent contact details, passwords or facts. If a login is needed and a matching saved account exists, mention its label in the step title (for example "log in with the saved Netflix account").
- Do not add steps that were not asked for.

Return ONLY JSON, no markdown:
{"summary": "one short sentence", "steps": [ {"title": "...", "kind": "ui", "expected": "...", "sensitive": false} ]}''';

  Future<Plan> createPlan(String goal, {String mode = 'planExecute'}) async {
    final context = await ctx.contextBlock(goal, includeSkillCatalog: false);
    final res = await ctx.llm.complete(
      [
        {'role': 'system', 'content': _planSystem},
        {
          'role': 'user',
          'content': '$context\n\nGOAL: $goal\n\nWrite the plan.',
        },
      ],
      temperature: 0.3,
      maxTokens: _budget,
    );
    final json = JsonUtils.extractObject(res.content);
    return Plan.fromLlm(goal, json, mode: mode);
  }

  /// Asks the model for replacement steps after [failed] could not be done.
  /// Returns null when the model decides the goal cannot be reached.
  Future<List<PlanStep>?> replan(
    Plan plan,
    PlanStep failed,
    String reason, {
    String screen = '',
    required int startIndex,
  }) async {
    final done = plan.steps
        .where((s) => s.status == StepStatus.done)
        .map((s) => '- ${s.title}${s.result.isEmpty ? '' : ' (result: ${_clip(s.result, 160)})'}')
        .join('\n');
    final context = await ctx.contextBlock(plan.goal, includeSkills: false);
    final prompt = '''
$context

ORIGINAL GOAL: ${plan.goal}

COMPLETED STEPS:
${done.isEmpty ? '(none)' : done}

FAILED STEP: ${failed.title}
WHY IT FAILED: ${_clip(reason, 400)}
${screen.isEmpty ? '' : '\nCURRENT SCREEN (abridged):\n${_clip(screen, 1500)}\n'}
Write the REMAINING steps needed to reach the goal, taking a different approach where the failed step went wrong (for example another route through the app, another app, or the web in Chrome). Do not repeat completed steps.
If the goal cannot be reached, return {"give_up": true, "reason": "..."}.
Otherwise return {"steps": [ ... ]} using the same step format as before.''';

    final res = await ctx.llm.complete(
      [
        {'role': 'system', 'content': _planSystem},
        {'role': 'user', 'content': prompt},
      ],
      temperature: 0.4,
      maxTokens: _budget,
    );
    final json = JsonUtils.extractObject(res.content);
    if (json == null) return null;
    if (JsonUtils.boolOf(json['give_up'])) return null;
    final raw = json['steps'];
    if (raw is! List || raw.isEmpty) return null;

    final steps = <PlanStep>[];
    for (final entry in raw.take(8)) {
      if (entry is Map) {
        final step = PlanStep.fromLlm(Map<String, dynamic>.from(entry), startIndex + steps.length);
        steps.add(step);
      }
    }
    return steps.isEmpty ? null : steps;
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
}
