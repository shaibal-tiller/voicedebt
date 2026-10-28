// ============================================================================
// VoiceDebt - 100% Free, Offline, Multilingual Voice-First Debt Tracker
// Languages: বাংলা (Bangla), Banglish (Phonetic Bengali), and English
// Framework: Flutter (Dart)
// Local Database: sqflite (Embedded SQLite, Zero Cloud Costs)
// Voice Engine: speech_to_text (Native Android Offline Speech Recognition)
// State Management: provider
// Android Shortcuts: quick_actions (Home screen shortcut & hardware gestures)
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:sqflite/sqflite.dart';

// ============================================================================
// SECTION 1: CORE DATA MODELS
// ============================================================================

enum TransactionType {
  lent_to,            // I gave money -> They owe me (+ balance)
  borrowed_from,      // I took money -> I owe them (- balance)
  repayment_received, // They gave me money back -> Their debt decreases (- balance)
  repayment_made,     // I gave money back -> My debt decreases (+ balance towards 0)
}

extension TransactionTypeExt on TransactionType {
  String get label {
    switch (this) {
      case TransactionType.lent_to:
        return 'Lent To (দিলাম)';
      case TransactionType.borrowed_from:
        return 'Borrowed From (নিলাম)';
      case TransactionType.repayment_received:
        return 'Repayment Received (ফেরত দিল)';
      case TransactionType.repayment_made:
        return 'Repayment Made (ফেরত দিলাম)';
    }
  }

  Color get color {
    switch (this) {
      case TransactionType.lent_to:
        return const Color(0xFF10B981); // Emerald
      case TransactionType.borrowed_from:
        return const Color(0xFFF43F5E); // Rose
      case TransactionType.repayment_received:
        return const Color(0xFF06B6D4); // Cyan
      case TransactionType.repayment_made:
        return const Color(0xFF8B5CF6); // Purple
    }
  }

  IconData get icon {
    switch (this) {
      case TransactionType.lent_to:
        return Icons.arrow_outward_rounded;
      case TransactionType.borrowed_from:
        return Icons.arrow_downward_rounded;
      case TransactionType.repayment_received:
        return Icons.check_circle_outline_rounded;
      case TransactionType.repayment_made:
        return Icons.task_alt_rounded;
    }
  }

  double get multiplier {
    switch (this) {
      case TransactionType.lent_to:
        return 1.0;
      case TransactionType.borrowed_from:
        return -1.0;
      case TransactionType.repayment_received:
        return -1.0;
      case TransactionType.repayment_made:
        return 1.0;
    }
  }
}

class Person {
  final int? id;
  final String name;
  final double netBalance;

  Person({
    this.id,
    required this.name,
    required this.netBalance,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'netBalance': netBalance,
    };
  }

  factory Person.fromMap(Map<String, dynamic> map) {
    return Person(
      id: map['id'] as int?,
      name: map['name'] as String,
      netBalance: (map['netBalance'] as num).toDouble(),
    );
  }
}

class TransactionItem {
  final int? id;
  final int personId;
  final double amount;
  final TransactionType type;
  final DateTime timestamp;
  final String? note;

  TransactionItem({
    this.id,
    required this.personId,
    required this.amount,
    required this.type,
    required this.timestamp,
    this.note,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'personId': personId,
      'amount': amount,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'note': note,
    };
  }

  factory TransactionItem.fromMap(Map<String, dynamic> map) {
    return TransactionItem(
      id: map['id'] as int?,
      personId: map['personId'] as int,
      amount: (map['amount'] as num).toDouble(),
      type: TransactionType.values.byName(map['type'] as String),
      timestamp: DateTime.parse(map['timestamp'] as String),
      note: map['note'] as String?,
    );
  }
}

// ============================================================================
// SECTION 2: MULTILINGUAL VOICE PARSER (Bangla, Banglish, English & Auto-Correct)
// ============================================================================

class VoiceParseResult {
  final String rawText;
  final String? cleanedText;
  final bool isSuccess;
  final TransactionType? type;
  final String? personName;
  final double? amount;
  final String? fallbackReason;
  final String? detectedLanguage;
  final List<String> autoCorrections;
  final double confidence;

  VoiceParseResult({
    required this.rawText,
    this.cleanedText,
    required this.isSuccess,
    this.type,
    this.personName,
    this.amount,
    this.fallbackReason,
    this.detectedLanguage,
    this.autoCorrections = const [],
    this.confidence = 0.0,
  });
}

class VoiceParser {
  static const Map<String, String> _bnDigits = {
    '০': '0', '১': '1', '২': '2', '৩': '3', '৪': '4',
    '৫': '5', '৬': '6', '৭': '7', '৮': '8', '৯': '9',
  };

  static const Map<String, String> _autoCorrectMap = {
    'land': 'lent', 'send': 'lent', 'lead': 'lent',
    'baro': 'borrowed', 'boro': 'borrowed', 'barrow': 'borrowed', 'bored': 'borrowed', 'tuk': 'took',
    'retun': 'returned', 'payed': 'paid',
    'delam': 'dilam', 'deecy': 'dichi', 'diyeci': 'diyechi',
    'nelam': 'nilam', 'neyechi': 'niyechi',
    'pherot': 'ferot', 'ferat': 'ferot', 'feroth': 'ferot', 'ferod': 'ferot',
    'shod': 'shodh', 'sodh': 'shodh', 'porisodh': 'porishodh',
    'hajar': 'thousand', 'hazar': 'thousand',
  };

