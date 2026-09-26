import 'package:flutter_contacts/flutter_contacts.dart';

class ContactsService {
  /// Search contacts by name. Returns formatted results.
  Future<List<Contact>> searchContacts(String query) async {
    if (!await FlutterContacts.requestPermission()) {
      return [];
    }

    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );

    final lowerQuery = query.toLowerCase();
    return contacts.where((c) {
      return c.displayName.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Get phone number for a contact name. Returns the first match.
  Future<String?> getPhoneNumber(String contactName) async {
    final matches = await searchContacts(contactName);
    if (matches.isEmpty) return null;

    final contact = matches.first;
    if (contact.phones.isEmpty) return null;

    return contact.phones.first.number;
  }

  /// Format contact search results as readable text
  Future<String> searchAndFormat(String query) async {
    final contacts = await searchContacts(query);

    if (contacts.isEmpty) {
      return 'No contacts found matching "$query".';
    }

    final buffer = StringBuffer('Found ${contacts.length} contact(s):\n');
    for (final contact in contacts.take(5)) {
      buffer.write('• ${contact.displayName}');
      if (contact.phones.isNotEmpty) {
        buffer.write(' - ${contact.phones.first.number}');
      }
      if (contact.emails.isNotEmpty) {
        buffer.write(' - ${contact.emails.first.address}');
      }
      buffer.writeln();
    }
    if (contacts.length > 5) {
      buffer.writeln('...and ${contacts.length - 5} more');
    }

    return buffer.toString();
  }
}
