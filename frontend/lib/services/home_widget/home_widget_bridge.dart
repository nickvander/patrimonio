/// Neutral entry point for the Android home-screen widget bridge.
///
/// `package:home_widget` is an Android/iOS plugin; the app also builds for
/// **web**, and `flutter test` runs on the Dart VM where its method channel
/// has no implementation. Conditional import per the platform-seam rule: the
/// stub is what web and the analyzer resolve, the io impl is the only file
/// that ever names the plugin.
///
/// Note `dart.library.io` is true for native AND the test VM — the io impl is
/// therefore gated on `Platform.isAndroid` and swallows plugin errors, so a
/// widget test that happens to trigger a push stays inert instead of throwing
/// MissingPluginException.
export 'home_widget_stub.dart' if (dart.library.io) 'home_widget_io.dart';
