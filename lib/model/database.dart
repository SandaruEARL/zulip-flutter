import 'package:drift/drift.dart';
import 'package:drift/internal/versioned_schema.dart';
import 'package:drift/remote.dart';
import 'package:sqlite3/common.dart';

import '../log.dart';
import 'schema_versions.g.dart';
import 'settings.dart';

part 'database.g.dart';

/// The table of one [GlobalSettingsData] record, the user's chosen settings
/// on this client that are independent of account.
///
/// These apply across all the user's accounts on this client (i.e. on this
/// install of the app on this device).
///
/// This table should always have exactly one row (it's created by a migration).
@DataClassName('GlobalSettingsData')
class GlobalSettings extends Table {
  Column<String> get themeSetting => textEnum<ThemeSetting>()
    .nullable()();

  Column<String> get browserPreference => textEnum<BrowserPreference>()
    .nullable()();
}

/// The table of [Account] records in the app's database.
class Accounts extends Table {
  /// The ID of this account in the app's local database.
  ///
  /// This uniquely identifies the account within this install of the app,
  /// and never changes for a given account.  It has no meaning to the server,
  /// though, or anywhere else outside this install of the app.
  Column<int>    get id => integer().autoIncrement()();

  /// The URL of the Zulip realm this account is on.
  ///
  /// This corresponds to [GetServerSettingsResult.realmUrl].
  /// It never changes for a given account.
  Column<String> get realmUrl => text().map(const UriConverter())();

  /// The Zulip user ID of this account.
  ///
  /// This is the identifier the server uses for the account.
  /// It never changes for a given account.
  Column<int>    get userId => integer()();

  Column<String> get email => text()();
  Column<String> get apiKey => text()();

  Column<String> get zulipVersion => text()();
  Column<String> get zulipMergeBase => text().nullable()();
  Column<int>    get zulipFeatureLevel => integer()();

  Column<String> get ackedPushToken => text().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {realmUrl, userId},
    {realmUrl, email},
  ];
}

class UriConverter extends TypeConverter<Uri, String> {
  const UriConverter();
  @override String toSql(Uri value) => value.toString();
  @override Uri fromSql(String fromDb) => Uri.parse(fromDb);
}

// TODO(drift): generate this
VersionedSchema _getSchema({
  required DatabaseConnectionUser database,
  required int schemaVersion,
}) {
  switch (schemaVersion) {
    case 2:
      return Schema2(database: database);
    case 3:
      return Schema3(database: database);
    case 4:
      return Schema4(database: database);
    case 5:
      return Schema5(database: database);
    default:
      throw Exception('unknown schema version: $schemaVersion');
  }
}

@DriftDatabase(tables: [GlobalSettings, Accounts])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  // When updating the schema:
  //  * Make the change in the table classes, and bump schemaVersion.
  //  * Export the new schema and generate test migrations with drift:
  //    $ tools/check --fix drift
  //    and generate database code with build_runner.
  //    See ../../README.md#generated-files for more
  //    information on using the build_runner.
  //  * Update [_getSchema] to handle the new schemaVersion.
  //  * Write a migration in `_migrationSteps` below.
  //  * Write tests.
  @override
  int get schemaVersion => 5; // See note.

  static Future<void> _dropAndCreateAll(Migrator m, {
    required int schemaVersion,
  }) async {
    await m.database.transaction(() async {
      final query = m.database.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table'");
      for (final row in await query.get()) {
        final data = row.data;
        final tableName = data['name'] as String;
        // Skip sqlite-internal tables.  See for comparison:
        //   https://www.sqlite.org/fileformat2.html#intschema
        //   https://github.com/simolus3/drift/blob/0901c984a/drift_dev/lib/src/services/schema/verifier_common.dart#L9-L22
        if (tableName.startsWith('sqlite_')) continue;
        // No need to worry about SQL injection; this table name
        // was already a table name in the database, not something
        // that should be affected by user data.
        await m.database.customStatement('DROP TABLE $tableName');
      }
      final schema = _getSchema(database: m.database, schemaVersion: schemaVersion);
      for (final entity in schema.entities) {
        await m.create(entity);
      }
    });
  }

  static final MigrationStepWithVersion _migrationSteps = migrationSteps(
    from1To2: (m, schema) async {
      await m.addColumn(schema.accounts, schema.accounts.ackedPushToken);
    },
    from2To3: (m, schema) async {
      await m.createTable(schema.globalSettings);
    },
    from3To4: (m, schema) async {
      await m.addColumn(
        schema.globalSettings, schema.globalSettings.browserPreference);
    },
    from4To5: (m, schema) async {
      // Corresponds to the `into(globalSettings).insert` in `onCreate`.
      // This migration ensures there is a row in GlobalSettings.
      // (If the app already ran at schema 3 or 4, there will be;
      // if not, there won't be before this point.)
      await m.database.transaction(() async {
        final rows = await m.database.select(schema.globalSettings).get();
        if (rows.isEmpty) {
          await m.database.into(schema.globalSettings).insert(
            // No field values; just use the defaults for both fields.
            // (This is like `GlobalSettingsCompanion.insert()`, but
            // without dependence on the current schema.)
            RawValuesInsertable({}));
        }
      });
    },
  );

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        // Corresponds to `from4to5` above.
        await into(globalSettings).insert(GlobalSettingsCompanion());
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from > to) {
          // This should only ever happen in dev.  As a dev convenience,
          // drop everything from the database and start over.
          // TODO(log): log schema downgrade as an error
          assert(debugLog('Downgrading schema from v$from to v$to.'));
          await _dropAndCreateAll(m, schemaVersion: to);
          return;
        }
        assert(1 <= from && from <= to && to <= schemaVersion);

        await m.runMigrationSteps(from: from, to: to, steps: _migrationSteps);
      });
  }

  Future<GlobalSettingsData> getGlobalSettings() async {
    // The migrations ensure there is a row.
    return await (select(globalSettings)..limit(1)).getSingle();
  }

  Future<int> createAccount(AccountsCompanion values) async {
    try {
      return await into(accounts).insert(values);
    } catch (e) {
      // Unwrap cause if it's a remote Drift call. On the app, it's running
      // via a remote, but on local tests, it's running natively so
      // unwrapping is not required.
      final cause = (e is DriftRemoteException) ? e.remoteCause : e;
      if (cause case SqliteException(
              extendedResultCode: SqlExtendedError.SQLITE_CONSTRAINT_UNIQUE)) {
        throw AccountAlreadyExistsException();
      }
      rethrow;
    }
  }
}

class AccountAlreadyExistsException implements Exception {}
