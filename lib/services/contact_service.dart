import 'package:contacts_service/contacts_service.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for managing contact permissions and verification
class ContactService {
  /// Request permission to access contacts
  static Future<bool> requestContactsPermission() async {
    final status = await Permission.contacts.request();
    return status.isGranted;
  }
  
  /// Check if contacts permission is already granted
  static Future<bool> hasContactsPermission() async {
    final status = await Permission.contacts.status;
    return status.isGranted;
  }
  
  /// Get all contacts from device
  static Future<List<Contact>> getAllContacts() async {
    if (await hasContactsPermission()) {
      return await ContactsService.getContacts();
    }
    return [];
  }
  
  /// Check if a user is in the device contacts
  /// 
  /// Verifies by checking email or phone number against contacts.
  /// Returns true if at least one match is found.
  static Future<bool> isInContacts({
    String? email,
    String? phone,
  }) async {
    // If neither email nor phone provided, cannot verify
    if (email == null && phone == null) {
      return false;
    }
    
    // Get all contacts
    final contacts = await getAllContacts();
    
    if (contacts.isEmpty) {
      return false;
    }
    
    // Check each contact
    for (var contact in contacts) {
      // Check emails
      if (email != null && contact.emails != null) {
        for (var contactEmail in contact.emails!) {
          if (contactEmail.value != null &&
              _normalizeEmail(contactEmail.value!) == _normalizeEmail(email)) {
            print('✅ Found contact match by email: ${contact.displayName ?? "Unknown"}');
            return true;
          }
        }
      }
      
      // Check phones
      if (phone != null && contact.phones != null) {
        for (var contactPhone in contact.phones!) {
          if (contactPhone.value != null &&
              _normalizePhone(contactPhone.value!) == _normalizePhone(phone)) {
            print('✅ Found contact match by phone: ${contact.displayName ?? "Unknown"}');
            return true;
          }
        }
      }
    }
    
    print('❌ No contact match found for email: $email, phone: $phone');
    return false;
  }
  
  /// Normalize email for comparison
  static String _normalizeEmail(String email) {
    return email.toLowerCase().trim();
  }
  
  /// Normalize phone number for comparison
  /// Removes spaces, dashes, parentheses, and other formatting
  static String _normalizePhone(String phone) {
    // Remove all non-digit characters except +
    return phone.replaceAll(RegExp(r'[^\d+]'), '');
  }
}
