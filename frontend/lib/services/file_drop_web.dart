import 'dart:async';
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Callback fired with the (filtered, byte-loaded) files dropped onto
/// the page. Files outside [allowedExtensions] are silently dropped
/// from the list before the callback fires.
typedef DroppedFilesCallback = void Function(List<PlatformFile> files);

/// Fired whenever the page transitions between "a file is being
/// dragged over us" and "no drag in progress". Hosts use it to flip
/// a hover state on the drop zone.
typedef DragStateCallback = void Function(bool isDragging);

/// Fired the moment a drop event lands but BEFORE we start reading
/// file bytes. The host can show "Reading N files…" while the
/// FileReader chews through each PDF — for a big batch (a year of
/// monthly Banamex statements at ~200 KB each) the read step alone
/// can run several seconds, and the old behaviour showed nothing
/// until every file finished. The count is the raw size of the
/// browser-supplied FileList — pre-filter, so non-CSV/PDF entries
/// the user dropped by accident still contribute to it.
typedef ReadingStartCallback = void Function(int fileCount);

/// Attaches drag-and-drop listeners to the document so files can be
/// dropped anywhere on the page and routed into the existing import
/// pipeline. We attach globally rather than to a specific element
/// because Flutter's render layer doesn't expose stable DOM nodes
/// for arbitrary widgets — global capture is simpler and there are
/// no competing drop targets on the page.
///
/// Lifecycle: construct in initState → call [attach]; call [detach]
/// from dispose. Construction is cheap (just builds the JS function
/// references); the actual listeners only live on the document while
/// attached.
///
/// `dragenter` / `dragleave` use a counter pattern because both fire
/// on every child-element boundary as the cursor moves. Without the
/// counter the hover state flickers off and on as the user drags
/// past nested elements.
class GlobalFileDropListener {
  final DroppedFilesCallback onFiles;
  final DragStateCallback onDragState;
  /// Optional — fired the moment a drop is detected so the host can
  /// render a loading state during the byte-read phase. Skipped when
  /// the host doesn't care (e.g. a no-op preview screen).
  final ReadingStartCallback? onReadingStart;
  final Iterable<String> allowedExtensions;

  late final JSExportedDartFunction _dragEnter;
  late final JSExportedDartFunction _dragOver;
  late final JSExportedDartFunction _dragLeave;
  late final JSExportedDartFunction _drop;

  int _dragCounter = 0;
  bool _attached = false;

  GlobalFileDropListener({
    required this.onFiles,
    required this.onDragState,
    this.onReadingStart,
    this.allowedExtensions = const ['csv', 'pdf'],
  }) {
    _dragEnter = ((web.Event e) {
      e.preventDefault();
      _dragCounter++;
      if (_dragCounter == 1) onDragState(true);
    }).toJS;

    _dragOver = ((web.Event e) {
      // Required: without preventDefault on dragover, the browser
      // never fires the subsequent `drop` event (this is the #1
      // reason DIY drop zones silently don't work).
      e.preventDefault();
    }).toJS;

    _dragLeave = ((web.Event e) {
      e.preventDefault();
      _dragCounter--;
      if (_dragCounter <= 0) {
        _dragCounter = 0;
        onDragState(false);
      }
    }).toJS;

    _drop = ((web.Event e) {
      e.preventDefault();
      _dragCounter = 0;
      onDragState(false);
      final dragEvent = e as web.DragEvent;
      final dt = dragEvent.dataTransfer;
      if (dt == null) return;

      // Capture FileSystemEntry handles SYNCHRONOUSLY — the DataTransfer
      // items are only valid during this event. A dropped DIRECTORY shows up
      // here as a directory entry we walk recursively (a plain `dt.files`
      // would contain a single unreadable directory pseudo-file, which is why
      // dropping a folder used to hang on "Reading 1 file…"). Browsers
      // without the entries API return null entries → we fall back to the
      // flat file list captured below.
      final entries = <web.FileSystemEntry>[];
      final items = dt.items;
      for (var i = 0; i < items.length; i++) {
        final entry = items[i].webkitGetAsEntry();
        if (entry != null) entries.add(entry);
      }
      final flat = <web.File>[];
      final fl = dt.files;
      for (var i = 0; i < fl.length; i++) {
        final f = fl.item(i);
        if (f != null) flat.add(f);
      }

      // Initial estimate; refined to the true file count after directories
      // are expanded (see _collectAndDispatch).
      onReadingStart?.call(entries.isNotEmpty ? entries.length : flat.length);
      // Fire-and-forget — readers complete on microtasks, the host gets the
      // list once everything (incl. nested directory files) is loaded.
      unawaited(_collectAndDispatch(entries, flat));
    }).toJS;
  }

