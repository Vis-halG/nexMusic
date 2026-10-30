import 'dart:ui' show FlutterView;
import 'package:flutter/widgets.dart';

/// Android Back hides the IME without clearing Flutter's text-field focus.
class KeyboardDismissFocus extends StatefulWidget {
  const KeyboardDismissFocus({super.key, required this.child});
  final Widget child;
  @override
  State<KeyboardDismissFocus> createState() => _KeyboardDismissFocusState();
}

class _KeyboardDismissFocusState extends State<KeyboardDismissFocus>
    with WidgetsBindingObserver {
  FlutterView? _view;
  bool _keyboardVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _keyboardVisible = _view!.viewInsets.bottom > 0;
  }

  @override
  void didChangeMetrics() {
    final visible = (_view?.viewInsets.bottom ?? 0) > 0;
    if (_keyboardVisible && !visible) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _keyboardVisible = visible;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
