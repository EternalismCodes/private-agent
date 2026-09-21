import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../agent/scheduler_service.dart';
import '../widgets/screen_helpers.dart';

class SchedulesScreen extends StatefulWidget {
  /// Runs a task immediately (provided by the home screen).
  final Future<void> Function(String goal)? onRunNow;
  const SchedulesScreen({super.key, this.onRunNow});

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  final SchedulerService _scheduler = SchedulerService.instance;
  List<ScheduledTask> _items = [];
  bool _loading = true;
  bool _exactOk = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await _scheduler.load(force: true);
    final exact = await _scheduler.canScheduleExact();
    if (!mounted) return;
    setState(() {
      _items = List<ScheduledTask>.from(_scheduler.items);
      _exactOk = exact;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final goal = TextEditingController();
    var when = DateTime.now().add(const Duration(hours: 1));
    when = DateTime(when.year, when.month, when.day, when.hour, 0);
    var repeat = 'none';
    final formKey = GlobalKey<FormState>();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Schedule a task', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: goal,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'What should the agent do?',
                      hintText: 'Open Weather and tell me if I need an umbrella',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Describe the task' : null,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.calendar_today_rounded, size: 16),
                          label: Text(DateFormat('EEE, d MMM').format(when)),
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: ctx,
                              initialDate: when,
                              firstDate: DateTime.now().subtract(const Duration(days: 1)),
                              lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                            );
                            if (d != null) {
                              setLocal(() => when = DateTime(d.year, d.month, d.day, when.hour, when.minute));
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.schedule_rounded, size: 16),
                          label: Text(DateFormat('HH:mm').format(when)),
                          onPressed: () async {
                            final t = await showTimePicker(
                              context: ctx,
                              initialTime: TimeOfDay(hour: when.hour, minute: when.minute),
                            );
                            if (t != null) {
                              setLocal(() => when = DateTime(when.year, when.month, when.day, t.hour, t.minute));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: repeat,
                    decoration: const InputDecoration(labelText: 'Repeat', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'none', child: Text('Once')),
                      DropdownMenuItem(value: 'daily', child: Text('Every day')),
                      DropdownMenuItem(value: 'weekdays', child: Text('Weekdays (Mon-Fri)')),
                      DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                    ],
                    onChanged: (v) => setLocal(() => repeat = v ?? 'none'),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        if (!formKey.currentState!.validate()) return;
                        if (repeat == 'none' && !when.isAfter(DateTime.now())) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Pick a time in the future.')),
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: const Text('Schedule'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (ok == true) {
      await _scheduler.add(goal: goal.text, when: when, repeat: repeat, mode: 'auto');
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Schedules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_alarm_rounded),
        label: const Text('Schedule'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                const InfoBanner(
                  icon: Icons.info_outline_rounded,
                  text:
                      'At the scheduled time PrivateAgent runs the task if the app is open, or posts a notification: tap it and the task starts. Android does not allow apps to control the screen from the background without you.',
                ),
                if (!_exactOk)
                  InfoBanner(
                    icon: Icons.alarm_off_rounded,
                    color: Colors.orange,
                    text: 'Exact alarms are off, so reminders may arrive a few minutes late.',
                    action: TextButton(
                      onPressed: () async {
                        await _scheduler.openExactAlarmSettings();
                      },
                      child: const Text('Allow'),
                    ),
                  ),
                if (_items.isEmpty)
                  const SizedBox(
                    height: 380,
                    child: EmptyState(
                      icon: Icons.schedule_rounded,
                      title: 'No scheduled tasks',
                      subtitle: 'Ask in Auto mode ("every weekday at 8 check the weather") or tap Schedule.',
                    ),
                  ),
                for (final t in _items)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(t.goal,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                              ),
                              Switch(
                                value: t.enabled,
                                onChanged: (v) async {
                                  await _scheduler.setEnabled(t, v);
                                  await _reload();
                                },
                              ),
                            ],
                          ),
                          Text(
                            t.enabled && t.nextRun != null
                                ? 'Next: ${DateFormat('EEE d MMM, HH:mm').format(t.nextRun!)} · ${t.repeatLabel}'
                                : '${t.repeatLabel} · off',
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurface.withValues(alpha: 0.65)),
                          ),
                          if (t.lastRun != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                'Last run ${DateFormat('d MMM, HH:mm').format(t.lastRun!)}${t.lastStatus.isEmpty ? '' : ' · ${t.lastStatus}'}',
                                style: TextStyle(fontSize: 11.5, color: scheme.onSurface.withValues(alpha: 0.5)),
                              ),
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (widget.onRunNow != null)
                                TextButton.icon(
                                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                                  label: const Text('Run now'),
                                  onPressed: () async {
                                    final goal = t.goal;
                                    Navigator.pop(context);
                                    await widget.onRunNow!(goal);
                                  },
                                ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                                onPressed: () async {
                                  final ok = await confirmDialog(
                                    context,
                                    title: 'Delete schedule?',
                                    message: 'This task will no longer run.',
                                  );
                                  if (ok) {
                                    await _scheduler.remove(t);
                                    await _reload();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