  static const Set<String> _stopWords = {
    'i', 'me', 'my', 'to', 'from', 'a', 'an', 'the', 'for', 'and', 'in', 'of',
    'dollars', 'dollar', 'taka', 'tk', 'rupees', 'rs', 'bucks', 'usd', 'eur', 'cash', 'money',
    'just', 'please', 'log', 'record', 'note',
    'ami', 'amake', 'amar', 'tumi', 'apni', 'ke', 'theke', 'te', 'er', 'kase', 'kaase',
    'poisa', 'ta', 'k', 'hajar', 'ekta', 'dhoro', 'bhai', 'dada',
    'dilam', 'nilam', 'ferot', 'dhar', 'karjo', 'shodh',
    'আমি', 'আমাকে', 'আমার', 'তুমি', 'আপনি', 'কে', 'থেকে', 'তে', 'টাকা', 'পয়সা', 'করে', 'দিয়ে', 'ভাই', 'দা',
    'দিলাম', 'নিলাম', 'দিয়েছি', 'দিয়েছি', 'নিয়েছি', 'নিয়েছি', 'দিছি', 'নিছি',
    'ফেরত', 'ধার', 'করজ', 'হাওলাত', 'শোধ', 'পরিশোধ', 'দিল', 'দিলো', 'পেলাম', 'পাইলাম', 'পাইছি'
  };

  static String normalizeBengaliDigits(String input) {
    String res = input;
    _bnDigits.forEach((bn, en) {
      res = res.replaceAll(bn, en);
    });
    return res;
  }

