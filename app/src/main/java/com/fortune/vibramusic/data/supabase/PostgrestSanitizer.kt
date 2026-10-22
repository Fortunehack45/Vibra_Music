package com.fortune.vibramusic.data.supabase

import java.util.regex.Pattern

/**
 * Defensive security utility for PostgREST / PostgreSQL query parameter sanitization
 * and injection prevention.
 *
 * Protects against:
 * - PostgREST Filter Injection (delimiters like `,`, `(`, `)`, `"`, `\`)
 * - PostgreSQL ILIKE Wildcard Enumeration / ReDoS (`%`, `_`)
 * - In-Filter Parameter Injection
 * - JSON Payload Field Injection
 */
object PostgrestSanitizer {

    private val SAFE_ID_PATTERN = Pattern.compile("^[a-zA-Z0-9_\\-\\.:]{1,128}$")
    private val POSTGREST_RESERVED_CHARS = Pattern.compile("[,()\"\\\\]")

    /**
     * Sanitizes search queries intended for PostgREST `ilike` filters.
     *
     * 1. Strips PostgREST query delimiters `,`, `(`, `)`, `"`, `\`.
     * 2. Escapes PostgreSQL LIKE wildcards `%` -> `\%` and `_` -> `\_` to prevent
     *    uncontrolled wildcard matching and quadratic evaluation attacks.
     * 3. Truncates length to prevent buffer/parser degradation.
     */
    fun escapeIlikePattern(query: String, maxLen: Int = 100): String {
        if (query.isBlank()) return ""
        val truncated = query.trim().take(maxLen)
        // Strip PostgREST syntax delimiters that could break out of or(...) clauses
        val stripped = POSTGREST_RESERVED_CHARS.matcher(truncated).replaceAll("")
        // Escape SQL LIKE wildcards
        return stripped
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")
            .trim()
    }

    /**
     * Validates and sanitizes an entity identifier (user_id, post_id, comment_id, etc.).
     * Returns the sanitized ID, or [fallback] if the ID contains prohibited characters.
     */
    fun sanitizeIdentifier(id: String, fallback: String = ""): String {
        val trimmed = id.trim()
        if (trimmed.contains("--") || trimmed.contains("/*") || trimmed.contains(";") || trimmed.contains("'")) {
            return fallback
        }
        return if (SAFE_ID_PATTERN.matcher(trimmed).matches() && trimmed.length <= 128) {
            trimmed
        } else {
            // Strip any non-allowed characters as a defensive fallback
            val cleaned = trimmed.replace(Regex("[^a-zA-Z0-9_\\-\\.:]"), "")
                .replace(Regex("-{2,}"), "-")
                .trim('-')
            if (cleaned.isNotBlank() && cleaned.length <= 128) cleaned else fallback
        }
    }

    /**
     * Constructs a safe PostgREST `in.(id1,id2,...)` filter expression.
     * Guarantees every element adheres strictly to safe identifier formatting.
     */
    fun buildSafeInFilter(ids: Collection<String>): String {
        val validIds = ids.asSequence()
            .map { sanitizeIdentifier(it) }
            .filter { it.isNotBlank() }
            .distinct()
            .toList()
        return if (validIds.isEmpty()) "in.()" else "in.(${validIds.joinToString(",")})"
    }

    /**
     * Strictly escapes a string literal for inclusion in JSON payloads,
     * preventing JSON string breakout or unauthorized attribute injection.
     */
    fun safeJsonString(value: String): String {
        val sb = StringBuilder()
        sb.append('"')
        for (i in 0 until value.length) {
            val c = value[i]
            when (c) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> {
                    if (c.code in 0x00..0x1F) {
                        sb.append(String.format("\\u%04x", c.code))
                    } else {
                        sb.append(c)
                    }
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
