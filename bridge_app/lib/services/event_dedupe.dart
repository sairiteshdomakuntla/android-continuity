/// Capped in-memory deduplication store.
/// Oldest entries are evicted when [maxSize] is exceeded.
class EventDedupe {
  final int maxSize;
  final Set<String> _ids = {};
  final List<String> _queue = [];

  EventDedupe({this.maxSize = 200});

  bool has(String id) => _ids.contains(id);

  void add(String id) {
    if (_ids.contains(id)) return;
    if (_queue.length >= maxSize) {
      final oldest = _queue.removeAt(0);
      _ids.remove(oldest);
    }
    _ids.add(id);
    _queue.add(id);
  }
}
