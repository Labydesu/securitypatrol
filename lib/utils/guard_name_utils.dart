class GuardNameUtils {
  static String format({
    String? firstName,
    String? lastName,
    String? fallbackName,
  }) {
    final trimmedFirst = (firstName ?? '').trim();
    final trimmedLast = (lastName ?? '').trim();

    if (trimmedFirst.isEmpty && trimmedLast.isEmpty) {
      final fallback = (fallbackName ?? '').trim();
      return fallback.isEmpty ? 'Unnamed Guard' : fallback;
    }

    final parts = <String>[];
    if (trimmedLast.isNotEmpty) {
      parts.add(trimmedLast);
    }
    if (trimmedFirst.isNotEmpty) {
      parts.add(trimmedFirst);
    }

    return parts.isEmpty ? 'Unnamed Guard' : parts.join(' ');
  }

  static int compareAsc({
    String? aFirstName,
    String? aLastName,
    String? bFirstName,
    String? bLastName,
    String? aFallbackName,
    String? bFallbackName,
  }) {
    int compareStrings(String a, String b) => a.compareTo(b);

    String normalize(String? value) => (value ?? '').trim().toLowerCase();

    final aLast = normalize(aLastName);
    final bLast = normalize(bLastName);
    if (aLast.isEmpty && bLast.isEmpty) {
      // fall through
    } else if (aLast.isEmpty) {
      return 1; // Empty last names go to the end
    } else if (bLast.isEmpty) {
      return -1;
    } else {
      final lastCompare = compareStrings(aLast, bLast);
      if (lastCompare != 0) return lastCompare;
    }

    final aFirst = normalize(aFirstName);
    final bFirst = normalize(bFirstName);
    if (aFirst.isEmpty && bFirst.isEmpty) {
      // fall through
    } else if (aFirst.isEmpty) {
      return 1;
    } else if (bFirst.isEmpty) {
      return -1;
    } else {
      final firstCompare = compareStrings(aFirst, bFirst);
      if (firstCompare != 0) return firstCompare;
    }

    final aDisplay = normalize(
      format(firstName: aFirstName, lastName: aLastName, fallbackName: aFallbackName),
    );
    final bDisplay = normalize(
      format(firstName: bFirstName, lastName: bLastName, fallbackName: bFallbackName),
    );
    return compareStrings(aDisplay, bDisplay);
  }
}