  static VoiceParseResult parse(String spokenText) {
    final raw = spokenText.trim();
    if (raw.isEmpty) {
      return VoiceParseResult(rawText: '', isSuccess: false, fallbackReason: 'No speech detected.');
    }

    String text = normalizeBengaliDigits(raw);
    final List<String> corrections = [];

    // Separate attached Banglish suffix (e.g. "rahimke" -> "rahim ke")
    text = text.replaceAllMapped(RegExp(r'([a-zA-Z]{3,})(ke|re|theke|thek|te)', caseSensitive: false), (m) {
      return '${m[1]} ${m[2]}';
    });

    // Separate attached Bangla suffix (e.g. "রহিমকে" -> "রহিম ")
    const protectedBn = {'থেকে', 'আমাকে', 'তোমাকে', 'কাকে', 'নিজেদের'};
    text = text.replaceAllMapped(RegExp(r'([ঀ-৿]{2,})(কে|রে)(?=s|$|[.,!?])'), (m) {
      if (protectedBn.contains(m[0])) return m[0]!;
      return '${m[1]} ';
    });

    // Auto-correct misheard words
    final wordsList = text.split(RegExp(r's+')).map((token) {
      final clean = token.toLowerCase().replaceAll(RegExp(r'[^a-zA-Z0-9ঀ-৿]'), '');
      if (_autoCorrectMap.containsKey(clean)) {
        corrections.add('"$token" -> "${_autoCorrectMap[clean]}"');
        return _autoCorrectMap[clean]!;
      }
      return token;
    }).toList();

    final cleaned = wordsList.join(' ');
    final lower = cleaned.toLowerCase();

    final bool isBanglaScript = RegExp(r'[ঀ-৿]').hasMatch(raw);
    final String detectedLang = isBanglaScript
        ? 'Bangla'
        : (RegExp(r'(dilam|nilam|ferot|shodh|dhar|taka|ke|theke|ami|amake)', caseSensitive: false).hasMatch(lower)
            ? 'Banglish'
            : 'English');

    TransactionType? detectedType;

    // 1. Repayment Made (I repaid)
    if (RegExp(r'(?:ফেরত দিলাম|শোধ দিলাম|শোধ করলাম|পরিশোধ করলাম|পরিশোধ দিলাম)').hasMatch(lower) ||
        RegExp(r'(is+returned|is+paid|is+gaves+back|gaves+back|paids+backs+to|repaid)').hasMatch(lower) ||
        RegExp(r'(ferots+dilam|pherots+dilam|shodhs+dilam|shodhs+korlam|sodhs+dilam|sodhs+korlam|porishodhs+korlam|amis+ferots+dilam)').hasMatch(lower)) {
      detectedType = TransactionType.repayment_made;
    }
    // 2. Repayment Received (They repaid me)
    else if (RegExp(r'(?:ফেরত দিল|ফেরত দিলো|ফেরত পেলাম|ফেরত পাইলাম|ফেরত পাইছি|শোধ দিল|শোধ দিলো)').hasMatch(lower) ||
        RegExp(r'(returned|paids+back|gots+d+|gots+from|received)').hasMatch(lower) ||
        RegExp(r'(ferots+dilo|pherots+dilo|ferots+pelam|pherots+pelam|ferots+paisi|ferots+paise)').hasMatch(lower)) {
      detectedType = TransactionType.repayment_received;
    }
    // 3. Borrow Intent (I took money)
    else if (RegExp(r'(?:ধার নিলাম|ধার নিছি|করজ নিলাম|হাওলাত নিলাম|নিলাম|নিয়েছি|নিছি|ধার নিয়েছি|ধার নিয়েছি)').hasMatch(lower) ||
        RegExp(r'(borrowed|took)').hasMatch(lower) ||
        RegExp(r'(dhars+nilam|karjos+nilam|nilam|nichi|niyechi|borrows+korlam|thekes+nilam)').hasMatch(lower)) {
      detectedType = TransactionType.borrowed_from;
    }
    // 4. Lend Intent (I gave money)
    else if (RegExp(r'(?:ধার দিলাম|ধার দিছি|করজ দিলাম|হাওলাত দিলাম|দিলাম|দিয়েছি|দিয়েছি|দিছি)').hasMatch(lower) ||
        RegExp(r'(lent|lend|gave)').hasMatch(lower) ||
        RegExp(r'(dhars+dilam|dilam|dichi|diyechi|lends+korlam|dhars+dichi)').hasMatch(lower)) {
      detectedType = TransactionType.lent_to;
    }
    // 5. Shorthand "paid"
    else if (RegExp(r'(paid)').hasMatch(lower)) {
      detectedType = TransactionType.repayment_made;
    }

    // Amount extraction
    double? amount;
    String? matchedToken;

    final kMatch = RegExp(r'(?:^|s|[.,!?])(d+(?:.d+)?)s*(?:k|thousand|হাজার|hajar|hazar)(?=s|$|[.,!?])', caseSensitive: false).firstMatch(lower);
    if (kMatch != null && kMatch.group(1) != null) {
      amount = double.tryParse(kMatch.group(1)!)! * 1000.0;
      matchedToken = kMatch.group(0);
    } else {
      final numMatch = RegExp(r'(?:[$€£₹৳]s*|tks*|takas*)?(d+(?:.d+)?|d{1,3}(?:,d{3})+(?:.d+)?)', caseSensitive: false).firstMatch(lower);
      if (numMatch != null && numMatch.group(1) != null) {
        amount = double.tryParse(numMatch.group(1)!.replaceAll(',', ''));
        matchedToken = numMatch.group(0);
      }
    }

    // Name extraction
    String remainder = lower;
    if (matchedToken != null) {
      remainder = remainder.replaceAll(matchedToken.toLowerCase(), ' ');
    }

    final phrasesToRemove = [
      'i returned', 'i paid', 'i gave back', 'paid back', 'gave back',
      'i lent', 'i borrowed', 'i took', 'i gave', 'lent', 'lend', 'gave',
      'borrowed', 'took', 'returned', 'paid', 'got', 'received',
      'ফেরত দিলাম', 'ফেরত দিল', 'ফেরত দিলো', 'ফেরত পেলাম', 'ফেরত পাইলাম', 'শোধ দিলাম', 'শোধ করলাম', 'শোধ দিল',
      'ধার নিলাম', 'ধার দিলাম', 'করজ নিলাম', 'করজ দিলাম', 'হাওলাত নিলাম', 'হাওলাত দিলাম',
      'দিয়েছি', 'দিয়েছি', 'দিলাম', 'দিছি', 'নিয়েছি', 'নিয়েছি', 'নিলাম', 'নিছি',
      'ferot dilam', 'ferot dilo', 'ferot pelam', 'ferot paisi', 'pherot dilam', 'pherot dilo',
      'shodh korlam', 'shodh dilam', 'sodh korlam', 'sodh dilam', 'porishodh korlam',
      'dhar dilam', 'dhar nilam', 'karjo dilam', 'karjo nilam', 'dhar dichi',
      'dilam', 'dichi', 'diyechi', 'nilam', 'nichi', 'niyechi'
    ];

    for (final p in phrasesToRemove) {
      if (RegExp(r'[ঀ-৿]').hasMatch(p)) {
        remainder = remainder.replaceAll(p, ' ');
      } else {
        remainder = remainder.replaceAll(RegExp(r'' + p + r'', caseSensitive: false), ' ');
      }
    }

    final tokens = remainder
        .replaceAll(RegExp(r'[^a-zA-Z0-9ঀ-৿s]'), ' ')
        .split(RegExp(r's+'))
        .where((w) => w.isNotEmpty && !_stopWords.contains(w) && !RegExp(r'^d+$').hasMatch(w))
        .toList();

    String? personName;
    if (tokens.isNotEmpty) {
      personName = tokens.take(2).map((w) {
        if (RegExp(r'[ঀ-৿]').hasMatch(w)) return w;
        return w[0].toUpperCase() + w.substring(1).toLowerCase();
      }).join(' ');
    }

    final isSuccess = detectedType != null && amount != null && amount > 0 && personName != null;
    String? fallbackReason;

    if (detectedType == null) {
      fallbackReason = detectedLang == 'Bangla'
          ? 'উদ্দেশ্য (ধার দেওয়া, ধার নেওয়া, বা ফেরত) শনাক্ত করা যায়নি।'
          : "Couldn't detect intent (Lend, Borrow, or Repay).";
    } else if (amount == null) {
      fallbackReason = detectedLang == 'Bangla' ? 'টাকার পরিমাণ শনাক্ত করা যায়নি।' : "Couldn't extract amount.";
    } else if (personName == null) {
      fallbackReason = detectedLang == 'Bangla' ? 'ব্যক্তির নাম শনাক্ত করা যায়নি।' : "Couldn't find person name.";
    }

    return VoiceParseResult(
      rawText: raw,
      cleanedText: cleaned,
      isSuccess: isSuccess,
      type: detectedType,
      personName: personName,
      amount: amount,
      fallbackReason: isSuccess ? null : fallbackReason,
      detectedLanguage: detectedLang,
      autoCorrections: corrections,
      confidence: isSuccess ? 0.95 : 0.4,
    );
  }
}

