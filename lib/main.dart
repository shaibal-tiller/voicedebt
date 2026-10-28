// ============================================================================
// VoiceDebt - 100% Free, Offline, Voice-First Debt & Borrowing Tracker
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
  lent_to, // I gave money -> They owe me (+ balance)
  borrowed_from, // I took money -> I owe them (- balance)
  repayment_received, // They gave me money back -> Their debt decreases (- balance)
  repayment_made, // I gave money back -> My debt decreases (+ balance towards 0)
}

extension TransactionTypeExt on TransactionType {
  String get label {
    switch (this) {
      case TransactionType.lent_to:
        return 'Lent To';
      case TransactionType.borrowed_from:
        return 'Borrowed From';
      case TransactionType.repayment_received:
        return 'Repayment Received';
      case TransactionType.repayment_made:
        return 'Repayment Made';
    }
  }

  Color get color {
    switch (this) {
      case TransactionType.lent_to:
        return const Color(0xFF10B981); // Emerald Green
      case TransactionType.borrowed_from:
        return const Color(0xFFF43F5E); // Rose/Coral
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

  // Math impact on person netBalance
  // positive netBalance means they owe me; negative means I owe them
  double get multiplier {
    switch (this) {
      case TransactionType.lent_to:
        return 1.0; // They owe me more
      case TransactionType.borrowed_from:
        return -1.0; // I owe them more (negative)
      case TransactionType.repayment_received:
        return -1.0; // They paid me back (reduces their positive debt)
      case TransactionType.repayment_made:
        return 1.0; // I paid them back (brings my negative debt closer to 0)
    }
  }
}

class Person {
  final int? id;
  final String name;
  final double netBalance; // Positive: owes me. Negative: I owe them.

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
// SECTION 2: ROBUST OFFLINE REGEX/KEYWORD PARSER ENGINE
// ============================================================================

class VoiceParseResult {
  final String rawText;
  final bool isSuccess;
  final TransactionType? type;
  final String? personName;
  final double? amount;
  final String? fallbackReason;
  final double confidence;

  VoiceParseResult({
    required this.rawText,
    required this.isSuccess,
    this.type,
    this.personName,
    this.amount,
    this.fallbackReason,
    this.confidence = 0.0,
  });
}

class VoiceParser {
  static const Set<String> _stopWords = {
    'i', 'me', 'my', 'to', 'from', 'a', 'an', 'the', 'for', 'and', 'in', 'of',
    'dollars', 'dollar', 'taka', 'tk', 'rupees', 'rs', 'bucks', 'usd', 'eur', 'cash', 'money',
    'just', 'please', 'log', 'record', 'note'
  };

  /// Parses raw transcribed voice speech into structured data offline.
  static VoiceParseResult parse(String spokenText) {
    final text = spokenText.trim();
    if (text.isEmpty) {
      return VoiceParseResult(
        rawText: text,
        isSuccess: false,
        fallbackReason: 'No speech detected.',
      );
    }

    final lower = text.toLowerCase();
    TransactionType? detectedType;

    // 1. Repayment Made: "I returned", "I paid", "I gave back", "gave back", "paid back to"
    if (RegExp(r'\b(i\s+returned|i\s+paid|i\s+gave\s+back|gave\s+back|paid\s+back\s+to|repaid)\b').hasMatch(lower)) {
      detectedType = TransactionType.repayment_made;
    }
    // 2. Repayment Received: "returned", "paid back", "got", "received"
    else if (RegExp(r'\b(returned|paid\s+back|got\s+\d+|got\s+from|received)\b').hasMatch(lower)) {
      detectedType = TransactionType.repayment_received;
    }
    // 3. Borrow Intent: "borrowed", "took"
    else if (RegExp(r'\b(borrowed|took)\b').hasMatch(lower)) {
      detectedType = TransactionType.borrowed_from;
    }
    // 4. Lend Intent: "gave", "lent", "lend"
    else if (RegExp(r'\b(lent|lend|gave)\b').hasMatch(lower)) {
      detectedType = TransactionType.lent_to;
    }
    // 5. Shorthand "paid" -> repayment_made
    else if (RegExp(r'\b(paid)\b').hasMatch(lower)) {
      detectedType = TransactionType.repayment_made;
    }

    // Extract amount (supports 5000, 5,000, 5.5k, $500, etc.)
    double? extractedAmount;
    String? matchedAmountToken;

    // Check for "5k" or "2.5k" or "thousand"
    final kMatch = RegExp(r'\b(\d+(?:\.\d+)?)\s*(?:k|thousand)\b').firstMatch(lower);
    if (kMatch != null && kMatch.group(1) != null) {
      extractedAmount = double.tryParse(kMatch.group(1)!)! * 1000.0;
      matchedAmountToken = kMatch.group(0);
    } else {
      // Standard number extraction
      final numMatch = RegExp(r'(?:[$€£₹৳]\s*)?(\b\d{1,3}(?:,\d{3})*(?:\.\d+)?\b|\b\d+(?:\.\d+)?\b)').firstMatch(lower);
      if (numMatch != null && numMatch.group(1) != null) {
        final clean = numMatch.group(1)!.replaceAll(',', '');
        extractedAmount = double.tryParse(clean);
        matchedAmountToken = numMatch.group(0);
      }
    }

    // Extract person name
    String remainder = lower;
    if (matchedAmountToken != null) {
      remainder = remainder.replaceAll(matchedAmountToken.toLowerCase(), ' ');
    }

    final phrasesToRemove = [
      'i returned', 'i paid', 'i gave back', 'paid back', 'gave back',
      'i lent', 'i borrowed', 'i took', 'i gave', 'lent', 'lend', 'gave',
      'borrowed', 'took', 'returned', 'paid', 'got', 'received'
    ];
    for (final phrase in phrasesToRemove) {
      remainder = remainder.replaceAll(RegExp('\\b$phrase\\b'), ' ');
    }

    // Split words and sanitize
    final tokens = remainder
        .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_stopWords.contains(w) && !RegExp(r'^\d+$').hasMatch(w))
        .toList();

    String? personName;
    if (tokens.isNotEmpty) {
      // Take up to 2 words for name (First & Last name) and capitalize
      personName = tokens.take(2).map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
    }

    final isSuccess = detectedType != null && extractedAmount != null && extractedAmount > 0 && personName != null;
    String? fallbackReason;

    if (detectedType == null) {
      fallbackReason = "Couldn't detect intent (Lend, Borrow, or Repay).";
    } else if (extractedAmount == null) {
      fallbackReason = "Couldn't extract the amount.";
    } else if (personName == null) {
      fallbackReason = "Couldn't find person name.";
    }

    double confidence = 0.2;
    if (detectedType != null) confidence += 0.3;
    if (extractedAmount != null) confidence += 0.3;
    if (personName != null) confidence += 0.2;

    return VoiceParseResult(
      rawText: text,
      isSuccess: isSuccess,
      type: detectedType,
      personName: personName,
      amount: extractedAmount,
      fallbackReason: isSuccess ? null : fallbackReason,
      confidence: confidence,
    );
  }
}

// ============================================================================
// SECTION 3: LOCAL SQLITE DATABASE HELPER (Zero Cost, Offline)
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
    // People table with net balance cache
    await db.execute('''
      CREATE TABLE people (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL COLLATE NOCASE,
        netBalance REAL NOT NULL DEFAULT 0.0
      )
    ''');

    // Transactions ledger table
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

  /// Retrieves all people ordered by absolute active balance
  Future<List<Person>> getAllPeople() async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT * FROM people 
      ORDER BY ABS(netBalance) DESC, name ASC
    ''');
    return result.map((map) => Person.fromMap(map)).toList();
  }

  /// Retrieves transaction ledger for a specific person
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

  /// Computes summary stats: "Total Owed to Me" & "Total I Owe"
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

    return {
      'owedToMe': owedToMe,
      'iOwe': iOwe,
    };
  }

  /// Records transaction and accurately recalculates person netBalance in a single atomic transaction
  Future<void> recordTransaction({
    required String personName,
    required double amount,
    required TransactionType type,
    String? note,
  }) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      // 1. Get or create person
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

      // 2. Insert transaction
      await txn.insert('transactions', {
        'personId': personId,
        'amount': amount,
        'type': type.name,
        'timestamp': DateTime.now().toIso8601String(),
        'note': note,
      });

      // 3. Recalculate person balance:
      // lent_to: +amount
      // borrowed_from: -amount
      // repayment_received: -amount (reduces debt they owe me)
      // repayment_made: +amount (reduces debt I owe them)
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

  /// Deletes a transaction and recalculates the person's net balance accurately
  Future<void> deleteTransaction(int transactionId, int personId) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      await txn.delete(
        'transactions',
        where: 'id = ?',
        whereArgs: [transactionId],
      );

      // Recalculate net balance from all remaining transactions
      final remaining = await txn.query(
        'transactions',
        where: 'personId = ?',
        whereArgs: [personId],
      );

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
// SECTION 4: APP PROVIDER & QUICK ACTIONS STATE
// ============================================================================

class AppProvider with ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final stt.SpeechToText _speech = stt.SpeechToText();
  final QuickActions _quickActions = const QuickActions();

  List<Person> _people = [];
  double _totalOwedToMe = 0.0;
  double _totalIOwe = 0.0;
  bool _isLoading = true;

  // Voice recognition states
  bool _isSpeechAvailable = false;
  bool _isListening = false;
  String _currentWords = '';
  VoiceParseResult? _lastParseResult;

  List<Person> get people => _people;
  double get totalOwedToMe => _totalOwedToMe;
  double get totalIOwe => _totalIOwe;
  bool get isLoading => _isLoading;
  bool get isListening => _isListening;
  String get currentWords => _currentWords;
  VoiceParseResult? get lastParseResult => _lastParseResult;

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
        // App launched directly into listening mode via Home shortcut or hardware gesture!
        startVoiceListening();
      }
    });

    _quickActions.setShortcutItems(<ShortcutItem>[
      const ShortcutItem(
        type: 'action_quick_listen',
        localizedTitle: 'Quick Voice Log',
        icon: 'ic_mic_shortcut', // Place icon in android/app/src/main/res/drawable
      ),
    ]);
  }

  Future<void> startVoiceListening() async {
    if (!_isSpeechAvailable) {
      await _initSpeech();
    }

    _currentWords = '';
    _lastParseResult = null;
    _isListening = true;
    notifyListeners();

    if (_isSpeechAvailable) {
      await _speech.listen(
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
// SECTION 5: APPLICATION ENTRY POINT & DARK THEME
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
          primary: Color(0xFF10B981), // Emerald
          secondary: Color(0xFF38BDF8), // Sky
          surface: Color(0xFF111827),
          error: Color(0xFFF43F5E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0F1D),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardTheme(
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
// SECTION 6: DASHBOARD SCREEN & QUICK VOICE FAB
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
    final provider = context.read<AppProvider>();
    provider.startVoiceListening();

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
    final currency = NumberFormat.currency(symbol: '$', decimalDigits: 0);

    final filteredPeople = provider.people.where((p) {
      if (_searchFilter.isEmpty) return true;
      return p.name.toLowerCase().contains(_searchFilter.toLowerCase());
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
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'VoiceDebt',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
                ),
                Text(
                  '100% Free • Offline • Voice First',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded),
            tooltip: 'Manual Entry',
            onPressed: () => _openManualFallbackDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => provider.refreshData(),
          ),
        ],
      ),
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => provider.refreshData(),
              child: CustomScrollView(
                slivers: [
                  // Summary Banner
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF131C31), Color(0xFF1E294B)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0xFF334155), width: 1),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                // Owed to Me
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: Color(0xFF10B981),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'TOTAL OWED TO ME',
                                            style: TextStyle(
                                              color: Colors.grey.shade400,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        currency.format(provider.totalOwedToMe),
                                        style: const TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF10B981),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  width: 1,
                                  height: 50,
                                  color: const Color(0xFF334155),
                                ),
                                const SizedBox(width: 16),
                                // I Owe
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: const BoxDecoration(
                                              color: Color(0xFFF43F5E),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'TOTAL I OWE',
                                            style: TextStyle(
                                              color: Colors.grey.shade400,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        currency.format(provider.totalIOwe),
                                        style: const TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFFF43F5E),
                                        ),
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

                  // Search bar & count
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
                                hintText: 'Search people...',
                                prefixIcon: const Icon(Icons.search, size: 20, color: Colors.grey),
                                filled: true,
                                fillColor: const Color(0xFF111827),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: Color(0xFF1E293B)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: const BorderSide(color: Color(0xFF1E293B)),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${provider.people.length} People',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
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
                            Icon(Icons.record_voice_over_rounded, size: 64, color: Colors.grey.shade600),
                            const SizedBox(height: 16),
                            const Text(
                              'No records found',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 40),
                              child: Text(
                                'Tap the massive green mic below and say:\n"I lent Rahim 5000" or "I borrowed 2000 from Zaman"',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final person = filteredPeople[index];
                            final owesMe = person.netBalance > 0;
                            final isZero = person.netBalance == 0;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                leading: CircleAvatar(
                                  radius: 22,
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
                                title: Text(
                                  person.name,
                                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                ),
                                subtitle: Text(
                                  isZero
                                      ? 'Settled up'
                                      : owesMe
                                          ? 'Owes you'
                                          : 'You owe them',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isZero
                                        ? Colors.grey
                                        : owesMe
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFF43F5E),
                                  ),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      currency.format(person.netBalance.abs()),
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                        color: isZero
                                            ? const Color(0xFF94A3B8)
                                            : owesMe
                                                ? const Color(0xFF10B981)
                                                : const Color(0xFFF43F5E),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
                                  ],
                                ),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => PersonDetailScreen(person: person),
                                    ),
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
      // MASSIVE QUICK VOICE FAB
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                // Outer Pulse Ring
                Container(
                  width: 82 + (_pulseController.value * 16),
                  height: 82 + (_pulseController.value * 16),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF10B981).withOpacity(0.18 - (_pulseController.value * 0.1)),
                  ),
                ),
                // Inner Button
                SizedBox(
                  width: 76,
                  height: 76,
                  child: FloatingActionButton(
                    onPressed: () => _openVoiceSheet(context),
                    backgroundColor: const Color(0xFF10B981),
                    elevation: 10,
                    shape: const CircleBorder(),
                    child: const Icon(
                      Icons.mic_rounded,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// SECTION 7: VOICE LISTENING SHEET & LIVE PARSER DISPLAY
// ============================================================================

class VoiceListeningSheet extends StatelessWidget {
  const VoiceListeningSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final parseResult = provider.lastParseResult;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade700,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 20),

          // Listening status indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: provider.isListening ? const Color(0xFF10B981) : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                provider.isListening ? 'LISTENING (OFFLINE NATIVE)...' : 'SPEECH CAPTURED',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  letterSpacing: 1.0,
                  color: provider.isListening ? const Color(0xFF10B981) : Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Transcribed Text Display Box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Text(
              provider.currentWords.isEmpty ? 'Speak now... (e.g. "I lent Rahim 5000")' : '"${provider.currentWords}"',
              style: TextStyle(
                fontSize: 16,
                fontStyle: provider.currentWords.isEmpty ? FontStyle.italic : FontStyle.normal,
                color: provider.currentWords.isEmpty ? Colors.grey : Colors.white,
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),

          // Real-time Parser Feedback Card
          if (parseResult != null && parseResult.isSuccess) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: parseResult.type!.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: parseResult.type!.color.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Icon(parseResult.type!.icon, color: parseResult.type!.color, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          parseResult.type!.label.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: parseResult.type!.color,
                          ),
                        ),
                        Text(
                          '${parseResult.personName} • $${parseResult.amount?.toStringAsFixed(0)}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.check_circle, color: Color(0xFF10B981)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Confirm & Save Button
            SizedBox(
              width: double.infinity,
              height: 52,
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
                      SnackBar(
                        content: Text('Logged ${parseResult.type!.label} to ${parseResult.personName}'),
                        backgroundColor: const Color(0xFF10B981),
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Confirm & Save Log', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ] else if (parseResult != null && !parseResult.isSuccess) ...[
            // Parser Fallback Notice
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFF59E0B).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.help_outline_rounded, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      parseResult.fallbackReason ?? 'Could not parse fully. Open manual entry to correct.',
                      style: const TextStyle(fontSize: 12, color: Color(0xFFFDE68A)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Open Manual Entry Fallback Button
            SizedBox(
              width: double.infinity,
              height: 48,
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
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFF59E0B)),
                  foregroundColor: const Color(0xFFF59E0B),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('Correct in Manual Entry'),
              ),
            ),
          ],

          const SizedBox(height: 12),
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
}

// ============================================================================
// SECTION 8: MANUAL ENTRY FALLBACK DIALOG
// ============================================================================

class ManualEntryDialog extends StatefulWidget {
  final String? initialName;
  final double? initialAmount;
  final TransactionType initialType;
  final String? initialNote;

  const ManualEntryDialog({
    super.key,
    this.initialName,
    this.initialAmount,
    this.initialType = TransactionType.lent_to,
    this.initialNote,
  });

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
    _amountController = TextEditingController(
      text: widget.initialAmount != null && widget.initialAmount! > 0
          ? widget.initialAmount!.toStringAsFixed(0)
          : '',
    );
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Row(
        children: [
          Icon(Icons.edit_note_rounded, color: Color(0xFF10B981)),
          SizedBox(width: 8),
          Text('Log Transaction', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Type Selector
              DropdownButtonFormField<TransactionType>(
                value: _selectedType,
                decoration: InputDecoration(
                  labelText: 'Transaction Intent',
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                items: TransactionType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Row(
                      children: [
                        Icon(type.icon, color: type.color, size: 18),
                        const SizedBox(width: 8),
                        Text(type.label),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedType = val);
                },
              ),
              const SizedBox(height: 14),
              // Person Name
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Person Name',
                  hintText: 'e.g. Rahim, Zaman',
                  prefixIcon: const Icon(Icons.person_outline, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'Enter person name' : null,
              ),
              const SizedBox(height: 14),
              // Amount
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Amount ($)',
                  hintText: 'e.g. 5000',
                  prefixIcon: const Icon(Icons.attach_money, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Enter amount';
                  final parsed = double.tryParse(val.replaceAll(',', ''));
                  if (parsed == null || parsed <= 0) return 'Invalid amount';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              // Note / Spoken phrase
              TextFormField(
                controller: _noteController,
                decoration: InputDecoration(
                  labelText: 'Note (Optional)',
                  hintText: 'e.g. For dinner, loan, etc.',
                  prefixIcon: const Icon(Icons.notes_rounded, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
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
                  SnackBar(
                    content: Text('Saved ${_nameController.text}: $${amount.toStringAsFixed(0)}'),
                    backgroundColor: const Color(0xFF10B981),
                  ),
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF10B981),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Save Record'),
        ),
      ],
    );
  }
}

// ============================================================================
// SECTION 9: PERSON DETAIL SCREEN & TRANSACTION LEDGER
// ============================================================================

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

  void _openQuickAction(TransactionType type) {
    showDialog(
      context: context,
      builder: (_) => ManualEntryDialog(
        initialName: widget.person.name,
        initialType: type,
      ),
    ).then((_) {
      setState(() {
        _loadHistory();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '$', decimalDigits: 0);
    final provider = context.watch<AppProvider>();

    // Current up-to-date balance from provider
    final updatedPerson = provider.people.firstWhere(
      (p) => p.id == widget.person.id,
      orElse: () => widget.person,
    );

    final owesMe = updatedPerson.netBalance > 0;
    final isZero = updatedPerson.netBalance == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(updatedPerson.name),
      ),
      body: Column(
        children: [
          // Header Card
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF151E33),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Column(
              children: [
                Text(
                  isZero
                      ? 'ALL SETTLED UP'
                      : owesMe
                          ? '${updatedPerson.name.toUpperCase()} OWES YOU'
                          : 'YOU OWE ${updatedPerson.name.toUpperCase()}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: isZero
                        ? Colors.grey
                        : owesMe
                            ? const Color(0xFF10B981)
                            : const Color(0xFFF43F5E),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  currency.format(updatedPerson.netBalance.abs()),
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: isZero
                        ? const Color(0xFF94A3B8)
                        : owesMe
                            ? const Color(0xFF10B981)
                            : const Color(0xFFF43F5E),
                  ),
                ),
                const SizedBox(height: 16),
                // Action Buttons (Lend, Borrow, Repay)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildActionButton(
                      label: '+ Lend',
                      color: const Color(0xFF10B981),
                      onTap: () => _openQuickAction(TransactionType.lent_to),
                    ),
                    _buildActionButton(
                      label: '- Borrow',
                      color: const Color(0xFFF43F5E),
                      onTap: () => _openQuickAction(TransactionType.borrowed_from),
                    ),
                    _buildActionButton(
                      label: 'Repayment',
                      color: const Color(0xFF06B6D4),
                      onTap: () => _openQuickAction(
                        owesMe ? TransactionType.repayment_received : TransactionType.repayment_made,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            child: Row(
              children: [
                const Text(
                  'Transaction History',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                Text(
                  'Chronological Ledger',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                ),
              ],
            ),
          ),

          // Transaction List
          Expanded(
            child: FutureBuilder<List<TransactionItem>>(
              future: _historyFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snapshot.data ?? [];
                if (list.isEmpty) {
                  return const Center(
                    child: Text('No transactions recorded yet.', style: TextStyle(color: Colors.grey)),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final tx = list[index];
                    final dateStr = DateFormat('MMM d, y • h:mm a').format(tx.timestamp);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: tx.type.color.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(tx.type.icon, color: tx.type.color, size: 20),
                        ),
                        title: Row(
                          children: [
                            Text(
                              tx.type.label,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            const Spacer(),
                            Text(
                              currency.format(tx.amount),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: tx.type.color,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dateStr, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                            if (tx.note != null && tx.note!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  tx.note!,
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                          tooltip: 'Delete Entry',
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                backgroundColor: const Color(0xFF1E293B),
                                title: const Text('Delete transaction?'),
                                content: Text('Remove $${tx.amount.toStringAsFixed(0)} ${tx.type.label}? The balance will be recalculated.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF43F5E)),
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              await provider.deleteTransaction(tx.id!, widget.person.id!);
                              _loadHistory();
                              setState(() {});
                            }
                          },
                        ),
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

  Widget _buildActionButton({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
        ),
      ),
    );
  }
}
