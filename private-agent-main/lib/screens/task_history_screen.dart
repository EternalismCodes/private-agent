import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/task_history_logger.dart';

class TaskHistoryScreen extends StatefulWidget {
  const TaskHistoryScreen({super.key});

  @override
  State<TaskHistoryScreen> createState() => _TaskHistoryScreenState();
}

class _TaskHistoryScreenState extends State<TaskHistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  Map<String, dynamic>? _analytics;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final history = await TaskHistoryLogger.readHistory();
    final analytics = await TaskHistoryLogger.getAnalytics();
    setState(() {
      _history = history;
      _analytics = analytics;
      _isLoading = false;
    });
  }

  Future<void> _clearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Task History'),
        content: const Text('Are you sure you want to delete all task history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await TaskHistoryLogger.clearHistory();
      _loadHistory();
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Success':
        return Colors.green;
      case 'Failed':
        return Colors.red;
      case 'Cancelled':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'Success':
        return Icons.check_circle;
      case 'Failed':
        return Icons.cancel;
      case 'Cancelled':
        return Icons.stop_circle;
      default:
        return Icons.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Task History (${_history.length})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _history.isEmpty ? null : _clearHistory,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? const Center(child: Text('No task history found.'))
              : Column(
                  children: [
                    if (_analytics != null && _analytics!['totalTasks'] > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildStatColumn('Total', _analytics!['totalTasks'].toString(), isDark: Theme.of(context).brightness == Brightness.dark),
                                _buildStatColumn('Success', _analytics!['successCount'].toString(), color: Colors.green, isDark: Theme.of(context).brightness == Brightness.dark),
                                _buildStatColumn('Failed', _analytics!['failedCount'].toString(), color: Colors.red, isDark: Theme.of(context).brightness == Brightness.dark),
                                _buildStatColumn('Rate', '${(_analytics!['successRate'] * 100).toStringAsFixed(1)}%', isDark: Theme.of(context).brightness == Brightness.dark),
                              ],
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _history.length,
                        padding: const EdgeInsets.all(16),
                        itemBuilder: (context, index) {
                          final task = _history[index];
                          final date = DateTime.tryParse(task['timestamp'] ?? '');
                          final dateStr = date != null
                              ? DateFormat('MMM d, y h:mm a').format(date)
                              : 'Unknown Date';
                          final status = task['status'] as String? ?? 'Unknown';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 16),
                            child: ExpansionTile(
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: _getStatusColor(status).withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _getStatusIcon(status),
                                  color: _getStatusColor(status),
                                  size: 24,
                                ),
                              ),
                              title: Text(
                                task['goal'] ?? 'Unknown Goal',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Row(
                                  children: [
                                    Text(dateStr, style: const TextStyle(fontSize: 12)),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '${task['total_tokens'] ?? 0} tokens',
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: _getStatusColor(status).withOpacity(0.12),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: _getStatusColor(status).withOpacity(0.3)),
                                            ),
                                            child: Text(
                                              status.toUpperCase(),
                                              style: TextStyle(
                                                color: _getStatusColor(status),
                                                fontWeight: FontWeight.w800,
                                                fontSize: 10,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            'Steps taken: ${task['steps_taken'] ?? 0}',
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                          ),
                                        ],
                                      ),
                                      if (task['mode'] != null) ...[
                                        const SizedBox(height: 10),
                                        Text(
                                          'Mode: ${task['mode']}',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                      if (task['plan'] is Map) ...[
                                        const SizedBox(height: 14),
                                        const Text(
                                          'Plan:',
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        const SizedBox(height: 6),
                                        ..._planSteps(task['plan'] as Map),
                                      ],
                                      const SizedBox(height: 20),
                                      const Text(
                                        'Execution Trace:',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      const SizedBox(height: 8),
                                      ...((task['trace'] as List<dynamic>?) ?? []).map((t) => Container(
                                        margin: const EdgeInsets.only(bottom: 6),
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          '• $t',
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.85),
                                          ),
                                        ),
                                      )),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  List<Widget> _planSteps(Map plan) {
    final steps = plan['steps'];
    if (steps is! List) return const [];
    return [
      for (final raw in steps)
        if (raw is Map)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  raw['status'] == 'done'
                      ? Icons.check_circle
                      : (raw['status'] == 'failed'
                          ? Icons.cancel
                          : (raw['status'] == 'skipped'
                              ? Icons.remove_circle_outline
                              : Icons.radio_button_unchecked)),
                  size: 16,
                  color: raw['status'] == 'done'
                      ? Colors.green
                      : (raw['status'] == 'failed' ? Colors.red : Colors.grey),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${raw['title'] ?? ''}',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
    ];
  }

  Widget _buildStatColumn(String label, String value, {Color? color, required bool isDark}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.06),
        ),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: color ?? (isDark ? Colors.white : const Color(0xFF1E293B)),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