// ============================================================================
// SECTION 3: LOCAL SQLITE DATABASE HELPER (With People Management)
// ============================================================================

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('voicedebt.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE people (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL COLLATE NOCASE,
        netBalance REAL NOT NULL DEFAULT 0.0
      )
    ''');

    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        personId INTEGER NOT NULL,
        amount REAL NOT NULL,
        type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        note TEXT,
        FOREIGN KEY (personId) REFERENCES people (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<List<Person>> getAllPeople() async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT * FROM people 
      ORDER BY ABS(netBalance) DESC, name ASC
    ''');
    return result.map((map) => Person.fromMap(map)).toList();
  }

  Future<int> addPerson(String name) async {
    final db = await instance.database;
    return await db.insert('people', {
      'name': name.trim(),
      'netBalance': 0.0,
    });
  }

  Future<void> renamePerson(int id, String newName) async {
    final db = await instance.database;
    await db.update(
      'people',
      {'name': newName.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePerson(int id) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.delete('transactions', where: 'personId = ?', whereArgs: [id]);
      await txn.delete('people', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> settlePerson(int id) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      final res = await txn.query('people', where: 'id = ?', whereArgs: [id], limit: 1);
      if (res.isNotEmpty) {
        final bal = (res.first['netBalance'] as num).toDouble();
        if (bal != 0) {
          final settleType = bal > 0 ? TransactionType.repayment_received : TransactionType.repayment_made;
          await txn.insert('transactions', {
            'personId': id,
            'amount': bal.abs(),
            'type': settleType.name,
            'timestamp': DateTime.now().toIso8601String(),
            'note': 'Marked balance settled / forgiven',
          });
          await txn.update('people', {'netBalance': 0.0}, where: 'id = ?', whereArgs: [id]);
        }
      }
    });
  }

  Future<List<TransactionItem>> getTransactionsForPerson(int personId) async {
    final db = await instance.database;
    final result = await db.query(
      'transactions',
      where: 'personId = ?',
      whereArgs: [personId],
      orderBy: 'timestamp DESC',
    );
    return result.map((map) => TransactionItem.fromMap(map)).toList();
  }

  Future<Map<String, double>> getSummaryTotals() async {
    final db = await instance.database;
    final people = await db.query('people');

    double owedToMe = 0.0;
    double iOwe = 0.0;

    for (final row in people) {
      final balance = (row['netBalance'] as num).toDouble();
      if (balance > 0) {
        owedToMe += balance;
      } else if (balance < 0) {
        iOwe += balance.abs();
      }
    }

    return {'owedToMe': owedToMe, 'iOwe': iOwe};
  }

  Future<void> recordTransaction({
    required String personName,
    required double amount,
    required TransactionType type,
    String? note,
  }) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'people',
        where: 'name = ? COLLATE NOCASE',
        whereArgs: [personName.trim()],
        limit: 1,
      );

      int personId;
      double currentBalance = 0.0;

      if (existing.isNotEmpty) {
        personId = existing.first['id'] as int;
        currentBalance = (existing.first['netBalance'] as num).toDouble();
      } else {
        personId = await txn.insert('people', {
          'name': personName.trim(),
          'netBalance': 0.0,
        });
      }

      await txn.insert('transactions', {
        'personId': personId,
        'amount': amount,
        'type': type.name,
        'timestamp': DateTime.now().toIso8601String(),
        'note': note,
      });

      final delta = amount * type.multiplier;
      final newBalance = currentBalance + delta;

      await txn.update(
        'people',
        {'netBalance': newBalance},
        where: 'id = ?',
        whereArgs: [personId],
      );
    });
  }

  Future<void> deleteTransaction(int transactionId, int personId) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      await txn.delete('transactions', where: 'id = ?', whereArgs: [transactionId]);

      final remaining = await txn.query('transactions', where: 'personId = ?', whereArgs: [personId]);

      double recalculated = 0.0;
      for (final tx in remaining) {
        final amt = (tx['amount'] as num).toDouble();
        final type = TransactionType.values.byName(tx['type'] as String);
        recalculated += amt * type.multiplier;
      }

      await txn.update(
        'people',
        {'netBalance': recalculated},
        where: 'id = ?',
        whereArgs: [personId],
      );
    });
  }
}

// ============================================================================
// SECTION 4: STATE MANAGEMENT (Provider)
// ============================================================================

