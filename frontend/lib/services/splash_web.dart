// Web splash: drives the HTML/JS boot splash in index.html via two globals.
import 'dart:js_interop';

@JS('__splashProgress')
external void _splashProgress(int percent, String message);

@JS('__splashDone')
external void _splashDone();

void splashProgress(int percent, String message) {
  try {
    _splashProgress(percent, message);
  } catch (_) {
    /* splash already dismissed / absent */
  }
}

void splashDone() {
  try {
    _splashDone();
  } catch (_) {
    /* swallow */
  }
}
