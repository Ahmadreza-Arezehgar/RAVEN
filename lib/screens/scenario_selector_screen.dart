import 'package:flutter/material.dart';
import '../services/dtn_config_service.dart';
import '../services/toast_service.dart';

/// Scenario Selector UI
/// تغییر manual یا auto-detect سناریو
class ScenarioSelectorScreen extends StatefulWidget {
  const ScenarioSelectorScreen({Key? key}) : super(key: key);

  @override
  State<ScenarioSelectorScreen> createState() => _ScenarioSelectorScreenState();
}

class _ScenarioSelectorScreenState extends State<ScenarioSelectorScreen> {
  final _configService = DTNConfigService.instance;
  DTNScenario? _selectedScenario;
  late DTNScenario _currentScenario;

  @override
  void initState() {
    super.initState();
    _currentScenario = _configService.scenario;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('⚙️ DTN Scenario'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'فعلی:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _buildCurrentScenario(),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'انتخاب سناریو:',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildScenarioCard(
            scenario: null,
            title: '🤖 Auto-Detect',
            description: 'تشخیص خودکار بر اساس محیط',
            icon: Icons.auto_awesome,
          ),
          _buildScenarioCard(
            scenario: DTNScenario.normal,
            title: '📱 Normal',
            description: 'استفاده عادی روزمره',
            icon: Icons.phone_android,
          ),
          _buildScenarioCard(
            scenario: DTNScenario.crowded,
            title: '👥 Crowded',
            description: 'محیط شلوغ با اینترنت',
            icon: Icons.people,
          ),
          _buildScenarioCard(
            scenario: DTNScenario.event,
            title: '🎓 Event/University',
            description: 'رویداد شلوغ + اینترنت ضعیف\nاولویت: Bluetooth',
            icon: Icons.school,
            color: Colors.purple,
          ),
          _buildScenarioCard(
            scenario: DTNScenario.camp,
            title: '🏕️ Camp',
            description: 'بدون اینترنت، چند نفر\nفقط Bluetooth',
            icon: Icons.landscape,
            color: Colors.green,
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentScenario() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(_getScenarioIcon(_currentScenario), size: 32),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _getScenarioTitle(_currentScenario),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                _getConfigSummary(),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScenarioCard({
    required DTNScenario? scenario,
    required String title,
    required String description,
    required IconData icon,
    Color? color,
  }) {
    final isSelected = scenario == _selectedScenario ||
        (scenario == null && _selectedScenario == null);

    return Card(
      color: isSelected ? (color ?? Colors.blue).withOpacity(0.1) : null,
      child: ListTile(
        leading: Icon(icon, size: 32, color: color),
        title: Text(title),
        subtitle: Text(description),
        trailing: isSelected
            ? const Icon(Icons.check_circle, color: Colors.green)
            : null,
        onTap: () {
          setState(() {
            _selectedScenario = scenario;
            _configService.initialize(scenario: scenario);
            _currentScenario = _configService.scenario;
          });
          ToastService.showSuccess('Changed to: $title');
        },
      ),
    );
  }

  IconData _getScenarioIcon(DTNScenario scenario) {
    switch (scenario) {
      case DTNScenario.normal:
        return Icons.phone_android;
      case DTNScenario.crowded:
        return Icons.people;
      case DTNScenario.event:
        return Icons.school;
      case DTNScenario.camp:
        return Icons.landscape;
    }
  }

  String _getScenarioTitle(DTNScenario scenario) {
    switch (scenario) {
      case DTNScenario.normal:
        return 'Normal';
      case DTNScenario.crowded:
        return 'Crowded';
      case DTNScenario.event:
        return 'Event/University';
      case DTNScenario.camp:
        return 'Camp';
    }
  }

  String _getConfigSummary() {
    final config = _configService.config;
    return 'Spray: ${config.sprayCounter}, TTL: ${config.ttl}, '
        'BT Priority: ${config.preferBluetoothOverServer ? 'Yes' : 'No'}';
  }
}
