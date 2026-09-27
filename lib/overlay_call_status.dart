import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Tiny "dynamic island"-style status pill shown while a voice call is
/// active, so the person can see what the agent is doing (listening,
/// thinking, controlling the phone) even while another app is on screen.
///
/// Entirely read-only and never intercepts touches (it's shown with
/// [OverlayFlag.clickThrough]): the app underneath stays fully usable.
/// Receives plain `"STATUS|<phase>|<detail>"` strings from the main app via
/// [FlutterOverlayWindow.shareData].
class CallStatusOverlay extends StatefulWidget {
  const CallStatusOverlay({super.key});

  @override
  State<CallStatusOverlay> createState() => _CallStatusOverlayState();
}

class _CallStatusOverlayState extends State<CallStatusOverlay> {
  String _phase = 'listening';
  String _detail = '';
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is! String || !event.startsWith('STATUS|')) return;
      final parts = event.split('|');
      if (!mounted) return;
      setState(() {
        _phase = parts.length > 1 ? parts[1] : _phase;
        _detail = parts.length > 2 ? parts[2] : '';
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  ({IconData icon, Color color, String label}) get _visual => switch (_phase) {
        'thinking' => (icon: Icons.psychology_rounded, color: const Color(0xFFF59E0B), label: 'Thinking'),
        'acting' => (icon: Icons.touch_app_rounded, color: const Color(0xFF38BDF8), label: 'Controlling your phone'),
        'speaking' => (icon: Icons.graphic_eq_rounded, color: const Color(0xFF818CF8), label: 'Speaking'),
        _ => (icon: Icons.mic_rounded, color: const Color(0xFF22C55E), label: 'Listening'),
      };

  @override
  Widget build(BuildContext context) {
    final v = _visual;
    final text = _detail.trim().isEmpty
        ? v.label
        : (_detail.length > 28 ? '${_detail.substring(0, 28)}…' : _detail);
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xF0111318),
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Pulse(color: v.color, icon: v.icon),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  final Color color;
  final IconData icon;
  const _Pulse({required this.color, required this.icon});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 0.25 + 0.35 * _c.value),
        ),
        child: Icon(widget.icon, size: 12, color: widget.color),
      ),
    );
  }
}
