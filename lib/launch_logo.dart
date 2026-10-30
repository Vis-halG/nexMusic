import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A single entrance per app launch, with no extra delay for loading work.
class LaunchLogo extends StatefulWidget {
  const LaunchLogo({super.key, required this.child});
  final Widget child;
  @override
  State<LaunchLogo> createState() => _LaunchLogoState();
}

class _LaunchLogoState extends State<LaunchLogo>
    with SingleTickerProviderStateMixin {
  late final _animation =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 760),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _finished = true);
        }
      });
  bool _started = false, _finished = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _finished = true;
    } else {
      _animation.forward();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_finished || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(child: widget.child),
        Positioned.fill(
          child: BlockSemantics(
            child: FadeTransition(
              opacity: Tween(begin: 1.0, end: 0.0).animate(
                CurvedAnimation(
                  parent: _animation,
                  curve: const Interval(0.7, 1, curve: Curves.easeOut),
                ),
              ),
              child: ColoredBox(
                key: const ValueKey('launch-logo'),
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: ScaleTransition(
                    scale: Tween(begin: 0.9, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _animation,
                        curve: const Interval(
                          0,
                          0.7,
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                    ),
                    child: FadeTransition(
                      opacity: Tween(begin: 0.45, end: 1.0).animate(
                        CurvedAnimation(
                          parent: _animation,
                          curve: const Interval(0, 0.5, curve: Curves.easeOut),
                        ),
                      ),
                      child: SvgPicture.asset(
                        'assets/branding/nexmusic-logo.svg',
                        width: 144,
                        height: 144,
                        semanticsLabel: 'nexMusic',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
