# FIXME: Code Cleanups and Improvements

This document outlines identified issues and potential cleanups in the codebase that should be addressed for better maintainability, performance, and code quality.

## 1. Code Duplication in Error Handling

Multiple methods in `SearchModel.swift` use similar patterns for error handling:
- `addURL(_:)` method sets `errorMessage` with a specific pattern
- `refetchMissingText()` and other methods also set `errorMessage` in similar ways
- Inconsistent error handling across methods (some return early, others throw)

## 2. Inconsistent Naming and Documentation

### Naming Issues:
- `focusSearch()` vs `findInPage()` - inconsistent naming patterns
- Method names don't follow a consistent style (some use verbs, others nouns)

### Documentation Issues:
- Some methods have detailed documentation while others are missing or minimal
- Documentation comments could be more consistent in format and content

## 3. Memory Management Concerns

### iOS AppDelegate:
- `retainedUploaders` array in `AppDelegate.swift` (iOS) might lead to memory leaks if not properly managed
- Background task handling logic could be simplified and made more predictable

### macOS AppDelegate:
- `uploaders` array in `AppDelegate.swift` (macOS) has similar potential issues

## 4. @MainActor Usage

The `SearchModel` is marked with `@MainActor` but:
- Many methods don't actually require main actor isolation
- This might impact performance and clarity of when actual UI updates occur

## 5. Hardcoded Values

### Magic Numbers:
- Value `50` used as search limit in multiple places (`queryChanged()`, `runSearch()`)
- Magic number `400` (milliseconds) in `withPhaseUpdates()` method
- Hardcoded values like `250` in search debouncing logic

## 6. Inconsistent Error Handling

### Methods with Different Approaches:
- Some methods use `try?` for error handling while others might throw errors
- Error propagation patterns aren't consistent across the codebase
- Some error handling returns early while others continue execution

## 7. Task Cancellation Patterns

### Search Task Management:
- `queryChanged()` method implements cancellation logic but could be simplified
- The pattern for handling task cancellation isn't consistently applied elsewhere

## 8. Redundant Checks

### Multiple Redundant Conditions:
- `AppServices.shared.isConfigured` check repeated in multiple methods
- Similar validation patterns in several methods that could be consolidated

## 9. Inconsistent Use of `try?` vs `try`

### Error Handling Patterns:
- Some methods use `try?` for potentially failing operations
- Others use strict error handling with explicit error propagation
- This inconsistency makes code harder to understand and maintain

## 10. Documentation Improvements

### README Content:
- The README contains extensive documentation but could benefit from:
  - More concise explanations in some sections
  - Better formatting for code examples and tables
  - More consistent terminology usage

## 11. Potential Performance Bottlenecks

### Background Operations:
- In `AppDelegate.swift` (iOS): Retained uploaders array that might cause memory leaks
- In `AppDelegate.swift` (macOS): Timer-based background operations that could be optimized

### UI Update Patterns:
- The `withPhaseUpdates` method with fixed polling intervals (400ms) might not be optimal for all scenarios

## 12. Code Structure Improvements

### Module Organization:
- Some methods in `SearchModel` might benefit from better organization
- The combination of search, sync, and ingest operations in one class could be refactored for better separation of concerns

## 13. Configuration and Constants

### Hardcoded Values:
- Several hardcoded configuration values that should be configurable or extracted to constants
- Server URL and token handling patterns could be made more consistent

These issues should be addressed in order of priority based on their impact on code stability, maintainability, and performance.