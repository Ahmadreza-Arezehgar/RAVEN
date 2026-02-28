import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:intl/intl.dart';

/// ✅ Modern Liquid Glass Schedule Picker
/// Preset chips + iOS-style time wheel + Jalali support
class SchedulePickerSheet extends StatefulWidget {
  final DateTime? initialDate;
  final Function(DateTime scheduledAtUtc) onConfirm;

  const SchedulePickerSheet({
    super.key,
    this.initialDate,
    required this.onConfirm,
  });

  /// Show the schedule picker sheet
  static Future<DateTime?> show(BuildContext context, {DateTime? initialDate}) async {
    DateTime? result;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SchedulePickerSheet(
        initialDate: initialDate,
        onConfirm: (dt) => result = dt,
      ),
    );
    return result;
  }

  @override
  State<SchedulePickerSheet> createState() => _SchedulePickerSheetState();
}

class _SchedulePickerSheetState extends State<SchedulePickerSheet> {
  late DateTime _selectedDate;
  late TimeOfDay _selectedTime;
  bool _isPersian = false;
  String? _activePreset;
  bool _showCustomPicker = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = widget.initialDate ?? now.add(const Duration(hours: 1));
    _selectedTime = TimeOfDay(hour: _selectedDate.hour, minute: _selectedDate.minute);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    _isPersian = locale.languageCode == 'fa';
  }

  // Preset definitions
  List<_PresetOption> get _presets => [
    _PresetOption(
      id: '10min',
      label: _isPersian ? '۱۰ دقیقه دیگر' : 'In 10 min',
      icon: Icons.timer_outlined,
      getTime: () => DateTime.now().add(const Duration(minutes: 10)),
    ),
    _PresetOption(
      id: '1hour',
      label: _isPersian ? '۱ ساعت دیگر' : 'In 1 hour',
      icon: Icons.schedule_outlined,
      getTime: () => DateTime.now().add(const Duration(hours: 1)),
    ),
    _PresetOption(
      id: 'tonight',
      label: _isPersian ? 'امشب ۲۱:۰۰' : 'Tonight 9 PM',
      icon: Icons.nightlight_outlined,
      getTime: () {
        final now = DateTime.now();
        var tonight = DateTime(now.year, now.month, now.day, 21, 0);
        if (tonight.isBefore(now)) tonight = tonight.add(const Duration(days: 1));
        return tonight;
      },
    ),
    _PresetOption(
      id: 'tomorrow',
      label: _isPersian ? 'فردا صبح' : 'Tomorrow 9 AM',
      icon: Icons.wb_sunny_outlined,
      getTime: () {
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day + 1, 9, 0);
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 20),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            color: const Color(0xFF1C1C1E).withOpacity(0.85),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white.withOpacity(0.35),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              
              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF32D74B).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.schedule_rounded, 
                      color: Color(0xFF32D74B), 
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _isPersian ? 'زمان ارسال' : 'When to send?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Quick preset chips
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _presets.map((preset) => _buildPresetChip(preset)).toList(),
              ),
              
              const SizedBox(height: 16),
              
              // Custom time button
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _showCustomPicker = !_showCustomPicker;
                    _activePreset = null;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: _showCustomPicker 
                        ? Colors.white.withOpacity(0.12)
                        : Colors.white.withOpacity(0.06),
                    border: Border.all(
                      color: _showCustomPicker 
                          ? Colors.white.withOpacity(0.2)
                          : Colors.white.withOpacity(0.08),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.edit_calendar_outlined, 
                        color: Colors.white.withOpacity(0.7),
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _isPersian ? 'انتخاب دقیق زمان' : 'Pick exact time',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 15,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _showCustomPicker ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        color: Colors.white.withOpacity(0.5),
                      ),
                    ],
                  ),
                ),
              ),
              
              // Custom picker (expandable)
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: _showCustomPicker ? _buildCustomPicker() : const SizedBox.shrink(),
              ),
              
              const SizedBox(height: 20),
              
              // Preview
              if (_activePreset != null || _showCustomPicker)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: const Color(0xFF0A84FF).withOpacity(0.12),
                    border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.25)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.send_rounded, 
                        color: Color(0xFF0A84FF),
                        size: 18,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _isPersian ? 'ارسال:' : 'Will send:',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _getFullPreview(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              
              const SizedBox(height: 20),
              
              // Confirm button
              GestureDetector(
                onTap: (_activePreset != null || _showCustomPicker) ? _confirm : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: (_activePreset != null || _showCustomPicker)
                        ? const Color(0xFF0A84FF)
                        : Colors.white.withOpacity(0.1),
                  ),
                  child: Center(
                    child: Text(
                      _isPersian ? 'تأیید' : 'Schedule',
                      style: TextStyle(
                        color: (_activePreset != null || _showCustomPicker)
                            ? Colors.white
                            : Colors.white.withOpacity(0.4),
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(_PresetOption preset) {
    final isActive = _activePreset == preset.id;
    
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        final time = preset.getTime();
        setState(() {
          _activePreset = preset.id;
          _showCustomPicker = false;
          _selectedDate = time;
          _selectedTime = TimeOfDay(hour: time.hour, minute: time.minute);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isActive 
              ? const Color(0xFF32D74B).withOpacity(0.2)
              : Colors.white.withOpacity(0.08),
          border: Border.all(
            color: isActive 
                ? const Color(0xFF32D74B).withOpacity(0.5)
                : Colors.white.withOpacity(0.1),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              preset.icon,
              color: isActive ? const Color(0xFF32D74B) : Colors.white.withOpacity(0.7),
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              preset.label,
              style: TextStyle(
                color: isActive ? Colors.white : Colors.white.withOpacity(0.8),
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomPicker() {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          // Date picker tile
          _buildPickerTile(
            icon: Icons.calendar_today_rounded,
            label: _isPersian ? 'تاریخ' : 'Date',
            value: _formatDate(),
            onTap: _pickDate,
          ),
          const SizedBox(height: 10),
          
          // Time picker tile
          _buildPickerTile(
            icon: Icons.access_time_rounded,
            label: _isPersian ? 'ساعت' : 'Time',
            value: _formatTime(),
            onTap: _pickTime,
          ),
        ],
      ),
    );
  }

  Widget _buildPickerTile({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withOpacity(0.08),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white.withOpacity(0.6), size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, 
              color: Colors.white.withOpacity(0.3),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate() {
    if (_isPersian) {
      final jalali = Jalali.fromDateTime(_selectedDate);
      return '${jalali.day} ${_jalaliMonthName(jalali.month)} ${jalali.year}';
    } else {
      return DateFormat.MMMd().format(_selectedDate);
    }
  }

  String _formatTime() {
    final hour = _selectedTime.hour.toString().padLeft(2, '0');
    final minute = _selectedTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _getFullPreview() {
    return '${_formatDate()} • ${_formatTime()}';
  }

  String _jalaliMonthName(int month) {
    const months = [
      'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
      'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'
    ];
    return months[month - 1];
  }

  Future<void> _pickDate() async {
    HapticFeedback.selectionClick();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF0A84FF),
            surface: Color(0xFF1C1C1E),
            onSurface: Colors.white,
          ),
          dialogBackgroundColor: const Color(0xFF1C1C1E),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _pickTime() async {
    HapticFeedback.selectionClick();
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF0A84FF),
            surface: Color(0xFF1C1C1E),
            onSurface: Colors.white,
          ),
          dialogBackgroundColor: const Color(0xFF1C1C1E),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  void _confirm() {
    HapticFeedback.mediumImpact();
    
    // Combine date and time
    final scheduledLocal = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );
    
    // ✅ Always store as UTC
    final scheduledUtc = scheduledLocal.toUtc();
    
    widget.onConfirm(scheduledUtc);
    Navigator.pop(context);
  }
}

class _PresetOption {
  final String id;
  final String label;
  final IconData icon;
  final DateTime Function() getTime;

  _PresetOption({
    required this.id,
    required this.label,
    required this.icon,
    required this.getTime,
  });
}
