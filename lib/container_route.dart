import 'package:flutter/material.dart';

/// Expands a source surface into a page without resizing the page's layout.
/// Other navigation uses the same gentle fade/scale instead of a side slide.
class NexPageRoute<T> extends PageRouteBuilder<T> {
  NexPageRoute({
    required WidgetBuilder builder,
    Rect? origin,
    Widget? preview,
    Color? surfaceColor,
    bool reducedMotion = false,
  }) : super(
         opaque: true,
         transitionDuration: reducedMotion
             ? Duration.zero
             : const Duration(milliseconds: 420),
         reverseTransitionDuration: reducedMotion
             ? Duration.zero
             : const Duration(milliseconds: 320),
         pageBuilder: (context, animation, secondary) => builder(context),
         transitionsBuilder: (context, animation, secondary, child) {
           if (reducedMotion) return child;
           return AnimatedBuilder(
             animation: animation,
             child: child,
             builder: (context, page) {
               final progress = Curves.easeInOutCubicEmphasized.transform(
                 animation.value,
               );
               if (origin == null) {
                 return FadeTransition(
                   opacity: animation.drive(
                     CurveTween(curve: Curves.easeOutCubic),
                   ),
                   child: Transform.scale(
                     scale: 0.985 + 0.015 * progress,
                     alignment: Alignment.bottomCenter,
                     child: page,
                   ),
                 );
               }
               return LayoutBuilder(
                 builder: (context, constraints) {
                   final full = Offset.zero & constraints.biggest;
                   final rect = Rect.lerp(origin, full, progress)!;
                   final radius =
                       (origin.height / 2).clamp(0.0, 36.0) * (1 - progress);
                   final contentOpacity = ((animation.value - 0.12) / 0.55)
                       .clamp(0.0, 1.0);
                   return Stack(
                     children: [
                       Positioned.fill(
                         child: ColoredBox(
                           color: Colors.black.withValues(
                             alpha: 0.1 * progress,
                           ),
                         ),
                       ),
                       Positioned.fromRect(
                         rect: rect,
                         child: ClipRRect(
                           key: const ValueKey('expanding-page-container'),
                           borderRadius: BorderRadius.circular(radius),
                           child: ColoredBox(
                             color: Color.lerp(
                               surfaceColor ??
                                   Theme.of(
                                     context,
                                   ).colorScheme.surfaceContainerHigh,
                               Theme.of(context).scaffoldBackgroundColor,
                               progress,
                             )!,
                             child: Stack(
                               fit: StackFit.expand,
                               children: [
                                 OverflowBox(
                                   alignment: Alignment.topLeft,
                                   minWidth: full.width,
                                   maxWidth: full.width,
                                   minHeight: full.height,
                                   maxHeight: full.height,
                                   child: Opacity(
                                     opacity: contentOpacity,
                                     child: page,
                                   ),
                                 ),
                                 if (preview != null && animation.value < 0.4)
                                   Center(
                                     child: Opacity(
                                       opacity: (1 - animation.value / 0.4)
                                           .clamp(0.0, 1.0),
                                       child: SizedBox(
                                         width: origin.width,
                                         height: origin.height,
                                         child: IgnorePointer(
                                           child: ExcludeSemantics(
                                             child: preview,
                                           ),
                                         ),
                                       ),
                                     ),
                                   ),
                               ],
                             ),
                           ),
                         ),
                       ),
                     ],
                   );
                 },
               );
             },
           );
         },
       );
}