  void attach() {
    if (_attached) return;
    final doc = web.document;
    doc.addEventListener('dragenter', _dragEnter);
    doc.addEventListener('dragover', _dragOver);
    doc.addEventListener('dragleave', _dragLeave);
    doc.addEventListener('drop', _drop);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    final doc = web.document;
    doc.removeEventListener('dragenter', _dragEnter);
    doc.removeEventListener('dragover', _dragOver);
    doc.removeEventListener('dragleave', _dragLeave);
    doc.removeEventListener('drop', _drop);
    _attached = false;
  }

  /// Expand any dropped directories into their files, then read + dispatch.
  Future<void> _collectAndDispatch(
    List<web.FileSystemEntry> entries,
    List<web.File> flat,
  ) async {
    final files = <web.File>[];
    if (entries.isNotEmpty) {
      for (final entry in entries) {
        await _collectEntry(entry, files);
      }
    } else {
      files.addAll(flat);
    }
    // Now that directories are expanded, refine the "Reading N files…" count.
    onReadingStart?.call(files.length);
    await _readAndDispatch(files);
  }

  /// Recursively walk a FileSystemEntry, appending every file it contains to
  /// [out]. Directories are read in batches (browsers cap `readEntries` at
  /// ~100 per call, so we loop until it returns empty).
  Future<void> _collectEntry(
    web.FileSystemEntry entry,
    List<web.File> out,
  ) async {
    if (entry.isFile) {
      final fileEntry = entry as web.FileSystemFileEntry;
      final c = Completer<web.File?>();
      fileEntry.file(
        ((web.File f) => c.complete(f)).toJS,
        ((web.DOMException _) => c.complete(null)).toJS,
      );
      final f = await c.future;
      if (f != null) out.add(f);
    } else if (entry.isDirectory) {
      final reader = (entry as web.FileSystemDirectoryEntry).createReader();
      while (true) {
        final batch = await _readBatch(reader);
        if (batch.isEmpty) break;
        for (final child in batch) {
          await _collectEntry(child, out);
        }
      }
    }
  }

  Future<List<web.FileSystemEntry>> _readBatch(
    web.FileSystemDirectoryReader reader,
  ) {
    final c = Completer<List<web.FileSystemEntry>>();
    reader.readEntries(
      ((JSArray<web.FileSystemEntry> entries) {
        c.complete(entries.toDart);
      }).toJS,
      ((web.DOMException _) => c.complete(const [])).toJS,
    );
    return c.future;
  }

  Future<void> _readAndDispatch(List<web.File> files) async {
    final accepted = <PlatformFile>[];
    final rejected = <String>[];
    for (final file in files) {
      final lower = file.name.toLowerCase();
      final matches =
          allowedExtensions.any((ext) => lower.endsWith('.${ext.toLowerCase()}'));
      if (!matches) {
        rejected.add(file.name);
        continue;
      }
      try {
        final bytes = await _readFileBytes(file);
        accepted.add(PlatformFile(
          name: file.name,
          size: file.size,
          bytes: bytes,
        ));
      } catch (e) {
        debugPrint('Failed to read dropped file ${file.name}: $e');
      }
    }
    if (rejected.isNotEmpty) {
      debugPrint('Rejected non-importable files: ${rejected.join(", ")}');
    }
    // ALWAYS dispatch — even an empty list — so the host clears its
    // "Reading…" state instead of hanging when a drop yields no importable
    // files (the bug that froze "Reading 1 file…" on a dropped folder).
    onFiles(accepted);
  }

  Future<Uint8List> _readFileBytes(web.File file) async {
    final arrayBuffer = await file.arrayBuffer().toDart;
    return arrayBuffer.toDart.asUint8List();
  }
}
