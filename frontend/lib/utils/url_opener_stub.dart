// VM/non-web implementation of the URL-opener seam. Used under
// `flutter test`, where there is no browser window to hand off to —
// a deliberate no-op (tests never exercise the real download path).
void openUrlSameTab(String url) {}
