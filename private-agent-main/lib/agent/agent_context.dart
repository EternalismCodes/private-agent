import 'package:intl/intl.dart';
import '../services/action_handler.dart';
import '../services/ai_service.dart';
import 'llm_client.dart';
import 'memory_service.dart';
import 'prefs.dart';
import 'skills_service.dart';
import 'vault_service.dart';

/// Everything the agent brain needs, in one place.
class AgentContext {
  final AiService ai;
  final ActionHandler actions;
  final MemoryService memory = MemoryService.instance;
  final SkillsService skills = SkillsService.instance;
  final VaultService vault = VaultService.instance;
  final AgentPrefs prefs = AgentPrefs.instance;

  AgentContext({required this.ai, required this.actions});

  LlmClient get llm => LlmClient(ai);

  Future<void> ensureLoaded() async {
    await prefs.load();
    await memory.load();
    await skills.load();
    await vault.load();
  }

  String get nowText =>
      DateFormat("EEEE, d MMMM y, HH:mm").format(DateTime.now());

  /// Prompt block with the date, the user's memory, preferences, matching
  /// skills and the labels of saved accounts. Sections that are empty are left
  /// out completely.
  Future<String> contextBlock(
    String query, {
    bool includeSkills = true,
    bool includeAccounts = true,
    bool includeSkillCatalog = false,
  }) async {
    await ensureLoaded();
    final b = StringBuffer();
    b.writeln('Current date and time: $nowText');
    if (prefs.userName.isNotEmpty) {
      b.writeln('The user\'s name is ${prefs.userName}.');
    }
    final mem = await memory.promptContext();
    if (mem.isNotEmpty) {
      b.writeln('\nWHAT YOU REMEMBER ABOUT THE USER (use it when relevant, never recite it):');
      b.writeln(mem);
    }
    if (prefs.customInstructions.trim().isNotEmpty) {
      b.writeln('\nUSER INSTRUCTIONS (always follow):');
      b.writeln(prefs.customInstructions.trim());
    }
    if (includeSkills) {
      final relevant = skills.promptFor(query);
      if (relevant.isNotEmpty) {
        b.writeln('\nRELEVANT SKILLS (follow these steps when they fit the request):');
        b.writeln(relevant);
      }
    }
    if (includeSkillCatalog) {
      final catalog = skills.catalog();
      if (catalog.isNotEmpty) {
        b.writeln('\nAVAILABLE SKILLS (runnable with run_skill):');
        b.writeln(catalog);
      }
    }
    if (includeAccounts && prefs.allowCredentialFill) {
      final accounts = vault.promptSummary();
      if (accounts.isNotEmpty) {
        b.writeln(
          '\nSAVED ACCOUNTS (labels only; use the type_credential action to fill a login, you never see the secrets):',
        );
        b.writeln(accounts);
      }
    }
    return b.toString().trim();
  }
}
