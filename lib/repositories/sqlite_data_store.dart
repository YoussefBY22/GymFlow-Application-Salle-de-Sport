import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/json.dart';
import 'data_store.dart';

/// Persistance SQLite (sqflite). Chaque collection est une table
/// `(id TEXT PRIMARY KEY, data TEXT, updated_at INTEGER)` où `data`
/// contient le document JSON. Les relations sont résolues par les services.
class SqliteDataStore implements DataStore {
  SqliteDataStore({this.fileName = 'gymflow.db', this.factory});

  final String fileName;

  /// Fabrique injectable (sqflite_common_ffi dans les tests sur PC).
  final DatabaseFactory? factory;

  /// Version du schéma. 2 : ajout de la collection `analytics`. Une base
  /// déjà installée (un téléphone, par exemple) passe de 1 à 2 sans perdre
  /// la moindre donnée : voir `onUpgrade`.
  static const int schemaVersion = 2;

  Database? _db;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('Base de données non ouverte.');
    }
    return db;
  }

  static String _createTable(String name, {bool ifNotExists = false}) =>
      'CREATE TABLE ${ifNotExists ? 'IF NOT EXISTS ' : ''}$name '
      '(id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at INTEGER NOT NULL)';

  @override
  Future<void> open() async {
    final f = factory ?? databaseFactory;
    final path = fileName == inMemoryDatabasePath
        ? inMemoryDatabasePath
        : p.join(await f.getDatabasesPath(), fileName);
    _db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, version) async {
          final batch = db.batch();
          for (final c in Collections.all) {
            batch.execute(_createTable(c));
          }
          batch.execute(
            'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await batch.commit(noResult: true);
        },
        // Montée de version : on ne crée que les tables qui manquent
        // (`IF NOT EXISTS`), les données existantes ne sont jamais touchées.
        onUpgrade: (db, oldVersion, newVersion) async {
          final batch = db.batch();
          for (final c in Collections.all) {
            batch.execute(_createTable(c, ifNotExists: true));
          }
          await batch.commit(noResult: true);
        },
      ),
    );
  }

  @override
  Future<List<Json>> loadAll(String collection) async {
    final rows = await _database.query(collection, columns: ['data']);
    return rows
        .map((r) => Map<String, dynamic>.from(jsonDecode(r['data'] as String)))
        .toList();
  }

  @override
  Future<void> put(String collection, String id, Json data) async {
    await _database.insert(collection, {
      'id': id,
      'data': jsonEncode(data),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> putAll(String collection, Map<String, Json> docs) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.transaction((txn) async {
      final batch = txn.batch();
      docs.forEach((id, data) {
        batch.insert(collection, {
          'id': id,
          'data': jsonEncode(data),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> delete(String collection, String id) async {
    await _database.delete(collection, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<String?> getMeta(String key) async {
    final rows = await _database.query(
      'meta',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> setMeta(String key, String value) async {
    await _database.insert('meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clear() async {
    await _database.transaction((txn) async {
      for (final c in [...Collections.all, 'meta']) {
        await txn.delete(c);
      }
    });
  }
}
