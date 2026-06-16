import Foundation

/// Typed errors for database operations.
/// Provides actionable error information for UI display and recovery decisions.
enum DatabaseError: Error, LocalizedError {
    /// A write was attempted while the database connection is closed.
    case notOpen
    /// The database file could not be opened.
    case openFailed(underlying: Error)
    /// Schema migration failed during database open.
    case migrationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notOpen:
            return "Database is not open. Captures cannot be saved."
        case .openFailed(let underlying):
            return "Failed to open database: \(underlying.localizedDescription)"
        case .migrationFailed(let underlying):
            return "Database migration failed: \(underlying.localizedDescription)"
        }
    }
}
