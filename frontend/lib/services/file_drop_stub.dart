// Non-web no-op for the global file-drop listener. The import screen only
// constructs and attaches this under `kIsWeb`, so on native these are never
// wired to anything — the stub just satisfies the compiler with the same API.
import 'package:file_picker/file_picker.dart';

typedef DroppedFilesCallback = void Function(List<PlatformFile> files);
typedef DragStateCallback = void Function(bool isDragging);
typedef ReadingStartCallback = void Function(int? fileCount);

class GlobalFileDropListener {
  final DroppedFilesCallback onFiles;
  final DragStateCallback onDragState;
  final ReadingStartCallback? onReadingStart;
  final Iterable<String> allowedExtensions;

  GlobalFileDropListener({
    required this.onFiles,
    required this.onDragState,
    this.onReadingStart,
    this.allowedExtensions = const ['csv', 'pdf'],
  });

  void attach() {}
  void detach() {}
}
