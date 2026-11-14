import 'package:flutter/widgets.dart';

/// One tab of a shell that keeps every visited tab mounted.
///
/// Showing a tab fades it in with a slight lift, so switching never jumps
/// straight to the new content. Hidden tabs stay offstage with their tickers
/// paused, keeping their scroll position and state. Reduced motion shows the
/// tab at once.
class TabStage extends StatefulWidget {
  const TabStage({super.key, required this.active, required this.child});

  static const duration = Duration(milliseconds: 160);

  final bool active;
  final Widget child;

  @override
  State<TabStage> createState() => _TabStageState();
}

class _TabStageState extends State<TabStage>
    with SingleTickerProviderStateMixin {
  // This controller lives outside the tab's own TickerMode, so it still runs
  // in the frame the tab wakes up.
  late final _controller = AnimationController(
    vsync: this,
    duration: TabStage.duration,
    value: widget.active ? 1 : 0,
  );
  late final _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final _offset = Tween(
    begin: const Offset(0, 0.008),
    end: Offset.zero,
  ).animate(_opacity);

  @override
  void didUpdateWidget(TabStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (!widget.active || MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.active ? 1 : 0;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: !widget.active,
    child: TickerMode(
      enabled: widget.active,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _offset, child: widget.child),
      ),
    ),
  );
}
