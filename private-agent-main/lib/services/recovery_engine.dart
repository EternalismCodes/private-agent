class RecoveryAction {
  final String action;
  final Map<String, dynamic> params;
  final String description;

  RecoveryAction({
    required this.action,
    required this.params,
    required this.description,
  });
}

class RecoveryEngine {
  /// Diagnoses the failure and suggests a recovery action based on the last action and current screen dump.
  Future<RecoveryAction> diagnose(String lastFailedAction, String screenContent) async {
    final lowerScreen = screenContent.toLowerCase();

    // 1. Loading/spinner detected -> Wait
    if (lowerScreen.contains('loading') || lowerScreen.contains('progress') || lowerScreen.contains('spinner') || lowerScreen.contains('wait')) {
      return RecoveryAction(
        action: 'wait',
        params: {},
        description: 'App seems to be loading, waiting...',
      );
    }

    // 2. Keyboard is likely covering elements -> Press back to dismiss
    if (lowerScreen.contains('gboard') || lowerScreen.contains('keyboard')) {
      return RecoveryAction(
        action: 'press_back',
        params: {},
        description: 'Keyboard might be blocking the screen, dismissing it.',
      );
    }

    // 3. Last action was click_text -> Try scrolling instead, or press back if stuck
    if (lastFailedAction == 'click_text' || lastFailedAction == 'click_at') {
      // Maybe we need to scroll to find it
      if (lowerScreen.contains('scrollable')) {
        return RecoveryAction(
          action: 'scroll',
          params: {'direction': 'down'},
          description: 'Click failed, trying to scroll down to find the target.',
        );
      } else {
        return RecoveryAction(
          action: 'press_back',
          params: {},
          description: 'Click failed and not scrollable, pressing back to retry from previous screen.',
        );
      }
    }

    // 4. Default fallback: go home if completely stuck
    if (lastFailedAction == 'open_app') {
      return RecoveryAction(
        action: 'press_home',
        params: {},
        description: 'Failed to open app, going home to try a different approach.',
      );
    }

    // Generic retry
    return RecoveryAction(
      action: 'press_back',
      params: {},
      description: 'Unknown failure, pressing back to recover.',
    );
  }
}