class AppProvider with ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final QuickActions _quickActions = const QuickActions();

  List<Person> _people = [];
  double _totalOwedToMe = 0.0;
  double _totalIOwe = 0.0;
  bool _isLoading = true;

  // Language settings: bn_BD (Bangla), auto/en_US (English/Banglish)
  String _selectedLanguage = 'auto';
  bool _isSpeechAvailable = false;
  bool _isListening = false;
  String _currentWords = '';
  VoiceParseResult? _lastParseResult;
  String? _speechErrorMessage;

  List<Person> get people => _people;
  double get totalOwedToMe => _totalOwedToMe;
  double get totalIOwe => _totalIOwe;
  bool get isLoading => _isLoading;
  bool get isListening => _isListening;
  String get selectedLanguage => _selectedLanguage;
  String get currentWords => _currentWords;
  VoiceParseResult? get lastParseResult => _lastParseResult;
  String? get speechErrorMessage => _speechErrorMessage;

  AppProvider() {
    _init();
  }

  Future<void> _init() async {
    await refreshData();
    await _initSpeech();
    _initQuickActions();
    _isLoading = false;
    notifyListeners();
  }

  void setLanguage(String lang) {
    _selectedLanguage = lang;
    _speechErrorMessage = null;
    notifyListeners();
  }

  Future<void> switchLanguageAndListen(String lang) async {
    _selectedLanguage = lang;
    _speechErrorMessage = null;
    if (_isListening) {
      await _speech.stop();
    }
    await startVoiceListening();
  }

  Future<void> refreshData() async {
    _people = await _db.getAllPeople();
    final totals = await _db.getSummaryTotals();
    _totalOwedToMe = totals['owedToMe'] ?? 0.0;
    _totalIOwe = totals['iOwe'] ?? 0.0;
    notifyListeners();
  }

  Future<void> _initSpeech() async {
    try {
      _isSpeechAvailable = await _speech.initialize(
        onError: (err) {
          debugPrint('Speech error: $err');
          _isListening = false;
          if (_selectedLanguage == 'bn_BD') {
            _speechErrorMessage = 'Bengali speech requires internet on this phone. Switch to Offline Banglish ("Rahim ke 5000 dilam")!';
          } else {
            _speechErrorMessage = err.errorMsg;
          }
          notifyListeners();
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
            notifyListeners();
          }
        },
      );
    } catch (e) {
      debugPrint('Speech init failed: $e');
      _isSpeechAvailable = false;
    }
  }

  void _initQuickActions() {
    _quickActions.initialize((String shortcutType) {
      if (shortcutType == 'action_quick_listen') {
        startVoiceListening();
      }
    });

    _quickActions.setShortcutItems(<ShortcutItem>[
      const ShortcutItem(
        type: 'action_quick_listen',
        localizedTitle: 'Quick Voice Log',
        icon: 'ic_mic_shortcut',
      ),
    ]);
  }

  Future<void> startVoiceListening() async {
    if (!_isSpeechAvailable) {
      await _initSpeech();
    }

    _currentWords = '';
    _lastParseResult = null;
    _speechErrorMessage = null;
    _isListening = true;
    notifyListeners();

    if (_isSpeechAvailable) {
      // Use bn_BD for Bangla, en_US for English/Banglish
      final localeId = _selectedLanguage == 'bn_BD' ? 'bn_BD' : 'en_US';

      await _speech.listen(
        localeId: localeId,
        onResult: (SpeechRecognitionResult result) {
          _currentWords = result.recognizedWords;
          if (_currentWords.isNotEmpty) {
            _lastParseResult = VoiceParser.parse(_currentWords);
          }
          notifyListeners();
        },
        listenMode: stt.ListenMode.confirmation,
        cancelOnError: true,
      );
    }
  }

  Future<void> stopVoiceListening() async {
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
      notifyListeners();
    }
  }

  // People Management calls
  Future<void> addPerson(String name) async {
    await _db.addPerson(name);
    await refreshData();
  }

  Future<void> renamePerson(int id, String newName) async {
    await _db.renamePerson(id, newName);
    await refreshData();
  }

  Future<void> deletePerson(int id) async {
    await _db.deletePerson(id);
    await refreshData();
  }

  Future<void> settlePerson(int id) async {
    await _db.settlePerson(id);
    await refreshData();
  }

  Future<void> saveTransaction({
    required String personName,
    required double amount,
    required TransactionType type,
    String? note,
  }) async {
    await _db.recordTransaction(
      personName: personName,
      amount: amount,
      type: type,
      note: note,
    );
    await refreshData();
  }

  Future<void> deleteTransaction(int transactionId, int personId) async {
    await _db.deleteTransaction(transactionId, personId);
    await refreshData();
  }

  Future<List<TransactionItem>> getHistory(int personId) async {
    return await _db.getTransactionsForPerson(personId);
  }
}

// ============================================================================
// SECTION 5: APP ENTRY POINT & THEME
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0F172A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
      ],
      child: const VoiceDebtApp(),
    ),
  );
}

class VoiceDebtApp extends StatelessWidget {
  const VoiceDebtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceDebt',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0F1D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF111827),
          error: Color(0xFFF43F5E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0F1D),
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF151E33),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1E293B), width: 1),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

