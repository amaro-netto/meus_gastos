// main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert'; // Necessário para jsonEncode/jsonDecode
import 'package:http/http.dart' as http; // Necessário para fazer requisições HTTP

// IMPORTANTE:
// Você deve importar o arquivo gerado automaticamente pelo FlutterFire:
import 'firebase_options.dart';
// Certifique-se de que 'firebase_options.dart' está na sua pasta 'lib'
// e foi gerado com sucesso após rodar 'flutterfire configure' no terminal.


void main() async {
  // Garante que os widgets do Flutter estão inicializados antes de usar o Firebase.
  WidgetsFlutterBinding.ensureInitialized();
  // Inicializa o Firebase com as opções geradas para a plataforma atual.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CodeBuddy - Controle Financeiro',
      // Define o tema visual do aplicativo.
      theme: ThemeData(
        primarySwatch: Colors.indigo, // Cor principal do tema.
        visualDensity: VisualDensity.adaptivePlatformDensity, // Densidade visual adaptativa.
        fontFamily: 'Inter', // Define a fonte (se "Inter" for adicionada ao pubspec.yaml e assets).
      ),
      // AuthWrapper lida com a autenticação de forma transparente.
      home: const AuthWrapper(),
    );
  }
}

// Wrapper para lidar com a autenticação do Firebase e carregar o userId.
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({Key? key}) : super(key: key);

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  String? _userId;
  bool _isLoadingAuth = true;

  @override
  void initState() {
    super.initState();
    _initializeAuth(); // Inicia o processo de autenticação ao carregar.
  }

  // Função para inicializar a autenticação anônima do Firebase.
  Future<void> _initializeAuth() async {
    try {
      UserCredential userCredential = await FirebaseAuth.instance.signInAnonymously();
      setState(() {
        _userId = userCredential.user?.uid; // Armazena o ID do usuário autenticado.
        _isLoadingAuth = false;
      });
      print('Usuário Firebase autenticado anonimamente: $_userId');
    } catch (e) {
      print('Erro na autenticação anônima do Firebase: $e');
      setState(() {
        _isLoadingAuth = false;
        // Se houver um erro, _userId permanecerá nulo.
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingAuth) {
      // Mostra um indicador de carregamento enquanto a autenticação está em andamento.
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    } else if (_userId == null) {
      // Exibe uma mensagem de erro se a autenticação falhar.
      return const Scaffold(
        body: Center(
          child: Text('Erro: Não foi possível autenticar o usuário.'),
        ),
      );
    } else {
      // Se autenticado com sucesso, navega para a tela principal, passando o userId.
      return FinanceTrackerHome(userId: _userId!);
    }
  }
}

// Classe que representa a estrutura de uma Transação.
class Transaction {
  final String id;
  final String description;
  final double amount;
  final String type; // 'expense' ou 'income'.
  final String category;
  final DateTime date;
  final bool isRecurring;
  final String? frequency; // 'monthly', 'weekly', etc. (nulo se não recorrente).

  Transaction({
    required this.id,
    required this.description,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
    this.isRecurring = false,
    this.frequency,
  });

  // Construtor de fábrica para criar uma Transação a partir de um DocumentSnapshot do Firestore.
  factory Transaction.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map<String, dynamic>;
    return Transaction(
      id: doc.id,
      description: data['description'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      type: data['type'] ?? 'expense',
      category: data['category'] ?? 'Geral',
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRecurring: data['isRecurring'] ?? false,
      frequency: data['frequency'],
    );
  }

  // Converte o objeto Transação para um mapa para salvar no Firestore.
  Map<String, dynamic> toFirestore() {
    return {
      'description': description,
      'amount': amount,
      'type': type,
      'category': category,
      'date': Timestamp.fromDate(date),
      'createdAt': Timestamp.now(), // Timestamp de criação.
      'isRecurring': isRecurring,
      'frequency': frequency,
    };
  }
}

// A tela principal do aplicativo.
class FinanceTrackerHome extends StatefulWidget {
  final String userId; // Recebe o userId do AuthWrapper.
  const FinanceTrackerHome({Key? key, required this.userId}) : super(key: key);

  @override
  State<FinanceTrackerHome> createState() => _FinanceTrackerHomeState();
}

class _FinanceTrackerHomeState extends State<FinanceTrackerHome> {
  int _selectedIndex = 0; // Índice da aba selecionada (0: Dashboard, 1: Adicionar, 2: Gráficos).

  // Controladores de texto para o formulário de transação.
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  String _transactionType = 'expense';
  String _category = '';
  DateTime? _selectedDate;
  bool _isRecurring = false;
  String _frequency = 'monthly';

  // Listas de dados e estados de carregamento/erro.
  List<Transaction> _transactions = [];
  String? _errorMessage;
  bool _isLoadingData = true;

  // Estados para a funcionalidade de Análise Financeira (LLM Gemini).
  String _financialInsights = '';
  bool _isGeneratingInsights = false;

  @override
  void initState() {
    super.initState();
    _listenToTransactions(); // Inicia o listener de transações ao carregar a tela.
  }

  // Listener para as transações no Firestore.
  void _listenToTransactions() {
    // Define o caminho da coleção de transações do usuário.
    final CollectionReference transactionsCollection = FirebaseFirestore.instance
        .collection('artifacts/${widget.userId}/users/${widget.userId}/transactions');

    // Escuta as mudanças em tempo real na coleção.
    transactionsCollection.snapshots().listen((snapshot) {
      setState(() {
        _transactions = snapshot.docs
            .map((doc) => Transaction.fromFirestore(doc))
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date)); // Ordena as transações pela data mais recente.
        _isLoadingData = false;
      });
    }, onError: (error) {
      // Trata erros ao carregar as transações.
      setState(() {
        _errorMessage = 'Erro ao carregar transações: $error';
        _isLoadingData = false;
      });
      print(_errorMessage);
    });
  }

  // Função para adicionar uma nova transação ao Firestore.
  Future<void> _addTransaction() async {
    // Validação básica dos campos do formulário.
    if (_descriptionController.text.isEmpty || _amountController.text.isEmpty || _selectedDate == null) {
      _showCustomSnackBar('Por favor, preencha todos os campos obrigatórios.');
      return;
    }

    final double? amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      _showCustomSnackBar('Por favor, insira um valor numérico válido e positivo.');
      return;
    }

    try {
      final CollectionReference transactionsCollection = FirebaseFirestore.instance
          .collection('artifacts/${widget.userId}/users/${widget.userId}/transactions');

      // Cria um novo objeto Transação.
      final newTransaction = Transaction(
        id: '', // O ID será gerado automaticamente pelo Firestore.
        description: _descriptionController.text,
        amount: amount,
        type: _transactionType,
        category: _category.isEmpty ? 'Geral' : _category, // Define 'Geral' se a categoria estiver vazia.
        date: _selectedDate!,
        isRecurring: _isRecurring,
        frequency: _isRecurring ? _frequency : null, // Salva a frequência se for recorrente.
      );

      // Adiciona a transação ao Firestore.
      await transactionsCollection.add(newTransaction.toFirestore());

      _showCustomSnackBar('Transação adicionada com sucesso!');
      _clearForm(); // Limpa o formulário após a adição.
      setState(() {
        _selectedIndex = 0; // Volta para a aba Dashboard.
      });
    } catch (e) {
      _showCustomSnackBar('Erro ao adicionar transação: $e');
      print('Erro ao adicionar transação: $e');
    }
  }

  // Função para deletar uma transação do Firestore.
  Future<void> _deleteTransaction(String transactionId) async {
    // Exibe um diálogo de confirmação antes de deletar.
    final bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirmar Exclusão'),
          content: const Text('Tem certeza que deseja deletar esta transação?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false), // Botão 'Cancelar'.
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true), // Botão 'Deletar'.
              child: const Text('Deletar'),
            ),
          ],
        );
      },
    );

    if (confirmDelete == true) {
      try {
        final DocumentReference docRef = FirebaseFirestore.instance
            .collection('artifacts/${widget.userId}/users/${widget.userId}/transactions')
            .doc(transactionId);
        await docRef.delete(); // Deleta o documento do Firestore.
        _showCustomSnackBar('Transação deletada com sucesso!');
      } catch (e) {
        _showCustomSnackBar('Erro ao deletar transação: $e');
        print('Erro ao deletar transação: $e');
      }
    }
  }

  // Limpa os campos do formulário de adicionar transação.
  void _clearForm() {
    _descriptionController.clear();
    _amountController.clear();
    setState(() {
      _transactionType = 'expense';
      _category = '';
      _selectedDate = null;
      _isRecurring = false;
      _frequency = 'monthly'; // Reseta a frequência para o padrão.
    });
  }

  // Exibe um SnackBar personalizado para mensagens ao usuário.
  void _showCustomSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2), // Duração da exibição.
        backgroundColor: Colors.indigo,
        behavior: SnackBarBehavior.floating, // Comportamento flutuante.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), // Cantos arredondados.
        margin: const EdgeInsets.all(10), // Margem ao redor do SnackBar.
      ),
    );
  }

  // Calcula o resumo financeiro (receitas totais, despesas totais, saldo).
  Map<String, double> _calculateSummary() {
    double totalIncome = 0;
    double totalExpense = 0;

    for (var t in _transactions) {
      if (t.type == 'income') {
        totalIncome += t.amount;
      } else {
        totalExpense += t.amount;
      }
    }
    return {
      'totalIncome': totalIncome,
      'totalExpense': totalExpense,
      'balance': totalIncome - totalExpense,
    };
  }

  // Processa os dados das transações para exibição em gráficos (atualmente, uma tabela).
  List<Map<String, dynamic>> _processChartData() {
    Map<String, Map<String, double>> monthlyData = {};
    Map<String, double> categoriesData = {}; // Para análise da LLM: gastos por categoria.

    for (var t in _transactions) {
      final monthYear = '${t.date.month.toString().padLeft(2, '0')}/${t.date.year}';

      monthlyData.putIfAbsent(monthYear, () => {'income': 0.0, 'expense': 0.0});

      if (t.type == 'income') {
        monthlyData[monthYear]!['income'] = monthlyData[monthYear]!['income']! + t.amount;
      } else {
        monthlyData[monthYear]!['expense'] = monthlyData[monthYear]!['expense']! + t.amount;
        if (t.category.isNotEmpty) {
          final normalizedCategory = t.category.toLowerCase();
          categoriesData.update(normalizedCategory, (value) => value + t.amount, ifAbsent: () => t.amount);
        }
      }
    }

    final List<Map<String, dynamic>> chartDataArray = monthlyData.entries.map((entry) {
      return {'month': entry.key, 'income': entry.value['income'], 'expense': entry.value['expense']};
    }).toList();

    // Ordena os dados do gráfico por mês/ano.
    chartDataArray.sort((a, b) {
      final monthA = int.parse(a['month'].split('/')[0]);
      final yearA = int.parse(a['month'].split('/')[1]);
      final monthB = int.parse(b['month'].split('/')[0]);
      final yearB = int.parse(b['month'].split('/')[1]);

      if (yearA != yearB) return yearA.compareTo(yearB);
      return monthA.compareTo(monthB);
    });

    return chartDataArray;
  }

  // Função para chamar a API Gemini e gerar insights financeiros.
  Future<void> _generateFinancialInsights() async {
    setState(() {
      _isGeneratingInsights = true;
      _financialInsights = ''; // Limpa insights anteriores.
      _errorMessage = null;
    });

    final summaryData = _calculateSummary();
    final chartData = _processChartData();
    final currentMonthData = chartData.isNotEmpty ? chartData.last : null;
    final lastMonthData = chartData.length > 1 ? chartData[chartData.length - 2] : null;

    // Adapta a lógica de top categorias de despesas para Dart.
    Map<String, double> categoriesMap = {};
    for (var t in _transactions) {
      if (t.type == 'expense' && t.category.isNotEmpty) {
        final normalizedCategory = t.category.toLowerCase();
        categoriesMap.update(normalizedCategory, (value) => value + t.amount, ifAbsent: () => t.amount);
      }
    }
    final sortedCategories = categoriesMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topCategories = sortedCategories.take(5).map((e) => '${e.key}: R\$ ${e.value.toStringAsFixed(2)}').toList();

    // Constrói o prompt para a LLM (modelo de linguagem grande).
    String prompt = '''Analise os seguintes dados financeiros para o usuário. Forneça insights, tendências e sugestões de forma amigável e construtiva, como se fosse um assistente financeiro.
Resumo Geral:
- Receitas Totais: R\$ ${summaryData['totalIncome']?.toStringAsFixed(2)}
- Despesas Totais: R\$ ${summaryData['totalExpense']?.toStringAsFixed(2)}
- Saldo Atual: R\$ ${summaryData['balance']?.toStringAsFixed(2)}
''';

    if (currentMonthData != null) {
      prompt += '''
Dados do Mês Atual (${currentMonthData['month']}):
- Receitas: R\$ ${currentMonthData['income']?.toStringAsFixed(2)}
- Despesas: R\$ ${currentMonthData['expense']?.toStringAsFixed(2)}
''';
    }

    if (lastMonthData != null) {
      prompt += '''
Dados do Mês Anterior (${lastMonthData['month']}):
- Receitas: R\$ ${lastMonthData['income']?.toStringAsFixed(2)}
- Despesas: R\$ ${lastMonthData['expense']?.toStringAsFixed(2)}
''';
    }

    if (topCategories.isNotEmpty) {
      prompt += '''
Principais Gastos por Categoria (todos os meses):
- ${topCategories.join('\n- ')}
''';
    }

    prompt += '\nCom base nisso, o que você pode me dizer sobre minha saúde financeira? Onde posso melhorar?';

    try {
      final chatHistory = [
        {'role': 'user', 'parts': [{'text': prompt}]}
      ];
      final payload = {
        'contents': chatHistory,
      };

      // A API Key para a Gemini API será injetada automaticamente pelo ambiente Canvas.
      // Em um app Flutter real, você gerencia essa chave de forma mais segura (ex: variáveis de ambiente).
      const apiKey = ''; // Deixe vazio para o Canvas injetar a chave.
      const apiUrl = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$apiKey';

      // Faz a requisição HTTP POST para a API Gemini.
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      final Map<String, dynamic> result = jsonDecode(response.body);

      // Verifica se a resposta da API foi bem-sucedida e contém o texto.
      if (response.statusCode == 200 &&
          result['candidates'] != null &&
          result['candidates'].isNotEmpty &&
          result['candidates'][0]['content'] != null &&
          result['candidates'][0]['content']['parts'] != null &&
          result['candidates'][0]['content']['parts'].isNotEmpty) {
        final text = result['candidates'][0]['content']['parts'][0]['text'];
        setState(() {
          _financialInsights = text;
        });
        _showCustomSnackBar('Análise gerada com sucesso!');
      } else {
        // Trata respostas inesperadas ou erros da API.
        setState(() {
          _errorMessage = 'Não foi possível gerar a análise. Resposta inesperada da API. Código: ${response.statusCode}, Erro: ${result['error']?['message'] ?? 'Desconhecido'}';
        });
        print('Erro API Gemini: Resposta inesperada: $result');
      }
    } catch (e) {
      // Trata erros de comunicação com a API.
      setState(() {
        _errorMessage = 'Erro ao se comunicar com o serviço de análise: $e';
      });
      print('Erro ao chamar API Gemini: $e');
    } finally {
      setState(() {
        _isGeneratingInsights = false; // Finaliza o estado de carregamento.
      });
    }
  }

  // Função auxiliar para traduzir a frequência de recorrência para português.
  String _translateFrequency(String freq) {
    switch (freq) {
      case 'daily': return 'Diário';
      case 'weekly': return 'Semanal';
      case 'bi-weekly': return 'Quinzenal';
      case 'monthly': return 'Mensal';
      case 'quarterly': return 'Trimestral';
      case 'semi-annually': return 'Semestral';
      case 'yearly': return 'Anual';
      default: return freq;
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _calculateSummary(); // Calcula o resumo financeiro para exibir.

    return Scaffold(
      // AppBar (cabeçalho do aplicativo).
      appBar: AppBar(
        title: const Text('CodeBuddy - Controle Financeiro'),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.indigo, Colors.purple],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 0,
      ),
      // O corpo principal do aplicativo, que muda conforme a aba selecionada.
      body: _buildBody(summary),
      // Barra de navegação inferior.
      bottomNavigationBar: _buildBottomNavigationBar(),
      // Floating Action Button (botão flutuante para adicionar transação).
      floatingActionButton: _selectedIndex == 0 // Exibido apenas na aba Dashboard.
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _selectedIndex = 1; // Muda para a aba de adicionar transação.
                });
              },
              backgroundColor: Colors.indigo,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30.0)),
              elevation: 8,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked, // Posicionamento do FAB.
    );
  }

  // Constrói o corpo principal da tela com base no índice da aba selecionada.
  Widget _buildBody(Map<String, double> summary) {
    if (_isLoadingData) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Erro: $_errorMessage',
            style: const TextStyle(color: Colors.red, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    switch (_selectedIndex) {
      case 0:
        return _buildDashboard(summary);
      case 1:
        return _buildAddTransactionForm();
      case 2:
        return _buildCharts();
      default:
        return const Center(child: Text('Aba não encontrada'));
    }
  }

  // Constrói o Dashboard do aplicativo.
  Widget _buildDashboard(Map<String, double> summary) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cartões de Resumo (Receitas e Despesas).
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Colors.greenAccent,
                          radius: 20,
                          child: Icon(Icons.arrow_upward, color: Colors.green, size: 24),
                        ),
                        const SizedBox(height: 8),
                        const Text('Receitas', style: TextStyle(fontSize: 14, color: Colors.grey)),
                        Text('R\$ ${summary['totalIncome']?.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        const CircleAvatar(
                          backgroundColor: Colors.redAccent,
                          radius: 20,
                          child: Icon(Icons.arrow_downward, color: Colors.red, size: 24),
                        ),
                        const SizedBox(height: 8),
                        const Text('Despesas', style: TextStyle(fontSize: 14, color: Colors.grey)),
                        Text('R\$ ${summary['totalExpense']?.toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Botão para gerar análise financeira com Gemini API.
          ElevatedButton.icon(
            onPressed: _isGeneratingInsights ? null : _generateFinancialInsights,
            icon: _isGeneratingInsights
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.psychology, color: Colors.white),
            label: Text(
              _isGeneratingInsights ? 'Gerando Análise...' : 'Gerar Análise Financeira ✨',
              style: const TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 5,
            ),
          ),
          const SizedBox(height: 16),

          // Exibição dos insights financeiros gerados pelo LLM.
          if (_financialInsights.isNotEmpty)
            Card(
              elevation: 4,
              color: Colors.indigo.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '✨ Insights Financeiros ✨',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _financialInsights,
                      style: const TextStyle(fontSize: 14, color: Colors.black87),
                      softWrap: true,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),

          // Título das Transações Recentes.
          Text(
            'Transações Recentes',
            style: Theme.of(context).textTheme.headlineSmall, // CORRIGIDO: headline6 para headlineSmall
          ),
          const SizedBox(height: 16),
          // Exibe as transações recentes ou uma mensagem de vazio.
          if (_transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: Text('Nenhuma transação registrada ainda.')),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _transactions.length > 5 ? 5 : _transactions.length,
              itemBuilder: (context, index) {
                final transaction = _transactions[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 8.0),
                  elevation: 2,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: transaction.type == 'income' ? Colors.green.shade100 : Colors.red.shade100,
                      child: Icon(
                        transaction.type == 'income' ? Icons.arrow_upward : Icons.arrow_downward,
                        color: transaction.type == 'income' ? Colors.green : Colors.red,
                      ),
                    ),
                    title: Text(
                      '${transaction.description} ${transaction.isRecurring ? '(🔁 ${_translateFrequency(transaction.frequency!)})' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('${transaction.category} • ${transaction.date.day.toString().padLeft(2, '0')}/${transaction.date.month.toString().padLeft(2, '0')}/${transaction.date.year}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'R\$ ${transaction.amount.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: transaction.type == 'income' ? Colors.green : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.grey),
                          onPressed: () => _deleteTransaction(transaction.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (_transactions.length > 5)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Center(
                child: TextButton(
                  onPressed: () {
                    _showCustomSnackBar('Funcionalidade "Ver todas as transações" em desenvolvimento!');
                  },
                  child: const Text('Ver todas as transações', style: TextStyle(color: Colors.blue)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Constrói o formulário para adicionar novas transações.
  Widget _buildAddTransactionForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Adicionar Nova Transação',
                style: Theme.of(context).textTheme.headlineSmall, // CORRIGIDO: headline6 para headlineSmall
              ),
              const SizedBox(height: 16),
              // Campo de texto para a descrição.
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Descrição',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                ),
              ),
              const SizedBox(height: 16),
              // Campo de texto para o valor.
              TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Valor (R\$)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.attach_money),
                ),
              ),
              const SizedBox(height: 16),
              // Dropdown para o tipo (Despesa/Receita).
              DropdownButtonFormField<String>(
                value: _transactionType,
                decoration: const InputDecoration(
                  labelText: 'Tipo',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.compare_arrows),
                ),
                items: const [
                  DropdownMenuItem(value: 'expense', child: Text('Despesa')),
                  DropdownMenuItem(value: 'income', child: Text('Receita')),
                ],
                onChanged: (value) {
                  setState(() {
                    _transactionType = value!;
                  });
                },
              ),
              const SizedBox(height: 16),
              // Campo de texto para a categoria.
              TextField(
                onChanged: (value) {
                  setState(() {
                    _category = value;
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Categoria (Opcional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.category),
                ),
              ),
              const SizedBox(height: 16),
              // Campo para seleção de data (abre um seletor de data).
              GestureDetector(
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2101),
                  );
                  if (picked != null && picked != _selectedDate) {
                    setState(() {
                      _selectedDate = picked;
                    });
                  }
                },
                child: AbsorbPointer(
                  child: TextField(
                    controller: TextEditingController(
                        text: _selectedDate == null ? '' : '${_selectedDate!.day.toString().padLeft(2, '0')}/${_selectedDate!.month.toString().padLeft(2, '0')}/${_selectedDate!.year}'),
                    decoration: const InputDecoration(
                      labelText: 'Data',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Checkbox para marcar como transação recorrente.
              Row(
                children: [
                  Checkbox(
                    value: _isRecurring,
                    onChanged: (bool? value) {
                      setState(() {
                        _isRecurring = value ?? false;
                        if (!(_isRecurring)) {
                          _frequency = 'monthly';
                        }
                      });
                    },
                  ),
                  const Text('É recorrente?'),
                ],
              ),
              // Dropdown para frequência, visível apenas se for recorrente.
              if (_isRecurring) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _frequency,
                  decoration: const InputDecoration(
                    labelText: 'Frequência',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.repeat),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'daily', child: Text('Diário')),
                    DropdownMenuItem(value: 'weekly', child: Text('Semanal')),
                    DropdownMenuItem(value: 'bi-weekly', child: Text('Quinzenal')),
                    DropdownMenuItem(value: 'monthly', child: Text('Mensal')),
                    DropdownMenuItem(value: 'quarterly', child: Text('Trimestral')),
                    DropdownMenuItem(value: 'semi-annually', child: Text('Semestral')),
                    DropdownMenuItem(value: 'yearly', child: Text('Anual')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _frequency = value!;
                    });
                  },
                ),
              ],
              const SizedBox(height: 24),
              // Botão para adicionar a transação.
              ElevatedButton(
                onPressed: _addTransaction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 5,
                ),
                child: const Text('Adicionar Transação', style: TextStyle(fontSize: 18, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Constrói a tela de Gráficos (apenas exibição tabular para demonstração).
  Widget _buildCharts() {
    final chartData = _processChartData();

    if (chartData.isEmpty) {
      return const Center(child: Text('Não há dados suficientes para gerar gráficos. Adicione mais transações!'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Gráficos de Receitas e Despesas por Mês',
                style: Theme.of(context).textTheme.headlineSmall, // CORRIGIDO: headline6 para headlineSmall
              ),
              const SizedBox(height: 16),
              // Tabela de dados para simular o gráfico.
              Table(
                border: TableBorder.all(color: Colors.grey.shade300),
                columnWidths: const {
                  0: FlexColumnWidth(2),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(1),
                },
                children: [
                  const TableRow(
                    decoration: BoxDecoration(color: Colors.indigo),
                    children: [
                      Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Text('Mês', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                      Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Text('Receita', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                      Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Text('Despesa', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ],
                  ),
                  ...chartData.map((data) {
                    return TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(data['month']!),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text('R\$ ${data['income']?.toStringAsFixed(2)}', style: const TextStyle(color: Colors.green)),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text('R\$ ${data['expense']?.toStringAsFixed(2)}', style: const TextStyle(color: Colors.red)),
                        ),
                      ],
                    );
                  }).toList(),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '**Nota:** Em um aplicativo Flutter real, você usaria bibliotecas como `fl_chart` ou `charts_flutter` para renderizar gráficos visuais aqui.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Constrói a barra de navegação inferior.
  Widget _buildBottomNavigationBar() {
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 8.0,
      color: Colors.white,
      elevation: 10,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          _buildNavBarItem(0, Icons.home, 'Principal'),
          // O espaço para o FAB é deixado automaticamente aqui pelo BottomAppBar.
          _buildNavBarItem(2, Icons.bar_chart, 'Gráficos'),
        ],
      ),
    );
  }

  // Constrói um item individual da barra de navegação.
  Widget _buildNavBarItem(int index, IconData icon, String label) {
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedIndex = index;
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                color: _selectedIndex == index ? Colors.indigo : Colors.grey.shade600,
                size: 28,
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: _selectedIndex == index ? Colors.indigo : Colors.grey.shade600,
                  fontWeight: _selectedIndex == index ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}