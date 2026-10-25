import 'package:flutter_test/flutter_test.dart';
import 'package:gymflow/repositories/data_store.dart';
import 'package:gymflow/repositories/sqlite_data_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Dépôt SQLite réel (via sqflite_common_ffi sur PC) : écriture, lecture,
/// mise à jour, suppression et métadonnées.
void main() {
  setUpAll(sqfliteFfiInit);

  test('aller-retour SQLite des documents', () async {
    final store = SqliteDataStore(
      fileName: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    await store.open();
    await store.put(Collections.users, 'u1', {'id': 'u1', 'fullName': 'Nour'});
    await store.putAll(Collections.users, {
      'u2': {'id': 'u2', 'fullName': 'Ahmed'},
      'u1': {'id': 'u1', 'fullName': 'Nour Ben Ammar'},
    });
    final users = await store.loadAll(Collections.users);
    expect(users.length, 2);
    expect(
      users.firstWhere((u) => u['id'] == 'u1')['fullName'],
      'Nour Ben Ammar',
    );
    await store.delete(Collections.users, 'u2');
    expect((await store.loadAll(Collections.users)).length, 1);
    await store.setMeta('seed_version', '1');
    expect(await store.getMeta('seed_version'), '1');
    await store.clear();
    expect(await store.loadAll(Collections.users), isEmpty);
  });

  test('une base installée en version 1 passe en version 2 sans perte',
      () async {
    final nom = 'ancienne_${DateTime.now().microsecondsSinceEpoch}.db';
    final fichier = p.join(await databaseFactoryFfi.getDatabasesPath(), nom);
    try {
      // 1. Une vraie base « version 1 » : aucune table `analytics`, des
      //    données déjà présentes, comme sur un téléphone déjà installé.
      final ancienne = await databaseFactoryFfi.openDatabase(
        fichier,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final c in Collections.all.where(
              (c) => c != Collections.analytics,
            )) {
              await db.execute(
                'CREATE TABLE $c (id TEXT PRIMARY KEY, data TEXT NOT NULL, '
                'updated_at INTEGER NOT NULL)',
              );
            }
            await db.execute(
              'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
            await db.insert(Collections.users, {
              'id': 'u1',
              'data': '{"id":"u1","fullName":"Nour"}',
              'updated_at': 1,
            });
            await db.insert('meta', {'key': 'seed_version', 'value': '1'});
          },
        ),
      );
      expect(
        await ancienne.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'analytics'",
        ),
        isEmpty,
        reason: 'la base de départ ne connaît pas encore la collection',
      );
      await ancienne.close();

      // 2. Ouverture par le nouveau code : la table apparaît, rien n'est perdu.
      final store = SqliteDataStore(fileName: nom, factory: databaseFactoryFfi);
      await store.open();
      expect(
        (await store.loadAll(Collections.users)).single['fullName'],
        'Nour',
        reason: 'les données existantes sont intactes',
      );
      expect(await store.getMeta('seed_version'), '1');
      await store.put(Collections.analytics, 'a', {'id': 'a', 'count': 1});
      expect((await store.loadAll(Collections.analytics)).length, 1);
    } finally {
      await databaseFactoryFfi.deleteDatabase(fichier);
    }
  });
}