// ============================================================================
// SECTION 6: DASHBOARD SCREEN
// ============================================================================

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  final TextEditingController _searchController = TextEditingController();
  String _searchFilter = '';
  String _activeFilter = 'all';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _openVoiceSheet(BuildContext context) {
    context.read<AppProvider>().startVoiceListening();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const VoiceListeningSheet(),
    );
  }

  void _openManagePeople(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ManagePeopleScreen()),
    );
  }

  void _openManualFallbackDialog(BuildContext context, {String? prefillName, double? prefillAmount, TransactionType? prefillType}) {
    showDialog(
      context: context,
      builder: (_) => ManualEntryDialog(
        initialName: prefillName,
        initialAmount: prefillAmount,
        initialType: prefillType ?? TransactionType.lent_to,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final currency = NumberFormat.currency(symbol: r'$', decimalDigits: 0);

    final filteredPeople = provider.people.where((p) {
      if (_searchFilter.isNotEmpty && !p.name.toLowerCase().contains(_searchFilter.toLowerCase())) {
        return false;
      }
      if (_activeFilter == 'owed') return p.netBalance > 0;
      if (_activeFilter == 'iowe') return p.netBalance < 0;
      if (_activeFilter == 'settled') return p.netBalance == 0;
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.mic_none_rounded, color: Color(0xFF10B981), size: 22),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('VoiceDebt', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                Text('Bangla • Banglish • English', style: TextStyle(color: Colors.grey.shade400, fontSize: 10)),
              ],
            ),
          ],
        ),
        actions: [
          // Manage People Button
          IconButton(
            icon: const Icon(Icons.people_outline_rounded, color: Color(0xFF38BDF8)),
            tooltip: 'Manage People',
            onPressed: () => _openManagePeople(context),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded),
            tooltip: 'Manual Entry',
            onPressed: () => _openManualFallbackDialog(context),
          ),
        ],
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => provider.refreshData(),
              child: CustomScrollView(
                slivers: [
                  // KPI Banner
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF131C31), Color(0xFF1E294B)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF334155), width: 1),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                                          const SizedBox(width: 6),
                                          Text('OWED TO ME (পাবো)', style: TextStyle(color: Colors.grey.shade400, fontSize: 10, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        currency.format(provider.totalOwedToMe),
                                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF10B981)),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(width: 1, height: 46, color: const Color(0xFF334155)),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFF43F5E), shape: BoxShape.circle)),
                                          const SizedBox(width: 6),
                                          Text('TOTAL I OWE (দিতে হবে)', style: TextStyle(color: Colors.grey.shade400, fontSize: 10, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        currency.format(provider.totalIOwe),
                                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFFF43F5E)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Search & Language bar
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchController,
                              onChanged: (val) => setState(() => _searchFilter = val),
                              decoration: InputDecoration(
                                hintText: 'Search people / খুঁজুন...',
                                prefixIcon: const Icon(Icons.search, size: 18, color: Colors.grey),
                                filled: true,
                                fillColor: const Color(0xFF111827),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF1E293B))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF1E293B))),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Language Selector Chip
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
                            child: DropdownButton<String>(
                              value: provider.selectedLanguage,
                              dropdownColor: const Color(0xFF1E293B),
                              underline: const SizedBox(),
                              items: const [
                                DropdownMenuItem(value: 'auto', child: Text('⚡ Offline Banglish', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                                DropdownMenuItem(value: 'bn_BD', child: Text('🌐 Online বাংলা', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                                DropdownMenuItem(value: 'en_US', child: Text('🇺🇸 English', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                              ],
                              onChanged: (val) {
                                if (val != null) provider.setLanguage(val);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Filter Chips
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      child: Row(
                        children: [
                          _buildFilterChip('All (${provider.people.length})', 'all'),
                          const SizedBox(width: 6),
                          _buildFilterChip('Owes Me (${provider.people.where((p) => p.netBalance > 0).length})', 'owed'),
                          const SizedBox(width: 6),
                          _buildFilterChip('I Owe (${provider.people.where((p) => p.netBalance < 0).length})', 'iowe'),
                          const SizedBox(width: 6),
                          _buildFilterChip('Settled', 'settled'),
                        ],
                      ),
                    ),
                  ),

                  // People List
                  if (filteredPeople.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.record_voice_over_rounded, size: 54, color: Colors.grey.shade600),
                            const SizedBox(height: 12),
                            const Text('No records found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 40),
                              child: Text(
                                'Tap mic: "Rahim ke 5000 dilam" or "রহিমকে ৫০০০ দিলাম"',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final person = filteredPeople[index];
                            final owesMe = person.netBalance > 0;
                            final isZero = person.netBalance == 0;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: CircleAvatar(
                                  radius: 20,
                                  backgroundColor: owesMe
                                      ? const Color(0xFF10B981).withOpacity(0.18)
                                      : isZero
                                          ? const Color(0xFF64748B).withOpacity(0.18)
                                          : const Color(0xFFF43F5E).withOpacity(0.18),
                                  child: Text(
                                    person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: owesMe
                                          ? const Color(0xFF10B981)
                                          : isZero
                                              ? const Color(0xFF94A3B8)
                                              : const Color(0xFFF43F5E),
                                    ),
                                  ),
                                ),
                                title: Text(person.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                                subtitle: Text(
                                  isZero
                                      ? 'Settled (পরিশোধিত)'
                                      : owesMe
                                          ? 'Owes you (পাবো)'
                                          : 'You owe them (দিতে হবে)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isZero ? Colors.grey : owesMe ? const Color(0xFF10B981) : const Color(0xFFF43F5E),
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      currency.format(person.netBalance.abs()),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                        color: isZero ? const Color(0xFF94A3B8) : owesMe ? const Color(0xFF10B981) : const Color(0xFFF43F5E),
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => PersonDetailScreen(person: person)),
                                  );
                                },
                              ),
                            );
                          },
                          childCount: filteredPeople.length,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 82 + (_pulseController.value * 16),
                  height: 82 + (_pulseController.value * 16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF10B981).withOpacity(0.18 - (_pulseController.value * 0.1)),
                  ),
                ),
                SizedBox(
                  width: 76,
                  height: 76,
                  child: FloatingActionButton(
                    onPressed: () => _openVoiceSheet(context),
                    backgroundColor: const Color(0xFF10B981),
                    elevation: 10,
                    shape: const CircleBorder(),
                    child: const Icon(Icons.mic_rounded, size: 38, color: Colors.white),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String key) {
    final isSelected = _activeFilter == key;
    return InkWell(
      onTap: () => setState(() => _activeFilter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isSelected ? Colors.white : Colors.grey)),
      ),
    );
  }
}

// ============================================================================
// SECTION 7: MANAGE PEOPLE SCREEN (Add, Rename, Delete, Settle)
// ============================================================================

class ManagePeopleScreen extends StatefulWidget {
  const ManagePeopleScreen({super.key});

  @override
  State<ManagePeopleScreen> createState() => _ManagePeopleScreenState();
}

class _ManagePeopleScreenState extends State<ManagePeopleScreen> {
  final TextEditingController _newPersonController = TextEditingController();

