import 'book_search_service.dart';
import 'book_search_sources.dart';
import 'store.dart';
import 'web_service.dart';

class BookSearchPlugin {
  BookSearchPlugin(
    this.store, {
    WebService Function(void Function())? webService,
    BookSearchProvider? find,
    BookSearchFileAcquirer? acquire,
    BookSearchSourceInspector? inspect,
  }) {
    final sources = BookSearchSources(webService: webService);
    searches = BookSearchService(
      store: store,
      find: find ?? sources.searchByCriteria,
      acquire: acquire ?? sources.acquire,
      inspect: inspect ?? sources.inspect,
    );
  }

  final CloudStore store;
  late final BookSearchService searches;

  bool enabled(String deviceKey) {
    final device = store.get(deviceKey)?.value;
    return device != null &&
        device['revoked_at'] == null &&
        device['online_book_search_enabled'] != false;
  }

  void setEnabled(String deviceKey, bool enabled) {
    final device = store.get(deviceKey);
    if (device == null || device.value['revoked_at'] != null) {
      throw const BookSearchException(401, '登录状态已失效，请重新登录');
    }
    if (device.value['online_book_search_enabled'] != enabled) {
      store.put(deviceKey, {
        ...device.value,
        'online_book_search_enabled': enabled,
      }, device.revision);
    }
    if (!enabled) searches.stopOwner(deviceKey);
  }
}
