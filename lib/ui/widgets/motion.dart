import 'package:material_ui/material_ui.dart';

/// Central switch for UI motion. Animations are short (≈100–200 ms) and only animate
/// opacity, size and rotation, which are cheap to render. They are disabled when the
/// user turns them off in Settings or the OS asks for reduced motion.
class Motion {
  static bool enabled = true;

  static const fast = 120;
  static const normal = 180;

  static Duration of(BuildContext context, [int ms = normal]) =>
      enabled && !MediaQuery.disableAnimationsOf(context) ? Duration(milliseconds: ms) : Duration.zero;

  static const curve = Curves.easeOutCubic;
}

/// Fades its child in once when it is first built (e.g. when a tab or panel changes).
/// Unlike a cross-fade it never keeps the previous widget alive, so switching between
/// heavy editors costs nothing extra.
class FadeIn extends StatefulWidget {
  final Widget child;
  final int ms;
  const FadeIn({super.key, required this.child, this.ms = Motion.fast});

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final d = Motion.of(context, widget.ms);
    if (_c.status == AnimationStatus.dismissed) {
      if (d == Duration.zero) {
        _c.value = 1;
      } else {
        _c.duration = d;
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut), child: widget.child);
}

/// Smoothly reveals / hides its child by growing or shrinking its height with a fade.
/// While collapsed the child is not built at all, so large hidden subtrees cost nothing.
class ExpandSection extends StatefulWidget {
  final bool expanded;
  final Widget Function() builder;
  const ExpandSection({super.key, required this.expanded, required this.builder});

  @override
  State<ExpandSection> createState() => _ExpandSectionState();
}

class _ExpandSectionState extends State<ExpandSection> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, value: widget.expanded ? 1 : 0);
  late final Animation<double> _size = CurvedAnimation(parent: _c, curve: Motion.curve, reverseCurve: Curves.easeInCubic);

  @override
  void didUpdateWidget(covariant ExpandSection old) {
    super.didUpdateWidget(old);
    if (widget.expanded == old.expanded) return;
    final d = Motion.of(context);
    _c.duration = d;
    _c.reverseDuration = Motion.of(context, Motion.fast + 20);
    if (d == Duration.zero) {
      _c.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.isDismissed) return const SizedBox.shrink();
        final child = widget.builder();
        if (_c.isCompleted) return child;
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _size.value,
            child: Opacity(opacity: _size.value, child: child),
          ),
        );
      },
    );
  }
}
