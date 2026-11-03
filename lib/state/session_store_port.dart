/// The slice of storage ContactService needs. SessionStore satisfies it.
abstract class KeyValueStore {
  String? read(String key);
  void write(String key, String value);
}
