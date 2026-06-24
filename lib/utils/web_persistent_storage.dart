import 'web_persistent_storage_stub.dart'
    if (dart.library.html) 'web_persistent_storage_web.dart' as impl;

/// Requests durable (non-evictable) browser storage on web; no-op on native.
Future<bool> requestPersistentStorage() => impl.requestPersistentStorage();