  void _showAddDialog(BuildContext context) {
    _newPersonController.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF151E33),
        title: const Text('Add New Contact', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: _newPersonController,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'e.g. Rahim, তানভীর',
            filled: true,
            fillColor: const Color(0xFF0F172A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (_newPersonController.text.trim().isNotEmpty) {
                await context.read<AppProvider>().addPerson(_newPersonController.text.trim());
                if (context.mounted) Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, Person p) {
    final controller = TextEditingController(text: p.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF151E33),
        title: const Text('Rename Contact', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0F172A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                await context.read<AppProvider>().renamePerson(p.id!, controller.text.trim());
                if (context.mounted) Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final currency = NumberFormat.currency(symbol: r'$', decimalDigits: 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage People'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDialog(context),
        backgroundColor: const Color(0xFF10B981),
        icon: const Icon(Icons.person_add_rounded, color: Colors.white),
        label: const Text('Add Person', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: provider.people.isEmpty
          ? const Center(child: Text('No contacts yet. Tap + to add.', style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
              itemCount: provider.people.length,
              itemBuilder: (context, index) {
                final p = provider.people[index];
                final owesMe = p.netBalance > 0;
                final isZero = p.netBalance == 0;

                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      isZero
                          ? r'Settled ($0)'
                          : owesMe
                              ? 'Owes: ${currency.format(p.netBalance)}'
                              : 'You owe: ${currency.format(p.netBalance.abs())}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isZero ? Colors.grey : owesMe ? const Color(0xFF10B981) : const Color(0xFFF43F5E),
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isZero)
                          TextButton(
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  backgroundColor: const Color(0xFF1E293B),
                                  title: const Text('Settle balance?'),
                                  content: Text('Mark ${p.name}\'s balance as fully settled?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF06B6D4)),
                                      child: const Text('Settle'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await provider.settlePerson(p.id!);
                              }
                            },
                            child: const Text('Settle', style: TextStyle(color: Color(0xFF06B6D4), fontSize: 12)),
                          ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18, color: Colors.grey),
                          onPressed: () => _showRenameDialog(context, p),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                backgroundColor: const Color(0xFF1E293B),
                                title: const Text('Delete contact?'),
                                content: Text('Delete ${p.name} and all their records?'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                  ElevatedButton(
                                    onPressed: () => Navigator.pop(context, true),
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF43F5E)),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await provider.deletePerson(p.id!);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ============================================================================
// SECTION 8: VOICE LISTENING SHEET
// ============================================================================

class VoiceListeningSheet extends StatelessWidget {
  const VoiceListeningSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final parseResult = provider.lastParseResult;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade700, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 12),

          // Language Switcher Chips inside sheet
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildSheetLangChip(context, provider, 'auto', '⚡ Banglish (Offline)'),
              const SizedBox(width: 6),
              _buildSheetLangChip(context, provider, 'bn_BD', '🌐 বাংলা (Online)'),
              const SizedBox(width: 6),
              _buildSheetLangChip(context, provider, 'en_US', '🇺🇸 English'),
            ],
          ),
          const SizedBox(height: 12),

          // Error banner if speech recognition had an issue
          if (provider.speechErrorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF43F5E).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF43F5E).withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFF43F5E), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      provider.speechErrorMessage!,
                      style: const TextStyle(fontSize: 10, color: Color(0xFFFECDD3)),
                    ),
                  ),
                  if (provider.selectedLanguage == 'bn_BD')
                    TextButton(
                      onPressed: () => provider.switchLanguageAndListen('auto'),
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                      child: const Text('Try Banglish', style: TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: provider.isListening ? const Color(0xFF10B981) : Colors.grey, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(
                provider.isListening ? 'LISTENING (OFFLINE NATIVE)...' : 'SPEECH CAPTURED',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 1.0, color: provider.isListening ? const Color(0xFF10B981) : Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Waveform
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF334155))),
            child: Column(
              children: [
                Text(
                  provider.currentWords.isEmpty ? 'বলুন: "রহিমকে ৫০০০ টাকা দিয়েছি" / "Rahim ke 5000 dilam"' : '"${provider.currentWords}"',
                  style: TextStyle(fontSize: 15, fontStyle: provider.currentWords.isEmpty ? FontStyle.italic : FontStyle.normal, color: provider.currentWords.isEmpty ? Colors.grey : Colors.white),
                  textAlign: TextAlign.center,
                ),
                if (parseResult?.detectedLanguage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Language: ${parseResult!.detectedLanguage}', style: const TextStyle(fontSize: 10, color: Color(0xFF38BDF8))),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Auto-corrections badge
          if (parseResult != null && parseResult.autoCorrections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Auto-corrected: ${parseResult.autoCorrections.join(', ')}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF38BDF8)),
              ),
            ),

          if (parseResult != null && parseResult.isSuccess) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: parseResult.type!.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: parseResult.type!.color.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Icon(parseResult.type!.icon, color: parseResult.type!.color, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(parseResult.type!.label.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: parseResult.type!.color)),
                        Text('${parseResult.personName} • \$${parseResult.amount?.toStringAsFixed(0)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  const Icon(Icons.check_circle, color: Color(0xFF10B981)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await provider.saveTransaction(
                    personName: parseResult.personName!,
                    amount: parseResult.amount!,
                    type: parseResult.type!,
                    note: 'Voice: "${provider.currentWords}"',
                  );
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Logged ${parseResult.type!.label} to ${parseResult.personName}'), backgroundColor: const Color(0xFF10B981)),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Confirm & Save', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ] else if (parseResult != null && !parseResult.isSuccess) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFF59E0B).withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3))),
              child: Row(
                children: [
                  const Icon(Icons.help_outline_rounded, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(parseResult.fallbackReason ?? 'Could not parse fully.', style: const TextStyle(fontSize: 11, color: Color(0xFFFDE68A)))),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  showDialog(
                    context: context,
                    builder: (_) => ManualEntryDialog(
                      initialName: parseResult.personName,
                      initialAmount: parseResult.amount,
                      initialType: parseResult.type ?? TransactionType.lent_to,
                      initialNote: provider.currentWords,
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFF59E0B)), foregroundColor: const Color(0xFFF59E0B), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('Correct in Dialog'),
              ),
            ),
          ],
          const SizedBox(height: 10),

          // Offline Guidance Tip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B).withOpacity(0.7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Row(
              children: [
                const Icon(Icons.offline_bolt_rounded, size: 15, color: Color(0xFF10B981)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '100% Offline Tip: Speak in Banglish (e.g. "Rahim ke 5000 dilam") using the English offline pack!',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () {
              provider.stopVoiceListening();
              Navigator.pop(context);
            },
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget _buildSheetLangChip(BuildContext context, AppProvider provider, String langKey, String label) {
    final isSelected = provider.selectedLanguage == langKey;
    return InkWell(
      onTap: () => provider.switchLanguageAndListen(langKey),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? const Color(0xFF10B981) : const Color(0xFF334155)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? const Color(0xFF10B981) : Colors.grey.shade400,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// SECTION 9: MANUAL ENTRY DIALOG & PERSON DETAIL SCREEN
// ============================================================================

class ManualEntryDialog extends StatefulWidget {
  final String? initialName;
  final double? initialAmount;
  final TransactionType initialType;
  final String? initialNote;

  const ManualEntryDialog({super.key, this.initialName, this.initialAmount, this.initialType = TransactionType.lent_to, this.initialNote});

  @override
  State<ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<ManualEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _amountController;
  late TextEditingController _noteController;
  late TransactionType _selectedType;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _amountController = TextEditingController(text: widget.initialAmount != null && widget.initialAmount! > 0 ? widget.initialAmount!.toStringAsFixed(0) : '');
    _noteController = TextEditingController(text: widget.initialNote ?? '');
    _selectedType = widget.initialType;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF151E33),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.edit_note_rounded, color: Color(0xFF10B981)),
          SizedBox(width: 8),
          Text('Log Transaction', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<TransactionType>(
                value: _selectedType,
                decoration: InputDecoration(labelText: 'Intent / উদ্দেশ্য', filled: true, fillColor: const Color(0xFF0F172A), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                items: TransactionType.values.map((type) {
                  return DropdownMenuItem(value: type, child: Text(type.label));
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedType = val);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(labelText: 'Person Name (নাম)', prefixIcon: const Icon(Icons.person_outline, size: 20), filled: true, fillColor: const Color(0xFF0F172A), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                validator: (val) => val == null || val.trim().isEmpty ? 'Enter name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: r'Amount ($ / ৳)', prefixIcon: const Icon(Icons.attach_money, size: 20), filled: true, fillColor: const Color(0xFF0F172A), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Enter amount';
                  final p = double.tryParse(val.replaceAll(',', ''));
                  if (p == null || p <= 0) return 'Invalid amount';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteController,
                decoration: InputDecoration(labelText: 'Note (Optional)', prefixIcon: const Icon(Icons.notes_rounded, size: 20), filled: true, fillColor: const Color(0xFF0F172A), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            if (_formKey.currentState!.validate()) {
              final amount = double.parse(_amountController.text.replaceAll(',', ''));
              await context.read<AppProvider>().saveTransaction(
                    personName: _nameController.text.trim(),
                    amount: amount,
                    type: _selectedType,
                    note: _noteController.text.trim().isNotEmpty ? _noteController.text.trim() : null,
                  );
              if (context.mounted) {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Saved ${_nameController.text}: \$${amount.toStringAsFixed(0)}'), backgroundColor: const Color(0xFF10B981)),
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
          child: const Text('Save Record'),
        ),
      ],
    );
  }
}

class PersonDetailScreen extends StatefulWidget {
  final Person person;
  const PersonDetailScreen({super.key, required this.person});

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  late Future<List<TransactionItem>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _loadHistory() {
    _historyFuture = context.read<AppProvider>().getHistory(widget.person.id!);
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: r'$', decimalDigits: 0);
    final provider = context.watch<AppProvider>();

    final updated = provider.people.firstWhere((p) => p.id == widget.person.id, orElse: () => widget.person);
    final owesMe = updated.netBalance > 0;
    final isZero = updated.netBalance == 0;

    return Scaffold(
      appBar: AppBar(title: Text(updated.name)),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: const Color(0xFF151E33), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF1E293B))),
            child: Column(
              children: [
                Text(
                  isZero ? 'ALL SETTLED UP' : owesMe ? '${updated.name.toUpperCase()} OWES YOU' : 'YOU OWE ${updated.name.toUpperCase()}',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isZero ? Colors.grey : owesMe ? const Color(0xFF10B981) : const Color(0xFFF43F5E)),
                ),
                const SizedBox(height: 6),
                Text(currency.format(updated.netBalance.abs()), style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: isZero ? const Color(0xFF94A3B8) : owesMe ? const Color(0xFF10B981) : const Color(0xFFF43F5E))),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<TransactionItem>>(
              future: _historyFuture,
              builder: (context, snapshot) {
                final list = snapshot.data ?? [];
                if (list.isEmpty) return const Center(child: Text('No transactions recorded.', style: TextStyle(color: Colors.grey)));
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final tx = list[index];
                    return Card(
                      child: ListTile(
                        leading: Icon(tx.type.icon, color: tx.type.color),
                        title: Text(tx.type.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        trailing: Text(currency.format(tx.amount), style: TextStyle(color: tx.type.color, fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
